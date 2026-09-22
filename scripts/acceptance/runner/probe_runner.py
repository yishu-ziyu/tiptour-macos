"""Probe invocation: exact argument plumbing and self-exiting child processes.

The app's DEBUG probe entrypoints are the only sanctioned way to drive the real
product path (AGENTS.md + tools/voice-acceptance/README.md). This module owns
their argument order — a wrong launch argument is a runner bug that would
silently invalidate evidence, so the plumbing is golden-tested in self-tests.
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import paths
from .process_control import (
    OwnedProcessRegistry,
    OwnedProcess,
    spawn_owned_process,
    wait_for_owned_exit,
    terminate_owned_process,
)

PROBE_MODES = (
    "voice_task",
    "voice_continuity",
    "desktop_task",
    "voice_route",
    "jev_fanout",
    "unknown",
)


class ProbeError(RuntimeError):
    pass


@dataclass
class ProbeRequest:
    mode: str
    app_binary: Path
    working_out_dir: Path
    expected_bundle_identifier: str = paths.CONTROLLED_BROWSER_BUNDLE_IDENTIFIER
    utterance_pcm_paths: list[Path] = field(default_factory=list)
    tool_arguments_json: str | None = None
    goal_text: str | None = None
    report_file_name: str = "report.json"
    # Only for mode="unknown": the exact argv template configured after the
    # work order that owns the probe merges (probe 04). Placeholders are
    # substituted by build_unknown_probe_argv.
    unknown_argv_template: list[str] | None = None

    def describe(self) -> dict:
        return {
            "mode": self.mode,
            "app_binary": str(self.app_binary),
            "expected_bundle_identifier": self.expected_bundle_identifier,
            "utterance_pcm_paths": [str(path) for path in self.utterance_pcm_paths],
            "tool_arguments_json": self.tool_arguments_json,
            "goal_text": self.goal_text,
            "report_file_name": self.report_file_name,
            "unknown_argv_template": self.unknown_argv_template,
        }


def build_probe_argv(request: ProbeRequest) -> list[str]:
    """Exact argv for each documented probe entrypoint.

    Order matches TipTour/Voice/VoiceRouteProbe.swift:
      --voice-task-probe <bundleID> <input.pcm> <outputDir>
      --voice-continuity-probe <progress.pcm> <cancel.pcm> <report.json>
      --desktop-task-probe <bundleID> <argumentsJSON> <report.json>
      --voice-route-probe <input.pcm> <outputDir>
      --jev-fanout-probe <bundleID> <goal> <report.json>
    """
    binary = str(request.app_binary)
    output_dir = request.working_out_dir
    report_path = output_dir / request.report_file_name

    if request.mode == "voice_task":
        if len(request.utterance_pcm_paths) != 1:
            raise ProbeError("voice_task probe needs exactly one utterance PCM path.")
        return [binary, "--voice-task-probe", request.expected_bundle_identifier,
                str(request.utterance_pcm_paths[0]), str(output_dir)]

    if request.mode == "voice_continuity":
        if len(request.utterance_pcm_paths) != 2:
            raise ProbeError("voice_continuity probe needs two utterance PCM paths "
                             "(progress, cancel).")
        return [binary, "--voice-continuity-probe",
                str(request.utterance_pcm_paths[0]),
                str(request.utterance_pcm_paths[1]),
                str(report_path)]

    if request.mode == "desktop_task":
        if not request.tool_arguments_json:
            raise ProbeError("desktop_task probe needs tool arguments JSON.")
        return [binary, "--desktop-task-probe", request.expected_bundle_identifier,
                request.tool_arguments_json, str(report_path)]

    if request.mode == "voice_route":
        if len(request.utterance_pcm_paths) != 1:
            raise ProbeError("voice_route probe needs exactly one utterance PCM path.")
        return [binary, "--voice-route-probe", str(request.utterance_pcm_paths[0]),
                str(output_dir)]

    if request.mode == "jev_fanout":
        if not request.goal_text:
            raise ProbeError("jev_fanout probe needs goal text.")
        return [binary, "--jev-fanout-probe", request.expected_bundle_identifier,
                request.goal_text, str(report_path)]

    if request.mode == "unknown":
        return build_unknown_probe_argv(request)

    raise ProbeError(f"Unsupported probe mode: {request.mode!r}")


def build_unknown_probe_argv(request: ProbeRequest) -> list[str]:
    """Substitute the placeholders of an externally owned probe (work order 04)."""
    template = request.unknown_argv_template or []
    if not template:
        raise ProbeError(
            "The 'unknown' scenario needs an argv template; the probe that owns it "
            "has not been merged yet (pending-integrator-run)."
        )
    replacements = {
        "{app_binary}": str(request.app_binary),
        "{report}": str(request.working_out_dir / request.report_file_name),
        "{out_dir}": str(request.working_out_dir),
        "{bundle_id}": request.expected_bundle_identifier,
        "{fixture_url}": paths.FIXTURE_URL,
        "{pcm}": str(request.utterance_pcm_paths[0]) if request.utterance_pcm_paths else "",
    }
    argv: list[str] = []
    for token in template:
        for placeholder, value in replacements.items():
            token = token.replace(placeholder, value)
        argv.append(token)
    return argv


def binary_supports_flag(app_binary: Path, flag: str) -> bool:
    """Cheap capability check: does the built binary contain this probe flag?

    Used to detect that a not-yet-merged probe (e.g. the work order 04 fault
    injection probe) is absent, so the runner can mark the scenario
    pending-integrator-run instead of failing the wrong thing.
    """
    try:
        payload = app_binary.read_bytes()
    except OSError:
        return False
    return flag.encode("utf-8") in payload


@dataclass
class ProbeRunResult:
    request: ProbeRequest
    argv: list[str]
    child: OwnedProcess | None
    exit_record: dict
    report_path: Path
    report: dict | None
    report_error: str | None
    output_files: list[str]
    duration_seconds: float

    def to_dict(self) -> dict:
        return {
            "argv": self.argv,
            "exit_record": self.exit_record,
            "report_path": str(self.report_path),
            "report_error": self.report_error,
            "output_files": self.output_files,
            "duration_seconds": round(self.duration_seconds, 3),
            "log_path": str(self.child.log_path) if self.child and self.child.log_path else None,
        }


def run_probe(
    request: ProbeRequest,
    registry: OwnedProcessRegistry,
    timeout_seconds: float = 300.0,
) -> ProbeRunResult:
    argv = build_probe_argv(request)
    request.working_out_dir.mkdir(parents=True, exist_ok=True)
    started_at = time.monotonic()
    child = spawn_owned_process(
        registry,
        label=f"probe-{request.mode}",
        argv=argv,
        log_path=request.working_out_dir / f"probe-{request.mode}.log",
    )
    exit_record = wait_for_owned_exit(child, timeout_seconds=timeout_seconds)
    if exit_record["timed_out"]:
        # The probe did not exit by itself: stop only our own child, then record it.
        exit_record = terminate_owned_process(child)
        exit_record["timed_out"] = True
    report_path = request.working_out_dir / request.report_file_name
    report: dict | None = None
    report_error: str | None = None
    if report_path.is_file():
        try:
            report = json.loads(report_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            report_error = f"Report file is not valid JSON: {error}"
    else:
        report_error = "The probe did not write its report file."
    output_files = sorted(
        str(path.relative_to(request.working_out_dir))
        for path in request.working_out_dir.rglob("*")
        if path.is_file()
    )
    return ProbeRunResult(
        request=request,
        argv=argv,
        child=child,
        exit_record=exit_record,
        report_path=report_path,
        report=report,
        report_error=report_error,
        output_files=output_files,
        duration_seconds=time.monotonic() - started_at,
    )
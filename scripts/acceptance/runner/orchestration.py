"""One-command orchestration for the Her E2E acceptance run.

Modes:
  full     — real app, real provider, real desktop actions on the fixture page
  dry_run   — same pipeline with a runner-level mock executor (never proof)
  self_test — runner self-tests, no app involvement

Every mode writes the same evidence package shape. A hard preflight failure
(bundle/team/freshness/keychain/port) is recorded as BLOCKED and still produces
a complete package: the run must never die without evidence.
"""
from __future__ import annotations

import datetime as _datetime
import json
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path

from . import browser_stage, dry_run, evidence, paths, scenarios as scenario_defs
from .app_identity import inspect_app_identity, resolve_app_path
from .browser_stage import BrowserStageError, reload_controlled_page, stage_controlled_page
from .fixture_page import FixtureError, FixtureServer
from .process_control import (
    OwnedProcessRegistry,
    find_processes_matching,
    port_accepts_connections,
)
from .probe_runner import (
    ProbeRequest,
    binary_supports_flag,
    run_probe,
)
from .scenario_judges import (
    STATUS_FAILED,
    STATUS_PASSED,
    STATUS_PENDING,
    judge_scenario,
)
from .synthetic_speech import SpeechSynthesisError, synthesize_placeholder_for_self_tests, synthesize_utterance

HER_PROCESS_PATTERN = "Her.app/Contents/MacOS/Her"


@dataclass
class RunOptions:
    app_path_argument: str | None
    out_dir: Path
    mode: str
    selected_scenarios: list[str] | None = None
    repeat_overrides: dict[str, int] = field(default_factory=dict)
    dry_run_failure_injection: bool = False
    require_evidence_language: bool = False
    unknown_probe_argv_template: list[str] | None = None
    probe_timeout_seconds: float = 300.0


@dataclass
class RunContext:
    mode: str
    entrypoint: str
    app_path: Path
    out_dir: Path
    started_at_iso: str
    finished_at_iso: str | None = None
    provider_connection_attempted: bool = False
    app_identity_dict: dict | None = None


class RunAborted(RuntimeError):
    pass


def _utc_now_iso() -> str:
    return _datetime.datetime.now(_datetime.UTC).isoformat()


def _default_entrypoint(app_path: Path, out_dir: Path) -> str:
    return (f"python3 scripts/acceptance/her_voice_e2e.py "
            f"--app \"{app_path}\" --out {out_dir}")


def _scenario_directory(out_dir: Path, scenario_name: str) -> Path:
    return out_dir / "scenario-artifacts" / scenario_name


def _attempt_scenario_evidence(
    scenario,
    verdict: Verdict,
    utterance_record: dict,
    probe_record: dict,
    probe_report: dict | None,
    state_before: dict,
    state_after: dict,
    cleanup_record: dict,
    mock: bool,
) -> dict:
    evidence_payload = dict(verdict.evidence)
    evidence_payload.setdefault("user_words", scenario.user_words)
    if not evidence_payload.get("model_tool_arguments"):
        evidence_payload["model_tool_arguments"] = (
            (probe_report or {}).get("calls") if isinstance(probe_report, dict) else None
        )
    evidence_payload["independent_state"] = {"before": state_before, "after": state_after}
    if "final_speech" not in evidence_payload and isinstance(probe_report, dict):
        evidence_payload["final_speech"] = probe_report.get("rendered_texts")
    return {
        "utterance": utterance_record,
        "probe": probe_record,
        "probe_report": probe_report,
        "independent_state": {"before": state_before, "after": state_after},
        "process_exit": probe_record.get("exit_record"),
        "cleanup": cleanup_record,
        "mock": mock,
        "verdict": verdict.to_dict(),
    }


def _failure_recovery_record(scenario, verdict_status: str, verdict_evidence: dict,
                             cleanup: dict, rerun_hygiene: dict) -> dict:
    if scenario.name == "unknown_delivery_fault_recovery":
        if verdict_status == STATUS_PENDING:
            return {
                "fault_injected": False,
                "recovery_evidence": None,
                "note": ("Pending: the real delivery-unknown fault injection is owned by work "
                         "order 04 and its DEBUG probe is not in this binary yet. No fault was "
                         "injected and no recovery was exercised by this run."),
                "rerun_hygiene": rerun_hygiene,
            }
        return {
            "fault_injected": True,
            "recovery_evidence": verdict_evidence.get("independent_state"),
            "note": ("Fault injected after a successful delivery, before the confirmation "
                     "returns; recovery checked by continue-requesting the same task and "
                     "comparing independent /state before and after."),
            "rerun_hygiene": rerun_hygiene,
        }
    return {
        "fault_injected": False,
        "recovery_evidence": {
            "cleanup": cleanup,
            "note": ("No fault is injected in this scenario. The runner still records the "
                     "post-run dedup/recovery facts that matter for reruns: probe process "
                     "exit, fixture shutdown, port release and the next run's clean start."),
        },
        "rerun_hygiene": rerun_hygiene,
    }


def _synthesize_or_placeholder(text: str, cache_dir: Path, mode: str) -> tuple[dict, Path | None]:
    try:
        audio = synthesize_utterance(text, cache_dir)
        return audio.to_dict(), audio.pcm_path
    except SpeechSynthesisError as error:
        if mode == "dry_run":
            audio = synthesize_placeholder_for_self_tests(text, cache_dir)
            record = audio.to_dict()
            record["fallback_reason"] = str(error)
            record["evidence_grade"] = False
            return record, audio.pcm_path
        raise


def run_acceptance(options: RunOptions) -> int:
    started_at = _utc_now_iso()
    out_dir = options.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    app_path = resolve_app_path(options.app_path_argument)
    context = RunContext(
        mode=options.mode,
        entrypoint=_default_entrypoint(app_path, out_dir),
        app_path=app_path,
        out_dir=out_dir,
        started_at_iso=started_at,
    )
    registry = OwnedProcessRegistry()
    environment: dict = {}
    scenario_results: list[dict] = []
    blocked_reason: str | None = None

    identity = inspect_app_identity(app_path)
    context.app_identity_dict = identity.to_dict()
    evidence.write_json(
        out_dir / "app-identity.json",
        evidence.build_app_identity_document(context, identity.to_dict()),
    )

    try:
        loaded_scenarios = scenario_defs.load_scenarios(
            selected_names=options.selected_scenarios,
            repeat_overrides=options.repeat_overrides or None,
        )
    except scenario_defs.ScenarioError as error:
        blocked_reason = f"Scenario definitions are unusable: {error}"
        print(blocked_reason, flush=True)
        return _finish(context, options, [], {"scenario_definitions_error": str(error)},
                       exit_code=1, blocked_reason=blocked_reason)

    if options.mode == "full" and identity.blocking_reasons:
        blocked_reason = "Preflight BLOCKED: " + " ".join(identity.blocking_reasons)
        print(blocked_reason, flush=True)
        for scenario in loaded_scenarios:
            scenario_results.append({
                "name": scenario.name,
                "title": scenario.title,
                "status": "blocked",
                "user_words": scenario.user_words,
                "model_tool_arguments": None,
                "task_turn_attempt_ids": None,
                "her_receipt": None,
                "independent_state": None,
                "final_speech": None,
                "failure_recovery": {"fault_injected": False, "recovery_evidence": None,
                                     "note": "Blocked before any scenario ran."},
                "basis": [],
                "failure_reasons": list(identity.blocking_reasons),
                "attempts": [],
            })
        return _finish(context, options, scenario_results,
                       {"blocked": True, "blocking_reasons": identity.blocking_reasons},
                       exit_code=1, blocked_reason=blocked_reason)

    if identity.blocking_reasons and options.mode == "dry_run":
        environment["preflight_warnings"] = list(identity.blocking_reasons)
        print("Dry-run preflight warnings (recorded, not fatal):", flush=True)
        for reason in identity.blocking_reasons:
            print(f"  - {reason}", flush=True)

    # ---- fixture lifecycle (real in every mode) ----
    fixture = FixtureServer(out_dir, registry)
    fixture_record: dict = {}
    try:
        fixture_record["start"] = fixture.start()
        fixture.assert_controlled_page_marker()
        fixture_record["controlled_page_marker_verified"] = True
        baseline_state = fixture.reset()
        fixture_record["reset"] = baseline_state
        if any((baseline_state.get(key) not in (None, False, 0, [])) for key in ("selected", "clicks", "menu_open", "events")):
            raise FixtureError(
                f"/state was not clean after reset: {json.dumps(baseline_state, ensure_ascii=False)}"
            )
        fixture_record["state_clean_after_reset"] = True
        page_views_before_browser = fixture.state().get("page_views")
        fixture_record["page_views_before_browser_open"] = page_views_before_browser

        if options.mode == "full":
            try:
                environment["browser_stage"] = stage_controlled_page(fixture, page_views_before_browser)
            except (BrowserStageError, FixtureError) as error:
                environment["browser_stage"] = {"error": str(error)}
                print(f"Browser staging failed: {error}", flush=True)
        else:
            environment["browser_stage"] = {
                "skipped": True,
                "reason": "dry-run never opens a browser or touches the desktop",
            }
            environment["dry_run_boundaries"] = dry_run.describe_dry_run_boundaries()
    except FixtureError as error:
        blocked_reason = f"Controlled-page environment failed: {error}"
        print(blocked_reason, flush=True)
        fixture_record["error"] = str(error)
        environment["fixture"] = fixture_record
        for scenario in loaded_scenarios:
            scenario_results.append({
                "name": scenario.name, "title": scenario.title, "status": "blocked",
                "user_words": scenario.user_words, "model_tool_arguments": None,
                "task_turn_attempt_ids": None, "her_receipt": None,
                "independent_state": None, "final_speech": None,
                "failure_recovery": {"fault_injected": False, "recovery_evidence": None,
                                     "note": "Blocked before any scenario ran."},
                "basis": [], "failure_reasons": [str(error)], "attempts": [],
            })
        cleanup = registry.terminate_all()
        return _finish(context, options, scenario_results,
                       {"fixture": fixture_record, "cleanup": cleanup},
                       exit_code=1, blocked_reason=blocked_reason)

    # ---- scenarios ----
    try:
        for scenario in loaded_scenarios:
            try:
                scenario_results.append(
                    _run_scenario(scenario, options, context, fixture, registry, environment)
                )
            except Exception as error:  # never die without evidence
                traceback_text = traceback.format_exc(limit=4)
                print(f"Scenario {scenario.name} crashed: {error}", flush=True)
                scenario_results.append({
                    "name": scenario.name, "title": scenario.title, "status": STATUS_FAILED,
                    "user_words": scenario.user_words, "model_tool_arguments": None,
                    "task_turn_attempt_ids": None, "her_receipt": None,
                    "independent_state": None, "final_speech": None,
                    "failure_recovery": {"fault_injected": False, "recovery_evidence": None,
                                         "note": "Scenario raised instead of producing a verdict."},
                    "basis": [], "failure_reasons": [f"{error}", traceback_text],
                    "attempts": [],
                })
    finally:
        environment["fixture"] = fixture_record
        environment["fixture"]["stop"] = fixture.stop()
        environment["fixture"]["port_released_after_stop"] = not port_accepts_connections(
            paths.FIXTURE_HOST, paths.FIXTURE_PORT, timeout_seconds=2.0
        )
        environment["cleanup"] = {"terminated": registry.terminate_all()}
        environment["cleanup"]["owned_processes_remaining"] = len(registry.running())
        environment["user_her_processes"] = find_processes_matching(HER_PROCESS_PATTERN)
        environment["rerun_hygiene"] = {
            "fixture_port_free": environment["fixture"]["port_released_after_stop"],
            "no_owned_processes_remaining": environment["cleanup"]["owned_processes_remaining"] == 0,
            "fixture_state_is_in_memory": True,
            "note": ("A rerun starts the fixture fresh and resets /state; stale state cannot "
                     "survive because the fixture process itself is stopped and restarted."),
        }

    # Exit code is meaningful: 0 only when every scenario passed. A pending
    # scenario (work order not merged yet) is not a fake pass and not a runner
    # failure — it exits non-zero with the reproduction command recorded.
    statuses = [scenario["status"] for scenario in scenario_results]
    exit_code = 0 if statuses and all(status == STATUS_PASSED for status in statuses) else 1
    return _finish(context, options, scenario_results, environment, exit_code=exit_code)


def _run_scenario(scenario, options: RunOptions, context: RunContext,
                  fixture: FixtureServer, registry: OwnedProcessRegistry,
                  environment: dict) -> dict:
    attempts: list[dict] = []
    statuses: list[str] = []
    scenario_directory = _scenario_directory(context.out_dir, scenario.name)

    # Work order 04's fault probe is not in this binary yet: mark pending with the
    # exact reproduction command instead of guessing a verdict.
    capability_flag = scenario.capability_flag
    if scenario.probe_mode == "unknown" and capability_flag:
        app_binary = context.app_path / "Contents/MacOS" / (
            (context.app_identity_dict or {}).get("bundle_executable") or "Her"
        )
        if not binary_supports_flag(app_binary, capability_flag):
            pending_reason = (
                f"The app binary does not contain the {capability_flag!r} probe. Work order 04 "
                "owns the real delivery-unknown fault injection probe; it is not merged into "
                "this binary yet, so this scenario is pending-integrator-run rather than "
                "passed or failed."
            )
            print(f"[{scenario.name}] {pending_reason}", flush=True)
            return {
                "name": scenario.name, "title": scenario.title, "status": STATUS_PENDING,
                "user_words": scenario.user_words, "model_tool_arguments": None,
                "task_turn_attempt_ids": None, "her_receipt": None,
                "independent_state": None, "final_speech": None,
                "failure_recovery": {
                    "fault_injected": False, "recovery_evidence": None,
                    "note": pending_reason,
                    "rerun_hygiene": environment.get("rerun_hygiene"),
                },
                "basis": [], "failure_reasons": [],
                "attempts": [],
                "reproduction": scenario.reproduction,
                "pending_reason": pending_reason,
            }

    for run_index in range(1, scenario.repeat + 1):
        utterance_text = scenario.utterances[(run_index - 1) % len(scenario.utterances)]
        cache_dir = context.out_dir / "utterances"
        if scenario.probe_mode == "voice_continuity":
            # The continuity probe runs two utterances (progress, then cancel);
            # both are synthesized and recorded as the scenario's user words.
            utterance_records: list[dict] = []
            pcm_paths: list[Path | None] = []
            for text in scenario.utterances[:2]:
                record, pcm_path = _synthesize_or_placeholder(text, cache_dir, options.mode)
                utterance_records.append(record)
                pcm_paths.append(pcm_path)
            utterance_record = {"utterances": utterance_records,
                                "primary_text": scenario.utterances[0]}
            pcm_path = pcm_paths[0]
        else:
            utterance_record, pcm_path = _synthesize_or_placeholder(
                utterance_text, cache_dir, options.mode
            )
            pcm_paths = [pcm_path] if pcm_path else []
        attempt_directory = scenario_directory / f"run-{run_index}"
        attempt_directory.mkdir(parents=True, exist_ok=True)

        if options.mode == "dry_run":
            quality = (dry_run.BAD_CHAIN_SUFFIX + "_"
                       + _bad_chain_flavor(scenario)) if options.dry_run_failure_injection else dry_run.GOOD_CHAIN_SUFFIX
            try:
                chain = dry_run.load_dry_run_chain(scenario, quality)
            except dry_run.DryRunChainError as error:
                raise RunAborted(str(error)) from error
            probe_record = dry_run.build_dry_run_probe_record(chain, attempt_directory)
            probe_report = chain.report
            state_before, state_after = dry_run.clone_chain_state(chain)
            mock = True
            # Dry-run still exercises the real fixture reset mechanics.
            fixture.reset()
        else:
            if pcm_path is None:
                raise RunAborted("No utterance PCM was synthesized for a full run.")
            request = ProbeRequest(
                mode=scenario.probe_mode,
                app_binary=context.app_path / "Contents/MacOS" / (
                    (context.app_identity_dict or {}).get("bundle_executable") or "Her"
                ),
                working_out_dir=attempt_directory,
                expected_bundle_identifier=scenario.expected_bundle_identifier,
                utterance_pcm_paths=(
                    list(pcm_paths) if scenario.probe_mode == "voice_continuity" else [pcm_path]
                ),
                report_file_name=scenario.report_file_name,
                unknown_argv_template=(options.unknown_probe_argv_template
                                       or scenario.unknown_argv_template),
            )
            # Scenario independence: reset the fixture and reload the page so the
            # visible controlled page matches the server-side /state the probe
            # is about to mutate. (Safari is reloaded with LaunchServices only;
            # AppleScript automation would intercept real mouse events.)
            fixture.reset()
            browser_stage.reload_controlled_page(fixture, fixture.state().get("page_views"))
            state_before = _snapshot(fixture)
            probe_result = run_probe(request, registry,
                                     timeout_seconds=options.probe_timeout_seconds)
            probe_record = probe_result.to_dict()
            probe_report = probe_result.report
            state_after = _snapshot(fixture)
            mock = False
            if isinstance(probe_report, dict):
                if probe_report.get("provider_connection_attempted"):
                    context.provider_connection_attempted = True
                if scenario.probe_mode == "voice_task" and probe_report.get("calls"):
                    context.provider_connection_attempted = True

        verdict = judge_scenario(
            scenario,
            probe_record,
            probe_report,
            state_before,
            state_after,
            require_evidence_language=options.require_evidence_language,
        )
        attempts.append(_attempt_scenario_evidence(
            scenario, verdict, utterance_record, probe_record, probe_report,
            state_before, state_after,
            cleanup_record={"owned_processes_remaining": 0, "note": "recorded at run end"},
            mock=mock,
        ))
        statuses.append(verdict.status)
        print(f"[{scenario.name}] run {run_index}/{scenario.repeat}: {verdict.status}", flush=True)
        for reason in verdict.failure_reasons:
            print(f"    reason: {reason}", flush=True)

    overall_status = STATUS_PASSED if all(status == STATUS_PASSED for status in statuses) else (
        STATUS_PENDING if all(status == STATUS_PENDING for status in statuses) else STATUS_FAILED
    )
    last_verdict = attempts[-1]["verdict"] if attempts else {}
    return {
        "name": scenario.name,
        "title": scenario.title,
        "status": overall_status,
        "user_words": scenario.user_words,
        "model_tool_arguments": last_verdict.get("evidence", {}).get("model_tool_arguments"),
        "task_turn_attempt_ids": last_verdict.get("evidence", {}).get("task_turn_attempt_ids"),
        "her_receipt": last_verdict.get("evidence", {}).get("her_receipt"),
        "independent_state": last_verdict.get("evidence", {}).get("independent_state"),
        "final_speech": last_verdict.get("evidence", {}).get("final_speech"),
        "failure_recovery": _failure_recovery_record(
            scenario, overall_status,
            last_verdict.get("evidence", {}) if last_verdict else {},
            {"note": "recorded at run end"}, environment.get("rerun_hygiene", {}),
        ),
        "basis": last_verdict.get("basis", []),
        "failure_reasons": _merged_failure_reasons(attempts),
        "attempts": attempts,
        "reproduction": scenario.reproduction,
        "repeat": scenario.repeat,
    }


def _bad_chain_flavor(scenario) -> str:
    flavors = {
        "single_step_right_setting": "double_click",
        "two_step_display_settings_scale": "open_app",
        "continuity_progress_cancel": "reexecute",
        "unknown_delivery_fault_recovery": "reclick",
    }
    return flavors.get(scenario.name, "")


def _snapshot(fixture: FixtureServer) -> dict:
    state = fixture.state()
    state["captured_at"] = _utc_now_iso()
    return state


def _merged_failure_reasons(attempts: list[dict]) -> list[str]:
    reasons: list[str] = []
    for index, attempt in enumerate(attempts, start=1):
        for reason in attempt.get("verdict", {}).get("failure_reasons", []):
            reasons.append(f"run {index}: {reason}")
    return reasons


def _finish(context: RunContext, options: RunOptions, scenario_results: list[dict],
            environment: dict, exit_code: int, blocked_reason: str | None = None) -> int:
    context.finished_at_iso = _utc_now_iso()
    result = evidence.build_result_document(
        context, scenario_results, environment, exit_code, blocked_reason=blocked_reason
    )
    problems = evidence.validate_result_schema(result)
    if problems:
        for problem in problems:
            print(f"result.json schema problem: {problem}", flush=True)
    commands = evidence.render_commands_document(
        context,
        scenario_results,
        _readme_sections(options),
        scenario_objects=scenario_defs.load_scenarios(
            selected_names=options.selected_scenarios,
            repeat_overrides=options.repeat_overrides or None,
        ),
    )
    readme = _render_run_readme(context, result, options)
    written = evidence.write_evidence_package(context.out_dir, result,
                                              context.app_identity_dict or {},
                                              commands, readme)
    secret_hits: list[str] = []
    for path in written:
        secret_hits.extend(evidence.scan_file_for_secrets(path))
    if secret_hits:
        result["secret_scan_findings"] = secret_hits
        evidence.write_json(context.out_dir / "result.json", result)
        print(f"SECRET SCAN FINDINGS (investigate immediately): {secret_hits}", flush=True)
    print("", flush=True)
    print("Scenario summary:", flush=True)
    for scenario in scenario_results:
        print(f"  {scenario['status']:>24}  {scenario['name']}", flush=True)
        for reason in scenario.get("failure_reasons", [])[:5]:
            print(f"      - {reason}", flush=True)
    print(f"Evidence package: {context.out_dir}", flush=True)
    print(f"passed={result['passed']} exit_code={exit_code} mode={context.mode} "
          f"proof={result['proof']}", flush=True)
    return exit_code


def _readme_sections(options: RunOptions) -> list[str]:
    return [
        "## Phases the integrator runs\n\n"
        "1. Rebuild the DEBUG app in Xcode (never xcodebuild from a terminal).\n"
        "2. Open Her once and enter the StepFun key in Settings → Models so the app's own\n"
        "   Keychain item is readable non-interactively.\n"
        "3. Close any browser automation that might hold 127.0.0.1:19475.\n"
        "4. Run the one command above from the repository root.",
        "## What the runner refuses to do\n\n"
        "- It never builds, installs, replaces or kills the user's Her (probe processes are\n"
        "  separate children that exit by themselves).\n"
        "- It never opens the microphone, plays audio, exports keys, or records screenshots.\n"
        "- It only ever opens http://127.0.0.1:19475 in Safari, and it never automates Safari.\n"
        "- It treats a non-zero exit code, a `completed` tool return, model prose or any page\n"
        "  change as insufficient on their own: every PASS cites six evidence layers.",
    ]


def _render_run_readme(context: RunContext, result: dict, options: RunOptions) -> str:
    lines = [
        f"# Her E2E acceptance evidence — {paths.WORK_ORDER_ID}",
        "",
        f"- Mode: **{context.mode}** (proof={result['proof']})",
        f"- Commit: {result.get('commit')} (branch {result.get('branch')})",
        f"- Started: {context.started_at_iso}",
        f"- Finished: {context.finished_at_iso}",
        f"- Entrypoint: `{context.entrypoint}`",
        "",
        "## Scenario verdicts",
        "",
        "| Scenario | Status |",
        "| --- | --- |",
    ]
    for scenario in result["scenarios"]:
        lines.append(f"| {scenario['title']} | {scenario['status']} |")
    lines += [
        "",
        "## Execution record for this package",
        "",
    ]
    summary = result["summary"]
    executed = [name for name, status in summary["scenario_statuses"].items()
                if status not in ("pending_integrator_run", "blocked")]
    blocked = [name for name, status in summary["scenario_statuses"].items() if status == "blocked"]
    pending = summary["pending_integrator_run"]
    lines.append(f"- Executed scenarios: {len(executed)}"
                 + (f" ({', '.join(executed)})" if executed else ""))
    if blocked:
        lines.append(f"- Blocked by preflight (nothing was executed): {', '.join(blocked)}")
    if pending:
        lines.append(f"- Pending integrator run (owning work order not merged): {', '.join(pending)}")
    if result.get("blocked_reason"):
        lines.append(f"- Blocking reason: {result['blocked_reason']}")
    if context.mode == "dry_run":
        lines.append("- This package proves the runner pipeline only; the app, the provider and")
        lines.append("  the desktop were never exercised.")
    if context.mode == "full" and not result["proof"] and executed:
        lines.append("- A full-mode run that did not pass every scenario is not acceptance proof;")
        lines.append("  the scenarios that did run are each backed by their six-layer evidence.")
    lines += [
        "",
        "## How to read this package",
        "",
        "- `result.json` — the machine-readable evidence: per-scenario six-layer comparison",
        "  (user words, raw model tool arguments, Her receipt with task/turn/attempt IDs,",
        "  independent /state before/after, final speech, process exit and cleanup).",
        "- `app-identity.json` — bundle/team/signature, binary-vs-source freshness, and",
        "  Keychain presence statuses (never secrets).",
        "- `commands.txt` — the exact one-command entrypoint and per-scenario reproduction.",
        "- `scenario-artifacts/` — the probe reports and logs this verdict was derived from.",
        "",
        "## Rerun",
        "",
        "```bash",
        context.entrypoint,
        "```",
        "",
        "The same command reruns everything: it rebuilds nothing, starts its own fixture,",
        "resets /state, and stops everything it started. Dry-run artifacts are never proof;",
        "a full-mode run against a rebuilt DEBUG app is the only acceptance evidence.",
        "",
    ]
    if context.mode == "dry_run":
        lines += [
            "## Dry-run notice",
            "",
            "This package was produced in dry-run mode: the app/provider/desktop phases were",
            "replaced by a runner-level mock. It proves the runner pipeline only. The real",
            "acceptance run (integrator, Xcode-rebuilt app) is pending.",
            "",
        ]
    return "\n".join(lines)

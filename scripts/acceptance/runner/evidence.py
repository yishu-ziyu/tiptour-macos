"""Evidence package writers, schema validation and secret hygiene.

The evidence package is the only deliverable that counts: result.json,
commands.txt, app-identity.json and README.md under
out/acceptance/03-her-e2e-runner/. Everything written here is checked against
a schema (validators used by the self-tests) and scanned so no key, no private
audio and no screenshot can silently enter the package.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from . import paths
from .app_identity import git_branch, git_commit

SCHEMA_VERSION = 1

# Shapes that would indicate a leaked credential if they ever appeared in the
# evidence. The runner records presence booleans only, so any hit is a bug.
SECRET_PATTERNS = (
    re.compile(r"sk-[A-Za-z0-9]{16,}"),
    re.compile(r"AKIA[0-9A-Z]{12,}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"(?i)api[_-]?key\"?\s*[:=]\s*\"[A-Za-z0-9_\-]{16,}"),
)

REQUIRED_RESULT_KEYS = (
    "work_order", "commit", "branch", "app_bundle", "bundle_id", "team_id",
    "entrypoint", "provider_connection_attempted", "synthetic_audio",
    "microphone_opened", "desktop_fixture_only", "mode", "proof",
    "scenarios", "passed", "exit_code", "schema_version",
)

REQUIRED_SCENARIO_KEYS = (
    "name", "title", "status", "user_words", "model_tool_arguments",
    "task_turn_attempt_ids", "her_receipt", "independent_state",
    "final_speech", "failure_recovery", "basis", "failure_reasons", "attempts",
)


class EvidenceError(RuntimeError):
    pass


def scan_for_secret_patterns(text: str) -> list[str]:
    hits: list[str] = []
    for pattern in SECRET_PATTERNS:
        for match in pattern.findall(text):
            hits.append(match if isinstance(match, str) else str(match))
    return hits


def scan_file_for_secrets(path: Path) -> list[str]:
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return scan_for_secret_patterns(content)


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def validate_result_schema(result: dict) -> list[str]:
    """Structural validation; also used by the self-tests on synthetic artifacts."""
    problems: list[str] = []
    for key in REQUIRED_RESULT_KEYS:
        if key not in result:
            problems.append(f"result.json is missing {key!r}.")
    if not isinstance(result.get("scenarios"), list):
        problems.append("result.json 'scenarios' must be a list.")
        return problems
    for index, scenario in enumerate(result["scenarios"]):
        if not isinstance(scenario, dict):
            problems.append(f"scenario #{index} is not an object.")
            continue
        for key in REQUIRED_SCENARIO_KEYS:
            if key not in scenario:
                problems.append(f"scenario {scenario.get('name', index)!r} is missing {key!r}.")
        status = scenario.get("status")
        if status not in ("passed", "failed", "pending_integrator_run", "blocked"):
            problems.append(f"scenario {scenario.get('name', index)!r} has unknown status {status!r}.")
        if status == "passed" and not scenario.get("basis"):
            problems.append(f"scenario {scenario.get('name', index)!r} passes without basis strings.")
        if status == "failed" and not scenario.get("failure_reasons"):
            problems.append(f"scenario {scenario.get('name', index)!r} fails without reasons.")
    if not isinstance(result.get("passed"), bool):
        problems.append("result.json 'passed' must be a boolean.")
    if not isinstance(result.get("exit_code"), int):
        problems.append("result.json 'exit_code' must be an integer.")
    if result.get("mode") not in ("full", "dry_run", "self_test"):
        problems.append("result.json 'mode' must be full, dry_run or self_test.")
    if not isinstance(result.get("proof"), bool):
        problems.append("result.json 'proof' must be a boolean.")
    if result.get("mode") == "dry_run" and result.get("proof"):
        problems.append("a dry-run result must never be marked as proof.")
    return problems


def build_result_document(
    context,
    scenarios: list[dict],
    environment: dict,
    exit_code: int,
    blocked_reason: str | None = None,
) -> dict:
    statuses = [scenario["status"] for scenario in scenarios]
    pending = [scenario["name"] for scenario in scenarios
               if scenario["status"] == "pending_integrator_run"]
    failed = [scenario["name"] for scenario in scenarios
              if scenario["status"] in ("failed", "blocked")]
    executed = [status for status in statuses if status not in ("pending_integrator_run", "blocked")]
    passed = bool(executed) and not failed and not pending
    # Proof means real product acceptance evidence: a full run that actually
    # executed scenarios. A blocked or dry-run package is never proof.
    is_proof = (context.mode == "full" and blocked_reason is None
                and bool(executed) and not failed and not pending)
    result = {
        "schema_version": SCHEMA_VERSION,
        "work_order": paths.WORK_ORDER_ID,
        "commit": git_commit(),
        "branch": git_branch(),
        "app_bundle": paths.EXPECTED_APP_BUNDLE_NAME,
        "bundle_id": paths.EXPECTED_BUNDLE_IDENTIFIER,
        "team_id": paths.EXPECTED_TEAM_IDENTIFIER,
        "entrypoint": context.entrypoint,
        "provider_connection_attempted": context.provider_connection_attempted,
        "synthetic_audio": True,
        "microphone_opened": False,
        "desktop_fixture_only": True,
        "mode": context.mode,
        # Dry-run artifacts are pipeline proofs, never product acceptance.
        "proof": is_proof,
        "started_at": context.started_at_iso,
        "finished_at": context.finished_at_iso,
        "app_identity": context.app_identity_dict,
        "environment": environment,
        "scenarios": scenarios,
        "summary": {
            "scenario_statuses": {scenario["name"]: scenario["status"] for scenario in scenarios},
            "pending_integrator_run": pending,
            "failed": failed,
        },
        "passed": passed,
        "exit_code": exit_code,
        "blocked_reason": blocked_reason,
    }
    return result


def build_app_identity_document(context, identity_dict: dict) -> dict:
    return {
        "schema_version": SCHEMA_VERSION,
        "work_order": paths.WORK_ORDER_ID,
        "commit": git_commit(),
        "branch": git_branch(),
        "captured_at": context.finished_at_iso or context.started_at_iso,
        "mode": context.mode,
        "identity": identity_dict,
        "privacy_notes": [
            "Keychain checks record presence and OS status codes only; secrets are never read, printed or stored.",
            "No private audio, screenshots, or API keys are part of this package.",
            "Synthetic PCM metadata is recorded; the samples themselves are not copied into evidence.",
        ],
    }


def expected_probe_command_text(scenario) -> list[str]:
    """The exact probe command a full run will execute for this scenario."""
    binary = "Her.app/Contents/MacOS/Her"
    mode = scenario.probe_mode
    if mode == "voice_task":
        return [binary, "--voice-task-probe", scenario.expected_bundle_identifier,
                "<synthesized-utterance.pcm>", "<attempt-dir>"]
    if mode == "voice_continuity":
        return [binary, "--voice-continuity-probe", "<progress-utterance.pcm>",
                "<cancel-utterance.pcm>", f"<attempt-dir>/{scenario.report_file_name}"]
    if mode == "desktop_task":
        return [binary, "--desktop-task-probe", scenario.expected_bundle_identifier,
                "<tool-arguments.json>", f"<attempt-dir>/{scenario.report_file_name}"]
    if mode == "voice_route":
        return [binary, "--voice-route-probe", "<synthesized-utterance.pcm>", "<attempt-dir>"]
    if mode == "jev_fanout":
        return [binary, "--jev-fanout-probe", scenario.expected_bundle_identifier,
                "<goal-text>", f"<attempt-dir>/{scenario.report_file_name}"]
    template = scenario.unknown_argv_template or ["<configure --unknown-probe-argv after the owning work order merges>"]
    return [token.replace("{app_binary}", binary) for token in template]


def render_commands_document(context, scenarios: list[dict], extra_sections: list[str],
                             scenario_objects=None) -> str:
    lines: list[str] = []
    lines.append("# Her E2E acceptance runner — exact commands")
    lines.append("")
    lines.append(f"Commit: {git_commit() or 'unknown'}")
    lines.append(f"Branch: {git_branch() or 'unknown'}")
    lines.append(f"Work order: {paths.WORK_ORDER_ID}")
    lines.append("")
    lines.append("## One command (full acceptance run)")
    lines.append("")
    lines.append("```bash")
    lines.append(context.entrypoint)
    lines.append("```")
    lines.append("")
    lines.append("This single command: verifies the signed DEBUG Her.app identity and")
    lines.append("freshness, checks Keychain presence, starts the disposable fixture,")
    lines.append("resets /state, opens the controlled page in Safari, runs every scenario")
    lines.append("through the real app probes, compares six-layer evidence, cleans up the")
    lines.append("probe processes and the fixture, and writes this evidence package.")
    lines.append("")
    lines.append("## Integrator rerun on the integration branch (after 01/02/04 merge)")
    lines.append("")
    lines.append("```bash")
    lines.append(context.entrypoint)
    lines.append("```")
    lines.append("")
    lines.append("Identical command: rebuild the DEBUG app in Xcode from the integration")
    lines.append("branch, then rerun. No runner edits are required; the runner re-derives")
    lines.append("everything from the app bundle and the fixture.")
    lines.append("")
    lines.append("## Scenario reproduction")
    lines.append("")
    for scenario in scenarios:
        lines.append(f"### {scenario['title']} — {scenario['status']}")
        lines.append("")
        has_attempt_argv = any(attempt.get("argv") for attempt in scenario.get("attempts", []))
        for attempt in scenario.get("attempts", []):
            if attempt.get("argv"):
                lines.append("```bash")
                lines.append(" ".join(attempt["argv"]))
                lines.append("```")
        if not has_attempt_argv and scenario_objects:
            definition = next(
                (item for item in scenario_objects if item.name == scenario["name"]), None
            )
            if definition is not None:
                lines.append("The full run executes (paths are runner-resolved):")
                lines.append("")
                lines.append("```bash")
                lines.append(" ".join(expected_probe_command_text(definition)))
                lines.append("```")
        reproduction = scenario.get("reproduction")
        if reproduction and scenario["status"] == "pending_integrator_run":
            lines.append("Pending until the owning work order merges. Prerequisites:")
            for prerequisite in reproduction.get("prerequisites", []):
                lines.append(f"- {prerequisite}")
        lines.append("")
    for section in extra_sections:
        lines.append(section)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def write_evidence_package(out_dir: Path, result: dict, app_identity: dict,
                           commands: str, readme: str) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    written = [
        out_dir / "result.json",
        out_dir / "app-identity.json",
        out_dir / "commands.txt",
        out_dir / "README.md",
    ]
    write_json(written[0], result)
    write_json(written[1], app_identity)
    written[2].write_text(commands, encoding="utf-8")
    written[3].write_text(readme, encoding="utf-8")
    return written
#!/usr/bin/env python3
"""Guided manual acceptance runner: the human does the UI, the machine verifies.

    python3 scripts/acceptance/manual_runner.py <protocol.json> <out_dir>

Some acceptance scenarios are inherently human-in-the-loop (set Her's display
scale, press Save, let Her refuse the Keychain read, restore, retry). A person
cannot be an evidence source for the *outcome* of such a step: they narrate what
they saw. This runner keeps the two roles strictly apart:

  1. it prints one step instruction at a time and waits for Enter, and
  2. only after the human confirms does it run a *machine* verification -
     a read-only `security` exit code, a `GET /state` over loopback HTTP, a
     `ps` listing, or a filesystem check - and records that result next to the
     confirmation.

Nothing here ever clicks, types, presses a key, moves the pointer, or opens
anything. The record carries an explicit `ui_actions_performed: []` so a reader
can see the absence instead of trusting a comment. The human's confirmation is
recorded as a *claim* (`confirmed_by_user`) and the machine's verification as an
independent fact (`verification`); they are never merged.

Protocol schema (JSON):

    {
      "scenario": "settings save -> keychain refusal -> restore -> retry",
      "steps": [
        {
          "id": "set-display-scale",                  // optional, for cross-referencing
          "instruction": "在 Her 中把显示缩放调到 125% 并点“保存”",
          "optional": false,                          // optional steps may be skipped
          "verify": {
            "kind": "http_state",                     // keychain_item | http_state |
                                                      // process_record | file_exists
            "params": {"base_url": "http://127.0.0.1:19475", "path": "/state"},
            "expect": "pass"                          // "fail" for a negative check,
                                                      // e.g. the keychain item must be gone
          }
        }
      ]
    }
Every step needs `instruction`; `verify` may be omitted (pure guidance). `expect`
defaults to "pass"; "fail" turns the step into a negative check whose success is
a verification that reports *not* ok (absence of a keychain item, absence of a
process). The record is written to `<out_dir>/manual-<UTC ts>/record.json`.

Exit codes: 0 all good, 2 usage/protocol error, 3 a required verification
failed, 4 the human aborted, 5 a required verification was undetermined.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

SCHEMA_VERSION = 1
RECORD_SCHEMA_VERSION = 1

# Mirrors scripts/acceptance/runner/paths.py (FIXTURE_URL) without importing the
# runner package, so this script stays a standalone, dependency-free CLI.
DEFAULT_STATE_BASE_URL = "http://127.0.0.1:19475"
DEFAULT_STATE_PATH = "/state"

# Read-only helper commands only. None of these can change state.
KEYCHAIN_COMMAND_TIMEOUT_SECONDS = 15.0
HTTP_TIMEOUT_SECONDS = 10.0
PS_COMMAND_TIMEOUT_SECONDS = 15.0
PS_OUTPUT_LIMIT = 4000
PS_COMMAND_LIMIT = 200
PS_MATCH_LIMIT = 50
FILE_READ_LIMIT = 65536

VERIFY_KINDS = ("keychain_item", "http_state", "process_record", "file_exists")

SECURITY_ITEM_NOT_FOUND_EXIT_CODE = 44  # errSecItemNotFound

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_VERIFICATION_FAILED = 3
EXIT_ABORTED = 4
EXIT_VERIFICATION_UNDETERMINED = 5

PROMPT_HINT = ("  → 完成后按回车确认；可选步骤可输入 skip 跳过；输入 q 中止"
               "   (Enter = done, skip = optional only, q = abort)")


class ProtocolError(ValueError):
    """The protocol file is not something this runner may execute."""


class HumanAbort(RuntimeError):
    """The human chose to stop; the partial record is still written."""


# --------------------------------------------------------------------- protocol


def load_protocol(path: Path) -> dict:
    """Read and validate a protocol file. Returns the parsed protocol."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ProtocolError(f"cannot read protocol {path}: {error}") from error
    try:
        protocol = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ProtocolError(f"protocol {path} is not valid JSON: {error}") from error
    if not isinstance(protocol, dict):
        raise ProtocolError("protocol must be a JSON object")
    steps = protocol.get("steps")
    if not isinstance(steps, list) or not steps:
        raise ProtocolError("protocol needs a non-empty 'steps' array")
    validated: list[dict] = []
    for index, step in enumerate(steps, start=1):
        if not isinstance(step, dict):
            raise ProtocolError(f"step {index} must be an object")
        instruction = step.get("instruction")
        if not isinstance(instruction, str) or not instruction.strip():
            raise ProtocolError(f"step {index} needs a non-empty 'instruction' string")
        optional = step.get("optional", False)
        if not isinstance(optional, bool):
            raise ProtocolError(f"step {index} 'optional' must be a boolean")
        verify = step.get("verify")
        if verify is not None:
            if not isinstance(verify, dict):
                raise ProtocolError(f"step {index} 'verify' must be an object")
            kind = verify.get("kind")
            if kind not in VERIFY_KINDS:
                raise ProtocolError(
                    f"step {index} verify kind must be one of {list(VERIFY_KINDS)}, got {kind!r}"
                )
            params = verify.get("params", {})
            if not isinstance(params, dict):
                raise ProtocolError(f"step {index} verify 'params' must be an object")
            _validate_verify_params(kind, params, index)
        validated.append({
            "index": index,
            "id": step.get("id") if isinstance(step.get("id"), str) else None,
            "instruction": instruction,
            "optional": optional,
            "verify": verify,
        })
    return {
        "schema_version": SCHEMA_VERSION,
        "scenario": protocol.get("scenario") if isinstance(protocol.get("scenario"), str) else None,
        "steps": validated,
    }


def _require(params: dict, key: str, kind: str) -> str:
    value = params.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ProtocolError(f"verify '{kind}' needs a non-empty '{key}' string")
    return value


def _validate_verify_params(kind: str, params: dict, index: int) -> None:
    if kind == "keychain_item":
        _require(params, "service", kind)
    elif kind == "http_state":
        base_url = params.get("base_url", DEFAULT_STATE_BASE_URL)
        if not isinstance(base_url, str) or not base_url.startswith("http"):
            raise ProtocolError(f"step {index} verify 'http_state' base_url must be an http(s) URL")
        path = params.get("path", DEFAULT_STATE_PATH)
        if not isinstance(path, str) or not path.startswith("/"):
            raise ProtocolError(f"step {index} verify 'http_state' path must start with '/'")
    elif kind == "process_record":
        _require(params, "pattern", kind)
        expect = params.get("expect", "present")
        if expect not in ("present", "absent"):
            raise ProtocolError(f"step {index} verify 'process_record' expect must be present|absent")
    elif kind == "file_exists":
        _require(params, "path", kind)


# ----------------------------------------------------------------- verifications


def verify_keychain_item(params: dict) -> dict:
    """Read-only generic-password lookup; only the exit code is recorded.

    `security find-generic-password` prints the secret to stdout. That stdout is
    discarded here: the record keeps the exit code (0 = present and readable,
    44 = errSecItemNotFound) and a classification, never the secret and never
    stderr text that could carry one.
    """
    argv = ["security", "find-generic-password",
            "-s", _require(params, "service", "keychain_item"),
            "-a", str(params.get("account") or "")]
    service = _require(params, "service", "keychain_item")
    result = {"kind": "keychain_item", "service": service,
              "account": params.get("account") if isinstance(params.get("account"), str) else None,
              "exit_code": None, "ok": None,
              "classification": "not_run", "summary": "", "recorded_at": _now_iso()}
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, check=False,
                                   timeout=KEYCHAIN_COMMAND_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        result["classification"] = "timeout"
        result["summary"] = "security did not answer in time"
        return result
    except OSError as error:
        result["classification"] = "command_unavailable"
        result["summary"] = f"security could not be run: {error}"
        return result
    result["exit_code"] = completed.returncode
    if completed.returncode == 0:
        result["ok"] = True
        result["classification"] = "present_and_readable"
        result["summary"] = "generic-password item was found (exit 0)"
    elif completed.returncode == SECURITY_ITEM_NOT_FOUND_EXIT_CODE:
        result["ok"] = False
        result["classification"] = "item_not_found"
        result["summary"] = "generic-password item does not exist (exit 44)"
    else:
        result["classification"] = "undetermined_exit_code"
        result["summary"] = f"security exited {completed.returncode}; presence not classified"
    return result


def verify_http_state(params: dict) -> dict:
    """Independent GET /state over loopback HTTP; the machine's own readback."""
    base_url = params.get("base_url", DEFAULT_STATE_BASE_URL).rstrip("/")
    path = params.get("path", DEFAULT_STATE_PATH)
    timeout = float(params.get("timeout_seconds", HTTP_TIMEOUT_SECONDS))
    result = {"kind": "http_state", "base_url": base_url, "path": path,
              "status_code": None, "ok": None, "summary": "",
              "body": None, "recorded_at": _now_iso()}
    url = base_url + path
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read()
            result["status_code"] = response.status
    except urllib.error.HTTPError as error:
        result["status_code"] = error.code
        result["ok"] = False
        result["summary"] = f"GET {path} answered {error.code}"
        return result
    except (urllib.error.URLError, OSError) as error:
        result["ok"] = None
        result["classification"] = "unreachable"
        result["summary"] = f"GET {path} failed: {error}"
        return result
    try:
        body = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        result["ok"] = False
        result["summary"] = f"GET {path} returned non-JSON: {error}"
        return result
    result["body"] = body if isinstance(body, (dict, list)) else {"value": body}
    result["ok"] = True
    result["summary"] = f"GET {path} answered 200 with JSON state"
    return result


def verify_process_record(params: dict) -> dict:
    """Read-only `ps` listing filtered by pattern. Never signals anything."""
    pattern = _require(params, "pattern", "process_record")
    expect = params.get("expect", "present")
    result = {"kind": "process_record", "pattern": pattern, "expect": expect,
              "ps_exit_code": None, "matches": [], "match_count": 0,
              "ok": None, "summary": "", "recorded_at": _now_iso()}
    try:
        completed = subprocess.run(["ps", "ax", "-o", "pid=,command="],
                                   capture_output=True, text=True, check=False,
                                   timeout=PS_COMMAND_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        result["ok"] = None
        result["classification"] = "timeout"
        result["summary"] = "ps did not answer in time"
        return result
    except OSError as error:
        result["ok"] = None
        result["classification"] = "command_unavailable"
        result["summary"] = f"ps could not be run: {error}"
        return result
    result["ps_exit_code"] = completed.returncode
    matches: list[dict] = []
    for line in completed.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        if pattern not in command:
            continue
        matches.append({"pid": int(pid_text) if pid_text.isdigit() else None,
                        "command": command[:PS_COMMAND_LIMIT]})
        if len(matches) >= PS_MATCH_LIMIT:
            break
    result["matches"] = matches
    result["match_count"] = len(matches)
    found = bool(matches)
    result["ok"] = found if expect == "present" else not found
    if expect == "present":
        result["summary"] = (f"{len(matches)} process record(s) match {pattern!r}"
                             if found else f"no process matches {pattern!r}")
    else:
        result["summary"] = (f"no process matches {pattern!r} as expected"
                             if result["ok"] else f"{len(matches)} process(es) still match {pattern!r}")
    return result


def verify_file_exists(params: dict) -> dict:
    """Filesystem check; optional substring marker inside a bounded read."""
    path_text = _require(params, "path", "file_exists")
    marker = params.get("marker") if isinstance(params.get("marker"), str) else None
    result = {"kind": "file_exists", "path": path_text, "exists": False,
              "marker": marker, "marker_found": None, "size_bytes": None,
              "ok": None, "summary": "", "recorded_at": _now_iso()}
    path = Path(path_text).expanduser()
    try:
        stat = path.stat()
    except OSError as error:
        result["ok"] = False
        result["summary"] = f"{path_text} is not readable: {error.__class__.__name__}"
        return result
    result["exists"] = True
    result["size_bytes"] = stat.st_size
    if path.is_file() and marker:
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                head = handle.read(FILE_READ_LIMIT)
        except OSError as error:
            result["ok"] = None
            result["classification"] = "unreadable_content"
            result["summary"] = f"{path_text} exists but could not be read: {error}"
            return result
        result["marker_found"] = marker in head
        result["ok"] = bool(result["marker_found"])
        result["summary"] = (f"{path_text} exists and contains the marker"
                             if result["ok"] else f"{path_text} exists but lacks the marker")
        return result
    result["ok"] = True
    result["summary"] = f"{path_text} exists ({stat.st_size} bytes)"
    return result


VERIFIERS = {
    "keychain_item": verify_keychain_item,
    "http_state": verify_http_state,
    "process_record": verify_process_record,
    "file_exists": verify_file_exists,
}


def run_verification(step: dict) -> dict:
    verify = step.get("verify")
    if not verify:
        return {"kind": None, "ok": None, "classification": "no_verification",
                "expected": None, "matched": None,
                "summary": "step carries no verify block", "recorded_at": _now_iso()}
    result = VERIFIERS[verify["kind"]](verify.get("params", {}))
    # A negative check ("the keychain item must NOT be there") is an expectation,
    # not a failure: the record says which of the two the step wanted.
    expected = "fail" if verify.get("expect") in ("fail", "absent", "false") else "pass"
    result["expected"] = expected
    if result.get("ok") is None:
        result["matched"] = None
    elif result["ok"] is True:
        result["matched"] = expected == "pass"
    else:
        result["matched"] = expected == "fail"
    outcome = ("as expected" if result["matched"] else
               "NOT as expected" if result["matched"] is False else "undetermined")
    result["summary"] = f"[expected {expected}, {outcome}] {result.get('summary', '')}".strip()
    return result


# ------------------------------------------------------------------ human loop


def _now_iso() -> str:
    return datetime.datetime.now(datetime.UTC).isoformat()


def _confirm(step: dict, total: int) -> tuple[str, str]:
    """Ask the human to confirm one step. Returns (outcome, confirmation_source)."""
    source = "tty-enter" if sys.stdin.isatty() else "piped-enter"
    label = f"step {step['index']}/{total}" + (f" [{step['id']}]" if step["id"] else "")
    optional = " (optional)" if step["optional"] else ""
    print("", flush=True)
    print(f"── {label}{optional} ──────────────────────────────────────────", flush=True)
    print(f"请按下面的说明在 Her 中操作（本 runner 不会点击、输入或打开任何界面）:", flush=True)
    print(f"  {step['instruction']}", flush=True)
    verify = step.get("verify")
    if verify:
        print(f"  确认后由机器独立验证: kind={verify['kind']} params={json.dumps(verify.get('params', {}), ensure_ascii=False)}",
              flush=True)
    while True:
        try:
            answer = input(PROMPT_HINT + "\n  > ").strip().lower()
        except EOFError as error:
            raise HumanAbort("stdin closed at the confirmation prompt") from error
        except KeyboardInterrupt as error:
            raise HumanAbort("interrupted at the confirmation prompt") from error
        if answer in ("q", "quit", "abort"):
            raise HumanAbort("the human chose to abort")
        if answer in ("s", "skip", "跳过"):
            if step["optional"]:
                return "skipped", source
            print("  该步骤不是可选步骤，不能跳过。完成后按回车，或输入 q 中止。", flush=True)
            continue
        if answer in ("", "ok", "y", "yes", "done", "完成"):
            return "confirmed", source
        print("  无法识别的输入：回车 = 已完成，skip = 跳过（仅可选步骤），q = 中止。", flush=True)


# ------------------------------------------------------------------------ main


def run(protocol_path: Path, out_dir: Path) -> tuple[int, dict]:
    protocol = load_protocol(protocol_path)
    raw_bytes = protocol_path.read_bytes()
    started_at = _now_iso()
    stamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ")
    record_dir = out_dir / f"manual-{stamp}"
    record_dir.mkdir(parents=True, exist_ok=False)
    record_path = record_dir / "record.json"

    steps_total = len(protocol["steps"])
    print("=" * 72, flush=True)
    print("Guided manual acceptance runner (no UI automation of any kind)", flush=True)
    print(f"protocol : {protocol_path}  sha256={hashlib.sha256(raw_bytes).hexdigest()[:16]}", flush=True)
    print(f"scenario : {protocol.get('scenario') or '(unnamed)'}", flush=True)
    print(f"steps    : {steps_total}   record -> {record_path}", flush=True)
    print("=" * 72, flush=True)

    records: list[dict] = []
    aborted: dict | None = None
    try:
        for step in protocol["steps"]:
            outcome, source = _confirm(step, steps_total)
            entry = {
                "step": step["index"],
                "id": step["id"],
                "instruction": step["instruction"],
                "optional": step["optional"],
                "verify_kind": (step.get("verify") or {}).get("kind"),
                "confirmed_by_user": outcome == "confirmed",
                "skipped_by_user": outcome == "skipped",
                "confirmation_source": source,
                "interactive_session": sys.stdin.isatty(),
                "timestamp": _now_iso(),
                "verification": None,
            }
            if outcome == "confirmed":
                verification = run_verification(step)
                entry["verification"] = verification
                print(f"  机器验证: ok={verification.get('ok')} matched={verification.get('matched')} "
                      f"expected={verification.get('expected')} "
                      f"classification={verification.get('classification') or verification.get('kind')} "
                      f"- {verification.get('summary', '')}", flush=True)
            else:
                print("  已跳过（可选步骤）。", flush=True)
            records.append(entry)
    except HumanAbort as abort:
        aborted = {"reason": str(abort), "timestamp": _now_iso()}
        print(f"\n人工中止: {abort}", flush=True)

    summary = _summarize(records)
    record = {
        "schema_version": RECORD_SCHEMA_VERSION,
        "tool": "scripts/acceptance/manual_runner.py",
        "protocol_file": str(protocol_path),
        "protocol_sha256": hashlib.sha256(raw_bytes).hexdigest(),
        "scenario": protocol.get("scenario"),
        "runner_pid": os.getpid(),
        "python": sys.version.split()[0],
        "started_at": started_at,
        "finished_at": _now_iso(),
        "interactive_session": sys.stdin.isatty(),
        "ui_actions_performed": [],
        "ui_actions_note": ("This runner never clicks, types, presses keys, moves the pointer or "
                            "opens anything. The human performs every UI action; the empty list is "
                            "the record of that, not a claim about intent."),
        "steps_total": steps_total,
        "steps_recorded": len(records),
        "steps": records,
        "summary": summary,
        "aborted": aborted,
    }
    record_path.write_text(json.dumps(record, ensure_ascii=False, indent=1) + "\n",
                           encoding="utf-8")
    print("", flush=True)
    print(json.dumps(summary, ensure_ascii=False, indent=1), flush=True)
    print(f"record written: {record_path}", flush=True)

    if aborted is not None:
        return EXIT_ABORTED, record
    if summary["required_failed"]:
        return EXIT_VERIFICATION_FAILED, record
    if summary["required_undetermined"]:
        return EXIT_VERIFICATION_UNDETERMINED, record
    return EXIT_OK, record


def _summarize(records: list[dict]) -> dict:
    confirmed = [entry for entry in records if entry["confirmed_by_user"]]
    skipped = [entry for entry in records if entry["skipped_by_user"]]
    verified = [entry for entry in confirmed if entry.get("verification")]
    passed = [entry for entry in verified if entry["verification"].get("matched") is True]
    failed = [entry for entry in verified if entry["verification"].get("matched") is False]
    undetermined = [entry for entry in verified if entry["verification"].get("ok") is None]
    return {
        "steps_total": len(records),
        "confirmed_by_user": len(confirmed),
        "skipped_by_user": len(skipped),
        "verifications_passed": len(passed),
        "verifications_failed": len(failed),
        "verifications_undetermined": len(undetermined),
        "required_failed": sum(1 for entry in failed if not entry["optional"]),
        "required_undetermined": sum(1 for entry in undetermined if not entry["optional"]),
        "optional_failed": sum(1 for entry in failed if entry["optional"]),
        "optional_undetermined": sum(1 for entry in undetermined if entry["optional"]),
    }
    return {
        "steps_total": len(records),
        "confirmed_by_user": len(confirmed),
        "skipped_by_user": len(skipped),
        "verifications_passed": len(passed),
        "verifications_failed": len(failed),
        "verifications_undetermined": len(undetermined),
        "required_failed": sum(1 for entry in failed if not entry["optional"]),
        "required_undetermined": sum(1 for entry in undetermined if not entry["optional"]),
        "optional_failed": sum(1 for entry in failed if entry["optional"]),
        "optional_undetermined": sum(1 for entry in undetermined if entry["optional"]),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Guided manual acceptance runner: the human operates the UI, "
                    "the runner verifies and records. It never touches the UI itself.",
    )
    parser.add_argument("protocol", type=Path, help="protocol.json describing the steps")
    parser.add_argument("out_dir", type=Path, help="directory that receives manual-<ts>/record.json")
    args = parser.parse_args(argv)
    try:
        exit_code, _ = run(args.protocol, args.out_dir)
    except ProtocolError as error:
        print(f"protocol error: {error}", file=sys.stderr)
        return EXIT_USAGE
    except OSError as error:
        print(f"cannot write the record: {error}", file=sys.stderr)
        return EXIT_USAGE
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

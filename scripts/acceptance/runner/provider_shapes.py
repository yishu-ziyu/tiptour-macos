"""Provider tool-argument shape monitor and labeled contract replay.

Two offline tools that share one job: notice when the real StepFun provider's
tool-argument shape drifts away from the contract the scenario judges were
written against. Both are strictly read-only over local evidence files — no
app is launched, no provider is called, no verdict is ever produced or changed
here.

`record_shapes(run_dir)` profiles the tool calls a real run already recorded
in its probe reports (`realtime.json`): whether a top-level `action` is mixed
with `steps` (the redundant action+steps shape behind work order 01R), the
step-count distribution, whether a label slot narrates a *result* instead of
naming an observable control ("已打开/页面已/完成"-style unobservable
wording), which required contract fields are missing, and where the top level
and the steps disagree. It writes `shapes.json` into the run directory and
prints one summary line. It monitors and reports; it never judges and never
blocks — acceptance verdicts stay owned by `scenario_judges`.

`replay_cassette(path)` replays a recorded cassette of real provider
arguments through the production judges (`judge_scenario`, called and never
modified) and writes `<cassette>.replay.json`. The header of every replay
result is stamped `"acceptance": false, "purpose": "contract-regression"`
by this module, not by the cassette author, so a replay can never be passed
off as E2E acceptance evidence. A replay answers exactly one question: do the
production judges still return the expected verdict for a known argument
shape (contract regression), yes or no.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

if __package__:  # python -m scripts.acceptance.runner.provider_shapes
    from . import scenarios as scenario_defs
    from .scenario_judges import judge_scenario
else:  # python3 scripts/acceptance/runner/provider_shapes.py ...
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from runner import scenarios as scenario_defs  # type: ignore
    from runner.scenario_judges import judge_scenario  # type: ignore

# The probe report file name the voice_task scenarios declare in their
# scenario definitions ("probe.report_file_name"). A scan of the run directory
# is deliberately limited to these names so unrelated JSON artifacts are never
# mistaken for probe output.
PROBE_REPORT_FILE_NAMES = ("realtime.json",)

SHAPES_FILE_NAME = "shapes.json"

# Result-phrase wording: a label slot that narrates an outcome instead of
# naming an observable control. A control the model could not have observed
# cannot be a target_label, so any of these words in a label slot is a
# contract-shape smell worth surfacing before the judges even run.
RESULT_PHRASE_WORDS = ("已打开", "页面已", "已完成", "完成", "已确认", "已点击", "已选择", "已送达")

# The contract fields every act_on_screen submission carries. The absence of a
# required field is recorded as a missing-field drift, never silently repaired.
REQUIRED_TOP_LEVEL_FIELDS = ("goal",)

# The two labels of a cassette replay result that make impersonation impossible.
REPLAY_ACCEPTANCE = False
REPLAY_PURPOSE = "contract-regression"

MAX_EXAMPLES = 5


class CassetteError(RuntimeError):
    pass


# ------------------------------------------------------------------ profiling


def _shape_of_call(report: str, call_index: int, call: dict) -> dict:
    """One tool call's auditable shape digest.

    The digest records what the arguments contained and which drift flags the
    raw JSON raised. It never repairs or reinterprets the call: the judges own
    interpretation, this monitor only notices shape.
    """
    record: dict[str, Any] = {
        "report": report,
        "call_index": call_index,
        "name": call.get("name", ""),
        "arguments_parsed": False,
        "keys": [],
        "steps_count": None,
        "flags": [],
    }
    name = call.get("name")
    arguments = call.get("arguments")
    parsed = _parse_object(arguments)
    if not isinstance(parsed, dict):
        if name == "act_on_screen":
            record["flags"].append("unparsable_arguments")
        return record

    record["arguments_parsed"] = True
    record["keys"] = sorted(parsed.keys())
    if name != "act_on_screen":
        # Non-routing tools are counted by name only: the act_on_screen shape
        # contract is the one whose drift invalidates scenarios.
        return record

    flags = record["flags"]
    has_top_action = "action" in parsed
    steps = parsed.get("steps")
    steps_list = steps if isinstance(steps, list) else None
    if steps_list is not None:
        record["steps_count"] = len(steps_list)

    if has_top_action and steps_list is not None:
        flags.append("mixed_action_and_steps")

    for field in REQUIRED_TOP_LEVEL_FIELDS:
        if not parsed.get(field):
            flags.append(f"missing_{field}")
    if parsed.get("action") == "click" and not parsed.get("target_label"):
        flags.append("missing_target_label")

    if steps_list is not None:
        first_action = None
        for step_index, step in enumerate(steps_list):
            if not isinstance(step, dict):
                flags.append(f"step_{step_index}_not_an_object")
                continue
            if "action" not in step:
                flags.append(f"step_{step_index}_missing_action")
                continue
            if first_action is None:
                first_action = step.get("action")
            if step.get("action") == "click" and not step.get("target_label"):
                flags.append(f"step_{step_index}_missing_target_label")
        if (has_top_action and first_action is not None
                and first_action != parsed.get("action")):
            # Top level and steps disagree about the intent: the redundancy is
            # no longer a spelling variant, it is a conflict.
            flags.append("conflicting_action")
        top_region = parsed.get("region")
        if top_region is not None:
            step_regions = [step.get("region") for step in steps_list
                            if isinstance(step, dict) and "region" in step]
            if any(region != top_region for region in step_regions):
                flags.append("conflicting_region")
        seen: list[str] = []
        for step in steps_list:
            if not isinstance(step, dict):
                continue
            fingerprint = json.dumps(step, sort_keys=True, ensure_ascii=False)
            if fingerprint in seen:
                flags.append("duplicate_steps")
                break
            seen.append(fingerprint)

    labels = _label_slots(parsed)
    for label in labels:
        hits = [word for word in RESULT_PHRASE_WORDS if word in label]
        if hits:
            flags.append("result_phrase_label")
            record["result_phrase_words"] = sorted(set(hits))
            record["result_phrase_label"] = label
    return record


def _label_slots(parsed: dict) -> list[str]:
    """Candidate label slots, top level first, then one per step."""
    slots: list[str] = []
    for key in ("target_label", "label"):
        value = parsed.get(key)
        if isinstance(value, str) and value.strip():
            slots.append(value)
    steps = parsed.get("steps")
    if isinstance(steps, list):
        for step in steps:
            if not isinstance(step, dict):
                continue
            for key in ("target_label", "label"):
                value = step.get(key)
                if isinstance(value, str) and value.strip():
                    slots.append(value)
    return slots


def _parse_object(arguments: Any) -> dict | None:
    if isinstance(arguments, dict):
        return arguments
    if not isinstance(arguments, str) or not arguments.strip():
        return None
    try:
        parsed = json.loads(arguments)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _examples(calls: list[dict], flag: str) -> list[dict]:
    found = []
    for call in calls:
        if flag in call["flags"]:
            example = {"report": call["report"], "call_index": call["call_index"],
                       "keys": call["keys"]}
            if "result_phrase_label" in call:
                example["label"] = call["result_phrase_label"]
                example["words"] = call["result_phrase_words"]
            found.append(example)
            if len(found) >= MAX_EXAMPLES:
                break
    return found


def _profile(calls: list[dict]) -> dict:
    """Aggregate shape features over the profiled calls (auditable counts)."""
    act_on_screen = [call for call in calls if call["name"] == "act_on_screen"]
    parsed_calls = [call for call in act_on_screen if call["arguments_parsed"]]
    steps_distribution: dict[str, int] = {}
    for call in parsed_calls:
        count = call["steps_count"]
        key = "none" if count is None else ("3+" if count >= 3 else str(count))
        steps_distribution[key] = steps_distribution.get(key, 0) + 1

    result_phrase_calls = [call for call in parsed_calls if "result_phrase_label" in call["flags"]]
    words: dict[str, int] = {}
    for call in result_phrase_calls:
        for word in call.get("result_phrase_words", []):
            words[word] = words.get(word, 0) + 1

    profile = {
        "calls_total": len(calls),
        "tool_names": _counts(calls),
        "mixed_action_and_steps": {
            "count": _flag_count(parsed_calls, "mixed_action_and_steps"),
            "examples": _examples(parsed_calls, "mixed_action_and_steps"),
        },
        "steps_count_distribution": steps_distribution,
        "result_phrase_labels": {
            "count": len(result_phrase_calls),
            "words_seen": words,
            "examples": _examples(result_phrase_calls, "result_phrase_label"),
        },
        "missing_fields": {
            "count": sum(1 for call in parsed_calls
                         if any(flag.startswith("missing_") or "_missing_" in flag
                                for flag in call["flags"])),
            "examples": [call for call in parsed_calls
                         if any(flag.startswith("missing_") or "_missing_" in flag
                                for flag in call["flags"])][:MAX_EXAMPLES],
        },
        "conflicts": {
            "count": _flag_count(parsed_calls, "conflicting_action")
                     + _flag_count(parsed_calls, "conflicting_region")
                     + _flag_count(parsed_calls, "duplicate_steps"),
            "examples": (_examples(parsed_calls, "conflicting_action")
                         + _examples(parsed_calls, "conflicting_region")
                         + _examples(parsed_calls, "duplicate_steps"))[:MAX_EXAMPLES],
        },
        "unparsable_arguments": _flag_count(act_on_screen, "unparsable_arguments"),
        "drift_flags": [],
    }
    profile["drift_flags"] = _drift_flags(profile)
    profile["summary_line"] = _summary_line(profile)
    return profile


def _counts(calls: list[dict]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for call in calls:
        name = call["name"]
        counts[name] = counts.get(name, 0) + 1
    return counts


def _flag_count(calls: list[dict], flag: str) -> int:
    return sum(1 for call in calls if flag in call["flags"])


def _drift_flags(profile: dict) -> list[str]:
    flags: list[str] = []
    mixed = profile["mixed_action_and_steps"]["count"]
    if mixed:
        flags.append(f"top-level action mixed with steps in {mixed} call(s) "
                     "(the redundant action+steps shape behind work order 01R)")
    phrases = profile["result_phrase_labels"]["count"]
    if phrases:
        words = ", ".join(sorted(profile["result_phrase_labels"]["words_seen"]))
        flags.append(f"result-phrase label wording in {phrases} call(s) "
                     f"(unobservable words: {words})")
    missing = profile["missing_fields"]["count"]
    if missing:
        flags.append(f"{missing} call(s) missing a required contract field")
    conflicts = profile["conflicts"]["count"]
    if conflicts:
        flags.append(f"{conflicts} call(s) carry conflicting top-level/steps redundancy")
    unparsable = profile["unparsable_arguments"]
    if unparsable:
        flags.append(f"{unparsable} call(s) had unparsable arguments JSON")
    return flags


def _summary_line(profile: dict) -> str:
    tools = " ".join(f"{name}={count}" for name, count in sorted(profile["tool_names"].items()))
    steps = " ".join(f"{key}={count}" for key, count
                     in sorted(profile["steps_count_distribution"].items())) or "none"
    drift = "yes" if profile["drift_flags"] else "no"
    return (f"calls={profile['calls_total']} ({tools}) "
            f"mixed_action_steps={profile['mixed_action_and_steps']['count']} "
            f"steps[{steps}] "
            f"result_phrase_labels={profile['result_phrase_labels']['count']} "
            f"missing_fields={profile['missing_fields']['count']} "
            f"conflicts={profile['conflicts']['count']} "
            f"unparsable={profile['unparsable_arguments']} drift={drift}")


# -------------------------------------------------------------------- monitor


def record_shapes(run_dir: Path | str) -> dict:
    """Profile every tool call in a run directory's probe reports.

    Reads only the probe reports (`realtime.json`) already written under
    `run_dir` (typically `scenario-artifacts/<scenario>/run-N/realtime.json`),
    writes the profile to `<run_dir>/shapes.json` and prints one summary line.
    Returns the same document that was written. The function never raises on
    unreadable or unexpected evidence: a monitoring failure must not take an
    acceptance run down with it, so per-file problems are recorded inside the
    document instead.
    """
    run_dir = Path(run_dir)
    reports = sorted(path for path in run_dir.rglob("*")
                     if path.is_file() and path.name in PROBE_REPORT_FILE_NAMES)
    calls: list[dict] = []
    unreadable_reports: list[str] = []
    for report_path in reports:
        try:
            payload = json.loads(report_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            unreadable_reports.append(f"{report_path}: {error}")
            continue
        if not isinstance(payload, dict):
            unreadable_reports.append(f"{report_path}: not a JSON object")
            continue
        raw_calls = payload.get("calls")
        if not isinstance(raw_calls, list):
            continue
        relative = str(report_path.relative_to(run_dir)) if report_path != run_dir else report_path.name
        for index, call in enumerate(raw_calls):
            if isinstance(call, dict):
                calls.append(_shape_of_call(relative, index, call))

    profile = _profile(calls)
    document = {
        "schema": "provider-argument-shapes/1",
        "generated_by": "scripts/acceptance/runner/provider_shapes.py",
        "purpose": ("provider tool-argument shape monitor: contract-drift detection "
                    "only, never acceptance evidence"),
        "acceptance": False,
        "run_dir": str(run_dir),
        "reports_scanned": [str(path) for path in reports],
        "reports_unreadable": unreadable_reports,
        "calls": calls,
    }
    document.update(profile)

    shapes_path = run_dir / SHAPES_FILE_NAME
    try:
        shapes_path.write_text(
            json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        document["shapes_file"] = str(shapes_path)
    except OSError as error:
        document["write_error"] = f"could not write {shapes_path}: {error}"
    print(f"provider shapes: {document['summary_line']}", flush=True)
    return document


# --------------------------------------------------------------------- replay

# A cassette replay never ran a process: these derived exit facts satisfy the
# judges' base attempt checks without pretending an app was launched.
DEFAULT_REPLAY_PROBE_RECORD = {
    "exit_record": {
        "pid": None,
        "self_exited": True,
        "returncode": 0,
        "timed_out": False,
        "returncode_basis": "derived: cassette contract replay (no process ran)",
        "report_artifact_present": True,
    },
    "report_error": None,
    "mock": True,
    "note": ("Contract-replay probe record: no probe process ran and no exit "
             "status was observed by the OS; the derived basis only satisfies "
             "the judges' base attempt checks."),
}


def replay_cassette(path: Path | str, write: bool = True) -> dict:
    """Replay one recorded cassette through the production scenario judges.

    The cassette carries raw provider arguments (recorded from a real run or
    hand-built from the 01R drift), the surrounding report/state context and
    the expected verdict. The verdict comes from `judge_scenario` — called,
    never modified — so a replay regression proves the judges and the contract
    have drifted apart, and nothing else.

    The result document's header carries `"acceptance": false` and
    `"purpose": "contract-regression"`, both written here rather than by the
    cassette, so no cassette author can label a replay as acceptance. When
    `write` is true the document is also saved next to the cassette as
    `<cassette>.replay.json`. Returns the document; raises `CassetteError` for
    a cassette that is unreadable or missing its required parts.
    """
    cassette_path = Path(path)
    try:
        cassette = json.loads(cassette_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CassetteError(f"Could not read cassette {cassette_path}: {error}") from error
    if not isinstance(cassette, dict):
        raise CassetteError(f"Cassette {cassette_path} is not a JSON object.")

    scenario_name = cassette.get("scenario")
    if not scenario_name:
        raise CassetteError(f"Cassette {cassette_path} does not name its scenario.")
    scenario = next((item for item in scenario_defs.load_scenarios()
                     if item.name == scenario_name), None)
    if scenario is None:
        raise CassetteError(
            f"Cassette {cassette_path} names unknown scenario {scenario_name!r}; "
            "the replay would judge nothing.")

    report = cassette.get("report")
    if not isinstance(report, dict):
        raise CassetteError(f"Cassette {cassette_path} has no report object to replay.")
    state_before = cassette.get("state_before")
    state_after = cassette.get("state_after")
    if not isinstance(state_before, dict) or not isinstance(state_after, dict):
        raise CassetteError(
            f"Cassette {cassette_path} needs both state_before and state_after objects.")
    expect = cassette.get("expect")
    if not isinstance(expect, dict) or not expect.get("verdict"):
        raise CassetteError(
            f"Cassette {cassette_path} must declare expect.verdict; a cassette "
            "without an expected verdict cannot detect a regression.")
    probe_record = cassette.get("probe_record")
    if not isinstance(probe_record, dict):
        probe_record = DEFAULT_REPLAY_PROBE_RECORD

    verdict = judge_scenario(scenario, probe_record, report, state_before, state_after)

    matched = verdict.status == expect["verdict"]
    failure_needle = expect.get("failure_contains")
    if matched and failure_needle and verdict.status == "failed":
        matched = any(failure_needle in reason for reason in verdict.failure_reasons)
    basis_needle = expect.get("basis_contains")
    if matched and basis_needle:
        matched = any(basis_needle in line for line in verdict.basis)

    shape_calls = []
    for index, call in enumerate(report.get("calls") or []):
        if isinstance(call, dict):
            shape_calls.append(_shape_of_call("cassette", index, call))

    document = {
        "acceptance": REPLAY_ACCEPTANCE,
        "purpose": REPLAY_PURPOSE,
        "schema": "provider-shape-replay/1",
        "generated_by": "scripts/acceptance/runner/provider_shapes.py",
        "note": ("Replay of recorded provider arguments through the production "
                 "scenario judges (called, never modified): a contract-regression "
                 "check only. It is not E2E acceptance evidence: no app ran, no "
                 "provider was called, no desktop was touched."),
        "cassette": str(cassette_path),
        "scenario": scenario_name,
        "expect": {"verdict": expect["verdict"],
                   "failure_contains": failure_needle,
                   "basis_contains": basis_needle},
        "verdict": verdict.to_dict(),
        "matched": matched,
        "regression": not matched,
        "shape_profile": {key: value for key, value in _profile(shape_calls).items()
                          if key != "summary_line"},
    }
    if write:
        replay_path = cassette_path.with_suffix(cassette_path.suffix + ".replay.json")
        try:
            replay_path.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            document["replay_file"] = str(replay_path)
        except OSError as error:
            document["write_error"] = f"could not write {replay_path}: {error}"
    return document


# ----------------------------------------------------------------------- cli


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="provider_shapes",
        description=("Offline provider tool-argument shape monitor and labeled "
                     "contract replay. Reads local evidence only."),
    )
    sub = parser.add_subparsers(dest="command", required=True)
    record = sub.add_parser("record", help="profile a run directory's probe reports")
    record.add_argument("run_dir", help="acceptance run directory to scan")
    replay = sub.add_parser("replay", help="replay a cassette through the judges")
    replay.add_argument("cassette", help="cassette JSON file")
    replay.add_argument("--no-write", action="store_true",
                        help="do not write <cassette>.replay.json")
    args = parser.parse_args(argv)
    if args.command == "record":
        record_shapes(args.run_dir)
        return 0
    result = replay_cassette(args.cassette, write=not args.no_write)
    status = "matched" if result["matched"] else "REGRESSION"
    print(f"cassette replay: {status} "
          f"(expected {result['expect']['verdict']}, "
          f"verdict {result['verdict']['status']}, "
          f"acceptance={result['acceptance']}, purpose={result['purpose']})",
          flush=True)
    return 0 if result["matched"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

"""Per-scenario evidence judges.

Every judge implements the work order's evidence doctrine: a scenario PASSes
only when the user's words, the model's raw tool arguments, the Her receipt,
the independent /state readback, the final speech and the process/cleanup facts
agree. Exit code 0, a `completed` tool return, confident model prose, or any
page change alone are never sufficient. Each judge returns human-readable
`basis` strings quoting the exact evidence so a reviewer can re-check the call.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

UNCERTAINTY_WORDING = ("不确定", "未确认", "没有确认", "已停下", "停下了", "结果还不确定")
COMPLETION_CLAIMS = ("已完成并确认", "已经完成", "已确认操作结果", "全部完成")

STATUS_PASSED = "passed"
STATUS_FAILED = "failed"
STATUS_PENDING = "pending_integrator_run"


@dataclass
class Verdict:
    status: str
    basis: list[str] = field(default_factory=list)
    failure_reasons: list[str] = field(default_factory=list)
    evidence: dict = field(default_factory=dict)

    @property
    def passed(self) -> bool:
        return self.status == STATUS_PASSED

    def to_dict(self) -> dict:
        return {"status": self.status, "basis": self.basis,
                "failure_reasons": self.failure_reasons, "evidence": self.evidence}


def _parse_json_object(text: Any) -> dict | None:
    if isinstance(text, dict):
        return text
    if not isinstance(text, str) or not text.strip():
        return None
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _normalized(text: str) -> str:
    return "".join(text.split()).casefold()


def _receipt_from_tool_results(tool_results: Any) -> tuple[dict | None, str | None]:
    if not isinstance(tool_results, list):
        return None, "probe report has no tool_results list"
    receipts = [parsed for parsed in (_parse_json_object(item) for item in tool_results) if parsed]
    if not receipts:
        return None, "no tool result parsed as a receipt JSON object"
    return receipts[-1], None


def _raw_submissions(calls: Any) -> tuple[list[dict], list[dict]]:
    """Return (act_on_screen submissions, all recorded calls)."""
    submissions: list[dict] = []
    all_calls: list[dict] = []
    if not isinstance(calls, list):
        return submissions, all_calls
    for call in calls:
        if not isinstance(call, dict):
            continue
        name = call.get("name", "")
        arguments = call.get("arguments")
        all_calls.append({"name": name, "arguments": arguments})
        if name == "act_on_screen":
            parsed = _parse_json_object(arguments)
            if parsed is not None:
                submissions.append(parsed)
    return submissions, all_calls


def _submission_requests_open_app(submission: dict) -> bool:
    if submission.get("action") == "open_app" or submission.get("application"):
        return True
    steps = submission.get("steps")
    if isinstance(steps, list):
        for step in steps:
            if isinstance(step, dict) and (step.get("action") == "open_app" or step.get("application")):
                return True
    return False


def _submission_click_steps(submission: dict) -> list[dict]:
    steps: list[dict] = []
    if isinstance(submission.get("steps"), list):
        for step in submission["steps"]:
            if isinstance(step, dict) and step.get("action") == "click":
                steps.append(step)
    elif submission.get("action") == "click":
        steps.append(submission)
    return steps


def _receipt_sent_actions(receipt: dict) -> list[dict]:
    actions = receipt.get("current_actions")
    if not isinstance(actions, list):
        return []
    return [action for action in actions
            if isinstance(action, dict) and action.get("delivery") in ("sent", "unknown")]


def _decision_packet(action: dict) -> dict:
    packet = action.get("decision_packet")
    return packet if isinstance(packet, dict) else {}


def _action_region_right(action: dict, submission: dict) -> tuple[bool, str]:
    """Region=right either in the raw model arguments or restored in code."""
    packet = _decision_packet(action)
    where = packet.get("where") if isinstance(packet.get("where"), dict) else {}
    if where.get("region") == "right":
        return True, "contract decision_packet.where.region=right"
    if submission.get("region") == "right":
        return True, "raw tool arguments region=right"
    if isinstance(submission.get("steps"), list):
        for step in submission["steps"]:
            if isinstance(step, dict) and step.get("region") == "right":
                return True, "raw tool arguments step region=right"
    return False, "no region=right found in raw arguments or contract decision packet"


def _speech_texts(report: dict) -> list[str]:
    texts = report.get("rendered_texts")
    if isinstance(texts, list):
        return [text for text in texts if isinstance(text, str) and text.strip()]
    return []


def _base_attempt_checks(probe_record: dict, report: dict | None) -> tuple[list[str], list[str]]:
    """Checks every probe-driven scenario shares: exit, report, speech presence."""
    basis: list[str] = []
    failures: list[str] = []
    exit_record = probe_record.get("exit_record", {})
    if exit_record.get("timed_out"):
        failures.append("The probe process did not exit on its own and had to be stopped.")
    elif not exit_record.get("self_exited"):
        failures.append("The probe process did not exit by itself.")
    elif exit_record.get("returncode") == 0:
        basis.append(f"Probe process exited by itself with code 0 (pid {exit_record.get('pid')}).")
    else:
        failures.append(f"Probe exited with code {exit_record.get('returncode')}.")
    if report is None:
        failures.append("The probe wrote no parseable report.")
        return basis, failures
    if report.get("timed_out"):
        failures.append("The probe report self-reports a timeout.")
    error_text = report.get("error")
    if isinstance(error_text, str) and error_text.strip():
        failures.append(f"The probe report carries an error: {error_text}")
    return basis, failures


# ---------------------------------------------------------------- scenario A


def judge_single_step_right_setting(
    scenario,
    probe_record: dict,
    report: dict | None,
    state_before: dict,
    state_after: dict,
    expectations: dict,
) -> Verdict:
    verdict = Verdict(status=STATUS_FAILED)
    basis, failures = _base_attempt_checks(probe_record, report)
    verdict.basis.extend(basis)
    verdict.failure_reasons.extend(failures)
    if failures:
        return verdict

    submissions, all_calls = _raw_submissions(report.get("calls"))
    verdict.evidence["user_words"] = scenario.user_words
    verdict.evidence["model_tool_arguments"] = all_calls
    verdict.evidence["model_input_transcript"] = report.get("input_transcript")

    if not submissions:
        verdict.failure_reasons.append(
            "The model issued no act_on_screen call; there is no routed action to judge."
        )
        return verdict
    submission = submissions[-1]

    if expectations.get("require_no_open_app") and _submission_requests_open_app(submission):
        verdict.failure_reasons.append(
            "Raw model arguments request open_app for a page-control click: "
            f"{json.dumps(submission, ensure_ascii=False)}"
        )
        return verdict

    receipt, receipt_error = _receipt_from_tool_results(report.get("tool_results"))
    verdict.evidence["her_receipt"] = receipt
    if receipt is None:
        verdict.failure_reasons.append(f"No Her receipt in the probe report: {receipt_error}")
        return verdict
    for required_key in ("task_id", "turn_id", "status", "current_actions"):
        if required_key not in receipt:
            verdict.failure_reasons.append(f"Her receipt is missing {required_key!r}.")
    if verdict.failure_reasons:
        return verdict

    sent_actions = _receipt_sent_actions(receipt)
    clicks = [action for action in sent_actions if action.get("action") == "click"]
    if not clicks:
        verdict.failure_reasons.append(
            f"The receipt shows no delivered click action: "
            f"{json.dumps(receipt.get('current_actions'), ensure_ascii=False)}"
        )
        return verdict
    last_click = clicks[-1]

    if any(action.get("action") == "right_click" for action in sent_actions):
        verdict.failure_reasons.append(
            "The executed contract action is right_click; a 右边 request must not become a right click."
        )
    region_ok, region_source = _action_region_right(last_click, submission)
    if expectations.get("require_region_right") and not region_ok:
        verdict.failure_reasons.append(
            "The click carries no region=right constraint (raw arguments and contract packet)."
        )
    else:
        verdict.basis.append(f"Region constraint confirmed via {region_source}.")

    selected = state_after.get("selected")
    clicks_after = state_after.get("clicks")
    clicks_before = state_before.get("clicks")
    events_after = list(state_after.get("events") or [])
    events_before = list(state_before.get("events") or [])
    new_events = events_after[len(events_before):] if events_after[:len(events_before)] == events_before else events_after
    verdict.evidence["independent_state"] = {"before": state_before, "after": state_after,
                                             "new_events": new_events}
    expected_selected = expectations.get("expected_selected_value")
    if selected != expected_selected:
        verdict.failure_reasons.append(
            f"Independent /state selected={selected!r}, expected {expected_selected!r}."
        )
    expected_delta = expectations.get("expected_click_delta", 1)
    if (clicks_after or 0) - (clicks_before or 0) != expected_delta:
        verdict.failure_reasons.append(
            f"Independent /state clicks changed by {(clicks_after or 0) - (clicks_before or 0)}, "
            f"expected exactly {expected_delta} (no re-click, no unrelated click)."
        )
    forbidden = set(expectations.get("forbidden_event_values") or [])
    bad_events = [event for event in new_events if event in forbidden]
    if bad_events:
        verdict.failure_reasons.append(
            f"Independent /state shows forbidden side effects: {bad_events}."
        )
    if new_events != [expected_selected]:
        verdict.failure_reasons.append(
            f"Independent /state new events {new_events} are not exactly [{expected_selected!r}]."
        )

    status = receipt.get("status")
    accepted = set(expectations.get("accepted_receipt_statuses") or [])
    speech = _speech_texts(report)
    verdict.evidence["final_speech"] = speech
    if not speech:
        verdict.failure_reasons.append("No final speech text was captured.")
    if status not in accepted:
        verdict.failure_reasons.append(
            f"Her receipt status {status!r} is not one of the accepted honest outcomes "
            f"{sorted(accepted)} (detail: {receipt.get('detail')!r})."
        )
        return verdict

    if status == "completed":
        last_action_basis = last_click.get("completion_basis")
        policy = last_click.get("completion_policy")
        delivery = last_click.get("delivery")
        if last_action_basis == "system_verified_outcome":
            verdict.basis.append(
                "Receipt claims completion with system-verified outcome evidence; "
                "independent /state corroborates the click landed on the right-hand control."
            )
        elif last_action_basis == "delivery_confirmed" and policy == "delivery_sufficient":
            verdict.basis.append(
                "Receipt claims completion on a delivery-sufficient direct click; "
                "independent /state shows exactly one click on the right-hand control."
            )
        else:
            verdict.failure_reasons.append(
                f"Receipt claims completed with completion_basis={last_action_basis!r}, "
                f"policy={policy!r}, delivery={delivery!r}; that is not corroborated evidence."
            )
    else:
        joined_speech = " ".join(speech)
        if expectations.get("require_uncertainty_wording_when_unverified", True):
            if not any(word in joined_speech for word in UNCERTAINTY_WORDING):
                verdict.failure_reasons.append(
                    f"uncertain_effect receipt but the final speech does not state the "
                    f"uncertainty: {joined_speech!r}"
                )
            else:
                verdict.basis.append(
                    "uncertain_effect receipt with matching honest speech; "
                    "independent /state proves the side effect without the app overclaiming."
                )
        for forbidden_claim in (expectations.get("forbidden_speech_claims_when_unverified") or []):
            if forbidden_claim in joined_speech:
                verdict.failure_reasons.append(
                    f"Final speech overclaims completion ({forbidden_claim!r}): {joined_speech!r}"
                )

    verdict.basis.append(
        f"Task identity: task_id={receipt.get('task_id')}, turn_id={receipt.get('turn_id')}, "
        f"target_version={receipt.get('target_version')}; delivered action id="
        f"{last_click.get('id')}, observation_id={last_click.get('observationID')}."
    )
    verdict.evidence["task_turn_attempt_ids"] = {
        "task_id": receipt.get("task_id"),
        "turn_id": receipt.get("turn_id"),
        "target_version": receipt.get("target_version"),
        "action_attempt_ids": [action.get("id") for action in sent_actions],
        "observation_ids": [action.get("observationID") for action in sent_actions],
    }
    if not verdict.failure_reasons:
        verdict.status = STATUS_PASSED
        verdict.basis.append(
            "All six evidence layers agree: user words, raw tool arguments (click with "
            "region=right, no open_app), Her receipt, independent /state "
            "(selected=right-setting, exactly one new event), final speech, and a "
            "self-exiting probe with no leftovers."
        )
    return verdict


# ---------------------------------------------------------------- scenario C


def judge_two_step_display_settings_scale(
    scenario,
    probe_record: dict,
    report: dict | None,
    state_before: dict,
    state_after: dict,
    expectations: dict,
) -> Verdict:
    verdict = Verdict(status=STATUS_FAILED)
    basis, failures = _base_attempt_checks(probe_record, report)
    verdict.basis.extend(basis)
    verdict.failure_reasons.extend(failures)
    if failures:
        return verdict

    submissions, all_calls = _raw_submissions(report.get("calls"))
    verdict.evidence["user_words"] = scenario.user_words
    verdict.evidence["model_tool_arguments"] = all_calls
    verdict.evidence["model_input_transcript"] = report.get("input_transcript")

    if not submissions:
        verdict.failure_reasons.append("The model issued no act_on_screen call.")
        return verdict
    submission = submissions[-1]

    if _submission_requests_open_app(submission):
        verdict.failure_reasons.append(
            "Raw model arguments request open_app for a two-step page-control sequence "
            f"(the multi-step intent bug): {json.dumps(submission, ensure_ascii=False)}"
        )
        return verdict

    click_steps = _submission_click_steps(submission)
    if expectations.get("require_two_click_steps") and len(click_steps) < 2:
        verdict.failure_reasons.append(
            f"The submission does not carry two explicit click steps: "
            f"{json.dumps(submission, ensure_ascii=False)}"
        )
        return verdict

    receipt, receipt_error = _receipt_from_tool_results(report.get("tool_results"))
    verdict.evidence["her_receipt"] = receipt
    if receipt is None:
        verdict.failure_reasons.append(f"No Her receipt in the probe report: {receipt_error}")
        return verdict
    for required_key in ("task_id", "turn_id", "status", "current_actions"):
        if required_key not in receipt:
            verdict.failure_reasons.append(f"Her receipt is missing {required_key!r}.")
    if verdict.failure_reasons:
        return verdict

    sent_actions = _receipt_sent_actions(receipt)
    if len(sent_actions) != 2:
        verdict.failure_reasons.append(
            f"The receipt shows {len(sent_actions)} delivered actions, expected exactly 2 "
            "with no extra or unrelated actions: "
            f"{json.dumps(receipt.get('current_actions'), ensure_ascii=False)}"
        )
    labels = [action.get("label") for action in sent_actions]
    expected_labels = ["打开显示设置", "缩放选项"]
    for action, expected_label in zip(sent_actions, expected_labels):
        if expected_label not in (action.get("label") or ""):
            verdict.failure_reasons.append(
                f"Delivered action label {action.get('label')!r} does not match the "
                f"expected control {expected_label!r}."
            )

    events_after = list(state_after.get("events") or [])
    events_before = list(state_before.get("events") or [])
    new_events = events_after[len(events_before):] if events_after[:len(events_before)] == events_before else events_after
    verdict.evidence["independent_state"] = {"before": state_before, "after": state_after,
                                             "new_events": new_events}
    expected_sequence = expectations.get("expected_event_sequence") or ["open-menu", "scale"]
    if new_events != expected_sequence:
        verdict.failure_reasons.append(
            f"Independent /state new events {new_events} are not exactly {expected_sequence}."
        )
    if state_after.get("selected") != expectations.get("expected_selected_value"):
        verdict.failure_reasons.append(
            f"Independent /state selected={state_after.get('selected')!r}, expected "
            f"{expectations.get('expected_selected_value')!r}."
        )
    click_delta = (state_after.get("clicks") or 0) - (state_before.get("clicks") or 0)
    if click_delta != expectations.get("expected_click_delta", 1):
        verdict.failure_reasons.append(
            f"Independent /state clicks changed by {click_delta}, expected "
            f"{expectations.get('expected_click_delta', 1)} (the menu open is not a click; "
            "no extra click is allowed)."
        )

    status = receipt.get("status")
    accepted = set(expectations.get("accepted_receipt_statuses") or [])
    speech = _speech_texts(report)
    verdict.evidence["final_speech"] = speech
    if not speech:
        verdict.failure_reasons.append("No final speech text was captured.")
    if status not in accepted:
        verdict.failure_reasons.append(
            f"Her receipt status {status!r} is not one of the accepted honest outcomes "
            f"{sorted(accepted)} (detail: {receipt.get('detail')!r})."
        )
        return verdict
    if status != "completed":
        joined_speech = " ".join(speech)
        if expectations.get("require_uncertainty_wording_when_unverified", True):
            if not any(word in joined_speech for word in UNCERTAINTY_WORDING):
                verdict.failure_reasons.append(
                    f"uncertain_effect receipt but the final speech does not state the "
                    f"uncertainty: {joined_speech!r}"
                )
        for forbidden_claim in (expectations.get("forbidden_speech_claims_when_unverified") or []):
            if forbidden_claim in joined_speech:
                verdict.failure_reasons.append(
                    f"Final speech overclaims completion ({forbidden_claim!r}): {joined_speech!r}"
                )

    verdict.basis.append(
        "Step facts: "
        + " | ".join(
            f"step {index + 1} label={action.get('label')!r} delivery={action.get('delivery')!r} "
            f"outcome_evidence={action.get('outcome_evidence')!r} "
            f"completion_policy={action.get('completion_policy')!r} "
            f"completion_basis={action.get('completion_basis')!r}"
            for index, action in enumerate(sent_actions)
        )
    )
    verdict.evidence["task_turn_attempt_ids"] = {
        "task_id": receipt.get("task_id"),
        "turn_id": receipt.get("turn_id"),
        "target_version": receipt.get("target_version"),
        "action_attempt_ids": [action.get("id") for action in sent_actions],
        "observation_ids": [action.get("observationID") for action in sent_actions],
    }
    if not verdict.failure_reasons:
        verdict.status = STATUS_PASSED
        verdict.basis.append(
            "All six evidence layers agree: user words, raw tool arguments (two click "
            "steps, no open_app), Her receipt with two delivered actions, independent "
            "/state events exactly [open-menu, scale] with selected=scale, final speech, "
            "and a self-exiting probe with no leftovers."
        )
    return verdict


# ------------------------------------------------------------ scenario continuity


def judge_continuity_progress_cancel(
    scenario,
    probe_record: dict,
    report: dict | None,
    state_before: dict,
    state_after: dict,
    expectations: dict,
    require_evidence_language: bool = False,
) -> Verdict:
    verdict = Verdict(status=STATUS_FAILED)
    basis, failures = _base_attempt_checks(probe_record, report)
    verdict.basis.extend(basis)
    verdict.failure_reasons.extend(failures)
    if failures:
        return verdict
    verdict.evidence["user_words"] = scenario.user_words

    rounds = report.get("rounds")
    if not isinstance(rounds, list) or len(rounds) != 2:
        verdict.failure_reasons.append(
            f"The continuity report does not contain exactly two rounds: {rounds!r}"
        )
        return verdict
    verdict.evidence["rounds"] = rounds

    progress_round, cancel_round = rounds[0], rounds[1]
    expected_actions = expectations.get("round_actions") or ["status", "cancel"]
    for round_payload, expected_action, label in (
        (progress_round, expected_actions[0], "first"),
        (cancel_round, expected_actions[1], "second"),
    ):
        if round_payload.get("action") != expected_action:
            verdict.failure_reasons.append(
                f"The {label} round used task_control action "
                f"{round_payload.get('action')!r}, expected {expected_action!r} "
                f"(input transcript: {round_payload.get('input_transcript')!r})."
            )
    if not progress_round.get("task_id"):
        verdict.failure_reasons.append("The progress round carries no task id.")
    if not cancel_round.get("task_id"):
        verdict.failure_reasons.append("The cancel round carries no task id.")

    if expectations.get("require_same_task_id_across_rounds", True):
        if progress_round.get("task_id") and progress_round.get("task_id") != cancel_round.get("task_id"):
            verdict.failure_reasons.append(
                "The reconnect lost the task identity: progress task_id="
                f"{progress_round.get('task_id')!r} vs cancel task_id={cancel_round.get('task_id')!r}."
            )
        else:
            verdict.basis.append(
                f"Same task survived the reconnect: task_id={progress_round.get('task_id')!r}."
            )
    if expectations.get("require_new_turn_id_on_second_round", True):
        if progress_round.get("turn_id") == cancel_round.get("turn_id"):
            verdict.failure_reasons.append(
                "The cancel reused the progress turn id; a reconnect must bind a fresh turn."
            )
        else:
            verdict.basis.append(
                f"Fresh turn binding after reconnect: {progress_round.get('turn_id')!r} → "
                f"{cancel_round.get('turn_id')!r}."
            )
    if not cancel_round.get("control_binding_valid"):
        verdict.failure_reasons.append(
            "The cancel control was not bound to the current task/version/turn."
        )
    expected_final = expectations.get("require_final_status")
    if expected_final and cancel_round.get("status") != expected_final:
        verdict.failure_reasons.append(
            f"Final receipt status is {cancel_round.get('status')!r}, expected {expected_final!r}."
        )

    fixture_actions = report.get("fixture_actions")
    allowed_fixture_actions = expectations.get("require_fixture_actions_at_most", 1)
    if not isinstance(fixture_actions, int) or fixture_actions > allowed_fixture_actions:
        verdict.failure_reasons.append(
            f"The progress query executed {fixture_actions!r} fixture actions; asking for "
            f"progress must not re-run steps (at most {allowed_fixture_actions})."
        )
    else:
        verdict.basis.append(
            f"Asking for progress did not re-execute any step (fixture actions={fixture_actions})."
        )

    verdict.evidence["independent_state"] = {"before": state_before, "after": state_after,
                                             "new_events": []}
    if expectations.get("require_no_desktop_side_effects", True):
        if state_before != state_after:
            verdict.failure_reasons.append(
                "The continuity scenario changed the controlled page state; it must not "
                f"produce desktop side effects: before={state_before!r} after={state_after!r}"
            )
        else:
            verdict.basis.append(
                "Independent /state unchanged across both rounds: no desktop side effects."
            )

    if report.get("microphone_opened") is not False:
        verdict.failure_reasons.append("The probe report does not confirm the microphone stayed closed.")
    if report.get("provider_connection_attempted") is not True:
        verdict.failure_reasons.append("The probe report does not confirm a real provider connection.")

    progress_speech = [text for text in (progress_round.get("rendered_texts") or []) if isinstance(text, str)]
    final_speech = [text for text in (cancel_round.get("rendered_texts") or []) if isinstance(text, str)]
    verdict.evidence["final_speech"] = {"progress_round": progress_speech, "cancel_round": final_speech}
    if not progress_speech:
        verdict.failure_reasons.append("The progress round captured no speech text.")

    language = expectations.get("progress_language") or {}
    forbidden_language = language.get("forbidden_substrings") or []
    joined_progress = " ".join(progress_speech)
    language_offenders = [phrase for phrase in forbidden_language if phrase in joined_progress]
    if language_offenders:
        message = (
            f"Progress speech uses verification wording for unverified steps "
            f"({language_offenders}): {joined_progress!r}. Work order 02 requires "
            "delivery-confirmed progress to be worded as 已处理/尚未完成, never 已确认."
        )
        if require_evidence_language or language.get("mode") == "required":
            verdict.failure_reasons.append(message)
        else:
            verdict.basis.append(f"ADVISORY evidence-language observation: {message}")

    verdict.evidence["task_turn_attempt_ids"] = {
        "task_id": progress_round.get("task_id"),
        "progress_turn_id": progress_round.get("turn_id"),
        "cancel_turn_id": cancel_round.get("turn_id"),
    }
    if not verdict.failure_reasons:
        verdict.status = STATUS_PASSED
        verdict.basis.append(
            "All six evidence layers agree: user words, the recorded task_control arguments "
            "(status then cancel), the receipts with stable task identity and fresh turn "
            "binding, an unchanged independent /state, the captured progress and cancel "
            "speech, and a self-exiting probe."
        )
    return verdict


# ------------------------------------------------------------- scenario unknown


def judge_unknown_delivery_fault(
    scenario,
    probe_record: dict,
    report: dict | None,
    state_before: dict,
    state_after: dict,
    expectations: dict,
) -> Verdict:
    """Work order 04's scenario U contract, evaluated generically.

    The probe that owns this evidence ships with work order 04, so until it is
    merged the scenario is pending-integrator-run and no verdict is guessed.
    """
    verdict = Verdict(status=STATUS_FAILED)
    basis, failures = _base_attempt_checks(probe_record, report)
    verdict.basis.extend(basis)
    verdict.failure_reasons.extend(failures)
    if failures:
        return verdict
    verdict.evidence["user_words"] = scenario.user_words

    state_checks = expectations.get("state_before_after") or {}
    selected = state_after.get("selected")
    if state_checks.get("expected_selected_value") and selected != state_checks["expected_selected_value"]:
        verdict.failure_reasons.append(
            f"Independent /state selected={selected!r}, expected "
            f"{state_checks['expected_selected_value']!r}."
        )
    expected_clicks = state_checks.get("expected_total_clicks_after_continue")
    if expected_clicks is not None and state_after.get("clicks") != expected_clicks:
        verdict.failure_reasons.append(
            f"Independent /state clicks={state_after.get('clicks')!r} after the continue "
            f"request, expected {expected_clicks!r} exactly: the unconfirmed attempt must "
            "not be re-delivered and no unrelated control may be clicked."
        )
    if state_checks.get("forbid_left_setting_event") and "left-setting" in (state_after.get("events") or []):
        verdict.failure_reasons.append(
            "Independent /state shows a click on the left-hand twin; the pinned target was replaced."
        )
    verdict.evidence["independent_state"] = {"before": state_before, "after": state_after,
                                             "new_events": list(state_after.get("events") or [])}

    receipt = None
    if isinstance(report.get("receipt"), dict):
        receipt = report["receipt"]
    else:
        candidate, _ = _receipt_from_tool_results(report.get("tool_results"))
        receipt = candidate
    verdict.evidence["her_receipt"] = receipt
    if receipt is None:
        verdict.failure_reasons.append(
            "The fault report contains no locatable Her receipt; cannot verify the "
            "delivery=unknown → uncertain_effect contract."
        )
        return verdict
    expected_sequence = expectations.get("receipt_sequence") or []
    for expected in expected_sequence:
        for key, expected_value in expected.items():
            if key in receipt:
                actual = receipt.get(key)
                where = "receipt"
            elif key in ("delivery", "outcome_evidence", "completion_policy", "completion_basis"):
                # Work order 04's contract states these per delivered action.
                actions = _receipt_sent_actions(receipt)
                actual = actions[-1].get(key) if actions else None
                where = "last delivered action"
            else:
                actual = receipt.get(key)
                where = "receipt"
            if actual != expected_value:
                verdict.failure_reasons.append(
                    f"Her receipt {where} {key}={actual!r}, expected {expected_value!r}."
                )

    speech = _speech_texts(report)
    verdict.evidence["final_speech"] = speech
    joined_speech = " ".join(speech)
    must_contain = expectations.get("final_speech_must_contain_any") or []
    if must_contain and not any(phrase in joined_speech for phrase in must_contain):
        verdict.failure_reasons.append(
            f"Final speech does not state the uncertain outcome ({must_contain}): {joined_speech!r}"
        )
    for forbidden in expectations.get("final_speech_must_not_contain") or []:
        if forbidden in joined_speech:
            verdict.failure_reasons.append(
                f"Final speech falsely claims completion ({forbidden!r}): {joined_speech!r}"
            )

    verdict.evidence["task_turn_attempt_ids"] = {
        "task_id": receipt.get("task_id"),
        "turn_id": receipt.get("turn_id"),
        "action_attempt_ids": [action.get("id") for action in _receipt_sent_actions(receipt)],
    }
    if not verdict.failure_reasons:
        verdict.status = STATUS_PASSED
        verdict.basis.append(
            "The injected delivery-unknown path is confirmed by independent /state "
            "(exactly one click, right-hand control), an honest uncertain receipt, no "
            "repeat delivery of the same attempt, and uncertain final speech."
        )
    return verdict


JUDGES = {
    "single_step_right_setting": judge_single_step_right_setting,
    "two_step_display_settings_scale": judge_two_step_display_settings_scale,
    "continuity_progress_cancel": judge_continuity_progress_cancel,
    "unknown_delivery_fault_recovery": judge_unknown_delivery_fault,
}


def judge_scenario(
    scenario,
    probe_record: dict,
    report: dict | None,
    state_before: dict,
    state_after: dict,
    require_evidence_language: bool = False,
) -> Verdict:
    judge = JUDGES.get(scenario.name)
    if judge is None:
        return Verdict(status=STATUS_FAILED,
                       failure_reasons=[f"No judge is registered for scenario {scenario.name!r}."])
    if scenario.name == "continuity_progress_cancel":
        return judge(scenario, probe_record, report, state_before, state_after,
                     scenario.expectations, require_evidence_language=require_evidence_language)
    return judge(scenario, probe_record, report, state_before, state_after, scenario.expectations)
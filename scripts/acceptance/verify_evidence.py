#!/usr/bin/env python3
"""Independent review of Her acceptance evidence packages (result.json).

Acceptance is never decided by the tested product's own `passed` field: this
script re-derives every criterion from the JSON evidence package and nothing
else. It is offline by construction — stdlib JSON reads only, no app launch,
no network, no product code, no runner imports — so it can audit a package on
a machine that has none of the tooling the run needed.

Doctrine re-derived here (sources cited, code not reused):

* Six evidence layers per scenario — user words, the model's raw tool
  arguments, task/turn/attempt ids, the Her receipt, the independent /state
  readback, the final speech, and the failure/recovery record. A claimed PASS
  that is missing any layer is a FAIL, not a PASS (runner evidence.py
  REQUIRED_SCENARIO_KEYS doctrine; scripts/acceptance/README.md "Evidence
  doctrine").
* A receipt action with delivery=sent must leave its side effect in the
  independent state: the new-event sequence must be non-empty and must
  correspond to the delivered actions (runner scenario_judges.py: /state
  click-delta and ordered-event checks).
* Final speech may only claim 已确认/完成 when the receipt carries the
  corresponding system-verified basis; a confirmation spoken for steps the
  system never independently verified is an overclaim and fails — work order
  02's verify-report.py `over_claims` rule ("a progress sentence that reports
  已确认 for steps the system never verified" is rejected) and the runner's
  `_overclaiming_speech` judge.
* A receipt with status=uncertain_effect must be spoken as uncertainty
  (runner scenario_judges.py UNCERTAINTY_WORDING; work order 02's
  "delivery-confirmed progress is worded 已处理/尚未完成, never 已确认").
* A recorded pass may also rest on a cancelled terminal contract:
  status=cancelled with a valid control binding, no un-disambiguated
  delivery=sent action, no side-effect residue in the independent state and
  no completion claim in the final speech (runner scenario_judges.py
  judge_continuity_progress_cancel: the real shape of a cancel is a progress
  question — no action — followed by 取消, so `cancelled` is a legitimate
  success outcome and rejecting it is a reviewer bug, not strictness).
* Raw model tool arguments must agree with the recorded effective/normalized
  plan when both are present (work order 01R: assert the effective plan, not
  the normalization mechanism).
* An exit status whose basis starts with `derived:` is only honest while the
  probe's report artifact is present (runner scenario_judges.py
  `_base_attempt_checks`, process_control.py `_wait_for_launched_instance_exit`).

Usage:
    python3 scripts/acceptance/verify_evidence.py <result.json | directory> [--strict]
    python3 scripts/acceptance/verify_evidence.py --self-test

Exit codes:
    0 — every derived criterion passed (and, under --strict, nothing is
        pending/blocked);
    1 — any criterion FAILed (this is the reviewer's "acceptance not proven");
    2 — the input could not be read or parsed (never an acceptance verdict).

--self-test replays the testdata packages offline: good and
cancelled-contract-good must review as PASS; missing-layer,
overclaiming-speech and cancelled-but-claimed-complete must review as FAIL.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# ---------------------------------------------------------------- constants

SIX_LAYERS = (
    "user_words",
    "model_tool_arguments",
    "task_turn_attempt_ids",
    "her_receipt",
    "independent_state",
    "final_speech",
    "failure_recovery",
)

RECORDED_STATUSES = ("passed", "failed", "pending_integrator_run", "blocked")
NON_EXECUTED_STATUSES = ("pending_integrator_run", "blocked")

# Work order 02 evidence-language doctrine, as enforced by the runner judges:
# a receipt whose outcome is uncertain must be spoken as uncertainty.
# (scenario_judges.py UNCERTAINTY_WORDING; verify-report.py demands
#  已处理/尚未完成 and forbids 已确认 for unverified steps.)
UNCERTAINTY_WORDING = (
    "不确定",
    "未确认",
    "没有确认",
    "已停下",
    "停下了",
    "结果还不确定",
    "尚未完成",
    "已处理",
)

# Speech that asserts a verified completion. Each claim is only licensed when
# the receipt carries the matching system-verified basis, per the sources
# cited in the module docstring.
COMPLETION_CLAIMS = (
    "已确认",
    "已完成并确认",
    "已完成",
    "已经完成",
    "全部完成",
    "确认完成",
    "已成功",
)

# The only (completion_policy, completion_basis) pairs that corroborate a
# completed step (scenario_judges.py CORROBORATED_COMPLETION, read under both
# the receipt's snake_case and camelCase spellings).
CORROBORATED_COMPLETION = {
    ("delivery_sufficient", "delivery_confirmed"),
    ("outcome_required", "system_verified_outcome"),
}
SYSTEM_VERIFIED_BASISES = {("outcome_required", "system_verified_outcome")}

# The third terminal contract: a task the user cancelled. Its real shape is a
# progress question (no action) followed by 取消 — the task ends `cancelled`,
# nothing was delivered and the independent /state never moved — so `cancelled`
# is a legitimate success outcome, not a failed one. It is only licensed when
# the receipt proves the cancel stopped a *resolved* state; see
# `_cancelled_terminal_contract`. (runner scenario_judges.py
# judge_continuity_progress_cancel: a valid control binding, the same task id
# across rounds, a fresh turn binding, at most one fixture action and
# state_before == state_after.)
CANCELLED_STATUS = "cancelled"

# Outcome markers that still leave a delivered step's result open. A cancelled
# terminal state must not rest on them: a delivered step whose outcome is still
# unknown/pending/not-observed belongs to the honest uncertain contract above,
# not to this one.
UNRESOLVED_OUTCOME_MARKERS = (
    "unknown",
    "unknown_effect",
    "uncertain",
    "uncertain_effect",
    "ambiguous",
    "unresolved",
    "pending",
    "not_observed",
)

# Outcomes that settle a delivered step as *not carried out*: the cancel caught
# the step before it ran, or superseded it. Either way the step's result is
# known and nothing is claimed about it.
SETTLED_NON_EXECUTION_OUTCOMES = (
    "cancelled",
    "not_attempted",
    "not_executed",
    "superseded",
    "skipped",
    "rolled_back",
)

# Outcome markers that settle a delivered step as verified: the system
# independently observed the result — the same evidence the completed contract
# accepts.
VERIFIED_OUTCOME_MARKERS = (
    "system_verified",
    "verified",
    "system_observed",
)

# ------------------------------------------------------------- check plumbing


class Check:
    """One review criterion's outcome, with the exact JSON path it rests on."""

    def __init__(self, criterion_id: str, scope: str, evidence_path: str):
        self.criterion_id = criterion_id
        self.scope = scope
        self.evidence_path = evidence_path
        self.status = "pass"
        self.detail = ""

    def pass_(self, detail: str = "") -> "Check":
        self.status, self.detail = "pass", detail
        return self

    def fail(self, detail: str) -> "Check":
        self.status, self.detail = "fail", detail
        return self

    def skip(self, detail: str) -> "Check":
        self.status, self.detail = "skip", detail
        return self

    def na(self, detail: str) -> "Check":
        # Not applicable: the recorded evidence does not describe this facet.
        # Never counts against the verdict, but always recorded.
        self.status, self.detail = "na", detail
        return self

    @property
    def failed(self) -> bool:
        return self.status == "fail"

    def to_dict(self) -> dict:
        return {
            "criterion": self.criterion_id,
            "scope": self.scope,
            "status": self.status,
            "detail": self.detail,
            "evidence_path": self.evidence_path,
        }

    @classmethod
    def from_dict(cls, entry: dict) -> "Check":
        check = cls(entry["criterion"], entry["scope"], entry["evidence_path"])
        check.status = entry["status"]
        check.detail = entry["detail"]
        return check


def _json_object(value):
    return value if isinstance(value, dict) else None


def _parse_arguments(value):
    """A tool-arguments payload is either an object or a JSON string."""
    if isinstance(value, dict):
        return value
    if isinstance(value, str) and value.strip():
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, dict) else None
    return None


def _normalized_text(text) -> str:
    return "".join(str(text).split()).casefold()


def _field(record: dict | None, *names, default=None):
    """Read the first present spelling of a field, never guessing a value."""
    for name in names:
        if isinstance(record, dict) and name in record:
            return record[name]
    return default


def _speech_texts(final_speech) -> list[str]:
    """Final speech is a list, or a per-round mapping (continuity scenario)."""
    if isinstance(final_speech, str):
        return [final_speech] if final_speech.strip() else []
    if isinstance(final_speech, list):
        return [text for text in final_speech if isinstance(text, str) and text.strip()]
    if isinstance(final_speech, dict):
        texts: list[str] = []
        for value in final_speech.values():
            texts.extend(_speech_texts(value))
        return texts
    return []


def _new_events(independent_state) -> list:
    """The side-effect events the independent state added, never the old ones."""
    if not isinstance(independent_state, dict):
        return []
    recorded = independent_state.get("new_events")
    if isinstance(recorded, list):
        return list(recorded)
    before = _field(independent_state.get("before"), "events", default=None)
    after = _field(independent_state.get("after"), "events", default=None)
    if not isinstance(after, list):
        return []
    if isinstance(before, list) and after[: len(before)] == before:
        return list(after[len(before):])
    return list(after)


def _receipt_actions(receipt) -> list[dict]:
    actions = _field(receipt, "current_actions", "currentActions", default=None)
    if not isinstance(actions, list):
        return []
    return [action for action in actions if isinstance(action, dict)]


def _delivered_actions(receipt) -> list[dict]:
    return [action for action in _receipt_actions(receipt)
            if action.get("delivery") == "sent"]


def _receipt_status(receipt) -> str | None:
    status = receipt.get("status") if isinstance(receipt, dict) else None
    return status if isinstance(status, str) else None


def _receipt_has_system_verified_basis(receipt) -> tuple[bool, str]:
    """Whether the receipt carries a system-verified completion basis.

    Two independent shapes count: the per-action corroborated pair the runner
    judges accept (completion_policy=outcome_required with
    completion_basis=system_verified_outcome), and work order 02's
    receipt-level counters (system_verified_step_count covering every
    processed step, or all_processed_steps_system_verified).
    """
    for index, action in enumerate(_receipt_actions(receipt)):
        policy = _field(action, "completion_policy", "completionPolicy")
        basis = _field(action, "completion_basis", "completionBasis")
        if (policy, basis) in SYSTEM_VERIFIED_BASISES:
            return True, (f"current_actions[{index}] completion_policy={policy!r} "
                          f"completion_basis={basis!r}")
    verified = receipt.get("system_verified_step_count")
    processed = receipt.get("processed_step_count") or receipt.get("completed_step_count")
    if isinstance(verified, int) and isinstance(processed, int) and 0 < processed <= verified:
        return True, f"system_verified_step_count={verified} >= processed_step_count={processed}"
    if receipt.get("all_processed_steps_system_verified") is True:
        return True, "all_processed_steps_system_verified=true"
    return False, ("no system-verified basis: no action with completion_policy="
                   "'outcome_required' + completion_basis='system_verified_outcome', "
                   "and no receipt-level system_verified_step_count coverage")


def _completion_corroboration(action: dict) -> tuple[bool, str]:
    """Whether one delivered step's completion claim is corroborated."""
    delivery = action.get("delivery")
    if delivery != "sent":
        return False, (f"delivery={delivery!r}; only delivery=sent can support a "
                       "completed step")
    policy = _field(action, "completion_policy", "completionPolicy")
    basis = _field(action, "completion_basis", "completionBasis")
    if (policy, basis) in CORROBORATED_COMPLETION:
        return True, f"completion_policy={policy!r} with completion_basis={basis!r}"
    return False, (f"completion_policy={policy!r} with completion_basis={basis!r} "
                   "is not a corroborated pair")


def _action_signature(submission: dict | None) -> dict | None:
    """The comparable shape of one tool call: action + target + steps."""
    if submission is None:
        return None
    steps = submission.get("steps")
    if isinstance(steps, list):
        step_signatures = []
        for step in steps:
            if not isinstance(step, dict):
                return None
            step_signatures.append({
                "action": step.get("action"),
                "application": step.get("application"),
                "target_label": _field(step, "target_label", "targetLabel"),
                "region": step.get("region"),
            })
        return {"action": submission.get("action"), "application": submission.get("application"),
                "steps": step_signatures}
    return {
        "action": submission.get("action"),
        "application": submission.get("application"),
        "target_label": _field(submission, "target_label", "targetLabel"),
        "region": submission.get("region"),
    }


def _signature_differences(raw: dict, effective: dict) -> list[str]:
    differences: list[str] = []
    raw_steps = raw.get("steps") if isinstance(raw.get("steps"), list) else None
    effective_steps = effective.get("steps") if isinstance(effective.get("steps"), list) else None
    if (raw_steps is None) != (effective_steps is None):
        differences.append(f"steps present only on one side (raw={raw_steps is not None}, "
                           f"effective={effective_steps is not None})")
        return differences
    if raw_steps is not None and effective_steps is not None:
        if len(raw_steps) != len(effective_steps):
            differences.append(f"raw has {len(raw_steps)} step(s), effective plan has "
                               f"{len(effective_steps)}")
            return differences
        for index, (raw_step, effective_step) in enumerate(zip(raw_steps, effective_steps)):
            for key in ("action", "application", "target_label", "region"):
                if raw_step.get(key) != effective_step.get(key):
                    differences.append(f"step {index + 1} {key}: raw={raw_step.get(key)!r} "
                                       f"effective={effective_step.get(key)!r}")
        return differences
    for key in ("action", "application", "target_label", "region"):
        if raw.get(key) != effective.get(key):
            differences.append(f"{key}: raw={raw.get(key)!r} effective={effective.get(key)!r}")
    return differences


# ------------------------------------------------------------ criteria bodies


def _cancel_control_binding(receipt: dict) -> tuple[bool, str]:
    """Whether the cancel control was bound to the task/version it cancelled.

    Read from the receipt's own recorded flags: the receipt-level
    `control_binding_valid` and each recorded round's own flag, under either
    the snake_case or the camelCase spelling. A receipt that records no binding
    flag at all fails closed — the reviewer never assumes a binding the
    evidence does not state (runner scenario_judges.py `_continuity_control_binding`).
    """
    flags: list[tuple[str, bool]] = []
    recorded = _field(receipt, "control_binding_valid", "controlBindingValid")
    if isinstance(recorded, bool):
        flags.append(("her_receipt.control_binding_valid", recorded))
    rounds = receipt.get("rounds")
    if isinstance(rounds, list):
        for position, entry in enumerate(rounds):
            if not isinstance(entry, dict):
                continue
            flag = _field(entry, "control_binding_valid", "controlBindingValid")
            if isinstance(flag, bool):
                flags.append((f"her_receipt.rounds[{position}].control_binding_valid", flag))
    if not flags:
        return False, ("no control_binding_valid flag is recorded, and a cancel whose "
                       "control binding is not recorded fails closed")
    invalid = [where for where, flag in flags if not flag]
    if invalid:
        return False, "invalid control binding recorded at " + ", ".join(invalid)
    return True, ("recorded valid at " + ", ".join(where for where, _ in flags))


def _action_outcome_settled(action: dict) -> tuple[bool, str]:
    """Whether one delivered action's outcome is resolved rather than still open.

    A cancelled terminal state may only rest on a state the receipt actually
    resolved: the step's completion is corroborated (the completed contract's
    own policy/basis pair), the system verified the outcome, or the receipt
    records that the step did not run (it was cancelled / superseded / skipped).
    An outcome marker that still says unknown, pending or not_observed leaves
    the step mid-flight: that run belongs to the honest uncertain contract, not
    to the cancelled one.
    """
    corroborated, detail = _completion_corroboration(action)
    if corroborated:
        return True, f"corroborated step ({detail})"
    values = (
        (_field(action, "outcome_evidence", "outcomeEvidence", "outcome"), "outcome_evidence"),
        (_field(action, "completion_basis", "completionBasis"), "completion_basis"),
        (_field(action, "status", "action_status"), "status"),
    )
    recorded = [(value, name) for value, name in values if isinstance(value, str)]
    if not recorded:
        return False, ("delivery=sent action records no outcome field at all, so what "
                       "happened to the delivered step is unknown")
    for value, name in recorded:
        if value.strip().casefold() in UNRESOLVED_OUTCOME_MARKERS:
            return False, (f"{name}={value!r} still leaves the delivered step unresolved; "
                           f"that run belongs to the uncertain contract")
    for value, name in recorded:
        if value.strip().casefold() in SETTLED_NON_EXECUTION_OUTCOMES:
            return True, f"{name}={value!r} records that the delivered step did not run"
    for value, name in recorded:
        if value.strip().casefold() in VERIFIED_OUTCOME_MARKERS:
            return True, f"{name}={value!r} records the system-verified outcome of the step"
    return False, ("delivery=sent with "
                   + ", ".join(f"{name}={value!r}" for value, name in recorded)
                   + ": neither a corroborated/verified completion nor a recorded "
                     "non-execution, so the step's result is still ambiguous")


def _cancelled_side_effect_residue(scenario: dict, receipt: dict,
                                   sent: list[dict]) -> tuple[bool, str]:
    """Whether the independent /state carries no side effect the cancel left behind.

    Third condition of the cancelled contract: the independent state must be
    identical before and after the cancel, or every effect that survived must be
    explicitly allowed — named in an allowance the receipt records, or
    attributable to a delivered action whose outcome the receipt resolved.

    Unlike the delivery criterion above this never falls back to count
    correspondence: with counts alone one surviving allowed effect and one
    unexplained effect look like two explained ones, and telling them apart is
    exactly what a cancelled contract is for. A receipt whose fixture events
    cannot be matched to its actions must name the allowance explicitly.
    """
    state = scenario.get("independent_state")
    events = _new_events(state)
    before = _field(state, "before")
    after = _field(state, "after")
    if not events:
        if isinstance(before, dict) and isinstance(after, dict):
            if before == after:
                return True, ("independent /state is identical before and after the "
                              "cancel: no side-effect residue")
            return False, ("the independent state changed across the cancel without any "
                           f"new event being recorded: before={before!r} after={after!r}")
        return True, "the independent state records no new events across the cancel"
    allowed = _allowed_side_effects(receipt)
    resolved = [action for action in sent if _action_outcome_settled(action)[0]]
    labels = [_normalized_text(_field(action, "label", "target_label", "targetLabel",
                                      "expected_label", default=""))
              for action in resolved]
    residue: list = []
    for event in events:
        if event in allowed:
            continue
        if any(label and (label in _normalized_text(event)
                          or _normalized_text(event) in label) for label in labels):
            continue
        residue.append(event)
    if residue:
        return False, (f"new events {events!r} contain unexplained side-effect residue "
                       f"{residue!r}: neither named in the receipt's allowance {allowed!r} "
                       f"nor attributable to a delivered action whose outcome the receipt "
                       f"resolved")
    return True, (f"new events {events!r} are all explicitly allowed — each is named in "
                  f"the receipt's allowance or attributable to a delivered action whose "
                  f"outcome the receipt resolved")


def _allowed_side_effects(receipt: dict) -> list:
    """The effects a receipt explicitly records as allowed to survive the cancel."""
    allowed: list = []
    for name in ("allowed_side_effects", "allowed_new_events", "preserved_side_effects"):
        value = _field(receipt, name)
        if isinstance(value, list):
            allowed.extend(value)
    return allowed


def _cancelled_terminal_contract(scenario: dict, index: int, receipt: dict) -> Check:
    """The third terminal contract: a cancelled task can be a legitimate success.

    The real shape of a cancel is a progress question (no action) followed by
    取消: the task ends `cancelled`, nothing was delivered and the independent
    /state never moved. Accepting that shape is not a weakening — the recorded
    pass is only supported when all four conditions hold simultaneously:

    1. the control binding is recorded valid (the cancel was bound to the
       task/turn it cancelled) — a missing binding flag fails closed;
    2. no delivery=sent action is left un-disambiguated (every delivered step's
       outcome is resolved, or recorded as not carried out);
    3. no side-effect residue: the independent state is unchanged across the
       cancel, or every surviving effect is explicitly allowed;
    4. the final speech does not claim completion/confirmation of the cancelled
       task.

    Any missing condition is a FAIL, never a PASS.
    """
    path = f"scenarios[{index}]"
    problems: list[str] = []
    satisfied: list[str] = []

    bound, binding_detail = _cancel_control_binding(receipt)
    (satisfied if bound else problems).append(f"control binding {binding_detail}")

    sent = _delivered_actions(receipt)
    receipt_level_sent = receipt.get("delivery") == "sent"
    ambiguous = [position for position, action in enumerate(sent)
                 if not _action_outcome_settled(action)[0]]
    if ambiguous:
        problems.append(
            f"delivery=sent action(s) {ambiguous} remain un-disambiguated: "
            + "; ".join(_action_outcome_settled(sent[position])[1]
                        for position in ambiguous)
            + " — a cancelled terminal state may not rest on a step whose result is "
              "still open")
    elif receipt_level_sent and not sent:
        problems.append("the receipt claims delivery=sent at receipt level but records no "
                        "per-action outcome, so the delivered step cannot be disambiguated")
    elif sent:
        satisfied.append(f"all {len(sent)} delivery=sent action(s) carry a resolved outcome")
    else:
        satisfied.append("the receipt records no delivery=sent action, so the cancel "
                         "stopped the task before anything was delivered")

    residue_ok, residue_detail = _cancelled_side_effect_residue(scenario, receipt, sent)
    (satisfied if residue_ok else problems).append(f"side-effect residue: {residue_detail}")

    speech = " ".join(_speech_texts(scenario.get("final_speech")))
    claimed = [claim for claim in COMPLETION_CLAIMS if claim in speech]
    if claimed:
        problems.append(f"final speech claims completion {claimed} of a task that ended "
                        f"cancelled: {speech!r}")
    else:
        satisfied.append(f"final speech does not claim completion: {speech!r}")

    if problems:
        return Check("scenario.recorded_pass_is_supported", f"scenarios[{index}]",
                     f"{path}.her_receipt.status").fail(
            "the cancelled terminal contract is incomplete: " + "; ".join(problems))
    return Check("scenario.recorded_pass_is_supported", f"scenarios[{index}]",
                 f"{path}.her_receipt.status").pass_(
        "recorded pass is supported by the cancelled terminal contract (a cancelled "
        "task is a legitimate success): " + "; ".join(satisfied))


def _criterion_six_layers(scenario: dict, index: int) -> Check:
    path = f"scenarios[{index}]"
    missing = [layer for layer in SIX_LAYERS if scenario.get(layer) is None]
    if missing:
        return Check("scenario.six_layers_present", f"scenarios[{index}]", path).fail(
            f"recorded status {scenario.get('status')!r} is missing or null in layer(s) "
            f"{missing}; a claimed verdict with a missing evidence layer is a FAIL, "
            f"never a PASS"
        )
    return Check("scenario.six_layers_present", f"scenarios[{index}]", path).pass_(
        "all six evidence layers are present and non-null: " + ", ".join(SIX_LAYERS)
    )


def _criterion_sent_actions_have_side_effects(scenario: dict, index: int,
                                              receipt: dict) -> Check:
    path = f"scenarios[{index}]"
    sent = _delivered_actions(receipt)
    events = _new_events(scenario.get("independent_state"))
    # A receipt may claim delivery per action or, in shorter formats, once at
    # the receipt level; either way the independent state must show the effect.
    receipt_level_sent = receipt.get("delivery") == "sent"
    if not sent and not receipt_level_sent:
        return Check("scenario.sent_actions_have_independent_side_effects",
                     f"scenarios[{index}]", f"{path}.her_receipt.current_actions").na(
            "the receipt records no delivery=sent action, so no independent side effect "
            "is claimed by this criterion"
        )
    missing_identity = [position for position, action in enumerate(sent)
                        if not action.get("id") or not _field(action, "observationID", "observation_id")]
    if missing_identity:
        return Check("scenario.sent_actions_have_independent_side_effects",
                     f"scenarios[{index}]", f"{path}.her_receipt.current_actions").fail(
            f"delivered action(s) {missing_identity} carry no attempt id / observation id, "
            f"so the side effect cannot be tied to a receipt action"
        )
    if not events:
        claim = (f"{len(sent)} delivery=sent action(s)" if sent
                 else "a receipt-level delivery=sent")
        return Check("scenario.sent_actions_have_independent_side_effects",
                     f"scenarios[{index}]", f"{path}.independent_state.after.events").fail(
            f"the receipt claims {claim} but the independent state shows no new events "
            f"at all"
        )
    if sent and len(events) < len(sent):
        return Check("scenario.sent_actions_have_independent_side_effects",
                     f"scenarios[{index}]", f"{path}.independent_state.after.events").fail(
            f"the receipt claims {len(sent)} delivery=sent action(s) but the independent "
            f"state shows only {len(events)} new event(s): {events!r}"
        )
    # Prefer a label match onto a recorded event. Fixture event values are
    # stable control names, not UI labels, so a missing match is recorded as
    # the weaker (count) correspondence — never silently, never as a failure.
    labelled = 0
    for action in sent:
        label = _normalized_text(_field(action, "label", "target_label", "targetLabel",
                                        "expected_label", default=""))
        if label and any(label in _normalized_text(event) or _normalized_text(event) in label
                         for event in events):
            labelled += 1
    if sent:
        if labelled == len(sent):
            correspondence = "each delivered action's label matches an independent event"
        else:
            correspondence = (f"{labelled}/{len(sent)} delivered action label(s) match an "
                              f"independent event name; correspondence established by the "
                              f"event/action count")
        claim = f"{len(sent)} delivery=sent action(s) with matching attempt/observation ids"
    else:
        correspondence = "receipt-level delivery=sent with a non-empty independent sequence"
        claim = "a receipt-level delivery=sent"
    return Check("scenario.sent_actions_have_independent_side_effects",
                 f"scenarios[{index}]", f"{path}.independent_state.after.events").pass_(
        f"{claim} correspond to the independent event sequence {events!r} "
        f"({correspondence})"
    )


def _criterion_completion_claims(scenario: dict, index: int, receipt: dict) -> Check:
    path = f"scenarios[{index}]"
    speech = " ".join(_speech_texts(scenario.get("final_speech")))
    claims = [claim for claim in COMPLETION_CLAIMS if claim in speech]
    if not claims:
        return Check("scenario.completion_claims_have_system_verified_basis",
                     f"scenarios[{index}]", f"{path}.final_speech").pass_(
            "final speech makes no completion/confirmation claim"
        )
    corroborated, basis = _receipt_has_system_verified_basis(receipt)
    if not corroborated:
        return Check("scenario.completion_claims_have_system_verified_basis",
                     f"scenarios[{index}]", f"{path}.final_speech").fail(
            f"final speech claims {claims} (越权播报 / overclaiming speech) but the receipt "
            f"carries no system-verified basis: {basis}; work order 02's rule — a "
            f"confirmation may only be spoken for steps the system independently verified"
        )
    return Check("scenario.completion_claims_have_system_verified_basis",
                 f"scenarios[{index}]", f"{path}.final_speech").pass_(
        f"final speech claims {claims} and the receipt provides the system-verified "
        f"basis: {basis}"
    )


def _criterion_uncertainty_wording(scenario: dict, index: int, receipt: dict) -> Check:
    path = f"scenarios[{index}]"
    status = _receipt_status(receipt)
    if not (isinstance(status, str) and "uncertain" in status):
        return Check("scenario.uncertain_receipt_speech_states_uncertainty",
                     f"scenarios[{index}]", f"{path}.her_receipt.status").na(
            f"receipt status {status!r} is not an uncertain outcome"
        )
    speech = " ".join(_speech_texts(scenario.get("final_speech")))
    if not any(word in speech for word in UNCERTAINTY_WORDING):
        return Check("scenario.uncertain_receipt_speech_states_uncertainty",
                     f"scenarios[{index}]", f"{path}.final_speech").fail(
            f"receipt status {status!r} is uncertain but the final speech states no "
            f"uncertainty ({UNCERTAINTY_WORDING}): {speech!r}"
        )
    return Check("scenario.uncertain_receipt_speech_states_uncertainty",
                 f"scenarios[{index}]", f"{path}.final_speech").pass_(
        f"uncertain receipt is spoken as uncertainty: {speech!r}"
    )


def _criterion_arguments_match_plan(scenario: dict, index: int) -> Check:
    path = f"scenarios[{index}]"
    calls = scenario.get("model_tool_arguments")
    if not isinstance(calls, list) or not calls:
        return Check("scenario.model_tool_arguments_match_effective_plan",
                     f"scenarios[{index}]", f"{path}.model_tool_arguments").na(
            "no recorded model tool calls"
        )
    comparisons = 0
    for position, call in enumerate(calls):
        if not isinstance(call, dict):
            continue
        raw = _parse_arguments(_field(call, "arguments", "raw_arguments", "raw"))
        effective = _parse_arguments(_field(call, "normalized_arguments",
                                            "effective_arguments", "effective_plan",
                                            "normalization"))
        if raw is None or effective is None:
            continue
        comparisons += 1
        differences = _signature_differences(_action_signature(raw) or {},
                                             _action_signature(effective) or {})
        if differences:
            return Check("scenario.model_tool_arguments_match_effective_plan",
                         f"scenarios[{index}]",
                         f"{path}.model_tool_arguments[{position}]").fail(
                f"raw model arguments disagree with the effective plan: "
                + "; ".join(differences)
            )
    if comparisons == 0:
        return Check("scenario.model_tool_arguments_match_effective_plan",
                     f"scenarios[{index}]", f"{path}.model_tool_arguments").na(
            "the recorded tool calls carry no raw/normalization pair to compare"
        )
    return Check("scenario.model_tool_arguments_match_effective_plan",
                 f"scenarios[{index}]", f"{path}.model_tool_arguments").pass_(
        f"{comparisons} recorded tool call(s) agree with their effective plan"
    )


def _criterion_exit_records(scenario: dict, index: int) -> list[Check]:
    path = f"scenarios[{index}]"
    attempts = scenario.get("attempts")
    if not isinstance(attempts, list) or not attempts:
        return [Check("scenario.exit_record_derived_returncode_has_artifact",
                      f"scenarios[{index}]", f"{path}.attempts").na(
            "the package records no per-attempt exit records"
        )]
    checks: list[Check] = []
    for position, attempt in enumerate(attempts):
        record = _json_object(_field(attempt, "process_exit", "exit_record"))
        where = f"{path}.attempts[{position}].process_exit"
        if record is None:
            checks.append(Check("scenario.exit_record_derived_returncode_has_artifact",
                                f"scenarios[{index}]", where).na(
                "attempt records no process_exit object"))
            continue
        returncode = record.get("returncode")
        basis = record.get("returncode_basis")
        if record.get("timed_out"):
            checks.append(Check("scenario.exit_record_derived_returncode_has_artifact",
                                f"scenarios[{index}]", where).fail(
                "the probe process did not exit on its own and had to be stopped"))
            continue
        if not record.get("self_exited"):
            checks.append(Check("scenario.exit_record_derived_returncode_has_artifact",
                                f"scenarios[{index}]", where).fail(
                "the probe process did not exit by itself"))
            continue
        if returncode != 0:
            checks.append(Check("scenario.exit_record_derived_returncode_has_artifact",
                                f"scenarios[{index}]", where).fail(
                f"no usable exit status: returncode={returncode!r}, "
                f"returncode_basis={basis!r}"))
            continue
        if basis and str(basis).startswith("derived:"):
            if record.get("report_artifact_present") is not True:
                checks.append(Check("scenario.exit_record_derived_returncode_has_artifact",
                                    f"scenarios[{index}]", where).fail(
                    f"returncode_basis={basis!r} derives the exit status from the probe's "
                    f"report artifact, but report_artifact_present="
                    f"{record.get('report_artifact_present')!r}"))
                continue
            checks.append(Check("scenario.exit_record_derived_returncode_has_artifact",
                                f"scenarios[{index}]", where).pass_(
                f"derived exit status 0 is backed by report_artifact_present=true: {basis}"))
            continue
        checks.append(Check("scenario.exit_record_derived_returncode_has_artifact",
                            f"scenarios[{index}]", where).pass_(
            f"probe self-exited with the OS-observable returncode={returncode} "
            f"(basis={basis!r})"))
    return checks


def _criterion_recorded_pass_is_supported(scenario: dict, index: int,
                                          receipt: dict, checks: list[Check]) -> Check:
    """The positive criterion: the layers must prove the recorded PASS.

    A recorded pass requires every integrity criterion above to hold and a
    receipt outcome the recorded verdict can rest on. Three terminal contracts
    are accepted:

    * `completed` with a corroborated completion basis per delivered step (work
      order 03R item 8);
    * an honest uncertain contract — uncertain receipt, uncertainty speech and
      an independent side effect (work order 04's scenario U contract);
    * `cancelled` with the cancel contract of `_cancelled_terminal_contract`:
      a valid control binding, no un-disambiguated delivered action, no
      side-effect residue and no completion claim.

    Anything else — including a `cancelled` receipt missing any of those
    conditions — is a FAIL, never a PASS.
    """
    path = f"scenarios[{index}]"
    failed = [check for check in checks if check.failed]
    if failed:
        return Check("scenario.recorded_pass_is_supported", f"scenarios[{index}]",
                     f"{path}").fail(
            "the recorded PASS rests on failing criteria: "
            + ", ".join(check.criterion_id for check in failed)
        )
    recorded = scenario.get("status")
    if recorded != "passed":
        return Check("scenario.recorded_pass_is_supported", f"scenarios[{index}]",
                     f"{path}.status").fail(
            f"the scenario does not claim a pass (status={recorded!r}), so the evidence "
            f"cannot prove acceptance"
        )
    status = _receipt_status(receipt)
    if status == "completed":
        sent = _delivered_actions(receipt)
        uncorroborated = [position for position, action in enumerate(sent)
                          if not _completion_corroboration(action)[0]]
        if uncorroborated:
            return Check("scenario.recorded_pass_is_supported", f"scenarios[{index}]",
                         f"{path}.her_receipt.current_actions").fail(
                f"receipt claims completed but delivered step(s) {uncorroborated} lack a "
                f"policy-licensed completion basis: "
                + "; ".join(_completion_corroboration(action)[1]
                            for action in (sent[position] for position in uncorroborated))
            )
        return Check("scenario.recorded_pass_is_supported", f"scenarios[{index}]",
                     f"{path}.her_receipt.status").pass_(
            "recorded pass is supported: completed receipt with corroborated completion "
            "basis per delivered step and matching independent side effects"
        )
    if isinstance(status, str) and "uncertain" in status:
        return Check("scenario.recorded_pass_is_supported", f"scenarios[{index}]",
                     f"{path}.her_receipt.status").pass_(
            f"recorded pass is supported by the honest uncertain contract: receipt "
            f"status={status!r} with uncertainty speech and independent side-effect "
            f"evidence"
        )
    if status == CANCELLED_STATUS:
        return _cancelled_terminal_contract(scenario, index, receipt)
    return Check("scenario.recorded_pass_is_supported", f"scenarios[{index}]",
                 f"{path}.her_receipt.status").fail(
        f"a recorded pass cannot rest on receipt status {status!r}"
    )


# ------------------------------------------------------------------ reviewing


def review_scenario(scenario: dict, index: int) -> dict:
    """Review one scenario entry; returns its derived verdict and criteria."""
    label = scenario.get("name") if isinstance(scenario.get("name"), str) else f"#{index}"
    checks: list[Check] = []
    recorded = scenario.get("status")

    if recorded in NON_EXECUTED_STATUSES:
        # Nothing was executed, so no layer is claimed: not a failure by
        # itself. --strict is what turns these into "not passed".
        checks.append(Check("scenario.six_layers_present", f"scenarios[{index}]",
                            f"scenarios[{index}]").skip(
            f"status={recorded!r}: the scenario never ran, so no six-layer evidence "
            f"is claimed (strict mode counts this as not passed)"))
        return {"name": label, "recorded_status": recorded, "derived": recorded,
                "checks": [check.to_dict() for check in checks]}

    if recorded not in RECORDED_STATUSES:
        checks.append(Check("scenario.recorded_status_known", f"scenarios[{index}]",
                            f"scenarios[{index}].status").fail(
            f"unknown recorded status {recorded!r}; expected one of {list(RECORDED_STATUSES)}"))

    checks.append(_criterion_six_layers(scenario, index))
    receipt = _json_object(scenario.get("her_receipt")) or {}

    if all(scenario.get(layer) is not None for layer in ("her_receipt", "independent_state")):
        checks.append(_criterion_sent_actions_have_side_effects(scenario, index, receipt))
    else:
        checks.append(Check("scenario.sent_actions_have_independent_side_effects",
                            f"scenarios[{index}]", f"scenarios[{index}].her_receipt").skip(
            "receipt or independent state layer is absent"))
    if scenario.get("her_receipt") is not None:
        checks.append(_criterion_completion_claims(scenario, index, receipt))
        checks.append(_criterion_uncertainty_wording(scenario, index, receipt))
        checks.append(_criterion_recorded_pass_is_supported(
            scenario, index, receipt,
            [check for check in checks
             if check.criterion_id != "scenario.recorded_pass_is_supported"]))
    checks.append(_criterion_arguments_match_plan(scenario, index))
    checks.extend(_criterion_exit_records(scenario, index))

    if any(check.failed for check in checks):
        derived = "failed"
    elif recorded == "passed":
        derived = "passed"
    else:
        derived = "failed"
    return {"name": label, "recorded_status": recorded, "derived": derived,
            "checks": [check.to_dict() for check in checks]}


def review_document(document: dict, source: str, strict: bool = False) -> dict:
    """Re-derive the acceptance verdict of one result.json document."""
    package_checks: list[Check] = []

    scenarios = document.get("scenarios")
    if not isinstance(scenarios, list) or not scenarios:
        package_checks.append(Check("package.scenarios_list_present", "package",
                                    "scenarios").fail(
            "result.json must contain a non-empty scenarios[] list"))
        scenarios = []
    else:
        package_checks.append(Check("package.scenarios_list_present", "package",
                                    "scenarios").pass_(
            f"{len(scenarios)} scenario(s) recorded"))

    if "passed" in document and not isinstance(document.get("passed"), bool):
        package_checks.append(Check("package.reported_passed_is_boolean", "package",
                                    "passed").fail("'passed' must be a boolean"))
    if "exit_code" in document and not isinstance(document.get("exit_code"), int):
        package_checks.append(Check("package.reported_exit_code_is_integer", "package",
                                    "exit_code").fail("'exit_code' must be an integer"))
    mode = document.get("mode")
    if mode is not None and mode not in ("full", "dry_run", "self_test"):
        package_checks.append(Check("package.mode_is_known", "package", "mode").fail(
            f"'mode' must be full, dry_run or self_test, not {mode!r}"))
    if mode == "dry_run" and document.get("proof") is True:
        package_checks.append(Check("package.dry_run_is_not_proof", "package", "proof").fail(
            "a dry-run package must never be marked as proof"))

    scenario_reviews = [review_scenario(scenario, index)
                        for index, scenario in enumerate(scenarios)
                        if isinstance(scenario, dict)]
    for index, scenario in enumerate(scenarios):
        if not isinstance(scenario, dict):
            package_checks.append(Check("package.scenarios_are_objects", "package",
                                        f"scenarios[{index}]").fail(
                "scenario entry is not an object"))

    all_checks = package_checks + [
        Check.from_dict(entry)
        for review in scenario_reviews for entry in review["checks"]
    ]

    any_failed = any(check.failed for check in all_checks)
    pending_like = [review["name"] for review in scenario_reviews
                    if review["derived"] in NON_EXECUTED_STATUSES]
    failed_scenarios = [review["name"] for review in scenario_reviews
                        if review["derived"] == "failed"]
    derived_passed = bool(scenario_reviews) and not failed_scenarios and not pending_like
    reported_passed = document.get("passed")
    if "passed" in document:
        check = Check("package.reported_passed_matches_derived", "package", "passed")
        if derived_passed and reported_passed is not True:
            check.fail("the evidence re-derives every scenario as passed, but result.json "
                       "records passed=false — the recording understates the evidence")
        elif not derived_passed and reported_passed is True:
            check.fail("result.json records passed=true, but the independently re-derived "
                       f"verdict fails scenario(s) {failed_scenarios or pending_like} — the "
                       f"product's own passed field cannot be trusted")
        else:
            check.pass_(f"reported passed={reported_passed!r} matches the re-derived verdict")
        package_checks.append(check)
        all_checks.append(check)

    any_failed = any(check.failed for check in all_checks)
    if any_failed:
        verdict = "fail"
        exit_code = 1
    elif strict and pending_like:
        verdict = "fail"
        exit_code = 1
    else:
        verdict = "pass"
        exit_code = 0

    summary_bits = [f"{sum(1 for check in all_checks if check.status == 'pass')} passed",
                    f"{sum(1 for check in all_checks if check.failed)} failed"]
    if pending_like:
        summary_bits.append(f"{len(pending_like)} pending/blocked scenario(s)"
                            + (" counted as not passed (strict)" if strict else ""))
    return {
        "input": source,
        "mode": document.get("mode"),
        "proof": document.get("proof"),
        "recorded_passed": document.get("passed"),
        "strict": strict,
        "verdict": verdict,
        "exit_code": exit_code,
        "criteria": [check.to_dict() for check in all_checks],
        "scenarios": scenario_reviews,
        "summary": "; ".join(summary_bits),
    }


def render_human(review: dict) -> str:
    lines: list[str] = []
    lines.append("Independent acceptance evidence review")
    lines.append(f"  input:           {review['input']}")
    lines.append(f"  mode/proof:      {review.get('mode')!r} / {review.get('proof')!r}")
    lines.append(f"  recorded passed: {review.get('recorded_passed')!r}"
                 f"   strict: {review['strict']}")
    lines.append("")
    for review_entry in review["scenarios"]:
        lines.append(f"[scenario] {review_entry['name']} — recorded: "
                     f"{review_entry['recorded_status']!r}, derived: "
                     f"{review_entry['derived']!r}")
        for entry in review_entry["checks"]:
            marker = entry["status"].upper()
            lines.append(f"  [{marker}] {entry['criterion']}")
            if entry["detail"]:
                lines.append(f"         {entry['detail']}")
            lines.append(f"         evidence: {entry['evidence_path']}")
        lines.append("")
    lines.append(f"criteria: {review['summary']}")
    lines.append(f"verdict:  {review['verdict'].upper()} (exit code {review['exit_code']})")
    return "\n".join(lines)


def load_document(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise EvidenceInputError(f"cannot read evidence package {path}: {error}") from error


class EvidenceInputError(RuntimeError):
    pass


def resolve_target(target: str) -> list[Path]:
    path = Path(target)
    if path.is_file():
        return [path]
    if path.is_dir():
        direct = path / "result.json"
        if direct.is_file():
            return [direct]
        nested = sorted(path.glob("*/result.json"))
        if nested:
            return nested
        raise EvidenceInputError(f"no result.json found in directory {path}")
    raise EvidenceInputError(f"no such file or directory: {path}")


SELF_TEST_EXPECTATIONS = (
    ("good", "pass", 0),
    ("missing-layer", "fail", 1),
    ("overclaiming-speech", "fail", 1),
    ("cancelled-contract-good", "pass", 0),
    ("cancelled-but-claimed-complete", "fail", 1),
)


def self_test() -> int:
    """Replay the testdata packages offline and assert the expected verdicts.

    This exercises the reviewer, exactly like work order 02's
    verify-report.py --mock-self-test: it says nothing about any product.
    """
    testdata = Path(__file__).resolve().parent / "testdata"
    failures: list[str] = []
    for sample, expected_verdict, expected_exit in SELF_TEST_EXPECTATIONS:
        path = testdata / sample / "result.json"
        if not path.is_file():
            failures.append(f"{sample}: missing testdata package {path}")
            continue
        review = review_document(load_document(path), str(path), strict=False)
        observed = (review["verdict"], review["exit_code"])
        marker = "ok" if observed == (expected_verdict, expected_exit) else "MISMATCH"
        print(f"[{marker}] {sample}: verdict={review['verdict']} "
              f"exit_code={review['exit_code']} (expected {expected_verdict}/"
              f"{expected_exit})")
        for entry in review["criteria"]:
            if entry["status"] == "fail":
                print(f"       failing criterion: {entry['criterion']} — {entry['detail']}")
        if observed != (expected_verdict, expected_exit):
            failures.append(f"{sample}: expected {expected_verdict}/{expected_exit}, "
                            f"observed {review['verdict']}/{review['exit_code']}")

    # Strict semantics: a pending/blocked package is not a failure on its own,
    # but --strict must count it as not passed.
    pending_package = {
        "scenarios": [{"name": "unknown_delivery_fault_recovery",
                       "status": "pending_integrator_run"}],
        "mode": "full", "proof": False, "passed": False, "exit_code": 1,
    }
    lenient = review_document(pending_package, "<in-memory pending package>", strict=False)
    strict_review = review_document(pending_package, "<in-memory pending package>",
                                    strict=True)
    lenient_ok = (lenient["verdict"], lenient["exit_code"]) == ("pass", 0)
    strict_ok = (strict_review["verdict"], strict_review["exit_code"]) == ("fail", 1)
    print(f"[{'ok' if lenient_ok else 'MISMATCH'}] pending package without --strict: "
          f"{lenient['verdict']}/{lenient['exit_code']} (expected pass/0)")
    print(f"[{'ok' if strict_ok else 'MISMATCH'}] pending package with --strict: "
          f"{strict_review['verdict']}/{strict_review['exit_code']} (expected fail/1)")
    if not lenient_ok:
        failures.append("strict semantics: a pending package must review as pass without "
                        "--strict")
    if not strict_ok:
        failures.append("strict semantics: a pending package must review as fail with "
                        "--strict")

    if failures:
        print("\nreviewer self-test: FAIL")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("\nreviewer self-test: PASS — the testdata verdicts and strict semantics "
          "behave as specified (this checks the reviewer, not any product)")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Independent review of Her acceptance evidence packages.")
    parser.add_argument("target", nargs="?",
                        help="result.json file, or a directory containing one")
    parser.add_argument("--strict", action="store_true",
                        help="count pending_integrator_run / blocked scenarios as not passed")
    parser.add_argument("--json-out", metavar="PATH",
                        help="also write the machine-readable review JSON to PATH")
    parser.add_argument("--self-test", action="store_true",
                        help="replay scripts/acceptance/testdata and assert the expected "
                             "verdicts (offline)")
    options = parser.parse_args(argv)

    if options.self_test:
        return self_test()

    if not options.target:
        parser.error("a result.json path (or a directory containing one) is required "
                     "unless --self-test is used")
    try:
        targets = resolve_target(options.target)
        reviews = [review_document(load_document(path), str(path), strict=options.strict)
                   for path in targets]
    except EvidenceInputError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    for review in reviews:
        print(render_human(review))
        print("")
        print(json.dumps(review, ensure_ascii=False, indent=2))
        print("")
    if options.json_out:
        out_path = Path(options.json_out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(
            reviews[0] if len(reviews) == 1 else {"inputs": reviews},
            ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    exit_code = max((review["exit_code"] for review in reviews), default=2)
    print(f"reviewed {len(reviews)} package(s); exit code {exit_code}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

"""Runner-side fault injection primitives for the Her E2E acceptance run.

These are the three real faults a scenario needs in order to test *recovery*
rather than the happy path. All of them act only on things this runner created
in the current run:

  * `kill_fixture_after(fixture, seconds)`  - the fixture child dies mid-scenario.
  * `delay_state_after(fixture, seconds)`   - the runner's /state readback goes stale.
  * `navigate_page_away(...)`                - the controlled page is navigated away.

Ownership invariant (mirrors `process_control`): a fault is only ever armed
against a PID that is registered in this run's `OwnedProcessRegistry`, i.e. a
child this runner spawned. Anything else is *refused* - the primitive returns a
fault record with `armed: False` and a refusal reason instead of signalling a
process it does not own. The user's own Her instance is never a target.

Every primitive returns a plain, JSON-serializable fault record that a scenario
can drop straight into its evidence payload:

    {"kind": ..., "target_pid_or_url": ..., "armed_at": ..., ...}

`delay_state_after` mechanism: the fixture page (tools/voice-acceptance/fixture.py)
has no fault hook and is shared tooling that must not be edited, and there is no
way to make that server go stale without changing what the *app and browser*
see. So the fault is injected on the runner's own readback channel: the fixture
server keeps serving live state, while this runner's `FixtureServer.state()` is
temporarily hooked to answer with the snapshot taken at arm time. That is exactly
the channel every judge and every evidence snapshot reads, so the injected
divergence (page says X, /state readback says stale-X) is real for everything
that consumes it, and the record proves it was injected rather than observed.

`navigate_page_away` is a *foreground* action: it steals focus from whatever the
operator is doing. It is therefore defined but never called by any scenario - the
manual runner or the integration owner runs it inside an authorized window, and
the call requires both `confirm=True` and a non-empty `authorized_by`.
"""
from __future__ import annotations

import datetime
import json
import threading
import time
from pathlib import Path
from typing import Any

from . import paths
from .fixture_page import FixtureServer
from .launch_services import run_open_command
from .process_control import OwnedProcess, OwnedProcessRegistry, terminate_owned_process

FAULT_RECORD_SCHEMA_VERSION = 1

MAX_DELAY_SECONDS = 900.0
DEFAULT_KILL_GRACE_SECONDS = 5.0
DEFAULT_NAVIGATE_URL = "about:blank"
NAVIGATE_TIMEOUT_SECONDS = 20.0

# Live timers are kept here so they are never garbage collected before firing,
# and so `disarm_fault` can find and cancel them.
_TIMERS: list[tuple[dict, threading.Timer]] = []


class FaultRefused(RuntimeError):
    """A fault could not be armed. The refusal reason is on the returned record."""


def _now_iso() -> str:
    return datetime.datetime.now(datetime.UTC).isoformat()


# ------------------------------------------------------------------- resolution


def _resolve_owned_fixture(fixture: Any, registry: Any = None):
    """Resolve the runner-owned fixture process, or raise `FaultRefused`.

    Accepted: a `FixtureServer` (the run's fixture page), an `OwnedProcess` that
    a registry handed out, or the `OwnedProcessRegistry` itself (the running
    child labelled as the fixture). Anything else - a bare `Popen`, a PID int, a
    process name - is refused, because ownership cannot be proven.
    """
    candidate = fixture
    if isinstance(candidate, FixtureServer):
        owned = candidate.owned
        if owned is None:
            raise FaultRefused("the fixture server was never started, so there is no PID to target")
        candidate = owned
    if isinstance(candidate, OwnedProcessRegistry):
        for owned in candidate.running():
            if "fixture" in owned.label:
                candidate = owned
                break
        else:
            raise FaultRefused("no running fixture child is registered in this run's registry")
    if not isinstance(candidate, OwnedProcess):
        raise FaultRefused(
            f"{type(candidate).__name__} is not a process this runner owns; a fault may only be "
            "armed against a registry-owned child (FixtureServer, OwnedProcess or "
            "OwnedProcessRegistry)"
        )
    if registry is not None and isinstance(registry, OwnedProcessRegistry):
        if all(owned is not candidate for owned in registry.all()):
            raise FaultRefused("the resolved process is not registered in the given registry")
    return candidate


def fixture_pid(fixture: Any) -> int | None:
    """Best-effort PID for a fault record; None when it cannot be resolved."""
    try:
        return int(_resolve_owned_fixture(fixture).pid)
    except (FaultRefused, ValueError, TypeError):
        return None


def _validate_delay(seconds: Any) -> float:
    if not isinstance(seconds, (int, float)) or isinstance(seconds, bool):
        raise FaultRefused(f"seconds must be a number, got {seconds!r}")
    if seconds < 0:
        raise FaultRefused("seconds must not be negative")
    if seconds > MAX_DELAY_SECONDS:
        raise FaultRefused(f"seconds must not exceed {MAX_DELAY_SECONDS:.0f}")
    return float(seconds)


def _refused(kind: str, target: Any, reason: str, extra: dict | None = None) -> dict:
    record = {
        "schema_version": FAULT_RECORD_SCHEMA_VERSION,
        "kind": kind,
        "target_pid_or_url": target,
        "armed_at": _now_iso(),
        "armed": False,
        "refusal": reason,
    }
    if extra:
        record.update(extra)
    return record


# --------------------------------------------------------- 1. kill the fixture


def _fire_kill(record: dict, owned: Any, grace_seconds: float) -> None:
    if record.get("disarmed"):
        record["outcome"] = {"terminated": False, "reason": "disarmed before firing"}
        return
    already = owned.poll()
    if already is not None:
        record["outcome"] = {"terminated": False, "self_exited": True, "returncode": already,
                             "reason": "process had already exited when the fault fired"}
        return
    outcome = terminate_owned_process(owned, grace_seconds=grace_seconds)
    outcome["reason"] = "terminated by kill_fixture_after"
    record["outcome"] = outcome


def kill_fixture_after(fixture: Any, seconds: Any, registry: Any = None,
                       reason: str = "", grace_seconds: float = DEFAULT_KILL_GRACE_SECONDS) -> dict:
    """Terminate this run's fixture child `seconds` from now.

    The target must be a process this runner owns and registered. The signal is
    the same one `process_control` uses at teardown (SIGTERM, bounded grace,
    then SIGKILL), so a scenario can prove the runner's recovery path against the
    real thing: a mid-scenario loss of the disposable page.
    """
    try:
        owned = _resolve_owned_fixture(fixture, registry)
        delay = _validate_delay(seconds)
    except FaultRefused as refusal:
        return _refused("fixture_kill_after", fixture_pid(fixture), str(refusal))

    armed_at = time.time()
    record = {
        "schema_version": FAULT_RECORD_SCHEMA_VERSION,
        "kind": "fixture_kill_after",
        "target_pid_or_url": int(owned.pid),
        "target_label": owned.label,
        "armed_at": _now_iso(),
        "armed_at_epoch": armed_at,
        "fires_at_epoch": armed_at + delay,
        "delay_seconds": delay,
        "armed": True,
        "disarmed": False,
        "ownership": "runner-registry",
        "reason": reason or None,
        "grace_seconds": grace_seconds,
        "outcome": None,
    }
    timer = threading.Timer(delay, _fire_kill, args=(record, owned, grace_seconds))
    timer.daemon = True
    _TIMERS.append((record, timer))
    timer.start()
    return record


# ------------------------------------------------- 2. stale /state readback


def _delayed_state_factory(server: FixtureServer, record: dict):
    """Build the hooked `state()` that serves the armed snapshot until expiry."""
    original = server.state
    baseline = record["stale_snapshot"]

    def delayed_state() -> dict:
        remaining = record["expires_at_epoch"] - time.time()
        if remaining > 0 and not record.get("disarmed"):
            record["stale_reads"] += 1
            record["last_stale_read_at"] = _now_iso()
            record["remaining_seconds"] = round(remaining, 3)
            return dict(baseline)
        server.state = original  # restore on the first live read after expiry
        record["restored_at"] = _now_iso()
        live = original()
        if record.get("live_state_after_expiry") is None:
            record["live_state_after_expiry"] = live
            record["diverged_from_live"] = _state_divergence(baseline, live)
        record["reads_after_expiry"] = record.get("reads_after_expiry", 0) + 1
        return live

    return delayed_state


def _state_divergence(before: dict | None, after: dict | None) -> list[str]:
    """Human-readable keys whose value differs between two /state snapshots."""
    if not isinstance(before, dict) or not isinstance(after, dict):
        return []
    changed = []
    for key in sorted(set(before) | set(after)):
        if before.get(key) != after.get(key):
            changed.append(key)
    return changed


def delay_state_after(fixture: Any, seconds: Any, reason: str = "") -> dict:
    """Make this runner's `GET /state` readback return stale values for `seconds`.

    See the module docstring for why the fault lives on the runner's readback
    channel rather than inside the fixture server. The live server keeps
    advancing; the record captures both the stale snapshot that was served and
    the live state seen once the window closed, plus which keys diverged.
    """
    try:
        delay = _validate_delay(seconds)
    except FaultRefused as refusal:
        return _refused("state_delay_after", None, str(refusal))
    if not isinstance(fixture, FixtureServer):
        return _refused("state_delay_after", None,
                        f"{type(fixture).__name__} is not a FixtureServer; the /state readback "
                        "channel can only be hooked on the run's own fixture server")
    if fixture.owned is None:
        return _refused("state_delay_after", None, "the fixture server was never started")
    try:
        baseline = fixture.state()
    except Exception as error:  # noqa: BLE001 - any read failure is a refusal, not a crash
        return _refused("state_delay_after", int(fixture.owned.pid),
                        f"the live /state snapshot could not be read: {error}")
    if not isinstance(baseline, dict):
        return _refused("state_delay_after", int(fixture.owned.pid),
                        "/state did not answer with a JSON object")

    armed_at = time.time()
    record = {
        "schema_version": FAULT_RECORD_SCHEMA_VERSION,
        "kind": "state_delay_after",
        "target_pid_or_url": int(fixture.owned.pid),
        "target_url": fixture.base_url,
        "armed_at": _now_iso(),
        "armed_at_epoch": armed_at,
        "expires_at_epoch": armed_at + delay,
        "expires_at": datetime.datetime.fromtimestamp(
            armed_at + delay, datetime.UTC).isoformat(),
        "delay_seconds": delay,
        "armed": True,
        "disarmed": False,
        "ownership": "runner-readback-channel",
        "mechanism": ("FixtureServer.state() is hooked on this run's fixture server instance; the "
                      "fixture server itself keeps serving live state and is not modified"),
        "reason": reason or None,
        "stale_snapshot": dict(baseline),
        "stale_reads": 0,
        "last_stale_read_at": None,
        "reads_after_expiry": 0,
        "live_state_after_expiry": None,
        "diverged_from_live": [],
        "restored_at": None,
    }
    fixture.state = _delayed_state_factory(fixture, record)  # type: ignore[method-assign]
    return record


def restore_state_delay(fixture: Any, record: dict | None = None) -> dict:
    """Drop a `state_delay_after` hook early. The live snapshot is restored."""
    if not isinstance(fixture, FixtureServer):
        return {"restored": False, "reason": f"{type(fixture).__name__} is not a FixtureServer"}
    if record is not None:
        record["disarmed"] = True
        record["disarmed_at"] = _now_iso()
    hooked = getattr(fixture, "state", None)
    if callable(hooked) and str(getattr(hooked, "__name__", "")).startswith("delayed_state"):
        # `delayed_state` restores the original on its next call; force one now.
        try:
            fixture.state()
        except Exception as error:  # noqa: BLE001 - a failing live read must not hide the restore
            if record is not None:
                record["restore_error"] = f"{type(error).__name__}: {error}"
        return {"restored": True, "record": record}
    if record is not None and record.get("restored_at"):
        # The window already closed on a live read, which restored the original.
        return {"restored": True, "already_restored": True, "restored_at": record["restored_at"]}
    return {"restored": False, "reason": "no active state-delay hook on this fixture server"}


# ------------------------------------------------- 3. navigate the page away


def plan_navigate_away(url: str = DEFAULT_NAVIGATE_URL,
                       browser: str | None = None) -> dict:
    """Build the plan for navigating the controlled page away. Never executes."""
    browser = browser or paths.CONTROLLED_BROWSER_BUNDLE_IDENTIFIER
    return {
        "kind": "page_navigate_away",
        "target_pid_or_url": url,
        "browser_bundle_id": browser,
        "command": ["open", "-b", browser, url],
        "armed_at": _now_iso(),
        "armed": False,
        "requires_foreground": True,
        "note": ("Foreground action: it steals focus from whatever the operator is doing. Defined "
                 "here but never invoked by a scenario; the manual runner or the integration owner "
                 "calls navigate_page_away(confirm=True, authorized_by=...) inside an authorized "
                 "window."),
    }


def navigate_page_away(confirm: bool = False, authorized_by: str | None = None,
                       url: str = DEFAULT_NAVIGATE_URL, browser: str | None = None,
                       timeout_seconds: float = NAVIGATE_TIMEOUT_SECONDS) -> dict:
    """Navigate the controlled page away through LaunchServices `open`.

    Deliberately inert unless a human opts in: it needs `confirm=True` *and* a
    non-empty `authorized_by`, because it changes the desktop state in front of
    the operator. Without both it returns the plan so a scenario can record the
    intent without performing it. It navigates only the local controlled browser
    to `about:blank`; it never touches the product under test.
    """
    record = plan_navigate_away(url=url, browser=browser)
    if not confirm:
        record["refusal"] = ("confirm=True is required: this is a foreground action and no scenario "
                             "may call it automatically")
        return record
    if not isinstance(authorized_by, str) or not authorized_by.strip():
        record["refusal"] = ("authorized_by is required: a named human must own this foreground "
                             "action inside an authorized window")
        return record
    record["authorized_by"] = authorized_by.strip()
    record["armed"] = True
    record["fired_at"] = _now_iso()
    opened = run_open_command(record["command"])
    record["open_returncode"] = opened.get("returncode")
    record["open_stderr"] = (opened.get("stderr") or "").strip()[:400]
    record["open_error"] = opened.get("error")
    record["navigated_away"] = opened.get("returncode") == 0
    return record


# ---------------------------------------------------------------------- catalogue


def disarm_fault(record: dict) -> dict:
    """Cancel a still-pending fault so it never fires."""
    if not isinstance(record, dict):
        return {"disarmed": False, "reason": "not a fault record"}
    if record.get("kind") == "fixture_kill_after" and record.get("armed"):
        record["disarmed"] = True
        record["disarmed_at"] = _now_iso()
        for entry_record, timer in list(_TIMERS):
            if entry_record is record:
                timer.cancel()
                _TIMERS.remove((entry_record, timer))
                return {"disarmed": True, "kind": record["kind"]}
    return {"disarmed": bool(record.get("disarmed")), "kind": record.get("kind"),
            "reason": "nothing pending to disarm"}


def describe_primitives() -> list[dict]:
    """The primitive catalogue: what each fault does and what it may touch."""
    return [
        {"kind": "fixture_kill_after", "callable": "kill_fixture_after(fixture, seconds)",
         "target": "this run's registry-owned fixture child",
         "effect": "SIGTERM (bounded grace, then SIGKILL) after `seconds`",
         "ownership": "runner-registry",
         "auto_callable_by_scenario": True,
         "foreground": False},
        {"kind": "state_delay_after", "callable": "delay_state_after(fixture, seconds)",
         "target": "this run's FixtureServer /state readback channel",
         "effect": ("the runner's fixture.state() answers with the snapshot taken at arm time "
                    "until `seconds` elapse; the fixture server itself is unchanged"),
         "ownership": "runner-readback-channel",
         "auto_callable_by_scenario": True,
         "foreground": False},
        {"kind": "page_navigate_away", "callable": "navigate_page_away(confirm=True, authorized_by=...)",
         "target": f"{paths.CONTROLLED_BROWSER_BUNDLE_IDENTIFIER} navigating to about:blank",
         "effect": "LaunchServices `open` brings the browser forward on about:blank",
         "ownership": "foreground action owned by the manual/integration owner",
         "auto_callable_by_scenario": False,
         "foreground": True},
    ]


def armed_faults(records: list[dict]) -> list[dict]:
    """Project fault records into the shape an evidence payload should carry."""
    projected = []
    for record in records:
        if not isinstance(record, dict):
            continue
        if record.get("kind") == "fixture_kill_after":
            fired = record.get("outcome") is not None
        elif record.get("kind") == "state_delay_after":
            fired = record.get("stale_reads", 0) > 0
        else:
            fired = bool(record.get("navigated_away"))
        projected.append({
            "kind": record.get("kind"),
            "target_pid_or_url": record.get("target_pid_or_url"),
            "armed_at": record.get("armed_at"),
            "armed": record.get("armed"),
            "fired": fired,
        })
    return projected


def write_fault_log(records: list[dict], path: Path) -> Path:
    """Persist the fault records next to a scenario's other artifacts."""
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": FAULT_RECORD_SCHEMA_VERSION,
        "recorded_at": _now_iso(),
        "primitives": describe_primitives(),
        "faults": [record for record in records if isinstance(record, dict)],
    }
    path.write_text(json_dumps(payload), encoding="utf-8")
    return path


def json_dumps(payload: Any) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=1) + "\n"

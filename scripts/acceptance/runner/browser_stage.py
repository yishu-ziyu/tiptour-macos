"""Browser staging for the controlled page.

The runner only ever opens the local disposable fixture URL in Safari through
LaunchServices. It never automates Safari with AppleScript (the automation
banner would intercept real mouse events) and never opens any other URL.

Who is frontmost is part of the staging *proof*, not a warning. The runner asks
LaunchServices for the frontmost identity and records what was actually
observed: `frontmost_established`, `frontmost_bundle_id` and, when the identity
could not be established, the exact `frontmost_stop_reason`. Nothing here
promotes an unproven foreground into a justification for a desktop action; the
decision belongs to the caller, which now has a fact instead of a hope.
"""
from __future__ import annotations

import re
import time

from . import paths
from .process_control import run_capture

# `lsappinfo front` prints one of two shapes, and which one a machine emits is a
# property of the OS build: either the bundle id itself ("com.apple.Safari
# ASN:0x0-0x...") or only the application serial number ("ASN:0x0-0x1ad3ad2:").
# This machine emits the ASN form, so a substring search for
# "com.apple.Safari" could never match and a wait that "succeeded" would have
# been a guess. The ASN is therefore resolved with the read-only
# `lsappinfo info <ASN>` (no TCC-gated automation, no AppleScript).
ASN_PATTERN = re.compile(r"ASN:0x[0-9A-Fa-f]+-0x[0-9A-Fa-f]+")
BUNDLE_ID_PATTERN = re.compile(r'bundleID\s*=\s*"?([^"\s]+)"?')
BUNDLE_ID_TOKEN_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)+$")

FRONTMOST_COMMAND_TIMEOUT_SECONDS = 5.0
FRONTMOST_POLL_INTERVAL_SECONDS = 0.5
FRONTMOST_INFO_STDOUT_LIMIT = 800


class BrowserStageError(RuntimeError):
    pass


def open_controlled_page(timeout_seconds: float = 20.0) -> dict:
    """Open http://127.0.0.1:19475 in Safari; return how it went."""
    result: dict = {"url": paths.FIXTURE_URL, "browser": paths.CONTROLLED_BROWSER_BUNDLE_IDENTIFIER,
                    "opened": False, "became_frontmost": False,
                    "frontmost_established": False,
                    "frontmost_stop_reason": "frontmost identity not checked yet",
                    "detail": ""}
    opened = run_capture(
        ["open", "-a", "Safari", paths.FIXTURE_URL], timeout_seconds=timeout_seconds
    )
    result["opened"] = opened.get("returncode") == 0
    result["detail"] = opened.get("stderr", "").strip()
    if not result["opened"]:
        raise BrowserStageError(f"Could not open the controlled page in Safari: {result['detail']}")
    return result


def _clean_token(token: str) -> str:
    """Drop the quoting and trailing punctuation `lsappinfo` wraps tokens in."""
    return token.strip().strip('"').strip("'").rstrip(":,").strip()


def _parse_frontmost_listing(stdout: str) -> tuple[str | None, str | None, str | None]:
    """Interpret one `lsappinfo front` stdout.

    Returns `(bundle_id, asn, reason)` with exactly one element set. A bundle id
    means the listing named the app itself (the shape older macOS builds print);
    an ASN means the listing only carried the serial number (the shape this
    machine prints) and must be resolved with `lsappinfo info <ASN>`. A reason
    is returned when the output carried neither, so the caller never has to
    infer an identity from text it does not understand.
    """
    text = (stdout or "").strip()
    if not text:
        return None, None, "lsappinfo front printed an empty frontmost listing"
    tokens = [_clean_token(token) for token in text.split()]
    tokens = [token for token in tokens if token]
    for token in tokens:
        if BUNDLE_ID_TOKEN_PATTERN.match(token):
            return token, None, None
    for token in tokens:
        if ASN_PATTERN.fullmatch(token):
            return None, token, None
    return None, None, f"lsappinfo front printed neither a bundle id nor an ASN: {text!r}"


def _resolve_bundle_id_for_asn(asn: str) -> tuple[str | None, str | None, str]:
    """Resolve an ASN to a bundle id through the read-only `lsappinfo info`."""
    listing = run_capture(
        ["lsappinfo", "info", asn], timeout_seconds=FRONTMOST_COMMAND_TIMEOUT_SECONDS
    )
    stdout = (listing.get("stdout") or "").strip()
    if listing.get("timed_out"):
        return None, (f"lsappinfo info {asn} timed out after "
                      f"{FRONTMOST_COMMAND_TIMEOUT_SECONDS:g}s"), stdout
    if listing.get("error"):
        return None, f"lsappinfo info {asn} could not be run: {listing['error']}", stdout
    returncode = listing.get("returncode")
    if returncode != 0:
        detail = (listing.get("stderr") or "").strip() or "no stderr output"
        return None, f"lsappinfo info {asn} exited {returncode}: {detail}", stdout
    match = BUNDLE_ID_PATTERN.search(stdout)
    if not match:
        return None, f"lsappinfo info {asn} printed no bundleID= field", stdout
    return match.group(1), None, stdout


def _cannot_establish(observation: dict, reason: str) -> dict:
    observation["frontmost_established"] = False
    observation["frontmost_stop_reason"] = reason
    return observation


def _observe_frontmost() -> dict:
    """Read, once, who is frontmost - and say exactly how that was determined."""
    expected = paths.CONTROLLED_BROWSER_BUNDLE_IDENTIFIER
    observation: dict = {"command": "lsappinfo front"}
    listing = run_capture(["lsappinfo", "front"], timeout_seconds=FRONTMOST_COMMAND_TIMEOUT_SECONDS)
    observation["lsappinfo_front_stdout"] = (listing.get("stdout") or "").strip()
    observation["returncode"] = listing.get("returncode")
    observation["timed_out"] = bool(listing.get("timed_out"))
    observation["lsappinfo_info_stdout"] = ""

    if observation["timed_out"]:
        return _cannot_establish(
            observation,
            f"lsappinfo front timed out after {FRONTMOST_COMMAND_TIMEOUT_SECONDS:g}s "
            "without naming the frontmost app",
        )
    if listing.get("error"):
        return _cannot_establish(observation, f"lsappinfo front could not be run: {listing['error']}")
    if observation["returncode"] != 0:
        detail = (listing.get("stderr") or "").strip() or "no stderr output"
        return _cannot_establish(
            observation, f"lsappinfo front exited {observation['returncode']}: {detail}"
        )

    bundle_id, asn, reason = _parse_frontmost_listing(observation["lsappinfo_front_stdout"])
    if bundle_id is not None:
        observation["basis"] = "lsappinfo front listed the bundle id directly"
        return _judge_frontmost(observation, bundle_id, "")

    if asn is not None:
        # Never guess from the ASN: ask LaunchServices what that ASN is.
        observation["frontmost_asn"] = asn
        observation["basis"] = f"bundle id resolved from lsappinfo info {asn}"
        resolved, resolve_reason, info_stdout = _resolve_bundle_id_for_asn(asn)
        observation["lsappinfo_info_stdout"] = info_stdout[:FRONTMOST_INFO_STDOUT_LIMIT]
        if resolved is None:
            return _cannot_establish(observation, resolve_reason or "ASN resolution failed")
        return _judge_frontmost(observation, resolved, f" (ASN {asn})")

    return _cannot_establish(
        observation, reason or "lsappinfo front produced an unusable frontmost listing"
    )


def _judge_frontmost(observation: dict, frontmost_bundle_id: str, how: str) -> dict:
    """Compare an established identity with the controlled browser."""
    expected = paths.CONTROLLED_BROWSER_BUNDLE_IDENTIFIER
    observation["frontmost_bundle_id"] = frontmost_bundle_id
    if frontmost_bundle_id == expected:
        observation["frontmost_established"] = True
        observation["frontmost_stop_reason"] = ""
        return observation
    observation["frontmost_established"] = False
    observation["frontmost_stop_reason"] = (
        f"frontmost app is {frontmost_bundle_id}{how}, "
        f"not the controlled browser {expected}"
    )
    return observation


def _compact_observation(observation: dict) -> dict:
    """The evidence-sized projection of one frontmost observation."""
    return {
        "attempt": observation.get("attempt"),
        "command": observation.get("command"),
        "returncode": observation.get("returncode"),
        "timed_out": observation.get("timed_out"),
        "basis": observation.get("basis", ""),
        "frontmost_asn": observation.get("frontmost_asn", ""),
        "frontmost_bundle_id": observation.get("frontmost_bundle_id", ""),
        "frontmost_established": bool(observation.get("frontmost_established")),
        "frontmost_stop_reason": observation.get("frontmost_stop_reason", ""),
        "lsappinfo_front_stdout": observation.get("lsappinfo_front_stdout", ""),
        "lsappinfo_info_stdout": observation.get("lsappinfo_info_stdout", ""),
    }


def observe_frontmost_identity(timeout_seconds: float = 15.0) -> dict:
    """Poll LaunchServices until the frontmost identity is proven, or not.

    Returns a record with `frontmost_established`, `frontmost_bundle_id`,
    `frontmost_stop_reason` (plus the attempt count and every raw observation).
    `frontmost_bundle_id` is only ever set once it is the controlled browser;
    a different app that was frontmost stays in `frontmost_observed_bundle_id`
    so no other identity can be mistaken for the browser.
    It never raises and never guesses: an unparseable listing, a failing
    `lsappinfo` call, an ASN that cannot be resolved, and a timeout each end
    the wait with `frontmost_established: false` and the exact reason. The same
    question is re-asked on every call, so no earlier answer is ever reused.
    """
    deadline = time.monotonic() + max(0.0, timeout_seconds)
    attempts = 0
    latest: dict = {}
    observations: list[dict] = []
    while True:
        attempts += 1
        latest = _observe_frontmost()
        latest["attempt"] = attempts
        observations.append(_compact_observation(latest))
        if latest.get("frontmost_established"):
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(FRONTMOST_POLL_INTERVAL_SECONDS)
    established = bool(latest.get("frontmost_established"))
    stop_reason = latest.get("frontmost_stop_reason", "")
    if not established and not stop_reason:
        # Only an unestablished wait carries a reason; an established one keeps
        # the empty string so the field never invents a failure out of nothing.
        stop_reason = "frontmost identity was never observed"
    observed_bundle_id = latest.get("frontmost_bundle_id", "")
    return {
        "frontmost_established": established,
        # Only ever the controlled browser's id: an unestablished wait must not
        # leave some other app's id in a field a reader would trust.
        "frontmost_bundle_id": observed_bundle_id if established else "",
        "frontmost_observed_bundle_id": observed_bundle_id,
        "frontmost_stop_reason": stop_reason,
        "frontmost_attempts": attempts,
        "frontmost_observations": observations,
    }


def wait_until_browser_is_frontmost(timeout_seconds: float = 15.0) -> bool:
    """True only when the frontmost identity was established as the browser."""
    return observe_frontmost_identity(timeout_seconds)["frontmost_established"]


def _record_frontmost(stage: dict, identity: dict) -> dict:
    """Put the frontmost facts onto the stage dict the caller will read."""
    established = bool(identity.get("frontmost_established"))
    stage["became_frontmost"] = established
    stage["frontmost_established"] = established
    stage["frontmost_bundle_id"] = identity.get("frontmost_bundle_id") or ""
    stage["frontmost_observed_bundle_id"] = identity.get("frontmost_observed_bundle_id") or ""
    stage["frontmost_stop_reason"] = identity.get("frontmost_stop_reason") or ""
    stage["frontmost_identity"] = identity
    return stage


def reload_controlled_page(fixture, previous_page_views: int | None) -> dict:
    """Reload the controlled page between scenarios.

    LaunchServices `open` is the only sanctioned reload: AppleScript control of
    Safari would raise the automation banner that intercepts real mouse events.
    Each reload lands in a new tab; the newest tab is authoritative and the
    page_views increment proves the server saw the load.

    The frontmost identity is re-established here rather than inherited from the
    previous scenario: a foreground that was true minutes ago proves nothing
    about the desktop the next scenario is about to click on.
    """
    stage = open_controlled_page()
    stage["page_views_after_reload"] = fixture.wait_for_page_reload(previous_page_views)
    return _record_frontmost(stage, observe_frontmost_identity())


def stage_controlled_page(fixture, previous_page_views: int | None) -> dict:
    """Open the controlled page and prove the browser actually loaded it.

    The returned stage states, as facts, whether Safari was proven to be the
    frontmost app (`frontmost_established`) and, when it was not, exactly why
    (`frontmost_stop_reason`). It is deliberately not a warning: the caller
    decides whether a desktop action may proceed, and it gets the honest
    identity it needs to do so.
    """
    stage = open_controlled_page()
    stage["page_views_after_open"] = fixture.wait_for_page_reload(previous_page_views)
    return _record_frontmost(stage, observe_frontmost_identity())

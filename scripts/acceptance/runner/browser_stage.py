"""Browser staging for the controlled page.

The runner only ever opens the local disposable fixture URL in Safari through
LaunchServices. It never automates Safari with AppleScript (the automation
banner would intercept real mouse events) and never opens any other URL.
"""
from __future__ import annotations

import time
from pathlib import Path

from . import paths
from .process_control import run_capture


class BrowserStageError(RuntimeError):
    pass


def open_controlled_page(timeout_seconds: float = 20.0) -> dict:
    """Open http://127.0.0.1:19475 in Safari; return how it went."""
    result: dict = {"url": paths.FIXTURE_URL, "browser": paths.CONTROLLED_BROWSER_BUNDLE_IDENTIFIER,
                    "opened": False, "became_frontmost": False, "detail": ""}
    opened = run_capture(
        ["open", "-a", "Safari", paths.FIXTURE_URL], timeout_seconds=timeout_seconds
    )
    result["opened"] = opened.get("returncode") == 0
    result["detail"] = opened.get("stderr", "").strip()
    if not result["opened"]:
        raise BrowserStageError(f"Could not open the controlled page in Safari: {result['detail']}")
    return result


def wait_until_browser_is_frontmost(timeout_seconds: float = 15.0) -> bool:
    """Poll `lsappinfo front` (no TCC-gated automation) for the browser."""
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        listing = run_capture(["lsappinfo", "front"], timeout_seconds=5.0)
        if listing.get("returncode") == 0:
            # Output looks like: com.apple.Safari "ASN:0x0-0x..."
            if paths.CONTROLLED_BROWSER_BUNDLE_IDENTIFIER in (listing.get("stdout") or ""):
                return True
        time.sleep(0.5)
    return False


def reload_controlled_page(fixture, previous_page_views: int | None) -> dict:
    """Reload the controlled page between scenarios.

    LaunchServices `open` is the only sanctioned reload: AppleScript control of
    Safari would raise the automation banner that intercepts real mouse events.
    Each reload lands in a new tab; the newest tab is authoritative and the
    page_views increment proves the server saw the load.
    """
    stage = open_controlled_page()
    stage["page_views_after_reload"] = fixture.wait_for_page_reload(previous_page_views)
    return stage


def stage_controlled_page(fixture, previous_page_views: int | None) -> dict:
    """Open the controlled page and prove the browser actually loaded it."""
    stage = open_controlled_page()
    stage["page_views_after_open"] = fixture.wait_for_page_reload(previous_page_views)
    stage["became_frontmost"] = wait_until_browser_is_frontmost()
    if not stage["became_frontmost"]:
        # Not fatal: the probes pin the expected bundle themselves, but the
        # observation is recorded because real input needs a foreground window.
        stage["frontmost_warning"] = (
            "Safari did not become the frontmost app within the wait window; "
            "the probe still pins the expected bundle, but a real desktop click "
            "can only land on a foreground window."
        )
    return stage

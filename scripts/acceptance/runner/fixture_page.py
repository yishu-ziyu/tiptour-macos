"""Lifecycle control for the disposable controlled page (127.0.0.1:19475).

The runner starts the fixture itself, resets its state, reads the independent
/state before and after every scenario, and always stops it again. A port that
is already occupied is treated as an environment problem (BLOCKED), never as
something to kill: only the runner's own child fixture may be terminated.
"""
from __future__ import annotations

import datetime as _datetime
import json
import time
import urllib.error
import urllib.request
from pathlib import Path

from . import paths
from .process_control import OwnedProcessRegistry, OwnedProcess, port_accepts_connections, spawn_owned_process, wait_for_owned_exit, terminate_owned_process


class FixtureError(RuntimeError):
    pass


class FixtureServer:
    def __init__(self, out_dir: Path, registry: OwnedProcessRegistry) -> None:
        self.out_dir = out_dir
        self.registry = registry
        self.owned: OwnedProcess | None = None
        self.log_path = out_dir / "fixture-server.log"
        self.base_url = paths.FIXTURE_URL
        self._page_views_at_start: int | None = None

    # ---------- lifecycle ----------

    def start(self, readiness_timeout_seconds: float = 15.0) -> dict:
        if port_accepts_connections(paths.FIXTURE_HOST, paths.FIXTURE_PORT):
            raise FixtureError(
                f"Port {paths.FIXTURE_PORT} is already occupied before the fixture starts. "
                "Another developer server, browser automation, or a leftover fixture is using it. "
                "The runner never kills unrelated processes: free the port and rerun."
            )
        script_path = paths.fixture_script_path()
        if not script_path.is_file():
            raise FixtureError(f"Fixture script is missing: {script_path}")
        self.owned = spawn_owned_process(
            self.registry,
            label="fixture-page",
            argv=["python3", str(script_path)],
            log_path=self.log_path,
        )
        deadline = time.monotonic() + readiness_timeout_seconds
        last_error = "fixture did not answer in time"
        while time.monotonic() < deadline:
            if self.owned.poll() is not None:
                raise FixtureError(
                    f"Fixture exited during startup with code {self.owned.poll()}. "
                    f"See {self.log_path}"
                )
            try:
                state = self.state()
            except FixtureError as error:
                last_error = str(error)
                time.sleep(0.25)
                continue
            self._page_views_at_start = state.get("page_views")
            return {"pid": self.owned.pid, "page_views_at_start": self._page_views_at_start}
        raise FixtureError(
            f"Fixture was not ready after {readiness_timeout_seconds:.0f}s: {last_error}"
        )

    def stop(self) -> dict:
        if self.owned is None:
            return {"stopped": False, "reason": "fixture was never started"}
        result = terminate_owned_process(self.owned)
        result["stopped"] = True
        result["port_released"] = not port_accepts_connections(
            paths.FIXTURE_HOST, paths.FIXTURE_PORT, timeout_seconds=2.0
        )
        self.owned = None
        return result

    # ---------- protocol ----------

    def _request(self, method: str, path: str, body: dict | None = None, timeout: float = 10.0) -> dict:
        url = self.base_url + path
        data = json.dumps(body).encode("utf-8") if body is not None else None
        request = urllib.request.Request(
            url, data=data, method=method,
            headers={"Content-Type": "application/json"} if data else {},
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = response.read()
                return json.loads(payload.decode("utf-8"))
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as error:
            raise FixtureError(f"{method} {path} failed: {error}") from error

    def state(self) -> dict:
        return self._request("GET", "/state")

    def reset(self) -> dict:
        return self._request("POST", "/reset")

    def fetch_page(self) -> str:
        url = self.base_url + "/"
        try:
            with urllib.request.urlopen(url, timeout=10.0) as response:
                return response.read().decode("utf-8", errors="replace")
        except (urllib.error.URLError, OSError) as error:
            raise FixtureError(f"GET / failed: {error}") from error

    # ---------- runner-facing assertions ----------

    def wait_for_page_reload(self, previous_views: int | None, timeout_seconds: float = 20.0) -> int:
        """Wait until the fixture records another page view.

        This proves the controlled page was actually loaded by the browser
        after the runner opened it — the runner never trusts a bare `open`.
        """
        deadline = time.monotonic() + timeout_seconds
        baseline = previous_views
        while time.monotonic() < deadline:
            state = self.state()
            views = state.get("page_views")
            if isinstance(views, int) and (baseline is None or views > baseline):
                return views
            time.sleep(0.25)
        raise FixtureError(
            "The controlled page was not reloaded within "
            f"{timeout_seconds:.0f}s (page_views stayed at {baseline})."
        )

    def assert_controlled_page_marker(self) -> None:
        html = self.fetch_page()
        if "TipTour 操作验收" not in html:
            raise FixtureError(
                "The fixture page does not look like the disposable controlled page; "
                "refusing to drive a foreign page."
            )


def snapshot_state(fixture: FixtureServer) -> dict:
    state = fixture.state()
    state = dict(state)
    state["captured_at"] = _datetime.datetime.now(_datetime.UTC).isoformat()
    return state


def summarize_event_delta(before: dict | None, after: dict) -> list[str]:
    """Ordered events added between two /state snapshots."""
    before_events = list((before or {}).get("events") or [])
    after_events = list(after.get("events") or [])
    if len(after_events) >= len(before_events) and after_events[: len(before_events)] == before_events:
        return after_events[len(before_events):]
    return after_events

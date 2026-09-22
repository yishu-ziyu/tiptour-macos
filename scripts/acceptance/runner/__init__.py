"""Runner package for the one-command Her E2E acceptance run.

The runner drives the signed DEBUG Her app through its documented probe
entrypoints, the disposable local fixture page, and an independent /state
readback. It never builds, installs, kills the user's Her, opens the
microphone, or records secrets. See scripts/acceptance/README.md.
"""
from __future__ import annotations

__all__ = [
    "app_identity",
    "browser_stage",
    "dry_run",
    "evidence",
    "fixture_page",
    "paths",
    "probe_runner",
    "process_control",
    "scenario_judges",
    "scenarios",
    "self_test",
    "synthetic_speech",
]

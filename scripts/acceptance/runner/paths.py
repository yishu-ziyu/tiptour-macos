"""Shared constants and path discovery for the Her E2E acceptance runner.

Everything the runner needs to know about the expected product identity and
the local controlled page lives here so the checks are auditable in one place.
"""
from __future__ import annotations

from pathlib import Path

# Expected product identity. The runner refuses to gather evidence from any
# other app: the work order requires Her.app / com.yishuziyu.her / team
# 87DM76C54G, and a stale or foreign binary must produce BLOCKED, not evidence.
EXPECTED_APP_BUNDLE_NAME = "Her.app"
EXPECTED_BUNDLE_IDENTIFIER = "com.yishuziyu.her"
EXPECTED_TEAM_IDENTIFIER = "87DM76C54G"
EXPECTED_BUNDLE_EXECUTABLE = "Her"

# Keychain: the app stores provider keys as generic-password items whose
# service is the bundle ID (see TipTour/Utilities/KeychainStore.swift). The
# runner only proves presence/accessibility; it never reads or prints secrets.
KEYCHAIN_SERVICE_NAME = EXPECTED_BUNDLE_IDENTIFIER
KEYCHAIN_ACCOUNTS_TO_CHECK = ("stepfunAPIKey", "jevAPIKey")

# The disposable controlled page served by tools/voice-acceptance/fixture.py.
FIXTURE_HOST = "127.0.0.1"
FIXTURE_PORT = 19475
FIXTURE_URL = f"http://{FIXTURE_HOST}:{FIXTURE_PORT}"
CONTROLLED_BROWSER_BUNDLE_IDENTIFIER = "com.apple.Safari"

# Product sources that participate in the "binary must not be older than
# product source" freshness gate.
PRODUCT_SOURCE_RELATIVE_GLOBS = (
    "TipTour/**/*.swift",
    "TipTour/Info.plist",
)

# Where Xcode leaves the Debug build on this machine. The runner never builds;
# this default only saves the integrator from retyping the path.
DEFAULT_DERIVED_DATA_APP = (
    Path.home()
    / "Library/Developer/Xcode/DerivedData/tiptour-macos-gtcdcfrkrqlavldfoxxsyfksnyrq"
    / "Build/Products/Debug/Her.app"
)

WORK_ORDER_ID = "03-her-e2e-runner"
DEFAULT_EVIDENCE_DIRECTORY_NAME = "03-her-e2e-runner"


def repository_root() -> Path:
    """Locate the repository root that contains this scripts/ tree."""
    return Path(__file__).resolve().parents[3]


def fixture_script_path() -> Path:
    return repository_root() / "tools/voice-acceptance/fixture.py"


def scenario_directory() -> Path:
    return repository_root() / "tools/voice-acceptance/scenarios"

"""App identity preflight: right app, right signature, fresh binary, key present.

Every check here exists to answer one question before any evidence is
collected: is this the signed DEBUG Her.app, built from code no older than the
binary, with its provider key present in the app's own Keychain? A failure is
reported as BLOCKED with the reason; the runner then refuses to run scenarios
instead of gathering evidence from an untrustworthy binary.
"""
from __future__ import annotations

import plistlib
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from . import paths
from .process_control import find_processes_matching, run_capture


@dataclass
class AppIdentity:
    app_path: str
    bundle_name_ok: bool = False
    bundle_identifier: str | None = None
    bundle_identifier_ok: bool = False
    bundle_executable: str | None = None
    bundle_executable_ok: bool = False
    bundle_display_name: str | None = None
    codesign_team_identifier: str | None = None
    codesign_team_ok: bool = False
    codesign_authority: str | None = None
    codesign_signature_ok: bool = False
    codesign_detail: str = ""
    binary_path: str | None = None
    binary_modified_at_epoch: float | None = None
    binary_modified_at_iso: str | None = None
    newest_product_source_path: str | None = None
    newest_product_source_modified_at_epoch: float | None = None
    binary_is_fresh: bool = False
    product_sources_checked: int = 0
    keychain: list[dict] = field(default_factory=list)
    keychain_accessible: bool = False
    user_her_processes: list[dict] = field(default_factory=list)
    blocking_reasons: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "app_path": self.app_path,
            "expected": {
                "app_bundle_name": paths.EXPECTED_APP_BUNDLE_NAME,
                "bundle_identifier": paths.EXPECTED_BUNDLE_IDENTIFIER,
                "team_identifier": paths.EXPECTED_TEAM_IDENTIFIER,
                "bundle_executable": paths.EXPECTED_BUNDLE_EXECUTABLE,
            },
            "bundle_name_ok": self.bundle_name_ok,
            "bundle_identifier": self.bundle_identifier,
            "bundle_identifier_ok": self.bundle_identifier_ok,
            "bundle_executable": self.bundle_executable,
            "bundle_executable_ok": self.bundle_executable_ok,
            "bundle_display_name": self.bundle_display_name,
            "codesign_team_identifier": self.codesign_team_identifier,
            "codesign_team_ok": self.codesign_team_ok,
            "codesign_authority": self.codesign_authority,
            "codesign_signature_ok": self.codesign_signature_ok,
            "codesign_detail": self.codesign_detail,
            "binary_path": self.binary_path,
            "binary_modified_at_epoch": self.binary_modified_at_epoch,
            "binary_modified_at_iso": self.binary_modified_at_iso,
            "newest_product_source_path": self.newest_product_source_path,
            "newest_product_source_modified_at_epoch": self.newest_product_source_modified_at_epoch,
            "binary_is_fresh": self.binary_is_fresh,
            "product_sources_checked": self.product_sources_checked,
            # Presence and OS status only. Secrets are never read, printed or stored.
            "keychain": self.keychain,
            "keychain_accessible": self.keychain_accessible,
            # Recorded, never killed: the runner must not stop a user's Her.
            "user_her_processes": self.user_her_processes,
            "blocking_reasons": self.blocking_reasons,
        }


def _read_info_plist(app_path: Path) -> dict:
    plist_path = app_path / "Contents/Info.plist"
    with plist_path.open("rb") as handle:
        return plistlib.load(handle)


def _inspect_codesign(app_path: Path) -> tuple[str, str, bool, str]:
    details = run_capture(
        ["codesign", "-dv", "--verbose=4", str(app_path)], timeout_seconds=30.0
    )
    # codesign writes the identity block to stderr.
    detail_text = (details.get("stderr") or "") + (details.get("stdout") or "")
    team_identifier = ""
    authority = ""
    for line in detail_text.splitlines():
        if line.startswith("TeamIdentifier="):
            team_identifier = line.split("=", 1)[1].strip()
        if line.startswith("Authority=") and not authority:
            authority = line.split("=", 1)[1].strip()
    verification = run_capture(
        ["codesign", "--verify", "--deep", "--strict", str(app_path)], timeout_seconds=60.0
    )
    signature_ok = verification.get("returncode") == 0 and not verification.get("error")
    detail_note = verification.get("stderr", "").strip() or verification.get("error") or ""
    return team_identifier, authority, signature_ok, detail_note


def _check_keychain_item(service: str, account: str) -> dict:
    """Presence/accessibility only: stdout is discarded, never stored.

    A generic-password lookup without -g/-w does not decrypt the secret, so no
    Keychain prompt is opened and no secret can reach this record.
    """
    lookup = run_capture(
        ["security", "find-generic-password", "-s", service, "-a", account],
        timeout_seconds=30.0,
    )
    # Deliberately drop stdout/stderr: attributes only, never the secret.
    status_code = lookup.get("returncode")
    return {
        "account": account,
        "present": status_code == 0,
        "os_status_code": status_code,
        "timed_out": bool(lookup.get("timed_out")),
        "lookup_error": lookup.get("error"),
    }


def _find_newest_product_source(repository_root: Path) -> tuple[Path | None, float | None, int]:
    newest_path: Path | None = None
    newest_mtime: float | None = None
    checked = 0
    for relative_glob in paths.PRODUCT_SOURCE_RELATIVE_GLOBS:
        for candidate in repository_root.glob(relative_glob):
            if not candidate.is_file():
                continue
            checked += 1
            mtime = candidate.stat().st_mtime
            if newest_mtime is None or mtime > newest_mtime:
                newest_mtime = mtime
                newest_path = candidate
    return newest_path, newest_mtime, checked


def inspect_app_identity(app_path: Path) -> AppIdentity:
    identity = AppIdentity(app_path=str(app_path))
    repository_root = paths.repository_root()

    if not app_path.exists():
        identity.blocking_reasons.append(f"App path does not exist: {app_path}")
        return identity
    if not app_path.is_dir() or app_path.suffix != ".app":
        identity.blocking_reasons.append(
            f"Expected a macOS .app bundle, got: {app_path}"
        )
        return identity
    identity.bundle_name_ok = app_path.name == paths.EXPECTED_APP_BUNDLE_NAME
    if not identity.bundle_name_ok:
        identity.blocking_reasons.append(
            f"App bundle is named {app_path.name!r}; the work order requires "
            f"{paths.EXPECTED_APP_BUNDLE_NAME!r} so a renamed debug product cannot pass."
        )

    try:
        info = _read_info_plist(app_path)
    except (OSError, plistlib.InvalidFileException) as error:
        identity.blocking_reasons.append(f"Could not read Info.plist: {error}")
        return identity
    identity.bundle_identifier = info.get("CFBundleIdentifier")
    identity.bundle_executable = info.get("CFBundleExecutable")
    identity.bundle_display_name = info.get("CFBundleDisplayName") or info.get("CFBundleName")
    identity.bundle_identifier_ok = identity.bundle_identifier == paths.EXPECTED_BUNDLE_IDENTIFIER
    identity.bundle_executable_ok = identity.bundle_executable == paths.EXPECTED_BUNDLE_EXECUTABLE
    if not identity.bundle_identifier_ok:
        identity.blocking_reasons.append(
            f"Bundle identifier is {identity.bundle_identifier!r}, expected "
            f"{paths.EXPECTED_BUNDLE_IDENTIFIER!r}."
        )
    if not identity.bundle_executable_ok:
        identity.blocking_reasons.append(
            f"Bundle executable is {identity.bundle_executable!r}, expected "
            f"{paths.EXPECTED_BUNDLE_EXECUTABLE!r}."
        )

    team_identifier, authority, signature_ok, detail = _inspect_codesign(app_path)
    identity.codesign_team_identifier = team_identifier
    identity.codesign_authority = authority
    identity.codesign_signature_ok = signature_ok
    identity.codesign_detail = detail
    identity.codesign_team_ok = team_identifier == paths.EXPECTED_TEAM_IDENTIFIER
    if not identity.codesign_team_ok:
        identity.blocking_reasons.append(
            f"Team identifier is {team_identifier or 'unknown'!r}, expected "
            f"{paths.EXPECTED_TEAM_IDENTIFIER!r}."
        )
    if not signature_ok:
        identity.blocking_reasons.append(f"codesign verification failed: {detail}")

    binary_path = app_path / "Contents/MacOS" / (identity.bundle_executable or "Her")
    if not binary_path.is_file():
        identity.blocking_reasons.append(f"App binary is missing: {binary_path}")
        return identity
    identity.binary_path = str(binary_path)
    binary_stat = binary_path.stat()
    identity.binary_modified_at_epoch = binary_stat.st_mtime
    identity.binary_modified_at_iso = _iso_from_epoch(binary_stat.st_mtime)

    newest_source, newest_source_mtime, checked = _find_newest_product_source(repository_root)
    identity.product_sources_checked = checked
    identity.newest_product_source_path = str(newest_source) if newest_source else None
    identity.newest_product_source_modified_at_epoch = newest_source_mtime
    if checked == 0:
        identity.blocking_reasons.append(
            "No product sources found to compare against the binary; refusing to judge freshness."
        )
    elif newest_source_mtime is not None:
        # The work order's gate: a binary older than product source would let an
        # old process "verify" new code, so this is BLOCKED, not a warning.
        identity.binary_is_fresh = binary_stat.st_mtime >= newest_source_mtime
        if not identity.binary_is_fresh:
            newer_sources = [
                str(candidate)
                for relative_glob in paths.PRODUCT_SOURCE_RELATIVE_GLOBS
                for candidate in repository_root.glob(relative_glob)
                if candidate.is_file() and candidate.stat().st_mtime > binary_stat.st_mtime
            ]
            identity.blocking_reasons.append(
                "Binary is older than product sources (newest source "
                f"{newest_source} modified {_iso_from_epoch(newest_source_mtime)}; "
                f"binary built {identity.binary_modified_at_iso}). "
                f"{len(newer_sources)} product source file(s) are newer. "
                "Rebuild the DEBUG app in Xcode and rerun; an older binary must not "
                "be used to verify newer code."
            )

    for account in paths.KEYCHAIN_ACCOUNTS_TO_CHECK:
        identity.keychain.append(
            _check_keychain_item(paths.KEYCHAIN_SERVICE_NAME, account)
        )
    stepfun_item = next(
        (item for item in identity.keychain if item["account"] == "stepfunAPIKey"), None
    )
    identity.keychain_accessible = bool(stepfun_item and stepfun_item["present"])
    if not identity.keychain_accessible:
        identity.blocking_reasons.append(
            "The app's own StepFun Keychain item is not readable non-interactively "
            f"(service {paths.KEYCHAIN_SERVICE_NAME!r}, account 'stepfunAPIKey'). "
            "Open Her once, enter the StepFun key in Settings → Models, and rerun. "
            "The runner never exports or prints keys."
        )

    # Recording only. A user's Her keeps running; the probe is a separate process.
    identity.user_her_processes = [
        process for process in find_processes_matching("Her.app/Contents/MacOS/Her")
    ]
    return identity


def _iso_from_epoch(epoch: float | None) -> str | None:
    if epoch is None:
        return None
    import datetime as _datetime

    return _datetime.datetime.fromtimestamp(epoch, _datetime.UTC).isoformat()


def default_debug_app_path() -> Path:
    """The only build location the runner looks at; it never builds anything."""
    return paths.DEFAULT_DERIVED_DATA_APP


def resolve_app_path(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).expanduser().resolve()
    return default_debug_app_path().expanduser().resolve()


def git_commit(repository_root: Path | None = None) -> str | None:
    root = repository_root or paths.repository_root()
    result = run_capture(["git", "-C", str(root), "rev-parse", "HEAD"], timeout_seconds=15.0)
    commit = (result.get("stdout") or "").strip()
    return commit or None


def git_branch(repository_root: Path | None = None) -> str | None:
    root = repository_root or paths.repository_root()
    result = run_capture(["git", "-C", str(root), "rev-parse", "--abbrev-ref", "HEAD"], timeout_seconds=15.0)
    branch = (result.get("stdout") or "").strip()
    return branch or None


def git_worktree_is_clean(repository_root: Path | None = None) -> bool | None:
    root = repository_root or paths.repository_root()
    result = run_capture(["git", "-C", str(root), "status", "--porcelain"], timeout_seconds=30.0)
    if result.get("returncode") is None:
        return None
    return result.get("stdout", "").strip() == ""

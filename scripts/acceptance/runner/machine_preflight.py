"""Read-only machine preflight: prove the desktop can be trusted before anything runs.

Real desktop acceptance runs keep getting interrupted by environment facts that
were knowable in advance: a stale DerivedData binary that would have verified
older code than the sources describe, a port still held by a leftover listener,
a user Her process nobody had recorded (and therefore might have signalled), a
foreground that was never the controlled page, or a locked screen that swallows
every input event. This module answers exactly those questions - and only those
- without touching anything.

The invariants are the point of this module:

* **Read-only.** No app is launched, no `open`, no activation, no screenshot, no
  signal is ever sent to any process, and no TCC state is changed. Every datum
  comes from a passive probe: a loopback socket connect attempt, a `ps`
  listing, a file mtime, static `codesign`/`security` reads, `lsappinfo front`
  / `lsappinfo info`, and `ioreg` / `pmset` reads. Port occupancy is decided by
  a connect attempt only, so an occupied port is reported, never disturbed.
* **Evidence, never a guess.** Every check reports `{ok, detail, evidence}` and
  puts the raw observation inside `evidence`. A state that cannot be proven -
  including a lock state no probe could answer - is reported as a concrete
  missing item, because a preflight that waves an unproven environment through
  is worse than no preflight at all: the failure would resurface later, as a
  vendor call against the wrong binary or a click that never landed.
* **Fresh perception.** The frontmost identity is re-read here, at check time,
  through the same mature LaunchServices resolution the browser staging uses
  (including the ASN-with-trailing-colon form this machine prints). Perception
  candidates jitter in time, so a report from this module is a statement about
  *now*; the caller still re-establishes the foreground before acting.

The computed verdict is `ready` only when every check proves itself; otherwise
`not_ready` with the concrete missing items, so the integration recheck can
judge BLOCKED before any provider or Driver call happens.
"""
from __future__ import annotations

import datetime
import re
from pathlib import Path

from . import browser_stage, evidence, paths
from .app_identity import inspect_app_identity
from .process_control import port_accepts_connections, run_capture

# The disposable controlled page's listener (127.0.0.1:19475) and the port the
# controlled page is reached through on this machine (127.0.0.1:19476). Both
# must be free before a run starts: a leftover listener on either port means a
# stale fixture or page would be exercised instead of the one this run starts.
FIXTURE_LISTEN_HOST = paths.FIXTURE_HOST
FIXTURE_LISTEN_PORT = paths.FIXTURE_PORT
CONTROLLED_PAGE_HOST = paths.FIXTURE_HOST
CONTROLLED_PAGE_PORT = 19476

# The user's own Her Mach-O, as its command line appears in a process listing.
# Matching it records the instance; nothing in this module ever signals it.
HER_BINARY_SUBSTRING = "Her.app/Contents/MacOS/Her"

# The only sanctioned process-listing shape: pid, the locale's launch-start
# string, and the full command, so a recorded Her can be re-identified later.
PS_LISTING_COMMAND = ["ps", "-Ao", "pid=,lstart=,command="]
PS_LISTING_TIMEOUT_SECONDS = 15.0

# One fresh LaunchServices read (it re-polls after an imperfect first read,
# which is the "wait for a fresh perception" behaviour, bounded).
FRONTMOST_PROBE_TIMEOUT_SECONDS = 2.0

# Read-only shell probes for the session lock state, with their time budgets.
# `ioreg -l -w 0` prints the whole registry including non-UTF-8 property bytes,
# which the shared text-mode runner cannot decode; the session dictionary is
# therefore fished out of the same listing by `grep -a` in the same shell, so the
# runner itself stays unchanged and only text-shaped lines reach Python.
IOREG_LISTING_COMMAND = "ioreg -l -w 0 | grep -a IOConsoleUsers"
IOREG_TIMEOUT_SECONDS = 20.0
PMSET_ASSERTIONS_COMMAND = ["pmset", "-g", "assertions"]
PMSET_TIMEOUT_SECONDS = 10.0

# `ioreg`'s IOConsoleUsers dictionary is the session property table; the lock
# keys are the documented-private IOKitKeysPrivate names for it.
IO_CONSOLE_USERS_PATTERN = re.compile(r'"IOConsoleUsers"\s*=\s*\((\{.*?\})\)', re.DOTALL)
IO_LOCK_TRUE_PATTERN = re.compile(
    r'"CGSSessionScreenIsLocked"\s*=\s*(?:Yes|true|1)\b', re.IGNORECASE)
IO_LOCK_FALSE_PATTERN = re.compile(
    r'"CGSSessionScreenIsLocked"\s*=\s*(?:No|false|0)\b', re.IGNORECASE)
IO_LOCK_TIME_PATTERN = re.compile(r'"CGSSessionScreenLockedTime"\s*=\s*([0-9]+)')

MACHINE_PREFLIGHT_FILE_NAME = "machine-preflight.json"
RESULT_SCHEMA_VERSION = 1

_VERDICT_READY = "ready"
_VERDICT_NOT_READY = "not_ready"


# --------------------------------------------------------------------- ports


def _capture_text(argv: list[str], timeout_seconds: float) -> dict:
    """`run_capture`, with the one failure it cannot classify handled locally.

    The shared runner decodes a child's output as strict text; a listing that
    carries bytes which are not valid UTF-8 would raise there, where a blocked
    run or an offline self-test would rather see a recorded reason in the
    evidence than a traceback.
    """
    try:
        return run_capture(argv, timeout_seconds=timeout_seconds)
    except UnicodeDecodeError as error:
        return {"argv": argv, "returncode": None, "stdout": "", "stderr": "",
                "timed_out": False, "error": f"output could not be decoded as text: {error}"}


def check_port(label: str, host: str, port: int, when_occupied: str) -> dict:
    """Decide, with a connect attempt only, whether `host:port` is free.

    A successful connect proves *something* is listening there, which is enough
    to block: the alternative - leaving the port alone and letting a run start
    on top of an unknown listener - is how a run ends up asserting against a
    stale fixture's `/state`. The listen itself is never disturbed, and no
    process is identified, let alone signalled.
    """
    occupied = port_accepts_connections(host, port)
    evidence = {
        "probe": "socket.connect",
        "host": host,
        "port": port,
        "port_accepts_connections": occupied,
    }
    if occupied:
        return {
            "name": label,
            "ok": False,
            "detail": (f"{host}:{port} already accepts connections; {when_occupied}"),
            "evidence": evidence,
        }
    return {
        "name": label,
        "ok": True,
        "detail": f"{host}:{port} accepts no connections (free)",
        "evidence": evidence,
    }


# --------------------------------------------------------- user Her processes


def parse_ps_listing(stdout: str, substring: str) -> list[dict]:
    """Extract the processes whose command line contains `substring`.

    `ps -Ao pid=,lstart=,command=` prints one right-aligned pid, the launch start
    as five whitespace-separated tokens, then the command. The result is a
    record for *recording* only - pid, binary, launch time - and the caller can
    say "the user's Her was running at these pids at this time" without ever
    having signalled anything.
    """
    entries: list[dict] = []
    for line in (stdout or "").splitlines():
        fields = line.split()
        if len(fields) < 7 or not fields[0].isdigit():
            continue
        command = " ".join(fields[6:])
        if substring not in command:
            continue
        entries.append({
            "pid": int(fields[0]),
            "started_at": " ".join(fields[1:6]),
            "binary": command.split()[0],
            "command": command,
        })
    return entries


def check_user_her_processes() -> dict:
    """Record any user Her process, so nobody can claim none was running.

    A user's Her keeps running through the whole acceptance session; the probe
    is a separate instance, and the runner's discipline is that it may only
    terminate what it spawned. This check therefore never fails on *finding* a
    Her - it exists so the evidence package can name the pids that were alive
    and must stay alive. It fails only when the listing itself could not be
    taken, because then no such record exists to protect.
    """
    listing = _capture_text(PS_LISTING_COMMAND, timeout_seconds=PS_LISTING_TIMEOUT_SECONDS)
    evidence = {
        "command": PS_LISTING_COMMAND,
        "returncode": listing.get("returncode"),
        "timed_out": bool(listing.get("timed_out")),
        "pattern": HER_BINARY_SUBSTRING,
        "processes": [],
        "error": listing.get("error"),
    }
    if listing.get("timed_out"):
        return {
            "name": "user_her_processes_recorded",
            "ok": False,
            "detail": (f"`{' '.join(PS_LISTING_COMMAND)}` timed out after "
                       f"{PS_LISTING_TIMEOUT_SECONDS:g}s; the user Her record "
                       "cannot be produced, so cleanup cannot be proven later"),
            "evidence": evidence,
        }
    if listing.get("error") or listing.get("returncode") != 0:
        reason = listing.get("error") or (listing.get("stderr") or "").strip() or "no stderr"
        return {
            "name": "user_her_processes_recorded",
            "ok": False,
            "detail": (f"the process listing failed (exit "
                       f"{evidence['returncode']}): {reason}; no user Her record"),
            "evidence": evidence,
        }
    processes = parse_ps_listing(listing.get("stdout") or "", HER_BINARY_SUBSTRING)
    evidence["processes"] = processes
    if processes:
        pids = ", ".join(str(process["pid"]) for process in processes)
        detail = (f"recorded {len(processes)} running Her process(es) (pid {pids}); "
                  "recorded only - none was signalled and none may be")
    else:
        detail = "no user Her process is running; the listing was taken"
    return {
        "name": "user_her_processes_recorded",
        "ok": True,
        "detail": detail,
        "evidence": evidence,
    }


# ------------------------------------------------------------- binary freshness


def check_binary_freshness(app_path: Path) -> dict:
    """The DerivedData binary must not be older than the product sources.

    An older binary "verifying" newer code is the failure mode the gate is for,
    so the comparison itself is delegated to the signed, audited identity
    inspection (its glob collection over `paths.PRODUCT_SOURCE_RELATIVE_GLOBS`),
    and this check only maps that judgment onto the preflight's verdict. If the
    comparison cannot even be made - no sources found, no binary, no app - the
    check fails rather than passing a staleness question it could not answer.
    """
    identity = inspect_app_identity(app_path)
    binary_is_fresh = bool(identity.binary_is_fresh)
    evidence = {
        "app_path": str(app_path),
        "binary_path": identity.binary_path,
        "binary_mtime_epoch": identity.binary_modified_at_epoch,
        "binary_mtime_iso": identity.binary_modified_at_iso,
        "newest_product_source_path": identity.newest_product_source_path,
        "newest_product_source_mtime_epoch": identity.newest_product_source_modified_at_epoch,
        "product_sources_checked": identity.product_sources_checked,
        "binary_is_fresh": binary_is_fresh,
        "identity_blocking_reasons": list(identity.blocking_reasons),
    }
    if identity.binary_path is None or identity.binary_modified_at_epoch is None:
        detail = (f"the app binary at {app_path} is missing or unreadable, so its age "
                  "cannot be compared with the product sources")
    elif identity.product_sources_checked == 0:
        detail = ("no product sources were found to compare against the binary; "
                  "refusing to judge freshness, so the run cannot be trusted")
    elif binary_is_fresh:
        detail = (f"binary built {identity.binary_modified_at_iso} is not older than "
                  f"the newest product source {identity.newest_product_source_path}")
    else:
        detail = ("binary is stale: newest product source "
                  f"{identity.newest_product_source_path} is newer than the binary built "
                  f"{identity.binary_modified_at_iso}; rebuild the DEBUG app in Xcode "
                  "and rerun (an older binary must not verify newer code)")
    return {
        "name": "derived_data_binary_fresh",
        "ok": binary_is_fresh and identity.product_sources_checked > 0,
        "detail": detail,
        "evidence": evidence,
    }


# ------------------------------------------------------------ frontmost identity


def check_frontmost_app(expect_frontmost_bundle: str) -> dict:
    """Resolve who is frontmost *now* and compare it with the expected identity.

    The resolution is browser_stage's proven one: `lsappinfo front` either lists
    a bundle id outright or prints only an ASN (with the trailing colon this
    machine emits), and an ASN is resolved with the read-only `lsappinfo info
    <ASN>` - never inferred from the ASN text. An identity that cannot be
    established, or that belongs to some other app, is a concrete missing item
    and not a warning.
    """
    expected = (expect_frontmost_bundle or "").strip()
    observation = browser_stage.observe_frontmost_identity(
        timeout_seconds=FRONTMOST_PROBE_TIMEOUT_SECONDS)
    observed = observation.get("frontmost_observed_bundle_id") or ""
    stop_reason = observation.get("frontmost_stop_reason") or ""
    evidence = {
        "expected_bundle_id": expected,
        "observed_bundle_id": observed,
        "frontmost_established": bool(observation.get("frontmost_established")),
        "frontmost_stop_reason": stop_reason,
        "frontmost_attempts": observation.get("frontmost_attempts"),
        "frontmost_observations": observation.get("frontmost_observations", []),
    }
    if not expected:
        return {
            "name": "frontmost_app_is_expected",
            "ok": False,
            "detail": ("no expected frontmost bundle was supplied, so the foreground "
                       "cannot be checked at all"),
            "evidence": evidence,
        }
    if observed:
        matches = observed == expected
        detail = (f"frontmost app is {observed}; expected {expected}"
                  + ("" if matches else " - the desktop must show the controlled page"))
        return {
            "name": "frontmost_app_is_expected",
            "ok": matches,
            "detail": detail,
            "evidence": evidence,
        }
    detail = f"frontmost identity could not be established: {stop_reason or 'unknown'}"
    return {
        "name": "frontmost_app_is_expected",
        "ok": False,
        "detail": detail,
        "evidence": evidence,
    }


# -------------------------------------------------------------- session lock


def _cg_session_dictionary() -> tuple[dict | None, str]:
    """`CGSessionCopyCurrentDictionary` (Quartz), read-only, or a reason."""
    try:
        from Quartz import CGSessionCopyCurrentDictionary
    except Exception as error:  # noqa: BLE001 - a missing pyobjc binding is data, not a crash
        return None, f"Quartz.CGSessionCopyCurrentDictionary is unavailable: {error}"
    try:
        snapshot = CGSessionCopyCurrentDictionary()
        return {str(key): _json_safe(snapshot[key]) for key in snapshot}, ""
    except Exception as error:  # noqa: BLE001 - an unreadable session is data, not a crash
        return None, f"CGSessionCopyCurrentDictionary failed: {error}"


def _json_safe(value) -> bool | int | float | str:
    """The evidence document is JSON; only JSON-shaped values may enter it."""
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return int(value)
    return str(value)


def _locked_from_cg_session(snapshot: dict) -> bool | None:
    """True/False from a CGSession lock key; None when no such key is carried."""
    for key, value in snapshot.items():
        lowered = key.lower()
        if "session" not in lowered or "lock" not in lowered:
            # A lock-named key from an unrelated domain would be a guess.
            continue
        if isinstance(value, bool):
            return value
    return None


def _io_console_users_blob(stdout: str) -> str:
    match = IO_CONSOLE_USERS_PATTERN.search(stdout or "")
    return match.group(1) if match else ""


def _locked_from_io_console_users(blob: str) -> bool | None:
    """True/False from the IOKit session lock keys; None when unanswerable."""
    if not blob:
        return None
    if IO_LOCK_TRUE_PATTERN.search(blob) or IO_LOCK_TIME_PATTERN.search(blob):
        return True
    if IO_LOCK_FALSE_PATTERN.search(blob):
        return False
    return None


def probe_screen_lock_state() -> dict:
    """Read-only, layered screen-lock probe.

    `CGSessionCopyCurrentDictionary` is the canonical session source;
    `ioreg`'s IOConsoleUsers dictionary is the IOKit session property table
    (`kIOConsoleSessionScreenIsLockedKey` / `kIOConsoleSessionScreenLockedTimeKey`);
    `pmset -g assertions` is recorded as supplementary context only and is never
    allowed to judge the lock state on its own. A layer that carries no lock key
    answers "unknown" rather than "unlocked": absence is not permission.
    """
    layers: list[dict] = []

    session_snapshot, session_note = _cg_session_dictionary()
    session_locked = _locked_from_cg_session(session_snapshot) if session_snapshot else None
    layers.append({
        "source": "CGSessionCopyCurrentDictionary",
        "locked": session_locked,
        "detail": session_note or ("lock key found" if session_locked is not None
                                   else "no session lock key in the dictionary"),
        "dictionary_keys": sorted(session_snapshot) if session_snapshot else [],
    })

    ioreg = _capture_text(["sh", "-c", IOREG_LISTING_COMMAND],
                          timeout_seconds=IOREG_TIMEOUT_SECONDS)
    io_locked: bool | None = None
    if ioreg.get("timed_out"):
        io_detail = ("ioreg listing timed out after "
                     f"{IOREG_TIMEOUT_SECONDS:g}s; IOKit session lock state unknown")
    elif ioreg.get("error") or ioreg.get("returncode") not in (0, 1):
        reason = ioreg.get("error") or (ioreg.get("stderr") or "").strip() or "no stderr"
        io_detail = f"ioreg listing failed (exit {ioreg.get('returncode')}): {reason}"
    else:
        blob = _io_console_users_blob(ioreg.get("stdout") or "")
        io_locked = _locked_from_io_console_users(blob)
        if blob:
            io_detail = ("IOConsoleUsers carried a screen-lock key" if io_locked is not None
                         else "IOConsoleUsers carried no screen-lock key")
        else:
            # grep exit 1 is the honest answer here: the listing had no such
            # dictionary, so this layer cannot say anything either way.
            io_detail = "ioreg output contained no IOConsoleUsers dictionary"
    layers.append({
        "source": IOREG_LISTING_COMMAND,
        "locked": io_locked,
        "detail": io_detail,
    })

    powerd = _capture_text(PMSET_ASSERTIONS_COMMAND, timeout_seconds=PMSET_TIMEOUT_SECONDS)
    powerd_stdout = (powerd.get("stdout") or "").strip()
    layers.append({
        "source": " ".join(PMSET_ASSERTIONS_COMMAND),
        "locked": None,
        "detail": ("recorded as supplementary context only; assertions do not decide "
                   "the lock state"),
        "timed_out": bool(powerd.get("timed_out")),
        "returncode": powerd.get("returncode"),
        "head": powerd_stdout[:400],
    })

    if any(layer["locked"] is True for layer in layers):
        locked: bool | None = True
    elif any(layer["locked"] is False for layer in layers):
        locked = False
    else:
        locked = None
    return {"locked": locked, "layers": layers}


def check_screen_not_locked() -> dict:
    """A locked screen silently eats every synthetic input event.

    The output is judged only when a probe *published* a lock answer: locked
    fails the run (desktop actions cannot land), and unlocked passes it. When
    neither canonical source answered, the check fails with the exact layers
    consulted instead of passing a session it could not prove unlocked.
    """
    probe = probe_screen_lock_state()
    locked = probe.get("locked")
    evidence = {
        "locked": locked,
        "layers": probe.get("layers", []),
        "rule": ("ok only for a probe-published 'unlocked'; locked fails, and an "
                 "unanswerable probe fails rather than passing an unproven session"),
    }
    if locked is True:
        detail = ("the screen is locked: input events cannot reach any app, so no desktop "
                  "acceptance action could land; unlock the session and rerun")
    elif locked is False:
        detail = "a read-only probe published the session as unlocked"
    else:
        detail = ("screen lock state could not be determined read-only - neither "
                  "CGSessionCopyCurrentDictionary nor ioreg's IOConsoleUsers published "
                  "a screen-lock key; refusing to pass an unproven session as unlocked "
                  "(confirm the screen is unlocked, or rerun on a machine whose session "
                  "property table publishes CGSSessionScreenIsLocked)")
    return {
        "name": "screen_unlocked",
        "ok": locked is False,
        "detail": detail,
        "evidence": evidence,
    }


# ------------------------------------------------------------------- verdict


def _iso_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def check_machine(app_path, out_dir, expect_frontmost_bundle: str) -> dict:
    """Run every read-only machine check and write the verdict into `out_dir`.

    Returns - and writes as `machine-preflight.json` - the same document: one
    `{ok, detail, evidence}` entry per check, the concrete `missing` items, and a
    verdict that is `ready` only when every check proved itself. Nothing here
    launches an app, opens a URL, activates a window, takes a screenshot,
    signals a process or changes a TCC permission, and an unproven state is
    reported as missing, never as a pass.
    """
    app_path = Path(app_path)
    out_dir = Path(out_dir)
    checks = [
        check_port(
            "fixture_port_free",
            FIXTURE_LISTEN_HOST,
            FIXTURE_LISTEN_PORT,
            "the disposable fixture page this run starts could not bind, or a left "
            "over fixture would serve a stale /state",
        ),
        check_port(
            "host_port_free",
            CONTROLLED_PAGE_HOST,
            CONTROLLED_PAGE_PORT,
            "the controlled page host port is held by another listener; close it "
            "before the desktop is touched",
        ),
        check_user_her_processes(),
        check_binary_freshness(app_path),
        check_frontmost_app(expect_frontmost_bundle),
        check_screen_not_locked(),
    ]
    missing = [f"{check['name']}: {check['detail']}" for check in checks if not check["ok"]]
    report = {
        "schema_version": RESULT_SCHEMA_VERSION,
        "checked_at": _iso_now(),
        "app_path": str(app_path),
        "expect_frontmost_bundle": (expect_frontmost_bundle or "").strip(),
        "read_only": True,
        "mutations": ("none: no app launched, no URL opened, no activation, no "
                      "screenshot, no process signalled, no TCC state changed"),
        "checks": checks,
        "missing": missing,
        "verdict": _VERDICT_READY if not missing else _VERDICT_NOT_READY,
        "blocked_reason": None if not missing else " | ".join(missing),
    }
    _write_report(report, out_dir)
    return report


def _write_report(report: dict, out_dir: Path) -> Path:
    evidence.write_json(out_dir / MACHINE_PREFLIGHT_FILE_NAME, report)
    return out_dir / MACHINE_PREFLIGHT_FILE_NAME

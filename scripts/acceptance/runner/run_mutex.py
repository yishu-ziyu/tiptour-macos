"""Cross-process mutex for Her E2E acceptance runs.

Parallel coding is fine; parallel *desktop* testing is not. Two acceptance runs
on the same machine would share one fixture server, one controlled page, one
`/state` and one physical mouse, so the work order requires minimal mutual
exclusion: the second run is refused outright instead of racing the first.

The lock is an advisory `flock` on a single small file, held for the whole run:

* it is taken **before** the app is resolved, the fixture is started, the port
  is bound or the controlled page is opened, so a refused run has done nothing
  at all to the desktop or to the active run's state;
* it is released on every exit path (normal, timeout, SIGINT, exception) by the
  `finally` of the context manager — and by the kernel if this process is
  killed outright, so an interrupted run never leaves the machine serialised
  behind it;
* the lock file is **never unlinked**. Deleting it would let a third runner
  create a brand-new file and lock that while the first run still holds the old
  inode, which is the classic TOCTOU hole this whole module exists to avoid.

The file carries who holds it (pid, start time, mode, evidence directory) so a
refused run can name the active one in its report instead of guessing.
"""
from __future__ import annotations

import contextlib
import datetime as _datetime
import errno
import fcntl
import getpass
import json
import os
import socket
from pathlib import Path

# The one file that serialises a machine's acceptance runs. It is a dotfile so
# it never looks like evidence and is never read back as a result.
LOCK_FILE_NAME = ".her-acceptance.lock"

# Modes that are allowed to touch the desktop/fixture and therefore take the
# lock. `self_test` never reaches the run path at all, and an ad-hoc in-process
# caller that passes some other mode is not serialised either.
MUTEXED_MODES = frozenset({"full", "dry_run"})

# An advisory flock reports contention with these errno values (EWOULDBLOCK is
# the same number as EAGAIN on POSIX, but both are named for readability).
_CONTENTION_ERRNOS = frozenset({errno.EACCES, errno.EAGAIN, errno.EWOULDBLOCK})

_ACQUIRED = "acquired"
_CONTENDED = "contended"
_ERROR = "error"


class RunMutexError(RuntimeError):
    """The mutex itself could not be used (never a contention report)."""


def default_lock_path(out_dir: Path | str) -> Path:
    """Where the run whose evidence directory is `out_dir` places its lock.

    A run whose evidence lives under an `out/acceptance/` tree locks that shared
    `out/acceptance/.her-acceptance.lock`, so two runs serialise even when they
    were handed different `--out` directories — the dangerous pair is two
    desktop runs, not two identically named directories. Any other evidence
    root (a self-test workspace, an ad-hoc directory outside the repo) locks
    beside its own `--out`, so a test run can neither serialise nor be
    serialised by a real acceptance run on the same machine.
    """
    resolved = Path(out_dir).expanduser().resolve()
    shared = _shared_evidence_root(resolved)
    if shared is not None:
        return shared / LOCK_FILE_NAME
    return resolved.parent / LOCK_FILE_NAME


def _shared_evidence_root(resolved: Path) -> Path | None:
    """The nearest `out/acceptance` directory at or above `resolved`, if any."""
    for ancestor in (resolved, *resolved.parents):
        if ancestor.name == "acceptance" and ancestor.parent.name == "out":
            return ancestor
    return None


def lock_path_for_options(options) -> Path:
    """The lock path a `RunOptions`-shaped object will use."""
    explicit = getattr(options, "run_lock_path", None)
    if explicit:
        return Path(explicit).expanduser()
    return default_lock_path(options.out_dir)


class RunLock:
    """One acquisition attempt against one lock file.

    Exactly one of three states: `acquired` (this process owns the run),
    `contended` (another live run owns it) or `error` (the mutex could not be
    used at all). Contention and error are both refusals, but they say
    different things and must never be reported as each other.
    """

    def __init__(self, path: Path, state: str, pid: int | None = None,
                 holder: dict | None = None, detail: str = "", fd: int | None = None):
        self.path = Path(path)
        self.state = state
        self.pid = pid
        self.holder = dict(holder or {})
        self.detail = detail
        self._fd = fd

    @property
    def acquired(self) -> bool:
        return self.state == _ACQUIRED

    @property
    def denied(self) -> bool:
        """True when this run must not proceed (contended or unusable mutex)."""
        return self.state in (_CONTENDED, _ERROR)

    def denial_reason(self) -> str:
        """The exact sentence that goes into the refused run's report."""
        if self.state == _CONTENDED:
            pid_text = str(self.pid) if self.pid else "unknown"
            details = [f"started {self.holder.get('started_at') or 'an unknown time'}"]
            if self.holder.get("mode"):
                details.append(f"mode {self.holder['mode']}")
            if self.holder.get("out_dir"):
                details.append(f"evidence directory {self.holder['out_dir']}")
            return (f"another acceptance run is active (pid {pid_text}; "
                    + "; ".join(details) + ")")
        return (f"the run mutex at {self.path} could not be acquired, so a second "
                f"concurrent run cannot be excluded: {self.detail or 'unknown error'}")

    def release(self) -> None:
        """Drop the advisory lock. Idempotent, and never removes the file."""
        if self._fd is None:
            return
        try:
            fcntl.flock(self._fd, fcntl.LOCK_UN)
        except OSError:
            pass
        finally:
            try:
                os.close(self._fd)
            except OSError:
                pass
            self._fd = None

    def to_evidence(self) -> dict:
        """The evidence-sized projection of one acquisition attempt."""
        return {
            "lock_file": str(self.path),
            "state": self.state,
            "this_pid": os.getpid(),
            "holder": self.holder,
            "detail": self.detail,
            "note": ("An advisory flock on one file, held for the whole run and "
                     "released in the run's finally path (and by the kernel if "
                     "this process dies); the file is never unlinked, because "
                     "replacing it would let a third run lock a fresh inode "
                     "while the first still holds the old one."),
        }


def _owner_record(owner: dict | None) -> dict:
    record = {
        "pid": os.getpid(),
        "ppid": os.getppid(),
        "started_at": _datetime.datetime.now(_datetime.UTC).isoformat(),
        "host": socket.gethostname(),
        "user": _safe_user(),
    }
    for key, value in (owner or {}).items():
        if isinstance(value, (str, int, float, bool)) or value is None:
            record[key] = value
        else:
            record[key] = str(value)
    return record


def _safe_user() -> str:
    try:
        return getpass.getuser()
    except Exception:  # noqa: BLE001 - the record is informational only
        return "unknown"


def _write_holder(fd: int, record: dict) -> str:
    payload = json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    os.ftruncate(fd, 0)
    os.lseek(fd, 0, os.SEEK_SET)
    os.write(fd, payload.encode("utf-8"))
    return payload


def _read_holder(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def acquire(path: Path | str, owner: dict | None = None) -> RunLock:
    """Try to take the lock at `path`. Never raises; reports what happened.

    `owner` adds identifying fields (mode, evidence directory, ...) to the
    holder record a later, refused run will read.
    """
    lock_path = Path(path).expanduser()
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as error:
        return RunLock(lock_path, _ERROR, pid=os.getpid(),
                       detail=f"{type(error).__name__}: {error}")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        try:
            os.close(fd)
        except OSError:
            pass
        if error.errno in _CONTENTION_ERRNOS:
            holder = _read_holder(lock_path)
            return RunLock(lock_path, _CONTENDED, pid=holder.get("pid"),
                           holder=holder,
                           detail="the advisory lock is held by another process")
        return RunLock(lock_path, _ERROR, pid=os.getpid(),
                       detail=f"{type(error).__name__}: {error}")

    holder = _owner_record(owner)
    detail = ""
    try:
        _write_holder(fd, holder)
    except OSError as error:
        # The lock is held either way; only the identification of *who* holds it
        # is degraded, which a refused run reports as an unknown pid.
        detail = f"the holder record could not be written: {error}"
    return RunLock(lock_path, _ACQUIRED, pid=holder.get("pid"), holder=holder,
                   detail=detail, fd=fd)


def release(lock: RunLock | None) -> None:
    if lock is not None:
        lock.release()


@contextlib.contextmanager
def hold(path: Path | str, owner: dict | None = None):
    """Hold the lock at `path` for the duration of the `with` block."""
    lock = acquire(path, owner)
    try:
        yield lock
    finally:
        lock.release()


@contextlib.contextmanager
def hold_for_run(options):
    """Hold the run mutex for a `RunOptions`-shaped object, or yield None.

    None means this mode does not take the desktop (or is not a run at all), so
    the caller proceeds without any lock. Otherwise the yielded `RunLock` is
    either acquired — the run owns the machine — or denied, in which case the
    caller must refuse and report instead of proceeding.
    """
    mode = getattr(options, "mode", None)
    if mode not in MUTEXED_MODES:
        yield None
        return
    with hold(lock_path_for_options(options),
              owner={"mode": mode, "out_dir": str(options.out_dir)}) as lock:
        yield lock

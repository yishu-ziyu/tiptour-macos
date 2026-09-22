"""Child-process control with one hard invariant.

The runner only ever terminates processes it spawned itself. Detection helpers
(`find_processes_matching`) exist to *record* what is running — most
importantly the user's own Her instance — and are never used to kill anything.
"""
from __future__ import annotations

import os
import signal
import socket
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class OwnedProcess:
    """A process this runner started; the only kind it may terminate."""

    label: str
    process: subprocess.Popen
    log_path: Path | None = None

    @property
    def pid(self) -> int:
        return self.process.pid

    def poll(self) -> int | None:
        return self.process.poll()


class OwnedProcessRegistry:
    """Tracks spawned children so termination can never touch a foreign PID."""

    def __init__(self) -> None:
        self._processes: list[OwnedProcess] = []

    def register(self, owned: OwnedProcess) -> OwnedProcess:
        self._processes.append(owned)
        return owned

    def all(self) -> list[OwnedProcess]:
        return list(self._processes)

    def running(self) -> list[OwnedProcess]:
        return [owned for owned in self._processes if owned.poll() is None]

    def terminate_all(self, grace_seconds: float = 5.0) -> list[dict]:
        results: list[dict] = []
        for owned in self.running():
            results.append(terminate_owned_process(owned, grace_seconds=grace_seconds))
        return results


def terminate_owned_process(owned: OwnedProcess, grace_seconds: float = 5.0) -> dict:
    """Stop a registered child: SIGTERM, bounded wait, then SIGKILL.

    Returns a record for the evidence artifact. The PID is only ever signalled
    after confirming it is still the same child this runner spawned.
    """
    result: dict = {"label": owned.label, "pid": owned.pid, "self_exited": False,
                    "returncode": None, "terminated": False, "killed_after_grace": False}
    process = owned.process
    returncode = process.poll()
    if returncode is not None:
        result["self_exited"] = True
        result["returncode"] = returncode
        return result
    try:
        process.terminate()
    except ProcessLookupError:
        result["self_exited"] = True
        result["returncode"] = process.poll()
        return result
    try:
        result["returncode"] = process.wait(timeout=grace_seconds)
        result["terminated"] = True
        return result
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            pass
        result["returncode"] = process.poll()
        result["killed_after_grace"] = True
        result["terminated"] = True
        return result


def spawn_owned_process(
    registry: OwnedProcessRegistry,
    label: str,
    argv: list[str],
    log_path: Path | None = None,
) -> OwnedProcess:
    """Spawn a child with its combined output captured in a log file."""
    log_handle = None
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_handle = open(log_path, "wb")
    try:
        process = subprocess.Popen(
            argv,
            stdout=log_handle if log_handle else subprocess.DEVNULL,
            stderr=subprocess.STDOUT if log_handle else subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    finally:
        if log_handle is not None:
            log_handle.close()
    return registry.register(OwnedProcess(label=label, process=process, log_path=log_path))


def wait_for_owned_exit(owned: OwnedProcess, timeout_seconds: float) -> dict:
    """Wait for a spawned child to exit by itself, recording how it ended."""
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        returncode = owned.poll()
        if returncode is not None:
            return {"pid": owned.pid, "self_exited": True, "returncode": returncode,
                    "timed_out": False}
        time.sleep(0.2)
    return {"pid": owned.pid, "self_exited": False, "returncode": None,
            "timed_out": True}


def run_capture(argv: list[str], timeout_seconds: float = 30.0) -> dict:
    """Run a short helper command and capture its output for evidence."""
    try:
        completed = subprocess.run(
            argv, capture_output=True, text=True, timeout=timeout_seconds, check=False
        )
    except subprocess.TimeoutExpired as error:
        return {"argv": argv, "returncode": None, "stdout": "", "stderr": "",
                "timed_out": True, "error": str(error)}
    except OSError as error:
        return {"argv": argv, "returncode": None, "stdout": "", "stderr": "",
                "timed_out": False, "error": str(error)}
    return {"argv": argv, "returncode": completed.returncode,
            "stdout": completed.stdout, "stderr": completed.stderr,
            "timed_out": False, "error": None}


def find_processes_matching(pattern: str) -> list[dict]:
    """Record (never kill) processes whose command line contains `pattern`."""
    listing = run_capture(["pgrep", "-fl", pattern], timeout_seconds=15.0)
    processes: list[dict] = []
    for line in listing["stdout"].splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        if not pid_text.isdigit():
            continue
        processes.append({"pid": int(pid_text), "command": command.strip()})
    return processes


def port_accepts_connections(host: str, port: int, timeout_seconds: float = 1.0) -> bool:
    """True when something is already listening on the port."""
    try:
        with socket.create_connection((host, port), timeout=timeout_seconds):
            return True
    except OSError:
        return False


def pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def send_signal_to_pid(pid: int, signal_number: int) -> bool:
    """Used only by self-tests to prove stray-PID termination is refused."""
    try:
        os.kill(pid, signal_number)
    except OSError:
        return False
    return True


@dataclass
class ProcessAudit:
    """Snapshot of who was running before/after the acceptance run."""

    before: list[dict] = field(default_factory=list)
    after: list[dict] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {"before": self.before, "after": self.after}

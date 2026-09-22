"""Child-process control with one hard invariant.

The runner only ever terminates processes it spawned itself. Detection helpers
(`find_processes_matching`) exist to *record* what is running — most
importantly the user's own Her instance — and are never used to kill anything.

An app Mach-O is the one case where the runner cannot fork its own child: a
signed GUI app has to be started by LaunchServices, and the resulting instance
is only ever stopped by the PID that launch was able to identify
(`launch_services`). Everything else still goes through a plain fork/exec.
"""
from __future__ import annotations

import os
import signal
import socket
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

from . import launch_services


@dataclass
class OwnedProcess:
    """A process this runner started; the only kind it may terminate."""

    label: str
    process: subprocess.Popen | launch_services.LaunchedInstanceHandle
    log_path: Path | None = None
    # Set only for a LaunchServices instance: how it was launched and how its
    # PID was identified. Evidence for the runner's exit and cleanup records.
    launch_record: dict = field(default_factory=dict)

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
    if _is_launched_instance(owned):
        return _terminate_launched_instance(owned, grace_seconds=grace_seconds)
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
    """Start a child this runner may later stop, and record it in the registry.

    An argv whose first element is the Mach-O inside an .app bundle is started
    through LaunchServices, never by exec-ing it: that is the supported way to
    start a signed GUI app, and it is what gives the probe process the app's own
    identity and permissions (see launch_services). Every other argv keeps the
    plain fork/exec path. A LaunchServices failure raises `LaunchServicesError`
    (an OSError, so a "process could not be started" handler records a BLOCKED
    reason) with a structured record for the caller - there is no silent
    fallback to a direct Popen of the Mach-O.
    """
    plan = launch_services.plan_launch(argv)
    if plan is None:
        return _fork_owned_process(registry, label, argv, log_path)
    outcome = launch_services.launch_app_instance(
        app_path=plan.app_path,
        app_argv=plan.app_argv,
        requested_argv=[str(token) for token in argv],
        binary=plan.binary,
    )
    if not outcome.ok:
        raise launch_services.LaunchServicesError(outcome)
    if log_path is not None:
        # The app's own stdout/stderr are not ours to capture; say so in the
        # log rather than shipping an empty file that looks like probe output.
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(launch_services.format_launch_log(outcome), encoding="utf-8")
    handle = launch_services.LaunchedInstanceHandle(
        pid=int(outcome.pid or 0),
        binary=str(plan.binary),
        probe_flag=plan.app_argv[0] if plan.app_argv else None,
    )
    return registry.register(OwnedProcess(
        label=label, process=handle, log_path=log_path,
        launch_record=outcome.to_dict(),
    ))


def _fork_owned_process(
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


def _terminate_launched_instance(owned: OwnedProcess, grace_seconds: float = 5.0) -> dict:
    """Stop exactly the instance the launch identified - nothing else.

    The PID came from the process listing, not from a name match, so a signal
    here can only ever reach the instance this runner asked LaunchServices to
    start. If that instance is already gone, nothing is signalled at all.
    """
    result: dict = {
        "label": owned.label, "pid": owned.pid, "self_exited": False,
        "returncode": None, "terminated": False, "killed_after_grace": False,
        "signal": None, "not_signalled_because": None,
        "returncode_basis": launch_services.RETURNCODE_UNAVAILABLE_BASIS,
        "launch_services": owned.launch_record,
    }
    process = owned.process
    if process.poll() is not None:
        result["self_exited"] = True
        result["not_signalled_because"] = "the identified instance had already terminated"
        return result
    try:
        process.terminate()
        result["signal"] = "SIGTERM"
    except ProcessLookupError as error:
        result["self_exited"] = True
        result["not_signalled_because"] = str(error)
        return result
    try:
        process.wait(timeout=grace_seconds)
        result["terminated"] = True
        return result
    except subprocess.TimeoutExpired:
        pass
    try:
        process.kill()
        result["signal"] = "SIGKILL"
    except ProcessLookupError:
        result["self_exited"] = True
        result["not_signalled_because"] = "the identified instance exited during the grace period"
        return result
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        pass
    result["killed_after_grace"] = True
    result["terminated"] = True
    return result


def _is_launched_instance(owned: OwnedProcess) -> bool:
    """True for an app instance LaunchServices started (we did not fork it)."""
    return isinstance(owned.process, launch_services.LaunchedInstanceHandle)


def wait_for_owned_exit(owned: OwnedProcess, timeout_seconds: float) -> dict:
    """Wait for a spawned child to exit by itself, recording how it ended."""
    if _is_launched_instance(owned):
        return _wait_for_launched_instance_exit(owned, timeout_seconds)
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        returncode = owned.poll()
        if returncode is not None:
            return {"pid": owned.pid, "self_exited": True, "returncode": returncode,
                    "timed_out": False}
        time.sleep(0.2)
    return {"pid": owned.pid, "self_exited": False, "returncode": None,
            "timed_out": True}


def _wait_for_launched_instance_exit(owned: OwnedProcess, timeout_seconds: float) -> dict:
    """Wait for the LaunchServices instance this runner identified to terminate.

    The runner is not that instance's parent, so there is no wait() and no exit
    status: what is observable is that the instance is gone, that the runner
    never signalled it, and whether the probe's own report artifact is there.
    `returncode` is therefore only ever the documented derived value, never an
    invented status.
    """
    result: dict = {
        "pid": owned.pid, "self_exited": False, "returncode": None, "timed_out": False,
        "observed_alive": False, "report_artifact_present": None,
        "returncode_basis": launch_services.RETURNCODE_UNAVAILABLE_BASIS,
        "launch_services": owned.launch_record,
    }
    artifact = owned.launch_record.get("report_artifact_hint")
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if owned.poll() is None:
            result["observed_alive"] = True
        else:
            # Gone on its own: the runner sent this instance no signal at all.
            result["self_exited"] = True
            break
        time.sleep(0.1)
    else:
        result["timed_out"] = True

    if artifact:
        result["report_artifact_present"] = launch_services.report_artifact_present(artifact)
    if result["self_exited"] and result["report_artifact_present"]:
        result["returncode"] = 0
        result["returncode_basis"] = launch_services.RETURNCODE_DERIVED_BASIS
    return result


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

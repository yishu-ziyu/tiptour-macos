"""Launch a signed GUI app through LaunchServices, and own only that instance.

Why this module exists: the runner used to start the DEBUG app's probe by
Popen-ing the Mach-O inside Her.app. That is not a supported way to start a
signed GUI app -- the recheck measured accessibility=false in exactly such a
child process, while the normally launched app has the permissions -- and a
forked Mach-O left the runner with nothing but a process name to tell its
child apart from the user's own Her.

`open -n -a <Her.app> --args <argv>` hands the launch to LaunchServices, the
same machinery that starts the product, so the probe process runs with the
app's real identity and permissions. Two invariants follow and are enforced
here:

* No silent fallback. When the LaunchServices launch cannot be proven, the
  caller gets a structured failure (`LaunchOutcome` / `LaunchServicesError`,
  an OSError) and never a Popen of the Mach-O.
* Kill only the instance we identified. The PID is discovered by watching the
  exact Mach-O path for a process whose start time is after the launch began.
  A name match is never enough, an ambiguous match is refused, and an instance
  that cannot be identified is never signalled.
"""
from __future__ import annotations

import os
import signal
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

# The supported launch shape: a new instance of an existing app bundle, with
# the probe argv handed to the app after --args. "-n" is what keeps the user's
# already-running Her from being reused for our probe.
LAUNCH_SERVICES_COMMAND = ["open", "-n", "-a"]
LAUNCH_SERVICES_DESCRIPTION = "LaunchServices (open -n -a <app> --args <argv>)"

PROCESS_LISTING_ARGUMENTS = ["ps", "-Ao", "pid=,lstart=,command="]
PROCESS_LISTING_TIMEOUT_SECONDS = 20.0
OPEN_TIMEOUT_SECONDS = 60.0
DISCOVERY_TIMEOUT_SECONDS = 15.0
DISCOVERY_POLL_SECONDS = 0.15

# lstart has one-second resolution, so a process that started in the same
# second as our launch request is still a candidate; nothing older is.
START_TIME_TOLERANCE_SECONDS = 1.0

# What an exit status means for an instance the runner did not fork. Stated
# once so every evidence record says exactly the same thing.
RETURNCODE_UNAVAILABLE_BASIS = (
    "unavailable: LaunchServices owns the parent relationship, so the runner is not "
    "the instance's parent and the kernel reports it no exit status"
)
RETURNCODE_DERIVED_BASIS = (
    "derived: the identified instance terminated without any signal from the runner and "
    "the probe's report artifact is present; the exit status itself is not observable "
    "because LaunchServices, not the runner, is the instance's parent"
)


class LaunchServicesError(OSError):
    """A LaunchServices launch that could not be proven. Never falls back.

    It is an OSError because that is what "the process could not be started"
    already means to the runner's callers, so an existing handler records a
    BLOCKED reason instead of the run dying without evidence.
    """

    def __init__(self, outcome: "LaunchOutcome") -> None:
        self.outcome = outcome
        super().__init__(outcome.error or f"LaunchServices launch failed: {outcome.status}")

    def to_dict(self) -> dict:
        return self.outcome.to_dict()


@dataclass(frozen=True)
class LaunchPlan:
    """Everything needed to start `argv` the supported way."""

    binary: Path          # the Mach-O the caller asked to run (evidence only)
    app_path: Path        # <Her.app>
    app_argv: list[str]   # argv the app receives after --args
    command: list[str]    # the exact command the runner executes

    def to_dict(self) -> dict:
        return {"binary": str(self.binary), "app_path": str(self.app_path),
                "app_argv": list(self.app_argv), "command": list(self.command)}


def app_bundle_for_binary(binary: Path) -> Path | None:
    """The .app bundle owning this Mach-O, or None when it is not in one.

    Only the canonical `<App.app>/Contents/MacOS/<executable>` layout counts:
    anything else is not a bundle LaunchServices can be asked to open.
    """
    parts = binary.parts
    if len(parts) < 4 or parts[-3] != "Contents" or parts[-2] != "MacOS":
        return None
    bundle = Path(*parts[:-3])
    return bundle if bundle.suffix == ".app" else None


def plan_launch(argv: list[str]) -> LaunchPlan | None:
    """Plan a LaunchServices launch, or None when `argv` is not an app Mach-O.

    The app receives everything after the Mach-O: `open -a X --args a b` gives
    the app argv `[<executable>, a, b]`, so passing the Mach-O path again would
    corrupt the probe's argument count.
    """
    if not argv:
        return None
    binary = Path(argv[0])
    app_path = app_bundle_for_binary(binary)
    if app_path is None:
        return None
    if not app_path.is_absolute():
        # A relative --app must still produce a runnable, reviewable command.
        app_path = app_path.absolute()
    app_argv = [str(token) for token in argv[1:]]
    return LaunchPlan(binary=binary, app_path=app_path, app_argv=app_argv,
                      command=build_open_command(app_path, app_argv))


def build_open_command(app_path: Path, app_argv: list[str]) -> list[str]:
    return [*LAUNCH_SERVICES_COMMAND, str(app_path), "--args", *app_argv]


def report_artifact_for_argv(argv: list[str]) -> str | None:
    """The report path (or output directory) the probe was given as its argument.

    Probe entrypoints take their report destination last; the runner passes it
    in today and still does, which is what lets a LaunchServices instance be
    waited for in terms of the probe's own artifact.
    """
    for token in reversed([str(token) for token in argv[1:]]):
        if token.startswith("/"):
            return token
    return None


def report_artifact_present(path_text: str) -> bool:
    """True when the probe's report artifact exists (file, or a non-empty dir)."""
    path = Path(path_text)
    if path.is_file():
        return True
    if path.is_dir():
        return any(child.is_file() for child in path.rglob("*"))
    return False


# ------------------------------------------------------------ process discovery


def launched_instance_is_alive(pid: int) -> bool:
    """Liveness only: signal 0 neither signals nor proves identity."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def argv0_spellings(binary: str | Path) -> list[str]:
    """The path spellings that all name the same Mach-O.

    `ps` reports whatever argv[0] the launcher used, which may be absolute,
    relative, or symlink-resolved (/var vs /private/var on macOS). Matching one
    spelling only would make identity depend on how --app was typed.
    """
    path = Path(binary)
    candidates = [str(path)]
    for spelling in (path.absolute(), path.resolve()):
        try:
            text = str(spelling)
        except OSError:
            continue
        if text not in candidates:
            candidates.append(text)
    return candidates


def pid_command(pid: int) -> str | None:
    """argv[0] of a live pid, or None when the pid is gone (one `ps -p`)."""
    try:
        completed = subprocess.run(
            ["ps", "-p", str(pid), "-o", "command="],
            capture_output=True, text=True, check=False, timeout=10.0,
            env=dict(os.environ, LC_ALL="C", LANG="C"),
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    line = completed.stdout.strip()
    return line.split()[0] if line else None


def pid_is_our_instance(pid: int, binary: str) -> bool:
    """True only while this pid is still the exact instance we launched.

    Liveness alone cannot tell our instance from a recycled pid; before the
    runner signals anything it re-reads the pid's argv[0] and refuses to signal
    a process that is no longer the one LaunchServices started for us.
    """
    return pid_command(pid) in argv0_spellings(binary)


def _read_process_listing() -> dict:
    """`ps -Ao pid=,lstart=,command=` under the C locale, where lstart is fixed.

    A locale-dependent listing would make start times unparsable on the very
    machine whose evidence has to be reproducible.
    """
    try:
        completed = subprocess.run(
            PROCESS_LISTING_ARGUMENTS,
            capture_output=True, text=True, check=False,
            timeout=PROCESS_LISTING_TIMEOUT_SECONDS,
            env=dict(os.environ, LC_ALL="C", LANG="C"),
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"returncode": None, "stdout": "", "stderr": "", "error": str(error)}
    return {"returncode": completed.returncode, "stdout": completed.stdout,
            "stderr": completed.stderr, "error": None}


def _parse_lstart(fields: list[str]) -> float | None:
    """Epoch seconds for the five-field `lstart` column, or None if unparsable."""
    try:
        return datetime.strptime(" ".join(fields), "%a %b %d %H:%M:%S %Y").timestamp()
    except ValueError:
        return None


def find_binary_processes(binary_path: str | Path) -> dict:
    """Rows whose argv[0] is exactly this Mach-O path, with their start times.

    Exact argv[0] matching is deliberate: a substring would also match the
    user's Her at a different path, a shell that mentions the path, or this
    runner's own bookkeeping commands.
    """
    binary = str(binary_path)
    listing = _read_process_listing()
    rows: list[dict] = []
    unparsable: list[str] = []
    spellings = argv0_spellings(binary)
    for line in listing["stdout"].splitlines():
        fields = line.split()
        if len(fields) < 7 or not fields[0].isdigit():
            # Fewer than pid + five lstart fields + one argv token: not a row
            # this module can attribute to any process at all.
            continue
        if fields[6] not in spellings:
            continue
        start_time = _parse_lstart(fields[1:6])
        if start_time is None:
            unparsable.append(" ".join(fields[1:6]))
        rows.append({
            "pid": int(fields[0]),
            "start_time": start_time,
            "start_time_text": " ".join(fields[1:6]),
            "command": " ".join(fields[6:]),
            "argv0": fields[6],
            "probe_flag": fields[7] if len(fields) > 7 else None,
        })
    return {"binary": binary, "argv0_spellings": spellings, "rows": rows,
            "unparsable_start_times": unparsable,
            "listing_returncode": listing["returncode"],
            "listing_error": listing["error"]}


def _corroborated_by_probe_flag(row: dict, probe_flag: str | None) -> bool:
    """The instance's own argv carries the probe flag we passed it."""
    if not probe_flag:
        return False
    return row.get("probe_flag") == probe_flag


@dataclass
class InstanceIdentification:
    """How the runner decided which process is ours. Evidence, not a claim."""

    identified: bool
    method: str
    binary: str
    before_pids: list[int] = field(default_factory=list)
    candidates: list[dict] = field(default_factory=list)
    narrowed_by: str | None = None
    ambiguous: bool = False
    elapsed_seconds: float = 0.0
    reason: str | None = None

    def to_dict(self) -> dict:
        return {
            "identified": self.identified,
            "pid": self.candidates[0]["pid"] if self.identified and self.candidates else None,
            "method": self.method,
            "binary": self.binary,
            "before_pids": list(self.before_pids),
            "candidates": [dict(candidate) for candidate in self.candidates],
            "narrowed_by": self.narrowed_by,
            "ambiguous": self.ambiguous,
            "elapsed_seconds": round(self.elapsed_seconds, 3),
            "reason": self.reason,
        }


def identify_launched_instance(
    binary_path: str | Path,
    launched_at_epoch: float,
    before_pids: list[int],
    probe_flag: str | None = None,
    discovery_timeout_seconds: float = DISCOVERY_TIMEOUT_SECONDS,
) -> InstanceIdentification:
    """Find the Mach-O process that this launch started, and only that one.

    A candidate must be (a) not already running when the launch began and
    (b) started no earlier than the launch request. When more than one
    candidate survives, the probe flag in the instance's own argv narrows it;
    if it still is not unique, the launch is reported as unidentified rather
    than guessed at.
    """
    started_at = time.monotonic()
    deadline = started_at + discovery_timeout_seconds
    before = sorted({int(pid) for pid in before_pids})
    while True:
        rows = find_binary_processes(binary_path)["rows"]
        fresh = [
            row for row in rows
            if row["pid"] not in before
            and row["start_time"] is not None
            and row["start_time"] >= launched_at_epoch - START_TIME_TOLERANCE_SECONDS
            and launched_instance_is_alive(row["pid"])
        ]
        corroborated = [row for row in fresh if _corroborated_by_probe_flag(row, probe_flag)]
        narrowed_by = None
        pool = fresh
        if probe_flag and len(corroborated) == 1 and len(fresh) > 1:
            pool = corroborated
            narrowed_by = f"argv[1] of the instance equals the probe flag {probe_flag!r}"
        if len(pool) == 1:
            return InstanceIdentification(
                identified=True,
                method=(f"{' '.join(PROCESS_LISTING_ARGUMENTS)} rows whose argv[0] is exactly "
                        f"{binary_path} and whose lstart is after the launch request, excluding "
                        f"the {len(before)} instance pid(s) already running"),
                binary=str(binary_path),
                before_pids=before,
                candidates=[dict(pool[0])],
                narrowed_by=narrowed_by,
                ambiguous=False,
                elapsed_seconds=time.monotonic() - started_at,
            )
        if time.monotonic() >= deadline:
            reason = ("no new instance of the exact Mach-O path appeared" if not fresh
                      else f"{len(fresh)} new instances appeared and could not be told apart")
            return InstanceIdentification(
                identified=False,
                method=(f"{' '.join(PROCESS_LISTING_ARGUMENTS)} rows whose argv[0] is exactly "
                        f"{binary_path} and whose lstart is after the launch request"),
                binary=str(binary_path),
                before_pids=before,
                candidates=[dict(row) for row in fresh],
                ambiguous=len(fresh) > 1,
                elapsed_seconds=time.monotonic() - started_at,
                reason=reason,
            )
        time.sleep(DISCOVERY_POLL_SECONDS)


# ----------------------------------------------------------------- the launch


@dataclass
class LaunchOutcome:
    """Structured result of one LaunchServices launch attempt."""

    status: str                     # launched | launch_failed | instance_unidentified
    command: list[str]
    requested_argv: list[str]
    app_path: str
    app_argv: list[str] = field(default_factory=list)
    returncode: int | None = None
    stdout: str = ""
    stderr: str = ""
    error: str | None = None
    launched_at_iso: str | None = None
    identification: dict = field(default_factory=dict)
    report_artifact_hint: str | None = None

    @property
    def ok(self) -> bool:
        return self.status == "launched"

    @property
    def pid(self) -> int | None:
        if self.status != "launched":
            return None
        return self.identification.get("pid")

    def to_dict(self) -> dict:
        return {
            "launcher": LAUNCH_SERVICES_DESCRIPTION,
            "command": list(self.command),
            "returncode": self.returncode,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "requested_argv": list(self.requested_argv),
            "app_path": self.app_path,
            "app_argv": list(self.app_argv),
            "status": self.status,
            "error": self.error,
            "launched_at": self.launched_at_iso,
            "instance_identification": dict(self.identification),
            "report_artifact_hint": self.report_artifact_hint,
            "direct_popen_fallback": False,
        }


def launch_app_instance(
    app_path: Path,
    app_argv: list[str],
    requested_argv: list[str],
    binary: Path | None = None,
    probe_flag: str | None = None,
    discovery_timeout_seconds: float = DISCOVERY_TIMEOUT_SECONDS,
) -> LaunchOutcome:
    """Start a new app instance and report exactly what happened.

    `requested_argv` is the argv the runner would have exec'd (its first element
    is the Mach-O); it is recorded so evidence still shows the full command.
    """
    if binary is None:
        binary = app_path / "Contents/MacOS" / app_path.stem
    command = build_open_command(app_path, app_argv)
    binary = Path(binary)
    # The probe entrypoint flag (e.g. --desktop-task-probe) is the strongest
    # independent corroboration that an instance is the one we asked for.
    probe_flag = app_argv[0] if app_argv and app_argv[0].startswith("--") else None

    # Snapshot what is already running first: the user's Her is exactly the
    # instance that must never be mistaken for ours.
    before_pids = [row["pid"] for row in find_binary_processes(binary)["rows"]]
    launched_at_epoch = time.time()
    launched_at_iso = datetime.fromtimestamp(launched_at_epoch).astimezone().isoformat()

    open_result = run_open_command(command)
    if open_result["error"] is not None:
        return LaunchOutcome(
            status="launch_failed", command=command, requested_argv=list(requested_argv),
            app_path=str(app_path), app_argv=list(app_argv),
            stdout=open_result["stdout"], stderr=open_result["stderr"],
            error=open_result["error"],
            launched_at_iso=launched_at_iso, report_artifact_hint=report_artifact_for_argv(requested_argv),
        )
    if open_result["returncode"] != 0:
        return LaunchOutcome(
            status="launch_failed", command=command, requested_argv=list(requested_argv),
            app_path=str(app_path), app_argv=list(app_argv),
            returncode=open_result["returncode"],
            stdout=open_result["stdout"], stderr=open_result["stderr"],
            error=(f"LaunchServices refused the launch: "
                   f"{(open_result['stderr'] or open_result['stdout']).strip() or 'no diagnostic output'}"),
            launched_at_iso=launched_at_iso, report_artifact_hint=report_artifact_for_argv(requested_argv),
        )

    identification = identify_launched_instance(
        binary, launched_at_epoch, before_pids, probe_flag=probe_flag,
        discovery_timeout_seconds=discovery_timeout_seconds,
    ).to_dict()
    artifact_hint = report_artifact_for_argv(requested_argv)
    if not identification["identified"]:
        return LaunchOutcome(
            status="instance_unidentified", command=command,
            requested_argv=list(requested_argv), app_path=str(app_path),
            app_argv=list(app_argv), returncode=open_result["returncode"],
            stdout=open_result["stdout"], stderr=open_result["stderr"],
            error=(f"LaunchServices reported success but no instance of {binary} could be "
                   f"identified as ours ({identification.get('reason')}); nothing was signalled "
                   f"and no direct Mach-O launch was attempted."),
            launched_at_iso=launched_at_iso, identification=identification,
            report_artifact_hint=artifact_hint,
        )
    return LaunchOutcome(
        status="launched", command=command, requested_argv=list(requested_argv),
        app_path=str(app_path), app_argv=list(app_argv),
        returncode=open_result["returncode"], stdout=open_result["stdout"],
        stderr=open_result["stderr"],
        error=None, launched_at_iso=launched_at_iso, identification=identification,
        report_artifact_hint=artifact_hint,
    )


def run_open_command(command: list[str]) -> dict:
    """Run the `open` request itself. It returns as soon as the launch is made."""
    try:
        completed = subprocess.run(
            command, capture_output=True, text=True, check=False,
            timeout=OPEN_TIMEOUT_SECONDS, env=dict(os.environ, LC_ALL="C", LANG="C"),
        )
    except subprocess.TimeoutExpired as error:
        return {"returncode": None, "stdout": "", "stderr": "",
                "error": f"LaunchServices did not answer within {OPEN_TIMEOUT_SECONDS}s: {error}"}
    except OSError as error:
        return {"returncode": None, "stdout": "", "stderr": "", "error": str(error)}
    return {"returncode": completed.returncode, "stdout": completed.stdout,
            "stderr": completed.stderr, "error": None}


# ------------------------------------------------------- owning that instance


class LaunchedInstanceHandle:
    """A Popen-compatible view of an instance LaunchServices started.

    The runner is not the instance's parent: there is no wait() and no exit
    status, so `poll()` reports liveness only and `terminate()`/`kill()` signal
    exactly this one PID - after re-reading that PID to confirm it is still the
    instance we launched. Nothing here matches by name.
    """

    def __init__(self, pid: int, binary: str, probe_flag: str | None = None) -> None:
        self.pid = pid
        self.binary = binary
        self.probe_flag = probe_flag

    def poll(self) -> int | None:
        """None while the instance is alive; 0 once it is gone (no status)."""
        return None if launched_instance_is_alive(self.pid) else 0

    def wait(self, timeout: float | None = None) -> int:
        """Wait for the instance to stop being ours (gone, or a different program)."""
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            if not pid_is_our_instance(self.pid, self.binary):
                return 0
            if deadline is not None and time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(cmd=self.binary, timeout=timeout)
            time.sleep(DISCOVERY_POLL_SECONDS)

    def _require_our_instance(self) -> None:
        """Refuse to signal a pid that is no longer the instance we launched."""
        if not launched_instance_is_alive(self.pid):
            raise ProcessLookupError(f"pid {self.pid} is already gone")
        if not pid_is_our_instance(self.pid, self.binary):
            raise ProcessLookupError(
                f"pid {self.pid} is no longer the {self.binary} instance this runner "
                f"launched; it was not signalled"
            )

    def terminate(self) -> None:
        self._require_our_instance()
        signal_launched_instance(self.pid, signal.SIGTERM)

    def kill(self) -> None:
        self._require_our_instance()
        signal_launched_instance(self.pid, signal.SIGKILL)


def signal_launched_instance(pid: int, signal_number: int) -> None:
    """Signal exactly one identified instance PID. Rejects nonsense pids."""
    if not isinstance(pid, int) or pid <= 1:
        raise ValueError(f"refusing to signal pid {pid!r}: not an identified instance")
    os.kill(pid, signal_number)


def format_launch_log(outcome: LaunchOutcome) -> str:
    """What goes into the runner's probe log when there is no fork to capture.

    The app's own stdout/stderr belong to the app's stderr stream, not to a
    pipe the runner owns, so the log says so explicitly instead of pretending
    to be the probe's output.
    """
    lines = [
        "Launched through LaunchServices, not by exec-ing the Mach-O.",
        f"command: {' '.join(outcome.command)}",
        f"status: {outcome.status}",
        f"open returncode: {outcome.returncode}",
        f"open stdout: {outcome.stdout.strip() or '(empty)'}",
        f"open stderr: {outcome.stderr.strip() or '(empty)'}",
        f"instance identification: {outcome.identification}",
        "note: the app process was not forked by the runner, so its own stdout/stderr "
        "are not captured here; the probe's report file is its artifact.",
    ]
    return "\n".join(lines) + "\n"

"""Timeline conversation scripts: schema, validation and probe degradation.

WHY THIS EXISTS
A real user is never a single sentence. They say one thing, wait, interrupt the
answer, change their mind, ask about progress and cancel. The runner today
synthesizes exactly one utterance per scenario (two for `voice_continuity`) and
hands it to a DEBUG probe, so the shapes that actually break a voice assistant -
barge-in during playback, a correction that must not repeat an action, a progress
question that must not invent a completion claim - have no script to be driven
from. This module is the script side of that gap: it owns the conversation script
contract, validates it, synthesizes one PCM per turn through the existing
`synthetic_speech` path, and states plainly how far the current build can go.

REBUILD-GATED SEAM (read this before wiring a multi-turn scenario)
The in-app DEBUG probes are the only sanctioned way to drive the real product
path (`tools/voice-acceptance/README.md`), and today they accept:

  --voice-task-probe       <bundleID> <input.pcm> <outputDir>       (exactly 1 PCM)
  --voice-route-probe      <input.pcm> <outputDir>                 (exactly 1 PCM)
  --voice-continuity-probe <progress.pcm> <cancel.pcm> <report>    (exactly 2 PCM)

Nothing in a signed build can accept "these N utterances at these offsets, one
of them inserted while the previous response is still playing". A multi-turn
conversation script with a barge-in therefore needs a NEW in-app probe mode
(`PROPOSED_CONVERSATION_PROBE_FLAG` below, driven by the manifest this module
writes). Adding that entrypoint means editing `TipTour/Voice/*Probe.swift` and
rebuilding `Her.app` in Xcode - work owned by the app/integration side, so this
module is **rebuild-gated**: it never launches the app, never calls a provider
and never touches the desktop, and it refuses (loudly, by name) to pretend a
barge-in conversation is covered by a single-PCM probe.

Until that rebuild lands, the module still earns its keep by degrading a script
onto the probes that do exist, in their documented argument order:

  1 turn, no barge-in              -> `voice_task`   (one PCM)
  2 turns, no barge-in             -> `voice_continuity` (<progress.pcm> <cancel.pcm>:
                                      turn 0 first, turn 1 second - the same order the
                                      probe's argv documents, never swapped)
  3+ turns, or any barge-in        -> unmapped: `requires_new_probe` with the proposed
                                      argv template for the new probe

`map_conversation_to_probe` returns that decision; `to_probe_request` turns the
degradable cases into a real `ProbeRequest` and raises for the rest, so a runner
that silently dropped turns 3..N cannot be written by accident.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from . import paths
from .probe_runner import ProbeRequest
from .synthetic_speech import UtteranceAudio, synthesize_utterance

# --------------------------------------------------------------------- schema

# Contract version of the conversation script. A script that declares another
# value is refused rather than guessed at.
CONVERSATION_SCRIPT_FORMAT = 1

# Required global keys of a conversation script.
REQUIRED_GLOBAL_KEYS = ("name", "app", "fixture_url", "trace_prefix", "turns")
# Optional global keys. Anything else is a typo, not a forward-compatible extra.
OPTIONAL_GLOBAL_KEYS = ("conversation_format", "acceptance", "description", "note")

# A turn is one user utterance plus what the run should observe around it.
REQUIRED_TURN_KEYS = ("text", "expect")
OPTIONAL_TURN_KEYS = ("wait_ms", "barge_in")

# `expect` fields. At least one must be present: a turn that asserts nothing
# cannot fail, and a scenario that cannot fail is not evidence.
EXPECT_KEYS = ("tool_call", "no_new_action", "speech_contains", "speech_not_contains")

# Bounds. A conversation script is a scripted acceptance conversation, not a
# recording of an afternoon: six turns, one minute of waiting between them and a
# short utterance each keep the run bounded and reviewable.
MAX_TURNS = 6
MAX_WAIT_MS = 60_000
MAX_TURN_TEXT_CHARS = 300
DEFAULT_WAIT_MS = 0
DEFAULT_BARGE_IN = False

# Report file name proposed for the new multi-turn probe.
PROPOSED_CONVERSATION_REPORT_FILE_NAME = "conversation-report.json"
# The in-app probe entrypoint a barge-in conversation would need. It does not
# exist in any build yet: `binary_supports_flag` is how a runner proves that.
PROPOSED_CONVERSATION_PROBE_FLAG = "--voice-conversation-probe"
# Same {placeholder} convention as probe_runner.build_unknown_probe_argv, so the
# template stays inert until a signed binary and a manifest exist to fill it in.
PROPOSED_CONVERSATION_ARGV_TEMPLATE = (
    "{app_binary}", PROPOSED_CONVERSATION_PROBE_FLAG, "{bundle_id}",
    "{manifest}", "{report}",
)

# Where the labeled contract-regression example lives.
CASSETTE_DIRECTORY_NAME = "cassettes"
CONVERSATION_CASSETTE_FILE_NAME = "conversation-example.json"


class ConversationScriptError(RuntimeError):
    """An unusable conversation script, or one the current build cannot drive."""


@dataclass(frozen=True)
class PlannedUtterance:
    """One turn of the script with the PCM the runner synthesized for it.

    `text`/`pcm_path` are the pair the deliverable contract names;
    `as_tuple()` returns exactly that pair, and the extra fields carry the
    timeline facts (wait, barge-in) plus the synthesis metadata the evidence
    package records. Samples are never inspected, only the metadata.
    """

    index: int
    text: str
    wait_ms: int
    barge_in: bool
    pcm_path: Path
    audio: UtteranceAudio

    def as_tuple(self) -> tuple[str, Path]:
        return self.text, self.pcm_path

    def to_dict(self) -> dict:
        record = self.audio.to_dict()
        record.update({
            "index": self.index,
            "wait_ms_before_utterance_ms": self.wait_ms,
            "barge_in": self.barge_in,
        })
        return record


@dataclass(frozen=True)
class ConversationProbeMapping:
    """How a conversation script degrades onto the probes that exist today.

    `mode` is the probe mode to use, or `"unmapped"` when the script needs the
    rebuild-gated multi-turn probe. `utterance_pcm_paths` is already in the
    order that probe's argv expects. `reason` states the decision in words so a
    reader of the evidence never has to re-derive it.
    """

    mode: str
    utterance_pcm_paths: list[Path]
    report_file_name: str
    requires_new_probe: bool
    proposed_argv_template: list[str] | None
    reason: str

    def to_dict(self) -> dict:
        return {
            "mode": self.mode,
            "utterance_pcm_paths": [str(path) for path in self.utterance_pcm_paths],
            "report_file_name": self.report_file_name,
            "requires_new_probe": self.requires_new_probe,
            "proposed_argv_template": list(self.proposed_argv_template or []),
            "reason": self.reason,
        }


# ----------------------------------------------------------------- validation


def turn_count(script) -> int:
    return len(script["turns"]) if isinstance(script, dict) and isinstance(script.get("turns"), list) else 0


def turn_texts(script) -> list[str]:
    return [str(turn.get("text", "")) for turn in script.get("turns", [])]


def barge_in_turn_indices(script) -> list[int]:
    return [index for index, turn in enumerate(script.get("turns", []))
            if isinstance(turn, dict) and turn.get("barge_in", DEFAULT_BARGE_IN) is True]


def total_wait_ms(script) -> int:
    return sum(int(turn.get("wait_ms", DEFAULT_WAIT_MS))
               for turn in script.get("turns", []) if isinstance(turn, dict))


def validate_script(script) -> list[str]:
    """Structural validation of one conversation script.

    Returns the list of problems; an empty list means the script is usable.
    Nothing is executed, no file is written and no probe is consulted, so this
    is safe to call on any cassette found in the repository.
    """
    if not isinstance(script, dict):
        return [f"a conversation script must be a JSON object, got {type(script).__name__}"]

    problems: list[str] = []
    for key in REQUIRED_GLOBAL_KEYS:
        if key not in script:
            problems.append(f"missing required global key {key!r}")
    unknown_globals = sorted(set(script) - set(REQUIRED_GLOBAL_KEYS) - set(OPTIONAL_GLOBAL_KEYS))
    if unknown_globals:
        problems.append(f"unknown global key(s): {', '.join(unknown_globals)}")

    declared_format = script.get("conversation_format", CONVERSATION_SCRIPT_FORMAT)
    if declared_format != CONVERSATION_SCRIPT_FORMAT:
        problems.append(f"'conversation_format' must be {CONVERSATION_SCRIPT_FORMAT}, "
                        f"got {declared_format!r}")
    for key in ("name", "app", "fixture_url", "trace_prefix"):
        if key in script:
            value = script[key]
            if not isinstance(value, str) or not value.strip():
                problems.append(f"{key!r} must be a non-empty string")
    if "acceptance" in script and not isinstance(script["acceptance"], bool):
        problems.append("'acceptance' must be a boolean")

    turns = script.get("turns")
    if not isinstance(turns, list) or not turns:
        problems.append("'turns' must be a non-empty list of turn objects")
        return problems
    if len(turns) > MAX_TURNS:
        problems.append(f"'turns' has {len(turns)} entries; the schema allows at most {MAX_TURNS}")

    for index, turn in enumerate(turns):
        problems.extend(_validate_turn(index, turn))
    return problems


def _validate_turn(index: int, turn) -> list[str]:
    label = f"turn {index}"
    if not isinstance(turn, dict):
        return [f"{label} must be a JSON object"]

    problems: list[str] = []
    unknown = sorted(set(turn) - set(REQUIRED_TURN_KEYS) - set(OPTIONAL_TURN_KEYS))
    if unknown:
        problems.append(f"{label} has unknown key(s): {', '.join(unknown)}")

    text = turn.get("text")
    if not isinstance(text, str) or not text.strip():
        problems.append(f"{label} 'text' must be a non-empty string")
    elif len(text) > MAX_TURN_TEXT_CHARS:
        problems.append(f"{label} 'text' is {len(text)} characters; the schema allows at "
                        f"most {MAX_TURN_TEXT_CHARS}")

    wait_ms = turn.get("wait_ms", DEFAULT_WAIT_MS)
    if isinstance(wait_ms, bool) or not isinstance(wait_ms, int):
        problems.append(f"{label} 'wait_ms' must be an integer number of milliseconds")
    elif not 0 <= wait_ms <= MAX_WAIT_MS:
        problems.append(f"{label} 'wait_ms' must be between 0 and {MAX_WAIT_MS} ms, got {wait_ms}")

    barge_in = turn.get("barge_in", DEFAULT_BARGE_IN)
    if not isinstance(barge_in, bool):
        problems.append(f"{label} 'barge_in' must be a boolean")
    elif barge_in and index == 0:
        problems.append(f"{label} cannot set barge_in: there is no previous utterance whose "
                        "response is still playing, so there is nothing to interrupt")

    problems.extend(_validate_expect(label, turn.get("expect")))
    return problems


def _validate_expect(label: str, expect) -> list[str]:
    if not isinstance(expect, dict):
        return [f"{label} 'expect' must be a JSON object with at least one of "
                f"{', '.join(EXPECT_KEYS)}"]

    problems: list[str] = []
    unknown = sorted(set(expect) - set(EXPECT_KEYS))
    if unknown:
        problems.append(f"{label} 'expect' has unknown key(s): {', '.join(unknown)}")
    if not any(key in expect for key in EXPECT_KEYS):
        problems.append(f"{label} 'expect' must carry at least one of {', '.join(EXPECT_KEYS)}: "
                        "a turn that asserts nothing cannot fail")

    if "tool_call" in expect:
        value = expect["tool_call"]
        if not isinstance(value, str) or not value.strip():
            problems.append(f"{label} 'expect.tool_call' must be a non-empty tool name string")
    if "no_new_action" in expect and not isinstance(expect["no_new_action"], bool):
        problems.append(f"{label} 'expect.no_new_action' must be a boolean")
    for key in ("speech_contains", "speech_not_contains"):
        if key in expect:
            problems.extend(_validate_speech_expectation(label, key, expect[key]))
    return problems


def _validate_speech_expectation(label: str, key: str, value) -> list[str]:
    values = value if isinstance(value, list) else [value]
    if isinstance(value, list) and not value:
        return [f"{label} 'expect.{key}' must not be an empty list"]
    for entry in values:
        if not isinstance(entry, str) or not entry.strip():
            return [f"{label} 'expect.{key}' entries must be non-empty strings"]
    return []


def load_script(path: Path | str) -> dict:
    """Read one conversation script from disk (no validation, no execution)."""
    path = Path(path)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ConversationScriptError(f"Could not read conversation script {path}: {error}") from error
    if not isinstance(payload, dict):
        raise ConversationScriptError(f"Conversation script {path} is not a JSON object.")
    return payload


def example_script_path() -> Path:
    return (paths.repository_root() / "scripts" / "acceptance"
            / CASSETTE_DIRECTORY_NAME / CONVERSATION_CASSETTE_FILE_NAME)


def require_valid_script(script) -> dict:
    """Fail closed on an unusable script instead of running a broken conversation."""
    problems = validate_script(script)
    if problems:
        raise ConversationScriptError(
            "Unusable conversation script: " + "; ".join(problems))
    return script


# ------------------------------------------------------ PCM planning per turn


def plan_utterances(
    script,
    cache_dir: Path | str,
    *,
    synthesizer: Callable[[str, Path], UtteranceAudio] | None = None,
) -> list[PlannedUtterance]:
    """Synthesize one PCM per turn, in script order.

    `synthesizer` defaults to `synthetic_speech.synthesize_utterance` (real
    system TTS). Self-tests and dry runs pass
    `synthesize_placeholder_for_self_tests` instead: that path needs no `say`,
    is deterministic, and labels its output `is_real_speech: false` so it can
    never be mistaken for evidence. Synthesis is the only side effect - no app,
    provider or desktop is touched - and identical text reuses the cache the
    speech module already owns.

    Each element exposes `.text` / `.pcm_path` (the `(text, pcm_path)` pair this
    contract names, also available via `as_tuple()`) plus the timeline fields
    the new probe would need. The runner owns the resulting PCM queue: it hands
    the paths to whatever probe mode `map_conversation_to_probe` selected.
    """
    require_valid_script(script)
    synthesizer = synthesizer or synthesize_utterance
    cache_dir = Path(cache_dir)

    plans: list[PlannedUtterance] = []
    for index, turn in enumerate(script["turns"]):
        text = turn["text"]
        audio = synthesizer(text, cache_dir)
        plans.append(PlannedUtterance(
            index=index,
            text=text,
            wait_ms=int(turn.get("wait_ms", DEFAULT_WAIT_MS)),
            barge_in=bool(turn.get("barge_in", DEFAULT_BARGE_IN)),
            pcm_path=audio.pcm_path,
            audio=audio,
        ))
    return plans


# ------------------------------------------------------- probe-mode degradation


def map_conversation_to_probe(script, utterances: list[PlannedUtterance] | None = None) -> ConversationProbeMapping:
    """Degrade a conversation script onto the probes the current build has.

    The mapping is a decision, never a guess: a script that cannot be driven
    today comes back `requires_new_probe=True` with the proposed argv template
    and the reason, so the runner (and the evidence) can say "rebuild-gated"
    instead of silently dropping turns.
    """
    require_valid_script(script)
    turns = script["turns"]
    pcm_paths = [plan.pcm_path for plan in utterances] if utterances else []

    if barge_in_turn_indices(script):
        indices = ", ".join(str(index) for index in barge_in_turn_indices(script))
        return ConversationProbeMapping(
            mode="unmapped",
            utterance_pcm_paths=pcm_paths,
            report_file_name=PROPOSED_CONVERSATION_REPORT_FILE_NAME,
            requires_new_probe=True,
            proposed_argv_template=list(PROPOSED_CONVERSATION_ARGV_TEMPLATE),
            reason=(f"barge-in on turn(s) {indices}: speech must be inserted while the "
                    "previous response is still playing. No existing probe can interleave "
                    f"audio into playback, so {PROPOSED_CONVERSATION_PROBE_FLAG} must be "
                    "added to the DEBUG build (Xcode rebuild, app-side) before this script "
                    "can be driven."),
        )

    if len(turns) == 1:
        return ConversationProbeMapping(
            mode="voice_task",
            utterance_pcm_paths=pcm_paths[:1],
            report_file_name="report.json",
            requires_new_probe=False,
            proposed_argv_template=None,
            reason=("A single-turn conversation is exactly what --voice-task-probe already "
                    "takes (one PCM); degrading it loses nothing."),
        )

    if len(turns) == 2:
        return ConversationProbeMapping(
            mode="voice_continuity",
            utterance_pcm_paths=pcm_paths[:2],
            report_file_name="continuity-report.json",
            requires_new_probe=False,
            proposed_argv_template=None,
            reason=("Two turns map onto --voice-continuity-probe <progress.pcm> <cancel.pcm>: "
                    "turn 0 is the first utterance and turn 1 the second, in the probe's "
                    "documented argument order (never swapped). The timeline offsets and the "
                    "per-turn expectations are recorded, not enforced by this probe."),
        )

    return ConversationProbeMapping(
        mode="unmapped",
        utterance_pcm_paths=pcm_paths,
        report_file_name=PROPOSED_CONVERSATION_REPORT_FILE_NAME,
        requires_new_probe=True,
        proposed_argv_template=list(PROPOSED_CONVERSATION_ARGV_TEMPLATE),
        reason=(f"{len(turns)} turns exceed what the existing probes accept (one PCM for "
                f"voice_task/voice_route, two for voice_continuity). Driving the whole "
                f"timeline needs {PROPOSED_CONVERSATION_PROBE_FLAG}, which does not exist "
                "in any build yet."),
    )


def to_probe_request(
    mapping: ConversationProbeMapping,
    app_binary: Path | str,
    working_out_dir: Path | str,
    expected_bundle_identifier: str | None = None,
    report_file_name: str | None = None,
) -> ProbeRequest:
    """Build the real `ProbeRequest` for a degradable mapping, or refuse.

    Refusing is the point: raising here makes "we only ran the first two turns"
    impossible to express as a silently successful run.
    """
    if mapping.requires_new_probe or mapping.mode not in ("voice_task", "voice_continuity"):
        raise ConversationScriptError(
            "This conversation script is rebuild-gated: " + mapping.reason)
    return ProbeRequest(
        mode=mapping.mode,
        app_binary=Path(app_binary),
        working_out_dir=Path(working_out_dir),
        expected_bundle_identifier=(expected_bundle_identifier
                                    or paths.CONTROLLED_BROWSER_BUNDLE_IDENTIFIER),
        utterance_pcm_paths=list(mapping.utterance_pcm_paths),
        report_file_name=report_file_name or mapping.report_file_name,
    )


def build_conversation_manifest(script, utterances: list[PlannedUtterance]) -> dict:
    """The input the proposed multi-turn probe would consume.

    One manifest per script: the timeline (wait_ms, barge_in), the PCM path the
    runner synthesized for each turn, and each turn's expectation, so the probe
    and the judges can be checked against the same script. Metadata only - no
    audio samples are embedded, and the manifest is stamped as not-evidence.
    """
    require_valid_script(script)
    plans = list(utterances)
    if len(plans) != turn_count(script):
        raise ConversationScriptError(
            f"The script has {turn_count(script)} turns but {len(plans)} planned utterances.")

    manifest_turns = []
    for plan in plans:
        manifest_turns.append({
            "index": plan.index,
            "text": plan.text,
            "pcm_path": str(plan.pcm_path),
            "wait_ms": plan.wait_ms,
            "barge_in": plan.barge_in,
            "is_real_speech": plan.audio.is_real_speech,
            "synthesis_method": plan.audio.synthesis_method,
            "expect": dict(script["turns"][plan.index]["expect"]),
        })
    return {
        "conversation_format": CONVERSATION_SCRIPT_FORMAT,
        "acceptance": False,
        "purpose": "input for the proposed in-app multi-turn conversation probe "
                   "(rebuild-gated); contract material, never acceptance evidence",
        "name": script["name"],
        "app": script["app"],
        "fixture_url": script["fixture_url"],
        "trace_prefix": script["trace_prefix"],
        "synthetic_audio": True,
        "microphone": "not_opened",
        "turns": manifest_turns,
    }


def describe_script(script) -> dict:
    """A compact, evidence-safe description of a conversation script."""
    require_valid_script(script)
    return {
        "name": script["name"],
        "app": script["app"],
        "fixture_url": script["fixture_url"],
        "trace_prefix": script["trace_prefix"],
        "acceptance": script.get("acceptance", False),
        "turn_count": turn_count(script),
        "total_wait_ms": total_wait_ms(script),
        "barge_in_turns": barge_in_turn_indices(script),
        "expectation_keys": sorted({key for turn in script["turns"] for key in turn["expect"]}),
        "probe_mapping": map_conversation_to_probe(script).to_dict(),
    }

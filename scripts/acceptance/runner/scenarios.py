"""Scenario definitions for the acceptance run.

Each scenario lives in tools/voice-acceptance/scenarios/*.json so the wording,
probe plumbing and expectations are auditable next to the fixture they drive.
`load_scenarios` returns them in a stable run order.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from . import paths

SCENARIO_RUN_ORDER = (
    "single_step_right_setting",
    "two_step_display_settings_scale",
    "continuity_progress_cancel",
    "unknown_delivery_fault_recovery",
)


class ScenarioError(RuntimeError):
    pass


@dataclass
class Scenario:
    name: str
    title: str
    description: str
    user_words: str
    utterances: list[str]
    probe: dict
    repeat: int
    expectations: dict
    reproduction: dict = field(default_factory=dict)
    source_path: Path | None = None

    @property
    def probe_mode(self) -> str:
        return self.probe.get("mode", "voice_task")

    @property
    def report_file_name(self) -> str:
        return self.probe.get("report_file_name", "report.json")

    @property
    def expected_bundle_identifier(self) -> str:
        return self.probe.get("expected_bundle_identifier",
                              paths.CONTROLLED_BROWSER_BUNDLE_IDENTIFIER)

    @property
    def timeout_seconds(self) -> float:
        return float(self.probe.get("timeout_seconds", 300))

    @property
    def capability_flag(self) -> str | None:
        return self.probe.get("capability_flag")

    @property
    def unknown_argv_template(self) -> list[str] | None:
        return self.probe.get("argv_template")


def load_scenario(path: Path) -> Scenario:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ScenarioError(f"Could not read scenario {path}: {error}") from error
    for required_key in ("name", "title", "user_words", "utterances", "probe"):
        if required_key not in payload:
            raise ScenarioError(f"Scenario {path} is missing {required_key!r}.")
    if not isinstance(payload["utterances"], list) or not payload["utterances"]:
        raise ScenarioError(f"Scenario {path} must list at least one utterance.")
    for utterance in payload["utterances"]:
        if not isinstance(utterance, str) or not utterance.strip():
            raise ScenarioError(f"Scenario {path} has an empty utterance.")
    repeat = payload.get("repeat", 1)
    if not isinstance(repeat, int) or repeat < 1:
        raise ScenarioError(f"Scenario {path} has an invalid repeat count.")
    return Scenario(
        name=payload["name"],
        title=payload["title"],
        description=payload.get("description", ""),
        user_words=payload["user_words"],
        utterances=list(payload["utterances"]),
        probe=payload["probe"],
        repeat=repeat,
        expectations=payload.get("expectations", {}),
        reproduction=payload.get("reproduction", {}),
        source_path=path,
    )


def load_scenarios(
    selected_names: list[str] | None = None,
    repeat_overrides: dict[str, int] | None = None,
) -> list[Scenario]:
    directory = paths.scenario_directory()
    scenarios: dict[str, Scenario] = {}
    for path in sorted(directory.glob("*.json")):
        scenario = load_scenario(path)
        scenarios[scenario.name] = scenario
    if not scenarios:
        raise ScenarioError(
            f"No scenario definitions found in {directory}; the runner has nothing to run."
        )
    if selected_names:
        missing = [name for name in selected_names if name not in scenarios]
        if missing:
            raise ScenarioError(
                f"Unknown scenario(s): {', '.join(missing)}. "
                f"Available: {', '.join(sorted(scenarios))}"
            )
        ordered = [scenarios[name] for name in selected_names]
    else:
        known_order = [name for name in SCENARIO_RUN_ORDER if name in scenarios]
        extra = sorted(set(scenarios) - set(known_order))
        ordered = [scenarios[name] for name in known_order + extra]
    if repeat_overrides:
        for scenario in ordered:
            if scenario.name in repeat_overrides:
                scenario.repeat = repeat_overrides[scenario.name]
    return ordered

"""Runner-level dry-run mode: same pipeline, mock executor, never proof.

`--dry-run` executes the entire orchestration — app identity inspection, real
fixture lifecycle, real /state reset mechanics, real utterance synthesis, the
same judges, evidence schema validation, cleanup and rerun-hygiene checks —
with the app probe replaced by a runner-level mock that replays a recorded
evidence chain. The result is labeled `"mode": "dry_run"`, `"proof": false`
and every scenario attempt carries `"mock": true`. It proves the runner, never
the product, and is never shipped as acceptance evidence.
"""
from __future__ import annotations

import copy
import json
from dataclasses import dataclass
from pathlib import Path

from . import paths
from .scenarios import Scenario

DRY_RUN_CHAIN_DIRECTORY = Path(__file__).resolve().parent.parent / "dry_run_chains"

GOOD_CHAIN_SUFFIX = "good"
BAD_CHAIN_SUFFIX = "bad"


class DryRunChainError(RuntimeError):
    pass


@dataclass
class DryRunChain:
    scenario_name: str
    quality: str
    description: str
    argv: list[str]
    report: dict
    state_before: dict
    state_after: dict
    source_path: Path

    def to_dict(self) -> dict:
        return {
            "scenario_name": self.scenario_name,
            "quality": self.quality,
            "description": self.description,
            "source_path": str(self.source_path),
            "argv": self.argv,
            "report": self.report,
            "state_before": self.state_before,
            "state_after": self.state_after,
            "mock": True,
            "synthetic_state": True,
        }


def _chain_path(scenario: Scenario, quality: str) -> Path:
    return DRY_RUN_CHAIN_DIRECTORY / f"{scenario.name}.{quality}.json"


def load_dry_run_chain(scenario: Scenario, quality: str = GOOD_CHAIN_SUFFIX) -> DryRunChain:
    path = _chain_path(scenario, quality)
    if not path.is_file():
        raise DryRunChainError(f"Missing dry-run chain {path} for scenario {scenario.name!r}.")
    payload = json.loads(path.read_text(encoding="utf-8"))
    return DryRunChain(
        scenario_name=scenario.name,
        quality=payload.get("quality", quality),
        description=payload.get("description", ""),
        argv=payload.get("argv", []),
        report=payload.get("report", {}),
        state_before=payload.get("state_before", {}),
        state_after=payload.get("state_after", {}),
        source_path=path,
    )


def dry_run_chain_exists(scenario: Scenario, quality: str = GOOD_CHAIN_SUFFIX) -> bool:
    return _chain_path(scenario, quality).is_file()


def build_dry_run_probe_record(chain: DryRunChain, attempt_directory: Path) -> dict:
    """A probe-run record shaped exactly like a real run, clearly marked mock."""
    attempt_directory.mkdir(parents=True, exist_ok=True)
    report_path = attempt_directory / "mock-report.json"
    report_path.write_text(
        json.dumps(chain.report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return {
        "argv": list(chain.argv),
        "exit_record": {"pid": None, "self_exited": True, "returncode": 0,
                        "timed_out": False, "mock": True},
        "report_path": str(report_path),
        "report_error": None,
        "output_files": ["mock-report.json"],
        "duration_seconds": 0.0,
        "log_path": None,
        "mock": True,
        "mock_description": chain.description,
    }


def clone_chain_state(chain: DryRunChain) -> tuple[dict, dict]:
    return copy.deepcopy(chain.state_before), copy.deepcopy(chain.state_after)


def describe_dry_run_boundaries() -> dict:
    return {
        "mock_executor": "runner-level only; no product code is exercised",
        "real_fixture": "the real fixture process, reset semantics and /state protocol are exercised",
        "real_speech_synthesis": "real system TTS when available; samples never enter evidence",
        "real_app": False,
        "real_provider": False,
        "real_desktop_actions": False,
        "never_proof": "dry-run artifacts prove the runner pipeline, never product acceptance",
    }
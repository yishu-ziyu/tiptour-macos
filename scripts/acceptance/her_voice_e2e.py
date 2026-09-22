#!/usr/bin/env python3
"""One-command Her E2E acceptance runner.

    python3 scripts/acceptance/her_voice_e2e.py \
        --app "/.../Debug/Her.app" \
        --out out/acceptance/03-her-e2e-runner

Modes:
  (default)     full acceptance run: signed DEBUG Her.app → real StepFun →
                real executor → local controlled page → independent /state →
                Her receipt and speech → post-failure dedup/recovery evidence.
  --dry-run     same pipeline with a runner-level mock executor. Clearly labeled,
                never shipped as proof.
  --self-test   runner self-tests only (fixture behavior, argument plumbing,
                evidence schema, judges, hygiene). No app involvement.

The runner never builds, installs, replaces or kills the user's Her, never opens
the microphone, never exports keys and only ever touches the local fixture page.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from runner import orchestration, paths, self_test  # noqa: E402
from runner.orchestration import RunOptions  # noqa: E402


def parse_repeat_overrides(values: list[str]) -> dict[str, int]:
    overrides: dict[str, int] = {}
    for value in values:
        name, separator, count = value.partition("=")
        if not separator or not count.isdigit() or int(count) < 1:
            raise SystemExit(f"--repeat-scenario expects NAME=N, got {value!r}")
        overrides[name] = int(count)
    return overrides


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--app", default=None,
                        help="Path to the signed DEBUG Her.app. Defaults to this machine's "
                             "Xcode DerivedData Debug product; the runner never builds.")
    parser.add_argument("--out", type=Path, default=None,
                        help="Evidence package directory. Defaults to "
                             "<repo>/out/acceptance/03-her-e2e-runner.")
    parser.add_argument("--scenarios", default=None,
                        help="Comma-separated scenario names to run (default: all).")
    parser.add_argument("--repeat-scenario", action="append", default=[],
                        metavar="NAME=N",
                        help="Run a scenario N times (e.g. --repeat-scenario "
                             "two_step_display_settings_scale=3).")
    parser.add_argument("--dry-run", action="store_true",
                        help="Run the full pipeline with a runner-level mock executor. "
                             "Results are labeled dry_run and never count as proof.")
    parser.add_argument("--dry-run-failure-injection", action="store_true",
                        help="With --dry-run, replay the bad evidence chains so the judges' "
                             "failure detection is exercised end to end.")
    parser.add_argument("--self-test", action="store_true",
                        help="Run the runner self-tests (no app involvement) and exit.")
    parser.add_argument("--require-evidence-language", action="store_true",
                        help="Gate the continuity progress speech on work order 02's "
                             "evidence-aware wording instead of recording it as advisory.")
    parser.add_argument("--unknown-probe-argv", default=None, metavar="JSON",
                        help="JSON argv template for the work order 04 fault probe. "
                             "Placeholders: {app_binary} {report} {out_dir} {bundle_id} "
                             "{fixture_url} {pcm}.")
    parser.add_argument("--probe-timeout", type=float, default=300.0,
                        help="Seconds to wait for a probe to exit by itself (default 300).")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test.run_all()

    try:
        repeat_overrides = parse_repeat_overrides(args.repeat_scenario)
    except SystemExit as error:
        parser.error(str(error))
    unknown_template = None
    if args.unknown_probe_argv:
        try:
            unknown_template = json.loads(args.unknown_probe_argv)
        except json.JSONDecodeError as error:
            parser.error(f"--unknown-probe-argv is not valid JSON: {error}")
        if not isinstance(unknown_template, list) or not all(
            isinstance(token, str) for token in unknown_template
        ):
            parser.error("--unknown-probe-argv must be a JSON array of strings.")

    out_dir = args.out or (paths.repository_root() / "out/acceptance"
                           / paths.DEFAULT_EVIDENCE_DIRECTORY_NAME)
    selected = [name.strip() for name in args.scenarios.split(",")] if args.scenarios else None
    options = RunOptions(
        app_path_argument=args.app,
        out_dir=out_dir,
        mode="dry_run" if args.dry_run else "full",
        selected_scenarios=selected,
        repeat_overrides=repeat_overrides,
        dry_run_failure_injection=args.dry_run_failure_injection,
        require_evidence_language=args.require_evidence_language,
        unknown_probe_argv_template=unknown_template,
        probe_timeout_seconds=args.probe_timeout,
    )
    return orchestration.run_acceptance(options)


if __name__ == "__main__":
    raise SystemExit(main())
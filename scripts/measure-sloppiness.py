#!/usr/bin/env python3
"""Measure verbosity and erosion of the app's Swift sources.

Definitions follow https://earendil.com/posts/measuring-code-sloppiness/
(taken from SlopCodeBench):

  verbosity = |lines flagged by ast-grep rules ∪ lines in cloned blocks| / SLOC
  mass(f)   = CC(f) * sqrt(SLOC(f))
  erosion   = sum of mass over functions with CC > 10 / sum of mass over all functions

Reference values from the article: established repositories verbosity 0.15 ± 0.06,
erosion 0.31 ± 0.17; agent-written code 0.33 ± 0.10 and 0.68 ± 0.20.

Needs `ast-grep`, `uvx` (runs lizard) and `npx` (runs jscpd) on PATH.

  python3 scripts/measure-sloppiness.py              # summary
  python3 scripts/measure-sloppiness.py --details    # plus the worst functions and clones
  python3 scripts/measure-sloppiness.py --json out.json
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import math
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIRECTORY = "TipTour"
AST_GREP_RULES = REPOSITORY_ROOT / "scripts" / "sloppiness-rules.yml"
COMPLEXITY_THRESHOLD = 10
CLONE_MINIMUM_TOKENS = 50
CLONE_MINIMUM_LINES = 5
# These rules match a whole if/guard block, but only its first line is verbose.
RULES_FLAGGING_FIRST_LINE_ONLY = {"redundant-optional-binding-name"}


def swift_source_files() -> list[Path]:
    return sorted((REPOSITORY_ROOT / SOURCE_DIRECTORY).rglob("*.swift"))


def source_line_numbers(path: Path) -> set[int]:
    """Lines that are neither blank nor comment-only (block comments included)."""
    counted_line_numbers = set()
    inside_block_comment = False
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped_line = line.strip()
        if inside_block_comment:
            if "*/" in stripped_line:
                inside_block_comment = False
                stripped_line = stripped_line.split("*/", 1)[1].strip()
            else:
                continue
        if stripped_line.startswith("/*"):
            if "*/" not in stripped_line:
                inside_block_comment = True
            continue
        if not stripped_line or stripped_line.startswith("//"):
            continue
        counted_line_numbers.add(line_number)
    return counted_line_numbers


def ast_grep_flagged_lines() -> tuple[dict[str, set[int]], dict[str, int]]:
    completed = subprocess.run(
        ["ast-grep", "scan", "--rule", str(AST_GREP_RULES), "--json=stream", SOURCE_DIRECTORY],
        cwd=REPOSITORY_ROOT, capture_output=True, text=True,
    )
    if completed.returncode not in (0, 1):
        sys.exit(f"ast-grep failed: {completed.stderr}")
    flagged_lines_by_file: dict[str, set[int]] = defaultdict(set)
    match_count_by_rule: dict[str, int] = defaultdict(int)
    for output_line in completed.stdout.splitlines():
        match = json.loads(output_line)
        first_line = match["range"]["start"]["line"] + 1
        last_line = first_line if match["ruleId"] in RULES_FLAGGING_FIRST_LINE_ONLY else match["range"]["end"]["line"] + 1
        flagged_lines_by_file[match["file"]].update(range(first_line, last_line + 1))
        match_count_by_rule[match["ruleId"]] += 1
    return flagged_lines_by_file, dict(match_count_by_rule)


def cloned_lines() -> tuple[dict[str, set[int]], list[dict]]:
    with tempfile.TemporaryDirectory() as report_directory:
        subprocess.run(
            ["npx", "-y", "jscpd@5.3.2", "--silent", "--format", "swift",
             "--min-tokens", str(CLONE_MINIMUM_TOKENS), "--min-lines", str(CLONE_MINIMUM_LINES),
             "--reporters", "json", "--output", report_directory, SOURCE_DIRECTORY],
            cwd=REPOSITORY_ROOT, capture_output=True, text=True, check=True,
        )
        report = json.loads((Path(report_directory) / "jscpd-report.json").read_text())
    cloned_lines_by_file: dict[str, set[int]] = defaultdict(set)
    for duplicate in report["duplicates"]:
        for side in (duplicate["firstFile"], duplicate["secondFile"]):
            # jscpd reports paths relative to the scanned directory.
            side["name"] = f"{SOURCE_DIRECTORY}/{side['name']}"
            cloned_lines_by_file[side["name"]].update(range(side["start"], side["end"] + 1))
    return cloned_lines_by_file, report["duplicates"]


def function_metrics() -> list[dict]:
    completed = subprocess.run(
        ["uvx", "lizard@1.24.0", "--csv", "-l", "swift", SOURCE_DIRECTORY],
        cwd=REPOSITORY_ROOT, capture_output=True, text=True, check=True,
    )
    functions = []
    for row in csv.reader(io.StringIO(completed.stdout)):
        # lizard CSV: NLOC, CCN, tokens, params, length, location, file, name, long name, start, end
        source_lines, cyclomatic_complexity = int(row[0]), int(row[1])
        functions.append({
            "file": row[6], "name": row[7], "start": int(row[9]),
            "sloc": source_lines, "cc": cyclomatic_complexity,
            "mass": cyclomatic_complexity * math.sqrt(source_lines),
        })
    return functions


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--details", action="store_true", help="list the heaviest functions and largest clones")
    parser.add_argument("--json", type=Path, help="write the full result to this file")
    arguments = parser.parse_args()

    source_lines_by_file = {
        str(path.relative_to(REPOSITORY_ROOT)): source_line_numbers(path) for path in swift_source_files()
    }
    total_source_lines = sum(len(lines) for lines in source_lines_by_file.values())

    flagged_lines_by_file, match_count_by_rule = ast_grep_flagged_lines()
    cloned_lines_by_file, duplicates = cloned_lines()
    verbose_line_count = 0
    for file_name, counted_lines in source_lines_by_file.items():
        verbose_lines = flagged_lines_by_file.get(file_name, set()) | cloned_lines_by_file.get(file_name, set())
        verbose_line_count += len(verbose_lines & counted_lines)
    verbosity = verbose_line_count / total_source_lines

    functions = function_metrics()
    total_mass = sum(function["mass"] for function in functions)
    complex_functions = [function for function in functions if function["cc"] > COMPLEXITY_THRESHOLD]
    erosion = sum(function["mass"] for function in complex_functions) / total_mass

    print(f"files {len(source_lines_by_file)}  SLOC {total_source_lines}  functions {len(functions)}")
    print(f"verbosity {verbosity:.3f}  (flagged ∪ cloned lines {verbose_line_count}; "
          f"clone pairs {len(duplicates)}; rule matches {match_count_by_rule or 'none'})")
    print(f"erosion   {erosion:.3f}  ({len(complex_functions)} functions with CC > {COMPLEXITY_THRESHOLD})")
    print("reference: repositories 0.15 / 0.31, agent code 0.33 / 0.68")

    if arguments.details:
        print("\nheaviest functions (mass, CC, SLOC):")
        for function in sorted(functions, key=lambda function: -function["mass"])[:25]:
            print(f"  {function['mass']:7.0f}  {function['cc']:4d}  {function['sloc']:4d}  "
                  f"{function['file']}:{function['start']}  {function['name']}")
        print("\nlargest clones (lines):")
        for duplicate in sorted(duplicates, key=lambda duplicate: -duplicate["lines"])[:25]:
            first, second = duplicate["firstFile"], duplicate["secondFile"]
            print(f"  {duplicate['lines']:4d}  {first['name']}:{first['start']}-{first['end']}  "
                  f"{second['name']}:{second['start']}-{second['end']}")

    if arguments.json:
        arguments.json.write_text(json.dumps({
            "sloc": total_source_lines, "verbosity": verbosity, "erosion": erosion,
            "rule_matches": match_count_by_rule, "clone_pairs": len(duplicates),
            "functions": functions,
        }, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())

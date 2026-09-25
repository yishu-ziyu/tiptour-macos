#!/usr/bin/env python3
"""Check that the repository's documentation still matches the repository.

Failures (exit code 1):
  - a relative Markdown link in a current document points at a missing file
  - a document under docs/ cannot be reached from README.md by following links
  - a repository path written in backticks in a current document does not exist
  - a path in docs/architecture/key-files.md does not exist, or its "~N lines"
    differs from the real file by more than 50 lines

Warnings (printed, never fail):
  - broken links or paths inside frozen records and dated work orders, which are
    never rewritten (see docs/development/README.md)
  - current documents longer than 300 lines (split them by section)

--changed [BASE] also lists code areas changed against BASE (default HEAD,
including untracked files) whose mapped document did not change; --staged does
the same for the files staged for the next commit (used by the pre-commit hook). That list is a
prompt to look, not proof of an omission: bug fixes that change no documented
fact need no document change. The mapping mirrors the table in AGENTS.md.

  python3 scripts/check-docs.py
  python3 scripts/check-docs.py --changed
  python3 scripts/check-docs.py --changed main
  python3 scripts/check-docs.py --staged
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import deque
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
ENTRY_DOCUMENT = "README.md"
DOCUMENT_INDEX = "docs/README.md"
KEY_FILES_DOCUMENT = "docs/architecture/key-files.md"
MAXIMUM_LINE_COUNT_DRIFT = 50
RECOMMENDED_MAXIMUM_DOCUMENT_LINES = 300
# Top-level directories whose backticked paths are checked for existence.
CHECKED_PATH_PREFIXES = ("TipTour/", "TipTourTests/", "TipTourUITests/", "docs/", "scripts/", "tools/")
EXCLUDED_DOCUMENT_PREFIXES = ("out/", ".serena/", ".statamcp/", "TipTour/Skills/")

# (code path pattern, documents that describe it). Mirrors AGENTS.md.
CODE_TO_DOCUMENT_MAPPING = [
    (r"^TipTour/(Voice/(StepFun|Gemini)|Jev/|Core/TipTourMode\.swift|Utilities/TipTourDefaults\.swift|UI/)",
     ["docs/architecture/provider-modes.md", "README.md"]),
    (r"^TipTour/(Core|Workflow|Actions|Perception|Harnesses)/|^TipTour/Voice/Desktop(TaskExecutor|ActionVerifier|DecisionPacket|ApplicationResolver|ObservedWindowIdentity)",
     ["docs/architecture/runtime.md"]),
    (r"^TipTour/Voice/DesktopTaskContract\.swift$", ["docs/architecture/step-completion.md"]),
    (r"^TipTour/Voice/(DesktopTask(Coordinator|Admission|Journal)|VoiceTaskContinuityProbe)\.swift$",
     ["docs/architecture/task-continuity.md"]),
    (r"^scripts/[^/]+\.(sh|py)$", ["docs/guides/build-and-verification.md", "docs/tools/scripts.md"]),
    (r"^scripts/acceptance/", ["docs/guides/acceptance.md", "docs/tools/acceptance-runner.md"]),
    (r"^tools/voice-acceptance/", ["docs/tools/voice-acceptance.md"]),
    (r"^tools/cua-host/", ["docs/tools/cua-host.md"]),
    (r"^tools/stepprobe/", ["docs/tools/stepprobe.md"]),
]

MARKDOWN_LINK_PATTERN = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
BACKTICK_PATTERN = re.compile(r"`([^`\n]+)`")
KEY_FILE_ROW_PATTERN = re.compile(r"^\|\s*`([^`]+)`\s*\|(.*)\|\s*$")
APPROXIMATE_LINE_COUNT_PATTERN = re.compile(r"~\s*(\d+)\s+lines")
DECLARED_RELATIVE_BASE_PATTERN = re.compile(r"Paths in backticks are relative to `([^`]+)`")


def run_git(arguments: list[str]) -> list[str]:
    output = subprocess.run(["git", *arguments], cwd=REPOSITORY_ROOT, capture_output=True, text=True, check=True).stdout
    return [line for line in output.splitlines() if line]


def list_markdown_documents() -> list[str]:
    tracked_and_untracked = run_git(["ls-files", "--cached", "--others", "--exclude-standard", "*.md"])
    return sorted(
        path for path in set(tracked_and_untracked)
        if (REPOSITORY_ROOT / path).is_file() and not path.startswith(EXCLUDED_DOCUMENT_PREFIXES)
    )


def frozen_or_dated_record_paths() -> set[str]:
    """Documents that are never rewritten, read from the Kind column of docs/README.md."""
    records: set[str] = set()
    index_text = (REPOSITORY_ROOT / DOCUMENT_INDEX).read_text(encoding="utf-8")
    for line in index_text.splitlines():
        link_match = MARKDOWN_LINK_PATTERN.search(line)
        if link_match and "Frozen record" in line:
            records.add(str(Path("docs") / link_match.group(1)))
    for path in list_markdown_documents():
        if path.startswith("docs/tasks/"):
            records.add(path)
    return records


def linked_targets(document_path: str) -> list[tuple[str, str]]:
    """(raw link, resolved repository-relative path) for every local link."""
    text = (REPOSITORY_ROOT / document_path).read_text(encoding="utf-8")
    targets = []
    for link_match in MARKDOWN_LINK_PATTERN.finditer(text):
        raw_link = link_match.group(1)
        if raw_link.startswith(("http://", "https://", "mailto:", "#")):
            continue
        target_without_anchor = raw_link.split("#", 1)[0]
        resolved = (REPOSITORY_ROOT / document_path).parent / target_without_anchor
        targets.append((raw_link, str(resolved.resolve().relative_to(REPOSITORY_ROOT)) if resolved.exists() else str(resolved)))
    return targets


def check_links(documents: list[str], records: set[str], failures: list[str], warnings: list[str]) -> None:
    for document_path in documents:
        for raw_link, resolved in linked_targets(document_path):
            if not (REPOSITORY_ROOT / resolved).exists():
                message = f"{document_path}: broken link ({raw_link})"
                (warnings if document_path in records else failures).append(message)


def check_reachability(documents: list[str], failures: list[str]) -> None:
    reached = {ENTRY_DOCUMENT}
    queue = deque([ENTRY_DOCUMENT])
    while queue:
        current = queue.popleft()
        for _, resolved in linked_targets(current):
            if resolved.endswith(".md") and resolved not in reached and (REPOSITORY_ROOT / resolved).is_file():
                reached.add(resolved)
                queue.append(resolved)
    for document_path in documents:
        if document_path.startswith("docs/") and document_path not in reached:
            failures.append(f"{document_path}: not reachable from {ENTRY_DOCUMENT}; link it from {DOCUMENT_INDEX}")


def path_is_git_ignored(repository_relative_path: str) -> bool:
    """Ignored paths are build products (e.g. `.build/`), which need not exist in a checkout."""
    return subprocess.run(["git", "check-ignore", "-q", "--no-index", repository_relative_path],
                          cwd=REPOSITORY_ROOT).returncode == 0


def check_backticked_paths(documents: list[str], records: set[str], failures: list[str], warnings: list[str]) -> None:
    for document_path in documents:
        text = (REPOSITORY_ROOT / document_path).read_text(encoding="utf-8")
        # Documents moved out of a tool directory keep paths relative to it and say so.
        declared_base = DECLARED_RELATIVE_BASE_PATTERN.search(text)
        base_directories = [Path(".")] + ([Path(declared_base.group(1))] if declared_base else [])
        for token in sorted(set(BACKTICK_PATTERN.findall(text))):
            candidate = token.split(":", 1)[0].rstrip("/").strip()
            if not candidate.startswith(CHECKED_PATH_PREFIXES) or " " in candidate:
                continue
            if any(character in candidate for character in "*<>{}$|"):
                continue
            if any((REPOSITORY_ROOT / base / candidate).exists() for base in base_directories):
                continue
            if path_is_git_ignored(candidate):
                continue
            message = f"{document_path}: path `{candidate}` does not exist"
            (warnings if document_path in records else failures).append(message)


def check_key_files_table(failures: list[str]) -> None:
    for line in (REPOSITORY_ROOT / KEY_FILES_DOCUMENT).read_text(encoding="utf-8").splitlines():
        row_match = KEY_FILE_ROW_PATTERN.match(line)
        if not row_match:
            continue
        file_path, purpose = row_match.group(1), row_match.group(2)
        absolute_path = REPOSITORY_ROOT / file_path
        if not absolute_path.exists():
            failures.append(f"{KEY_FILES_DOCUMENT}: `{file_path}` does not exist")
            continue
        count_match = APPROXIMATE_LINE_COUNT_PATTERN.search(purpose)
        if count_match and absolute_path.is_file():
            documented_line_count = int(count_match.group(1))
            actual_line_count = len(absolute_path.read_text(encoding="utf-8", errors="replace").splitlines())
            if abs(actual_line_count - documented_line_count) > MAXIMUM_LINE_COUNT_DRIFT:
                failures.append(
                    f"{KEY_FILES_DOCUMENT}: `{file_path}` documented ~{documented_line_count} lines, actual {actual_line_count}")


def check_document_sizes(documents: list[str], records: set[str], warnings: list[str]) -> None:
    for document_path in documents:
        if document_path in records:
            continue
        line_count = len((REPOSITORY_ROOT / document_path).read_text(encoding="utf-8").splitlines())
        if line_count > RECOMMENDED_MAXIMUM_DOCUMENT_LINES:
            warnings.append(f"{document_path}: {line_count} lines; split it by section and keep an overview")


def report_code_changes_without_document_changes(base_reference: str | None) -> list[str]:
    """base_reference None means the files staged for the next commit."""
    if base_reference is None:
        changed_paths = set(run_git(["diff", "--cached", "--name-only"]))
    else:
        changed_paths = set(run_git(["diff", "--name-only", base_reference]))
        changed_paths |= set(run_git(["ls-files", "--others", "--exclude-standard"]))
    prompts = []
    for code_pattern, mapped_documents in CODE_TO_DOCUMENT_MAPPING:
        changed_code = sorted(path for path in changed_paths if re.search(code_pattern, path))
        if changed_code and not any(document in changed_paths for document in mapped_documents):
            shown = ", ".join(changed_code[:4]) + (f" (+{len(changed_code) - 4} more)" if len(changed_code) > 4 else "")
            prompts.append(f"{shown} changed; none of {', '.join(mapped_documents)} changed")
    return prompts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--changed", nargs="?", const="HEAD", metavar="BASE",
                        help="also list code areas changed against BASE whose documents did not change")
    parser.add_argument("--staged", action="store_true",
                        help="also list staged code areas whose documents are not staged")
    arguments = parser.parse_args()

    documents = list_markdown_documents()
    records = frozen_or_dated_record_paths()
    failures: list[str] = []
    warnings: list[str] = []
    check_links(documents, records, failures, warnings)
    check_reachability(documents, failures)
    check_backticked_paths(documents, records, failures, warnings)
    check_key_files_table(failures)
    check_document_sizes(documents, records, warnings)

    for warning in warnings:
        print(f"WARN  {warning}")
    for failure in failures:
        print(f"FAIL  {failure}")
    if arguments.changed or arguments.staged:
        base_reference = None if arguments.staged else arguments.changed
        for prompt in report_code_changes_without_document_changes(base_reference):
            print(f"CHECK {prompt}")
    print(f"DOCS_CHECK={'PASS' if not failures else 'FAIL'} documents={len(documents)} "
          f"failures={len(failures)} warnings={len(warnings)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

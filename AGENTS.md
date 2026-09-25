# Her — Agent Instructions

This file is the entry point for coding agents; `CLAUDE.md` is a symlink to it. It holds only the rules that apply to every change and a map of where everything else is written. Details live in small documents under `docs/`, indexed by [`docs/README.md`](docs/README.md).

## What this repository is

- **Her** (`com.yishuziyu.her`, Personal Team `87DM76C54G`): a macOS 14.2+ menu bar companion. StepFun realtime voice (Ctrl+Option) is the default mode, JEV text (Ctrl+K) the fallback. Gemini was removed on 2026-09-25.
- `os` is the only development repository. `我的agent` is frozen at tag `archive/2026-09-23-frozen`; port from it per [`docs/lineage.md`](docs/lineage.md), never add runtimes from it.
- The source folder, Swift module and many type names still use the historical `TipTour` namespace. Do not perform a cosmetic whole-codebase rename while consolidation is in progress.

## Read before you change

| If you are touching… | Read first |
| --- | --- |
| Product behavior, persona, priorities | [`docs/PRODUCT.md`](docs/PRODUCT.md), [`docs/ROADMAP.md`](docs/ROADMAP.md) |
| A provider mode, onboarding, voice session settings | [`docs/architecture/provider-modes.md`](docs/architecture/provider-modes.md) |
| Engine, grounding, perception, actions, harness | [`docs/architecture/runtime.md`](docs/architecture/runtime.md) |
| Anything that decides whether a step is done | [`docs/architecture/step-completion.md`](docs/architecture/step-completion.md) |
| Task coordinator, admission, journal, continuity | [`docs/architecture/task-continuity.md`](docs/architecture/task-continuity.md) |
| Where a file lives or what it does | [`docs/architecture/key-files.md`](docs/architecture/key-files.md), [`docs/source-layout.md`](docs/source-layout.md) |
| Building, isolated suites, probes | [`docs/guides/build-and-verification.md`](docs/guides/build-and-verification.md) |
| Real-user-path acceptance | [`docs/guides/acceptance.md`](docs/guides/acceptance.md) |
| Writing Swift in this codebase | [`docs/guides/code-style.md`](docs/guides/code-style.md) |
| The current stage's working contract and evidence | the newest dated file in [`docs/development/`](docs/development/README.md) |
| What to call a stage, metric or component | [`docs/terminology.md`](docs/terminology.md) — use only these names; no metaphors or nicknames |

## Hard rules

- **Do not run `xcodebuild` from the terminal** — it invalidates TCC permissions. Build in Xcode. Pure Swift typechecking and the isolated test scripts are allowed; none of them replaces or launches the installed app.
- Never bypass `CompanionManager` → `TipTourEngine` → `WorkflowRunner` → `ActionExecutor`/`TipTourActionDriver`. Every entry shares that engine, its permissions and its pauses.
- `DesktopActionCompletion` in `TipTour/Voice/DesktopTaskContract.swift` is the only authority for whether a step counts as done. Nothing re-derives its own completion rule.
- Provider keys live only in macOS Keychain: no environment, sibling-project or hosted-key fallback. The UI reports Keychain errors accurately.
- No Claude/Hermes integration, separate Flash Lite matcher, image-generation service, recording/video pipeline or Worker proxy is bundled. Do not reintroduce them without an explicit user request. Exception (user decision 2026-09-25): Stage 4 may invoke Claude Code and Codex as external command-line tools; they are not a second reasoning runtime inside Her. See [`docs/development/2026-09-25-claude-code-delegation-map.md`](docs/development/2026-09-25-claude-code-delegation-map.md).
- Do not add features, refactors or "improvements" beyond what was asked. Do not add docstrings, comments or type annotations to code you did not change.
- Do not fix the known non-blocking Swift 6 concurrency and deprecated `onChange` warnings as incidental cleanup.

## Testing rules

- Tests must be **results-based, not implementation-based**: assert the observable outcome the user cares about — receipts, spoken text, independent `/state` readback, real side effects — never that a particular function was called or implemented in a specific way. When a collaborator must be stubbed, stub at a real protocol/URL seam and still assert on the end result, not on which collaborators were invoked.
- E2E through the real product entrypoint is the primary completion gate: user's words → real Her build → real provider and executor → controlled local fixture page → real side effects → independent `/state` readback → Her receipt and speech → post-failure deduplication and recovery. Every E2E run must save a verifiable, repeatable evidence artifact (JSON) capturing the user's exact words, the model's tool arguments, task/turn/attempt IDs, Her receipts, independent `/state`, final speech text, and failure-recovery results.
- Existing XCTest / Swift Testing suites are regression protection only. They are never a completion criterion: no coverage targets, no test-count metrics, no exit-code-0 or reviewer self-assessment as proof of completion.
- If a system must be verified in isolation, first enumerate every way it can fail, then write the code against those failure outcomes — still asserting observable results, not internal mechanics.

## Documentation sync rule

A change is not finished until every current document it made wrong is corrected **in the same change**. Documents are part of the interface, not a follow-up task.

| When you change… | Update |
| --- | --- |
| Provider modes, shortcuts, onboarding, voice/VAD defaults (`TipTour/Voice/StepFun*`, `TipTour/Voice/RealtimeAudioPlayer.swift`, `TipTour/Jev/`, `TipTour/Core/TipTourMode.swift`, `TipTour/Utilities/TipTourDefaults.swift`, `TipTour/UI/`) | `docs/architecture/provider-modes.md`; `README.md` if a user would notice |
| Engine, workflow, actions, perception, harness, desktop task adapters | `docs/architecture/runtime.md` |
| Completion policy or predicates in `DesktopTaskContract.swift` | `docs/architecture/step-completion.md` |
| Task coordinator, admission, journal, continuity probe | `docs/architecture/task-continuity.md` |
| A source file added, deleted or renamed, or its size drifts by more than 50 lines | `docs/architecture/key-files.md` (and `docs/source-layout.md` for a new directory) |
| Test scripts, typecheck, build steps | `docs/guides/build-and-verification.md` |
| `scripts/acceptance/**` | `docs/guides/acceptance.md`, `docs/tools/acceptance-runner.md` |
| `tools/<name>/**` | `docs/tools/<name>.md` |
| A product direction or stage status | `docs/PRODUCT.md`, `docs/ROADMAP.md` |

Rules for the documents themselves:

1. Every document lives under `docs/` and is linked from [`docs/README.md`](docs/README.md). Directories under `tools/` and `scripts/` keep only a one-line `README.md` pointing there. Bundled `TipTour/Skills/**/SKILL.md` files are app resources, not documentation.
2. Progressive disclosure: keep a document to roughly 300 lines. When it grows past that, split it by section into sibling files and leave the parent as an overview plus links.
3. Frozen records under `docs/development/` are never rewritten, not even to fix a fact; write the correction in a current document and name what it supersedes.
4. Minor edits and bug fixes that change no documented fact need no document change.
5. The pre-commit hook (`scripts/git-hooks/pre-commit`, enabled per clone with `git config core.hooksPath scripts/git-hooks`) runs `python3 scripts/check-docs.py --staged` and blocks the commit on any failure; do not bypass it with `--no-verify` to land a documentation gap. Run the same check before finishing uncommitted work. It fails on broken links, documents unreachable from `README.md`, missing paths in the key-files table and line counts that drifted more than 50 lines. `python3 scripts/check-docs.py --changed` also lists code areas changed against `HEAD` whose mapped document did not change — a prompt to look, not proof of an omission.
6. Rules still miss things. At every merge to `main`, and at least weekly, run the full check and read the documents mapped to that period's changes against the code.

## Git workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

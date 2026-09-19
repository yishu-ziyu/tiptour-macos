# TipTour — Agent Instructions

This file is the source of truth for coding agents; CLAUDE.md is a symlink.

## Product

macOS 14.2+ menu bar-only SwiftUI/AppKit app (`LSUIElement=true`). Two provider modes ship together on `main`:

- **Gemini realtime**: Ctrl+Option toggles a voice session. Audio and optional screenshots go directly to Gemini using the user's Keychain key. One tool per user turn: a single desktop workflow action or the existing Apple Notes convenience action.
- **JEV text**: Ctrl+K opens the command panel. TypeSafe's `jev-latest` classifies locally detected screen labels and locations. JEV selects click/double-click/right-click targets, not prose or pixels. It acts on the top-ranked target without minimum probability or absent-score cutoffs. Its bounded loop stops on an explicit none choice, task completion, malformed responses, cancellation, action rejection/pause/failure, or 12 actions, with a final observation after the last action.

JEV is the default selected mode. Onboarding is Choose mode → Save that mode’s API key → Grant its permissions; Gemini additionally requires microphone access. The previous onboarding flag is migrated to a new mode-setup completion flag so existing users also choose a mode. Settings → Models shows the selector and only the selected mode’s key input. Keys are stored only in macOS Keychain; no environment, sibling project, or hosted-key fallback. The UI must report Keychain errors accurately.

No Claude/Hermes integration, separate Flash Lite matcher, image-generation service, recording/video pipeline, or Worker proxy is bundled. Do not reintroduce them without an explicit user request.

## Architecture

- `CompanionManager` persists the selected mode, initializes Gemini only when used, gates mode-specific shortcuts, and coordinates hotkeys, provider sessions, focus highlight, permissions, and overlay state. It owns the cancellable JEV task and prevents overlapping text/voice runs.
- `TipTourEngine` is the shared facade for perception, exact targets, workflow submission, action history, and localhost harness operations. `WorkflowRunner` owns pauses, per-operation tokens, target resolution, and post-action checks. `ActionExecutor`/`TipTourActionDriver` deliver CUA input. Never bypass these boundaries.
- Ground exact local IDs/marks first, then AX, browser DOM/CDP, local CoreML/OCR, and finally Gemini screenshot coordinates. JEV never invents coordinates and never walks stale alternative rankings after a failed action.
- JEV runs local detection while active without changing the user's persisted Accurate Grounding setting. Its command panel freezes position during execution; Escape/Stop cancels the task and active workflow.
- Ctrl+Shift paints focus context for Gemini. Ctrl+Option+Command is a Speak/Type/Highlight input chooser, not an extra model mode.
- Auto-click controls action delivery; Gemini supports point-only guidance, while JEV requires auto-click. CUA's toggle gates all desktop actions. Screenshots controls remote images, not local perception. Microphone is needed only for Gemini.
- AX is enabled for Electron on app activation. Preserve batched AX reads, messaging timeouts, target app pinning, clipboard/selected-range protections, and event-driven detection refreshes.
- The localhost harness (`127.0.0.1:19474`) exposes the engine to developer clients. `/v1/agent-contract` is canonical. Preserve trace IDs, single-action workflow limits, and explicit deterministic `/v1/tasks` sequences.
- Portable app instructions live in `TipTour/Skills/**/SKILL.md`; precedence is user overrides, project skills, then bundled skills. General documentation belongs outside the app target.

## Key files

| File | Purpose |
| --- | --- |
| `TipTour/App/CompanionManager.swift` | Shared state, provider coordination, hotkeys, highlight and detection lifecycle |
| `TipTour/Perception/LocalTargetContinuity.swift` | Matches the same label/source/display across small detection bounds changes before execution (~20 lines) |
| `TipTour/Core/TipTourMode.swift` | JEV-first mode defaults, key/shortcut metadata and permission requirements (~30 lines) |
| `TipTour/Core/TipTourEngine.swift` | Grounding, execution, validation and local harness facade |
| `TipTour/Jev/JevClient.swift` | Keychain-authenticated TypeSafe API client |
| `TipTour/Jev/JevGrounding.swift` | Bounded candidate requests and validated decisions |
| `TipTour/Jev/JevPointerLoop.swift` | Cancellable JEV action loop and immutable UI snapshots |
| `TipTour/Jev/JevStepPanelView.swift` | Decision progress in the text panel |
| `TipTour/Voice/GeminiLiveSession.swift` | Realtime session, microphone, screenshots and tool callbacks |
| `TipTour/Voice/GeminiLiveClient.swift` | Gemini WebSocket protocol and tool declarations |
| `TipTour/UI/ProviderSetupView.swift` | The two Keychain key cards |
| `TipTour/UI/CompanionPanelView.swift` | Compact mode hints, permissions and action controls |
| `TipTour/UI/TipTourSettingsView.swift` | Models, desktop actions, privacy, permissions and advanced options |
| `TipTour/UI/TextCommandPanelManager.swift` | Cursor-following, resizable command panel |
| `TipTour/UI/TextCommandPanelView.swift` | JEV input, stop control and results |
| `TipTour/Utilities/KeychainStore.swift` | Device-local provider credential storage |

See `docs/source-layout.md` for the remaining directory responsibilities.

## Build and verification

Open `tiptour-macos.xcodeproj`, select TipTour, build/run in Xcode. This fork is set up for local machine signing; see `docs/local-development.md` for the signing identity, bundle identifier, Sparkle feed and remote conventions used here.

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC permissions and the app will need to re-request screen recording/accessibility access. Pure Swift parsing/typechecking and isolated tests are permitted without replacing or launching the installed app. Run `scripts/test-jev.sh` for the JEV decision suite.

Known non-blocking Swift 6 concurrency and deprecated `onChange` warnings must not be fixed as incidental cleanup.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.

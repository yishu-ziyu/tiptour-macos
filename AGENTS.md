# Her — Agent Instructions

This file is the source of truth for coding agents; CLAUDE.md is a symlink.

## Product

The shipped product identity is now **Her** (`com.yishuziyu.her`) and local development uses Personal Team `87DM76C54G` with Apple Development signing. The repository, source folder, Swift module and many internal type names still use the historical `TipTour` namespace during migration. Do not perform a cosmetic whole-codebase rename while product/runtime consolidation is still in progress.

macOS 14.2+ menu bar-only SwiftUI/AppKit app (`LSUIElement=true`). Three provider modes ship together on `main` — `jev`, `gemini` (being retired) and `stepfun`:

- **Gemini realtime**: Ctrl+Option toggles a voice session. Audio and optional screenshots go directly to Gemini using the user's Keychain key. One tool per user turn: a single desktop workflow action or the existing Apple Notes convenience action.
- **StepFun realtime voice**: Ctrl+Option runs a full-duplex voice session. `response.audio.delta` from that same Realtime session is the only playback source; interruptions clear queued audio and pending actions. The realtime model receives **no direct image input**. `describe_screen` passes the locally captured image and its bounded AX/OCR candidate list to the vision client, with one observation ID. Screenshots obey the existing permission/toggle. An index requires that same observation ID; visual prose alone is not a clickable target.
  `act_on_screen` defaults to **one action**. Workflows require an explicit list of at most six steps; each result must be independently verified before continuing. Exact names and location constraints restrict the candidate set before model selection; a missing named target gets one re-observation, not an unrelated substitute. Supported primitives are click/double-click/right-click, open_app, type, press_key, shortcut and scroll, all through the existing engine. Typing requires a named, already-focused field and complete text.
  A top-level pointer request may omit `action` only when it carries an explicit pointer constraint (`target_label`, `index`+`observation_id`, `region`, or `anchor_label`+`relation`); a bare goal is rejected as incomplete rather than defaulting to click. In that narrow case JEV chooses click/double-click/right-click. Explicit actions and every workflow-step action are locked and cannot be overridden by JEV.
  Literal spatial wording remains code-owned even when the realtime model emits a conflicting mouse action. For top-level Chinese requests, `右边/右侧/右方` and `左边/左侧/左方` restore the corresponding horizontal region. If the model confuses `右边` with `right_click`, the action is corrected to ordinary click unless the preserved goal explicitly contains `右键`、`右击`、`上下文菜单` or an English right-click/context-menu equivalent. Never apply this correction to an explicit right-click request.
  `new`, `resume` and `correct` distinguish task intent. Current and historical actions are separate; verified progress is recorded even if interruption arrives before the receipt. Explicit resume cannot execute an unrelated or rejected plan. An action whose outcome is not independently verified puts the task into an explicit `uncertain_effect` state: it is not repeated, never enters the decision model's already-done history (the satisfied history: only independently verified, delivery-confirmed and user-confirmed steps count, while user confirmation never enters the verified history), and a plain resume or correction cannot switch to another candidate. The user resolves it explicitly with `uncertain_resolution`: `confirmed_succeeded` (recorded as user_confirmed: the step counts done and enters the satisfied history, but never the verified history), `confirmed_failed` (block lifts, attempt stays attempted-unverified), `retry_same` (same-goal resume, the recorded target is pinned so the retry cannot pick another candidate), or `replace_target` (with `intent=correct` and an explicit new target). Uncertain records are scoped to their task chain, so a brand-new instruction is never blocked by an older task's uncertainty.
  Normal conversation plays Realtime audio as it arrives. Session voice is configured once in `session.update`; response.create never overrides it again. Once a response emits a real tool call, any queued/spilling tool-preamble audio from that response is suppressed; the result response is not created until the original response has actually ended. After the tool result is sent, the turn waits in an awaiting-followup-created phase instead of going idle. A barge-in in that window cannot tell the pending follow-up's `response.created` from the user's next response (measured: StepFun echoes neither `response.metadata` nor a client `event_id`, and a cancelled follow-up still emits created + done(incomplete) with no audio), so the session cancels the follow-up and performs one explicit session rebuild — retiring the socket the stale follow-up lives on instead of assuming which created is which. Probe: `swift run --package-path tools/stepprobe stepprobe followup-race`. Action speech is generated from the current receipt: the same Realtime session receives a one-response exact-reading instruction, and its audio is buffered until the returned transcript matches that receipt. A mismatch is displayed but not played. Screen questions retain four historical observations; window/input changes invalidate old reads. Voice telemetry records speech-stop→first-audio latency and whether the server-reported voice matches the requested session voice, without raw audio/text by default.
- **JEV text**: Ctrl+K opens the command panel. TypeSafe's `jev-latest` classifies locally detected screen labels and locations. JEV selects click/double-click/right-click targets, not prose or pixels. It acts on the top-ranked target without minimum probability or absent-score cutoffs. Its bounded loop stops on an explicit none choice, task completion, malformed responses, cancellation, action rejection/pause/failure, or 12 actions, with a final observation after the last action.

JEV is the default selected mode. `stepfun` occupies the voice slot alongside the outgoing `gemini`. Onboarding is Choose mode → Save that mode’s API key → Grant its permissions; Both voice modes require microphone access. The previous onboarding flag is migrated to a new mode-setup completion flag so existing users also choose a mode. Settings → Models shows the selector and only the selected mode’s key input. Successful key reads are reused in process memory; settings check presence without decrypting. Keys are stored only in macOS Keychain; no environment, sibling project, or hosted-key fallback. The UI must report Keychain errors accurately.

No Claude/Hermes integration, separate Flash Lite matcher, image-generation service, recording/video pipeline, or Worker proxy is bundled. Do not reintroduce them without an explicit user request.

## Architecture

- `CompanionManager` persists the selected mode, initializes Gemini only when used, gates mode-specific shortcuts, and coordinates hotkeys, provider sessions, focus highlight, permissions, and overlay state. It owns the cancellable JEV task and prevents overlapping text/voice runs.
- `TipTourEngine` is the shared facade for perception, exact targets, workflow submission, action history, and localhost harness operations. `WorkflowRunner` owns pauses, per-operation tokens, target resolution, and post-action checks. `ActionExecutor`/`TipTourActionDriver` deliver CUA input. Never bypass these boundaries.
- Ground exact local IDs/marks first, then AX, browser DOM/CDP, local CoreML/OCR, and finally Gemini screenshot coordinates. JEV never invents coordinates and never walks stale alternative rankings after a failed action.
- JEV runs local detection while active without changing the user's persisted Accurate Grounding setting. Its command panel freezes position during execution; Escape/Stop cancels the task and active workflow.
- Ctrl+Shift paints focus context for Gemini. Ctrl+Option+Command is a Speak/Type/Highlight input chooser, not an extra model mode.
- Auto-click controls action delivery; Gemini supports point-only guidance, while JEV requires auto-click. CUA's toggle gates all desktop actions. Screenshots controls remote images, not local perception. Both voice modes need the microphone.
- AX is enabled for Electron on app activation. Preserve batched AX reads, messaging timeouts, target app pinning, clipboard/selected-range protections, and event-driven detection refreshes.
- The perception cache retains one local image with its capture time and observation identity. Visual candidates are restricted to the target application's foreground window; whole-display OCR from other apps cannot become its controls. Window identity and bounds participate in capture invalidation; the JEV panel uses the application captured by its shortcut rather than the panel itself. AX controls are merged with OCR before ranking; secure AX fields are excluded by the AX reader. This does not redact screenshots, so the remote screenshot toggle remains important. Failed/superseded captures cannot replace newer observations. YOLO may only borrow overlapping OCR text; a highly overlapping YOLO box cannot rename the same AX control. Distinct same-name controls remain distinct.
- `DesktopTaskExecutor` adapts voice steps to the shared engine. `DesktopActionVerifier` checks selected/focused state, typed values, or a newly visible explicit result label. A driver return, changing target set, or model `done` is insufficient. Generic keyboard/scroll outcomes without a checkable result remain unconfirmed; do not market that as full workflow completion.
- `DesktopDecisionPacket` is the per-action SSOT for `intent / action / target / where / scope / confidence / perception / planning / evidence`. Exact and targetless actions create deterministic packets. Ambiguous pointer actions use JEV speculative fan-out: one request asks `action` plus `target_click`, `target_double_click`, and `target_right_click`; code consumes only the target head matching the chosen or explicitly locked action. Probability and margin are recorded but are not threshold-gated until labeled traffic exists.
- `open_app` is a targetless fast path: it uses context-only observation, never requires screenshot/OCR/JEV, resolves localized installed-app names once to a bundle ID, then reuses WorkflowRunner/ActionExecutor and verifies that the target bundle has a live process. Intermediate app activations must not cancel the atomic launch; any later step still re-pins the foreground app/window before sending input, and unrelated switches still pause other action types.
- `open_app` success means user-visible state, not merely a live process: the resolved app (including nested helper bundles) must own an on-screen top-level window and be foreground. If a background wrapper process exists with no window, LaunchServices gets one bounded reopen attempt; otherwise the receipt stays unverified and must not say the app opened.
- `describe_screen` must describe the target application's visible window, never the cursor display as a substitute. It first checks for an on-screen top-level window, captures that `SCWindow` directly, and refuses visual claims when the app has no visible window. The captured window is the focused AX window mapped to its `SCWindow` (falling back to frontmost z-order, never largest-area), and the observation is bound to that window's identity: a slow vision result is only spoken while the same window ID, frame, app and content version are still current, the capture is fresh (`DesktopObservedWindowIdentity`), AND a fresh capture of the same window still matches its dHash content fingerprint (re-verified owner PID included) — so a same-window page navigation or dialog during the call is caught and re-read once. A yes/no “can you see it?” question is answered from local window state without the remote vision round-trip. Whole-display OCR/YOLO is suppressed when the selected app has no visible window so desktop/other-app text cannot be attributed to it.
- `DesktopVoiceTrace` uses the `VoiceTask` unified-log category with status/identity metadata. Opt-in DEBUG `voiceDiagnosticTraceEnabled` writes bounded local raw diagnostics, not credentials or images. Do not enable it silently for private user sessions.
- The localhost harness (`127.0.0.1:19474`) exposes the engine to developer clients. `/v1/agent-contract` is canonical. Preserve trace IDs, single-action workflow limits, and explicit deterministic `/v1/tasks` sequences.
- Portable app instructions live in `TipTour/Skills/**/SKILL.md`; precedence is user overrides, project skills, then bundled skills. General documentation belongs outside the app target.

## Experimental task continuity

`--voice-task-continuity` opts into the application-retained StepFun task path.
It is **off by default** until real-provider, real-desktop and microphone acceptance
pass. It does not merge the other repositories or enable a new runtime/provider.

- `CompanionManager` retains the task router independently of a voice session.
  The existing `DesktopTaskCoordinator` owns execution, task/revision/attempt identity,
  progress and terminal facts. Each voice session receives an identity-bound handler;
  a retired handler cannot stop or control its replacement's task.
- Speech first clears playback and pauses future desktop delivery. In-flight action
  readback survives loss of the voice waiter. Progress queries return a snapshot without
  waiting for readback; any deferred continuation is checked again after settlement.
  New turns, cancellation, disconnection and uncertain effects invalidate that continuation.
  Automatic continuation also checks the verified after-scene's app/window/content version;
  explicit resume remains distinct from merely asking for progress.
- `task_control` status is read-only. Continuing/cancelling binds task ID, target version
  and current user-turn ID. Task snapshots are data, never fresh authorization. State
  updates refresh the panel and model context without unsolicited speech; they do not
  replay an old connection's `function_call_output` or create a second TTS route.
- `DesktopTaskAdmission` coordinates this process's reachable task/engine/driver entries.
  Busy requests are rejected before focus-changing perception or action delivery. A stopped
  driver retains its execution occupancy until it returns. Task-owned settled attempts
  retire their workflow while legacy UI pauses retain their own explicit resume controls.
  `TipTourLongTaskCoordinator` is still a separate legacy task path with mutual
  exclusion, not yet the fully unified task owner. This is not a cross-process lock.
- `DesktopTaskJournal` records only recovery metadata in Application Support / bundle ID /
  `TaskRecovery/task.json`: IDs, counts, action kinds, target digests and delivery/verification
  state. It does not persist goals, typed text, screenshots, audio or credentials. Admission
  and attempt metadata are written before dispatch; write/read failure blocks further work.
  An unreadable journal is preserved and reported. Restart recovery requires inspection,
  not automatic replay; this is a current-task recovery file, not full historical memory.

`scripts/test-workflow-integration.py --derived-data <existing-checkout-DerivedData>`
compiles actual app sources into an isolated headless test package against existing
dependencies. Use `--filter 'WorkflowRunnerIntegrationTests|TaskRouterIntegrationTests|VoiceTaskSessionIntegrationTests'`
for the production-source seams. It does not replace real UI/provider acceptance.

The signed DEBUG app accepts `--voice-continuity-probe <progress.pcm> <cancel.pcm> <report.json>`.
Inputs are public synthetic PCM16 / 24 kHz mono. It tests two provider sessions with the
production session/router but an in-memory executor, and never opens the microphone,
plays sound, starts monitors, drives the desktop or loads the real task journal. Keychain
access remains non-interactive and fails without a credential fallback; the report includes
only the OS failure code/message, not a key. See the current task document for evidence.

## Key files

| File | Purpose |
| --- | --- |
| `TipTour/App/CompanionManager.swift` | Shared state, provider coordination, hotkeys, highlight and detection lifecycle |
| `TipTour/Perception/LocalTargetContinuity.swift` | Matches the same label/source/display across small detection bounds changes before execution (~20 lines) |
| `TipTour/Core/TipTourMode.swift` | JEV-first mode defaults, key/shortcut metadata and permission requirements (~30 lines) |
| `TipTour/Core/TipTourEngine.swift` | Grounding, execution, validation and local harness facade |
| `TipTour/Jev/JevClient.swift` | Keychain-authenticated TypeSafe API client |
| `TipTour/Jev/JevGrounding.swift` | Bounded speculative action/target fan-out and validated decisions |
| `TipTour/Jev/JevPointerLoop.swift` | Cancellable JEV action loop and immutable UI snapshots |
| `TipTour/Jev/JevStepPanelView.swift` | Decision progress in the text panel |
| `TipTour/Voice/GeminiLiveSession.swift` | Realtime session, microphone, screenshots and tool callbacks |
| `TipTour/Voice/GeminiLiveClient.swift` | Gemini WebSocket protocol and tool declarations |
| `TipTour/Voice/StepFunRealtimeClient.swift` | Ordered WebSocket events, response identity filtering, deduplicated calls and task-context data (~710 lines) |
| `TipTour/Voice/StepFunRealtimeSession.swift` | Full-duplex session, receipt speech, cancellation and production-path synthetic probe (~1090 lines) |
| `TipTour/Voice/StepFunRealtimeTools.swift` | Strict task/step parameters and observation-bound indices (~245 lines) |
| `TipTour/Voice/StepFunRealtimeToolRouter.swift` | Shared scene identity, constrained routing, task controls and session-bound access (~545 lines) |
| `TipTour/Voice/StepFunVisionClient.swift` | Screen understanding, history-aware comparison and bounded general-model decisions (~295 lines) |
| `TipTourTests/StepFunVisionClientTests.swift` | Vision request format and malformed screen-description regressions (~65 lines) |
| `TipTour/Voice/DesktopTaskCoordinator.swift` | Task-owned execution, goal revisions, step budget, verified progress, safe continuation and uncertainty (~671 lines) |
| `TipTour/Voice/DesktopTaskContract.swift` | Typed actions, literal/spatial constraints, task submissions and receipts/speech (~265 lines) |
| `TipTour/Voice/DesktopTaskAdmission.swift` | Process-local task ownership and per-execution dispatch admission (~23 lines) |
| `TipTour/Voice/DesktopTaskJournal.swift` | Private, atomic metadata-only recovery checkpoint; no automatic replay (~103 lines) |
| `TipTour/Voice/VoiceTaskContinuityProbe.swift` | Signed-app, no-mic/no-desktop provider smoke with a fixture executor (~123 lines) |
| `TipTourTests/DesktopTaskContinuityTests.swift` | Task identity, interruption, deferred continuation, journal and recovery behavior (~462 lines) |
| `TipTourTests/WorkflowRunnerIntegrationTests.swift` | Actual engine/runner admission, delivery lifetime and terminal-status tests (~176 lines) |
| `TipTourTests/TaskRouterIntegrationTests.swift` | Actual router binding, status controls and constrained resume tests (~125 lines) |
| `TipTourTests/VoiceTaskSessionIntegrationTests.swift` | Production speech event pauses without cancelling the task (~36 lines) |
| `TipTour/Voice/DesktopDecisionPacket.swift` | Shared structured action/target/where/confidence decision packet (~125 lines) |
| `TipTour/Voice/DesktopTaskExecutor.swift` | Existing-engine adapter and independent before/after readback (~125 lines) |
| `TipTour/Voice/DesktopApplicationResolver.swift` | Installed-app catalog, Spotlight-localized names and stable bundle-ID resolution (~180 lines) |
| `TipTour/Voice/DesktopObservedWindowIdentity.swift` | Window identity + dHash content fingerprint for slow vision observations (~110 lines) |
| `TipTour/Voice/DesktopActionVerifier.swift` | Pure target-specific result predicates (~55 lines) |
| `TipTour/Perception/DesktopAccessibilityReader.swift` | Bounded read-only AX evidence and local candidate geometry (~110 lines) |
| `TipTour/Voice/StepFunResponseBoundary.swift` | Stale/duplicate response rejection and verified-receipt transcript matching (~55 lines) |
| `TipTour/Voice/DesktopVoiceTrace.swift` | Metadata telemetry and explicitly enabled bounded local diagnostics (~55 lines) |
| `TipTour/Voice/VoiceRouteProbe.swift` | DEBUG probes; voice-task uses the production session and JEV fan-out probe never executes actions (~260 lines) |
| `TipTour/Workflow/WorkflowModalPolicy.swift` | Distinguishes blocking modals from unrelated modeless windows (~11 lines) |
| `TipTourTests/DesktopTaskCoordinatorTests.swift` | Execution, cancellation, budget, escalation and continuation regressions (~395 lines) |
| `TipTourTests/DesktopControlContractTests.swift` | Receipt, targeting, verification, response boundary, window identity and resume regressions (~575 lines) |
| `TipTourTests/WorkflowModalPolicyTests.swift` | Blocking-dialog and modeless-window rules (~15 lines) |
| `TipTourTests/NativeElementDetectorTests.swift` | Real OCR regression for Chinese and English control labels (~30 lines) |
| `TipTourTests/LocalPerceptionTargetCacheTests.swift` | Duplicate preservation, frame identity, window isolation and contradictory-label regressions (~130 lines) |
| `TipTour/UI/ProviderSetupView.swift` | The two Keychain key cards |
| `TipTour/UI/CompanionPanelView.swift` | Compact mode hints, permissions and action controls |
| `TipTour/UI/TipTourSettingsView.swift` | Models, desktop actions, privacy, permissions and advanced options |
| `TipTour/UI/TextCommandPanelManager.swift` | Cursor-following, resizable command panel |
| `TipTour/UI/TextCommandPanelView.swift` | JEV input, stop control and results |
| `TipTour/Utilities/KeychainStore.swift` | Device-local provider credential storage |

See `docs/source-layout.md` for the remaining directory responsibilities.

## Build and verification

`tools/voice-acceptance/fixture.py` serves disposable controls on `127.0.0.1:19475` with
independent `/state` readback. DEBUG-only probe launch arguments are documented in
`tools/voice-acceptance/README.md`; they never export keys or open the microphone.
Real desktop probes still require exclusive access to the target window.

Run `bash scripts/test-local-perception.sh` for the real OCR regression on Simplified Chinese,
Traditional Chinese and English controls, plus cross-source duplicate detection and blocking-modal tests. It uses a generated image and an isolated package,
without launching or replacing the app.

Open `tiptour-macos.xcodeproj`, select the `tiptour-macos` scheme, build/run in Xcode.
Run `scripts/test-stepfun.sh` and `scripts/test-jev.sh` for the decision suites, which compile
into temporary packages and never touch the installed app. Her uses the local Personal Team signing identity; see `docs/local-development.md` for signing, bundle identifier, Sparkle feed and remote conventions used here.

Run `scripts/test-stepfun-voice-lifecycle.sh` for isolated voice turn-lifecycle, task coordination, audio playback and vision-client tests; it compiles real sources without launching the app or opening the microphone. Vision requests use a local URLProtocol fixture.

The StepFun scripts accept Swift test filters, e.g. `bash scripts/test-stepfun-voice-lifecycle.sh --filter DesktopControlContractTests`.
`python3 scripts/typecheck-local-app.py --derived-data <existing-checkout-DerivedData>` type-checks against an existing Xcode dependency build without linking, signing, installing or launching. It does not replace Xcode build or runtime acceptance.

The current control contract and evidence are in `docs/development/2026-09-21-trustworthy-desktop-control.md`.
Read the evidence status before enabling automated real-app trials or changing the default entrypoint.

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC permissions and the app will need to re-request screen recording/accessibility access. Pure Swift parsing/typechecking and isolated tests are permitted without replacing or launching the installed app. Run `scripts/test-jev.sh` and `scripts/test-stepfun.sh` for the two decision suites.

Known non-blocking Swift 6 concurrency and deprecated `onChange` warnings must not be fixed as incidental cleanup.

## Testing Rules

- NEVER write unit tests after you write code.
- Highly prefer E2E tests as the sole testing mechanism. Use them to verify complex features work. At the end of E2E tests, produce a verifiable and repeatable artifact.
- If you must test a system in isolation, FIRST write all the ways it could fail, THEN write the code.

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

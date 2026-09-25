# Key files

Part of the [architecture overview](README.md). Moved verbatim from `AGENTS.md` on 2026-09-23.
Keep the approximate line counts within 50 lines of the real file; `scripts/check-docs.py` checks this.

| File | Purpose |
| --- | --- |
| `TipTour/App/CompanionManager.swift` | Shared state, provider coordination, hotkeys, highlight and detection lifecycle |
| `TipTour/App/TipTourApp.swift` | App entry point, Sparkle gate (skipped without `SUFeedURL`/`SUPublicEDKey`), DEBUG probe dispatch, then single-instance retirement before interactive start (~132 lines) |
| `TipTour/Utilities/SingleInstanceGuard.swift` | A normal launch quits other interactive Her instances (argv read via `KERN_PROCARGS2`; `-probe`/`--preflight` runs are left alone); if one survives a forced quit (e.g. held by the Xcode debugger) the new instance exits instead, so two sessions never share the mic and hotkey (~95 lines) |
| `TipTour/Workflow/WorkflowRunner.swift` | Operation tokens, pause/resume, target resolution and post-action checks shared by every entry (~1842 lines) |
| `TipTour/Actions/ActionExecutor.swift` | Delivers CUA input and reports the delivery fact for an attempt; DEBUG-only receipt-loss fault injection for the unknown/recovery acceptance (~1187 lines) |
| `TipTour/Actions/TipTourActionDriver.swift` | CUA driver boundary (~69 lines) |
| `TipTour/Harnesses/TipTourHarnessServer.swift` | Localhost engine API on `127.0.0.1:19474`, `/v1/agent-contract` canonical (~1183 lines) |
| `TipTourTests/HarnessOriginIntegrationTests.swift` | Real local HTTP check for loopback access and foreign browser-origin rejection |
| `TipTour/Perception/LocalTargetContinuity.swift` | Matches the same label/source/display across small detection bounds changes before execution (~20 lines) |
| `TipTour/Core/TipTourMode.swift` | JEV-first mode defaults, key/shortcut metadata and permission requirements (~93 lines) |
| `TipTour/Core/TipTourEngine.swift` | Grounding, execution, validation and local harness facade |
| `TipTour/Jev/JevClient.swift` | Keychain-authenticated TypeSafe API client |
| `TipTour/Jev/JevGrounding.swift` | Bounded speculative action/target fan-out and validated decisions |
| `TipTour/Jev/JevPointerLoop.swift` | Cancellable JEV action loop and immutable UI snapshots |
| `TipTour/Jev/JevStepPanelView.swift` | Decision progress in the text panel |
| `TipTour/Voice/GeminiLiveSession.swift` | Realtime session, microphone, screenshots and tool callbacks |
| `TipTour/Voice/GeminiLiveClient.swift` | Gemini WebSocket protocol and tool declarations |
| `TipTour/Voice/StepFunRealtimeClient.swift` | Ordered WebSocket events, response identity filtering, deduplicated calls and task-context data (~710 lines) |
| `TipTour/Voice/StepFunRealtimeSession.swift` | Full-duplex session, receipt speech, cancellation and production-path synthetic probe (~1300 lines) |
| `TipTour/Voice/StepFunRealtimeTools.swift` | Strict task/step parameters, observation-bound indices, goal-declared operation gate, redundant-action normalization and model-facing expected_label guidance (~627 lines) |
| `TipTour/Voice/StepFunRealtimeToolRouter.swift` | Shared scene identity, constrained routing, task controls and session-bound access (~545 lines) |
| `TipTour/Voice/StepFunVisionClient.swift` | Screen understanding, history-aware comparison and bounded general-model decisions (~295 lines) |
| `TipTourTests/StepFunVisionClientTests.swift` | Vision request format and malformed screen-description regressions (~65 lines) |
| `TipTour/Voice/DesktopTaskCoordinator.swift` | Task-owned execution, goal revisions, step budget, verified progress, safe continuation and uncertainty (~671 lines) |
| `TipTour/Voice/DesktopTaskContract.swift` | Typed actions, literal/spatial constraints, delivery vs outcome evidence, step completion predicates, receipts and speech (~543 lines) |
| `TipTour/Voice/DesktopTaskAdmission.swift` | Process-local task ownership and per-execution dispatch admission (~23 lines) |
| `TipTour/Voice/DesktopTaskJournal.swift` | Private, atomic metadata-only recovery checkpoint; no automatic replay (~187 lines) |
| `TipTour/Voice/VoiceTaskContinuityProbe.swift` | Signed-app, no-mic/no-desktop provider smoke with a fixture executor; delivery-only vs verified progress wording and cancellation chains (~493 lines) |
| `TipTourTests/DesktopTaskContinuityTests.swift` | Task identity, interruption, deferred continuation, journal and recovery behavior (~462 lines) |
| `TipTourTests/WorkflowRunnerIntegrationTests.swift` | Actual engine/runner admission, delivery lifetime and terminal-status tests (~176 lines) |
| `TipTourTests/TaskRouterIntegrationTests.swift` | Actual router binding, status controls and constrained resume tests (~125 lines) |
| `TipTourTests/VoiceTaskSessionIntegrationTests.swift` | Production speech event pauses without cancelling the task (~36 lines) |
| `TipTour/Voice/DesktopDecisionPacket.swift` | Shared structured action/target/where/confidence decision packet (~125 lines) |
| `TipTour/Voice/DesktopTaskExecutor.swift` | Existing-engine adapter and independent before/after readback (~229 lines) |
| `TipTour/Voice/DesktopApplicationResolver.swift` | Installed-app catalog, Spotlight-localized names and stable bundle-ID resolution (~262 lines) |
| `TipTour/Voice/DesktopObservedWindowIdentity.swift` | Window identity + dHash content fingerprint for slow vision observations (~110 lines) |
| `TipTour/Voice/DesktopActionVerifier.swift` | Pure target-specific result predicates (~55 lines) |
| `TipTour/Perception/DesktopAccessibilityReader.swift` | Bounded read-only AX evidence and local candidate geometry (~110 lines) |
| `TipTour/Voice/StepFunResponseBoundary.swift` | Stale/duplicate response rejection and verified-receipt transcript matching (~55 lines) |
| `TipTour/Voice/DesktopVoiceTrace.swift` | Metadata telemetry and explicitly enabled bounded local diagnostics, written under the Her bundle identity (~61 lines) |
| `TipTour/Voice/VoiceRouteProbe.swift` | DEBUG probes; voice-task uses the production session, JEV fan-out probe never executes actions, receipt-loss/journal-recovery/preflight probe dispatch (~312 lines) |
| `TipTour/Voice/DiagnosticPreflight.swift` | DEBUG-only read-only acceptance preflight: bundle/team identity, accessibility trust, frontmost identity, no prompts (~132 lines) |
| `TipTour/Voice/DesktopFaultRecoveryProbe.swift` | DEBUG-only one-shot receipt-loss fault plus receipt-loss and v1 journal-recovery acceptance probes (~724 lines) |
| `TipTour/Workflow/WorkflowModalPolicy.swift` | Distinguishes blocking modals from unrelated modeless windows (~11 lines) |
| `TipTourTests/DesktopTaskCoordinatorTests.swift` | Execution, cancellation, budget, escalation and continuation regressions, including the delivery-vs-outcome completion matrix (~1013 lines) |
| `TipTourTests/DesktopControlContractTests.swift` | Receipt, targeting, verification, response boundary, window identity and resume regressions (~648 lines) |
| `TipTourTests/WorkflowModalPolicyTests.swift` | Blocking-dialog and modeless-window rules (~15 lines) |
| `TipTourTests/NativeElementDetectorTests.swift` | Real OCR regression for Chinese and English control labels (~30 lines) |
| `TipTourTests/LocalPerceptionTargetCacheTests.swift` | Duplicate preservation, frame identity, window isolation and contradictory-label regressions (~130 lines) |
| `TipTour/UI/ProviderSetupView.swift` | The two Keychain key cards, the shared name field and the realtime voice picker |
| `TipTour/UI/CompanionPanelView.swift` | Menu bar panel shell: header with `ThinkingOrb` and live status, setup vs ready vs unusable-key routing, footer (~145 lines) |
| `TipTour/UI/Panel/PanelStyle.swift` | Panel material, system-adaptive colors, the pill-to-panel reveal and shared keycap/chip/button pieces (~250 lines) |
| `TipTour/UI/Panel/PanelOnboardingView.swift` | Two-step setup (key with portal link, first-use permissions) and the in-place key field (~195 lines) |
| `TipTour/UI/Panel/PanelReadyView.swift` | Ready panel: clickable shortcut keys, example phrases, live transcript, receipt, missing permissions (~200 lines) |
| `TipTour/UI/Panel/PanelPermissionRow.swift` | One permission: reason, request path, granted state (~110 lines) |
| `TipTour/UI/ThinkingOrb/ThinkingOrbView.swift` | System-layer presence orb and its voice-state mapping (idle breathing, connecting, listening, responding); ink set by surface, not system appearance (~85 lines) |
| `TipTour/UI/ThinkingOrb/ThinkingOrbEngine.swift` | Dotted-orb Canvas renderer; MIT thinking-orbs lineage, license beside it (~1010 lines) |
| `TipTour/Voice/VoiceConsistencyProbe.swift` | DEBUG `--voice-consistency-probe <voice> <dir> <turn.pcm>...` (several synthetic turns in one session, production persona or `-probePersonaFile`, each reply's audio saved) and `--vad-probe <out.json> <speech.pcm> <noise_dbfs> <tail_s>` (server-VAD start/stop timing against noise; threshold from `-stepfunVADEnergyThreshold`) (~200 lines) |
| `scripts/acceptance/voice_consistency_report.py` | Pitch/MFCC speaker-drift measurement between those replies; `--self-check` proves it flags a `say` speaker change |
| `scripts/acceptance/voice_latency_report.py` | Streams VoiceTask telemetry during a real-mic session and reports speech-stop→first-audio and estimated barge-in p50 |
| `TipTour/UI/TipTourSettingsView.swift` | Models, desktop actions, privacy, permissions and advanced options |
| `TipTour/UI/TipTourSettingsWindowManager.swift` | Settings and log windows; default pipeline events store only diagnostic IDs, statuses and counts |
| `TipTourTests/PipelineLogIntegrationTests.swift` | Serialized default-log privacy regression without writing to the user's log files |
| `TipTour/UI/TextCommandPanelManager.swift` | Cursor-following, resizable command panel |
| `TipTour/UI/TextCommandPanelView.swift` | JEV input, stop control and results |
| `TipTour/Utilities/KeychainStore.swift` | Device-local provider credential storage; existence vs in-process readability states, DEBUG-only acceptance denial seam (~540 lines) |

See `docs/source-layout.md` for the remaining directory responsibilities.

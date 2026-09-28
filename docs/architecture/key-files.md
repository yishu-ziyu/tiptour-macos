# Key files

Part of the [architecture overview](README.md). Moved verbatim from `AGENTS.md` on 2026-09-23.
Keep the approximate line counts within 50 lines of the real file; `scripts/check-docs.py` checks this.

| File | Purpose |
| --- | --- |
| `TipTour/App/CompanionManager.swift` | Shared state, provider coordination, hotkeys, highlight and detection lifecycle |
| `TipTour/App/DelegationNoticeCenter.swift` | Hand-off notices as ordinary macOS notifications: delegate set in `applicationWillFinishLaunching`, permission asked at the first hand-off without waiting, a refusal reported in the panel, click opens Ctrl+K on that record, 「这类不再提醒」 action with a receipt naming where to undo it, notices withdrawn once decided (~93 lines) |
| `TipTour/App/DiscoveryNotices.swift` | Roadmap 3.4 trial: reads the day file `scripts/daily-discovery.py` writes to `~/Library/Application Support/Her/discovery/`, posts each pick once (link opens on click) and records 「这类别推」 in `silenced.json` for the script |
| `TipTour/App/TipTourApp.swift` | App entry point, Sparkle gate (skipped without `SUFeedURL`/`SUPublicEDKey`), DEBUG probe dispatch, then single-instance retirement before interactive start (~132 lines) |
| `TipTour/Utilities/SingleInstanceGuard.swift` | A normal launch quits other interactive Her instances (argv read via `KERN_PROCARGS2`; `-probe`/`--preflight` runs are left alone); if one survives a forced quit (e.g. held by the Xcode debugger) the new instance exits instead, so two sessions never share the mic and hotkey (~95 lines) |
| `TipTour/Utilities/ListenOnlyEventTap.swift` | The listen-only CGEvent tap shared by the four global shortcut monitors (push-to-talk, Ctrl+K, highlight, radial input): events always pass through, the tap re-enables itself after a timeout, and restarting while running is a no-op (~105 lines) |
| `TipTour/Workflow/WorkflowRunner.swift` | Operation tokens, pause/resume, target resolution and post-action checks shared by every entry (~1842 lines) |
| `TipTour/Actions/ActionExecutor.swift` | Delivers CUA input and reports the delivery fact for an attempt; DEBUG-only receipt-loss fault injection for the unknown/recovery acceptance (~1187 lines) |
| `TipTour/Actions/TipTourActionDriver.swift` | CUA driver boundary (~69 lines) |
| `TipTour/Harnesses/TipTourHarnessServer.swift` | Localhost engine API on `127.0.0.1:19474`, `/v1/agent-contract` canonical (~1113 lines) |
| `TipTourTests/HarnessOriginIntegrationTests.swift` | Real local HTTP check for loopback access and foreign browser-origin rejection |
| `TipTour/Perception/LocalTargetContinuity.swift` | Matches the same label/source/display across small detection bounds changes before execution (~20 lines) |
| `TipTour/Core/TipTourMode.swift` | StepFun voice and JEV text modes, default and retired-value restore, key/shortcut metadata and permission requirements (~101 lines) |
| `TipTour/Core/TipTourEngine.swift` | Grounding, execution, validation and local harness facade |
| `TipTour/Jev/JevClient.swift` | Keychain-authenticated TypeSafe API client |
| `TipTour/Jev/JevGrounding.swift` | Bounded speculative action/target fan-out and validated decisions |
| `TipTour/Jev/JevPointerLoop.swift` | Cancellable JEV action loop and immutable UI snapshots |
| `TipTour/Jev/JevStepPanelView.swift` | Decision progress in the text panel |
| `TipTour/Voice/RealtimeAudioPlayer.swift` | StepFun PCM16 playback on the shared engine, odd-byte carry and underrun counts (~283 lines) |
| `TipTour/Voice/StepFunRealtimeClient.swift` | Ordered WebSocket events, response identity filtering, deduplicated calls and task-context data (~710 lines) |
| `TipTour/Voice/StepFunRealtimeSession.swift` | Full-duplex session with a per-session half-duplex fallback after own echo, receipt speech, cancellation and production-path synthetic probe (~1533 lines) |
| `TipTour/Voice/StepFunRealtimeTools.swift` | Strict task/step parameters, observation-bound indices, goal-declared operation gate, redundant-action normalization and model-facing expected_label guidance; the `remember_names` declaration and its argument decoding (~670 lines) |
| `TipTour/Voice/StepFunRealtimeToolRouter.swift` | Shared scene identity, constrained routing, task controls, name saving handed to the app, and session-bound access (~559 lines) |
| `TipTour/Voice/StepAudioTranscriber.swift` | 「声音稳定」 speech-to-text: one utterance to Step Plan `stepaudio-2.5-asr` over HTTP + SSE (~90 lines) |
| `TipTour/Voice/MiniMaxSpeechClient.swift` | 「声音稳定」 speech: MiniMax `t2a_v2` streamed as 24 kHz PCM16 in the user's own voice; provider errors surfaced (~120 lines) |
| `TipTour/Voice/StableVoiceConversation.swift` | 「声音稳定」 reply from the Ctrl+K chat model with the shared identity, Ctrl+K context and names as fields; speaking lines shared with realtime voice (~115 lines) |
| `TipTour/Voice/StableVoiceTurnRunner.swift` | One hold-to-talk turn: heard → reply → names saved → speech, interruption by pressing again, per-step timings (~180 lines) |
| `TipTour/Voice/StableVoiceSession.swift` | Microphone only while ⌃⌥ is held (own engine), output-only playback engine (~110 lines) |
| `TipTour/Voice/StableVoiceProbe.swift` | DEBUG `--stable-voice-probe <dir> <turn.pcm>...`: real services, production turn logic, output shaped like the realtime consistency probe (~115 lines) |
| `TipTourTests/StableVoiceTests.swift` | Stubbed-HTTP speech-to-text and speech parsing, reply/name/transcript rules, and whole turns with a fake microphone and speaker (~330 lines) |
| `TipTour/Voice/StepFunVisionClient.swift` | Screen understanding, history-aware comparison and bounded general-model decisions (~295 lines) |
| `TipTourTests/StepFunVisionClientTests.swift` | Vision request format and malformed screen-description regressions (~65 lines) |
| `TipTour/Voice/DesktopTaskCoordinator.swift` | Task-owned execution, goal revisions, step budget, verified progress, safe continuation and uncertainty; `run` is split into one method per stage, each early stop thrown as `TaskRunEnd` and turned into the receipt in one place (~806 lines) |
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
| `TipTour/Voice/VoiceRouteProbe.swift` | DEBUG probes; voice-task uses the production session, JEV fan-out probe never executes actions, receipt-loss/journal-recovery/preflight probe dispatch, `--stable-voice-probe` dispatch (~365 lines) |
| `TipTour/Voice/DiagnosticPreflight.swift` | DEBUG-only read-only acceptance preflight: bundle/team identity, accessibility trust, frontmost identity, no prompts (~132 lines) |
| `TipTour/Voice/DesktopFaultRecoveryProbe.swift` | DEBUG-only one-shot receipt-loss fault plus receipt-loss and v1 journal-recovery acceptance probes (~724 lines) |
| `TipTour/Workflow/WorkflowModalPolicy.swift` | Distinguishes blocking modals from unrelated modeless windows (~11 lines) |
| `TipTourTests/DesktopTaskCoordinatorTests.swift` | Execution, cancellation, budget, escalation and continuation regressions, including the delivery-vs-outcome completion matrix (~1013 lines) |
| `TipTourTests/DesktopControlContractTests.swift` | Receipt, targeting, verification, response boundary, window identity and resume regressions (~648 lines) |
| `TipTourTests/WorkflowModalPolicyTests.swift` | Blocking-dialog and modeless-window rules (~15 lines) |
| `TipTourTests/NativeElementDetectorTests.swift` | Real OCR regression for Chinese and English control labels (~30 lines) |
| `TipTourTests/LocalPerceptionTargetCacheTests.swift` | Duplicate preservation, frame identity, window isolation and contradictory-label regressions (~130 lines) |
| `TipTour/UI/ProviderSetupView.swift` | The Keychain key cards (StepFun, JEV, MiniMax), the name and user-address fields, the persona.md row, the voice-style picker, the realtime voice picker and the MiniMax voice field |
| `TipTour/UI/CompanionPanelView.swift` | Menu bar panel shell: header with `ThinkingOrb` and live status, setup vs ready vs unusable-key routing, footer (~145 lines) |
| `TipTour/UI/Panel/PanelStyle.swift` | Panel material, system-adaptive colors, the pill-to-panel reveal and shared keycap/chip/button pieces (~250 lines) |
| `TipTour/UI/Panel/PanelOnboardingView.swift` | Two-step setup (key with portal link, first-use permissions) and the in-place key field (~195 lines) |
| `TipTour/UI/Panel/PanelReadyView.swift` | Ready panel: clickable shortcut keys, example phrases, live transcript, receipt, missing permissions (~200 lines) |
| `TipTour/UI/Panel/PanelPermissionRow.swift` | One permission: reason, request path, granted state (~110 lines) |
| `TipTour/UI/ThinkingOrb/ThinkingOrbView.swift` | System-layer presence orb and its voice-state mapping (idle breathing, connecting, listening, thinking, responding); ink set by surface, not system appearance (~85 lines) |
| `TipTour/UI/ThinkingOrb/ThinkingOrbEngine.swift` | Dotted-orb Canvas renderer; MIT thinking-orbs lineage, license beside it (~1010 lines) |
| `TipTour/Voice/VoiceConsistencyProbe.swift` | DEBUG `--voice-consistency-probe <voice> <dir> <turn.pcm>...` (several synthetic turns in one session, production persona or `-probePersonaFile`, each reply's audio saved) and `--vad-probe <out.json> <speech.pcm> <noise_dbfs> <tail_s>` (server-VAD start/stop timing against noise; threshold from `-stepfunVADEnergyThreshold`) (~200 lines) |
| `scripts/acceptance/voice_consistency_report.py` | Pitch/MFCC speaker-drift measurement between those replies; `--self-check` proves it flags a `say` speaker change |
| `scripts/acceptance/voice_style_comparison.py` | Same synthetic turns through both voice styles: `inputs` synthesizes them and prints the two probe commands, `page` writes a side-by-side listening page with waits and voice-change results |
| `scripts/acceptance/voice_latency_report.py` | Streams VoiceTask telemetry during a real-mic session and reports speech-stop→first-audio and estimated barge-in p50 |
| `TipTour/UI/TipTourSettingsView.swift` | Models, desktop actions, privacy (including silenced hand-off notices with 「恢复」), permissions and advanced options |
| `TipTour/UI/TipTourSettingsWindowManager.swift` | Settings and log windows, Chinese diagnostic log viewer; default pipeline events store only diagnostic IDs, statuses and counts (~653 lines) |
| `TipTourTests/PipelineLogIntegrationTests.swift` | Serialized default-log privacy regression without writing to the user's log files |
| `TipTour/Delegation/CodingAgentDelegation.swift` | Explicit Claude/Codex/Kimi/Step hand-off, current-project lookup, private worktree, concurrent process output, git receipt with a fingerprint of what was shown, and merge only while the workspace still matches it and the project is on its starting branch, or discard (~589 lines) |
| `TipTour/Delegation/DelegationAgentOutput.swift` | Normalizes four CLI JSONL formats, terminal outcome, summary and session ID; rejects nonzero exit and incomplete output (~131 lines) |
| `TipTourTests/CodingAgentDelegationTests.swift` | Real git outcomes with four CLI process stubs, failure/truncation, tool-error recovery, stderr and cancellation isolation (~548 lines) |
| `TipTour/Utilities/PersonaStore.swift` | persona.md: default identity, re-read on every use, length cap, unreadable file moved aside; the shared identity lines (her name, the user's address, persona) for voice and Ctrl+K |
| `TipTourTests/PersonaStoreTests.swift` | persona.md created when missing, edits read next time, empty and unreadable files never overwritten, length cap, names only when known |
| `TipTour/Delegation/DelegationConversation.swift` | Step Plan conversation (at most 12 messages to the model, only the latest draft in full, the last turns restored after a restart; hand-offs named by fixed six-character references), selected-tool context, recent hand-off records, rules for Her's own wording and for explaining failures, task draft, say-do guard that ignores recalled hand-offs and also catches pointers at draft buttons when no draft is showing, the referenced record number (`refers_to`) and the project choice (`project`: current / record / her), where Her's own code is, empty-answer error (~349 lines) |
| `TipTour/Delegation/DelegationConversationLog.swift` | Ctrl+K conversation on disk (`~/Library/Application Support/Her/ctrlk-conversation.jsonl`): one JSON line per entry, only appended; restored since the last 「重新开始」, newest 50, damaged lines skipped and the file never rewritten |
| `TipTour/Delegation/DelegationHistory.swift` | Hand-off records on disk (`~/Library/Application Support/Her/delegation-history.json`): user's words, draft, project, tool, worktree, result with raw failure and the receipt words Her showed, merge/discard; the exact background line a draft about a record starts with (numbered from the same five newest records), a one-line summary for a clicked notice, and the change still owed a decision rebuilt after a restart; the shown change summary, untracked files and fingerprint kept so a restored receipt matches; re-read before every write so hand edits survive; interrupted runs marked, unreadable file moved aside (~330 lines) |
| `TipTour/Delegation/DelegationNotices.swift` | What Her tells the user when a hand-off ends while they are away: category (changed / no change / failed; a stop is never announced), app-written title and body with why now (uncommitted new files are named, not called “no change”), the notification payload round trip, 「这类不再提醒」 rules in `~/Library/Application Support/Her/notice-rules.json` (re-read before each change, read-only when unreadable), and the idle-sleep assertion held while a tool runs (~216 lines) |
| `TipTour/Delegation/DelegationSession.swift` | Explicit project validation and conversation retention, project/tool-bound draft, isolated execution context, helper-file constraints, preparation, receipt, pending decisions, hand-off recording, recognizing Her's own source repository, Her's own reminder of the actually selected tool when a tool is requested or claimed, and the recorded background placed at the top of a draft about an earlier hand-off (kept apart from the model's draft, which is what gets recorded), and binding a draft to Her's own repository or the recalled hand-off's project when the project was only guessed from recent use hand-off notices when the user is away (quoting the request that produced the draft; never after 「停止」), a clicked notice explained from the record, the change still owed a decision restored at launch, keep-awake while a tool runs, a merge refused when the workspace changed or the branch moved, and a screen goal's end reported back to the conversation; binds a guessed draft to the repository the user named (~794 lines) |
| `TipTour/UI/DelegationPanelView.swift` | Stable conversation layout, native project folder picker, tool/model confirmation, fixed composer and receipts; a receipt that replaced one the user saw leads with what changed, the tool's summary is quoted under who wrote it and when, and the replaced receipt is dimmed (~583 lines) |
| `TipTourTests/DelegationSessionTests.swift` | Explicit project selection, failed-task retry retention, four-tool binding and promise correction, isolation prompt, preparation, pending decisions and hand-off records across restarts (including the receipt words shown) Her's own repository, recalled hand-offs not taken for promises, tool reminders, recorded backgrounds on drafts and their revisions, records without backgrounds, project binding (Her's own code, the recalled project, unknown Her code, the user's own choice) and empty model answers, with real Git readback hand-off notices (away, looking, silenced across restarts through the notification payload, stopped, quoting the request, redo, uncommitted files, notifications off, decision restored after restart and merged, clicked notice, hand-edited rules, keep-awake), merge refused after a change or branch move, untracked files named, restored receipts, hand-deleted records, screen goal results (~2057 lines) |
| `TipTour/UI/TextCommandPanelManager.swift` | Separate conversation/JEV geometry, native header drag region, hidden conversation frame restoration and screen bounds; JEV cursor following (~349 lines) |
| `TipTour/UI/TextCommandPanelView.swift` | JEV input, stop control and results |
| `TipTour/Utilities/KeychainStore.swift` | Device-local provider credential storage; existence vs in-process readability states, DEBUG-only acceptance denial seam (~540 lines) |

See `docs/source-layout.md` for the remaining directory responsibilities.

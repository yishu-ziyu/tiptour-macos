# Experimental task continuity

Part of the [architecture overview](README.md). Moved verbatim from `AGENTS.md` on 2026-09-23.

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

The signed DEBUG binary (`Her.app/Contents/MacOS/Her`) accepts
`--voice-continuity-probe <progress.pcm> <cancel.pcm> <report.json>`.
Inputs are public synthetic PCM16 / 24 kHz mono. It tests two provider sessions with the
production session/router but an in-memory executor, and never opens the microphone,
plays sound, starts monitors, drives the desktop or loads the real task journal. Keychain
access remains non-interactive and fails without a credential fallback; the report includes
only the OS failure code/message, not a key. See the current task document for evidence.

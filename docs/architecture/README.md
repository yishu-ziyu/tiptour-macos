# Architecture overview

Her is a macOS 14.2+ menu bar app (`LSUIElement=true`, bundle ID `com.yishuziyu.her`). The Swift module, folders and many type names still use the historical `TipTour` namespace.

## Ownership decision (2026-09-26)

Her owns shared context, authorization, task state and user-facing receipts; execution paths remain separate. The user confirmed this boundary while reviewing the whole product architecture. It supersedes the former blanket claim that every entry must run through the desktop engine.

- Desktop input reuses the existing engine, workflow runner, permissions, pauses and action verification.
- External Coding Agents use the existing delegation executor, isolated worktree, explicit send/merge decisions and independent repository readback. They do not become a second conversational coordinator inside Her.
- Conversation, remembered information, task execution and notification are distinct responsibilities. Reading a message, hiding a panel or stopping speech is not task completion or cancellation.
- Shared ownership is the direction, not a claim that all current owners have already been merged. Do not replace the execution systems just to make the diagram uniform.

## Current implementation

```text
CompanionManager
  voice → StepFunRealtimeSession → tool router
          → DesktopTaskCoordinator → DesktopTaskExecutor ─┐
  text  → DelegationSession / DelegationConversation      │
          ├─ screen goal → JEV PointerLoop ───────────────┤
          └─ confirmed draft → CodingAgentDelegation     │
                  → Claude / Codex / Kimi / Step CLI / worktree / git receipt
  harness → legacy LongTaskCoordinator ──────────────────┤
                                                        ▼
                TipTourEngine → WorkflowRunner → ActionExecutor / ActionDriver
                perception: AX → browser DOM/CDP → OCR/CoreML → screenshot
```

| Responsibility | Current state | Gap before claiming one continuous companion |
| --- | --- | --- |
| Voice and text conversation | Separate provider sessions and histories | No shared conversation/context handoff across the two entries |
| Task ownership | Voice coordinator, JEV task/loop, legacy harness owner and Coding Agent delegation coexist | Shared user-visible task identity and control are not yet implemented across paths |
| Results | Desktop step verification and delegation git receipts exist | Each task type keeps its own evidence rules; a global success claim cannot be inferred from a model or diff alone |
| Return after hiding | Text session and pending result remain while the app runs; each delegation hand-off (words, draft, project, tool, worktree, result, decision) is recorded on disk and the newest five are given to the conversation, so a restart does not erase what was handed off; a change still waiting for merge or discard comes back after a restart with its buttons, and a hand-off that ends while the user is away is announced by one notification | The conversation itself is not restored after restart, and a run cut off by quitting is only marked interrupted (its worktree is not offered back); the hand-off record is not general memory and has no view/edit/delete UI; voice continuity journal is opt-in recovery metadata, not long-term memory |
| Project context and sources | Recent Claude session suggests a project; the draft can explicitly select a validated Git root, with branch/recent commits | No production case-library, browsing-history or cross-session recall reader |
| Proactivity | Window/input monitoring supports current perception | No production follow-up/discovery inbox or quiet-notification flow; current UX is a simulation |

The next integration should introduce a clear owner for the facts needed by one real task, expose its existing receipt through the native UI, and then generalize only from demonstrated needs. Long-term memory and proactive discovery remain distinct product responsibilities, not implicit side effects of an execution log.

The [2026-09-26 coordination research](../research/2026-09-26-coordination-architecture.md) records supporting examples and counterexamples. Its proposed mechanisms are not a claim of implemented behavior or approval to port another runtime.

| Topic | Read |
| --- | --- |
| What each provider mode does, onboarding, voice defaults | [provider-modes.md](provider-modes.md) |
| Engine, grounding order, perception cache, open_app, describe_screen, telemetry, harness | [runtime.md](runtime.md) |
| When a step counts as done (the only completion authority) | [step-completion.md](step-completion.md) |
| Off-by-default task continuity path (`--voice-task-continuity`) | [task-continuity.md](task-continuity.md) |
| Key source files and their purpose | [key-files.md](key-files.md) |
| Directory responsibilities | [../source-layout.md](../source-layout.md) |
| Localhost harness contract | [../tiptour-agent-contract.md](../tiptour-agent-contract.md) |

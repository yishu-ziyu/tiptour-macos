# Architecture overview

Her is a macOS 14.2+ menu bar app (`LSUIElement=true`, bundle ID `com.yishuziyu.her`). The Swift module, folders and many type names still use the historical `TipTour` namespace.

```
user voice (Ctrl+Option) / text (Ctrl+K)
        │
CompanionManager ── provider sessions: StepFun realtime voice (default) · JEV text
        │
StepFun tool router → DesktopTaskCoordinator → DesktopTaskExecutor
        │                      (task identity, progress, uncertainty, receipts)
TipTourEngine → WorkflowRunner → ActionExecutor / TipTourActionDriver (CUA input)
        │
perception: AX → browser DOM/CDP → local CoreML/OCR → screenshot coordinates
```

One brain: every entry goes through the same engine, runner and executor. Nothing bypasses those boundaries.

| Topic | Read |
| --- | --- |
| What each provider mode does, onboarding, voice defaults | [provider-modes.md](provider-modes.md) |
| Engine, grounding order, perception cache, open_app, describe_screen, telemetry, harness | [runtime.md](runtime.md) |
| When a step counts as done (the only completion authority) | [step-completion.md](step-completion.md) |
| Off-by-default task continuity path (`--voice-task-continuity`) | [task-continuity.md](task-continuity.md) |
| Key source files and their purpose | [key-files.md](key-files.md) |
| Directory responsibilities | [../source-layout.md](../source-layout.md) |
| Localhost harness contract | [../tiptour-agent-contract.md](../tiptour-agent-contract.md) |

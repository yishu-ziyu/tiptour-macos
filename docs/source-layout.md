# Source layout

| Directory | Responsibility |
| --- | --- |
| `TipTour/App` | Lifecycle, hotkeys, shared state, and mode coordination |
| `TipTour/Voice` | StepFun Realtime WebSocket, microphone, audio playback, voice sessions |
| `TipTour/Jev` | TypeSafe client, validated target decisions, bounded click loop, results view |
| `TipTour/Core` | Shared engine, action requests, highlight source resolution, harness contract |
| `TipTour/Actions` | Desktop input facade and CUA driver |
| `TipTour/Workflow` | Action schema, local grounding, execution, pause and validation rules |
| `TipTour/Perception` | AX, browser geometry, CoreML/OCR, screenshots, target cache |
| `TipTour/Harnesses` | Localhost HTTP access to the engine |
| `TipTour/Skills` | Portable markdown app guidance and small runtime hints |
| `TipTour/UI` | Menu bar, Settings, command panel, pointer and detection overlays; `UI/Panel` holds the menu bar panel's pieces |
| `TipTour/Utilities` | Permissions, Keychain, preferences, shortcuts, logging and analytics |

JEV and StepFun use the same action engine. Keep provider networking in their respective directories, execution in the action/workflow layer, and app-specific quirks in markdown skills. Neither UI nor providers should bypass the engine's action permissions or pauses.

The StepFun task contract and coordinator in `Voice` own explicit task steps and per-turn receipts.
`DesktopTaskExecutor` adapts that contract to the existing engine; it is not another input driver.
`DesktopActionVerifier` contains pure result checks. `Perception/DesktopAccessibilityReader` supplies
bounded AX evidence, merged into the existing local target cache alongside the captured image.
`StepFunResponseBoundary` and the session keep cancelled responses, extra tool calls and pre-tool
success prose from reaching execution or playback. `VoiceRouteProbe` exercises that production
session with synthetic input; general test orchestration remains in `tools/voice-acceptance`.

The app has no recording, image-generation, hosted-key proxy, Claude planner, or Hermes integration. General documentation stays outside the bundled `TipTour` directory.

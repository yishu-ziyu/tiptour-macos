# Source layout

| Directory | Responsibility |
| --- | --- |
| `TipTour/App` | Lifecycle, hotkeys, shared state, and mode coordination |
| `TipTour/Voice` | Gemini Live WebSocket (retiring), StepFun Realtime WebSocket, microphone, audio playback, voice sessions |
| `TipTour/Jev` | TypeSafe client, validated target decisions, bounded click loop, results view |
| `TipTour/Core` | Shared engine, action requests, highlight source resolution, harness contract |
| `TipTour/Actions` | Desktop input facade and CUA driver |
| `TipTour/Workflow` | Action schema, local grounding, execution, pause and validation rules |
| `TipTour/Perception` | AX, browser geometry, CoreML/OCR, screenshots, target cache |
| `TipTour/Harnesses` | Localhost HTTP access to the engine |
| `TipTour/Skills` | Portable markdown app guidance and small runtime hints |
| `TipTour/UI` | Menu bar, Settings, command panel, pointer and detection overlays |
| `TipTour/Utilities` | Permissions, Keychain, preferences, shortcuts, logging and analytics |

Gemini and JEV use the same action engine. Keep provider networking in their respective directories, execution in the action/workflow layer, and app-specific quirks in markdown skills. Neither UI nor providers should bypass the engine's action permissions or pauses.

The app has no recording, image-generation, hosted-key proxy, Claude planner, or Hermes integration. General documentation stays outside the bundled `TipTour` directory.

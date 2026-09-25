# Local harness

TipTour listens only on `127.0.0.1:19474`. This developer interface shares the same grounding, action permissions, and workflow validation as Gemini and JEV. No external orchestrator is bundled.
Requests must use a loopback `Host` header. Browser requests with an `Origin` header are accepted only when that origin matches the harness itself; other origins receive HTTP 403 before an endpoint runs. Local command-line clients using `127.0.0.1:19474` need no new credential. This does not authenticate other processes on the same Mac.
Requests over 1 MiB receive HTTP 413 before an endpoint runs.

Fetch `GET /v1/agent-contract` for the current machine-readable contract and `GET /v1/capabilities` for supported operations.

1. Read `GET /v1/observe` to check app state and toggles.
2. Use `POST /v1/visual-context` with `visual_context: "auto"` for screen context, or `POST /v1/resolve-highlight-source` for the user's highlight.
3. Ground a visible target with `POST /v1/ground-target`, then pass its exact target ID/mark to `POST /v1/act`.
4. Wait for the action result and inspect `GET /v1/action-history` when needed.
5. Refresh context before deciding another action. A failed exact ID must not fall back to an arbitrary nearby label.

Preserve one `trace_id` across a task. `POST /v1/workflow-plan` accepts one action; `/v1/tasks` is for concrete deterministic sequences, not open-ended model planning. `/v1/targets` and `/v1/screenshots` are debug endpoints.

Desktop actions require both CUA access and Autopilot. Remote screenshots obey the screenshot privacy toggle. Local grounding uses AX/browser geometry and local detection; it no longer invokes a separate semantic matching model. The image-edit endpoint has been removed.

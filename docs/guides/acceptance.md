# Acceptance infrastructure

Part of the [documentation index](../README.md). Moved verbatim from `AGENTS.md` on 2026-09-23.

Real-user-path acceptance runs from `scripts/acceptance/`:

- `her_voice_e2e.py` is the one-command runner: identity/freshness gate → machine preflight → controlled fixture (`tools/voice-acceptance/fixture.py`, :19475) or controlled desktop host app (`tools/cua-host`, :19476) → signed DEBUG Her launched via LaunchServices (`-n`, a new instance, never the user's running Her) → synthetic-PCM voice probes → real provider and executor → independent `/state` readback → six-layer evidence (`out/acceptance/<id>/result.json`: user words, model tool arguments, task/turn/attempt IDs, Her receipt, independent state, final speech, failure-recovery). Exit codes: 0 pass, 1 any non-pass, 3 preflight/precondition BLOCKED, 4 another run active (cross-process mutex), 130 SIGINT — every termination path writes the aggregate report.
- `runner/machine_preflight.py` is read-only machine verification (ports, user Her process record, binary freshness, frontmost identity via ASN resolution, screen-lock state); unproven states fail closed.
- `verify_evidence.py` is the independent reviewer: it re-derives PASS/FAIL from the evidence package and never trusts the product's own `passed` field. Accepted terminal contracts: `completed` with per-action corroboration, honest `uncertain_effect` with uncertainty speech, and `cancelled` with valid control binding and no unexplained side effects.
- `manual_runner.py` drives human-in-the-loop steps (for example save → deny-read → restore in Settings): it prints instructions, waits for the human, and independently verifies each claim (keychain presence via `security` exit code, `/state`, process records). It never clicks UI itself.
- `runner/conversation_driver.py` defines the multi-turn conversation script schema (turns with `wait_ms` / `barge_in` / `expect`); the in-app probe for 3+ turns and barge-in is rebuild-gated.
- `runner/provider_shapes.py` records real tool-argument shapes per run as a contract-drift monitor; replays under `cassettes/` are labeled `acceptance: false` and can never stand in for E2E.
- `runner/runner_faults.py` holds runner-side fault primitives (owned-fixture kill, stale-state window); arming requires a named `authorized_by`, and page-navigation faults never run automatically.
- **Not in this repository (checked 2026-09-23):** AXProbe (planned at tools/ax-probe) was never committed on any branch, although this list and `docs/development/2026-09-23-acceptance-infrastructure.md` describe it. Treat the rest of this bullet as a plan until it is committed. Planned behavior: AXProbe snapshots and, only with a user-created grant token, types into another app's UI; snapshot mode fails cleanly when the controlling process lacks Accessibility. No mode activates or focuses any app.

Desktop acceptance requires the fixture or host app to be foreground, so it only runs inside a window the user explicitly grants. Background-safe work (builds, self-tests, dry-runs, cassette replays, isolated suites, evidence review) never touches the desktop.

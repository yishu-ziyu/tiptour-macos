# Her E2E acceptance runner (work order 03)

One command runs the complete Her real-path acceptance from an idle environment
and writes a verifiable evidence package. It changes no product behavior and no
product code.

```bash
python3 scripts/acceptance/her_voice_e2e.py \
  --app "/path/to/Debug/Her.app" \
  --out out/acceptance/03-her-e2e-runner
```

`--app` defaults to this machine's Xcode DerivedData Debug product. The runner
**never builds, installs, replaces, or kills anything**: it inspects the app
bundle, spawns the app's own DEBUG probe entrypoints as separate short-lived
children that exit by themselves, and stops only its own children.

## Modes

| Mode | Command | What it proves |
| --- | --- | --- |
| Full acceptance | (default command above) | The real path: signed DEBUG Her.app → real StepFun → real executor → local controlled page → independent `/state` → Her receipt and speech → post-failure dedup/recovery evidence. |
| Dry-run | add `--dry-run` | The runner pipeline with a runner-level mock executor. Clearly labeled `"mode": "dry_run"`, `"proof": false`, every attempt `"mock": true`. **Never shipped as proof.** |
| Self-test | add `--self-test` | 19 runner-level tests: fixture behavior, probe argument plumbing and execution, evidence schema, every scenario judge, dry-run consistency, child-process discipline, secret hygiene. No app involvement. |
| Failure-injection drill | `--dry-run --dry-run-failure-injection` | Replays deliberately bad evidence chains so you can watch the judges refuse PASS and the run exit non-zero. |

## What the full run does, in order

1. **Preflight (app identity)** — `Her.app`, bundle id `com.yishuziyu.her`,
   executable `Her`, Team ID `87DM76C54G`, `codesign --verify` passes. Any
   mismatch is BLOCKED before evidence is gathered.
2. **Freshness gate** — the app binary must not be older than any product
   source under `TipTour/**`. An older binary is BLOCKED with the offending
   source list: an old process must never be used to "verify" newer code.
3. **Keychain presence** — `security find-generic-password -s
   com.yishuziyu.her -a stepfunAPIKey` (and `jevAPIKey`) records presence and
   the OS status code only. stdout is discarded: secrets are never read,
   printed or stored, and no prompt is opened.
4. **Process audit** — any already-running user Her is recorded (pid, command),
   never killed.
5. **Fixture** — starts `tools/voice-acceptance/fixture.py` itself, waits for
   `/state`, verifies the disposable controlled page, `POST /reset`, asserts a
   clean `/state`. An occupied port 19475 is an environment error (BLOCKED):
   the runner never kills unrelated processes.
6. **Browser staging** — opens `http://127.0.0.1:19475` in Safari through
   LaunchServices (never AppleScript, which would raise the automation banner
   that intercepts real mouse events) and waits for the fixture's `page_views`
   counter to prove the browser really loaded the page.
7. **Scenarios** — for each scenario: synthesize the synthetic utterance with
   system `say`+`afconvert` to headerless 24 kHz mono PCM16 (metadata only in
   evidence, never samples), reset the fixture, reload the page, snapshot
   `/state`, run the documented app probe, snapshot `/state` again, then judge.
8. **Cleanup** — stops its own probe children and its fixture, verifies the
   port is free, verifies no owned process remains, and records rerun hygiene.
9. **Evidence package** — `result.json`, `app-identity.json`, `commands.txt`,
   `README.md` plus `scenario-artifacts/` with the probe reports and logs the
   verdicts were derived from. Written files are scanned for secret-shaped
   content; a hit is reported, never hidden.

## Scenarios

Scenario definitions live in `tools/voice-acceptance/scenarios/*.json` next to
the fixture they drive. Run order and meanings:

| Scenario | Probe | Meaning |
| --- | --- | --- |
| `single_step_right_setting` | `--voice-task-probe` | One-step spatial click: "点击右边的设置按钮" must be a `click` constrained to `region=right` — never `open_app`, never `right_click`, never the left-hand twin. |
| `two_step_display_settings_scale` | `--voice-task-probe` | Two-step page-control sequence: "点击打开显示设置，然后点击缩放选项" must be two explicit `click` steps, never `open_app` of a fictional "显示设置" application. |
| `continuity_progress_cancel` | `--voice-continuity-probe` | Progress question, then cancel after reconnect: same task id survives, fresh turn binding, zero repeated desktop actions, final `cancelled`. |
| `unknown_delivery_fault_recovery` | work order 04's probe | Real delivery-unknown fault injection and recovery. The probe does not exist in this binary yet, so the scenario is `pending_integrator_run` with the reproduction command until 04 merges. |

Repeat a scenario with `--repeat-scenario NAME=N` (work order 01 asks for three
consecutive two-step passes: `--repeat-scenario
two_step_display_settings_scale=3`).

## Evidence doctrine

A scenario PASSes only when all six layers agree. The runner refuses to derive
PASS from any single one of them:

1. **User's words** — the scenario utterance plus the probe's real input
   transcript.
2. **Model tool arguments** — the raw JSON the model emitted (recorded
   verbatim, including any wrong `open_app`).
3. **Her receipt** — the production receipt JSON (`task_id`, `turn_id`,
   `target_version`, per-action `delivery`, `outcome_evidence`,
   `completion_policy`, `completion_basis`, attempt/observation ids).
4. **Independent `/state`** — the fixture's own readback before and after:
   exact selected value, click delta, ordered events, forbidden side effects.
5. **Final speech** — the rendered texts captured from the Realtime session;
   an `uncertain_effect` receipt must be spoken as uncertainty, and a
   `completed` receipt must be corroborated by layer 4.
6. **Process exit and cleanup** — the probe self-exited with code 0, the
   fixture stopped, the port is free, nothing of the runner's is left running.

Never sufficient on their own: exit code 0, a `completed` tool return, model
prose, or any page change.

## Exit codes and result.json

- `0` — every scenario passed (only possible once work order 04 has merged and
  the integration branch has been rebuilt).
- `1` — a scenario failed, a scenario is pending-integrator-run, preflight
  BLOCKED, or a self-test failed. `result.json` always records which, with
  per-scenario reasons. Self-test failures are runner bugs: fix them before
  producing evidence.

`result.json` carries `commit`, `branch`, `app_bundle`, `bundle_id`,
`team_id`, `entrypoint`, `provider_connection_attempted`, `synthetic_audio`,
`microphone_opened` (always false), `desktop_fixture_only` (always true),
`mode`, `proof`, and one entry per scenario with its six-layer evidence,
basis strings and failure reasons.

## Hard rules the runner upholds

- Never runs `xcodebuild`; never installs or replaces the app.
- Never kills the user's Her; probe processes are separate children that exit
  by themselves, and only registry-tracked children are ever signalled.
- Never opens the microphone, never plays audio, never exports keys.
- Real desktop actions only ever target `http://127.0.0.1:19475`; no real user
  pages, private data, legacy keys or screenshots are fixtures.
- No second coordinator/TTS/provider is introduced; the app's own documented
  probes are the only entrypoints.

## Integrator: final rerun after 01/02/04 merge

```bash
# 1. merge 01 → 02 → 04 (merge order from the plan README; 03 is documentation
#    of this runner and carries no product code)
# 2. rebuild the DEBUG app in Xcode from the integration branch
# 3. rerun the exact same command:
python3 scripts/acceptance/her_voice_e2e.py \
  --app "/path/to/Debug/Her.app" \
  --out out/acceptance/03-her-e2e-runner
```

No runner edits are required. If work order 04's probe takes different
arguments than the placeholder template in
`tools/voice-acceptance/scenarios/unknown-delivery-fault-recovery.json`, update
that one `argv_template` (or pass `--unknown-probe-argv '<JSON>'`) and rerun.

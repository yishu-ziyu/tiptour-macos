# Provider cassettes — labeled contract regression, never acceptance evidence

Paths in backticks are relative to `scripts/acceptance/cassettes/` unless they start with a top-level directory. Moved from `scripts/acceptance/cassettes/README.md` on 2026-09-23; that file now only points here. Index: [docs/README.md](../README.md).

This directory holds **cassettes**: recordings of real provider tool
arguments (as they appeared in a run's probe report) plus the verdict the
production scenario judges are expected to return for them. Cassettes exist to
answer one question after every provider-shape change: *do the production
judges still answer the same question the same way for a known argument
shape?*

A cassette replay is **contract regression only**. It is not E2E acceptance
evidence and must never be shipped as such. The anti-impersonation guarantee
is structural: `scripts/acceptance/runner/provider_shapes.py` writes the
stamp `"acceptance": false, "purpose": "contract-regression"` into the header
of every `<cassette>.replay.json` it produces — the stamp comes from the
replay tool, not from the cassette author, so no cassette can label itself
acceptance. No app is launched, no provider is called, no desktop is touched
by a replay.

## Why the monitor exists

The real StepFun tool-argument shape drifts. Work order 01R's rework started
from exactly such a drift: the model returned the click both as a top-level
`action` and inside a `steps` array. `record_shapes(run_dir)` profiles the
`realtime.json` probe reports a real run already left on disk and surfaces
that class of drift early:

- **mixed top-level `action` + `steps`** — the redundant action+steps shape,
- **steps-count distribution** — how many steps each act_on_screen call carries,
- **result-phrase labels** — label slots narrating an outcome instead of naming
  an observable control ("已打开 / 页面已 / 完成"-style unobservable wording),
- **missing required contract fields** (e.g. `goal`, a click without
  `target_label`),
- **conflicting redundancy** — top level and steps disagreeing about action or
  region, or duplicated steps,
- **unparsable arguments** — calls whose arguments are not a JSON object.

The monitor reports; it never judges and never blocks. Verdict ownership stays
with `scenario_judges.py`.

## Cassette format

```jsonc
{
  "cassette_format": 1,
  "scenario": "<scenario name from tools/voice-acceptance/scenarios>",
  "title": "<what this cassette pins down>",
  "recorded_from": "<provenance: which run/shape this was recorded from>",
  "note": "<why it matters>",
  "probe_record": { "exit_record": { "…derived, no process ran…" } },
  "report": {                       // the probe report shape: calls + tool_results + rendered_texts
    "calls": [{"name": "act_on_screen", "arguments": "<raw JSON string, verbatim>"}],
    "tool_results": ["<receipt JSON string>"],
    "rendered_texts": ["…"]
  },
  "state_before": { },              // independent /state before
  "state_after": { },               // independent /state after
  "expect": {
    "verdict": "passed | failed",
    "basis_contains": "<optional string the PASS basis must carry>",
    "failure_contains": "<optional string the FAIL reasons must carry>"
  }
}
```

`report.calls[*].arguments` stays the **raw JSON string** exactly as the
provider produced it — a cassette that pre-parses the arguments cannot detect
a shape drift. Optional `probe_record` may be omitted; the replay tool then
uses a record whose derived `returncode_basis` states plainly that no process
ran.

## Recording a cassette from a real run

1. Copy the raw `calls` (and the matching `tool_results`, `rendered_texts`,
   and the before/after `/state` snapshots) from the run's
   `scenario-artifacts/<scenario>/run-N/realtime.json` — verbatim, no edits.
2. Decide the expected verdict from the run's `attempt-evidence.json`
   (`verdict.status`), and cite in `expect.why` which evidence layer pins it.
3. Name the file after the shape it pins
   (e.g. `example-action-plus-steps.json`).
4. Replay it once (below) and keep the matching `<cassette>.replay.json` out
   of git if it is only a local check; commit cassettes, not replays.

## Replaying

```bash
# one cassette, writes <cassette>.replay.json next to it
python3 scripts/acceptance/runner/provider_shapes.py replay \
    scripts/acceptance/cassettes/example-action-plus-steps.json

# or from the runner directory
python3 scripts/acceptance/runner/provider_shapes.py record \
    out/acceptance/<run-dir>          # profile a real run's tool-argument shapes
```

A replay exits non-zero when the judge's verdict no longer matches the
cassette's expectation: that mismatch is the contract regression.

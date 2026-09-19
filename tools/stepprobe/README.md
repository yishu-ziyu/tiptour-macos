# stepprobe

Standalone investigation harness for the providers TipTour uses after the Gemini
path is removed. It answers with measurements instead of opinions.

It deliberately lives outside the Xcode project: it must be runnable with
`swift run` **without building, signing, or launching TipTour**, because
replacing the installed app bundle invalidates its macOS Accessibility / Screen
Recording grants.

## Credentials

Read from the repository root `.env` (see `.env.example`). Never commit it.

```bash
cp .env.example .env   # then fill in STEPFUN_API_KEY / TYPESAFE_API_KEY
```

The app itself does not read this file — it keeps keys in the Keychain through
its own setup UI.

## Commands

### `models` — which models the account can actually reach

```bash
swift run --package-path tools/stepprobe stepprobe models
swift run --package-path tools/stepprobe stepprobe models --image /tmp/shot.png
```

With `--image` it also reports image-input support, which is the property the
"eye" role depends on. A model can answer text and still reject images.

Why this exists: documentation and account entitlement disagree in both
directions. `step-5-preview` answers but is absent from the docs; `step-3.5-preview`
is in the docs but 404s for this account. Probe, don't trust.

### `vision` — can a vision model be trusted with click coordinates?

```bash
python3 tools/stepprobe/scripts/make-vision-fixture.py
# then run the printed command, or:
swift run --package-path tools/stepprobe stepprobe vision \
  --image /tmp/stepprobe-fixture.png \
  --truth A=300,180,390,270 --truth B=2100,1500,2240,1640 --truth C=2900,300,2960,360
```

Reports latency, token usage, `finish_reason`, the raw answer, and the
centre-point error in pixels against ground truth.

Options: `--model`, `--effort low|medium|high`, `--no-json`, `--max-tokens`,
`--prompt`.

Two failure modes this command exists to catch — see
`docs/model-research-findings.md` §4 and §5:

- `finish_reason=length` with an **empty answer**, because reasoning content is
  billed against `max_tokens`. Always pass a generous `--max-tokens`.
- Coordinates that do not track the input resolution. Pixel-level grounding from
  these models is not reliable, which is why the product asks the vision model to
  *pick among locally detected candidate regions* rather than to emit coordinates.

### `jev` — is the hand reliable in Chinese?

```bash
swift run --package-path tools/stepprobe stepprobe jev --lang zh
swift run --package-path tools/stepprobe stepprobe jev --lang en
```

Asks the same "open a new tab" question against a six-item menu rendered in
Chinese or English, and prints latency, token usage, and the full probability
distribution. A concentrated distribution means the language is safe for that
workload; a flat one means confidence routing or a vision fallback is required.

TypeSafe documents English as the primary language with lower CJK accuracy, and
TipTour's screens are full of Chinese control labels — so this comparison is the
gate for shipping Jev without a fallback.

Options: `--lang zh|en`, `--candidates N`, `--model` (defaults to the pinned
`jev-1.13.0`, not the drifting `jev-latest` alias).

## Interpreting the output

`probabilities` shape is the signal, not just the winning `choice`. A
concentrated distribution is an act; a flat one is an honest "I don't know" —
and "I don't know" must route to a human, a clarification, or a fallback, never
to a click.

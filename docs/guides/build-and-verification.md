# Build and verification

Part of the [documentation index](../README.md). Moved verbatim from `AGENTS.md` on 2026-09-23.

`tools/voice-acceptance/fixture.py` serves disposable controls on `127.0.0.1:19475` with
independent `/state` readback. DEBUG-only probe launch arguments are documented in
`tools/voice-acceptance/README.md`; they never export keys or open the microphone.
The signed DEBUG binary they accept is `Her.app/Contents/MacOS/Her`
(bundle ID `com.yishuziyu.her`, Personal Team `87DM76C54G`).
Real desktop probes still require exclusive access to the target window.

Run `bash scripts/test-local-perception.sh` for the real OCR regression on Simplified Chinese,
Traditional Chinese and English controls, plus cross-source duplicate detection and blocking-modal tests. It uses a generated image and an isolated package,
without launching or replacing the app.

Open `tiptour-macos.xcodeproj`, select the `tiptour-macos` scheme, build/run in Xcode.
Run `scripts/test-stepfun.sh` and `scripts/test-jev.sh` for the decision suites, which compile
into temporary packages and never touch the installed app. Her uses the local Personal Team signing identity; see `docs/local-development.md` for signing, bundle identifier, Sparkle feed and remote conventions used here.

Run `scripts/test-stepfun-voice-lifecycle.sh` for isolated voice turn-lifecycle, task coordination, audio playback and vision-client tests; it compiles real sources without launching the app or opening the microphone. Vision requests use a local URLProtocol fixture.

The StepFun scripts accept Swift test filters, e.g. `bash scripts/test-stepfun-voice-lifecycle.sh --filter DesktopControlContractTests`.
`python3 scripts/typecheck-local-app.py --derived-data <existing-checkout-DerivedData>` type-checks against an existing Xcode dependency build without linking, signing, installing or launching. It does not replace Xcode build or runtime acceptance.

Every command in this section is a regression or seam check. None of them is a completion criterion: `XCTest` / `Swift Testing` results, exit codes and typechecks never stand in for the E2E gate described in Testing Rules.

The current control contract and evidence are in `docs/development/2026-09-21-trustworthy-desktop-control.md`.
Read the evidence status before enabling automated real-app trials or changing the default entrypoint.

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC permissions and the app will need to re-request screen recording/accessibility access. Pure Swift parsing/typechecking and isolated tests are permitted without replacing or launching the installed app. Run `scripts/test-jev.sh` and `scripts/test-stepfun.sh` for the two decision suites.

Known non-blocking Swift 6 concurrency and deprecated `onChange` warnings must not be fixed as incidental cleanup.

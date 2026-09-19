# Local development setup (fork)

This fork is configured to build and run locally on the machine it was cloned
onto. These settings are machine-specific on purpose — do not carry them back
into an upstream pull request.

## Signing

| Setting | Value | Why |
| --- | --- | --- |
| `CODE_SIGN_STYLE` | `Manual` | The upstream project uses Automatic signing with the upstream authors' Apple teams (`993D98NH4J`, `6D7X9GGZAW`), which this machine has no account for. |
| `CODE_SIGN_IDENTITY` | `Shangqiuko Local Code Signing` | A machine-local code signing certificate, valid until 2036. |
| `DEVELOPMENT_TEAM` | `""` | No paid Apple Developer account on this machine. |

Why a persistent certificate instead of ad-hoc signing: macOS grants
Accessibility / Screen Recording / Microphone permission to a *code signature*.
An ad-hoc signature (`-`) is regenerated on every build, so macOS would
re-ask for every permission after every rebuild. Signing with the same local
certificate keeps the designated requirement stable, so permissions survive
rebuilds.

If the certificate is ever removed from the keychain, `security find-identity -v -p codesigning`
will no longer list it. Either re-create a local code signing certificate
(Keychain Access → Certificate Assistant → Code Signing Certificate) and update
`CODE_SIGN_IDENTITY`, or accept ad-hoc signing and the repeated permission
prompts.

## Bundle identifiers

`com.milindsoni.tiptour` → `com.yishuziyu.tiptour` (plus `.tests` / `.uitests`).
Separate identifiers keep this fork's Keychain entries (provider API keys) and
its macOS permission grants independent from any copy of the original app that
might be installed side by side.

## Auto-update

`INFOPLIST_KEY_SUFeedURL` is deliberately empty, which disables Sparkle. The
upstream feed points at `milind-soni/tiptour-releases`; if it stayed enabled, a
locally developed build could be silently replaced by an official release.
`TipTourApp` already skips the updater when `SUFeedURL` or `SUPublicEDKey` is
absent.

## Build

Open `tiptour-macos.xcodeproj` in Xcode and run the `tiptour-macos`
scheme (the README calls it `TipTour`, which is wrong). Swift package
dependencies are pinned in
`tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
and are already resolved in `~/Library/Developer/Xcode/DerivedData/tiptour-macos-*`.

**Do not build or archive from the terminal once the app has been run locally**: it
replaces the signed bundle and macOS will re-request every permission. Use
`scripts/test-jev.sh` for isolated JEV decision tests, which compiles only the
`JevCore` sources into a temporary SwiftPM package.

### Signing settings that matter

| Setting | Value |
| --- | --- |
| `CODE_SIGN_STYLE` | `Manual` |
| `CODE_SIGN_IDENTITY` | `Shangqiuko Local Code Signing` |
| `ENABLE_HARDENED_RUNTIME` | `NO` |
| `DEVELOPMENT_TEAM` | key removed |
| `ENABLE_DEBUG_DYLIB` | `NO` |
| `ENABLE_PREVIEWS` | `NO` |

**This configuration makes macOS permissions survive a rebuild.** That is the whole
point of it: without it, every build resets Accessibility, Screen Recording and
Microphone, and re-granting by hand after each build is the single biggest tax on
iterating.

Why it works: the designated requirement is
`identifier "com.yishuziyu.tiptour" and certificate leaf = H"<cert hash>"` — it names
the *certificate*, not the binary. Verified by changing the source and rebuilding:
the binary's SHA-1 changed while the designated requirement stayed byte-identical.
TCC therefore treats every build as the same app.

Four rules, each learned from a build or launch that failed:

- **`ENABLE_HARDENED_RUNTIME` must be `NO`.** This is what actually fixed launching.
  Hardened runtime enforces team matching for every loaded library, and a self-signed
  certificate has no Team ID to match on, so dyld refuses with
  `mapping process and mapped file (non-platform) have different Team IDs` for every
  embedded framework. The certificate itself is fine — it carries Digital Signature
  plus the Code Signing EKU, and `codesign` accepts it without complaint. The
  certificate was blamed for this for several rounds before the runtime flag was
  identified as the real cause. Ad-hoc signing is the other way to make the app
  launch, but it costs the stable-requirement property above.
- **Remove `DEVELOPMENT_TEAM`; do not set it to an empty string.** An explicitly
  empty team makes Xcode demand a team for every target that inherits it,
  including the SPM package products (`PostHog`, `PLCrashReporter`), which then
  fail with "Signing requires a development team".
- **`ENABLE_DEBUG_DYLIB` must be `NO`.** Its default emits a `TipTour.debug.dylib`
  beside the executable — a SwiftUI Previews JIT artefact a menu-bar app has no
  use for — and the product then refuses to launch with the same Team ID error.
  `ENABLE_PREVIEWS = NO` does *not* remove it; the two settings are independent.
- **Do not pass `CODE_SIGN_IDENTITY` on the `xcodebuild` command line.** It
  overrides the setting for every target, packages included, and reproduces the
  "requires a development team" failure. The project file already targets the
  right configs on its own.

### Terminal builds

Terminal `xcodebuild` is what the repository's `AGENTS.md` prohibits, because it
invalidates grants the installed app already holds. That prohibition only bites
once permissions have been granted — before then there is nothing to lose, which
is why the fork's configuration was validated from the terminal at all.

Once the app has been run and granted Accessibility / Screen Recording /
Microphone, all further builds belong in Xcode. Everything else keeps working
from the terminal: source edits, `scripts/test-stepfun.sh`, `scripts/test-jev.sh`
and the `tools/stepprobe` harness all compile into temporary directories and
never touch an installed bundle.

## Repository remotes

| Remote | URL |
| --- | --- |
| `origin` | `https://github.com/yishu-ziyu/tiptour-macos.git` |
| `upstream` | `https://github.com/milind-soni/tiptour-macos.git` |

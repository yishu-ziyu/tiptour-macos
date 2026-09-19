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

Open `tiptour-macos.xcodeproj` in Xcode and run the `TipTour` scheme. Swift
package dependencies are pinned in
`tiptour-macos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
and are already resolved in `~/Library/Developer/Xcode/DerivedData/tiptour-macos-*`.

Do not build or archive from the terminal once the app has been run locally: it
replaces the signed bundle and macOS will re-request every permission. Use
`scripts/test-jev.sh` for isolated JEV decision tests, which compiles only the
`JevCore` sources into a temporary SwiftPM package.

## Repository remotes

| Remote | URL |
| --- | --- |
| `origin` | `https://github.com/yishu-ziyu/tiptour-macos.git` |
| `upstream` | `https://github.com/milind-soni/tiptour-macos.git` |

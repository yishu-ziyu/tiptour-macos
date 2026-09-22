# Local development setup (fork)

This checkout now builds the local product identity **Her**. The source tree and
Swift namespace still contain the historical TipTour name while repositories are
being consolidated; product identity and code-namespace cleanup are deliberately
separate changes.

## Signing

| Setting | Value | Why |
| --- | --- | --- |
| `CODE_SIGN_STYLE` | `Automatic` | Xcode provisions the local Personal Team identity for Her. |
| `CODE_SIGN_IDENTITY` | `Apple Development` | Current identity: `Apple Development: yishuziyu@gmail.com (N7M4BXHV68)`. |
| `DEVELOPMENT_TEAM` | `87DM76C54G` | Personal Team for this local development machine. |

The previous self-signed `Shangqiuko Local Code Signing` identity is no longer
the product signing identity. It had no Team ID, and legacy Keychain partition
authorization could fall back to per-build cdhash entries. That made an
Access Control grant fragile across rebuilds. Keep the old certificate installed
only as historical local tooling until the Her migration is complete.

## Bundle identifiers

Her uses `com.yishuziyu.her` (plus `.tests` / `.uitests`). The previous local
TipTour identity was `com.yishuziyu.tiptour`.

This is an intentional clean identity boundary: do not silently migrate, delete
or rewrite the old TipTour Keychain items or TCC records. Provider keys are
entered once into Her through its normal UI, and macOS permissions are granted
to Her as a new application identity.

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
| `CODE_SIGN_STYLE` | `Automatic` |
| `CODE_SIGN_IDENTITY` | `Apple Development` |
| `ENABLE_HARDENED_RUNTIME` | `NO` |
| `DEVELOPMENT_TEAM` | `87DM76C54G` |
| `ENABLE_DEBUG_DYLIB` | `NO` |
| `ENABLE_PREVIEWS` | `NO` |

Her now has the stable product identity `com.yishuziyu.her` and Team ID
`87DM76C54G`. Moving from the old self-signed TipTour build is a one-time
identity migration, so Accessibility / Screen Recording / Microphone must be
granted to Her again. Future development should keep the Her team and bundle
identity stable instead of switching back to self-signed or ad-hoc builds.

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
- **Keep the Personal Team explicit.** Do not remove or replace
  `DEVELOPMENT_TEAM = 87DM76C54G` without an intentional signing migration.
- **`ENABLE_DEBUG_DYLIB` must be `NO`.** Its default emits a `TipTour.debug.dylib`
  beside the executable — a SwiftUI Previews JIT artefact a menu-bar app has no
  use for — and the product then refuses to launch with the same Team ID error.
  `ENABLE_PREVIEWS = NO` does *not* remove it; the two settings are independent.
- **Do not override signing on a command line.** The project already owns the
  Her team/identity configuration; ad-hoc overrides create a different macOS
  application identity.

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


### Keychain identity boundary

The old `com.yishuziyu.tiptour` / `stepfunAPIKey` item demonstrated the
self-signed failure mode: Access Control could list the app while its partition
list lacked the current build cdhash, returning OSStatus `-25293` before any
provider connection. Her does not inherit that Keychain item.

Enter provider keys once through Her's normal settings. Successful key reads
remain cached only in the current process; settings presence checks do not
decrypt. Do not copy secrets from the old service, weaken ACLs, write keys to
`.env`, or use the old self-signed identity as a workaround.

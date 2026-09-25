# Her

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Platform: macOS 14.2+](https://img.shields.io/badge/Platform-macOS%2014.2+-black)](https://www.apple.com/macos)

She is always present on your Mac: call her and she answers, she can do short tasks in the window you are looking at, and she says honestly whether they worked. Her is a menu bar app powered by your own API keys. Product direction: [docs/PRODUCT.md](docs/PRODUCT.md).

| Mode | Shortcut | What it does |
| --- | --- | --- |
| StepFun realtime voice (default) | Ctrl+Option | Full-duplex Chinese voice conversation. She can describe the current window and perform short desktop actions, then reads back what was actually confirmed. |
| JEV text | Ctrl+K | Type a click-based task. JEV chooses from locally detected controls; each action is executed and validated by the shared engine. |

First launch: save your StepFun API key (the panel links to where to get one) → allow the microphone and Accessibility → press ⌃⌥ and talk. Screen Recording is asked for when you first want her to look at the screen. Name her and choose another mode in **Settings → Models**. Keys stay in macOS Keychain.

## Privacy and permissions

- Voice modes send microphone audio to the provider. The StepFun realtime model never receives images directly; when screenshots are enabled, a screen question sends one captured image of the target window to StepFun's vision model.
- JEV receives your typed task, locally detected labels and locations, and recent action history; screenshots stay local.
- Accessibility is needed to inspect and control apps. Screen Recording enables screenshots and local screen detection; nothing records video.

## Build

Open `tiptour-macos.xcodeproj`, select the `tiptour-macos` scheme and build/run in Xcode (macOS 14.2+). Do not run `xcodebuild` from the terminal: it invalidates the installed app's macOS permissions. Tests and probes: [docs/guides/build-and-verification.md](docs/guides/build-and-verification.md).

## Documentation

| Start here | For |
| --- | --- |
| [AGENTS.md](AGENTS.md) | Rules for every change, including the documentation sync rule |
| [docs/README.md](docs/README.md) | Full index of every document and whether it is current or a dated record |
| [docs/PRODUCT.md](docs/PRODUCT.md) · [docs/ROADMAP.md](docs/ROADMAP.md) | What she should be and the order we build it in |
| [docs/architecture/README.md](docs/architecture/README.md) | How the app works |
| [docs/guides/build-and-verification.md](docs/guides/build-and-verification.md) · [docs/guides/acceptance.md](docs/guides/acceptance.md) | How to build, test and prove a change |

MIT licensed. See [LICENSE](LICENSE).

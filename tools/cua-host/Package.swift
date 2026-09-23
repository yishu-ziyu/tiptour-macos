// swift-tools-version: 5.9
import PackageDescription

// CuaHost — the controlled desktop test host for Her's real E2E acceptance.
//
// It is deliberately standalone: it never links against the TipTour app target,
// so the acceptance side can build, package and launch it on its own without
// touching the product's build, signing or Accessibility grants.
//
// Controls mirror the controlled page in tools/voice-acceptance/fixture.py
// (left-setting / right-setting 「设置」, open-menu 「打开显示设置」 →
// 「缩放选项」) and add a notes field, a menu command and a second window.
let package = Package(
    name: "cua-host",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CuaHost",
            path: "Sources/CuaHost"
        )
    ]
)

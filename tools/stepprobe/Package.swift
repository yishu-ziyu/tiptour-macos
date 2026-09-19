// swift-tools-version: 5.9
import PackageDescription

// A standalone investigation harness. It deliberately does NOT link against the
// TipTour app target: it must be runnable from the terminal with `swift run`
// without building, signing, or launching the app, which would reset the app's
// macOS Accessibility / Screen Recording grants.
let package = Package(
    name: "stepprobe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "stepprobe",
            path: "Sources/stepprobe"
        )
    ]
)

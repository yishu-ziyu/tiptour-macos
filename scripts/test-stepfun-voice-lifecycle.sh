#!/bin/bash
# Run the StepFun realtime session's turn-lifecycle tests without building,
# signing, or launching TipTour.
#
# Why an isolated package: the lifecycle decisions — when a reply counts as
# finished, whether an interrupted turn may still report a tool result — are
# pure state. Compiling the client and session with their audio dependencies
# into a temporary package keeps verification separate from the installed app,
# so running this cannot reset the app's TCC permissions, and a failure here is
# unambiguous rather than entangled with signing or provisioning.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/tiptour-stepfun-voice-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/Sources/StepFunVoiceLifecycle" "$test_dir/Tests/StepFunVoiceLifecycleTests"

cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StepFunVoiceLifecycle",
    platforms: [.macOS(.v14)],
    targets: [
        // The realtime client and session. The audio player and its format
        // converter come along because the session owns them; nothing here
        // opens a microphone.
        .target(name: "StepFunVoiceLifecycle"),
        .testTarget(
            name: "StepFunVoiceLifecycleTests",
            dependencies: ["StepFunVoiceLifecycle"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
SWIFT

cp "$project_dir/TipTour/Voice/StepFunRealtimeClient.swift" \
   "$project_dir/TipTour/Voice/StepFunRealtimeSession.swift" \
   "$project_dir/TipTour/Voice/GeminiLiveAudioPlayer.swift" \
   "$project_dir/TipTour/Voice/GeminiLiveClient.swift" \
   "$project_dir/TipTour/Voice/PCM16AudioConverter.swift" \
   "$test_dir/Sources/StepFunVoiceLifecycle/"

sed 's/@testable import TipTour/@testable import StepFunVoiceLifecycle/' \
    "$project_dir/TipTourTests/StepFunRealtimeSessionLifecycleTests.swift" \
    > "$test_dir/Tests/StepFunVoiceLifecycleTests/StepFunRealtimeSessionLifecycleTests.swift"

swift test --package-path "$test_dir"

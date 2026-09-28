#!/bin/bash
# Run the 「声音稳定」 voice style tests without building, signing, or
# launching Her: speech-to-text and speech parsing against stubbed HTTP, her
# reply and name saving, and whole turns with a fake microphone and speaker.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/her-stable-voice-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/Sources/StableVoice" "$test_dir/Tests/StableVoiceTests"

cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StableVoice",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything except StableVoiceSession, which needs a real microphone.
        .target(name: "StableVoice"),
        .testTarget(name: "StableVoiceTests", dependencies: ["StableVoice"]),
    ],
    swiftLanguageModes: [.v5]
)
SWIFT

cp "$project_dir/TipTour/Voice/StepAudioTranscriber.swift" \
   "$project_dir/TipTour/Voice/MiniMaxSpeechClient.swift" \
   "$project_dir/TipTour/Voice/StableVoiceConversation.swift" \
   "$project_dir/TipTour/Voice/StableVoiceTurnRunner.swift" \
   "$test_dir/Sources/StableVoice/"
sed 's/@testable import TipTour/@testable import StableVoice/' \
    "$project_dir/TipTourTests/StableVoiceTests.swift" > "$test_dir/Tests/StableVoiceTests/StableVoiceTests.swift"

swift test --package-path "$test_dir" "$@"

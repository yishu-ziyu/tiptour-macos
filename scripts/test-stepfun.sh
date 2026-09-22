#!/bin/bash
# Run the StepFun voice-path decision tests without building, signing, or
# launching TipTour.
#
# Why an isolated package: these tests cover the rules that decide whether a
# voice request may become a click. They depend only on Foundation, so compiling
# them into a temporary package keeps verification completely separate from the
# app — running them cannot reset the app's macOS permissions, and a failure here
# is unambiguous rather than entangled with signing or provisioning.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/tiptour-stepfun-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/Sources/StepFunVoiceCore" "$test_dir/Tests/StepFunVoiceCoreTests"

cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StepFunVoiceCore",
    platforms: [.macOS(.v14)],
    targets: [
        // Only the decision layer. Anything touching AVAudioEngine, URLSession, or
        // TipTourEngine belongs to the integration tests that need the real app.
        .target(name: "StepFunVoiceCore"),
        .testTarget(name: "StepFunVoiceCoreTests", dependencies: ["StepFunVoiceCore"]),
    ],
    swiftLanguageModes: [.v5]
)
SWIFT

cp "$project_dir/TipTour/Voice/StepFunRealtimeTools.swift" \
   "$project_dir/TipTour/Voice/DesktopTaskContract.swift" \
   "$project_dir/TipTour/Voice/DesktopDecisionPacket.swift" \
   "$project_dir/TipTour/Voice/DesktopTaskCoordinator.swift" \
   "$project_dir/TipTour/Voice/DesktopTaskAdmission.swift" \
   "$project_dir/TipTour/Voice/DesktopTaskJournal.swift" \
   "$project_dir/TipTour/Voice/DesktopVoiceTrace.swift" \
   "$project_dir/TipTour/Perception/LocalTargetContinuity.swift" \
   "$test_dir/Sources/StepFunVoiceCore/"

sed 's/@testable import TipTour/@testable import StepFunVoiceCore/' \
    "$project_dir/TipTourTests/StepFunTests.swift" > "$test_dir/Tests/StepFunVoiceCoreTests/StepFunTests.swift"

swift test --package-path "$test_dir" "$@"

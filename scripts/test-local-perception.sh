#!/bin/bash
# Exercise the real local OCR pipeline without building or launching the app.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/tiptour-perception-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/Sources/LocalPerception" "$test_dir/Tests/LocalPerceptionTests"

cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "LocalPerception",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LocalPerception"),
        .testTarget(name: "LocalPerceptionTests", dependencies: ["LocalPerception"])
    ],
    swiftLanguageModes: [.v5]
)
SWIFT
cp "$project_dir/TipTour/Perception/NativeElementDetector.swift" "$test_dir/Sources/LocalPerception/"
cp "$project_dir/TipTour/Perception/LocalPerceptionTargetCache.swift" "$test_dir/Sources/LocalPerception/"
cp "$project_dir/TipTour/Workflow/WorkflowModalPolicy.swift" "$test_dir/Sources/LocalPerception/"
sed 's/@testable import TipTour/@testable import LocalPerception/' \
    "$project_dir/TipTourTests/NativeElementDetectorTests.swift" \
    > "$test_dir/Tests/LocalPerceptionTests/NativeElementDetectorTests.swift"
sed 's/@testable import TipTour/@testable import LocalPerception/' \
    "$project_dir/TipTourTests/LocalPerceptionTargetCacheTests.swift" \
    > "$test_dir/Tests/LocalPerceptionTests/LocalPerceptionTargetCacheTests.swift"
sed 's/@testable import TipTour/@testable import LocalPerception/' \
    "$project_dir/TipTourTests/WorkflowModalPolicyTests.swift" \
    > "$test_dir/Tests/LocalPerceptionTests/WorkflowModalPolicyTests.swift"
swift test --package-path "$test_dir"

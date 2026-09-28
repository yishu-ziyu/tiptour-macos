#!/bin/bash
# Run the daily new things tests (roadmap 3.4) without building, signing, or
# launching Her: Her reads the day file scripts/daily-discovery.py wrote,
# posts each pick once and records 「这类别推」 for the script.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/her-discovery-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/Sources/Discovery" "$test_dir/Tests/DiscoveryTests"
cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Discovery",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Discovery"),
        .testTarget(name: "DiscoveryTests", dependencies: ["Discovery"]),
    ],
    swiftLanguageModes: [.v5]
)
SWIFT

cp "$project_dir/TipTour/App/DiscoveryNotices.swift" "$test_dir/Sources/Discovery/"
sed 's/@testable import TipTour/@testable import Discovery/' \
    "$project_dir/TipTourTests/DiscoveryNoticesTests.swift" > "$test_dir/Tests/DiscoveryTests/DiscoveryNoticesTests.swift"

swift test --package-path "$test_dir" "$@"

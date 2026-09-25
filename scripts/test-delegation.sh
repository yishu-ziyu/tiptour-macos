#!/bin/bash
# Run the Claude Code delegation tests without building, signing, or launching
# Her. Claude Code is replaced by stub executables at the process seam; git and
# the worktrees are real, created under a temporary directory.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/her-delegation-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/Sources/Delegation" "$test_dir/Tests/DelegationTests"

cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Delegation",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Delegation"),
        .testTarget(name: "DelegationTests", dependencies: ["Delegation"]),
    ],
    swiftLanguageModes: [.v5]
)
SWIFT

cp "$project_dir/TipTour/Delegation/"*.swift "$test_dir/Sources/Delegation/"
sed 's/@testable import TipTour/@testable import Delegation/' \
    "$project_dir/TipTourTests/CodingAgentDelegationTests.swift" \
    > "$test_dir/Tests/DelegationTests/CodingAgentDelegationTests.swift"
sed 's/@testable import TipTour/@testable import Delegation/' \
    "$project_dir/TipTourTests/DelegationSessionTests.swift" \
    > "$test_dir/Tests/DelegationTests/DelegationSessionTests.swift"

swift test --package-path "$test_dir" "$@"

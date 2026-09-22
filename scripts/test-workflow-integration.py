#!/usr/bin/env python3
"""Test real app sources without Xcode, installing the app, or opening devices.

Reuses an existing checkout's Xcode-built dependency objects. The application
entry point is excluded; tests own their fixtures and never start the app.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--filter", default="WorkflowRunnerIntegrationTests")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    derived = args.derived_data.expanduser().resolve()
    products = derived / "Build/Products/Debug"
    generated = derived / "Build/Intermediates.noindex/tiptour-macos.build/Debug/tiptour-macos.build/DerivedSources"
    maps = derived / "Build/Intermediates.noindex/GeneratedModuleMaps"
    objects = [products / f"{name}.o" for name in ("CuaDriverCore", "PostHog", "CrashReporter", "phlibwebp")]
    module_maps = [maps / f"{name}.modulemap" for name in ("CrashReporter", "phlibwebp")]
    required = objects + module_maps + [generated / "GeneratedAssetSymbols.swift"]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        parser.error("Existing dependency build required; nothing was built: " + ", ".join(missing))

    with tempfile.TemporaryDirectory(prefix="tiptour-production-tests-") as temporary:
        package = Path(temporary)
        source_dir = package / "Sources/TipTour"
        test_dir = package / "Tests/WorkflowIntegrationTests"
        source_dir.mkdir(parents=True)
        test_dir.mkdir(parents=True)
        for source in (root / "TipTour").rglob("*.swift"):
            if source.name == "TipTourApp.swift":
                continue
            destination = source_dir / source.relative_to(root / "TipTour")
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        for source in generated.glob("*.swift"):
            shutil.copy2(source, source_dir / source.name)
        # Xcode's generated asset symbols use Bundle.module under SwiftPM.
        # Supply a test bundle; these tests do not render or inspect app assets.
        (source_dir / "FixtureBundle.txt").write_text("Headless production-source tests.\n")
        for source in (root / "TipTourTests").glob("*IntegrationTests.swift"):
            shutil.copy2(source, test_dir / source.name)

        swift_flags = ["-I", str(products), "-F", str(products)]
        compiler_help = subprocess.check_output(["xcrun", "swiftc", "-help"], text=True)
        if "-default-isolation" in compiler_help:
            swift_flags += ["-default-isolation", "MainActor"]
        for module_map in module_maps:
            swift_flags += ["-Xcc", f"-fmodule-map-file={module_map}"]
        linker_flags = [str(path) for path in objects] + ["-lc++"]
        manifest = f'''// swift-tools-version: 6.0
import PackageDescription
let settings: [SwiftSetting] = [.unsafeFlags({json.dumps(swift_flags)})]
let package = Package(
    name: "WorkflowIntegration", platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TipTour", resources: [.copy("FixtureBundle.txt")], swiftSettings: settings,
                linkerSettings: [.unsafeFlags({json.dumps(linker_flags)})]),
        .testTarget(name: "WorkflowIntegrationTests", dependencies: ["TipTour"], swiftSettings: settings)
    ], swiftLanguageModes: [.v5]
)
'''
        (package / "Package.swift").write_text(manifest)
        print("Compiling actual app sources; app entry point excluded; no microphone or GUI automation.", flush=True)
        result = subprocess.run([
            "xcrun", "swift", "test", "--package-path", str(package), "--jobs", "4",
            "--enable-code-coverage", "--filter", args.filter,
        ], cwd=package, check=False)
        return result.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"Integration test setup failed: {error}")

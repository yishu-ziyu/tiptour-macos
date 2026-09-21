#!/usr/bin/env python3
"""Type-check the app using existing Xcode dependencies, without building it.

No linking, signing, installing, launching, or dependency resolution is done.
Pass the DerivedData directory of this checkout's existing Xcode build.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    derived = options.derived_data.expanduser().resolve()
    products = derived / "Build/Products/Debug"
    generated = derived / "Build/Intermediates.noindex/tiptour-macos.build/Debug/tiptour-macos.build/DerivedSources"
    module_maps = derived / "Build/Intermediates.noindex/GeneratedModuleMaps"
    required = [products / "CuaDriverCore.swiftmodule", products / "PostHog.swiftmodule",
                products / "Sparkle.framework", generated / "GeneratedAssetSymbols.swift",
                module_maps / "CrashReporter.modulemap", module_maps / "phlibwebp.modulemap"]
    missing = [path for path in required if not path.exists()]
    if missing:
        print("An existing Xcode dependency build is required; nothing was built or changed.", file=sys.stderr)
        for path in missing:
            print(f"Missing: {path}", file=sys.stderr)
        return 2

    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    sources = sorted((root / "TipTour").rglob("*.swift")) + sorted(generated.rglob("*.swift"))
    command = ["xcrun", "swiftc", "-typecheck", "-parse-as-library", "-module-name", "TipTour",
               "-swift-version", "5", "-D", "DEBUG", "-target", "arm64-apple-macos14.2",
               "-sdk", sdk, "-I", str(products), "-F", str(products)]
    compiler_help = subprocess.check_output(["xcrun", "swiftc", "-help"], text=True)
    if "-default-isolation" in compiler_help:
        command += ["-default-isolation", "MainActor"]
    for name in ("CrashReporter", "phlibwebp"):
        command += ["-Xcc", f"-fmodule-map-file={module_maps / (name + '.modulemap')}"]
    command += [str(path) for path in sources]
    with tempfile.NamedTemporaryFile(prefix="tiptour-app-typecheck-", suffix=".log", delete=False) as log:
        print(f"Type-checking {len(sources)} source files. Log: {log.name}", flush=True)
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=False)
    for line in Path(log.name).read_text().splitlines():
        if "error:" in line or "warning:" in line:
            print(line)
    print(f"TYPECHECK_EXIT={result.returncode}")
    return result.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Type-check setup failed: {error}", file=sys.stderr)
        raise SystemExit(2)

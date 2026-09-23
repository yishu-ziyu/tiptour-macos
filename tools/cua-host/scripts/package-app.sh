#!/usr/bin/env bash
# Package the CuaHost SwiftPM executable into a CuaHost.app bundle.
#
# FILE ASSEMBLY ONLY: it builds, copies the binary and Info.plist into a .app
# skeleton and prints the result. It never runs, opens, activates or focuses
# the app — launching is the acceptance integrator's decision, documented in
# README.md.
#
# Usage: scripts/package-app.sh [release|debug]
# Result: tools/cua-host/.build/CuaHost.app  (git-ignored build area)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CONFIG="${1:-release}"

case "$CONFIG" in
  release | debug) ;;
  *)
    echo "usage: $0 [release|debug]" >&2
    exit 2
    ;;
esac

echo "== swift build -c ${CONFIG} (${ROOT})"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="${ROOT}/.build/${CONFIG}/CuaHost"
if [[ ! -x "$BIN" ]]; then
  echo "package-app: missing built binary at ${BIN}" >&2
  exit 1
fi

APP="${ROOT}/.build/CuaHost.app"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "$BIN" "${APP}/Contents/MacOS/CuaHost"
chmod +x "${APP}/Contents/MacOS/CuaHost"
cp "${ROOT}/Info.plist" "${APP}/Contents/Info.plist"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "${APP}/Contents/Info.plist"
fi

echo "== packaged ${APP}"
echo "-- ${APP}/Contents/MacOS"
ls -l "${APP}/Contents/MacOS"
echo "-- ${APP}/Contents"
ls -l "${APP}/Contents"
echo "== done (app not launched; launching is the integrator's step)"

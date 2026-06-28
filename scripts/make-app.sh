#!/bin/bash
# Build WhisperNotionApp and wrap it into a runnable .app bundle with the
# Info.plist (mic + speech usage strings, menu-bar only) and an ad-hoc code
# signature so TCC will attribute microphone/speech permission to the app.
#
# Usage: scripts/make-app.sh [debug|release]   (default: release)
# Output: build/WhisperNotion.app
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ building WhisperNotionApp ($CONFIG)…"
swift build -c "$CONFIG" --product WhisperNotionApp

BIN="$ROOT/.build/$CONFIG/WhisperNotionApp"
[ -x "$BIN" ] || { echo "build failed: $BIN missing" >&2; exit 1; }

APP="$ROOT/build/WhisperNotion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/WhisperNotionApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "▸ ad-hoc signing…"
codesign --force --sign - \
    --entitlements "$ROOT/Resources/WhisperNotion.entitlements" \
    --options runtime \
    "$APP"

echo "✓ built: $APP"
echo "  launch:  open \"$APP\""
echo "  (first launch prompts for microphone + speech permission)"

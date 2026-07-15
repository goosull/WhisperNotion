#!/usr/bin/env bash
# Build and install WhisperNotion into a user-writable Applications folder.
# Usage: scripts/install-app.sh [debug|release] [destination]
set -euo pipefail

CONFIG="${1:-release}"
DEST="${2:-$HOME/Applications/WhisperNotion.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/make-app.sh" "$CONFIG"

mkdir -p "$(dirname "$DEST")"
if [[ -e "$DEST" ]]; then
    echo "▸ replacing ${DEST}…"
    rm -rf "$DEST"
fi

ditto "$ROOT/build/WhisperNotion.app" "$DEST"
echo "✓ installed: $DEST"
echo "  launch:    open \"$DEST\""

#!/usr/bin/env bash
# Capture real mouse-wheel gestures in a local AppKit window. No global input permissions.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_DIR="${TMPDIR:-/tmp}/lyra-wheel-probe"
mkdir -p "$PROBE_DIR/modulecache"
swiftc -parse-as-library -module-cache-path "$PROBE_DIR/modulecache" \
  "$ROOT/apps/macos/Sources/LyraReaderKit/WheelMotion.swift" \
  "$ROOT/scripts/wheel-probe.swift" -o "$PROBE_DIR/wheel-probe"
exec "$PROBE_DIR/wheel-probe" "${1:-$PROBE_DIR/events.jsonl}"

#!/usr/bin/env bash
# Run native shell checks. Default uses offscreen/software and makes no Wayland claim.
# --native [--vulkan|--opengl] exercises the current real desktop session.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE=0
BACKEND=
for arg in "$@"; do
  case "$arg" in
    --native) NATIVE=1 ;;
    --vulkan) BACKEND=vulkan ;;
    --opengl) BACKEND=opengl ;;
    *) echo "Usage: $0 [--native [--vulkan|--opengl]]" >&2; exit 2 ;;
  esac
done
if [ -n "$BACKEND" ] && [ "$NATIVE" -ne 1 ]; then echo "A GPU backend check requires --native" >&2; exit 2; fi
cd "$ROOT"
bash scripts/build-qt.sh
cargo test -p aris-reader-runtime -p aris-reader-desktop-ffi
if [ "$NATIVE" = 1 ]; then
  if [ -n "$BACKEND" ]; then export QSG_RHI_BACKEND="$BACKEND"; fi
  ARIS_READER_REQUIRE_NATIVE_QT=1 "$ROOT/build/desktop-qt-debug/lyra_checks" "$ROOT"
else
  ctest --test-dir "$ROOT/build/desktop-qt-debug" --output-on-failure
fi

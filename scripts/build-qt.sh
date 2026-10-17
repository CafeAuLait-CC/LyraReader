#!/usr/bin/env bash
# Build only the Qt desktop frontend and its narrow Rust static library.
# No Swift, Qt Rust bindings, or Qt system dependencies are added to other crates.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE=debug
if [ "${1:-}" = --release ]; then PROFILE=release; shift; fi
if [ $# -ne 0 ]; then echo "Usage: $0 [--release]" >&2; exit 2; fi
cd "$ROOT"
cmake -S apps/desktop-qt -B "build/desktop-qt-$PROFILE" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DARIS_READER_RUST_PROFILE="$PROFILE"
cmake --build "build/desktop-qt-$PROFILE" --parallel 2
echo "Run: $ROOT/build/desktop-qt-$PROFILE/lyra /path/to/paper.pdf"

#!/usr/bin/env bash
# Repeatable text-selection hit-test benchmark (measurement only, no app behaviour).
#
# Runs the Rust half (uncached FFI text_page vs cached text page) and the Swift half
# (TextPage.characterIndex, SelectionLine.build, the real UniFFI text_page call, and the
# Swift↔Rust parity comparison) on the same corpus pages and points.
#
# Usage:
#   ./scripts/bench-hit-test.sh [--repeat N] [--points N] [--parity N]
#
# Environment (the same variables the rest of the gates use):
#   CARGO_HOME              shared Cargo home (e.g. <repo>/.cargo-home)
#   LYRA_READER_PDFIUM_PATH explicit libpdfium.dylib
#   LYRA_READER_PDF_SAMPLES directory holding the corpus PDFs (default: ./pdf-samples)
#   LYRA_READER_INDEX_CACHE=disabled is set for the run.
#
# Outputs under build/hit-bench/run-N/: dataset.jsonl (inputs + Rust results), rust.txt,
# swift.txt, load.txt. The datasets are never committed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPEAT=3
POINTS=2000
PARITY=500
while [ $# -gt 0 ]; do
  case "$1" in
    --repeat) REPEAT="${2:?--repeat needs a count}"; shift 2 ;;
    --points) POINTS="${2:?--points needs a count}"; shift 2 ;;
    --parity) PARITY="${2:?--parity needs a count}"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

export CARGO_HOME="${CARGO_HOME:?set CARGO_HOME to the shared cargo home}"
export LYRA_READER_PDFIUM_PATH="${LYRA_READER_PDFIUM_PATH:-$ROOT/vendor/pdfium/lib/libpdfium.dylib}"
export LYRA_READER_PDF_SAMPLES="${LYRA_READER_PDF_SAMPLES:-$ROOT/pdf-samples}"
export LYRA_READER_INDEX_CACHE=disabled
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

if [ ! -f "$LYRA_READER_PDFIUM_PATH" ]; then
  echo "missing PDFium: $LYRA_READER_PDFIUM_PATH" >&2
  exit 66
fi

# Five pages, five documents: a line-number gutter (manuscript), an exam page, a report, a
# dense two-column paper, and an avatar paper page.
PAGES=(
  "manuscript_0925.pdf:2"
  "2022-04-05 QualifyExam_Peizhi.pdf:4"
  "Candidacy Report - Ghaith Chrit.pdf:4"
  "[HumanML3D] Guo_Generating_Diverse_and_Natural_3D_Human_Motions_From_Text_CVPR_2022_paper.pdf:1"
  "Wang et al. - 2025 - InstructAvatar Text-Guided Emotion and Motion Control for Avatar Generation.pdf:2"
)
PAGE_ARGS=()
for page in "${PAGES[@]}"; do
  PAGE_ARGS+=(--page "$LYRA_READER_PDF_SAMPLES/$page")
done

mkdir -p "$ROOT/build/hit-bench"
echo "==> building Rust harness (release)"
cargo build --release -q -p lyra-reader-ffi --example hit_bench

echo "==> building Swift checks (release)"
if ! (cd apps/macos && swift build -c release -Xswiftc -enable-testing >"$ROOT/build/hit-bench/swift-build.log" 2>&1); then
  if grep -q "sandbox_apply" "$ROOT/build/hit-bench/swift-build.log"; then
    (cd apps/macos && swift build -c release -Xswiftc -enable-testing --disable-sandbox >"$ROOT/build/hit-bench/swift-build.log" 2>&1)
  else
    tail -20 "$ROOT/build/hit-bench/swift-build.log" >&2
    exit 1
  fi
fi
SWIFT_CHECKS="$ROOT/apps/macos/.build/release/LyraReaderChecks"
if [ ! -x "$SWIFT_CHECKS" ]; then
  echo "missing Swift binary: $SWIFT_CHECKS" >&2
  exit 66
fi

mkdir -p build/hit-bench
for run in $(seq 1 "$REPEAT"); do
  dir="$ROOT/build/hit-bench/run-$run"
  rm -rf "$dir"
  mkdir -p "$dir"
  {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
    uptime
    sysctl -n vm.loadavg
  } >"$dir/load-before.txt"

  echo "==> run $run/$REPEAT: Rust"
  "$ROOT/target/release/examples/hit_bench" \
    --points "$POINTS" --parity "$PARITY" \
    --out "$dir/dataset.jsonl" --results "$dir/rust.json" \
    "${PAGE_ARGS[@]}" >"$dir/rust.txt"

  echo "==> run $run/$REPEAT: Swift"
  "$SWIFT_CHECKS" --bench-hit-test "$dir/dataset.jsonl" >"$dir/swift.txt"

  {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
    uptime
    sysctl -n vm.loadavg
  } >"$dir/load-after.txt"
  echo "    log: $dir"
done

echo
echo "==> summary (mean microseconds; see logs for p50/p95/max)"
for run in $(seq 1 "$REPEAT"); do
  dir="$ROOT/build/hit-bench/run-$run"
  echo "run $run"
  grep -E "Path A|Path B|100% zoom|200% zoom|Parity|closest index|box→|Swift FFI text_page|Swift FFI pageCount|SelectionLine" \
    "$dir/rust.txt" "$dir/swift.txt" | sed 's/^/  /' || true
done
echo
echo "Full logs: build/hit-bench/run-*/"

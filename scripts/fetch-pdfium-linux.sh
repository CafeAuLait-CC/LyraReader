#!/usr/bin/env bash
# Fixed, checksum-verified Linux PDFium. Leaves macOS vendor/pdfium untouched.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$(uname -m)" in
  x86_64) ASSET=pdfium-linux-x64.tgz ;;
  aarch64|arm64) ASSET=pdfium-linux-arm64.tgz ;;
  *) echo "Unsupported Linux architecture" >&2; exit 1 ;;
esac
[ "$(uname -s)" = Linux ] || { echo "This script is for Linux" >&2; exit 1; }
DEST="$ROOT/vendor/pdfium-linux"
if [ -e "$DEST" ]; then
  echo "$DEST already exists; set ARIS_READER_PDFIUM_PATH for another engine, or move it aside before fetching." >&2
  exit 1
fi
mkdir -p "$ROOT/vendor"
STAGING="$(mktemp -d "$ROOT/vendor/.pdfium-linux.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
curl -fL --retry 3 --connect-timeout 15 \
  "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/8100/$ASSET" -o "$STAGING/$ASSET"
EXPECTED="$(awk -v asset="$ASSET" '$2 == asset {print $1}' "$ROOT/scripts/pdfium-sha256.txt")"
ACTUAL="$(sha256sum "$STAGING/$ASSET" | cut -d ' ' -f1)"
[ -n "$EXPECTED" ] && [ "$ACTUAL" = "$EXPECTED" ] || { echo "PDFium checksum mismatch" >&2; exit 1; }
mkdir "$STAGING/package"
tar -xzf "$STAGING/$ASSET" -C "$STAGING/package"
[ -f "$STAGING/package/lib/libpdfium.so" ] || { echo "libpdfium.so is missing" >&2; exit 1; }
mv "$STAGING/package" "$DEST"
echo "PDFium chromium/8100 installed: $DEST/lib/libpdfium.so"

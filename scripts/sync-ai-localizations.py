#!/usr/bin/env python3
"""Export the AI string catalog for SwiftPM builds under Command Line Tools."""
import json
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent.parent
    resources = root / "apps/macos/Sources/LyraReaderKit/Resources"
    catalog = json.loads((resources / "Localizable.xcstrings").read_text())
    for language in ("en", "zh-Hans"):
        folder = resources / f"{language}.lproj"
        folder.mkdir(exist_ok=True)
        lines = ["/* Generated from Localizable.xcstrings by scripts/sync-ai-localizations.py. */"]
        for key, entry in sorted(catalog["strings"].items()):
            value = entry["localizations"][language]["stringUnit"]["value"]
            lines.append(f"{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};")
        (folder / "Localizable.strings").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()

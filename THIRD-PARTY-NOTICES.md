# Third-party notices

LyraReader itself is MIT-licensed (see [LICENSE](LICENSE)). It ships or links the following components, the full texts live with each component (PDFium's are under `vendor/pdfium/licenses/` in a development checkout and are shipped by distributions).


- PDFium — BSD-3-Clause (including its bundled freetype/harfbuzz/icu/lcms/
  libjpeg-turbo/openjpeg/libpng/zlib/agg/abseil, all permissively licensed).
  Distributions must ship the license texts found in vendor/pdfium/licenses/.
- wgpu / naga — MIT OR Apache-2.0
- pdfium-render — MIT OR Apache-2.0
- png (Rust) — MIT OR Apache-2.0 (re-encodes an image stamp's samples for the reader)
- UniFFI / cbindgen — MPL-2.0 (build-time tooling only; their sources are not modified)

The native Qt desktop frontend dynamically links Qt 6 Core, Gui, Qml, Quick,
QuickControls2, Concurrent, Widgets, PrintSupport and their Qt dependencies under
LGPL-3.0 (or a commercial Qt licence). Qt ShaderTools/qsb is used at build time;
the shader compiler is not distributed with the application. The local Linux
build uses the system Qt shared libraries and plugins.

- QtKeychain — BSD-2-Clause (CMake helpers BSD-3-Clause). Notices are in
  `apps/desktop-qt/licenses/QtKeychain.txt`.
- LyraReader Sans SC — a renamed subset of Noto Sans SC, SIL Open Font License 1.1.
  The font and OFL are in `apps/macos/Resources/Fonts/` and are shared by the
  PDF annotation writer and native Qt annotation display.

Qt desktop distributions install these notices, the LGPL text and its referenced
GPL text alongside the PDFium and font notices. This does not bundle a GPL-only
runtime library. MuPDF and AGPL libraries remain excluded.

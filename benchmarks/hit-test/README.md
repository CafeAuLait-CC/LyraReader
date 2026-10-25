# Text hit-test benchmark (C1 input)

Measurement only. It answers two questions before text selection moves into
`lyra-reader-text`: what a per-event synchronous FFI hit-test costs, and how far the Swift and
Rust selection semantics are apart today.

## Run

```sh
export CARGO_HOME=/Users/alex/Documents/Projects/ArisReader/.cargo-home
export LYRA_READER_PDFIUM_PATH="$PWD/vendor/pdfium/lib/libpdfium.dylib"
export LYRA_READER_PDF_SAMPLES=/Users/alex/Documents/Projects/ArisReader/pdf-samples
export LYRA_READER_INDEX_CACHE=disabled
./scripts/bench-hit-test.sh --repeat 3
```

The script builds `crates/lyra-reader-ffi/examples/hit_bench.rs` and the release
`LyraReaderChecks`, then writes `build/hit-bench/run-N/{dataset.jsonl,rust.txt,swift.txt,load-*.txt}`.
`dataset.jsonl` is the shared input: the same pages, view-space character boxes and points feed
both halves. It is generated output and is never committed.

## Method

* **Pages** — five `pdf-samples` pages chosen for layout variety: `manuscript_0925` p3 (line-number
  gutter), `QualifyExam_Peizhi` p5, `Candidacy Report - Ghaith Chrit` p5, `HumanML3D` p2,
  `InstructAvatar` p3. No eval-papers.
* **Points** — 2000 per zoom group (100% and 200%), 78% jittered around a random ink glyph by half a
  box plus 2 pt, 22% uniform over the page. Parity uses 500 points per page (2500 total) with the
  same generator and a random 8–72 × 8–31 pt box around each point.
* **Rust A** — one `LyraReaderDocument.text_page` call per point plus an exact containment scan.
* **Rust B** — one `text_page` per page, then `lyra_reader_text::TextPage::char_index_at` in memory.
* **Swift** — `TextPage.characterIndex` (drag and press variants), `SelectionLine.build`, the real
  UniFFI `LyraReaderDocument.text_page` call on the same points, and a `pageCount()` call as the
  bare FFI round-trip. Timed with `mach_absolute_time()`; the Rust half uses `std::time::Instant`.
* **Parity** — on the same boxes: Swift's closest index vs Rust exact containment and vs a
  test-only nearest-glyph reference (production Rust has no nearest-character hit-test); Swift
  `characterRange` set vs Rust's inverse of `selection_rects` (one rect per character); and the
  `AnnotationSentenceMap` >35% box-coverage range vs both. The coverage predicate is reimplemented
  in the harness because the real entry point takes a `DocumentAnnotation`, which only the engine
  can construct.
* **Zoom** — character boxes are page-space at 100%; the canvas passes page-space points at every
  zoom, so the hit-test itself is zoom-independent. The 100% and 200% groups use different seeds.

## What it does not measure

GPU/Metal submission or presentation, SwiftUI layout/composition, NSEvent delivery, and the
app's overlay redraw. The frame-fraction numbers therefore divide the measured hit-test by
16.7 ms and leave the rest of the frame budget unspent; they do not claim a whole-frame time.
The "nearest" Rust reference and the 35% coverage range are comparison models, not production
APIs.

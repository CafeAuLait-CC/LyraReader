# LyraReader

A **native macOS PDF reader** for papers and technical documents: Rust engine, GPU-composited rendering,
SwiftUI/AppKit interface. Read, annotate and edit PDFs without a web view, and reach the tools a reader of
papers actually needs — clickable citations and figures, a searchable outline, metadata and BibTeX, and an
optional AI assistant.

The repository, the Rust crates (`lyra-reader-*`), the Swift modules (`LyraReaderKit`, `LyraReaderFFI`) and the
developer environment variables (`LYRA_READER_*`) share the `lyra` prefix; the application, its bundle
(`LyraReader.app`), its window titles and its icon all say **LyraReader**.

Design notes, measurement records and the task list are kept outside this repository on purpose (see the note
under *Directory layout*). What ships here is the code, the scripts, the fixtures and this overview.

## Status

Working today: reading with sharp GPU page rendering and deep-zoom tiles, selection and search, tabs and
independent windows, an outline with numbering, annotated thumbnails and reply threads, highlight /
underline / strikethrough / ink / shapes / sticky notes / text boxes / stamps and image signatures, all of
them written back into the PDF, staged page editing with undo, merge and split, forms, redaction that removes
content, printing, bookmarks, citation / figure / table previews, paper metadata with BibTeX, annotation
export, an index cache, and the AI assistant.

A measured performance pass now covers the cold first frame, sharp-on-scroll-stop, deep-zoom tile batching,
on-demand sidebar thumbnails and a memory-lifecycle audit; the numbers, conditions and remaining limits live
in the design notes (document 26), not in this overview. A native Linux port is in progress on a separate,
unmerged branch.

Deliberately not done: a Windows shell, localisation, automatic updates, and a handful
of editing niceties documented in the task list. In-place body-text editing and full content editing exist as
separate features with their own documented limits.

## Capabilities

- **Read**: GPU-composited pages at the display's true resolution, tile pyramid for deep zoom, facing pages,
  page gap, calibrated zoom (Actual Size / Fit Width / Fit Page), independent windows.
- **Navigate**: outline with section numbers and levels, thumbnails that show the file's own annotations,
  document-wide search, per-window Back/Forward across preview jumps.
- **Annotate**: four sliding tool rows — Annotate (markup / pen / placement), Edit (content tools), Fill & Sign
  (text, signature, date, checkmark, cross, stamp, image) and Export — with a right-hand inspector that appears only
  while a tool or a selected object needs it; text markup, ink, shapes, sticky notes, text boxes, stamps and image
  signatures, all with undo,
  recovery in the application cache and verified saving into the original PDF. Signed originals use Save As.
- **Quit safely**: quitting with unsaved changes asks Save All / Discard All / Cancel across every window; a
  resolved quit does not restore those drafts on the next launch, while a crash or SIGTERM still offers them as
  recovery. Closing a dirty tab uses the same decision model.
- **Edit pages**: rotate, delete, reorder, insert, extract, merge and split, redaction consolidated in the Edit
  workspace (Blackout / Erase), flattened copies that bake annotations and form values into the page, all staged with
  undo and verified
  on write; forms; document properties (Info and XMP); redaction that removes the covered content; printing
  (a page torn open by a region card still prints as the original page).
- **Papers**: clickable citations (author–year, bracketed, superscript and bare parenthetical numerals),
  figure/table/algorithm previews with transparent crops, metadata recognition with BibTeX export.
- **Assist**: an optional assistant in its own right-hand panel — document chat with retrieval across the whole
  file and citation chips that jump to the verified source and flash it; region questions, where a drag opens the
  answer in a card set into a real tear in the page (the page's pixels are clipped into two pieces, never
  re-rendered) and the exchange later exports as a Markdown knowledge document; layered summaries over the whole
  document, its sections and its pages, each linking to its source; and in-place translation with a Show original
  toggle that sends nothing on a cache hit. It works over an OpenAI-compatible endpoint or a ChatGPT plan, previews
  every request before anything leaves the machine, keeps the key in the Keychain, and keeps a local record of what
  each send contained (pages, characters, whether a picture went) that never stores document text.
  Summary, Translate and Chat have separate tabs. The assistant and Edit inspectors share the right
  edge; switching between them preserves drafts, reserves the panel's width in the document
  viewport and keeps the document's vertical position stable. Wide pages can scroll horizontally.
- **Translate in place**: select a paragraph and choose Translate from the context menu, the toolbar or
  ⇧⌘L; the translation is drawn over that block with a Show original / Translate chip and a fitted font size,
  never a side-by-side panel. Per-block results are cached in the document cache, so flipping, switching tabs,
  scrolling away and relaunching send nothing again. On a region-card tear the cover follows the page's two paper
  pieces, and opening or closing the tear sends nothing. The overlay writes nothing into the PDF.

## Tech stack (decided)

| Dimension | Choice | Rationale / ADR |
| --- | --- | --- |
| Rendering & compositing | **wgpu 30** (macOS → Metal; future Windows → DX12, Linux → Vulkan) | One GPU layer reused across all three platforms · [ADR-0003](docs/adr/0003-gpu-wgpu-shared-device.md) |
| PDF engine | **Backend trait abstraction + PDFium as the first implementation** (BSD-3), with a slot reserved for a pure-Rust backend | The only engine that supports rendering, per-glyph text boxes, links, forms and incremental save at once · [ADR-0002](docs/adr/0002-pdf-engine-backend.md) |
| UI | **SwiftUI + AppKit** (native macOS), with the portable layout, zoom, viewport and navigation-history rules in the platform-independent `lyra-reader-session` | Native look and feel, input methods and accessibility; a future shell swap reuses those rules instead of rewriting them · [ADR-0001](docs/adr/0001-native-ui-stack.md) |
| Bridging | **UniFFI** (control plane) + hand-written C ABI (GPU surface/device handoff) | Generates Swift bindings automatically, supports async and callback streams · [ADR-0004](docs/adr/0004-rust-swift-ffi.md) |
| License | This project is **MIT**; all dependencies use permissive licenses | [ADR-0005](docs/adr/0005-licensing.md) |
| Build | Cargo workspace + SwiftPM (**Command Line Tools only**, CLT 26.3 on this machine) | Develop without a full Xcode install · [ADR-0006](docs/adr/0006-build-without-xcode.md) |

## Directory layout

```
LyraReader/
├── Cargo.toml                  # Rust workspace (12 crates)
├── rust-toolchain.toml         # Pinned toolchain
├── crates/
│   ├── lyra-reader-core/              # Document model, geometry/coordinates, errors, backend traits (zero platform deps)
│   ├── lyra-reader-pdfium/            # PDFium implementation of DocumentBackend (feature-gated)
│   ├── lyra-reader-text/              # Text pages, per-glyph boxes, selection, search, reading order
│   ├── lyra-reader-edit/              # Annotation model, page operations, forms, incremental save, page-edit transaction
│   ├── lyra-reader-render/            # Tile pyramid, LOD, batch tile planning (cache stays in Swift, ADR-0007)
│   ├── lyra-reader-gpu/               # wgpu device/surface/compositor, shares MTLDevice with the native layer
│   ├── lyra-reader-session/           # Layout, zoom, viewport and navigation-history rules (platform-independent)
│   ├── lyra-reader-ai/                # LLM provider abstraction, context building, citation index
│   ├── lyra-reader-metadata/          # Info/XMP/first-page metadata recognition and BibTeX generation
│   ├── lyra-reader-xfa/               # Read-only XFA rendering and form-data display
│   ├── lyra-reader-ffi/               # UniFFI interface definitions + C ABI exports
│   └── lyra-reader-cli/               # Headless CLI: render/text/metadata/benchmarks (also the golden test entry point)
├── apps/macos/                 # SwiftPM package: LyraReaderKit (UI library) + LyraReader (app) + LyraReaderChecks (native regression runner)
├── scripts/                    # Build, packaging, PDFium fetch and check scripts
├── docs/                       # Design and planning documents (see below)
└── vendor/                     # Third-party binaries (pdfium, git-ignored)
```

> **Note**: `docs/` and `.gitignore` are intentionally **local-only** — they are not committed (both are listed in
> `.gitignore` itself). A fresh clone therefore contains code, scripts and this README, but no design documents and no
> default ignore rules, so build output (`target/`, `build/`, `apps/macos/.build/`, `vendor/`) shows up as untracked
> until you recreate a `.gitignore`.

## Quick start

```bash
./scripts/fetch-pdfium.sh          # PDFium dynamic library (needed for rendering; not committed)
./scripts/build-rust.sh            # Rust static library + generated UniFFI Swift bindings
cd apps/macos && swift build       # add --disable-sandbox in a sandboxed shell
swift run LyraReader               # LYRA_READER_OPEN=/path/to.pdf opens a document at launch
./scripts/make-app-bundle.sh       # output: build/LyraReader.app
./scripts/check.sh                 # full gate: Rust tests, Swift build, native regression suite
```

The developer commands that are not needed to build and run — headless test hooks, fixture generation,
reference-raster comparisons, the CLI inspection commands and the measurement recipes — are documented in the
design notes rather than here.

## Paper visual regression

The debug bundle supports opt-in capture of its own native window on macOS 14.4 or later.
Keep the desktop awake and idle while capture controls its own window and full-screen Space.
The launcher creates a separate bundle identity and scratch caches.
It records 11 checkpoints for paper scale, native edges, sidebar changes, resizing, zoom round trips,
and full-screen entry/exit. The source PDF is generated from synthetic content.

```bash
./scripts/build-rust.sh --debug
./scripts/make-app-bundle.sh --debug
python3 scripts/check-visual.py self-test
python3 -m unittest discover -s scripts -p test_visual_regression.py
python3 scripts/check-visual.py capture --output build/visual-en-light --language en --appearance light
```

Open the output's `index.html` to review native-size PNGs and environment details. Repeat with
`--language zh-Hans` or `--appearance dark`. Each output directory must be new. Capture failure,
missing GPU content, and unstable compositor pixels fail explicitly; an unreviewed candidate is not
an accepted baseline. `--mutation scale` and `--mutation chrome` deliberately produce failing runs
for diagnostic use. Capture waits for registered GPU content and stable native compositor pixels;
Metal presentation timestamps are recorded when available and are not a performance measurement.
Display mode points, backing framebuffer pixels and each window's backing scale are recorded separately;
the framebuffer dimensions do not assert the panel's physical resolution. The flows drive production
state and native window actions; they do not cover pointer gesture delivery.

```bash
python3 scripts/check-visual.py compare --baseline BASELINE --actual ACTUAL --output build/visual-diff
```

Comparison never rescales images and defaults to exact sRGB pixels. It requires matching environments
and an explicit `approval.json` in the baseline directory: `schema_version: 1`, `approved: true`,
`capture_manifest_sha256` for `capture.json`, and a `sha256` object mapping every checkpoint PNG filename
to its SHA-256 digest. Create that approval only after reviewing the images. Changing an approved image
or manifest invalidates it. `--allow-unreviewed` is available solely for developer repeatability checks
and marks the result as **not a regression gate**. No image baselines are accepted automatically.

CI runs the comparer and approval regressions. Its manual **Capture unreviewed visual candidates**
input additionally collects en/light, zh-Hans preference/light and en/dark candidates as artifacts;
reviewed image baselines are required before enabling a PR image-comparison gate. The current bundle
declares English localization; a zh-Hans request records that preference and its actual locale/fallback,
and does not assert translated UI coverage.

## Documentation index

The design documents live in `docs/` in the working copy and are **not committed** (see the note under
*Directory layout*), so the links below resolve locally. Everything explanatory lives there: the README
carries the overview, and the only documents that ship with the code are this file, the licence and
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

| Document | Contents |
| --- | --- |
| [01 Product definition](docs/01-product.md) | Positioning, scenarios, feature tiers, non-goals, success criteria |
| [02 Architecture overview](docs/02-architecture.md) | Layers, crate responsibilities, threading, data flow, portability |
| [03 Rendering pipeline](docs/03-rendering.md) | Coordinates, tile pyramid, cache, PDFium parallelism, GPU compositing |
| [04 UI/UX design](docs/04-ui-ux.md) | Window layout, sidebar, toolbar, shortcuts, gestures, accessibility |
| [05 FFI contract](docs/05-ffi.md) | Object model, threading rules, GPU device/layer handoff |
| [06 AI and advanced reading](docs/06-ai.md) | Previews, region discussion, summarisation, translation, document chat, privacy |
| [07 Roadmap](docs/07-roadmap.md) | Milestones, deliverables, exit criteria, risks |
| [08 Task list](docs/08-tasks.md) | Checkable task breakdown with decisions taken and why |
| [09 Development setup](docs/09-dev-setup.md) | Environment facts, build commands, packaging, workarounds without Xcode |
| [10 Text and citations](docs/10-text-and-citations.md) | Text layer, citation detection, bibliography attribution, caption indexing |
| [11 Content editing](docs/11-content-editing.md) | The content editor in Chinese: interaction, the three hard decisions, limits, verification |
| [12](docs/12-readme-feature-notes.md) / [13](docs/13-readme-measurements.md) / [14](docs/14-readme-intro-archive.md) | Material moved out of this README: feature implementation notes, measurement recipes, the former overview |
| [15](docs/15-document-saving.md) | The save model: working copies, the annotation cache, backups and what a failed save leaves behind |
| [16](docs/16-renaming.md) | The ArisReader to LyraReader rename: scope, compatibility kept, and what migrates on first open |
| [17](docs/17-review-notes.md) / [18](docs/18-eval-latest.md) / [19](docs/19-eval-audit.md) / [20](docs/20-m4-previews-notes.md) / [21](docs/21-review-pr9-notes.md) | Historical reviews and evaluation audits, kept for context — not the current state |
| [22](docs/22-architecture-and-rust-audit.md) | Architecture and Rust-robustness audit: the counterexample catalogue behind the refactor |
| [23](docs/23-audit-todo.md) | The audit's remediation list: what was moved, with PR numbers and the evidence each entry requires |
| [24](docs/24-drift-checklist.md) | Periodic drift checklist and the measured baselines (line counts, unsafe/unwrap, goldens, corpora) |
| [25](docs/25-post-refactor-independent-audit.md) | Independent post-refactor audit: the three regressions it found, their fixes, and what remains |
| [26](docs/26-performance-baseline-and-plan.md) | Performance baseline and plan: measurement definitions, first-frame attribution, the fixes merged so far, the memory audit, and what is deliberately not done |
| [ADR](docs/adr/) | Architecture decision records |

## Milestones at a glance

| Milestone | Theme | Status |
| --- | --- | --- |
| M0 | Skeleton, FFI path, GPU interop | Complete |
| M1 | Minimum readable loop | Complete for reading; performance budgets are now visible in the in-app performance panel |
| M2 | Reading experience | Complete: tabs, independent windows, outline, search, bookmarks, page-corner flags, facing pages |
| M3 | Annotation and editing | Complete: annotations (incl. stamps, image signatures, typed/drawn/Continuity signatures), page operations, forms filling without a tool, redaction (Edit workspace), flattened copies, printing |
| M4 | Advanced reading | Complete: citation/figure/table previews, citation attribution, captions, metadata and BibTeX |
| M5 | AI assistant | Broadly complete: document chat, region questions with an inline card, layered summaries, in-place translation, vision on both connections, local request log; cross-document Q&A not done |
| M6 | Cross-platform | In progress: native Linux port on a separate, unmerged branch; Windows shell not started |
| M7 | Polish: accessibility, i18n, updates | In progress: performance pass delivered (startup, sharp-on-stop, memory audit); accessibility, i18n and updates not started |

Per-milestone detail, measurements and the remaining work live in the design notes, not here.

## License

This project is released under the MIT licence ([LICENSE](LICENSE)). The components it ships or links are
listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md); all of them are permissive, and no AGPL component is
included (MuPDF is excluded on purpose). The decision record is [ADR-0005](docs/adr/0005-licensing.md).

Notable components: PDFium (BSD-3-Clause), wgpu (Apache-2.0), pdfium-render (MIT OR Apache-2.0), UniFFI
(MPL-2.0, build-time only), ureq (MIT OR Apache-2.0), rustls (Apache-2.0 OR ISC OR MIT), unicode-segmentation
(MIT OR Apache-2.0, pinned to the Unicode 16 tables that match the Swift runtime), Noto Sans SC (SIL Open
Font License 1.1, shipped subsetted as `LyraReader Sans SC`), rcgen (tests only). Interface icons are SF Symbols,
used under Apple's licence for in-app use on Apple platforms only: they may not become an application icon or
mark, may not be redistributed as an icon set, and a Linux or Windows shell must bring its own icons. The
application icon is original artwork made for this project.

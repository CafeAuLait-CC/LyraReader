//! Measure text hit-testing on real PDF pages: the uncached FFI path, a cached text page, and
//! the data a Swift/Rust parity comparison needs. **Measurement only — not part of the app.**
//!
//! ```text
//! cargo run -p lyra-reader-ffi --release --example hit_bench -- \
//!   --page 'pdf-samples/manuscript_0925.pdf:2' ... --out build/hit-bench/dataset.jsonl
//! ```
//!
//! Paths measured here:
//!
//! * **A — uncached.** One `LyraReaderDocument::text_page` call per point (the FFI method the
//!   shell uses today), followed by an exact containment scan over the returned boxes. This is
//!   the cost a synchronous per-event FFI hit-test would pay if Rust kept no text page.
//! * **B — cached text page.** One `text_page` call per page, then
//!   `lyra_reader_text::TextPage::char_index_at` in memory per point. `char_index_at` is the
//!   current production Rust hit-test (a linear containment scan; see
//!   `crates/lyra-reader-text/src/lib.rs`).
//!
//! The example also writes JSON Lines with the page boxes, the sampled points and Rust's
//! results. `LyraReaderChecks --bench-hit-test` consumes that file and measures the Swift
//! implementation on the same points, so the two tables share inputs rather than approximations.
//!
//! The timing points are 78% near a random glyph (jittered by half a box plus 2 pt) and 22%
//! uniform over the page; a drag spends most of its events on text, while the uniform points
//! keep margins and inter-line gaps represented. Points are page-space at 100%; the hit-test
//! itself is zoom-independent (the canvas passes page-space points at every zoom), so the two
//! zoom groups differ only in their sample seed.
//!
//! Run with `LYRA_READER_PDFIUM_PATH` set (see `docs/09-dev-setup.md`). The page list is passed
//! explicitly so no corpus path is baked into the binary.

use lyra_reader_core::{PageIndex, Point, RawCharBox, Rect};
use lyra_reader_ffi::api::{
    LyraReaderDocument, LyraReaderEngine, TextChar, TextPage as FfiTextPage,
};
use lyra_reader_text::{CharBox, CharIndex, SelectionTextPage, TextPage};
use serde_json::json;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;

const DEFAULT_POINTS: usize = 2000;
const DEFAULT_PARITY_PER_PAGE: usize = 500;

/// One corpus page, opened once.
struct PageData {
    label: String,
    path: PathBuf,
    page_index: u32,
    width: f64,
    height: f64,
    /// UTF-8 length of the whole-page string (part of a cached text page's cost).
    text_bytes: usize,
    /// FFI boxes (view space, top-left origin) exactly as the shell receives them.
    chars: Vec<TextChar>,
    /// The same boxes as a production `lyra-reader-text` text page, for `char_index_at` and
    /// `selection_rects`. Constructed test-only; the boxes are the FFI ones, so both paths and
    /// Swift address identical geometry.
    text_page: TextPage,
    /// The Swift-parity line-aware view of the same page: the engine's interactive path.
    selection: SelectionTextPage,
    /// `selection_rects(i, i)[0]` for every character; the Rust definition of "one rect per
    /// character" used by the box→character comparison.
    char_rects: Vec<Rect>,
    ink_indices: Vec<usize>,
}

#[derive(Clone, Copy)]
struct PointSample {
    page: usize,
    x: f64,
    y: f64,
    box_w: f64,
    box_h: f64,
}

struct Stats {
    n: usize,
    min: f64,
    mean: f64,
    p50: f64,
    p95: f64,
    max: f64,
}

impl PageData {
    /// A `lyra-reader-text` page owned by a cache: its `CharBox` vector plus the page string.
    /// This excludes `Vec` spare capacity (the cache can shrink to fit) and allocator rounding.
    fn estimated_text_page_bytes(&self) -> usize {
        std::mem::size_of::<TextPage>()
            + self.chars.len() * std::mem::size_of::<CharBox>()
            + self.text_bytes
    }
}

impl Stats {
    fn of(values: &[f64]) -> Self {
        let mut sorted = values.to_vec();
        sorted.sort_by(f64::total_cmp);
        let n = sorted.len();
        let mean = if n == 0 {
            0.0
        } else {
            sorted.iter().sum::<f64>() / n as f64
        };
        Self {
            n,
            min: sorted.first().copied().unwrap_or(0.0),
            mean,
            p50: percentile(&sorted, 0.50),
            p95: percentile(&sorted, 0.95),
            max: sorted.last().copied().unwrap_or(0.0),
        }
    }

    fn to_json(&self) -> serde_json::Value {
        json!({
            "n": self.n, "min_us": self.min, "mean_us": self.mean,
            "p50_us": self.p50, "p95_us": self.p95, "max_us": self.max,
        })
    }
}

/// Nearest-rank percentile: the smallest observed value whose rank covers `p`.
fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let rank = ((p * sorted.len() as f64).ceil() as usize).max(1);
    sorted[rank.min(sorted.len()) - 1]
}

struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.0
    }

    fn unit(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn below(&mut self, upper: usize) -> usize {
        if upper == 0 {
            0
        } else {
            (self.next() % upper as u64) as usize
        }
    }
}

fn main() {
    let mut out: Option<PathBuf> = None;
    let mut results: Option<PathBuf> = None;
    let mut points = DEFAULT_POINTS;
    let mut parity_per_page = DEFAULT_PARITY_PER_PAGE;
    let mut specs: Vec<(PathBuf, u32)> = Vec::new();

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--out" => out = Some(PathBuf::from(args.next().unwrap_or_default())),
            "--results" => results = Some(PathBuf::from(args.next().unwrap_or_default())),
            "--points" => {
                points = args
                    .next()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(DEFAULT_POINTS)
            }
            "--parity" => {
                parity_per_page = args
                    .next()
                    .and_then(|value| value.parse().ok())
                    .unwrap_or(DEFAULT_PARITY_PER_PAGE)
            }
            "--page" => {
                if let Some(spec) = args.next() {
                    match parse_page_spec(&spec) {
                        Some(page) => specs.push(page),
                        None => fail(&format!("--page wants PATH:PAGE, got {spec:?}")),
                    }
                }
            }
            "-h" | "--help" => {
                println!(
                    "usage: hit_bench --page PATH:PAGE [--page …] [--out dataset.jsonl] \
                     [--results results.json] [--points N] [--parity N]\n\
                     \x20      default page list: 5 pdf-samples pages; --page overrides it"
                );
                return;
            }
            other => fail(&format!("unknown argument {other:?}")),
        }
    }
    if specs.is_empty() {
        specs = default_pages();
    }
    if specs.is_empty() {
        fail("no --page given and LYRA_READER_PDF_SAMPLES has no default corpus");
    }
    let out = out.unwrap_or_else(|| {
        fail("--out is required (the Swift half reads the dataset)");
    });

    let engine = LyraReaderEngine::new();
    let mut pages = Vec::with_capacity(specs.len());
    for (path, page_index) in &specs {
        match open_page(&engine, path, *page_index) {
            Ok(page) => pages.push(page),
            Err(error) => fail(&format!("{} page {page_index}: {error}", path.display())),
        }
    }

    let mut writer = BufWriter::new(File::create(&out).unwrap_or_else(|error| {
        fail(&format!("could not create {}: {error}", out.display()));
    }));
    for (index, page) in pages.iter().enumerate() {
        let chars: Vec<_> = page
            .chars
            .iter()
            .map(|c| json!([c.unicode, c.x_pt, c.y_pt, c.width_pt, c.height_pt]))
            .collect();
        writeln!(
            writer,
            "{}",
            json!({
                "kind": "page",
                "page": index,
                "label": page.label,
                "path": page.path.display().to_string(),
                "page_index": page.page_index,
                "width_pt": page.width,
                "height_pt": page.height,
                "chars": chars,
            })
        )
        .expect("write page dataset");
    }

    println!("Rust hit-test benchmark");
    println!(
        "pages={} points_per_zoom={} parity_points={}",
        pages.len(),
        points,
        parity_per_page * pages.len()
    );
    println!(
        "struct bytes: RawCharBox={} CharBox={} FFI TextChar={} (text layer excludes font_name/angle)",
        std::mem::size_of::<RawCharBox>(),
        std::mem::size_of::<CharBox>(),
        std::mem::size_of::<TextChar>()
    );
    let selection_cache_bytes: usize = pages
        .iter()
        .map(|page| page.selection.estimated_bytes())
        .sum();
    println!(
        "five-page selection cache≈{:.1} KiB (budget {:.1} KiB, max 5 pages)",
        selection_cache_bytes as f64 / 1024.0,
        1536.0
    );
    let mut page_json = Vec::new();
    for (index, page) in pages.iter().enumerate() {
        println!(
            "  page[{index}] {:<18} p{:<3} chars={:<5} size={:.1}x{:.1} pt text={} B \
             cached_text_page≈{:.1} KiB ({:.1} B/char)",
            page.label,
            page.page_index,
            page.chars.len(),
            page.width,
            page.height,
            page.text_bytes,
            page.estimated_text_page_bytes() as f64 / 1024.0,
            page.estimated_text_page_bytes() as f64 / page.chars.len().max(1) as f64
        );
        println!(
            "          selection layout≈{:.1} KiB ({} lines)",
            page.selection.estimated_bytes() as f64 / 1024.0,
            page.selection.layout().lines().len()
        );
        page_json.push(json!({
            "page": index, "label": page.label, "page_index": page.page_index,
            "chars": page.chars.len(), "width_pt": page.width, "height_pt": page.height,
        }));
    }

    // ── Sample the points once; every path and the Swift half see the same values ───────────
    let timing: Vec<(&'static str, Vec<PointSample>)> = [
        ("timing100", 0x9E37_79B9_7F4A_7C15_u64),
        ("timing200", 0xC2B2_AE3D_27D4_EB4F_u64),
    ]
    .into_iter()
    .map(|(group, seed)| (group, sample_points(&pages, points, seed)))
    .collect();
    let mut parity: Vec<PointSample> = Vec::new();
    for (index, _) in pages.iter().enumerate() {
        let mut rng = Lcg(0x5EED_5EED_5EED_5EED_u64 ^ index as u64);
        for _ in 0..parity_per_page {
            parity.push(generate_point(&pages[index], index, &mut rng));
        }
    }

    // ── Path A: text_page per point, exact scan over its boxes ──────────────────────────────
    let mut path_a: HashMap<&'static str, Vec<f64>> = HashMap::new();
    let mut path_b: HashMap<&'static str, Vec<f64>> = HashMap::new();
    let mut path_c: HashMap<&'static str, Vec<f64>> = HashMap::new();
    let mut mismatched_paths = 0usize;
    for (group, samples) in &timing {
        let mut by_page: Vec<Vec<&PointSample>> = vec![Vec::new(); pages.len()];
        for sample in samples {
            by_page[sample.page].push(sample);
        }
        let mut read_times = Vec::with_capacity(samples.len());
        let mut cached_times = Vec::with_capacity(samples.len());
        let mut line_aware_times = Vec::with_capacity(samples.len());
        for (page_index, page) in pages.iter().enumerate() {
            let document = open_document(&engine, &page.path);
            // Warm PDFium's per-page text extraction; the recorded loop measures the steady
            // state a drag actually sees after the page has been on screen.
            for _ in 0..3 {
                let _ = document
                    .text_page(page.page_index)
                    .unwrap_or_else(|error| fail(&format!("text_page warmup failed: {error}")));
            }
            let warmup = by_page[page_index].first().map_or(
                PointSample {
                    page: 0,
                    x: page.width / 2.0,
                    y: page.height / 2.0,
                    box_w: 1.0,
                    box_h: 1.0,
                },
                |sample| **sample,
            );
            for _ in 0..64 {
                let _ = page.text_page.char_index_at(Point::new(warmup.x, warmup.y));
            }
            for sample in &by_page[page_index] {
                let started = Instant::now();
                let text = document
                    .text_page(page.page_index)
                    .unwrap_or_else(|error| fail(&format!("text_page failed: {error}")));
                let index = exact_index(&text.chars, sample.x, sample.y);
                let elapsed = started.elapsed().as_secs_f64() * 1e6;
                std::hint::black_box(index);
                read_times.push(elapsed);

                let started = Instant::now();
                let cached = page.text_page.char_index_at(Point::new(sample.x, sample.y));
                let elapsed = started.elapsed().as_secs_f64() * 1e6;
                std::hint::black_box(cached);
                cached_times.push(elapsed);
                if cached.map(|index| index.0 as usize) != index {
                    mismatched_paths += 1;
                }

                let started = Instant::now();
                let line_aware = page
                    .selection
                    .char_index_at(Point::new(sample.x, sample.y), false);
                let elapsed = started.elapsed().as_secs_f64() * 1e6;
                std::hint::black_box(line_aware);
                line_aware_times.push(elapsed);
            }
        }
        path_a.insert(group, read_times);
        path_b.insert(group, cached_times);
        path_c.insert(group, line_aware_times);
    }

    let mut timing_json = serde_json::Map::new();
    println!("\nPath A — uncached: text_page + exact scan (per point)");
    for group in ["timing100", "timing200"] {
        let stats = Stats::of(&path_a[group]);
        print_stats(group_label(group), &stats);
        timing_json.insert(
            format!("path_a_{}", group.trim_start_matches("timing")),
            stats.to_json(),
        );
    }
    println!("\nPath B — cached text page: char_index_at (per point)");
    for group in ["timing100", "timing200"] {
        let stats = Stats::of(&path_b[group]);
        print_stats(group_label(group), &stats);
        timing_json.insert(
            format!("path_b_{}", group.trim_start_matches("timing")),
            stats.to_json(),
        );
    }
    println!("\nPath C — cached line-aware (Swift-parity) char_index_at (per point)");
    for group in ["timing100", "timing200"] {
        let stats = Stats::of(&path_c[group]);
        print_stats(group_label(group), &stats);
        timing_json.insert(
            format!("path_c_{}", group.trim_start_matches("timing")),
            stats.to_json(),
        );
    }
    if mismatched_paths > 0 {
        println!(
            "\nWARNING: {mismatched_paths} point(s) returned a different character from A and B"
        );
    } else {
        println!("\nPath A and path B returned the same character for every sampled point");
    }

    // ── Parity data: Rust results the Swift half compares against ──────────────────────────
    let mut parity_lines = Vec::with_capacity(parity.len());
    for sample in &parity {
        let page = &pages[sample.page];
        let exact = exact_index(&page.chars, sample.x, sample.y);
        let nearest = nearest_index(&page.chars, sample.x, sample.y);
        let box_rect = Rect::new(
            sample.x - sample.box_w / 2.0,
            sample.y - sample.box_h / 2.0,
            sample.box_w,
            sample.box_h,
        );
        let (first, last, count, hash) = box_set(page, box_rect);
        let new_index = page
            .selection
            .char_index_at(Point::new(sample.x, sample.y), false)
            .map(|index| index.0 as usize);
        let new_drag = page
            .selection
            .char_index_at(Point::new(sample.x, sample.y), true)
            .map(|index| index.0 as usize);
        let (new_first, new_last, new_set_count, new_hash) = selection_box_set(page, box_rect);
        let new_string = match (new_first, new_last) {
            (Some(first), Some(last)) => page.selection.string_in_range(first as u32, last as u32),
            _ => String::new(),
        };
        parity_lines.push(json!({
            "kind": "point", "group": "parity", "page": sample.page,
            "x": sample.x, "y": sample.y, "box_w": sample.box_w, "box_h": sample.box_h,
            "rust_exact": exact, "rust_nearest": nearest,
            "rust_box_first": first, "rust_box_last": last,
            "rust_box_count": count, "rust_box_hash": format!("{hash:016x}"),
            "rust_new_index": new_index, "rust_new_drag_index": new_drag,
            "rust_new_box_first": new_first, "rust_new_box_last": new_last,
            "rust_new_box_count": new_set_count,
            "rust_new_box_hash": format!("{new_hash:016x}"),
            "rust_new_string_hash": format!("{:016x}", string_hash(&new_string)),
            "rust_new_string_len": new_string.len(),
        }));
    }

    for (group, samples) in &timing {
        for sample in samples {
            writeln!(
                writer,
                "{}",
                json!({
                    "kind": "point", "group": group, "page": sample.page,
                    "x": sample.x, "y": sample.y, "box_w": sample.box_w, "box_h": sample.box_h,
                })
            )
            .expect("write timing point");
        }
    }
    for line in &parity_lines {
        writeln!(writer, "{line}").expect("write parity point");
    }
    writer.flush().expect("flush dataset");
    println!(
        "\nDataset: {} ({} page + {} point lines)",
        out.display(),
        pages.len(),
        points * 2 + parity.len()
    );

    if let Some(results) = results {
        let payload = json!({
            "pages": page_json,
            "points_per_zoom": points,
            "parity_per_page": parity_per_page,
            "timing": timing_json,
            "path_results_disagree": mismatched_paths,
        });
        if let Err(error) = std::fs::write(&results, serde_json::to_vec_pretty(&payload).unwrap()) {
            fail(&format!("could not write {}: {error}", results.display()));
        }
        println!("Rust results: {}", results.display());
    }
}

fn group_label(group: &str) -> &'static str {
    match group {
        "timing100" => "100% zoom",
        _ => "200% zoom",
    }
}

fn print_stats(label: &str, stats: &Stats) {
    println!(
        "  {label:<10} n={:<5} mean={:8.2}  p50={:8.2}  p95={:8.2}  max={:9.2}  min={:8.2} µs",
        stats.n, stats.mean, stats.p50, stats.p95, stats.max, stats.min
    );
}

fn exact_index(chars: &[TextChar], x: f64, y: f64) -> Option<usize> {
    chars.iter().position(|c| {
        x >= c.x_pt && x <= c.x_pt + c.width_pt && y >= c.y_pt && y <= c.y_pt + c.height_pt
    })
}

/// Test-only nearest-character reference: minimum squared distance to a glyph box. Production
/// Rust has no nearest-character hit-test, so this is explicitly a candidate, not today's path.
fn nearest_index(chars: &[TextChar], x: f64, y: f64) -> Option<usize> {
    let mut best: Option<(f64, usize)> = None;
    for (index, c) in chars.iter().enumerate() {
        if c.width_pt <= 0.0 || c.height_pt <= 0.0 {
            continue;
        }
        if char::from_u32(c.unicode).is_some_and(char::is_whitespace) {
            continue;
        }
        let dx = distance(x, c.x_pt, c.x_pt + c.width_pt);
        let dy = distance(y, c.y_pt, c.y_pt + c.height_pt);
        let squared = dx * dx + dy * dy;
        if best.is_none_or(|(best, _)| squared < best) {
            best = Some((squared, index));
        }
    }
    best.map(|(_, index)| index)
}

fn distance(value: f64, low: f64, high: f64) -> f64 {
    (low - value).max(value - high).max(0.0)
}

/// Rust's "one rect per character" selection, reversed into a box→character set.
fn box_set(page: &PageData, box_rect: Rect) -> (Option<usize>, Option<usize>, usize, u64) {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    let mut first = None;
    let mut last = None;
    let mut count = 0;
    for (index, rect) in page.char_rects.iter().enumerate() {
        if rect.intersection(box_rect).is_some() {
            first.get_or_insert(index);
            last = Some(index);
            count += 1;
            for byte in (index as u32).to_le_bytes() {
                hash ^= byte as u64;
                hash = hash.wrapping_mul(0x100_0000_01b3);
            }
        }
    }
    (first, last, count, hash)
}

/// The new line-aware box rule, expressed the same way as `box_set`: the contiguous span from
/// the first to the last intersecting stop (Swift's `first...last`). The character *set* is
/// every index in the span, so the hash walks the span.
fn selection_box_set(
    page: &PageData,
    box_rect: Rect,
) -> (Option<usize>, Option<usize>, usize, u64) {
    let Some((first, last)) = page.selection.character_range(box_rect) else {
        return (None, None, 0, 0xcbf2_9ce4_8422_2325);
    };
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for index in first.0..=last.0 {
        for byte in index.to_le_bytes() {
            hash ^= byte as u64;
            hash = hash.wrapping_mul(0x100_0000_01b3);
        }
    }
    (
        Some(first.0 as usize),
        Some(last.0 as usize),
        (last.0 - first.0 + 1) as usize,
        hash,
    )
}

/// FNV-1a over UTF-8, used for the range→string parity comparison without storing the text.
fn string_hash(value: &str) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in value.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    hash
}

fn sample_points(pages: &[PageData], total: usize, seed: u64) -> Vec<PointSample> {
    let mut rng = Lcg(seed);
    let mut samples = Vec::with_capacity(total);
    let per_page = total / pages.len();
    let extra = total % pages.len();
    for (index, page) in pages.iter().enumerate() {
        let count = per_page + usize::from(index < extra);
        for _ in 0..count {
            samples.push(generate_point(page, index, &mut rng));
        }
    }
    samples
}

fn generate_point(page: &PageData, page_index: usize, rng: &mut Lcg) -> PointSample {
    let (mut x, mut y) = if !page.ink_indices.is_empty() && rng.below(100) < 78 {
        let character = &page.chars[page.ink_indices[rng.below(page.ink_indices.len())]];
        (
            character.x_pt + (rng.unit() * 2.0 - 1.0) * (character.width_pt / 2.0 + 2.0),
            character.y_pt + (rng.unit() * 2.0 - 1.0) * (character.height_pt / 2.0 + 2.0),
        )
    } else {
        (rng.unit() * page.width, rng.unit() * page.height)
    };
    x = x.clamp(0.0, page.width);
    y = y.clamp(0.0, page.height);
    PointSample {
        page: page_index,
        x,
        y,
        box_w: 8.0 + (rng.next() % 65) as f64,
        box_h: 8.0 + (rng.next() % 24) as f64,
    }
}

fn open_page(engine: &LyraReaderEngine, path: &Path, page_index: u32) -> Result<PageData, String> {
    let document = engine
        .open_document(path.display().to_string(), None)
        .map_err(|error| error.to_string())?;
    let size = document
        .page_size_pt(page_index)
        .map_err(|error| error.to_string())?;
    let raw = document
        .text_page(page_index)
        .map_err(|error| error.to_string())?;
    Ok(build_page(
        path,
        page_index,
        size.width_pt,
        size.height_pt,
        raw,
    ))
}

fn build_page(path: &Path, page_index: u32, width: f64, height: f64, raw: FfiTextPage) -> PageData {
    let chars = raw.chars;
    let mut text_chars = Vec::with_capacity(chars.len());
    for c in &chars {
        text_chars.push(CharBox {
            rect: Rect::new(c.x_pt, c.y_pt, c.width_pt, c.height_pt),
            origin: Point::new(c.x_pt, c.y_pt),
            unicode: c.unicode,
            font_size: 0.0,
            logical_order: 0,
        });
    }
    let text_page = TextPage {
        page: PageIndex(page_index),
        chars: text_chars,
        blocks: Vec::new(),
        text: raw.text,
        is_generated: false,
        has_unicode_map_error: raw.has_unicode_map_error,
    };
    let selection = SelectionTextPage::new(text_page.clone());
    let char_rects = (0..text_page.chars.len())
        .map(|index| {
            let index = CharIndex(index as u32);
            text_page.selection_rects(index, index)[0]
        })
        .collect();
    let ink_indices = chars
        .iter()
        .enumerate()
        .filter(|(_, c)| {
            c.width_pt > 0.0
                && c.height_pt > 0.0
                && !char::from_u32(c.unicode).is_some_and(char::is_whitespace)
        })
        .map(|(index, _)| index)
        .collect();
    PageData {
        label: path
            .file_stem()
            .map(|stem| stem.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string()),
        path: path.to_path_buf(),
        page_index,
        width,
        height,
        text_bytes: text_page.text.len(),
        chars,
        text_page,
        selection,
        char_rects,
        ink_indices,
    }
}

fn open_document(engine: &LyraReaderEngine, path: &Path) -> std::sync::Arc<LyraReaderDocument> {
    engine
        .open_document(path.display().to_string(), None)
        .unwrap_or_else(|error| fail(&format!("open {}: {error}", path.display())))
}

fn parse_page_spec(spec: &str) -> Option<(PathBuf, u32)> {
    let (path, page) = spec.rsplit_once(':')?;
    Some((PathBuf::from(path), page.parse().ok()?))
}

fn default_pages() -> Vec<(PathBuf, u32)> {
    let Ok(root) = std::env::var("LYRA_READER_PDF_SAMPLES") else {
        return Vec::new();
    };
    [
        ("manuscript_0925.pdf", 2),
        ("CR2.pdf", 4),
        ("CR1.pdf", 4),
        (
            "[HumanML3D] Guo_Generating_Diverse_and_Natural_3D_Human_Motions_From_Text_CVPR_2022_paper.pdf",
            1,
        ),
        (
            "Wang et al. - 2025 - InstructAvatar Text-Guided Emotion and Motion Control for Avatar Generation.pdf",
            2,
        ),
    ]
    .into_iter()
    .map(|(name, page)| (Path::new(&root).join(name), page))
    .collect()
}

fn fail(message: &str) -> ! {
    eprintln!("hit_bench: {message}");
    std::process::exit(64)
}

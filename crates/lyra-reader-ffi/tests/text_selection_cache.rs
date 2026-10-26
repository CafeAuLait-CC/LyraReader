//! The per-document selection cache: the loading path prepares a page, synchronous pointer
//! queries never extract, and a five-page byte-bounded LRU.
//!
//! These tests use committed fixtures and are skipped, with an announcement, when PDFium is not
//! available (the same convention as the other FFI integration tests).

use lyra_reader_core::{PageIndex, Point, Rect};
use lyra_reader_ffi::api::{LyraReaderDocument, LyraReaderEngine, TextPage};
use lyra_reader_text::{CharBox, SelectionTextPage};
use std::path::PathBuf;
use std::sync::Arc;

fn fixture(name: &str) -> PathBuf {
    if let Some(override_dir) = std::env::var_os("LYRA_READER_TEST_FIXTURES")
        && !override_dir.is_empty()
    {
        let candidate = PathBuf::from(override_dir).join(name);
        if candidate.is_file() {
            return candidate;
        }
    }
    if let Ok(current) = std::env::current_dir() {
        for ancestor in current.ancestors() {
            let candidate = ancestor.join("tests/fixtures").join(name);
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    panic!("committed fixture {name:?} not found");
}

fn open(name: &str) -> (Arc<LyraReaderEngine>, Arc<LyraReaderDocument>) {
    let engine = LyraReaderEngine::new();
    let document = engine
        .open_document(fixture(name).display().to_string(), None)
        .expect("open fixture");
    (engine, document)
}

/// The Swift `TextPage` model for the same page, built from the loading path's record.
///
/// This is deliberately independent of the Rust selection cache: it is the parity-tested
/// fallback the shell uses when a synchronous query returns "not prepared". The record's boxes
/// are already view space, exactly what Swift's `TextChar` carries.
fn local_selection(record: &TextPage) -> SelectionTextPage {
    let chars = record
        .chars
        .iter()
        .map(|character| CharBox {
            rect: Rect::new(
                character.x_pt,
                character.y_pt,
                character.width_pt,
                character.height_pt,
            ),
            origin: Point::new(character.x_pt, character.y_pt),
            unicode: character.unicode,
            font_size: character.height_pt,
            logical_order: 0,
        })
        .collect();
    SelectionTextPage::new(lyra_reader_text::TextPage {
        page: PageIndex(record.page),
        chars,
        blocks: Vec::new(),
        text: record.text.clone(),
        is_generated: false,
        has_unicode_map_error: record.has_unicode_map_error,
    })
}

#[test]
fn a_cold_synchronous_query_is_a_typed_miss_and_does_not_extract() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium is not available");
        return;
    }
    let (_engine, document) = open("multipage.pdf");
    let before = document.text_page_cache_stats();
    assert_eq!(before.loads, 0);
    assert_eq!(before.entries, 0);

    let size = document.page_size_pt(0).expect("page size");
    let index = document
        .text_character_index(0, size.width_pt / 2.0, size.height_pt / 2.0, false)
        .expect("hit test");
    let range = document
        .text_character_range(0, size.width_pt / 4.0, size.height_pt / 4.0, 20.0, 20.0)
        .expect("box range");
    let string = document.text_range_string(0, 0, 10).expect("range string");
    let after = document.text_page_cache_stats();

    assert!(index.is_none(), "a cold page is not prepared");
    assert!(range.is_none(), "a cold page is not prepared");
    assert!(string.is_none(), "a cold page is not prepared");
    assert_eq!(
        after.loads, before.loads,
        "a synchronous query never extracts"
    );
    assert_eq!(after.entries, 0, "a miss must not prepare the page");
    assert_eq!(after.misses, 3, "all three lookups report the typed miss");
    assert_eq!(after.hits, 0);
}

#[test]
fn text_page_is_the_only_prepare_path_and_a_warm_page_stays_extraction_free() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium is not available");
        return;
    }
    let (_engine, document) = open("multipage.pdf");
    // The shell loads the page before anyone can point at it.
    let text = document.text_page(0).expect("text page");
    let warmed = document.text_page_cache_stats();
    assert_eq!(
        warmed.entries, 1,
        "loading the page retains its selection geometry"
    );
    assert_eq!(warmed.loads, 1, "the loading path counts as one extraction");
    assert_eq!(warmed.misses, 0);

    let first_char = text.chars.first().expect("fixture page has text");
    let x = first_char.x_pt + first_char.width_pt / 2.0;
    let y = first_char.y_pt + first_char.height_pt / 2.0;
    let rect = Rect::new(
        first_char.x_pt,
        first_char.y_pt,
        first_char.width_pt,
        first_char.height_pt,
    );
    let first = document
        .text_character_index(0, x, y, false)
        .expect("hit test");
    assert!(first.is_some(), "the warm page answers the first event");
    let second = document
        .text_character_index(0, x, y, false)
        .expect("hit test");
    let after_second = document.text_page_cache_stats();
    assert_eq!(first, second, "the same point returns the same character");
    assert_eq!(
        after_second.loads, 1,
        "a hit never re-enters PDFium after the loading path"
    );
    assert_eq!(after_second.hits, 2);
    assert_eq!(after_second.misses, 0);

    // The other synchronous entry points share the same prepared page.
    let _ = document
        .text_character_range(
            0,
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height,
        )
        .expect("box range");
    let _ = document.text_range_string(0, 0, 10).expect("range string");
    let after_range = document.text_page_cache_stats();
    assert_eq!(
        after_range.loads, 1,
        "box→range and range→string reuse the page"
    );
}

#[test]
fn an_evicted_page_is_a_typed_miss_until_the_background_warm_refills_it() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium is not available");
        return;
    }
    let (_engine, document) = open("index-past-120.pdf");
    let record = document.text_page(0).expect("load page 0");
    let local = local_selection(&record);
    let first = record.chars.first().expect("fixture page has text");
    let point = Point::new(
        first.x_pt + first.width_pt / 2.0,
        first.y_pt + first.height_pt / 2.0,
    );
    let box_rect = Rect::new(first.x_pt, first.y_pt, first.width_pt, first.height_pt);

    // What the prepared Rust cache answers before eviction.
    let warm_index = document
        .text_character_index(0, point.x, point.y, false)
        .expect("warm hit test");
    let warm_range = document
        .text_character_range(
            0,
            box_rect.origin.x,
            box_rect.origin.y,
            box_rect.size.width,
            box_rect.size.height,
        )
        .expect("warm box range");
    let warm_string = document
        .text_range_string(0, 0, 20)
        .expect("warm range string");

    // Five more pages fill the five-entry LRU and evict page 0.
    for page in 1..=5 {
        document.text_page(page).expect("load page");
    }
    let evicted = document.text_page_cache_stats();
    assert!(!evicted.pages.contains(&0), "page 0 must be evicted");
    assert_eq!(evicted.entries, 5);
    assert_eq!(evicted.loads, 6);

    // A pointer event on the evicted page must answer "not prepared" without extracting.
    let miss_index = document
        .text_character_index(0, point.x, point.y, false)
        .expect("miss hit test");
    let miss_range = document
        .text_character_range(
            0,
            box_rect.origin.x,
            box_rect.origin.y,
            box_rect.size.width,
            box_rect.size.height,
        )
        .expect("miss box range");
    let miss_string = document
        .text_range_string(0, 0, 20)
        .expect("miss range string");
    let after_miss = document.text_page_cache_stats();
    assert!(miss_index.is_none(), "an evicted page is not prepared");
    assert!(miss_range.is_none(), "an evicted page is not prepared");
    assert!(miss_string.is_none(), "an evicted page is not prepared");
    assert_eq!(
        after_miss.loads, evicted.loads,
        "the evicted synchronous path never extracts"
    );
    assert_eq!(after_miss.misses, 3);
    assert_eq!(
        after_miss.pages, evicted.pages,
        "a miss must not disturb the LRU"
    );

    // The local model the shell falls back to gives exactly the prepared answers.
    assert_eq!(
        local.char_index_at(point, false).map(|index| index.0),
        warm_index,
        "the Swift-parity fallback matches the prepared Rust index"
    );
    assert_eq!(
        local
            .character_range(box_rect)
            .map(|(first, last)| (first.0, last.0)),
        warm_range.map(|range| (range.start, range.end)),
        "the Swift-parity fallback matches the prepared Rust range"
    );
    assert_eq!(
        Some(local.string_in_range(0, 20)),
        warm_string,
        "the Swift-parity fallback matches the prepared Rust string"
    );

    // The cheap background warm the shell uses after a miss refills the same page.
    let _ = document.text_page(0).expect("warm page 0 again");
    let warmed = document.text_page_cache_stats();
    assert_eq!(warmed.loads, after_miss.loads + 1);
    assert!(warmed.pages.contains(&0));
    assert_eq!(
        document
            .text_character_index(0, point.x, point.y, false)
            .expect("warm hit test"),
        warm_index
    );
    assert_eq!(
        document
            .text_character_range(
                0,
                box_rect.origin.x,
                box_rect.origin.y,
                box_rect.size.width,
                box_rect.size.height,
            )
            .expect("warm box range")
            .map(|range| (range.start, range.end)),
        warm_range.map(|range| (range.start, range.end))
    );
    assert_eq!(
        document
            .text_range_string(0, 0, 20)
            .expect("warm range string"),
        warm_string
    );
    let after_warm = document.text_page_cache_stats();
    assert_eq!(
        after_warm.loads, warmed.loads,
        "the re-prepared page answers without another extraction"
    );
}

#[test]
fn an_oversized_page_is_retained_alone_instead_of_re_extracting_on_every_event() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium is not available");
        return;
    }
    // Synthetic, committed fixture: page 0 carries 57,600 identical glyphs, far above the
    // whole-cache byte budget; page 1 is an ordinary page. No corpus is needed.
    let (_engine, document) = open("text-page-oversized.pdf");
    assert_eq!(document.page_count(), 2);
    // Even an above-budget page must answer "not prepared" before its first load: the
    // synchronous path does not get to discover the size, because it never extracts.
    let cold = document
        .text_character_index(0, 100.0, 100.0, false)
        .expect("cold hit test");
    assert!(cold.is_none(), "a cold oversized page is not prepared");
    let cold_stats = document.text_page_cache_stats();
    assert_eq!(cold_stats.loads, 0, "a cold oversized query never extracts");
    assert_eq!(cold_stats.entries, 0);
    assert_eq!(cold_stats.misses, 1);
    let oversized = document.text_page(0).expect("load oversized page");
    assert!(
        oversized.chars.len() > 40_000,
        "fixture page is large: {} chars",
        oversized.chars.len()
    );
    let loaded = document.text_page_cache_stats();
    assert_eq!(
        loaded.entries, 1,
        "the oversized page is retained by itself"
    );
    assert_eq!(loaded.pages, vec![0]);
    assert!(
        loaded.bytes > loaded.max_bytes,
        "the single-entry exception necessarily exceeds the soft budget: {} > {}",
        loaded.bytes,
        loaded.max_bytes
    );
    assert_eq!(loaded.loads, 1);
    assert_eq!(loaded.evictions, 0);

    // Its own pointer events must be served by the retained page, not re-extracted.
    let local = local_selection(&oversized);
    let first = oversized.chars.first().expect("fixture page has text");
    let point = Point::new(
        first.x_pt + first.width_pt / 2.0,
        first.y_pt + first.height_pt / 2.0,
    );
    let first_index = document
        .text_character_index(0, point.x, point.y, false)
        .expect("hit test");
    assert_eq!(
        first_index,
        local.char_index_at(point, false).map(|index| index.0),
        "the retained page matches the Swift-parity fallback"
    );
    let after_hit = document.text_page_cache_stats();
    assert_eq!(
        after_hit.loads, loaded.loads,
        "an event on the retained oversized page must not extract"
    );
    assert_eq!(after_hit.hits, 1);

    // A normal page that fits drops the exception instead of being starved by it.
    let small = document.text_page(1).expect("load ordinary page");
    assert!(!small.chars.is_empty());
    let replaced = document.text_page_cache_stats();
    assert_eq!(replaced.entries, 1);
    assert_eq!(replaced.pages, vec![1]);
    assert!(replaced.bytes <= replaced.max_bytes);
    assert_eq!(replaced.evictions, 1, "the oversized exception was evicted");
    assert_eq!(replaced.loads, 2);

    // Loading the oversized page again makes it the sole entry once more.
    let _ = document.text_page(0).expect("reload oversized page");
    let reloaded = document.text_page_cache_stats();
    assert_eq!(reloaded.entries, 1);
    assert_eq!(reloaded.pages, vec![0]);
    assert!(reloaded.bytes > reloaded.max_bytes);
    assert_eq!(reloaded.evictions, 2);
    assert_eq!(reloaded.loads, 3);
}

#[test]
fn cache_keeps_five_pages_and_evicts_the_oldest() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium is not available");
        return;
    }
    let (_engine, document) = open("index-past-120.pdf");
    for page in 0..6 {
        document.text_page(page).expect("fixture page");
    }
    let stats = document.text_page_cache_stats();
    assert_eq!(stats.max_entries, 5);
    assert!(stats.entries <= 5, "entries={}", stats.entries);
    assert_eq!(stats.entries, 5);
    assert_eq!(stats.evictions, 1, "the first page was evicted");
    assert_eq!(stats.pages, vec![1, 2, 3, 4, 5], "oldest first");
    assert!(stats.bytes <= stats.max_bytes, "bytes={}", stats.bytes);
    assert_eq!(stats.max_bytes, 1_572_864);
    assert_eq!(stats.loads, 6, "one extraction per loading-path call");

    // Touching an older page makes it most-recently used, so page 2 survives the next insert.
    let size = document.page_size_pt(2).expect("page size");
    let _ = document
        .text_character_index(2, size.width_pt / 2.0, size.height_pt / 2.0, false)
        .expect("hit test");
    let touched = document.text_page_cache_stats();
    assert_eq!(touched.loads, 6, "a cache hit does not extract");
    assert_eq!(touched.hits, 1);
    document.text_page(6).expect("seventh page");
    let stats = document.text_page_cache_stats();
    assert_eq!(
        stats.pages,
        vec![3, 4, 5, 2, 6],
        "page 2 was refreshed and page 1 evicted"
    );
}

#[test]
fn an_out_of_range_sync_query_is_an_error_not_a_miss() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium is not available");
        return;
    }
    let (_engine, document) = open("multipage.pdf");
    let page = document.page_count();
    let error = document
        .text_character_index(page, 10.0, 10.0, false)
        .expect_err("out-of-range page");
    let lyra_reader_ffi::api::LyraReaderFfiError::InvalidArgument { message, .. } = error else {
        panic!("out-of-range page must be InvalidArgument");
    };
    assert_eq!(
        message,
        lyra_reader_core::page_out_of_range_message(page, document.page_count())
    );
    let stats = document.text_page_cache_stats();
    assert_eq!(stats.loads, 0, "a rejected page must not extract");
    assert_eq!(stats.misses, 0, "a rejected page is not a cache miss");
}

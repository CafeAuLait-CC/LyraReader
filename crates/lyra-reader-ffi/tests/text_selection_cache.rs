//! The per-document selection cache: one PDFium read for the first pointer event, none after,
//! and a five-page byte-bounded LRU.
//!
//! These tests use committed fixtures and are skipped, with an announcement, when PDFium is not
//! available (the same convention as the other FFI integration tests).

use lyra_reader_ffi::api::LyraReaderEngine;
use std::path::PathBuf;

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

fn open(
    name: &str,
) -> (
    std::sync::Arc<LyraReaderEngine>,
    std::sync::Arc<lyra_reader_ffi::api::LyraReaderDocument>,
) {
    let engine = LyraReaderEngine::new();
    let document = engine
        .open_document(fixture(name).display().to_string(), None)
        .expect("open fixture");
    (engine, document)
}

#[test]
fn second_hit_on_the_same_page_does_not_read_pdfium_again() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium is not available");
        return;
    }
    let (_engine, document) = open("multipage.pdf");
    let before = document.text_page_cache_stats();
    assert_eq!(before.loads, 0);
    assert_eq!(before.entries, 0);

    // A press in the middle of page 0: a cache miss, so one extraction.
    let size = document.page_size_pt(0).expect("page size");
    let first = document
        .text_character_index(0, size.width_pt / 2.0, size.height_pt / 2.0, false)
        .expect("hit test");
    let after_first = document.text_page_cache_stats();
    assert_eq!(after_first.loads, 1, "the first hit extracts the page once");
    assert_eq!(after_first.entries, 1);

    // The second event is the one the shell actually pays on every drag step.
    let second = document
        .text_character_index(0, size.width_pt / 2.0, size.height_pt / 2.0, false)
        .expect("hit test");
    let after_second = document.text_page_cache_stats();
    assert_eq!(first, second, "the same point returns the same character");
    assert_eq!(
        after_second.loads, after_first.loads,
        "the second hit must not enter PDFium"
    );
    assert_eq!(after_second.hits, 1);

    // The other cached entry points share the page, not a fresh extraction.
    let range = document
        .text_character_range(0, size.width_pt / 4.0, size.height_pt / 4.0, 20.0, 20.0)
        .expect("box range");
    if let Some(range) = range {
        let _ = document
            .text_range_string(0, range.start, range.end)
            .expect("range string");
    }
    let after_range = document.text_page_cache_stats();
    assert_eq!(
        after_range.loads, 1,
        "box→range and range→string reuse the page"
    );
}

#[test]
fn text_page_warms_the_selection_cache_for_the_first_pointer_event() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium is not available");
        return;
    }
    let (_engine, document) = open("multipage.pdf");
    // The shell loads the page before anyone can point at it.
    let text = document.text_page(0).expect("text page");
    let stats = document.text_page_cache_stats();
    assert_eq!(
        stats.entries, 1,
        "loading the page retains its selection geometry"
    );
    assert_eq!(stats.loads, 0, "a load is not a hit-test miss");
    let first_char = text.chars.first().expect("fixture page has text");
    let _ = document
        .text_character_index(
            0,
            first_char.x_pt + first_char.width_pt / 2.0,
            first_char.y_pt + first_char.height_pt / 2.0,
            false,
        )
        .expect("hit test");
    let stats = document.text_page_cache_stats();
    assert_eq!(stats.loads, 0, "the warmed page is served without PDFium");
    assert_eq!(stats.hits, 1);
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

    // Touching an older page makes it most-recently used, so page 2 survives the next insert.
    let size = document.page_size_pt(2).expect("page size");
    let _ = document
        .text_character_index(2, size.width_pt / 2.0, size.height_pt / 2.0, false)
        .expect("hit test");
    document.text_page(6).expect("seventh page");
    let stats = document.text_page_cache_stats();
    assert_eq!(
        stats.pages,
        vec![3, 4, 5, 2, 6],
        "page 2 was refreshed and page 1 evicted"
    );
}

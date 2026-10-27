//! Region-text parity fixture (C1-style).
//!
//! The fixture holds the five frozen synthetic C1 pages and 240 rectangles. Its expectation
//! fields were written by the pre-change Swift `AIRegionText.extract`, before that path moved to
//! `lyra_reader_text::selection::region_text`. The test proves the Rust rectangle-coverage
//! selection reproduces every stored string and truncation flag exactly.
//!
//! The quads are anchored on real glyph boxes and deliberately include the C1 fixture's invalid
//! scalars, zero-sized boxes and out-of-page glyphs. They are synthetic: no corpus text and no
//! PDF are involved.

use lyra_reader_core::{Point, Rect};
use lyra_reader_text::{CharBox, region_text};
use serde_json::Value;
use std::path::PathBuf;

fn fixture() -> PathBuf {
    if let Some(override_dir) = std::env::var_os("LYRA_READER_TEST_FIXTURES")
        && !override_dir.is_empty()
    {
        let candidate = PathBuf::from(override_dir).join("region-text-parity.json");
        if candidate.is_file() {
            return candidate;
        }
    }
    if let Ok(current) = std::env::current_dir() {
        for ancestor in current.ancestors() {
            let candidate = ancestor
                .join("tests/fixtures")
                .join("region-text-parity.json");
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    panic!("region-text-parity.json not found");
}

fn number(value: &Value) -> f64 {
    value.as_f64().expect("number")
}

#[test]
fn rust_region_text_matches_the_frozen_swift_expectations() {
    let data = std::fs::read_to_string(fixture()).expect("read region parity fixture");
    let root: Value = serde_json::from_str(&data).expect("parse region parity fixture");
    let pages = root["pages"].as_array().expect("pages");
    let quads = root["quads"].as_array().expect("quads");
    assert_eq!(pages.len(), 5);

    let mut chars_by_page: Vec<Vec<CharBox>> = Vec::new();
    for raw_page in pages {
        let mut chars = Vec::new();
        for row in raw_page["chars"].as_array().expect("chars") {
            let row = row.as_array().expect("char row");
            let x = number(&row[1]);
            let y = number(&row[2]);
            let width = number(&row[3]);
            let height = number(&row[4]);
            chars.push(CharBox {
                rect: Rect::new(x, y, width, height),
                origin: Point::new(x, y),
                unicode: row[0].as_u64().expect("unicode") as u32,
                font_size: height,
                logical_order: 0,
            });
        }
        chars_by_page.push(chars);
    }

    let mut mismatches = 0;
    let mut examples = Vec::new();
    let mut nonempty = 0;
    let mut truncated = 0;
    for (index, quad) in quads.iter().enumerate() {
        let page = quad["page"].as_u64().expect("quad page") as usize;
        let rect = Rect::new(
            number(&quad["x"]),
            number(&quad["y"]),
            number(&quad["w"]),
            number(&quad["h"]),
        );
        let limit = quad["limit"].as_u64().expect("quad limit") as usize;
        let (text, was_truncated) = region_text(&chars_by_page[page], rect, limit);
        let expected = quad["swift_text"].as_str().expect("swift_text");
        if !expected.is_empty() {
            nonempty += 1;
        }
        if quad["swift_truncated"].as_bool().expect("swift_truncated") {
            truncated += 1;
        }
        if text != expected
            || was_truncated != quad["swift_truncated"].as_bool().expect("swift_truncated")
        {
            mismatches += 1;
            if examples.len() < 8 {
                examples.push(format!(
                    "quad {index} p{page} rect=({}, {}, {}, {}) limit={limit} Swift={expected:?}/{} Rust={text:?}/{was_truncated}",
                    rect.min_x(),
                    rect.min_y(),
                    rect.size.width,
                    rect.size.height,
                    quad["swift_truncated"].as_bool().unwrap_or(false),
                ));
            }
        }
        assert_eq!(
            quad["swift_utf8_len"].as_u64().expect("swift_utf8_len"),
            expected.len() as u64,
            "fixture length is self-consistent at quad {index}"
        );
    }

    assert!(
        nonempty >= 200,
        "the fixture must exercise at least 200 non-empty quads, got {nonempty}"
    );
    assert!(
        truncated >= 1,
        "the fixture must pin at least one truncated extraction"
    );
    assert!(
        mismatches == 0,
        "{mismatches} region-text mismatch(es); first examples:\n{}",
        examples.join("\n")
    );
    println!(
        "PASS: {} region quads ({nonempty} non-empty, {truncated} truncated) match the frozen Swift expectations",
        quads.len()
    );
}

/// The FFI path must use the same rectangle-coverage selection on a real PDF, not only the
/// synthetic page model. The expected text is the pre-change Swift extraction stored with the
/// AI plan goldens for the same `text-page.pdf` rectangle.
#[test]
fn ffi_region_text_matches_the_pre_change_swift_text_on_a_pdf() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium is not available");
        return;
    }
    let goldens = fixture().with_file_name("ai-plan-goldens.json");
    let data = std::fs::read_to_string(&goldens).expect("read AI plan goldens");
    let root: Value = serde_json::from_str(&data).expect("parse AI plan goldens");
    let region = &root["region_question"];
    let rect = region["region_rect"].as_array().expect("region rect");
    let expected = region["region_text"].as_str().expect("region text");
    let expected_truncated = region["region_truncated"]
        .as_bool()
        .expect("region truncated");

    let pdf = fixture().with_file_name("text-page.pdf");
    let engine = lyra_reader_ffi::api::LyraReaderEngine::new();
    let document = engine
        .open_document(pdf.display().to_string(), None)
        .expect("open text-page.pdf");
    let actual = document
        .region_text(
            0,
            number(&rect[0]),
            number(&rect[1]),
            number(&rect[2]),
            number(&rect[3]),
        )
        .expect("extract region text");
    assert_eq!(actual.text, expected);
    assert_eq!(actual.truncated, expected_truncated);
}

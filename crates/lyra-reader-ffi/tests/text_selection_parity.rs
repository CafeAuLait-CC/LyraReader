//! C1 frozen parity fixture, Rust half.
//!
//! The fixture holds five synthetic pages and 2,500 points. Its expectation fields were written
//! by the Swift reference (`LyraReaderChecks --write-text-selection-parity`) and are checked by
//! both implementations:
//!
//! * this test proves the Rust line-aware path reproduces every stored Swift answer;
//! * `LyraReaderChecks --check-text-selection-parity` proves the Swift reference still does.
//!
//! The live corpus comparison is `scripts/bench-hit-test.sh`, which runs both implementations on
//! the same PDF pages. This fixture exists so the rules stay pinned without a PDF or the
//! copyrighted sample corpus.

use lyra_reader_core::{PageIndex, Point, Rect};
use lyra_reader_text::{CharBox, SelectionTextPage, TextPage};
use serde_json::Value;
use std::path::PathBuf;

fn fixture() -> PathBuf {
    if let Some(override_dir) = std::env::var_os("LYRA_READER_TEST_FIXTURES")
        && !override_dir.is_empty()
    {
        let candidate = PathBuf::from(override_dir).join("text-selection-parity.json");
        if candidate.is_file() {
            return candidate;
        }
    }
    if let Ok(current) = std::env::current_dir() {
        for ancestor in current.ancestors() {
            let candidate = ancestor
                .join("tests/fixtures")
                .join("text-selection-parity.json");
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    panic!("text-selection-parity.json not found");
}

fn optional_u32(value: &Value) -> Option<u32> {
    value.as_u64().map(|value| value as u32)
}

fn number(value: &Value) -> f64 {
    value.as_f64().expect("number")
}

fn string_hash(value: &str) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in value.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    hash
}

#[test]
fn rust_line_aware_selection_matches_the_frozen_swift_expectations() {
    let data = std::fs::read_to_string(fixture()).expect("read parity fixture");
    let root: Value = serde_json::from_str(&data).expect("parse parity fixture");
    let pages = root["pages"].as_array().expect("pages");
    let points = root["points"].as_array().expect("points");
    assert_eq!(pages.len(), 5);
    assert_eq!(points.len(), 2500);

    let mut selections = Vec::new();
    for raw_page in pages {
        let page_index = raw_page["page"].as_u64().expect("page id") as u32;
        let mut chars = Vec::new();
        for row in raw_page["chars"].as_array().expect("chars") {
            let row = row.as_array().expect("char row");
            chars.push(CharBox {
                rect: Rect::new(
                    number(&row[1]),
                    number(&row[2]),
                    number(&row[3]),
                    number(&row[4]),
                ),
                origin: Point::new(number(&row[1]), number(&row[2])),
                unicode: row[0].as_u64().expect("unicode") as u32,
                font_size: number(&row[4]),
                logical_order: 0,
            });
        }
        selections.push(SelectionTextPage::new(TextPage {
            page: PageIndex(page_index),
            chars,
            blocks: Vec::new(),
            text: String::new(),
            is_generated: false,
            has_unicode_map_error: false,
        }));
    }

    let mut index_mismatches = 0;
    let mut drag_mismatches = 0;
    let mut box_mismatches = 0;
    let mut string_mismatches = 0;
    let mut examples = Vec::new();
    let mut string_checks = 0;
    for point in points {
        let page_id = point["page"].as_u64().expect("point page") as usize;
        let page = &selections[page_id];
        let x = number(&point["x"]);
        let y = number(&point["y"]);
        let location = Point::new(x, y);
        let index = page.char_index_at(location, false).map(|index| index.0);
        let drag = page.char_index_at(location, true).map(|index| index.0);
        if index != optional_u32(&point["swift_index"]) {
            index_mismatches += 1;
            if examples.len() < 8 {
                examples.push(format!(
                    "index p{page_id} ({x:.2},{y:.2}) Swift={:?} Rust={index:?}",
                    optional_u32(&point["swift_index"])
                ));
            }
        }
        if drag != optional_u32(&point["swift_drag_index"]) {
            drag_mismatches += 1;
        }

        let box_width = number(&point["box_w"]);
        let box_height = number(&point["box_h"]);
        let range = page
            .character_range(Rect::new(
                x - box_width / 2.0,
                y - box_height / 2.0,
                box_width,
                box_height,
            ))
            .map(|(first, last)| (first.0, last.0));
        let expected_first = optional_u32(&point["swift_box_first"]);
        let expected_last = optional_u32(&point["swift_box_last"]);
        if range.map(|range| range.0) != expected_first
            || range.map(|range| range.1) != expected_last
        {
            box_mismatches += 1;
            if examples.len() < 8 {
                examples.push(format!(
                    "box p{page_id} ({x:.2},{y:.2}) Swift={expected_first:?}…{expected_last:?} Rust={range:?}"
                ));
            }
        }

        let text = range
            .map(|(first, last)| page.string_in_range(first, last))
            .unwrap_or_default();
        let expected_hash = point["swift_string_hash"]
            .as_str()
            .and_then(|hash| u64::from_str_radix(hash, 16).ok());
        if expected_hash != Some(string_hash(&text))
            || point["swift_string_len"].as_u64() != Some(text.len() as u64)
        {
            string_mismatches += 1;
            if examples.len() < 8 {
                examples.push(format!(
                    "string p{page_id} {range:?} Swift hash={expected_hash:?}/{} Rust={:016x}/{}",
                    point["swift_string_len"].as_u64().unwrap_or(0),
                    string_hash(&text),
                    text.len()
                ));
            }
        }
        string_checks += 1;
    }

    let mut range_checks = 0;
    let mut range_mismatches = 0;
    for record in root["string_ranges"].as_array().expect("string_ranges") {
        let page_id = record["page"].as_u64().expect("range page") as usize;
        let start = record["start"].as_u64().expect("range start") as u32;
        let end = record["end"].as_u64().expect("range end") as u32;
        let text = selections[page_id].string_in_range(start, end);
        let expected_hash = record["swift_string_hash"]
            .as_str()
            .and_then(|hash| u64::from_str_radix(hash, 16).ok());
        if expected_hash != Some(string_hash(&text))
            || record["swift_string_len"].as_u64() != Some(text.len() as u64)
        {
            range_mismatches += 1;
            if examples.len() < 8 {
                examples.push(format!(
                    "fixed range p{page_id} {start}…{end} Swift hash={expected_hash:?} Rust={:016x}",
                    string_hash(&text)
                ));
            }
        }
        range_checks += 1;
    }

    assert_eq!(
        index_mismatches + drag_mismatches + box_mismatches + string_mismatches + range_mismatches,
        0,
        "{} index, {} drag, {} box, {} string, {} fixed-range mismatch(es):\n{}",
        index_mismatches,
        drag_mismatches,
        box_mismatches,
        string_mismatches,
        range_mismatches,
        examples.join("\n")
    );
    assert_eq!(string_checks, 2500);
    assert_eq!(range_checks, 25);
}

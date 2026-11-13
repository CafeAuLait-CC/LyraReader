//! Thin JSON adapter for the shared text-layout helper on an immutable render source.
use lyra_reader_core::Rect;
use lyra_reader_ffi::api::LyraReaderDocument;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct BoxRecord {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}
#[derive(Deserialize)]
struct Entry {
    id: String,
    boxes: Vec<BoxRecord>,
}

pub(super) fn query(
    engine: &LyraReaderDocument,
    page: u32,
    entries: &Value,
) -> Result<Value, String> {
    let values = entries.as_array().ok_or("Missing inline-note entries")?;
    // Check caller-controlled counts before deserializing another owned copy.
    if values.len() > lyra_reader_text::MAX_INLINE_NOTE_MARKERS
        || values
            .iter()
            .try_fold(0usize, |count, item| {
                let id = item["id"].as_str()?;
                if id.is_empty() || id.len() > 256 {
                    return None;
                }
                count.checked_add(item["boxes"].as_array()?.len())
            })
            .is_none_or(|count| count > lyra_reader_text::MAX_INLINE_NOTE_BOXES)
    {
        return Err("The inline-note entries exceed their safe size limits".into());
    }
    let entries: Vec<Entry> = serde_json::from_value(entries.clone()).map_err(|e| e.to_string())?;
    let boxes = entries
        .iter()
        .map(|entry| {
            entry
                .boxes
                .iter()
                .map(|b| Rect::new(b.x, b.y, b.width, b.height))
                .collect()
        })
        .collect::<Vec<_>>();
    let prepared = engine
        .prepared_selection_text_page(page)
        .map_err(|e| e.to_string())?;
    let markers =
        lyra_reader_text::inline_note_markers(prepared.as_ref().map(|p| p.layout()), &boxes)?;
    Ok(
        json!({"prepared":prepared.is_some(),"markers":entries.iter().zip(markers).filter_map(|(entry,rect)|rect.map(|r|json!({"id":entry.id,"rect":{"x":r.min_x(),"y":r.min_y(),"width":r.size.width,"height":r.size.height}}))).collect::<Vec<_>>()}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use lyra_reader_ffi::api::LyraReaderEngine;

    #[test]
    fn cached_lookup_distinguishes_unprepared_and_never_extracts_or_rasterizes() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/text-page.pdf");
        let engine = LyraReaderEngine::new()
            .open_document(path.to_string_lossy().into_owned(), None)
            .unwrap();
        let entries = json!([{"id":"synthetic-comment","boxes":[{"x":160.0,"y":70.0,"width":10.0,"height":12.0}]}]);
        assert_eq!(query(&engine, 0, &entries).unwrap()["prepared"], false);
        assert_eq!(engine.text_page_cache_stats().loads, 0);
        let page = engine.text_page(0).unwrap();
        let ink: Vec<_> = page
            .chars
            .iter()
            .filter(|c| {
                c.width_pt > 0.0
                    && c.height_pt > 0.0
                    && c.unicode != 32
                    && c.unicode != 10
                    && c.unicode != 13
            })
            .collect();
        let first = ink[0];
        let last = ink
            .iter()
            .find(|c| c.x_pt > first.x_pt + 30.0 && (c.y_pt - first.y_pt).abs() < 2.0)
            .unwrap();
        let entries = json!([{"id":"synthetic-comment","boxes":[{"x":last.x_pt,"y":last.y_pt,"width":last.width_pt,"height":last.height_pt}]}]);
        let loads = engine.text_page_cache_stats().loads;
        for _ in 0..4 {
            let result = query(&engine, 0, &entries).unwrap();
            assert_eq!(result["prepared"], true);
            let x = result["markers"][0]["rect"]["x"].as_f64().unwrap();
            assert!((x - (first.x_pt - 30.0).max(2.0)).abs() < 1e-6);
        }
        assert_eq!(engine.text_page_cache_stats().loads, loads);
        assert!(query(&engine, 99, &entries).unwrap_err().contains("page"));
        assert!(query(&engine, 0, &json!([{"id":"", "boxes":[]}])).is_err());
        assert!(
            query(
                &engine,
                0,
                &json!([{"id":"bad", "boxes":[{"x":0,"y":0,"width":"bad","height":1}]}])
            )
            .is_err()
        );
    }
}

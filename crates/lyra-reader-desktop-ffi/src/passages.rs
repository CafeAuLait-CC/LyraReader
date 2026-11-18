//! Bounded, read-only annotation context on an immutable render revision.
use lyra_reader_ffi::{
    api::{AiSourceRectRecord, LyraReaderDocument},
    passages::AnnotationContextSpanRecord,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashSet;
const MAX_ENTRIES: usize = 512;
const MAX_REGIONS: usize = 8192;
const MAX_OUTPUT: usize = 1 << 20;
#[derive(Deserialize)]
struct Entry {
    id: String,
    start: Option<u32>,
    end: Option<u32>,
    #[serde(default)]
    regions: Vec<AiSourceRectRecord>,
}
pub(super) fn query(
    engine: &LyraReaderDocument,
    page: u32,
    values: &Value,
) -> Result<Value, String> {
    let items = values
        .as_array()
        .ok_or("Missing annotation context entries.")?;
    let total_regions = items.iter().try_fold(0usize, |n, item| {
        n.checked_add(item["regions"].as_array()?.len())
    });
    if items.len() > MAX_ENTRIES
        || items.iter().any(|v| {
            v["id"]
                .as_str()
                .is_none_or(|id| id.is_empty() || id.len() > 256)
        })
        || total_regions.is_none_or(|n| n > MAX_REGIONS)
    {
        return Err("The annotation context entries exceed their safe limits.".into());
    }
    let total_regions = total_regions.ok_or("Missing annotation context regions.")?;
    let entries: Vec<Entry> = serde_json::from_value(values.clone()).map_err(|e| e.to_string())?;
    let mut ids = HashSet::new();
    if entries.iter().any(|e| !ids.insert(e.id.as_str())) {
        return Err("Duplicate annotation context identities are not valid.".into());
    }
    if entries.is_empty() {
        return Ok(json!({"entries":[],"warnings":[]}));
    }
    let map = engine
        .annotation_text_map(page)
        .map_err(|e| e.to_string())?;
    if (map.source_character_count() as usize)
        .checked_mul(total_regions)
        .is_none_or(|n| n > 16 << 20)
    {
        return Err("Annotation context exceeds the page geometry work budget.".into());
    }
    let mut rows = Vec::new();
    let mut warnings = Vec::new();
    let mut used = 0usize;
    for entry in entries {
        let make = || -> Result<Option<(Value, usize)>, String> {
            let span = if !entry.regions.is_empty() {
                map.regions_span(entry.regions.clone())
            } else {
                let Some((start, end)) = entry.start.zip(entry.end) else {
                    return Ok(None);
                };
                let end = end
                    .checked_add(1)
                    .ok_or("The annotation source end is invalid.")?;
                map.source_span(start, end)
            }
            .map_err(|e| e.to_string())?;
            let Some(span) = span else {
                return Ok(None);
            };
            let context = map.context_span(span, None).map_err(|e| e.to_string())?;
            let quote = map.text_in_span(span).map_err(|e| e.to_string())?;
            let text = map.text_in_span(context).map_err(|e| e.to_string())?;
            let bytes = quote
                .len()
                .checked_add(text.len())
                .ok_or("The annotation context size overflowed.")?;
            Ok(Some((
                json!({"id":entry.id,"page":page,"quote":quote,"context":text,"start":span.start-context.start,"end":span.end-context.start,"span":context}),
                bytes,
            )))
        };
        match make() {
            Ok(Some((row, bytes))) => {
                if used.checked_add(bytes).is_none_or(|n| n > MAX_OUTPUT) {
                    warnings.push(json!({"id":entry.id,"message":"This page exceeds the annotation context display budget."}));
                    continue;
                }
                used += bytes;
                rows.push(row);
            }
            Ok(None) => {}
            Err(message) => warnings.push(json!({"id":entry.id,"message":message})),
        }
    }
    let ranges = rows
        .iter()
        .map(|r| {
            serde_json::from_value::<AnnotationContextSpanRecord>(r["span"].clone())
                .map_err(|e| e.to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    let clusters = lyra_reader_ffi::passages::annotation_context_clusters(ranges)
        .map_err(|e| e.to_string())?;
    Ok(
        json!({"entries":rows,"clusters":clusters,"warnings":warnings,"sentence_boundary_provider":"unicode-uax29"}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use lyra_reader_ffi::api::LyraReaderEngine;
    fn engine() -> std::sync::Arc<LyraReaderDocument> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/text-page.pdf");
        LyraReaderEngine::new()
            .open_document(path.to_string_lossy().into_owned(), None)
            .unwrap()
    }
    #[test]
    fn own_ranges_and_pdf_quads_identify_the_same_words_without_a_placeholder_range() {
        let engine = engine();
        let page = engine.text_page(0).unwrap();
        let scalars = page.chars.iter().map(|c| c.unicode).collect::<Vec<_>>();
        let target = "quick".chars().map(|c| c as u32).collect::<Vec<_>>();
        let start = scalars
            .windows(target.len())
            .position(|w| w == target)
            .unwrap();
        let regions=page.chars[start..start+target.len()].iter().map(|c|json!({"x_pt":c.x_pt,"y_pt":c.y_pt,"width_pt":c.width_pt,"height_pt":c.height_pt})).collect::<Vec<_>>();
        let result=query(&engine,0,&json!([{"id":"own","start":start,"end":start+4,"regions":[]},{"id":"file","start":0,"end":0,"regions":regions}])).unwrap();
        let rows = result["entries"].as_array().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["quote"], "quick");
        assert_eq!(rows[1]["quote"], "quick");
        assert_eq!(rows[0]["context"], rows[1]["context"]);
        assert!(rows[0]["context"].as_str().unwrap().contains("brown fox"));
        assert_eq!(result["clusters"].as_array().unwrap().len(), 1);
        let prefix = rows[0]["start"].as_u64().unwrap() as usize;
        let suffix = rows[0]["end"].as_u64().unwrap() as usize;
        let utf16 = rows[0]["context"]
            .as_str()
            .unwrap()
            .encode_utf16()
            .collect::<Vec<_>>();
        assert_eq!(String::from_utf16(&utf16[prefix..suffix]).unwrap(), "quick");
    }
    #[test]
    fn invalid_entries_are_isolated_and_request_budgets_are_checked_before_copying() {
        let engine = engine();
        let result=query(&engine,0,&json!([{"id":"invalid","start":0,"end":u32::MAX,"regions":[]},{"id":"valid","start":0,"end":3,"regions":[]}])).unwrap();
        assert_eq!(result["warnings"].as_array().unwrap().len(), 1);
        assert_eq!(result["entries"].as_array().unwrap().len(), 1);
        assert!(query(&engine,0,&json!([{"id":"duplicate","start":0,"end":1,"regions":[]},{"id":"duplicate","start":2,"end":3,"regions":[]}])).is_err());
        assert!(
            query(
                &engine,
                0,
                &json!(vec![json!({"id":"too-many","regions":[]}); MAX_ENTRIES + 1])
            )
            .is_err()
        );
        assert_eq!(query(&engine, 0, &json!([])).unwrap()["entries"], json!([]));
        assert!(
            query(
                &engine,
                engine.page_count(),
                &json!([{"id":"outside","start":0,"end":1,"regions":[]}])
            )
            .is_err()
        );
    }
}

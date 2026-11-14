//! Local layered-summary catalog and coverage over the shared macOS production builders.
//! Listing rows never extracts page text. Explicit inspection reads only one selected unit;
//! neither operation builds a prompt, opens a provider connection, or writes a cache.
use lyra_reader_ffi::api::*;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CatalogRequest {
    layer: AiSummaryLayerRecord,
    #[serde(default)]
    offset: u32,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct InspectRequest {
    layer: AiSummaryLayerRecord,
    index: u32,
}

#[derive(Serialize)]
struct Row {
    id: String,
    unit: AiSummaryUnitRequestRecord,
    link_page: Option<u32>,
    page_span: String,
}

struct Units {
    layer: AiSummaryLayerRecord,
    page_count: u32,
    sections: Vec<AiSummarySectionRecord>,
}

impl Units {
    fn new(document: &LyraReaderDocument, layer: AiSummaryLayerRecord) -> Result<Self, String> {
        let page_count = document.page_count();
        if page_count == 0 {
            return Err("This document has no pages.".into());
        }
        let sections = if layer == AiSummaryLayerRecord::Section {
            ai_summary_sections(
                document.outline().map_err(|error| error.to_string())?,
                page_count,
            )
        } else {
            Vec::new()
        };
        Ok(Self {
            layer,
            page_count,
            sections,
        })
    }

    fn len(&self) -> Result<u32, String> {
        match self.layer {
            AiSummaryLayerRecord::Abstract => Ok(1),
            AiSummaryLayerRecord::Section => u32::try_from(self.sections.len())
                .map_err(|_| "The summary outline has too many rows.".into()),
            AiSummaryLayerRecord::Page => Ok(self.page_count),
        }
    }

    fn row(&self, index: u32) -> Result<Row, String> {
        if index >= self.len()? {
            return Err("The summary row is outside this layer.".into());
        }
        let (id, title, number, depth, start, end, link, kind) = match self.layer {
            AiSummaryLayerRecord::Abstract => (
                "abstract".into(),
                "Abstract".into(),
                None,
                0,
                1,
                self.page_count,
                None,
                "abstract",
            ),
            AiSummaryLayerRecord::Section => {
                let position = usize::try_from(index).map_err(|_| "Invalid summary row index.")?;
                let section = self
                    .sections
                    .get(position)
                    .ok_or("The summary section is unavailable.")?;
                (
                    format!("section:{index}"),
                    section.title.clone(),
                    (!section.number.is_empty()).then(|| section.number.clone()),
                    section.depth,
                    section.page_start,
                    section.page_end,
                    Some(section.link_page),
                    "sections",
                )
            }
            AiSummaryLayerRecord::Page => {
                let page = index.checked_add(1).ok_or("Invalid summary page index.")?;
                (
                    format!("page:{page}"),
                    page_label(vec![page]),
                    None,
                    0,
                    page,
                    page,
                    Some(index),
                    "pages",
                )
            }
        };
        Ok(Row {
            id,
            unit: AiSummaryUnitRequestRecord {
                kind: self.layer,
                index,
                title,
                number,
                depth,
                page_start: start,
                page_end: end,
            },
            link_page: link,
            page_span: page_span_label(
                kind.into(),
                Vec::new(),
                start,
                end,
                0,
                false,
                self.page_count,
            ),
        })
    }
}

pub(crate) fn catalog(
    document: &LyraReaderDocument,
    request: CatalogRequest,
) -> Result<Value, String> {
    let units = Units::new(document, request.layer)?;
    let total = units.len()?;
    if request.offset >= total {
        return Err("The summary catalog offset is outside this layer.".into());
    }
    // Share the panel's existing batch bound without allocating a row for every page.
    let limits = ai_summary_limits();
    let remaining = total
        .checked_sub(request.offset)
        .ok_or("Invalid summary offset.")?;
    let count = remaining.min(limits.max_requests_per_batch);
    let mut rows = Vec::new();
    rows.try_reserve_exact(usize::try_from(count).map_err(|_| "Invalid summary row count.")?)
        .map_err(|_| "The summary catalog could not be allocated.")?;
    for step in 0..count {
        let index = request
            .offset
            .checked_add(step)
            .ok_or("Invalid summary row index.")?;
        rows.push(units.row(index)?);
    }
    let next = request
        .offset
        .checked_add(count)
        .ok_or("Invalid summary catalog end.")?;
    #[derive(Serialize)]
    struct Catalog {
        layer: AiSummaryLayerRecord,
        page_count: u32,
        offset: u32,
        total: u32,
        next_offset: Option<u32>,
        limits: AiSummaryLimitsRecord,
        rows: Vec<Row>,
    }
    serde_json::to_value(Catalog {
        layer: request.layer,
        page_count: units.page_count,
        offset: request.offset,
        total,
        next_offset: (next < total).then_some(next),
        limits,
        rows,
    })
    .map_err(|error| error.to_string())
}

pub(crate) fn inspect(
    document: &LyraReaderDocument,
    request: InspectRequest,
) -> Result<Value, String> {
    let units = Units::new(document, request.layer)?;
    let row = units.row(request.index)?;
    // Inspection ignores provider settings and builds no prompt or transport plan.
    let mut fingerprints = document
        .inspect_ai_summary(AiSummaryRequestRecord {
            layer: request.layer,
            units: vec![row.unit.clone()],
            language: None,
            document_title: String::new(),
            base_url: String::new(),
            model: String::new(),
            temperature: None,
            max_tokens: None,
            reasoning_mode: String::new(),
            reasoning_encoding: String::new(),
            document_knowledge_text: None,
            document_knowledge_pages: Vec::new(),
        })
        .map_err(|error| error.to_string())?;
    if fingerprints.len() != 1 {
        return Err("The summary inspection returned an unexpected unit count.".into());
    }
    let fingerprint = fingerprints
        .pop()
        .ok_or("The summary coverage is unavailable.")?;
    let kind = match request.layer {
        AiSummaryLayerRecord::Abstract => "abstract",
        AiSummaryLayerRecord::Section => "sections",
        AiSummaryLayerRecord::Page => "pages",
    };
    let span = page_span_label(
        kind.into(),
        fingerprint.pages.clone(),
        row.unit.page_start,
        row.unit.page_end,
        fingerprint.covered_page_end,
        fingerprint.truncated,
        units.page_count,
    );
    #[derive(Serialize)]
    struct Inspection {
        id: String,
        fingerprint: AiSummaryFingerprintRecord,
        page_span: String,
    }
    serde_json::to_value(Inspection {
        id: row.id,
        fingerprint,
        page_span: span,
    })
    .map_err(|error| error.to_string())
}

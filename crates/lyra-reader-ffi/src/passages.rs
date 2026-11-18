//! Immutable annotation context maps; platform tokenizers may supply their own sentence spans.
use crate::api::{
    AiSourceRectRecord, ErrorSeverity, LyraReaderDocument, LyraReaderFfiError, TextChar,
};
use lyra_reader_core::{Point, Rect};
use lyra_reader_text::{AnnotationTextMap, CharBox, MAX_PASSAGE_GLYPHS, PassageRange};
use std::sync::Arc;

/// Half-open UTF-16 offsets in readable passage text. PDF character ranges use separate APIs.
#[derive(Clone, Copy, Debug, uniffi::Record)]
#[cfg_attr(feature = "desktop-json", derive(serde::Serialize, serde::Deserialize))]
pub struct AnnotationContextSpanRecord {
    pub start: u32,
    pub end: u32,
}
impl From<PassageRange> for AnnotationContextSpanRecord {
    fn from(r: PassageRange) -> Self {
        Self {
            start: r.start,
            end: r.end,
        }
    }
}
impl From<AnnotationContextSpanRecord> for PassageRange {
    fn from(r: AnnotationContextSpanRecord) -> Self {
        Self {
            start: r.start,
            end: r.end,
        }
    }
}
fn invalid(message: String) -> LyraReaderFfiError {
    LyraReaderFfiError::InvalidArgument {
        message,
        severity: ErrorSeverity::Recoverable,
    }
}

#[derive(uniffi::Object)]
pub struct LyraReaderAnnotationTextMap {
    map: AnnotationTextMap,
}
#[uniffi::export]
impl LyraReaderAnnotationTextMap {
    pub fn source_character_count(&self) -> u32 {
        self.map.source_character_count()
    }
    pub fn text(&self) -> String {
        self.map.text().into()
    }
    pub fn source_span(
        &self,
        start: u32,
        end: u32,
    ) -> Result<Option<AnnotationContextSpanRecord>, LyraReaderFfiError> {
        self.map
            .span_for_range(start, end)
            .map(|r| r.map(Into::into))
            .map_err(invalid)
    }
    pub fn indices_span(
        &self,
        indices: Vec<u32>,
    ) -> Result<Option<AnnotationContextSpanRecord>, LyraReaderFfiError> {
        self.map
            .span_for_indices(&indices)
            .map(|r| r.map(Into::into))
            .map_err(invalid)
    }
    pub fn regions_span(
        &self,
        regions: Vec<AiSourceRectRecord>,
    ) -> Result<Option<AnnotationContextSpanRecord>, LyraReaderFfiError> {
        if regions.len() > 512 {
            return Err(invalid(
                "The annotation has too many context regions.".into(),
            ));
        }
        let regions = regions
            .into_iter()
            .map(|r| Rect::new(r.x_pt, r.y_pt, r.width_pt, r.height_pt))
            .collect::<Vec<_>>();
        self.map
            .span_for_regions(&regions)
            .map(|r| r.map(Into::into))
            .map_err(invalid)
    }
    pub fn context_span(
        &self,
        mark: AnnotationContextSpanRecord,
        sentences: Option<Vec<AnnotationContextSpanRecord>>,
    ) -> Result<AnnotationContextSpanRecord, LyraReaderFfiError> {
        if sentences.as_ref().is_some_and(|s| s.len() > 8192) {
            return Err(invalid(
                "The annotation has too many sentence boundaries.".into(),
            ));
        }
        let sentences = sentences.map(|s| s.into_iter().map(Into::into).collect::<Vec<_>>());
        self.map
            .context(mark.into(), sentences.as_deref())
            .map(Into::into)
            .map_err(invalid)
    }
    pub fn text_in_span(
        &self,
        span: AnnotationContextSpanRecord,
    ) -> Result<String, LyraReaderFfiError> {
        self.map
            .slice(span.into())
            .map(str::to_owned)
            .map_err(invalid)
    }
}
#[uniffi::export]
pub fn annotation_text_map_for_text(
    chars: Vec<TextChar>,
) -> Result<Arc<LyraReaderAnnotationTextMap>, LyraReaderFfiError> {
    if chars.len() > MAX_PASSAGE_GLYPHS {
        return Err(invalid(
            "This page has too much text for annotation context.".into(),
        ));
    }
    let chars = chars
        .into_iter()
        .map(|c| CharBox {
            unicode: c.unicode,
            rect: Rect::new(c.x_pt, c.y_pt, c.width_pt, c.height_pt),
            origin: Point::new(c.x_pt, c.y_pt),
            font_size: c.height_pt,
            logical_order: 0,
        })
        .collect::<Vec<_>>();
    AnnotationTextMap::new(&chars)
        .map(|map| Arc::new(LyraReaderAnnotationTextMap { map }))
        .map_err(invalid)
}
#[uniffi::export]
impl LyraReaderDocument {
    /// Explicit sidebar work, called on the host's worker queue. The selection cache
    /// intentionally retains no raw glyph geometry, so this does not inflate that cache.
    pub fn annotation_text_map(
        &self,
        page: u32,
    ) -> Result<Arc<LyraReaderAnnotationTextMap>, LyraReaderFfiError> {
        let page = self.extract_text_page(page)?;
        AnnotationTextMap::new(&page.chars)
            .map(|map| Arc::new(LyraReaderAnnotationTextMap { map }))
            .map_err(invalid)
    }
}

#[derive(Clone, Debug, uniffi::Record)]
#[cfg_attr(feature = "desktop-json", derive(serde::Serialize, serde::Deserialize))]
pub struct AnnotationContextClusterRecord {
    pub span: AnnotationContextSpanRecord,
    pub indices: Vec<u32>,
}
#[uniffi::export]
pub fn annotation_context_clusters(
    ranges: Vec<AnnotationContextSpanRecord>,
) -> Result<Vec<AnnotationContextClusterRecord>, LyraReaderFfiError> {
    if ranges.len() > 4096 {
        return Err(invalid(
            "The annotation has too many context ranges.".into(),
        ));
    }
    let ranges = ranges.into_iter().map(Into::into).collect::<Vec<_>>();
    lyra_reader_text::cluster_passages(&ranges)
        .map(|clusters| {
            clusters
                .into_iter()
                .map(|c| AnnotationContextClusterRecord {
                    span: c.span.into(),
                    indices: c.indices,
                })
                .collect()
        })
        .map_err(invalid)
}

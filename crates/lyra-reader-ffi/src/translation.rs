//! Typed translation geometry over the shared selection implementation.
use crate::api::{
    AiSourceRectRecord, ErrorSeverity, LyraReaderDocument, LyraReaderFfiError, TextChar,
};
use lyra_reader_core::{PageIndex, Point, Rect};
use lyra_reader_text::{CharBox, SelectionTextPage, TextPage, TranslationTarget};

#[derive(Clone, Debug, uniffi::Record)]
#[cfg_attr(feature = "desktop-json", derive(serde::Serialize, serde::Deserialize))]
pub struct TranslationTargetRecord {
    pub page: u32,
    pub start: u32,
    pub end: u32,
    pub rect: AiSourceRectRecord,
    pub line_rects: Vec<AiSourceRectRecord>,
    pub source_text: String,
    pub source_font_pt: f64,
    pub is_block: bool,
}
fn rect(r: Rect) -> AiSourceRectRecord {
    AiSourceRectRecord {
        x_pt: r.min_x(),
        y_pt: r.min_y(),
        width_pt: r.size.width,
        height_pt: r.size.height,
    }
}
fn record(t: TranslationTarget) -> TranslationTargetRecord {
    TranslationTargetRecord {
        page: t.page,
        start: t.start,
        end: t.end,
        rect: rect(t.rect),
        line_rects: t.line_rects.into_iter().map(rect).collect(),
        source_text: t.source_text,
        source_font_pt: t.source_font_pt,
        is_block: t.is_block,
    }
}
fn invalid(message: String) -> LyraReaderFfiError {
    LyraReaderFfiError::InvalidArgument {
        message,
        severity: ErrorSeverity::Recoverable,
    }
}

#[uniffi::export]
impl LyraReaderDocument {
    /// Cache-only paragraph inspection, also used to validate restored overlay geometry.
    pub fn text_translation_blocks(
        &self,
        page: u32,
    ) -> Result<Option<Vec<TranslationTargetRecord>>, LyraReaderFfiError> {
        let Some(text) = self.prepared_selection_text_page(page)? else {
            return Ok(None);
        };
        lyra_reader_text::translation_blocks(&text)
            .map(|v| Some(v.into_iter().map(record).collect()))
            .map_err(invalid)
    }
    /// Cache-only target resolution; callers prepare text asynchronously on an explicit action.
    pub fn text_translation_targets(
        &self,
        page: u32,
        start: u32,
        end: u32,
    ) -> Result<Option<Vec<TranslationTargetRecord>>, LyraReaderFfiError> {
        let Some(text) = self.prepared_selection_text_page(page)? else {
            return Ok(None);
        };
        lyra_reader_text::translation_targets(&text, start, end)
            .map(|targets| Some(targets.into_iter().map(record).collect()))
            .map_err(invalid)
    }
}

fn selection_page(
    page: u32,
    chars: Vec<TextChar>,
) -> Result<SelectionTextPage, LyraReaderFfiError> {
    if chars.len() > 1 << 20 {
        return Err(invalid(
            "This page has too many translation characters.".into(),
        ));
    }
    let chars = chars
        .into_iter()
        .map(|c| CharBox {
            rect: Rect::new(c.x_pt, c.y_pt, c.width_pt, c.height_pt),
            origin: Point::new(c.x_pt, c.y_pt),
            unicode: c.unicode,
            font_size: c.height_pt,
            logical_order: 0,
        })
        .collect();
    Ok(SelectionTextPage::new(TextPage {
        page: PageIndex(page),
        chars,
        ..Default::default()
    }))
}

#[uniffi::export]
pub fn translation_blocks_for_text(
    page: u32,
    chars: Vec<TextChar>,
) -> Result<Vec<TranslationTargetRecord>, LyraReaderFfiError> {
    let text = selection_page(page, chars)?;
    lyra_reader_text::translation_blocks(&text)
        .map(|targets| targets.into_iter().map(record).collect())
        .map_err(invalid)
}

/// Value-only adapter for synthetic text pages and platform-independent reference checks.
/// Production document callers use the cached method to avoid copying a page over the bridge.
#[uniffi::export]
pub fn translation_targets_for_text(
    page: u32,
    chars: Vec<TextChar>,
    start: u32,
    end: u32,
) -> Result<Vec<TranslationTargetRecord>, LyraReaderFfiError> {
    let text = selection_page(page, chars)?;
    lyra_reader_text::translation_targets(&text, start, end)
        .map(|targets| targets.into_iter().map(record).collect())
        .map_err(invalid)
}

/// Stable legacy identity shared by native hosts. No file access or network activity.
#[uniffi::export]
pub fn inplace_translation_cache_key(
    source: String,
    page: u32,
    rect: AiSourceRectRecord,
    language: String,
    model: String,
    version: String,
) -> Result<String, LyraReaderFfiError> {
    lyra_reader_ai::translation::cache_key(
        &source,
        page,
        Rect::new(rect.x_pt, rect.y_pt, rect.width_pt, rect.height_pt),
        &language,
        &model,
        &version,
    )
    .map_err(invalid)
}
#[uniffi::export]
pub fn inplace_translation_prompt_version() -> String {
    lyra_reader_ai::translation::PROMPT_VERSION.into()
}

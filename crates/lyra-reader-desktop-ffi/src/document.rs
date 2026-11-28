//! Desktop transport over the same portable Rust control plane the macOS shell uses.
//! JSON only crosses the narrow C boundary; requests are decoded into typed engine records.
use crate::analysis_cache::{AnalysisRun, PendingSummary, SummaryCapture};
use crate::reading_notes::PendingNote;
use lyra_reader_ai::workspace::{ReadingRecord, reading_scope_key};
use lyra_reader_core::Size;
use lyra_reader_ffi::api::*;
use lyra_reader_runtime::{MAX_PAGE_BYTES, PAGE_GAP_PT, bounded_raster_scale};
use lyra_reader_session::paper_document::{PaperCard, PaperDocumentLayout};
use lyra_reader_session::{DocumentLayout, LayoutMode};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex, RwLock},
};

pub struct DesktopDocument {
    pub(super) engine: RwLock<Arc<LyraReaderDocument>>,
    pub(super) layout: RwLock<DocumentLayout>,
    pub(super) original_signature: SignatureStatusRecord,
    original_xfa: XfaStatusRecord,
    ai: Mutex<Option<DesktopAiRequest>>,
    summary_batch: Mutex<crate::summary_batch::Batch>,
    summary_scope: Arc<crate::summary_batch::Scope>,
    pub(super) translation_scope: Arc<crate::summary_batch::Scope>,
    pub(super) translations: Mutex<crate::translation::Translations>,
    pub(super) summaries: Mutex<crate::summary_store::Store>,
    pub(super) knowledge: Arc<Mutex<crate::knowledge::Knowledge>>,
    pub(super) pending_summary: Mutex<Option<PendingSummary>>,
    pub(super) pending_note: Mutex<Option<PendingNote>>,
    pub(super) regions: Mutex<crate::region_store::RegionStore>,
    pub(super) ai_region_sources: Mutex<Option<Arc<crate::region_store::RequestProvenance>>>,
    pub(super) marks: Mutex<crate::marks::Marks>,
    pub(super) edits: Mutex<crate::pages::PageEdits>,
    pub(super) original_path: PathBuf,
    pub(super) recovery_status: Mutex<Value>,
    pub(super) password: Option<String>,
}

const MAX_READING_REPLY_BYTES: usize = 8 * 1024 * 1024;

struct DesktopAiRequest {
    request: Arc<LyraReaderAiRequest>,
    reading: Option<ReadingReplies>,
    analysis: Option<AnalysisRun>,
}

#[derive(Deserialize, Serialize)]
struct ReadingSummaryStyle {
    detail: String,
    language: String,
    reasoning_mode: String,
    reasoning_encoding: String,
}

enum ReadingOutput {
    Translation(Box<crate::reading_history::PendingTranslation>),
    Chat(Box<crate::reading_history::ChatArchive>),
    Note(Box<PendingNote>),
    Synthesis {
        request: Box<AiMergePlanRequestRecord>,
        style: ReadingSummaryStyle,
        capture: Arc<SummaryCapture>,
        account: Option<String>,
    },
    Summary {
        capture: Arc<SummaryCapture>,
        model: String,
    },
}

enum ReadingArchive {
    Translation(Box<Result<ReadingRecord, String>>),
    Chat(crate::reading_history::ChatArchive),
    Note(Box<PendingNote>, String),
    NoteSynthesis(Box<PendingNote>),
    PendingSummary(PendingSummary),
    Summary(Box<Result<ReadingRecord, String>>),
}

struct ReadingReplies {
    output: ReadingOutput,
    expected_parts: usize,
    replies: Vec<String>,
    remaining_bytes: usize,
    failure: Option<&'static str>,
    incomplete: bool,
    cancelled: bool,
    done: bool,
}

impl ReadingReplies {
    fn new(output: ReadingOutput, expected_parts: usize) -> Self {
        Self {
            output,
            expected_parts,
            replies: Vec::new(),
            remaining_bytes: MAX_READING_REPLY_BYTES,
            failure: None,
            incomplete: false,
            cancelled: false,
            done: false,
        }
    }

    fn observe(&mut self, events: &[AiEventRecord]) {
        for event in events {
            if matches!(event, AiEventRecord::Done) {
                self.done = true;
            }
            if matches!(
                event,
                AiEventRecord::Error {
                    cancelled: true,
                    ..
                }
            ) {
                self.cancelled = true;
            }
            if self.failure.is_some() {
                continue;
            }
            match event {
                AiEventRecord::PartStarted { index, total, .. } => {
                    if *index as usize == self.replies.len()
                        && *total as usize == self.expected_parts
                        && self.replies.len() < self.expected_parts
                    {
                        self.replies.push(String::new());
                    } else {
                        self.failure =
                            Some("The response parts do not match the reviewed request.");
                    }
                }
                AiEventRecord::Delta { text } => {
                    if let Some(reply) = self.replies.last_mut()
                        && text.len() <= self.remaining_bytes
                    {
                        reply.push_str(text);
                        self.remaining_bytes -= text.len();
                    } else {
                        self.failure =
                            Some("The response could not fit in the reading task display.");
                    }
                }
                AiEventRecord::Diagnostics { diagnostics }
                    if matches!(
                        diagnostics.finish_reason.as_deref(),
                        Some("length" | "content_filter" | "tool_calls" | "function_call")
                    ) =>
                {
                    self.incomplete = true;
                }
                AiEventRecord::Error { .. } => {
                    self.incomplete = true;
                }
                _ => {}
            }
        }
    }

    fn publish(self, result: &mut Value) -> Option<ReadingArchive> {
        let failure = self
            .failure
            .or((self.incomplete || !self.done)
                .then_some("The provider stopped before completing all reading task parts."))
            .or((self.replies.len() != self.expected_parts)
                .then_some("The response is missing reviewed parts."));
        match self.output {
            ReadingOutput::Translation(pending) => pending
                .finish(&self.replies, failure, result)
                .map(|record| ReadingArchive::Translation(Box::new(record))),
            ReadingOutput::Chat(pending) => {
                let state = if self.cancelled {
                    "cancelled"
                } else if failure.is_none()
                    && self.replies.iter().any(|reply| !reply.trim().is_empty())
                {
                    "finished"
                } else if self.done {
                    "partial"
                } else {
                    "failed"
                };
                Some(ReadingArchive::Chat(
                    pending.with_reply(&self.replies, state),
                ))
            }
            ReadingOutput::Note(capture) => {
                if failure.is_some() || self.replies.iter().any(|reply| reply.trim().is_empty()) {
                    result["note_warning"] =
                        json!("The note update did not finish. The saved note was kept.");
                    return None;
                }
                if capture.needs_consolidation() {
                    match capture.consolidate(self.replies) {
                        Ok((next, plan)) => {
                            result["note_synthesis_plan"] = plan;
                            return Some(ReadingArchive::NoteSynthesis(Box::new(next)));
                        }
                        Err(error) => {
                            result["note_warning"] = json!(error);
                            return None;
                        }
                    }
                }
                Some(ReadingArchive::Note(capture, self.replies.join("\n\n")))
            }
            ReadingOutput::Summary { capture, model } => {
                if failure.is_some() {
                    return None;
                }
                let answer = self.replies.into_iter().next()?;
                if answer.trim().is_empty() {
                    return None;
                }
                Some(ReadingArchive::Summary(Box::new(
                    Arc::unwrap_or_clone(capture).ready(model, answer),
                )))
            }
            ReadingOutput::Synthesis {
                mut request,
                style,
                capture,
                account,
            } => {
                if !self.done {
                    return None;
                }
                if let Some(message) = failure {
                    result["synthesis_warning"] = json!(message);
                    return None;
                }
                for (part, reply) in request.parts.iter_mut().zip(self.replies) {
                    part.summary = reply;
                }
                let preview = render_reviewed_plan(
                    build_ai_merge_plan(*request).and_then(|plan| {
                        style_ai_reading_plan(plan, "summary".into(), style.detail, style.language)
                    }),
                    account.as_deref(),
                );
                let mut plan = match preview {
                    Ok(plan) => plan,
                    Err(message) => {
                        result["synthesis_warning"] = json!(message);
                        return None;
                    }
                };
                let pending = plan["parts"][0]["wire_body"]
                    .as_str()
                    .ok_or(
                        "The summary synthesis preview did not contain a request body.".to_owned(),
                    )
                    .and_then(|body| PendingSummary::new(capture, body, account));
                plan["kind"] = json!("summary_synthesis");
                let archive = match pending {
                    Ok(pending) => {
                        plan["summary_capture"] = json!(pending.token);
                        Some(ReadingArchive::PendingSummary(pending))
                    }
                    Err(error) => {
                        result["cache_warning"] = json!(error);
                        None
                    }
                };
                result["synthesis_plan"] = plan;
                archive
            }
        }
    }
}

fn value<T: Serialize>(result: Result<T, LyraReaderFfiError>) -> Result<Value, String> {
    serde_json::to_value(result.map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}

pub(super) fn reference_preview_value(resolved: Vec<ResolvedReference>) -> Result<Value, String> {
    // Decorate only the disposable preview response, never the index/cache record format.
    let mut rows = Vec::with_capacity(resolved.len());
    for entry in resolved {
        let heading = lyra_reader_text::reference_preview_title(&entry.reference.text);
        let mut row = serde_json::to_value(&entry).map_err(|error| error.to_string())?;
        let reference = row
            .get_mut("reference")
            .and_then(Value::as_object_mut)
            .ok_or("The resolved reference did not serialize as a reference record")?;
        reference.insert("heading".into(), json!(heading));
        rows.push(row);
    }
    Ok(Value::Array(rows))
}

pub(super) fn render_reviewed_plan(
    result: Result<AiPlanRecord, LyraReaderFfiError>,
    account: Option<&str>,
) -> Result<Value, String> {
    let mut plan = value(result.and_then(|plan| {
        if account.is_some() {
            render_chatgpt_plan(plan)
        } else {
            render_ai_plan(plan, AiWireTransport::ChatCompletions)
        }
    }))?;
    if let Some(account) = account {
        plan["chatgpt_account"] = json!(account);
    }
    Ok(plan)
}
pub(super) fn chatgpt_account(request: &Value) -> Result<Option<&str>, String> {
    request
        .get("chatgpt_account")
        .map(|entry| {
            entry
                .as_str()
                .filter(|id| !id.is_empty() && id.len() <= 128)
                .ok_or_else(|| "The ChatGPT connection changed. Preview the request again.".into())
        })
        .transpose()
}
fn arg<T: DeserializeOwned>(request: &Value, key: &str) -> Result<T, String> {
    serde_json::from_value(request.get(key).cloned().unwrap_or(Value::Null))
        .map_err(|e| format!("Invalid {key}: {e}"))
}
fn text(request: &Value, key: &str) -> Result<String, String> {
    arg(request, key)
}

pub(super) fn consolidation_request(
    plan: &AiPlanRecord,
    reasoning_mode: String,
    reasoning_encoding: String,
) -> Result<AiMergePlanRequestRecord, String> {
    let parts = plan
        .parts
        .iter()
        .map(|part| {
            Ok(AiMergePartRecord {
                index: part
                    .index
                    .checked_add(1)
                    .ok_or("Invalid summary part index.")?,
                total: part.total,
                pages: part.pages.clone(),
                summary: String::new(),
            })
        })
        .collect::<Result<Vec<_>, &str>>()?;
    Ok(AiMergePlanRequestRecord {
        document_title: plan.document_title.clone(),
        parts,
        base_url: plan.base_url.clone(),
        model: plan.model.clone(),
        temperature: plan.temperature,
        max_tokens: plan.max_tokens,
        reasoning_mode,
        reasoning_encoding,
        document_knowledge_text: None,
        document_knowledge_pages: Vec::new(),
    })
}

fn desktop_annotation_rules() -> Result<Value, String> {
    let mut value = serde_json::to_value(annotation_rules()).map_err(|e| e.to_string())?;
    let object = value
        .as_object_mut()
        .ok_or("Invalid annotation rule snapshot")?;
    object.insert(
        "kind_flags".into(),
        json!(annotation_kind_flags().into_iter().map(|kind| { let editable=lyra_reader_edit::kind::AnnotationKind::from_record_kind(&kind.kind).is_some_and(|k|lyra_reader_edit::text_edit::TextEditMode::Note.supports_kind(&k)); json!({"kind":kind.kind,"is_note":kind.is_note,"is_markup":kind.is_markup,"is_text_markup":kind.is_text_markup,"note_editable":editable}) }).collect::<Vec<_>>()),
    );
    Ok(value)
}

fn layout_rows(layout: &DocumentLayout) -> Result<Value, String> {
    // Ranges reference the packet's existing pages, avoiding a second serialized page table.
    // Reuse the shared paper geometry count bound before allocating a file-sized snapshot.
    let count = layout.rows().len();
    if count > lyra_reader_session::paper::MAX_PAPER_GEOMETRY_ITEMS {
        return Err("The layout row snapshot exceeds its geometry limit".into());
    }
    let mut rows = Vec::new();
    rows.try_reserve_exact(count)
        .map_err(|_| "The layout row snapshot could not be allocated")?;
    for row in layout.rows() {
        rows.push(
            json!({"top":row.top_pt,"bottom":row.bottom_pt,"height":row.height_pt,
            "first":row.first_page,"count":row.page_count}),
        );
    }
    Ok(Value::Array(rows))
}

fn layout_mode_name(mode: LayoutMode) -> &'static str {
    match mode {
        LayoutMode::Continuous => "Continuous",
        LayoutMode::Facing => "Facing",
    }
}

pub(super) fn layout_value(source_layout: &DocumentLayout, r: &Value) -> Result<Value, String> {
    #[derive(serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Card {
        page: u32,
        split_pt: Option<f64>,
        gap_pt: f64,
    }
    let card = r
        .get("paper_card")
        .filter(|card| !card.is_null())
        .map(|card| {
            // Reject oversized display snapshots and malformed input before building any rows.
            if source_layout.page_count() > lyra_reader_session::paper::MAX_PAPER_GEOMETRY_ITEMS {
                return Err("The inserted paper snapshot exceeds its geometry limit".into());
            }
            serde::Deserialize::deserialize(card)
                .map_err(|e| format!("Invalid inserted paper: {e}"))
        })
        .transpose()?;
    let gap = r.get("gap").and_then(Value::as_f64).unwrap_or(PAGE_GAP_PT);
    if !gap.is_finite() || !(0.0..=200.0).contains(&gap) {
        return Err("Invalid page gap".into());
    }
    let mode = match r
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("Continuous")
    {
        "Continuous" => LayoutMode::Continuous,
        "Facing" => LayoutMode::Facing,
        _ => return Err("Unknown page layout".into()),
    };
    let sizes = source_layout
        .placements()
        .iter()
        .map(|p| (p.width_pt, p.height_pt));
    let layout = DocumentLayout::new_with_mode(sizes, gap, mode);
    let rows = layout_rows(&layout)?;
    let mut value = json!({"pages": layout.placements().iter().map(|p|json!({
        "index":p.index,"top":p.top_pt,"left":p.left_pt,"width":p.width_pt,"height":p.height_pt
    })).collect::<Vec<_>>(), "width":layout.content_width_pt(),"height":layout.content_height_pt(),"gap":gap});
    // The literal above is an object; move the bounded array without serializing it twice.
    value["rows"] = rows;
    value["mode"] = json!(layout_mode_name(mode));
    if let Some(card) = card {
        // Display geometry never replaces source placements used by PDF writes or bookmarks.
        let card: Card = card;
        let display = PaperDocumentLayout::new(
            &layout,
            Some(PaperCard {
                page: card.page,
                split_pt: card.split_pt,
                gap_pt: card.gap_pt,
            }),
        )
        .map_err(|e| e.to_string())?;
        let mut display_rows = Vec::new();
        display_rows
            .try_reserve_exact(display.rows().len())
            .map_err(|_| "The inserted row snapshot could not be allocated")?;
        for row in display.rows() {
            display_rows.push(
                json!({"top":row.display_top_pt,"height":row.display_height_pt,
                "first":row.source.first_page,"count":row.source.page_count}),
            );
        }
        let mut display_pages = Vec::new();
        display_pages
            .try_reserve_exact(layout.page_count())
            .map_err(|_| "The inserted page snapshot could not be allocated")?;
        for page in layout.placements() {
            display_pages.push(json!({"index":page.index,
                "top":display.page_top_pt(page.index).ok_or("The inserted page is unavailable")?,
                "height":display.page_height_pt(page.index).ok_or("The inserted page is unavailable")?}));
        }
        value["paper"] = json!({"rows":display_rows,"pages":display_pages,
            "height":display.content_height_pt(),"gap_top":display.gap_top_pt(),"card_row":display.card_row()});
    }
    Ok(value)
}

impl DesktopDocument {
    pub(crate) fn ai_running(&self) -> Result<bool, String> {
        Ok(self
            .ai
            .lock()
            .map_err(|_| "AI state is unavailable.")?
            .as_ref()
            .is_some_and(|job| !job.request.is_finished()))
    }
    pub(crate) fn summary_running(&self) -> Result<bool, String> {
        Ok(self
            .summary_batch
            .lock()
            .map_err(|_| "Summary state is unavailable.")?
            .is_running())
    }
    pub(crate) fn request_summary_cancel(&self) {
        self.summary_scope.cancel();
    }
    pub fn open(path: &Path, password: Option<&str>) -> Result<Self, String> {
        Self::open_with_cache_root(path, password, None)
    }
    pub(super) fn open_with_cache_root(
        path: &Path,
        password: Option<&str>,
        cache_root: Option<&Path>,
    ) -> Result<Self, String> {
        let engine = LyraReaderEngine::new()
            .open_document(
                path.to_string_lossy().into_owned(),
                password.map(str::to_owned),
            )
            .map_err(|e| e.to_string())?;
        if engine.page_count() == 0 {
            return Err("PDF contains no pages".into());
        }
        let sizes = (0..engine.page_count())
            .map(|p| {
                let size = engine.page_size_pt(p).map_err(|e| e.to_string())?;
                if !size.width_pt.is_finite()
                    || !size.height_pt.is_finite()
                    || size.width_pt <= 0.0
                    || size.height_pt <= 0.0
                {
                    return Err("Page dimensions must be positive and finite".to_string());
                }
                Ok((size.width_pt, size.height_pt))
            })
            .collect::<Result<Vec<_>, String>>()?;
        let mut mark_state = crate::marks::Marks::load_opened(&engine, cache_root);
        if let Err(error) = mark_state.seed_bookmarks(&engine) {
            mark_state.error = Some(error);
        }
        let marks = Mutex::new(mark_state);
        let original = Arc::clone(&engine);
        let original_layout = DocumentLayout::new(sizes, PAGE_GAP_PT);
        let summary_scope = Arc::new(crate::summary_batch::Scope::default());
        let translation_scope = Arc::new(crate::summary_batch::Scope::default());
        let document = Self {
            original_signature: engine.signature_status(),
            original_xfa: engine.xfa_status(),
            engine: RwLock::new(engine),
            layout: RwLock::new(original_layout.clone()),
            edits: Mutex::new(crate::pages::PageEdits::default()),
            original_path: path.to_path_buf(),
            recovery_status: Mutex::new(Value::Null),
            password: password.map(str::to_owned),
            ai: Mutex::new(None),
            summary_batch: Mutex::new(crate::summary_batch::Batch::new(Arc::clone(&summary_scope))),
            summary_scope,
            translations: Mutex::new(crate::translation::Translations::new(Arc::clone(
                &translation_scope,
            ))),
            translation_scope,
            summaries: Mutex::new(crate::summary_store::Store::default()),
            knowledge: Arc::new(Mutex::new(crate::knowledge::Knowledge::default())),
            pending_summary: Mutex::new(None),
            pending_note: Mutex::new(None),
            regions: Mutex::new(crate::region_store::RegionStore::default()),
            ai_region_sources: Mutex::new(None),
            marks,
        };
        if let Err(error) = document.restore_cached_pages() {
            if let Ok(mut marks) = document.marks.lock() {
                marks.recovery_notice(error.clone());
            }
            if let Ok(mut status) = document.recovery_status.lock() {
                *status = json!({"error":error});
            }
        }
        if let Err(error) = crate::quit::consume(&document) {
            let reason = format!(
                "The resolved quit could not be cleaned up. Recovery files were kept; reopen to retry. {error}"
            );
            *document
                .engine
                .write()
                .map_err(|_| "Document state is unavailable")? = Arc::clone(&original);
            *document
                .layout
                .write()
                .map_err(|_| "Document layout is unavailable")? = original_layout;
            *document
                .edits
                .lock()
                .map_err(|_| "Page-edit state is unavailable")? =
                crate::pages::PageEdits::default();
            document
                .marks
                .lock()
                .map_err(|_| "Annotation state is unavailable")?
                .hide_resolved_draft(&original, reason.clone());
            *document
                .recovery_status
                .lock()
                .map_err(|_| "Recovery state is unavailable")? =
                json!({"error":reason,"resolved_quit_cleanup_pending":true});
        }
        Ok(document)
    }

    pub(super) fn active(&self) -> Result<Arc<LyraReaderDocument>, String> {
        self.engine
            .read()
            .map(|d| Arc::clone(&d))
            .map_err(|_| "Document state is unavailable".into())
    }
    pub(super) fn source_signature(&self, current: &LyraReaderDocument) -> SignatureStatusRecord {
        // A private editing revision is unsigned; the source must retain its original protection.
        // Discard can reopen a source replaced outside the app, so refresh that source's status.
        if Path::new(&current.path()) == self.original_path {
            current.signature_status()
        } else {
            self.original_signature.clone()
        }
    }
    fn source_xfa(&self, current: &LyraReaderDocument) -> XfaStatusRecord {
        // Cached working PDFs must not erase the source form's read-only contract.
        if Path::new(&current.path()) == self.original_path {
            current.xfa_status()
        } else {
            self.original_xfa.clone()
        }
    }
    pub fn info(&self) -> Result<Value, String> {
        let current = self.active()?;
        let document_id = self
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")?
            .cache_location()
            .ok()
            .and_then(|cache| cache.document_id().map(str::to_owned));
        let layout = self
            .layout
            .read()
            .map_err(|_| "Layout state is unavailable")?;
        let rows = layout_rows(&layout)?;
        let mut value = json!({
            "pages":layout.placements().iter().map(|p|json!({"index":p.index,"width":p.width_pt,"height":p.height_pt,"top":p.top_pt,"left":p.left_pt})).collect::<Vec<_>>(),
            "width":layout.content_width_pt(),"height":layout.content_height_pt(),"gap":layout.gap_pt(),"path":self.original_path,"revision":self.active()?.path(),"signature_status":self.source_signature(&current),"xfa_status":self.source_xfa(&current),"annotation_rules":desktop_annotation_rules()?,"ai_history_limit":ai_chat_history_limit(),"recovery":self.recovery_status.lock().map_err(|_|"Recovery state is unavailable")?.clone(),
        });
        // Private revisions keep the source cache's identity. An unavailable cache leaves
        // this optional decoration unknown rather than blocking document reading.
        value["document_id"] = json!(document_id);
        value["rows"] = rows;
        value["mode"] = json!(layout_mode_name(layout.mode()));
        Ok(value)
    }

    pub fn render(
        &self,
        page: u32,
        requested: f64,
        embedded_annotations: bool,
    ) -> Result<PageBitmap, String> {
        let engine = self.active()?;
        let size = engine.page_size_pt(page).map_err(|e| e.to_string())?;
        let scale = bounded_raster_scale(Size::new(size.width_pt, size.height_pt), requested)
            .map_err(|e| e.to_string())?;
        let bitmap = if embedded_annotations {
            engine.rasterize_page_with_annotations(page, scale)
        } else {
            engine.rasterize_page(page, scale)
        }
        .map_err(|e| e.to_string())?;
        if bitmap.pixels.len() > MAX_PAGE_BYTES {
            return Err("Raster exceeded its byte budget".into());
        }
        Ok(bitmap)
    }

    pub fn command(&self, r: Value) -> Result<Value, String> {
        let op = r
            .get("op")
            .and_then(Value::as_str)
            .ok_or("Missing operation")?;
        if matches!(
            op,
            "ai_preview"
                | "ai_start"
                | "ai_summary_prepare"
                | "ai_summary_batch_prepare"
                | "ai_summary_batch_start"
                | "translation_prepare"
                | "translation_start"
        ) {
            self.ensure_reading_idle()?;
        }
        if op.starts_with("translation_") {
            return self.translation_command(op, &r);
        }
        if matches!(
            op,
            "ai_start" | "ai_summary_batch_prepare" | "ai_summary_batch_start"
        ) && self.translations_running()?
        {
            return Err("Stop the in-place translation before starting another response.".into());
        }
        if op.starts_with("knowledge_") {
            return self.knowledge_command(op, &r);
        }
        if op.starts_with("replace_")
            || matches!(
                op,
                "content_stage"
                    | "page_stage"
                    | "page_undo"
                    | "page_redo"
                    | "page_discard"
                    | "page_apply"
                    | "document_save"
                    | "document_discard"
            )
        {
            self.request_translation_cancel();
            self.invalidate_reading()?;
        }
        // The shared writer already rejects XFA derivatives. Gate shell-side mutations too,
        // before creating a cache/session or turning a synthetic form page into an editable draft.
        // Local reading bookmarks and their undo history remain available.
        let writes_pdf_or_annotations = op.starts_with("save_")
            || op.starts_with("replace_")
            || op.starts_with("mark_")
            || op.starts_with("file_")
            || (op.starts_with("ink_erase_") && op != "ink_erase_cancel")
            || matches!(
                op,
                "marks_erase"
                    | "extract_pages"
                    | "page_operation"
                    | "content_stage"
                    | "content_redaction_preflight"
                    | "page_stage"
                    | "page_undo"
                    | "page_redo"
                    | "page_apply"
                    | "document_save"
            );
        if writes_pdf_or_annotations {
            let status = self.source_xfa(self.active()?.as_ref());
            if status.is_xfa {
                return Err(status
                    .read_only_reason
                    .ok_or("The XFA read-only status is incomplete")?);
            }
        }
        if op.starts_with("region_") {
            return self.region_command(op, &r);
        }
        if matches!(op, "save_merge" | "save_split" | "split_plan") {
            return self.export_command(op, &r);
        }
        if let Some(destination) = r.get("destination").and_then(Value::as_str) {
            let destination = Path::new(destination);
            let resolved = if destination.exists() {
                std::fs::canonicalize(destination)
            } else {
                let parent = destination
                    .parent()
                    .filter(|p| !p.as_os_str().is_empty())
                    .unwrap_or(Path::new("."));
                std::fs::canonicalize(parent)
                    .map(|p| p.join(destination.file_name().unwrap_or_default()))
            }
            .map_err(|e| e.to_string())?;
            if resolved == std::fs::canonicalize(&self.original_path).map_err(|e| e.to_string())? {
                return Err("A copy cannot overwrite the original PDF. Choose another name or use the explicit replace action with its verified backup.".into());
            }
        }
        if matches!(
            op,
            "content_stage"
                | "page_stage"
                | "page_undo"
                | "page_redo"
                | "page_discard"
                | "page_apply"
                | "document_save"
                | "document_discard"
        ) {
            return self.page_command(op, &r);
        }
        let _write_guard = if op.starts_with("save_")
            || op.starts_with("replace_")
            || matches!(op, "extract_pages" | "page_operation" | "layout")
        {
            Some(
                self.edits
                    .lock()
                    .map_err(|_| "Page-edit state is unavailable")?,
            )
        } else {
            None
        };
        let d = self.active()?;
        if op.starts_with("ink_erase_") && op != "ink_erase_commit" {
            return self
                .marks
                .lock()
                .map_err(|_| "Annotation state is unavailable")?
                .command(op, &r, &d);
        }
        if op.starts_with("replace_")
            && (_write_guard
                .as_ref()
                .is_some_and(|edits| edits.has_session())
                || d.path() != self.original_path.to_string_lossy())
        {
            return Err(
                "Apply or discard the staged page changes before replacing the original PDF".into(),
            );
        }
        if matches!(
            op,
            "marks"
                | "mark_create"
                | "mark_text_begin"
                | "mark_text_update"
                | "mark_text_end"
                | "mark_update"
                | "mark_delete"
                | "bookmark_create"
                | "bookmark_update"
                | "bookmark_delete"
                | "bookmark_move"
                | "marks_undo"
                | "marks_redo"
                | "file_delete"
                | "file_adopt"
                | "marks_recover"
                | "marks_erase"
                | "ink_erase_commit"
        ) {
            let edits = self
                .edits
                .lock()
                .map_err(|_| "Page-edit state is unavailable")?;
            let mut marks = self
                .marks
                .lock()
                .map_err(|_| "Annotation state is unavailable")?;
            let active = self.active()?;
            let state = marks.command(op, &r, &active)?;
            // Page redo follows the shared transaction, including its annotation snapshots.
            return Ok(edits.annotate_state(state, &active, &self.original_path));
        }
        match op {
            "save_current_edited_copy" | "save_document_copy" => {
                let marks = self
                    .marks
                    .lock()
                    .map_err(|_| "Annotation state is unavailable")?;
                let destination = text(&r, "destination")?;
                let original = crate::marks::Marks::load_with_root(
                    Path::new(&destination),
                    d.page_count(),
                    marks.cache_root(),
                );
                let translation_snapshot = self
                    .translations
                    .lock()
                    .map_err(|_| "Translation state is unavailable.".to_owned())
                    .and_then(|mut translations| {
                        translations.save_snapshot(marks.cache_location()?)
                    });
                let payload = marks.payload(&d)?;
                let prepared = crate::saving::prepare(
                    &d,
                    &marks.cache_location()?.directory,
                    &r,
                    self.password.clone(),
                )?;
                let d = &prepared.document;
                let clean = marks.cleaned_for_save(&payload.ids);
                let (report, published, _) = clean.publish_page_revision(&original, || {
                    if payload.is_empty() {
                        serde_json::to_value(
                            d.save_edited_copy(destination).map_err(|e| e.to_string())?,
                        )
                        .map_err(|e| e.to_string())
                    } else {
                        serde_json::to_value(
                            d.save_annotation_changes_copy(
                                destination,
                                payload.annotations,
                                payload.bookmarks,
                                payload.updates,
                                payload.deletions,
                            )
                            .map_err(|e| e.to_string())?,
                        )
                        .map_err(|e| e.to_string())
                    }
                })?;
                let mut report = report;
                report["forms"] = prepared.form_report;
                let translation_error = (|| {
                    self.translations
                        .lock()
                        .map_err(|_| "Translation state is unavailable.")?
                        .publish_snapshot(
                            published.cache_location()?,
                            translation_snapshot?.as_deref(),
                        )
                })()
                .err();
                let region_error = (|| {
                    crate::region_store::carry_notes(
                        marks.cache_location()?,
                        published.cache_location()?,
                    )
                })()
                .err();
                report["cache_cleanup_error"] = json!(match (published.error, region_error) {
                    (Some(a), Some(b)) => Some(format!("{a}. {b}")),
                    (a, b) => a.or(b),
                });
                if let Some(error) = translation_error {
                    crate::translation::append_warning(&mut report, error);
                }
                value(Ok(report))
            }
            "save_current_annotations" | "replace_current_annotations" => {
                let mut marks = self
                    .marks
                    .lock()
                    .map_err(|_| "Annotation state is unavailable")?;
                let payload = marks.payload(&d)?;
                let report = if op == "save_current_annotations" {
                    d.save_annotation_changes_copy(
                        text(&r, "destination")?,
                        payload.annotations,
                        payload.bookmarks,
                        payload.updates,
                        payload.deletions,
                    )
                } else {
                    d.replace_with_annotation_changes(
                        payload.annotations,
                        payload.bookmarks,
                        payload.updates,
                        payload.deletions,
                    )
                }
                .map_err(|e| e.to_string())?;
                let cleanup = if op == "replace_current_annotations" {
                    marks
                        .clear_saved(&payload.ids)
                        .and_then(|()| marks.after_save())
                        .err()
                } else {
                    None
                };
                let mut result = serde_json::to_value(report).map_err(|e| e.to_string())?;
                result["sidecar_cleanup_error"] = json!(cleanup);
                Ok(result)
            }
            "content_objects" => {
                let snapshot = d
                    .content_objects(arg(&r, "page")?)
                    .map_err(|e| e.to_string())?;
                serde_json::from_str(&snapshot)
                    .map_err(|e| format!("Invalid content snapshot: {e}"))
            }
            "content_redaction_preflight" => {
                value(d.content_redaction_raster_pages(arg(&r, "page")?, arg(&r, "command")?))
            }
            "save_content_image" => crate::exports::save_content_image(&d, &r),
            "info" => self.info(),
            "outline" => value(d.outline()),
            "metadata" => value(d.metadata()),
            "signature_status" => {
                serde_json::to_value(self.source_signature(self.active()?.as_ref()))
                    .map_err(|e| e.to_string())
            }
            "document_info" => value(d.document_info()),
            "export_suggestion" => crate::export_dialog::suggestion(&self.original_path, &r),
            "forms" => value(d.form_info()),
            "annotations" => {
                crate::artwork::annotations(d.annotations().map_err(|e| e.to_string())?)
            }
            "links" => value(d.links(arg(&r, "page")?)),
            "text" => value(d.text_page(arg(&r, "page")?)),
            "search" => value(
                d.search(
                    text(&r, "pattern")?,
                    r.get("limit")
                        .and_then(Value::as_u64)
                        .unwrap_or(1000)
                        .min(10000) as u32,
                ),
            ),
            "citations" => value(d.citations(arg(&r, "page")?)),
            "caption_mentions" => value(d.caption_mentions(arg(&r, "page")?)),
            "references" => value(d.references()),
            "figures" => value(d.figures()),
            "resolve_citations" => {
                let resolved = d
                    .resolve_citations_on(arg(&r, "page")?, arg(&r, "labels")?)
                    .map_err(|error| error.to_string())?;
                reference_preview_value(resolved)
            }
            "rotations" => value(d.page_rotations()),
            "index_report" => {
                serde_json::to_value(d.index_cache_report()).map_err(|e| e.to_string())
            }
            "layout" => {
                let source_layout = self
                    .layout
                    .read()
                    .map_err(|_| "Layout state is unavailable")?;
                layout_value(&source_layout, &r)
            }
            "bibtex" => Ok(Value::String(generate_bibtex_entry(arg(&r, "draft")?))),
            "font_coverage" => value(appearance_font_coverage(text(&r, "text")?)),
            "save_annotations" => value(d.save_annotation_changes_copy(
                text(&r, "destination")?,
                arg(&r, "annotations")?,
                arg(&r, "bookmarks")?,
                arg(&r, "updates")?,
                arg(&r, "deletions")?,
            )),
            "replace_annotations" => value(d.replace_with_annotation_changes(
                arg(&r, "annotations")?,
                arg(&r, "bookmarks")?,
                arg(&r, "updates")?,
                arg(&r, "deletions")?,
            )),
            "save_forms" => {
                value(d.save_filled_form_copy(text(&r, "destination")?, arg(&r, "values")?))
            }
            // Like the macOS export, flatten the active PDF's saved bytes, not the
            // annotation/form drafts. The shared writer owns baking and preservation.
            "save_flattened_copy" => value(d.flatten_to_copy(text(&r, "destination")?)),
            "replace_forms" => value(d.replace_with_filled_form(arg(&r, "values")?)),
            "save_properties" => value(d.save_document_properties_copy(
                text(&r, "destination")?,
                text(&r, "title")?,
                text(&r, "author")?,
                text(&r, "subject")?,
                text(&r, "keywords")?,
            )),
            "replace_properties" => value(d.replace_with_document_properties(
                text(&r, "title")?,
                text(&r, "author")?,
                text(&r, "subject")?,
                text(&r, "keywords")?,
            )),
            "extract_pages" => value(d.extract_pages(text(&r, "destination")?, arg(&r, "pages")?)),
            "page_operation" => {
                value(d.apply_page_operation(text(&r, "destination")?, arg(&r, "operation")?))
            }
            "save_edited_copy" => value(d.save_edited_copy(text(&r, "destination")?)),
            "replace_edited_pages" => value(d.replace_with_edited_pages(text(&r, "original")?)),
            "preview_redactions" | "save_redactions" | "replace_redactions" => Err(
                "Annotation redaction has been retired. Use Edit → Redact → Blackout/Erase.".into(),
            ),
            "ai_preview" => {
                let mut request = crate::region::request(r["request"].clone())?;
                let account = chatgpt_account(&r["request"])?;
                if account.is_some() {
                    let reading = r["reading"]["kind"].as_str();
                    let eligible = match request.action {
                        AiActionRecord::DocumentChat
                        | AiActionRecord::AskSelection
                        | AiActionRecord::SummarizePage => r.get("reading").is_none(),
                        AiActionRecord::SummarizeSelection => reading == Some("summary"),
                        AiActionRecord::TranslateSelection => reading == Some("translation"),
                        AiActionRecord::SummarizeDocument => {
                            matches!(
                                reading,
                                Some("summary" | "translation" | "note" | "region_note")
                            ) && request.selection.is_none()
                        }
                        AiActionRecord::RegionQuestion => {
                            r.get("reading").is_none()
                                && request.region.as_ref().is_some_and(|region| {
                                    region.send_image
                                        && !region.include_document_context
                                        && region.image_png.is_some()
                                })
                        }
                        _ => false,
                    };
                    if !eligible {
                        return Err("This request does not use the ChatGPT plan connection.".into());
                    }
                    request.base_url = "https://api.openai.com/v1".into();
                }
                if r.get("reading").is_some() {
                    let options: AiReadingOptionsRecord = arg(&r, "reading")?;
                    if options.kind == "note" {
                        return self.prepare_note_review(
                            &d,
                            &text(&r["reading"], "id")?,
                            None,
                            request,
                            account,
                        );
                    }
                    if options.kind == "region_note" {
                        return self.prepare_note_review(
                            &d,
                            &text(&r["reading"], "id")?,
                            Some(&text(&r["reading"], "expected_history_revision")?),
                            request,
                            account,
                        );
                    }
                    if let Some(id) = r["reading"]["saved_translation"].as_str() {
                        if options.kind != "translation" {
                            return Err(
                                "A saved translation requires a translation preview.".into()
                            );
                        }
                        let original_action = request.action;
                        self.replay_translation_source(&d, id, &mut request)?;
                        if account.is_some() && request.action != original_action {
                            let message = if original_action == AiActionRecord::TranslateSelection {
                                "ChatGPT retranslation requires a saved selection."
                            } else {
                                "This saved translation covers a selection. Preview it with that scope."
                            };
                            return Err(message.into());
                        }
                    }
                    let limit = lyra_reader_ai::chat::MAX_SELECTION_CHARS as u64;
                    let selected = request.selection.is_some_and(|range| {
                        range.end >= range.start && u64::from(range.end - range.start) < limit
                    });
                    let translation = options.kind == "translation";
                    let valid = match (options.kind.as_str(), request.action) {
                        ("summary", AiActionRecord::SummarizeSelection)
                        | ("translation", AiActionRecord::TranslateSelection) => selected,
                        ("summary" | "translation", AiActionRecord::SummarizeDocument) => {
                            request.selection.is_none()
                        }
                        _ => false,
                    };
                    if !valid || request.document_knowledge {
                        return Err(format!(
                            "Select a passage of at most {limit} characters or choose a supported document task."
                        ));
                    }
                    // Reading tasks only receive the approved
                    // source, without the optional background document analysis.
                    request.document_knowledge_text = None;
                    request.document_knowledge_pages.clear();
                    let whole_summary =
                        !translation && request.action == AiActionRecord::SummarizeDocument;
                    let style = whole_summary.then(|| ReadingSummaryStyle {
                        detail: options.detail.clone(),
                        // An absent language asks the engine to use the document's language.
                        language: request.language.as_deref().unwrap_or("").to_owned(),
                        reasoning_mode: request.reasoning_mode.clone(),
                        reasoning_encoding: request.reasoning_encoding.clone(),
                    });
                    let mut cache_warning = None;
                    if let Some(summary) = &style
                        && r["reading"]["force"].as_bool() != Some(true)
                    {
                        match self.cached_document_summary(&d, &summary.language, &summary.detail) {
                            Ok(Some(record)) => return Ok(json!({"saved_summary":record})),
                            Ok(None) => {}
                            Err(error) => cache_warning = Some(error),
                        }
                    }
                    let scope = (!whole_summary).then(|| crate::reading_history::ReadingScope {
                        selection: request.selection,
                        language: request.language.as_deref().unwrap_or("").to_owned(),
                        detail: options.detail.clone(),
                    });
                    let mut plan =
                        render_reviewed_plan(d.prepare_ai_reading_task(request, options), account)?;
                    if let Some(scope) = scope {
                        plan["kind"] = json!(if translation {
                            "reading_translation"
                        } else {
                            "reading_summary_selection"
                        });
                        plan["reading_scope"] =
                            serde_json::to_value(scope).map_err(|error| error.to_string())?;
                    } else if let Some(style) = style {
                        plan["kind"] = json!("reading_summary");
                        plan["reading_style"] =
                            serde_json::to_value(style).map_err(|error| error.to_string())?;
                        if let Some(warning) = cache_warning {
                            plan["cache_warning"] = json!(warning);
                        }
                    }
                    return Ok(plan);
                }
                self.enrich_region_history(
                    &mut request,
                    r.get("region_history_id").and_then(Value::as_str),
                    &d.document_identity().sha256,
                )?;
                self.enrich_reading(&mut request, &d.document_identity().sha256)?;
                render_reviewed_plan(d.prepare_ai_plan(request), account)
            }
            "ai_translation_history" => self.translation_history(&d, arg(&r, "selection")?),
            "ai_translation_history_entry" => self.translation_history_entry(&d, &text(&r, "id")?),
            "ai_translation_history_entries" => {
                let values = r["ids"]
                    .as_array()
                    .filter(|values| {
                        !values.is_empty()
                            && values.len() <= crate::reading_history::MAX_TRANSLATION_HISTORY_BATCH
                    })
                    .ok_or("Choose between 1 and 16 saved translations per history read.")?;
                let ids = values
                    .iter()
                    .map(|value| {
                        value
                            .as_str()
                            .ok_or("Saved translation identities must be strings.")
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                self.translation_history_entries(&d, &ids).map(Value::Array)
            }

            "ai_chat_sessions" => self.chat_sessions(&d),
            "ai_chat_session" => self.chat_session(&d, &text(&r, "id")?),
            "ai_chat_draft" => self.save_chat_draft(&d, arg(&r, "draft")?),
            "ai_reading_tasks" => {
                let scope = if r.get("selection").is_some() {
                    if r.get("source_id").is_some() {
                        return Err(
                            "Choose either a reading-task selection or source identity.".into()
                        );
                    }
                    let selection: Option<AiSelectionRecord> = arg(&r, "selection")?;
                    if selection.as_ref().is_some_and(|range| {
                        range.page >= d.page_count() || range.start > range.end
                    }) {
                        return Err(
                            "The saved-task selection does not match a valid page and range."
                                .into(),
                        );
                    }
                    Some(lyra_reader_ffi::ai_workspace::ai_reading_scope_key(
                        selection,
                    ))
                } else {
                    None
                };
                self.reading_tasks(
                    &d,
                    &text(&r, "kind")?,
                    scope
                        .as_deref()
                        .or_else(|| r.get("source_id").and_then(Value::as_str)),
                )
            }
            "ai_reading_sync_regions" => self.sync_region_reading_notes(&d),
            "ai_reading_notes" => self.reading_notes(
                &d,
                &text(&r, "query")?,
                r["recent"].as_bool().unwrap_or(true),
            ),
            "ai_reading_note" => self.reading_note(&d, &text(&r, "id")?),
            "ai_reading_note_update" => self.save_reading_note(&d, arg(&r, "draft")?),
            "ai_reading_note_review" => self.resolve_note_review(&d, arg(&r, "review")?),
            "ai_reading_keep" => self.keep_reading_note(&d, &text(&r, "id")?),
            "ai_reading_keep_region" => self.keep_region_note(
                &d,
                &text(&r, "id")?,
                &text(&r, "expected_history_revision")?,
            ),
            "ai_merge_preview" => value(
                build_ai_merge_plan(arg(&r, "request")?)
                    .and_then(|plan| render_ai_plan(plan, AiWireTransport::ChatCompletions)),
            ),
            "ai_summary_prepare" => {
                let mut request = crate::region::request(r["request"].clone())?;
                let account = chatgpt_account(&r["request"])?;
                if account.is_some() {
                    request.base_url = "https://api.openai.com/v1".into();
                    request.reasoning_mode = "default".into();
                    request.reasoning_encoding = "none".into();
                }
                // Only completed, matching document knowledge may enrich this local preview.
                // Questions, selections and chat history are never forwarded to a summary unit.
                request.action = AiActionRecord::SummarizeDocument;
                request.document_knowledge_text = None;
                request.document_knowledge_pages.clear();
                self.enrich_reading(&mut request, &d.document_identity().sha256)?;
                let (mut preview, capture) =
                    crate::summary::prepare(&d, arg(&r, "unit")?, request, account)?;
                let warning = match self
                    .with_summary_store(&d, true, |store, cache| Ok(store.prepare(capture, cache)))
                {
                    Ok(warning) => warning,
                    Err(error) => Some(error),
                };
                preview["cache_warning"] = json!(warning);
                Ok(preview)
            }
            "ai_summary_cached" => self.cached_summary(&d, &r),
            "ai_summary_catalog" => crate::summary::catalog(&d, arg(&r, "request")?),
            "ai_summary_inspect" => crate::summary::inspect(&d, arg(&r, "request")?),
            "ai_summary_batch_prepare" => {
                if self
                    .ai
                    .lock()
                    .map_err(|_| "AI state is unavailable")?
                    .as_ref()
                    .is_some_and(|job| !job.request.is_finished())
                {
                    return Err(
                        "Stop the current response before preparing a summary batch.".into(),
                    );
                }
                let mut request = crate::region::request(r["request"].clone())?;
                let account = chatgpt_account(&r["request"])?.map(str::to_owned);
                if account.is_some() {
                    request.base_url = "https://api.openai.com/v1".into();
                    request.reasoning_mode = "default".into();
                    request.reasoning_encoding = "none".into();
                }
                request.action = AiActionRecord::SummarizeDocument;
                request.document_knowledge_text = None;
                request.document_knowledge_pages.clear();
                self.enrich_reading(&mut request, &d.document_identity().sha256)?;
                self.with_summary_store(&d, true, |store, cache| {
                    self.summary_batch
                        .lock()
                        .map_err(|_| "Summary batch state is unavailable")?
                        .prepare(&d, arg(&r, "batch")?, request, account, store, cache)
                })
            }
            "ai_summary_batch_start" => {
                if self
                    .ai
                    .lock()
                    .map_err(|_| "AI state is unavailable")?
                    .as_ref()
                    .is_some_and(|job| !job.request.is_finished())
                {
                    return Err("Stop the current response before sending a summary batch.".into());
                }
                let root = self
                    .marks
                    .lock()
                    .map_err(|_| "Annotation state is unavailable")?
                    .cache_root()
                    .map(Path::to_path_buf)
                    .map(Ok)
                    .unwrap_or_else(crate::document_cache::default_root)?;
                let account = chatgpt_account(&r)?;
                let credential = if account.is_some() {
                    "chatgpt_access_token"
                } else {
                    "api_key"
                };
                self.summary_batch
                    .lock()
                    .map_err(|_| "Summary batch state is unavailable")?
                    .start(
                        &d,
                        &text(&r, "token")?,
                        text(&r, credential)?,
                        account,
                        root,
                    )
            }
            "ai_summary_batch_poll" => self.with_summary_store(&d, false, |store, cache| {
                self.summary_batch
                    .lock()
                    .map_err(|_| "Summary batch state is unavailable")?
                    .poll(&d, &text(&r, "token")?, store, cache)
            }),
            "ai_summary_batch_cancel" => self.with_summary_store(&d, false, |store, cache| {
                self.summary_batch
                    .lock()
                    .map_err(|_| "Summary batch state is unavailable")?
                    .cancel(&d, &text(&r, "token")?, store, cache)
            }),
            "ai_endpoint" => value(inspect_ai_base_url(text(&r, "base_url")?)),
            "ai_start" => {
                if self
                    .summary_batch
                    .lock()
                    .map_err(|_| "Summary batch state is unavailable")?
                    .is_running()
                {
                    return Err("Stop the summary batch before starting another response.".into());
                }
                let plan: AiPlanRecord = arg(&r, "plan")?;
                let account = chatgpt_account(&r["plan"])?;
                if account != chatgpt_account(&r)? {
                    return Err("The ChatGPT connection changed. Preview the request again.".into());
                }
                if account.is_some() {
                    let eligible = match (plan.action, r["plan"]["kind"].as_str()) {
                        (
                            AiActionRecord::DocumentChat
                            | AiActionRecord::AskSelection
                            | AiActionRecord::SummarizePage,
                            None,
                        ) => true,
                        (
                            AiActionRecord::SummarizeAbstract
                            | AiActionRecord::SummarizeSection
                            | AiActionRecord::SummarizePageLine,
                            None,
                        ) => true,
                        (AiActionRecord::RegionQuestion, None) => {
                            plan.parts.len() == 1 && plan.parts[0].image.is_some()
                        }
                        (AiActionRecord::SummarizeSelection, Some("reading_summary_selection")) => {
                            r["plan"]["reading_scope"]["selection"].is_object()
                        }
                        (AiActionRecord::TranslateSelection, Some("reading_translation"))
                        | (AiActionRecord::SummarizeDocument, Some("reading_summary")) => true,
                        (AiActionRecord::SummarizeDocument, Some("summary_synthesis")) => {
                            r["plan"]["summary_capture"].as_str().is_some()
                        }
                        (
                            AiActionRecord::SummarizeDocument,
                            Some("reading_note_suggestion" | "region_knowledge_note"),
                        ) => r["plan"]["note_capture"].as_str().is_some(),
                        _ => false,
                    };
                    if !eligible
                        || plan.endpoint != lyra_reader_ai::openai::CHATGPT_RESPONSES_ENDPOINT
                    {
                        return Err(
                            "The ChatGPT connection changed. Preview the request again.".into()
                        );
                    }
                }
                let reading = match (r["plan"]["kind"].as_str(), plan.action) {
                    (_, AiActionRecord::DocumentChat) if r.get("chat").is_some() => {
                        let chat: crate::reading_history::ChatInput = arg(&r, "chat")?;
                        Some(ReadingOutput::Chat(Box::new(
                            chat.capture(&plan, d.document_identity().sha256)?,
                        )))
                    }
                    (Some("reading_translation"), AiActionRecord::TranslateSelection) => {
                        let scope: crate::reading_history::ReadingScope =
                            arg(&r["plan"], "reading_scope")?;
                        Some(ReadingOutput::Translation(Box::new(
                            scope.capture_translation(&plan, d.document_identity().sha256)?,
                        )))
                    }
                    (Some("reading_summary"), AiActionRecord::SummarizeDocument) => {
                        let style: ReadingSummaryStyle = arg(&r["plan"], "reading_style")?;
                        let capture=Arc::new(SummaryCapture::new(&plan,d.document_identity().sha256,style.language.clone(),style.detail.clone(),None)?);
                        if plan.parts.len()==1 {
                            Some(ReadingOutput::Summary { capture, model:plan.model.clone() })
                        } else {
                        let request=consolidation_request(&plan,style.reasoning_mode.clone(),style.reasoning_encoding.clone())?;
                        Some(ReadingOutput::Synthesis {
                            request: Box::new(request),
                            style,
                            capture,
                            account: account.map(str::to_owned),
                        })
                        }
                    }
                    (Some("reading_summary_selection"), AiActionRecord::SummarizeSelection) => {
                        let scope: crate::reading_history::ReadingScope = arg(&r["plan"], "reading_scope")?;
                        let selection = scope.selection.filter(|range| range.page < d.page_count() && range.start <= range.end)
                            .ok_or("The summary no longer has a valid source passage.")?;
                        if plan.parts.len() != 1 || plan.source_pages != [selection.page + 1] {
                            return Err("The selected summary does not match its reviewed source.".into());
                        }
                        let capture = Arc::new(SummaryCapture::new(&plan,d.document_identity().sha256,scope.language,scope.detail,
                            Some(lyra_reader_ai::SelectionRange {page: selection.page, start: selection.start, end: selection.end}))?);
                        Some(ReadingOutput::Summary { capture, model: plan.model.clone() })
                    }
                    (Some(kind @ ("reading_note_suggestion" | "region_knowledge_note")), AiActionRecord::SummarizeDocument) => {
                        let token=text(&r["plan"],"note_capture")?;
                        let capture={
                            let mut pending=self.pending_note.lock().map_err(|_|"Note review state is unavailable.")?;
                            if !pending.as_ref().is_some_and(|capture|capture.matches(&token,kind,&plan,&d.document_identity().sha256,account)) {
                                return Err("This note preview changed. Review it again before sending.".into());
                            }
                            pending.take().ok_or("The reviewed note request is unavailable.")?
                        };
                        self.validate_note_review(&d,&capture)?;
                        Some(ReadingOutput::Note(Box::new(capture)))
                    }
                    (Some("summary_synthesis"), AiActionRecord::SummarizeDocument) => {
                        if let Some(token)=r["plan"]["summary_capture"].as_str() {
                            let body=plan.parts.first().map(|part| part.wire_body.as_str()).filter(|body| !body.is_empty())
                                .ok_or("The synthesis request body is missing. Review it again.")?;
                            let pending=self.pending_summary.lock().map_err(|_| "Summary source state is unavailable")?;
                            let capture=pending.as_ref()
                                .filter(|pending|plan.parts.len()==1 && pending.matches(token,body,&d.document_identity().sha256,account))
                                .ok_or("The document or synthesis request changed. Review a fresh summary.")?
                                .capture();
                            Some(ReadingOutput::Summary { capture, model:plan.model.clone() })
                        } else {
                            None
                        }
                    }
                    _ => None,
                }
                .map(|output| ReadingReplies::new(output, plan.parts.len()));
                let analysis = match reading.as_ref().map(|reading| &reading.output) {
                    Some(
                        ReadingOutput::Summary { capture, .. }
                        | ReadingOutput::Synthesis { capture, .. },
                    ) => capture.claim(self, &d)?,
                    _ => None,
                };
                let root = self
                    .marks
                    .lock()
                    .map_err(|_| "Annotation state is unavailable")?
                    .cache_root()
                    .map(Path::to_path_buf)
                    .map(Ok)
                    .unwrap_or_else(crate::document_cache::default_root)?;
                let audit = crate::audit::observer(root, plan.action, plan.is_local);
                let (audit, provenance) =
                    if plan.action == AiActionRecord::RegionQuestion && plan.parts.len() == 1 {
                        if let Some((id, turn)) = r
                            .get("region_id")
                            .and_then(Value::as_str)
                            .zip(r.get("turn_id").and_then(Value::as_str))
                        {
                            let (audit, proof) = crate::region_store::track_request(
                                audit,
                                id.to_owned(),
                                turn.to_owned(),
                                plan.source_pages.clone(),
                            );
                            (audit, Some(proof))
                        } else {
                            (audit, None)
                        }
                    } else {
                        (audit, None)
                    };
                *self
                    .ai_region_sources
                    .lock()
                    .map_err(|_| "Region request state is unavailable")? = provenance;
                let request = {
                    self.summaries
                        .lock()
                        .map_err(|_| "Summary cache state is unavailable")?
                        .start(&d, &plan)?;
                    if account.is_some() {
                        start_chatgpt_request_audited(
                            plan,
                            text(&r, "chatgpt_access_token")?,
                            audit,
                        )
                    } else {
                        start_ai_request_audited(plan, text(&r, "api_key")?, false, Some(audit))
                    }
                    .map_err(|e| e.to_string())?
                };
                let mut current = self.ai.lock().map_err(|_| "AI state is unavailable")?;
                if let Some(old) = current.replace(DesktopAiRequest {
                    request,
                    reading,
                    analysis,
                }) {
                    old.request.cancel();
                }
                Ok(Value::Bool(true))
            }
            "ai_poll" => {
                let mut current = self.ai.lock().map_err(|_| "AI state is unavailable")?;
                if let Some(job) = current.as_mut() {
                    let mut events = job.request.poll();
                    // Error is the final queued event even if the worker has not yet set its
                    // finished flag. The native shell stops polling as soon as it sees Error.
                    let finished = job.request.is_finished()
                        || events
                            .iter()
                            .any(|event| matches!(event, AiEventRecord::Error { .. }));
                    // The worker can finish between draining and observing its finished flag.
                    if finished {
                        events.extend(job.request.poll());
                    }
                    if let Some(reading) = &mut job.reading {
                        reading.observe(&events);
                    }
                    let reading = if finished { job.reading.take() } else { None };
                    let analysis = if finished { job.analysis.take() } else { None };
                    let active = self
                        .summaries
                        .lock()
                        .map_err(|_| "Summary cache state is unavailable")?
                        .has_active();
                    let warning = if active {
                        match self.with_summary_store(&d, false, |store, cache| {
                            Ok(store.poll(cache, &d, &events, finished))
                        }) {
                            Ok(warning) => warning,
                            Err(error) => {
                                self.summaries
                                    .lock()
                                    .map_err(|_| "Summary cache state is unavailable")?
                                    .clear_active();
                                Some(error)
                            }
                        }
                    } else {
                        None
                    };
                    drop(current);
                    let mut result =
                        json!({"events":events,"finished":finished,"cache_warning":warning});
                    match reading.and_then(|reading| reading.publish(&mut result)) {
                        Some(ReadingArchive::Translation(archive)) => {
                            if let Err(error) =
                                archive.and_then(|record| self.archive_translation(&d, record))
                            {
                                result["translation_history_warning"] = json!(error);
                            }
                        }
                        Some(ReadingArchive::Chat(archive)) => match self.archive_chat(&d, archive)
                        {
                            Ok(checkpoint) => result["chat_checkpoint"] = checkpoint,
                            Err(error) => result["chat_history_warning"] = json!(error),
                        },
                        Some(ReadingArchive::Note(capture, answer)) => {
                            let key = capture.result_key();
                            match self.publish_note_review(&d, *capture, answer) {
                                Ok(suggestion) => result[key] = suggestion,
                                Err(error) => result["note_warning"] = json!(error),
                            }
                        }
                        Some(ReadingArchive::NoteSynthesis(capture)) => {
                            *self
                                .pending_note
                                .lock()
                                .map_err(|_| "Note review state is unavailable.")? = Some(*capture);
                        }
                        Some(ReadingArchive::PendingSummary(snapshot)) => {
                            *self
                                .pending_summary
                                .lock()
                                .map_err(|_| "Summary source state is unavailable")? =
                                Some(snapshot);
                        }
                        Some(ReadingArchive::Summary(record)) => {
                            let published = record.and_then(|record| {
                                if record.source_id == reading_scope_key(None) {
                                    let run=analysis.ok_or("The completed summary no longer owns its document analysis.")?;
                                    let (context, id, warning) = self.publish_summary(&d, record, run)?;
                                    if let Some(warning) = warning { result["summary_history_warning"] = json!(warning); }
                                    result["understanding"] = self.adopt_understanding(context)?;
                                    Ok(id)
                                } else {
                                    self.archive_summary_task(&d, record)
                                }
                            });
                            match published {
                                Ok(id) => result["summary_note_source"] = json!(id),
                                Err(error) => result["cache_warning"] = json!(error),
                            }
                        }
                        None => {}
                    }
                    Ok(result)
                } else {
                    Ok(json!({"events":[],"finished":true}))
                }
            }
            "ai_cancel" => {
                if let Some(job) = self
                    .ai
                    .lock()
                    .map_err(|_| "AI state is unavailable")?
                    .as_ref()
                {
                    job.request.cancel();
                }
                Ok(Value::Bool(true))
            }
            _ => Err(format!("Unknown document operation: {op}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn citation_heading_decorates_only_the_preview_response() {
        let text = "[12] A. Author. A useful research title. Example Journal, 2024.";
        let resolved = ResolvedReference {
            reference: ReferenceRecord {
                label: "12".into(),
                text: text.into(),
                page: 2,
                x_pt: 10.0,
                y_pt: 20.0,
                width_pt: 200.0,
                height_pt: 30.0,
                fragments: Vec::new(),
            },
            list_index: 1,
            list_count: 2,
            list_heading: Some("References".into()),
            list_first_page: Some(2),
            list_last_page: Some(4),
            document_wide: false,
            reason: "Same section".into(),
            ambiguous: false,
        };
        let original = serde_json::to_value(&resolved).unwrap();
        let mut preview = reference_preview_value(vec![resolved.clone()]).unwrap();
        assert_eq!(
            preview[0]["reference"]["heading"],
            "A useful research title."
        );
        assert_eq!(preview[0]["reference"]["text"], text);
        preview[0]["reference"]
            .as_object_mut()
            .unwrap()
            .remove("heading");
        assert_eq!(preview[0], original);
        assert!(
            !serde_json::to_value(&resolved.reference)
                .unwrap()
                .as_object()
                .unwrap()
                .contains_key("heading")
        );
        let mut unstructured = resolved;
        unstructured.reference.text = "An unstructured citation".into();
        assert!(
            reference_preview_value(vec![unstructured]).unwrap()[0]["reference"]["heading"]
                .is_null()
        );
    }

    #[test]
    fn inserted_paper_packet_keeps_source_pages_and_facing_partners_unchanged() {
        let source = DocumentLayout::new(
            [
                (100.0, 300.0),
                (100.0, 500.0),
                (100.0, 700.0),
                (100.0, 400.0),
            ],
            20.0,
        );
        let baseline = layout_value(&source, &json!({"mode":"Facing","gap":20})).unwrap();
        let request =
            json!({"mode":"Facing","gap":20,"paper_card":{"page":1,"split_pt":250,"gap_pt":100}});
        let opened = layout_value(&source, &request).unwrap();
        for key in ["pages", "rows", "width", "height", "gap"] {
            assert_eq!(opened[key], baseline[key]);
        }
        assert_eq!(
            opened["paper"]["rows"][1],
            json!({"top":320.0,"height":820.0,"first":1,"count":2})
        );
        assert_eq!(
            opened["paper"]["pages"][1],
            json!({"index":1,"top":320.0,"height":600.0})
        );
        assert_eq!(
            opened["paper"]["pages"][2],
            json!({"index":2,"top":320.0,"height":700.0})
        );
        assert_eq!(opened["paper"]["pages"][3]["top"], 1140.0);
        assert_eq!(opened["paper"]["gap_top"], 570.0);
        let foot = layout_value(
            &source,
            &json!({"mode":"Facing","gap":20,"paper_card":{"page":1,"split_pt":null,"gap_pt":100}}),
        )
        .unwrap();
        assert_eq!(foot["paper"]["gap_top"], 1020.0);
        assert_eq!(foot["paper"]["pages"][1]["height"], 500.0);
        assert_eq!(
            layout_value(
                &source,
                &json!({"mode":"Facing","gap":20,"paper_card":null})
            )
            .unwrap(),
            baseline
        );
        for card in [
            json!({"page":20,"gap_pt":30}),
            json!({"page":1,"gap_pt":-1}),
            json!({"page":1,"split_pt":501,"gap_pt":30}),
            json!({"page":1,"gap_pt":30,"guessed":true}),
        ] {
            assert!(layout_value(&source, &json!({"paper_card":card})).is_err());
        }
    }

    #[test]
    fn oversized_row_snapshot_is_rejected_before_serialization() {
        let layout = DocumentLayout::new(
            std::iter::repeat_n(
                (1.0, 1.0),
                lyra_reader_session::paper::MAX_PAPER_GEOMETRY_ITEMS + 1,
            ),
            0.0,
        );
        assert_eq!(
            layout_rows(&layout).unwrap_err(),
            "The layout row snapshot exceeds its geometry limit"
        );
    }
    use std::{
        fs,
        path::PathBuf,
        sync::atomic::{AtomicU64, Ordering},
    };
    fn fixture_cache_root(path: &Path) -> PathBuf {
        path.ancestors()
            .find(|p| {
                p.file_name().is_some_and(|n| {
                    n.to_string_lossy()
                        .starts_with("lyra-reader-desktop-check-")
                })
            })
            .expect("fixture-owned directory")
            .join("cache")
    }
    fn open_fixture_document(
        path: &Path,
        password: Option<&str>,
    ) -> Result<DesktopDocument, String> {
        DesktopDocument::open_with_cache_root(path, password, Some(&fixture_cache_root(path)))
    }
    fn cache_path(path: &Path) -> PathBuf {
        crate::document_cache::DocumentCache::open(path, &fixture_cache_root(path))
            .unwrap()
            .annotations()
    }
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    struct Fixture {
        directory: PathBuf,
        path: PathBuf,
    }
    impl Fixture {
        fn new(name: &str) -> Self {
            let directory = std::env::temp_dir().join(format!(
                "lyra-reader-desktop-check-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&directory).unwrap();
            let path = directory.join(name);
            fs::copy(
                Path::new(env!("CARGO_MANIFEST_DIR"))
                    .join("../../tests/fixtures")
                    .join(name),
                &path,
            )
            .unwrap();
            Self { directory, path }
        }
        fn open(&self) -> DesktopDocument {
            open_fixture_document(&self.path, None).unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.directory);
        }
    }

    fn saved_region(doc: &DesktopDocument) -> String {
        let capture=crate::render_source::RenderSource::new(doc,false).unwrap().query(json!({"op":"capture_region","page":0,"zoom":1,"rect":{"x":0,"y":0,"width":595,"height":842}})).unwrap();
        let id = crate::marks::uuid().unwrap();
        doc.command(json!({"op":"region_create","id":id,"attachment":capture,"draft":"Keep this synthetic draft"})).unwrap();
        id
    }

    #[test]
    fn native_incremental_index_contract_runs_with_its_own_cold_cache_policy() {
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "document::tests::native_incremental_index_contract_worker",
                "--ignored",
                "--nocapture",
            ])
            .env("LYRA_READER_INDEX_CACHE", "disabled")
            .env("LYRA_READER_INCREMENTAL_INDEX_WORKER", "1")
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
    }

    #[test]
    #[ignore = "run by the parent with an isolated cold-index policy"]
    fn native_incremental_index_contract_worker() {
        if std::env::var("LYRA_READER_INCREMENTAL_INDEX_WORKER")
            .ok()
            .as_deref()
            != Some("1")
        {
            return;
        }
        let mut partial_seen = false;
        for file in [
            "narrative-citation.pdf",
            "booktabs-bounds.pdf",
            "two-column-references.pdf",
        ] {
            let fixture = Fixture::new(file);
            for kind in ["references", "figures"] {
                let expected_doc = fixture.open();
                let expected_source =
                    crate::render_source::RenderSource::new(&expected_doc, false).unwrap();
                let expected = expected_source.query(json!({"op":kind})).unwrap();
                let doc = fixture.open();
                let source = crate::render_source::RenderSource::new(&doc, false).unwrap();
                let mut complete = false;
                for _ in 0..400 {
                    let step = source
                        .query(json!({"op":format!("{kind}_scan_step"),"pages":1,"entries":1}))
                        .unwrap();
                    assert!(step["total_pages"].as_u64().unwrap() > 0);
                    if step["done"].as_bool().unwrap() {
                        assert_eq!(step["records"], expected, "{file}/{kind}");
                        complete = true;
                        break;
                    }
                    partial_seen = true;
                    assert!(step["records"].as_array().unwrap().is_empty());
                }
                assert!(
                    complete,
                    "bounded fixture scan failed to finish: {file}/{kind}"
                );
                assert_eq!(source.query(json!({"op":kind})).unwrap(), expected);
            }
        }
        assert!(
            partial_seen,
            "cold multi-page fixtures must expose an incomplete step"
        );
    }

    #[test]
    fn native_reading_source_lookup_uses_the_shared_matcher_and_pins_its_revision() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let source = crate::render_source::RenderSource::new(&doc, false).unwrap();
        let passage = "Line 1: The quick brown fox jumps over the lazy dog.";
        let expected = serde_json::to_value(
            doc.active()
                .unwrap()
                .locate_ai_reading_source(0, passage.into())
                .unwrap(),
        )
        .unwrap();
        assert!(!expected.as_array().unwrap().is_empty());
        let query = json!({"op":"ai_reading_source","page":0,"text":passage});
        assert_eq!(source.query(query.clone()).unwrap(), expected);
        assert_eq!(source.query(json!({"op":"ai_reading_source","page":0,"text":"ABSENT_SYNTHETIC_READING_SOURCE_ZZZ"})).unwrap(), json!([]));
        for page in [
            json!(-1),
            json!(u64::MAX),
            Value::Null,
            json!("one"),
            json!(1),
        ] {
            assert!(
                source
                    .query(json!({"op":"ai_reading_source","page":page,"text":passage}))
                    .is_err()
            );
        }
        assert!(
            source
                .query(json!({"op":"ai_reading_source","page":0,"text":false}))
                .is_err()
        );
        let repeated_lines = "L\n".repeat(16_385);
        assert!(
            source
                .query(json!({"op":"ai_reading_source","page":0,"text":repeated_lines}))
                .unwrap_err()
                .contains("display budget")
        );
        let oversized = "x".repeat(lyra_reader_ai::chat::MAX_READING_SOURCE_BYTES + 1);
        assert!(
            source
                .query(json!({"op":"ai_reading_source","page":0,"text":oversized}))
                .unwrap_err()
                .contains("supported size")
        );
        doc.command(
            json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}}),
        )
        .unwrap();
        let current = crate::render_source::RenderSource::new(&doc, false).unwrap();
        let rotated = serde_json::to_value(
            doc.active()
                .unwrap()
                .locate_ai_reading_source(0, passage.into())
                .unwrap(),
        )
        .unwrap();
        assert_ne!(rotated, expected);
        assert_eq!(current.query(query.clone()).unwrap(), rotated);
        assert_eq!(source.query(query.clone()).unwrap(), expected);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        drop(current);
        drop(doc);
        fs::remove_file(&fixture.path).unwrap();
        assert_eq!(source.query(query).unwrap(), expected);
    }

    #[test]
    fn native_index_batches_reject_invalid_values_before_advancing() {
        let fixture = Fixture::new("narrative-citation.pdf");
        let doc = fixture.open();
        let source = crate::render_source::RenderSource::new(&doc, false).unwrap();
        for pages in [
            json!(0),
            json!(-1),
            json!(5),
            json!(u64::MAX),
            json!("one"),
            Value::Null,
        ] {
            for op in ["references_scan_step", "figures_scan_step"] {
                assert!(
                    source
                        .query(json!({"op":op,"pages":pages}))
                        .unwrap_err()
                        .contains("Invalid index pages batch")
                );
            }
        }
        assert!(
            source
                .query(json!({"op":"references_scan_step","entries":13}))
                .unwrap_err()
                .contains("Invalid index entries batch")
        );
    }
    fn region_path(path: &Path) -> PathBuf {
        cache_path(path)
            .parent()
            .unwrap()
            .join("region-conversations-v1.json")
    }
    #[test]
    fn interleaf_sync_keeps_manual_notes_and_is_a_byte_preserving_local_noop() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let path = cache_path(&fixture.path).with_file_name("ai-reading-workspace.json");
        let pdf = fs::read(&fixture.path).unwrap();
        assert_eq!(
            doc.command(json!({"op":"ai_reading_sync_regions"}))
                .unwrap()["changed"],
            false
        );
        assert!(!path.exists());
        let region = saved_region(&doc);
        doc.command(json!({"op":"region_note","id":region,"text":"Original knowledge"}))
            .unwrap();
        let history_path = region_path(&fixture.path);
        let history = fs::read(&history_path).unwrap();
        let report = doc
            .command(json!({"op":"ai_reading_sync_regions"}))
            .unwrap();
        assert_eq!(report["created"], 1);
        assert_eq!(fs::read(&history_path).unwrap(), history);
        let list = doc
            .command(json!({"op":"ai_reading_notes","query":"","recent":false}))
            .unwrap();
        let id = list[0]["id"].as_str().unwrap();
        let mut note = doc
            .command(json!({"op":"ai_reading_note","id":id}))
            .unwrap();
        assert!(!note["source"]["excerpt"].as_str().unwrap().is_empty());
        note = doc.command(json!({"op":"ai_reading_note_update","draft":{"id":id,
            "expected_modified":note["modified"],"title":"My title","content":"My edited ideas","thoughts":"Private thoughts"}})).unwrap();
        // Preserve an externally formatted but valid file exactly on a semantic no-op.
        let pretty = serde_json::to_vec_pretty(
            &serde_json::from_slice::<Value>(&fs::read(&path).unwrap()).unwrap(),
        )
        .unwrap();
        fs::write(&path, &pretty).unwrap();
        assert_eq!(
            doc.command(json!({"op":"ai_reading_sync_regions"}))
                .unwrap()["changed"],
            false
        );
        assert_eq!(fs::read(&path).unwrap(), pretty);
        doc.command(json!({"op":"region_note","id":region,"text":"New generated ideas"}))
            .unwrap();
        assert_eq!(
            doc.command(json!({"op":"ai_reading_sync_regions"}))
                .unwrap()["updated"],
            1
        );
        let after = doc
            .command(json!({"op":"ai_reading_note","id":id}))
            .unwrap();
        for field in ["id", "title", "content", "thoughts", "modified"] {
            assert_eq!(after[field], note[field], "{field}");
        }
        assert_eq!(after["suggestion"]["content"], "New generated ideas");
        // An already open Thoughts draft still uses its original edit version.
        doc.command(json!({"op":"ai_reading_note_update","draft":{"id":id,
            "expected_modified":note["modified"],"thoughts":"Late thoughts"}}))
            .unwrap();
        assert_eq!(
            doc.command(json!({"op":"ai_reading_notes","query":"","recent":false}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), pdf);
    }
    #[test]
    fn interleaf_sync_protects_unknown_revisions_corruption_and_busy_history() {
        use fs2::FileExt;
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let region = saved_region(&doc);
        doc.command(json!({"op":"region_note","id":region,"text":"Saved ideas"}))
            .unwrap();
        doc.command(json!({"op":"ai_reading_sync_regions"}))
            .unwrap();
        let workspace_path = cache_path(&fixture.path).with_file_name("ai-reading-workspace.json");
        let workspace = fs::read(&workspace_path).unwrap();
        let path = region_path(&fixture.path);
        let raw = fs::read(&path).unwrap();
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(path.with_file_name(".region-conversations.lock"))
            .unwrap();
        FileExt::try_lock_exclusive(&lock).unwrap();
        assert!(
            doc.command(json!({"op":"ai_reading_sync_regions"}))
                .unwrap_err()
                .contains("Another window")
        );
        drop(lock);
        for corrupt in [b"not JSON".to_vec(), {
            let mut value: Value = serde_json::from_slice(&raw).unwrap();
            let duplicate = value[0].clone();
            value.as_array_mut().unwrap().push(duplicate);
            serde_json::to_vec(&value).unwrap()
        }] {
            fs::write(&path, &corrupt).unwrap();
            assert!(
                doc.command(json!({"op":"ai_reading_sync_regions"}))
                    .is_err()
            );
            assert_eq!(fs::read(&path).unwrap(), corrupt);
            assert_eq!(fs::read(&workspace_path).unwrap(), workspace);
        }
        let mut unverified: Value = serde_json::from_slice(&raw).unwrap();
        unverified[0]
            .as_object_mut()
            .unwrap()
            .remove("captureSha256");
        let bytes = serde_json::to_vec(&unverified).unwrap();
        fs::write(&path, &bytes).unwrap();
        let report = doc
            .command(json!({"op":"ai_reading_sync_regions"}))
            .unwrap();
        assert_eq!(report["changed"], false);
        assert_eq!(report["skipped"], 1);
        assert!(!report["warning"].as_str().unwrap().is_empty());
        assert_eq!(fs::read(&path).unwrap(), bytes);
        assert_eq!(fs::read(&workspace_path).unwrap(), workspace);
    }
    #[test]
    fn legacy_region_append_preserves_the_top_level_answer_before_a_new_turn() {
        use lyra_reader_ai::region_history::{AnswerState, History};
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let id = saved_region(&doc);
        let path = region_path(&fixture.path);
        drop(doc);
        let mut history = History::decode(&fs::read(&path).unwrap()).unwrap();
        let mut entry = history.get(&id).unwrap().clone();
        entry.question = "LEGACY_QUESTION".into();
        entry.answer = "LEGACY_ANSWER".into();
        entry.state = AnswerState::Finished;
        let date = entry.created_at;
        history.put(entry).unwrap();
        fs::write(&path, history.encode().unwrap()).unwrap();
        let doc = fixture.open();
        let state = doc.command(json!({"op":"region_list"})).unwrap();
        let restored = doc
            .command(
                json!({"op":"region_reopen","id":id,"expected_history_revision":state["revision"]}),
            )
            .unwrap();
        assert_eq!(restored["latest_turn"]["turn_id"], id);
        assert_eq!(restored["latest_turn"]["output"], "LEGACY_ANSWER");
        assert!(
            restored["latest_turn"]["source_pages"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let turn = crate::marks::uuid().unwrap();
        doc.command(json!({"op":"region_snapshot","id":id,"draft":"","turn":{"id":turn,"question":"NEW_QUESTION","answer":"NEW_ANSWER","state":"finished"}})).unwrap();
        let saved = doc.command(json!({"op":"region_get","id":id})).unwrap();
        assert_eq!(saved["turns"].as_array().unwrap().len(), 2);
        assert_eq!(saved["turns"][0]["id"], id);
        assert_eq!(saved["turns"][0]["createdAt"], date);
        assert_eq!(saved["turns"][0]["answer"], "LEGACY_ANSWER");
        assert_eq!(saved["turns"][1]["answer"], "NEW_ANSWER");
        assert!(saved["turns"][0]["sourcePages"].is_null());
    }
    #[test]
    fn region_followup_context_uses_completed_stored_turns_and_rejects_changed_capture() {
        use lyra_reader_ai::region_history::{AnswerState, History, Turn};
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let id = saved_region(&doc);
        let path = region_path(&fixture.path);
        drop(doc);
        let mut history = History::decode(&fs::read(&path).unwrap()).unwrap();
        let mut entry = history.get(&id).unwrap().clone();
        entry.turns = [
            AnswerState::Finished,
            AnswerState::Cancelled,
            AnswerState::Failed,
            AnswerState::Empty,
        ]
        .into_iter()
        .enumerate()
        .map(|(i, state)| Turn {
            id: crate::marks::uuid().unwrap(),
            question: format!("HISTORY_QUESTION_{i}"),
            answer: format!("HISTORY_ANSWER_{i}"),
            state,
            error: None,
            created_at: 0.0,
            source_pages: None,
        })
        .collect();
        history.put(entry.clone()).unwrap();
        let cached = history.encode().unwrap();
        fs::write(&path, &cached).unwrap();
        let doc = fixture.open();
        let state = doc.command(json!({"op":"region_list"})).unwrap();
        let mut region = doc
            .command(
                json!({"op":"region_reopen","id":id,"expected_history_revision":state["revision"]}),
            )
            .unwrap();
        region["send_image"] = json!(false);
        region["include_document_context"] = json!(false);
        let request = json!({"action":"RegionQuestion","document_knowledge":false,"document_knowledge_text":null,"document_knowledge_pages":[],
            "current_page":0,"selection":null,"question":"NEXT_SYNTHETIC_QUESTION","language":null,"history":[{"question":"FORGED_UI_CONTEXT","answer":"NOT_STORED"}],
            "base_url":"http://localhost:11434/v1","model":"synthetic-context","temperature":null,"max_tokens":null,"reasoning_mode":"default","reasoning_encoding":"none","region":region});
        let plan = doc
            .command(json!({"op":"ai_preview","request":request,"region_history_id":id}))
            .unwrap();
        let body = plan["parts"][0]["wire_body"].as_str().unwrap();
        assert!(body.contains("HISTORY_ANSWER_0"));
        for i in 1..4 {
            assert!(!body.contains(&format!("HISTORY_ANSWER_{i}")));
        }
        assert!(!body.contains("FORGED_UI_CONTEXT"));
        let mut changed = request.clone();
        changed["region"]["text"] = json!("CHANGED_CAPTURE_TEXT");
        assert!(
            doc.command(json!({"op":"ai_preview","request":changed,"region_history_id":id}))
                .unwrap_err()
                .contains("region changed")
        );
        assert_eq!(fs::read(&path).unwrap(), cached);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        drop(doc);
        entry.attachment.rect[1][0] = 1e100;
        history.put(entry).unwrap();
        let oversized = history.encode().unwrap();
        fs::write(&path, &oversized).unwrap();
        let doc = fixture.open();
        let state = doc.command(json!({"op":"region_list"})).unwrap();
        assert_eq!(
            doc.command(json!({"op":"region_get","id":id})).unwrap()["can_reopen"],
            false
        );
        assert!(
            doc.command(
                json!({"op":"region_reopen","id":id,"expected_history_revision":state["revision"]})
            )
            .unwrap_err()
            .contains("outside the page bounds")
        );
        assert_eq!(fs::read(&path).unwrap(), oversized);
    }
    #[test]
    fn saved_region_reopens_frozen_bytes_and_refuses_stale_geometry_without_writing() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let id = saved_region(&doc);
        let history = fs::read(region_path(&fixture.path)).unwrap();
        let state = doc.command(json!({"op":"region_list"})).unwrap();
        let entry = doc.command(json!({"op":"region_get","id":id})).unwrap();
        assert_eq!(entry["can_reopen"], true);
        let reopened = doc
            .command(
                json!({"op":"region_reopen","id":id,"expected_history_revision":state["revision"]}),
            )
            .unwrap();
        assert_eq!(reopened["history_id"], id);
        assert_eq!(reopened["image_png"], entry["attachment"]["png"]);
        assert_eq!(reopened["text"], entry["attachment"]["text"]);
        assert_eq!(reopened["question"], entry["draftQuestion"]);
        assert_eq!(reopened["completed_turn_count"], 0);
        assert_eq!(fs::read(region_path(&fixture.path)).unwrap(), history);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert!(
            doc.command(json!({"op":"region_reopen","id":id,"expected_history_revision":"stale"}))
                .unwrap_err()
                .contains("changed")
        );
        doc.command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":0}}}))
            .unwrap();
        let state = doc.command(json!({"op":"region_list"})).unwrap();
        assert!(
            doc.command(
                json!({"op":"region_reopen","id":id,"expected_history_revision":state["revision"]})
            )
            .is_err()
        );
        let stale = doc.command(json!({"op":"region_get","id":id})).unwrap();
        assert_eq!(stale["can_reopen"], false);
        assert_eq!(stale["attachment"], entry["attachment"]);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }
    #[test]
    fn region_thumbnails_read_one_reviewed_attachment_without_rewriting_history() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let id = saved_region(&doc);
        let history = fs::read(region_path(&fixture.path)).unwrap();
        let state = doc.command(json!({"op":"region_list"})).unwrap();
        let image = doc
            .command(json!({"op":"region_thumbnail","id":id,
            "expected_history_revision":state["revision"]}))
            .unwrap();
        let entry = doc.command(json!({"op":"region_get","id":id})).unwrap();
        assert_eq!(image["png"], entry["attachment"]["png"]);
        assert_eq!(image["width"], entry["attachment"]["pixelWidth"]);
        assert_eq!(image["id"], id);
        assert_eq!(image["revision"], state["revision"]);
        assert!(image.get("attachment").is_none());
        assert!(image.get("turns").is_none());
        assert_eq!(fs::read(region_path(&fixture.path)).unwrap(), history);
        doc.command(json!({"op":"region_note","id":id,"text":"New local note"}))
            .unwrap();
        let saved = fs::read(region_path(&fixture.path)).unwrap();
        assert!(
            doc.command(json!({"op":"region_thumbnail","id":id,
            "expected_history_revision":state["revision"]}))
                .unwrap_err()
                .contains("changed")
        );
        assert_eq!(fs::read(region_path(&fixture.path)).unwrap(), saved);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }
    #[test]
    fn region_export_uses_the_reviewed_saved_snapshot_and_never_rewrites_source_or_cache() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let id = saved_region(&doc);
        let initial = doc.command(json!({"op":"region_list"})).unwrap();
        assert_eq!(initial["entries"][0]["has_answer"], false);
        let destination = fixture.directory.join("notes.md");
        assert!(doc.command(json!({"op":"region_export_markdown","destination":destination,"expected_history_revision":initial["revision"]})).unwrap_err().contains("no saved region conversations"));
        doc.command(json!({"op":"region_note","id":id,"text":"A synthetic note α/β"}))
            .unwrap();
        let snapshot = doc.command(json!({"op":"region_list"})).unwrap();
        assert_eq!(snapshot["entries"][0]["has_answer"], true);
        let history = fs::read(region_path(&fixture.path)).unwrap();
        assert!(doc.command(json!({"op":"region_export_markdown","destination":destination,"expected_history_revision":initial["revision"]})).unwrap_err().contains("changed"));
        assert!(!destination.exists());
        assert!(!fixture.directory.join("notes-images").exists());
        let outcome=doc.command(json!({"op":"region_export_markdown","destination":destination,"expected_history_revision":snapshot["revision"]})).unwrap();
        assert_eq!(outcome["image_count"], 1);
        assert_eq!(outcome["omitted_count"], 0);
        let markdown = fs::read_to_string(&destination).unwrap();
        assert!(markdown.contains("A synthetic note α/β"));
        assert!(!markdown.contains("data:image"));
        let entry = doc.command(json!({"op":"region_get","id":id})).unwrap();
        let image =
            lyra_reader_edit::records::base64_decode(entry["attachment"]["png"].as_str().unwrap())
                .unwrap();
        assert_eq!(
            fs::read(fixture.directory.join("notes-images/region-01.png")).unwrap(),
            image
        );
        assert_eq!(fs::read(region_path(&fixture.path)).unwrap(), history);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert!(doc.command(json!({"op":"region_export_markdown","destination":destination,"expected_history_revision":snapshot["revision"]})).is_err());
        assert_eq!(fs::read_to_string(destination).unwrap(), markdown);
        let mut external = history.clone();
        external.push(b' ');
        fs::write(region_path(&fixture.path), &external).unwrap();
        assert!(doc.command(json!({"op":"region_export_markdown","destination":fixture.directory.join("external.md"),"expected_history_revision":snapshot["revision"]})).unwrap_err().contains("outside this window"));
        assert!(!fixture.directory.join("external.md").exists());
        assert_eq!(fs::read(region_path(&fixture.path)).unwrap(), external);
    }
    #[test]
    fn region_reopen_rejects_external_history_and_list_refreshes_its_revision() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let id = saved_region(&doc);
        let snapshot = doc.command(json!({"op":"region_list"})).unwrap();
        let path = region_path(&fixture.path);
        let mut external = fs::read(&path).unwrap();
        external.push(b' ');
        fs::write(&path, &external).unwrap();
        let Err(error) = doc.command(json!({"op":"region_reopen","id":id,
            "expected_history_revision":snapshot["revision"]}))
        else {
            panic!("A stale region revision must not reopen");
        };
        assert!(error.contains("changed"));
        let fresh = doc.command(json!({"op":"region_list"})).unwrap();
        assert_ne!(fresh["revision"], snapshot["revision"]);
        assert_eq!(fresh["entries"][0]["id"], id);
        doc.command(
            json!({"op":"region_reopen","id":id,"expected_history_revision":fresh["revision"]}),
        )
        .unwrap();
        assert_eq!(fs::read(path).unwrap(), external);
    }
    #[test]
    fn region_history_reopens_without_raster_or_pdf_writes_and_retains_saved_drafts() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let id = saved_region(&doc);
        let before = doc.command(json!({"op":"region_get","id":id})).unwrap();
        assert_eq!(before["draftQuestion"], "Keep this synthetic draft");
        assert!(
            before["attachment"]["text"]
                .as_str()
                .unwrap()
                .contains("quick brown fox")
        );
        assert_eq!(
            doc.command(json!({"op":"marks"})).unwrap()["pdf_dirty"],
            false
        );
        drop(doc);
        let doc = fixture.open();
        assert_eq!(
            doc.command(json!({"op":"region_get","id":id})).unwrap(),
            before
        );
        doc.command(json!({"op":"region_note","id":id,"text":"My / knowledge note"}))
            .unwrap();
        let raw = fs::read(region_path(&fixture.path)).unwrap();
        let next = fixture.open();
        assert_eq!(
            next.command(json!({"op":"region_get","id":id})).unwrap()["knowledgeNote"],
            "My / knowledge note"
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert!(raw.windows(2).any(|p| p == b"\\/"));
        let backup =
            region_path(&fixture.path).with_file_name("region-conversations-v1.previous.json");
        assert!(backup.exists());
    }
    #[test]
    fn region_history_keeps_frozen_content_through_edits_discard_save_and_save_as() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let id = saved_region(&doc);
        let before = doc.command(json!({"op":"region_get","id":id})).unwrap();
        doc.command(
            json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}}),
        )
        .unwrap();
        let changed = doc.command(json!({"op":"region_get","id":id})).unwrap();
        assert_eq!(changed["attachment"], before["attachment"]);
        assert_eq!(changed["locationInvalidated"], true);
        doc.command(json!({"op":"document_discard"})).unwrap();
        assert_eq!(
            doc.command(json!({"op":"region_get","id":id})).unwrap()["locationInvalidated"],
            false
        );
        let copy = fixture.directory.join("copy.pdf");
        let outcome = doc
            .command(json!({"op":"save_document_copy","destination":copy}))
            .unwrap();
        assert!(outcome["cache_cleanup_error"].is_null(), "{outcome}");
        let copied = open_fixture_document(&copy, None).unwrap();
        copied.command(json!({"op":"region_note","id":id,"text":"Keep destination's different local history"})).unwrap();
        let copy_cache = region_path(&copy);
        let copy_notes = fs::read(&copy_cache).unwrap();
        let repeated = doc
            .command(json!({"op":"save_document_copy","destination":copy}))
            .unwrap();
        assert!(
            repeated["cache_cleanup_error"]
                .as_str()
                .unwrap()
                .contains("reading notes"),
            "{repeated}"
        );
        assert_eq!(fs::read(&copy_cache).unwrap(), copy_notes);

        assert_eq!(
            copied.command(json!({"op":"region_get","id":id})).unwrap()["attachment"],
            before["attachment"]
        );
        doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":3,"color":"#E8BC5552","note":"A saved mark"}})).unwrap();
        let bytes = fs::read(region_path(&fixture.path)).unwrap();
        doc.command(json!({"op":"document_save"})).unwrap();
        assert_eq!(fs::read(region_path(&fixture.path)).unwrap(), bytes);
        assert_eq!(
            doc.command(json!({"op":"region_get","id":id})).unwrap()["attachment"],
            before["attachment"]
        );
    }
    #[test]
    fn region_history_refuses_external_cache_edits_corruption_and_changed_pdf_without_overwriting()
    {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let id = saved_region(&doc);
        let other = fixture.open();
        other.command(json!({"op":"region_list"})).unwrap();
        doc.command(json!({"op":"region_note","id":id,"text":"First window"}))
            .unwrap();
        let raw = fs::read(region_path(&fixture.path)).unwrap();
        assert!(
            other
                .command(json!({"op":"region_note","id":id,"text":"Stale window"}))
                .unwrap_err()
                .contains("outside")
        );
        assert_eq!(fs::read(region_path(&fixture.path)).unwrap(), raw);
        fs::write(region_path(&fixture.path), b"broken history").unwrap();
        let broken = fixture.open();
        assert!(
            broken.command(json!({"op":"region_list"})).unwrap()["error"]
                .as_str()
                .unwrap()
                .contains("could not be read")
        );
        assert!(
            broken
                .command(json!({"op":"region_delete","id":id}))
                .is_err()
        );
        assert_eq!(
            fs::read(region_path(&fixture.path)).unwrap(),
            b"broken history"
        );
        fs::write(region_path(&fixture.path), &raw).unwrap();
        let clean = fixture.open();
        clean.command(json!({"op":"region_list"})).unwrap();
        let mut pdf = fs::read(&fixture.path).unwrap();
        pdf.extend_from_slice(b"\n% external edit");
        fs::write(&fixture.path, &pdf).unwrap();
        assert!(
            clean
                .command(json!({"op":"region_note","id":id,"text":"Blocked"}))
                .unwrap_err()
                .contains("changed outside")
        );
        assert_eq!(fs::read(region_path(&fixture.path)).unwrap(), raw);
    }
    #[test]
    fn region_autosave_extends_only_the_current_unfinished_request_and_keeps_durable_drafts() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let id = saved_region(&doc);
        let turn = crate::marks::uuid().unwrap();
        let audit = crate::audit::observer(
            fixture.directory.clone(),
            AiActionRecord::RegionQuestion,
            true,
        );
        let (audit, proof) =
            crate::region_store::track_request(audit, id.clone(), turn.clone(), vec![1]);
        audit.started().unwrap();
        *doc.ai_region_sources.lock().unwrap() = Some(proof);
        let snapshot = |answer: &str, state: &str| json!({"op":"region_snapshot","id":id,"draft":"LATEST_LOCAL_DRAFT","turn":{"id":turn,"state":state,"question":"SENT_QUESTION","answer":answer}});
        doc.command(snapshot("Partial", "empty")).unwrap();
        let first = doc.command(json!({"op":"region_get","id":id})).unwrap();
        assert_eq!(first["turns"][0]["sourcePages"], json!([1]));
        let created = first["turns"][0]["createdAt"].clone();
        // A second reader has no current-request proof, including after process restart.
        let reopened = fixture.open();
        assert_eq!(
            reopened
                .command(json!({"op":"region_get","id":id}))
                .unwrap(),
            first
        );
        let before = fs::read(region_path(&fixture.path)).unwrap();
        assert!(
            reopened
                .command(snapshot("Partial forged", "finished"))
                .unwrap_err()
                .contains("different contents")
        );
        assert_eq!(fs::read(region_path(&fixture.path)).unwrap(), before);
        doc.command(snapshot("Partial answer", "empty")).unwrap();
        assert!(doc.command(snapshot("Replacement", "empty")).is_err());
        doc.command(snapshot("Partial answer", "cancelled"))
            .unwrap();
        let final_record = doc.command(json!({"op":"region_get","id":id})).unwrap();
        assert_eq!(final_record["turns"].as_array().unwrap().len(), 1);
        assert_eq!(final_record["turns"][0]["createdAt"], created);
        assert_eq!(final_record["draftQuestion"], "LATEST_LOCAL_DRAFT");
        assert_eq!(final_record["turns"][0]["state"], "cancelled");
        let final_bytes = fs::read(region_path(&fixture.path)).unwrap();
        assert!(
            doc.command(snapshot("Partial answer edited", "finished"))
                .is_err()
        );
        assert_eq!(fs::read(region_path(&fixture.path)).unwrap(), final_bytes);
        drop(reopened);
        drop(doc);
        assert_eq!(
            fixture
                .open()
                .command(json!({"op":"region_get","id":id}))
                .unwrap(),
            final_record
        );
    }

    #[test]
    fn region_history_never_trusts_ui_supplied_page_markers_and_snapshot_retry_is_idempotent() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let id = saved_region(&doc);
        let turn = crate::marks::uuid().unwrap();
        let snapshot = json!({"op":"region_snapshot","id":id,"draft":"Follow-up draft","turn":{"id":turn,"state":"finished","question":"Question","answer":"Answer [p.999]","source_pages":[999]}});
        doc.command(snapshot.clone()).unwrap();
        let first = doc.command(json!({"op":"region_get","id":id})).unwrap();
        assert!(first["turns"][0]["sourcePages"].is_null());
        doc.command(snapshot).unwrap();
        let after = doc.command(json!({"op":"region_get","id":id})).unwrap();
        assert_eq!(after["turns"].as_array().unwrap().len(), 1);
        assert_eq!(first, after);
        let forged = json!({"op":"region_snapshot","id":id,"draft":"","turn":{"id":turn,"state":"finished","question":"Question","answer":"Changed answer"}});
        assert!(
            doc.command(forged.clone())
                .unwrap_err()
                .contains("different contents")
        );
        assert_eq!(
            doc.command(json!({"op":"region_get","id":id})).unwrap(),
            after
        );

        let path = region_path(&fixture.path);
        let original = fs::read(&path).unwrap();
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path.with_file_name(".region-conversations.lock"))
            .unwrap();
        fs2::FileExt::try_lock_exclusive(&lock).unwrap();
        assert!(
            doc.command(json!({"op":"region_delete","id":id}))
                .unwrap_err()
                .contains("Another window")
        );
        assert_eq!(fs::read(&path).unwrap(), original);
    }
    #[test]
    fn partial_ink_preview_is_transient_and_one_atomic_history_step() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let original = fs::read(&fixture.path).unwrap();
        let created=doc.command(json!({"op":"mark_create","entry":{"kind":"ink","page":0,"version":1,"paths":[[{"x":100,"y":200},{"x":150,"y":200},{"x":250,"y":200},{"x":300,"y":200}]],"strokeWidth":2,"color":"#1B7F3BFF","note":"keep my ink note"}})).unwrap();
        let id = created["selected_id"].as_str().unwrap();
        let sidecar = cache_path(&fixture.path);
        let baseline = fs::read(&sidecar).unwrap();
        let segments = json!([{"from":{"x":200,"y":170},"to":{"x":200,"y":230}}]);
        let begin=doc.command(json!({"op":"ink_erase_begin","token":"first","page":0,"zoom":1,"segments":segments})).unwrap();
        assert_eq!(begin["hidden"], json!([id]));
        assert_eq!(begin["annotations"].as_array().unwrap().len(), 2);
        assert_eq!(fs::read(&sidecar).unwrap(), baseline);
        assert!(
            (begin["annotations"][0]["paths"][0]
                .as_array()
                .unwrap()
                .last()
                .unwrap()["x"]
                .as_f64()
                .unwrap()
                - 191.)
                .abs()
                < 1e-9
        );
        doc.command(json!({"op":"ink_erase_cancel","token":"first"}))
            .unwrap();
        assert!(
            doc.command(json!({"op":"ink_erase_commit","token":"first","segments":[]}))
                .is_err()
        );
        assert_eq!(fs::read(&sidecar).unwrap(), baseline);
        doc.command(
            json!({"op":"ink_erase_begin","token":"cut","page":0,"zoom":1,"segments":segments}),
        )
        .unwrap();
        let preview=doc.command(json!({"op":"ink_erase_preview","token":"cut","segments":[{"from":{"x":270,"y":180},"to":{"x":270,"y":220}}]})).unwrap();
        let committed = doc
            .command(json!({"op":"ink_erase_commit","token":"cut","segments":[]}))
            .unwrap();
        assert_eq!(committed["erase_changed"], 1);
        assert_eq!(committed["annotations"].as_array().unwrap().len(), 3);
        for (p, c) in preview["annotations"]
            .as_array()
            .unwrap()
            .iter()
            .zip(committed["annotations"].as_array().unwrap())
        {
            assert_eq!(p["paths"], c["paths"]);
            assert_eq!(c["note"], "keep my ink note");
        }
        let undo = doc.command(json!({"op":"marks_undo"})).unwrap();
        assert_eq!(undo["annotations"].as_array().unwrap().len(), 1);
        assert_eq!(undo["annotations"][0]["id"], id);
        assert_eq!(fs::read(&sidecar).unwrap(), baseline);
        doc.command(json!({"op":"ink_erase_begin","token":"miss","page":0,"zoom":2,"segments":[{"from":{"x":0,"y":0},"to":{"x":1,"y":1}}]})).unwrap();
        let miss = doc
            .command(json!({"op":"ink_erase_commit","token":"miss","segments":[]}))
            .unwrap();
        assert_eq!(miss["erase_changed"], 0);
        assert_eq!(miss["can_redo"], true);
        assert_eq!(fs::read(&sidecar).unwrap(), baseline);
        let redo = doc.command(json!({"op":"marks_redo"})).unwrap();
        assert_eq!(redo["annotations"], committed["annotations"]);
        doc.command(json!({"op":"ink_erase_begin","token":"external","page":0,"zoom":1,"segments":[{"from":{"x":125,"y":180},"to":{"x":125,"y":220}}]})).unwrap();
        let mut external = fs::read(&sidecar).unwrap();
        external.extend_from_slice(b" ");
        fs::write(&sidecar, &external).unwrap();
        assert!(
            doc.command(json!({"op":"ink_erase_commit","token":"external","segments":[]}))
                .is_err()
        );
        assert_eq!(fs::read(&sidecar).unwrap(), external);
        assert_eq!(
            doc.command(json!({"op":"marks"})).unwrap()["annotations"],
            committed["annotations"]
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn partial_ink_invalid_preview_or_intervening_edit_cannot_commit_a_stale_cut() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let created=doc.command(json!({"op":"mark_create","entry":{"kind":"ink","page":0,"version":1,"paths":[[{"x":100,"y":200},{"x":300,"y":200}]],"strokeWidth":2,"color":"#000000FF","note":""}})).unwrap();
        let id = created["selected_id"].as_str().unwrap();
        let sweep = json!([{"from":{"x":200,"y":150},"to":{"x":200,"y":250}}]);
        let preview = doc
            .command(
                json!({"op":"ink_erase_begin","token":"zoom","page":0,"zoom":2,"segments":sweep}),
            )
            .unwrap();
        let end = preview["annotations"][0]["paths"][0]
            .as_array()
            .unwrap()
            .last()
            .unwrap();
        assert!((end["x"].as_f64().unwrap() - 195.).abs() < 1e-9);
        assert!(doc.command(json!({"op":"ink_erase_preview","token":"zoom","segments":[{"from":{"x":125,"y":200}}]})).is_err());
        assert!(
            doc.command(json!({"op":"ink_erase_commit","token":"zoom","segments":[]}))
                .is_err()
        );
        doc.command(
            json!({"op":"ink_erase_begin","token":"edit","page":0,"zoom":1,"segments":sweep}),
        )
        .unwrap();
        doc.command(json!({"op":"mark_update","id":id,"patch":{"note":"new note"}}))
            .unwrap();
        assert!(
            doc.command(json!({"op":"ink_erase_commit","token":"edit","segments":[]}))
                .is_err()
        );
        let marks = doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(marks["annotations"].as_array().unwrap().len(), 1);
        assert_eq!(marks["annotations"][0]["note"], "new note");
    }

    #[test]
    fn partial_ink_refuses_review_threads_but_splits_bare_file_ink_and_reopens() {
        let fixture = Fixture::new("annotated-ink-review.pdf");
        let doc = fixture.open();
        let original = fs::read(&fixture.path).unwrap();
        let raw = doc.command(json!({"op":"annotations"})).unwrap();
        let records = raw.as_array().unwrap();
        let review = records
            .iter()
            .find(|a| a["id"] == "nm:review-ink-commented")
            .unwrap();
        assert_eq!(review["has_popup"], true);
        let sweep = json!([{"from":{"x":250,"y":0},"to":{"x":250,"y":1000}}]);
        let preview = doc
            .command(
                json!({"op":"ink_erase_begin","token":"mixed","page":0,"zoom":1,"segments":sweep}),
            )
            .unwrap();
        assert_eq!(preview["hidden"], json!(["nm:review-ink-bare"]));
        assert_eq!(preview["refused"], json!([review["id"]]));
        let state = doc
            .command(json!({"op":"ink_erase_commit","token":"mixed","segments":[]}))
            .unwrap();
        assert_eq!(state["erase_changed"], 1);
        assert_eq!(state["pending_deletions"], 1);
        assert_eq!(state["annotations"].as_array().unwrap().len(), 2);
        let output = fixture.directory.join("cut.pdf");
        doc.command(json!({"op":"save_current_annotations","destination":output}))
            .unwrap();
        let saved = open_fixture_document(&output, None)
            .unwrap()
            .command(json!({"op":"annotations"}))
            .unwrap();
        let saved = saved.as_array().unwrap();
        assert_eq!(saved.len(), records.len() + 1);
        assert!(
            saved
                .iter()
                .any(|a| a["id"] == review["id"] && a["has_popup"] == true)
        );
        assert!(!saved.iter().any(|a| a["id"] == "nm:review-ink-bare"));
        for reply in records.iter().filter(|a| a["parent_id"] == review["id"]) {
            assert!(saved.iter().any(|a| a["id"] == reply["id"]
                && a["parent_id"] == reply["parent_id"]
                && a["visible"] == reply["visible"]));
        }
        let undone = doc.command(json!({"op":"marks_undo"})).unwrap();
        assert_eq!(undone["pending_deletions"], 0);
        assert!(undone["annotations"].as_array().unwrap().is_empty());
        let adopted = doc
            .command(json!({"op":"file_adopt","id":review["id"]}))
            .unwrap();
        let id = adopted["selected_id"].as_str().unwrap();
        doc.command(json!({"op":"mark_update","id":id,"patch":{"note":""}}))
            .unwrap();
        let preview=doc.command(json!({"op":"ink_erase_begin","token":"adopted","page":0,"zoom":1,"segments":sweep})).unwrap();
        assert!(
            preview["refused"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v == id)
        );
        assert!(
            !preview["hidden"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v == id)
        );
        doc.command(json!({"op":"ink_erase_cancel","token":"adopted"}))
            .unwrap();
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn pdf_owned_ink_pieces_are_staged_until_saved_and_discard_cannot_duplicate_them() {
        let fixture = Fixture::new("annotated-ink-review.pdf");
        let original_pdf = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        doc.command(json!({"op":"file_adopt","id":"nm:review-ink-bare"}))
            .unwrap();
        let records = cache_path(&fixture.path);
        let before = fs::read(&records).unwrap();
        doc.command(json!({"op":"ink_erase_begin","token":"cut","page":0,"zoom":1,"segments":[{"from":{"x":250,"y":200},"to":{"x":250,"y":350}}]})).unwrap();
        let cut = doc
            .command(json!({"op":"ink_erase_commit","token":"cut","segments":[]}))
            .unwrap();
        assert_eq!(cut["erase_requires_pdf_save"], true);
        assert_eq!(cut["annotations"].as_array().unwrap().len(), 2);
        assert_ne!(fs::read(&records).unwrap(), before);
        let reopened = fixture.open().command(json!({"op":"marks"})).unwrap();
        assert_eq!(reopened["annotations"].as_array().unwrap().len(), 2);
        assert_eq!(reopened["pending_deletions"], 1);
        assert!(
            !reopened["file_annotations"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["id"] == "nm:review-ink-bare")
        );
        doc.command(json!({"op":"ink_erase_begin","token":"again","page":0,"zoom":1,"segments":[{"from":{"x":150,"y":200},"to":{"x":150,"y":350}}]})).unwrap();
        let again = doc
            .command(json!({"op":"ink_erase_commit","token":"again","segments":[]}))
            .unwrap();
        assert_eq!(again["annotations"].as_array().unwrap().len(), 3);
        let undo = doc.command(json!({"op":"marks_undo"})).unwrap();
        assert_eq!(undo["annotations"], cut["annotations"]);
        doc.command(json!({"op":"marks_redo"})).unwrap();
        doc.command(json!({"op":"mark_create","entry":{"kind":"square","page":0,"version":1,"rect":{"x":10,"y":10,"width":20,"height":20},"strokeWidth":2,"color":"#000000FF","note":"keep square"}})).unwrap();
        assert_eq!(
            fixture.open().command(json!({"op":"marks"})).unwrap()["annotations"]
                .as_array()
                .unwrap()
                .len(),
            4
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original_pdf);
        doc.command(json!({"op":"replace_current_annotations"}))
            .unwrap();
        let reopened = fixture.open();
        let file = reopened.command(json!({"op":"annotations"})).unwrap();
        assert_eq!(file.as_array().unwrap().len(), 7);
        assert!(
            !file
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["id"] == "nm:review-ink-bare")
        );
        let state = reopened.command(json!({"op":"marks"})).unwrap();
        assert!(state["annotations"].as_array().unwrap().is_empty());
        assert_eq!(state["pending_deletions"], 0);
    }

    #[test]
    fn artwork_round_trips_through_sidecar_pdf_and_identity_preserving_adoption() {
        use image::{ExtendedColorType, ImageEncoder};
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let rgba = [220, 40, 10, 128, 20, 80, 200, 255];
        let mut png = Vec::new();
        image::codecs::png::PngEncoder::new(&mut png)
            .write_image(&rgba, 2, 1, ExtendedColorType::Rgba8)
            .unwrap();
        let encoded = crate::artwork::encode(&png);
        for entry in [
            json!({"kind":"stamp","page":0,"version":1,"color":"#90B79AFF","note":"APPROVED","rect":{"x":60,"y":120,"width":150,"height":50},"stampStyle":"approved"}),
            json!({"kind":"signature","page":0,"version":1,"color":"#000000FF","note":"","rect":{"x":250,"y":120,"width":128,"height":64},"stampStyle":"signature","image":encoded}),
        ] {
            doc.command(json!({"op":"mark_create","entry":entry}))
                .unwrap();
        }
        assert_eq!(
            doc.command(json!({"op":"marks"})).unwrap()["annotations"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        let copy = fixture.directory.join("artwork.pdf");
        doc.command(json!({"op":"save_current_annotations","destination":copy}))
            .unwrap();
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        let copy_doc = open_fixture_document(&copy, None).unwrap();
        let file = copy_doc.command(json!({"op":"annotations"})).unwrap();
        assert_eq!(file.as_array().unwrap().len(), 2);
        assert!(
            file.as_array()
                .unwrap()
                .iter()
                .all(|a| a["kind"] == "stamp" && a["drawing"] == "stamp")
        );
        assert!(
            file.as_array()
                .unwrap()
                .iter()
                .any(|a| a["stamp"]["text"] == "APPROVED")
        );
        let image = file
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["stamp"]["image"].as_str().is_some_and(|s| !s.is_empty()))
            .unwrap();
        let decoded = crate::artwork::pixels(image["stamp"]["image"].as_str().unwrap()).unwrap();
        assert_eq!(decoded, (2, 1, rgba.to_vec()));
        let identity = image["id"].as_str().unwrap();
        let adopted = copy_doc
            .command(json!({"op":"file_adopt","id":identity}))
            .unwrap();
        let id = adopted["selected_id"].as_str().unwrap();
        let edited=copy_doc.command(json!({"op":"mark_update","id":id,"patch":{"rect":{"x":260,"y":130,"width":128,"height":64}}})).unwrap();
        assert_eq!(edited["annotations"][0]["kind"], "signature");
        assert_eq!(edited["annotations"][0]["image"], image["stamp"]["image"]);
        let second = fixture.directory.join("edited-artwork.pdf");
        copy_doc
            .command(json!({"op":"save_current_annotations","destination":second}))
            .unwrap();
        let reopened = open_fixture_document(&second, None)
            .unwrap()
            .command(json!({"op":"annotations"}))
            .unwrap();
        assert_eq!(reopened.as_array().unwrap().len(), 2);
        let moved = reopened
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["id"] == identity)
            .unwrap();
        assert!((moved["x_pt"].as_f64().unwrap() - 260.0).abs() < 0.01);
        assert!((moved["y_pt"].as_f64().unwrap() - 130.0).abs() < 0.01);
        let sidecar = cache_path(&fixture.path);
        let before = fs::read(&sidecar).unwrap();
        assert!(doc.command(json!({"op":"mark_create","entry":{"kind":"signature","page":0,"version":1,"color":"#000000FF","note":"","image":"invalid","rect":{"x":10,"y":10,"width":10,"height":10}}})).is_err());
        assert_eq!(before, fs::read(&sidecar).unwrap());
    }

    #[test]
    fn whole_summary_history_and_legacy_open_preserve_the_authoritative_cache() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let source = doc.active().unwrap();
        let directory = doc
            .with_reading_cache(&source, true, |cache, _| Ok(cache.directory.clone()))
            .unwrap();
        let run = doc
            .with_reading_cache(&source, true, |cache, sha| {
                AnalysisRun::begin(cache, sha, "English".into(), "Brief".into())
            })
            .unwrap();
        let record = ReadingRecord {
            id: "whole-history-source".into(),
            kind: "summary".into(),
            source_id: reading_scope_key(None),
            source_hash: source.document_identity().sha256,
            content: "## Overview\nA complete synthetic answer [p.1].".into(),
            pages: vec![1],
            model: "synthetic".into(),
            language: "English".into(),
            detail: "Brief".into(),
            originals: vec!["Synthetic source passage.".into()],
            original_pages: vec![1],
            status: "finished".into(),
            modified: 1,
            ..ReadingRecord::default()
        };
        let (context, id, warning) = doc.publish_summary(&source, record.clone(), run).unwrap();
        assert!(warning.is_none());
        assert_eq!(id, record.id);
        assert_eq!(context.summary, record.content);
        let history = doc
            .command(json!({"op":"ai_reading_tasks","kind":"summary","selection":null}))
            .unwrap();
        assert_eq!(history[0]["id"], record.id);
        assert_eq!(history[0]["content"], record.content);
        let primary = directory.join(crate::analysis_cache::FILE);
        let primary_bytes = fs::read(&primary).unwrap();
        let workspace = directory.join(crate::reading_history::WORKSPACE_FILE);
        fs::remove_file(&workspace).unwrap();
        assert!(
            doc.command(json!({"op":"ai_reading_tasks","kind":"summary","selection":null}))
                .unwrap()
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert!(!workspace.exists());
        let opened = doc
            .cached_document_summary(&source, "English", "Brief")
            .unwrap()
            .unwrap();
        assert_eq!(opened["output"], record.content);
        assert!(opened["history_warning"].is_null());
        assert_eq!(fs::read(&primary).unwrap(), primary_bytes);
        let restored = doc
            .command(json!({"op":"ai_reading_tasks","kind":"summary","selection":null}))
            .unwrap();
        assert_eq!(restored[0]["id"], record.id);
        let damaged = b"damaged history must stay byte-identical";
        fs::write(&workspace, damaged).unwrap();
        let opened = doc
            .cached_document_summary(&source, "English", "Brief")
            .unwrap()
            .unwrap();
        assert_eq!(opened["output"], record.content);
        assert!(
            opened["history_warning"]
                .as_str()
                .unwrap()
                .contains("summary is saved")
        );
        assert_eq!(fs::read(&workspace).unwrap(), damaged);
        assert_eq!(fs::read(&primary).unwrap(), primary_bytes);
        let mut second = record;
        second.id = "whole-history-second".into();
        second.content = "A newer complete synthetic answer [p.1].".into();
        second.modified = 2;
        let run = doc
            .with_reading_cache(&source, true, |cache, sha| {
                AnalysisRun::begin(cache, sha, "English".into(), "Brief".into())
            })
            .unwrap();
        let (context, id, warning) = doc.publish_summary(&source, second.clone(), run).unwrap();
        assert_eq!(id, second.id);
        assert_eq!(context.summary, second.content);
        assert!(warning.unwrap().contains("summary is saved"));
        assert_eq!(fs::read(&workspace).unwrap(), damaged);
        assert_eq!(
            fs::read(directory.join("document-understanding-v2.previous.json")).unwrap(),
            primary_bytes
        );
    }

    #[test]
    fn translation_entry_batches_match_single_reads_and_keep_unverified_pages_unlinked() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let source = doc.active().unwrap();
        let long_id = format!("retained-{}", "x".repeat(600));
        doc.update_reading_workspace(&source, |workspace, sha, _| {
            for (id, fingerprint, status, original) in [
                ("batch-current", sha, "finished", true),
                ("batch-stale", "earlier-source", "finished", true),
                ("batch-partial", sha, "partial", false),
                (long_id.as_str(), "", "finished", true),
            ] {
                workspace.put(ReadingRecord {
                    id: id.into(),
                    kind: "translation".into(),
                    source_id: "document".into(),
                    content: "<!--lyra:0--> Synthetic translated passage [p.99].".into(),
                    pages: vec![1, 99],
                    source_hash: fingerprint.into(),
                    status: status.into(),
                    language: "Synthetic language".into(),
                    originals: if original {
                        vec!["Synthetic original passage.".into()]
                    } else {
                        Vec::new()
                    },
                    original_pages: if original { vec![1] } else { Vec::new() },
                    ..ReadingRecord::default()
                })?;
            }
            Ok(())
        })
        .unwrap();
        let directory = doc
            .with_reading_cache(&source, false, |cache, _| Ok(cache.directory.clone()))
            .unwrap();
        let path = directory.join(crate::reading_history::WORKSPACE_FILE);
        // The canonical writer binds a new record to its source. Model an
        // older unbound record in this owned fixture before testing reads.
        let mut legacy: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let unbound = legacy["records"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|record| record["id"] == long_id)
            .unwrap();
        unbound["source_hash"] = json!("");
        fs::write(&path, serde_json::to_vec_pretty(&legacy).unwrap()).unwrap();
        let before = fs::read(&path).unwrap();
        let ids = [
            long_id.as_str(),
            "batch-current",
            "batch-partial",
            "batch-stale",
        ];
        let expected: Vec<_> = ids
            .iter()
            .map(|id| {
                doc.command(json!({"op":"ai_translation_history_entry","id":id}))
                    .unwrap()
            })
            .collect();
        let batch = doc
            .command(json!({"op":"ai_translation_history_entries","ids":ids}))
            .unwrap();
        assert_eq!(batch, json!(expected));
        assert_eq!(batch[0]["source_pages"], json!([]));
        assert_eq!(batch[0]["can_replay"], false);
        assert_eq!(batch[1]["source_pages"], json!([1]));
        assert_eq!(
            batch[1]["blocks"][0]["original"],
            "Synthetic original passage."
        );
        assert_eq!(batch[2]["blocks"], json!([]));
        assert_eq!(batch[2]["source_pages"], json!([1]));
        assert_eq!(batch[3]["source_pages"], json!([]));
        assert_eq!(batch[3]["status"], "sourceChanged");
        for ids in [
            json!([]),
            json!([true]),
            json!([""]),
            json!(["batch-current", "batch-current"]),
            json!(["missing"]),
            json!(vec!["batch-current"; 17]),
        ] {
            assert!(
                doc.command(json!({"op":"ai_translation_history_entries","ids":ids}))
                    .is_err()
            );
        }
        assert_eq!(fs::read(path).unwrap(), before);
    }

    #[test]
    fn reading_sidebar_batches_note_metadata_and_task_history_without_writes() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let source = doc.active().unwrap();
        doc.update_reading_workspace(&source, |workspace, sha, _| {
            let summary = ReadingRecord {
                id: "sidebar-summary".into(),
                kind: "summary".into(),
                source_id: "document".into(),
                title: "Synthetic overview".into(),
                content: "## Overview\nApproved finding [p.1].".into(),
                pages: vec![1, 99],
                source_hash: sha.into(),
                status: "finished".into(),
                modified: 2,
                model: "fixture".into(),
                detail: "Brief".into(),
                ..Default::default()
            };
            workspace.put(ReadingRecord {
                id: "sidebar-selection".into(),
                kind: "summary".into(),
                source_id: lyra_reader_ffi::ai_workspace::ai_reading_scope_key(Some(
                    AiSelectionRecord {
                        page: 0,
                        start: 0,
                        end: 3,
                    },
                )),
                content: "Selected synthetic result".into(),
                pages: vec![1],
                source_hash: sha.into(),
                status: "finished".into(),
                modified: 3,
                ..ReadingRecord::default()
            })?;
            workspace.put(summary.clone())?;
            workspace.keep(summary, "sidebar-note".into())?;
            workspace.put(ReadingRecord {
                id: "old-sidebar-summary".into(),
                kind: "summary".into(),
                source_id: "document".into(),
                content: "Older source".into(),
                pages: vec![1],
                source_hash: "different-source".into(),
                status: "finished".into(),
                modified: 1,
                ..Default::default()
            })?;
            Ok(())
        })
        .unwrap();
        let path = cache_path(&fixture.path)
            .parent()
            .unwrap()
            .join(crate::reading_history::WORKSPACE_FILE);
        let before = fs::read(&path).unwrap();
        let tasks = doc
            .command(json!({"op":"ai_reading_tasks","kind":"summary","source_id":"document"}))
            .unwrap();
        assert_eq!(tasks.as_array().unwrap().len(), 2);
        assert_eq!(tasks[0]["content"], "## Overview\nApproved finding [p.1].");
        assert_eq!(tasks[0]["source_pages"], json!([1]));
        assert_eq!(tasks[1]["status"], "sourceChanged");
        assert_eq!(tasks[1]["source_pages"], json!([]));
        assert!(
            doc.command(json!({"op":"ai_reading_tasks","kind":"note"}))
                .is_err()
        );
        let whole = doc
            .command(json!({"op":"ai_reading_tasks","kind":"summary","selection":null}))
            .unwrap();
        assert_eq!(whole, tasks);
        let selected = doc.command(json!({"op":"ai_reading_tasks","kind":"summary","selection":{"page":0,"start":0,"end":3}})).unwrap();
        assert_eq!(selected.as_array().unwrap().len(), 1);
        assert_eq!(selected[0]["id"], "sidebar-selection");
        for selection in [
            json!({"page":99,"start":0,"end":3}),
            json!({"page":0,"start":3,"end":0}),
            json!({"page":-1,"start":0,"end":3}),
        ] {
            assert!(
                doc.command(
                    json!({"op":"ai_reading_tasks","kind":"summary","selection":selection})
                )
                .is_err()
            );
        }
        assert!(doc.command(json!({"op":"ai_reading_tasks","kind":"summary","source_id":"document","selection":null})).is_err());
        let notes = doc
            .command(json!({"op":"ai_reading_notes","query":"Approved","recent":false}))
            .unwrap();
        assert_eq!(notes.as_array().unwrap().len(), 1);
        assert_eq!(notes[0]["origin_kind"], "summary");
        assert_eq!(notes[0]["origin_scope"], "document");
        assert_eq!(notes[0]["content"], tasks[0]["content"]);
        assert_eq!(notes[0]["source_pages"], json!([1]));
        assert!(notes[0]["modified"].is_u64());
        assert!(notes[0].get("source").is_none());
        let detail = doc
            .command(json!({"op":"ai_reading_note","id":"sidebar-note"}))
            .unwrap();
        assert!(detail["modified"].is_string());
        assert_eq!(detail["source"]["whole_document"], true);
        assert_eq!(detail["source"]["answer"]["content"], tasks[0]["content"]);
        assert_eq!(detail["source"]["answer"]["source_pages"], json!([1]));
        assert_eq!(fs::read(&path).unwrap(), before);
    }

    #[test]
    fn home_identity_tracks_source_bytes_across_private_revisions_and_save() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let source = doc.info().unwrap()["document_id"].clone();
        let staged = doc
            .command(
                json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}}),
            )
            .unwrap();
        assert_eq!(staged["info"]["document_id"], source);
        assert_ne!(
            doc.active().unwrap().document_id(),
            source.as_str().unwrap()
        );
        let undo = doc.command(json!({"op":"page_undo"})).unwrap();
        assert_eq!(undo["info"]["document_id"], source);
        doc.command(json!({"op":"page_redo"})).unwrap();
        let saved = doc.command(json!({"op":"document_save"})).unwrap();
        assert_ne!(saved["info"]["document_id"], source);
        assert_eq!(
            saved["info"]["document_id"],
            doc.active().unwrap().document_id()
        );
    }

    #[test]
    fn annotation_cache_uses_document_id_and_ignores_both_adjacent_formats() {
        let fixture = Fixture::new("text-page.pdf");
        let modern = format!("{}.lyra-reader-annotations.json", fixture.path.display());
        let legacy = format!("{}.aris-annotations.json", fixture.path.display());
        fs::write(&modern, b"deliberately unreadable adjacent file").unwrap();
        fs::write(&legacy, b"[]").unwrap();
        let doc = fixture.open();
        let state = doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(
            doc.info().unwrap()["document_id"],
            doc.active().unwrap().document_id()
        );
        assert!(state["error"].is_null());
        assert!(state["annotations"].as_array().unwrap().is_empty());
        doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":1,"color":"#E8BC5552","note":"cached only"}})).unwrap();
        let path = cache_path(&fixture.path);
        assert_eq!(
            path.parent()
                .unwrap()
                .file_name()
                .unwrap()
                .to_string_lossy(),
            doc.active().unwrap().document_id()
        );
        assert_eq!(
            fs::read(&modern).unwrap(),
            b"deliberately unreadable adjacent file"
        );
        assert_eq!(fs::read(&legacy).unwrap(), b"[]");
        assert_eq!(
            fixture.open().command(json!({"op":"marks"})).unwrap()["annotations"][0]["note"],
            "cached only"
        );
        #[cfg(unix)]
        {
            let alias = fixture.directory.join("alias.pdf");
            std::os::unix::fs::symlink(&fixture.path, &alias).unwrap();
            assert_eq!(cache_path(&alias), path);
            assert_eq!(
                open_fixture_document(&alias, None)
                    .unwrap()
                    .command(json!({"op":"marks"}))
                    .unwrap()["annotations"]
                    .as_array()
                    .unwrap()
                    .len(),
                1
            );
        }
    }

    #[test]
    fn external_pdf_changes_keep_readable_drafts_and_refuse_replacement() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":1,"color":"#E8BC5552","note":"keep after external edit"}})).unwrap();
        let old_cache = cache_path(&fixture.path);
        let draft = fs::read(&old_cache).unwrap();
        // A changed mtime with identical bytes still names the same document.
        fs::write(&fixture.path, &original).unwrap();
        assert_eq!(cache_path(&fixture.path), old_cache);
        assert!(fixture.open().command(json!({"op":"marks"})).unwrap()["error"].is_null());
        let changed = [original.as_slice(), b"\n% external change\n"].concat();
        fs::write(&fixture.path, &changed).unwrap();
        assert!(
            doc.command(json!({"op":"replace_current_annotations"}))
                .unwrap_err()
                .contains("changed outside")
        );
        let reopened = fixture.open();
        let state = reopened.command(json!({"op":"marks"})).unwrap();
        assert_eq!(state["annotations"][0]["note"], "keep after external edit");
        assert!(state["error"].as_str().unwrap().contains("changed outside"));
        assert_ne!(cache_path(&fixture.path), old_cache);
        assert_eq!(fs::read(old_cache).unwrap(), draft);
        assert!(
            reopened
                .command(json!({"op":"replace_current_annotations"}))
                .unwrap_err()
                .contains("changed outside")
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), changed);
    }

    #[test]
    fn successful_save_rekeys_cleaned_records_and_keeps_foreign_bytes() {
        let fixture = Fixture::new("text-page.pdf");
        let old = cache_path(&fixture.path);
        let foreign = r#"{ "kind":"future-cache-kind", "number":1.0000, "text":"a\/b" }"#;
        fs::write(&old, format!("[{foreign}]")).unwrap();
        let doc = fixture.open();
        let old_identity = doc.active().unwrap().document_identity();
        doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":1,"color":"#E8BC5552","note":"saved mark"}})).unwrap();
        let report = doc
            .command(json!({"op":"replace_current_annotations"}))
            .unwrap();
        assert!(report["sidecar_cleanup_error"].is_null(), "{report}");
        let new = cache_path(&fixture.path);
        assert_ne!(new, old);
        assert!(old.exists());
        assert!(fs::read_to_string(&new).unwrap().contains(foreign));
        let reopened = fixture.open();
        assert_ne!(
            reopened.active().unwrap().document_id(),
            old_identity.document_id
        );
        let state = reopened.command(json!({"op":"marks"})).unwrap();
        assert!(state["error"].is_null(), "{state}");
        assert_eq!(state["preserved"], 1);
        assert!(state["annotations"].as_array().unwrap().is_empty());
        assert!(
            reopened
                .command(json!({"op":"annotations"}))
                .unwrap()
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["contents"] == "saved mark")
        );
    }

    #[test]
    fn corrupt_source_metadata_never_drops_readable_annotation_records() {
        let fixture = Fixture::new("text-page.pdf");
        fixture
            .open()
            .command(json!({"op":"bookmark_create","page":0,"title":"kept","yPt":0}))
            .unwrap();
        let source = cache_path(&fixture.path)
            .parent()
            .unwrap()
            .join("source.json");
        fs::write(&source, b"broken metadata").unwrap();
        let doc = fixture.open();
        let state = doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(state["bookmarks"][0]["title"], "kept");
        assert!(state["error"].as_str().unwrap().contains("source stamp"));
        assert!(
            doc.command(json!({"op":"replace_current_annotations"}))
                .is_err()
        );
        assert_eq!(fs::read(source).unwrap(), b"broken metadata");
    }

    #[test]
    fn previous_page_recovery_keeps_records_and_pointer_until_it_can_be_restored() {
        use sha2::{Digest, Sha256};
        let fixture = Fixture::new("text-page.pdf");
        let root = fixture_cache_root(&fixture.path);
        let canonical = fixture.path.canonicalize().unwrap();
        let key: String = Sha256::digest(canonical.to_string_lossy().as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        let legacy = root.join(&key);
        fs::create_dir_all(&legacy).unwrap();
        let bytes = br#"[{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","kind":"bookmark","page":0,"title":"recover me","yPt":0,"createdAt":0}]"#;
        fs::write(legacy.join("annotations.json"), bytes).unwrap();
        let recovery = br#"{"keep":"complete legacy recovery manifest"}"#;
        fs::write(legacy.join("session.json"), recovery).unwrap();
        for _ in 0..2 {
            let doc = fixture.open();
            let state = doc.command(json!({"op":"marks"})).unwrap();
            assert_eq!(state["bookmarks"][0]["title"], "recover me");
            assert!(state["error"].as_str().unwrap().contains("recovery"));
            assert!(
                doc.command(json!({"op":"bookmark_create","page":0,"title":"must wait","yPt":0}))
                    .is_err()
            );
            assert!(
                doc.command(json!({"op":"replace_current_annotations"}))
                    .is_err()
            );
        }
        assert_eq!(fs::read(legacy.join("annotations.json")).unwrap(), bytes);
        assert_eq!(fs::read(legacy.join("session.json")).unwrap(), recovery);
        assert!(!root.join(format!("{key}.identity")).exists());
    }

    #[test]
    fn unavailable_document_cache_keeps_pdf_readable_and_blocks_edits() {
        let fixture = Fixture::new("text-page.pdf");
        let blocked = fixture.directory.join("blocked-cache");
        fs::write(&blocked, b"existing file").unwrap();
        let doc =
            DesktopDocument::open_with_cache_root(&fixture.path, None, Some(&blocked)).unwrap();
        assert_eq!(doc.info().unwrap()["pages"].as_array().unwrap().len(), 1);
        assert!(doc.command(json!({"op":"marks"})).unwrap()["error"].is_string());
        assert!(
            doc.command(json!({"op":"bookmark_create","page":0,"title":"refused","yPt":0}))
                .is_err()
        );
        assert_eq!(fs::read(blocked).unwrap(), b"existing file");
    }

    #[test]
    fn native_transport_reuses_search_text_metadata_and_facing_geometry() {
        let fixture = Fixture::new("outlined.pdf");
        let doc = fixture.open();
        let info = doc.info().unwrap();
        assert_eq!(
            info["rows"].as_array().unwrap().len(),
            info["pages"].as_array().unwrap().len()
        );
        assert_eq!(info["rows"][0]["first"], 0);
        assert_eq!(info["rows"][0]["count"], 1);
        let outline = doc.command(json!({"op":"outline"})).unwrap();
        assert!(!outline.as_array().unwrap().is_empty());
        let layout = doc
            .command(json!({"op":"layout","mode":"Facing","gap":18}))
            .unwrap();
        assert_eq!(layout["pages"][1]["top"], layout["pages"][2]["top"]);
        assert_ne!(layout["pages"][1]["left"], layout["pages"][2]["left"]);
        assert_eq!(layout["rows"][1]["first"], 1);
        assert_eq!(layout["rows"][1]["count"], 2);
        assert_eq!(layout["rows"][1]["top"], layout["pages"][1]["top"]);
        let text = doc.command(json!({"op":"text","page":0})).unwrap();
        let pattern = text["text"]
            .as_str()
            .unwrap()
            .split_whitespace()
            .next()
            .unwrap();
        let hits = doc
            .command(json!({"op":"search","pattern":pattern}))
            .unwrap();
        assert!(!hits.as_array().unwrap().is_empty());
        assert!(
            doc.command(json!({"op":"metadata"}))
                .unwrap()
                .get("bibtex")
                .is_some()
        );
        assert!(
            doc.command(json!({"op":"layout","mode":"Unknown"}))
                .is_err()
        );
        assert!(doc.command(json!({"op":"text","page":999})).is_err());
        assert!(doc.command(json!({"op":"unsupported"})).is_err());
    }

    #[test]
    fn native_transport_writes_verified_copies_without_touching_source() {
        let fixture = Fixture::new("form-fields.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let fields = doc.command(json!({"op":"forms"})).unwrap();
        let field = fields["fields"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f["kind"] == "text")
            .unwrap();
        let copy = fixture.directory.join("filled.pdf");
        let report = doc
            .command(json!({"op":"save_forms","destination":copy,"values":[{
                "field_id":field["id"],"text":"Linux native check","checked":null,"selected":null
            }]}))
            .unwrap();
        assert!(report["source_bytes_preserved"].as_bool().unwrap());
        let filled = open_fixture_document(&copy, None)
            .unwrap()
            .command(json!({"op":"forms"}))
            .unwrap();
        assert!(
            filled["fields"]
                .as_array()
                .unwrap()
                .iter()
                .any(|f| f["value"] == "Linux native check")
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        let properties = fixture.directory.join("properties.pdf");
        doc.command(json!({"op":"save_properties","destination":properties,"title":"Linux title","author":"Reader","subject":"Check","keywords":"native"})).unwrap();
        let info = open_fixture_document(&properties, None)
            .unwrap()
            .command(json!({"op":"document_info"}))
            .unwrap();
        assert_eq!(info["title"], "Linux title");
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }
    #[test]
    fn properties_replacement_preserves_application_drafts_and_verified_backup() {
        let fixture = Fixture::new("metadata-info.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let foreign = r#"{ "kind":"future-tool", "opaque":[3, 1, 4] }"#;
        fs::write(cache_path(&fixture.path), format!("[{foreign}]\n")).unwrap();
        let doc = fixture.open();
        let note = doc.command(json!({"op":"mark_create","entry":{"kind":"square","version":1,"page":0,"rect":{"x":20,"y":50,"width":80,"height":40},"strokeWidth":2,"color":"#E8BC5580","note":"Keep this local draft"}})).unwrap();
        let note_id = note["selected_id"].as_str().unwrap().to_owned();
        let bookmark = doc.command(json!({"op":"bookmark_create","page":0,"title":"Keep the reading bookmark","yPt":20})).unwrap();
        let bookmark_id = bookmark["bookmarks"][0]["id"].as_str().unwrap().to_owned();
        let report = doc.command(json!({"op":"replace_properties","title":"Changed PDF information","author":"Synthetic author","subject":"Properties check","keywords":"native"})).unwrap();
        let backup = report["backup_path"].as_str().unwrap();
        assert_eq!(fs::read(backup).unwrap(), original);
        assert_ne!(fs::read(&fixture.path).unwrap(), original);
        let reopened = fixture.open();
        assert_eq!(
            reopened.command(json!({"op":"document_info"})).unwrap()["title"],
            "Changed PDF information"
        );
        let marks = reopened.command(json!({"op":"marks"})).unwrap();
        assert!(
            marks["annotations"]
                .as_array()
                .unwrap()
                .iter()
                .any(|entry| entry["id"] == note_id)
        );
        assert!(
            marks["bookmarks"]
                .as_array()
                .unwrap()
                .iter()
                .any(|entry| entry["id"] == bookmark_id)
        );
        assert!(
            fs::read_to_string(cache_path(&fixture.path))
                .unwrap()
                .contains(foreign)
        );
    }

    #[test]
    fn properties_writes_keep_the_staged_revision_immutable_and_refuse_original_replacement() {
        let fixture = Fixture::new("multipage.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        doc.command(
            json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}}),
        )
        .unwrap();
        let lease = doc.active().unwrap();
        let revision = fs::read(lease.path()).unwrap();
        let error = doc.command(json!({"op":"replace_properties","title":"Refused title","author":"Synthetic author","subject":"","keywords":""})).unwrap_err();
        assert!(error.contains("staged page changes"));
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert_eq!(fs::read(lease.path()).unwrap(), revision);
        let copy = fixture.directory.join("properties-from-revision.pdf");
        doc.command(json!({"op":"save_properties","destination":copy,"title":"Working revision copy","author":"Synthetic author","subject":"","keywords":""})).unwrap();
        let copied = open_fixture_document(&copy, None).unwrap();
        assert_eq!(
            copied.command(json!({"op":"document_info"})).unwrap()["title"],
            "Working revision copy"
        );
        assert_eq!(
            copied.info().unwrap()["pages"][0]["width"],
            doc.info().unwrap()["pages"][0]["width"]
        );
        assert_eq!(
            copied.info().unwrap()["pages"][0]["height"],
            doc.info().unwrap()["pages"][0]["height"]
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert_eq!(fs::read(lease.path()).unwrap(), revision);
    }

    #[test]
    fn properties_copy_strips_signatures_and_protects_the_original() {
        let fixture = Fixture::new("signed-signature.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let copy = fixture.directory.join("unsigned-properties-copy.pdf");
        doc.command(json!({"op":"save_properties","destination":copy,"title":"Unsigned properties copy","author":"Synthetic author","subject":"","keywords":""})).unwrap();
        let copied = open_fixture_document(&copy, None).unwrap();
        assert_eq!(copied.info().unwrap()["signature_status"]["signed"], false);
        assert_eq!(
            copied.command(json!({"op":"document_info"})).unwrap()["title"],
            "Unsigned properties copy"
        );
        assert!(doc.command(json!({"op":"replace_properties","title":"Refused title","author":"Synthetic author","subject":"","keywords":""})).is_err());
        assert_eq!(doc.info().unwrap()["signature_status"]["signed"], true);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn page_corner_bookmarks_default_only_an_omitted_name_and_keep_manual_order() {
        let fixture = Fixture::new("multipage.pdf");
        let sidecar = cache_path(&fixture.path);
        let foreign = r#"{ "kind":"future-tool", "future":[1, 2, 3] }"#;
        fs::write(&sidecar, format!("[{foreign}]\n")).unwrap();
        let doc = fixture.open();
        let created = doc
            .command(json!({"op":"bookmark_create","page":2}))
            .unwrap();
        let first = created["bookmarks"][0].clone();
        assert_eq!(first["title"], bookmark_title(None, 2));
        assert_eq!(first["yPt"], 0);
        assert!(fs::read_to_string(&sidecar).unwrap().contains(foreign));
        let explicit = doc
            .command(json!({"op":"bookmark_create","page":0,"title":"  Kept 😀  "}))
            .unwrap();
        assert_eq!(explicit["bookmarks"][0], first);
        assert_eq!(explicit["bookmarks"][1]["title"], "  Kept 😀  ");
        let empty = doc
            .command(json!({"op":"bookmark_create","page":1,"title":""}))
            .unwrap();
        assert_eq!(empty["bookmarks"][2]["title"], "");
        let undone = doc.command(json!({"op":"marks_undo"})).unwrap();
        assert_eq!(undone["bookmarks"], explicit["bookmarks"]);
        let redone = doc.command(json!({"op":"marks_redo"})).unwrap();
        assert_eq!(redone["bookmarks"], empty["bookmarks"]);
        let copy = fixture.directory.join("corner-copy.pdf");
        doc.command(json!({"op":"save_current_annotations","destination":copy}))
            .unwrap();
        let reopened = open_fixture_document(&copy, None)
            .unwrap()
            .command(json!({"op":"marks"}))
            .unwrap();
        assert_eq!(reopened["bookmarks"].as_array().unwrap().len(), 3);
        assert_eq!(reopened["bookmarks"][0]["title"], "Page 3");
        assert_eq!(reopened["bookmarks"][1]["title"], "  Kept 😀  ");
    }

    #[test]
    fn page_corner_bookmarks_refuse_invalid_arguments_without_cache_or_history_changes() {
        let fixture = Fixture::new("multipage.pdf");
        let doc = fixture.open();
        for request in [
            json!({"op":"bookmark_create","page":-1}),
            json!({"op":"bookmark_create","page":3}),
            json!({"op":"bookmark_create","page":u64::MAX}),
            json!({"op":"bookmark_create","page":"0"}),
            json!({"op":"bookmark_create"}),
            json!({"op":"bookmark_create","page":0,"title":null}),
            json!({"op":"bookmark_create","page":0,"title":1}),
            json!({"op":"bookmark_create","page":0,"yPt":-1}),
        ] {
            let before = doc.command(json!({"op":"marks"})).unwrap();
            assert!(doc.command(request.clone()).is_err(), "{request}");
            assert_eq!(doc.command(json!({"op":"marks"})).unwrap(), before);
        }
        doc.command(json!({"op":"bookmark_create","page":0}))
            .unwrap();
        let sidecar = cache_path(&fixture.path);
        let external = b"[]\n";
        fs::write(&sidecar, external).unwrap();
        assert!(
            doc.command(json!({"op":"bookmark_create","page":1}))
                .is_err()
        );
        assert_eq!(fs::read(&sidecar).unwrap(), external);
    }

    #[test]
    fn annotations_bookmarks_and_future_entries_survive_verified_replace() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let sidecar = cache_path(&fixture.path);
        let future = r#"{ "kind" : "future-tool", "id":"F12FA132-BB4B-4272-A8F5-64240550BE19", "future" : [1, 2, 3] }"#;
        fs::write(&sidecar, format!("[{future}]\n")).unwrap();
        let doc = fixture.open();
        let state=doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":3,"color":"#E8BC5552","note":"Native annotation"}})).unwrap();
        let id = state["annotations"][0]["id"].as_str().unwrap();
        assert_eq!(state["preserved"], 1);
        assert_eq!(state["selected_id"], id);
        doc.command(json!({"op":"bookmark_create","page":0,"title":"My bookmark","yPt":30}))
            .unwrap();
        let copy = fixture.directory.join("marked-copy.pdf");
        doc.command(json!({"op":"save_current_annotations","destination":copy}))
            .unwrap();
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        let copy_doc = open_fixture_document(&copy, None).unwrap();
        assert_eq!(
            copy_doc
                .command(json!({"op":"annotations"}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            copy_doc.command(json!({"op":"marks"})).unwrap()["bookmarks"][0]["title"],
            "My bookmark"
        );
        let rotated = copy_doc
            .command(
                json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}}),
            )
            .unwrap();
        assert_eq!(rotated["marks"]["bookmarks"].as_array().unwrap().len(), 1);
        copy_doc.command(json!({"op":"page_discard"})).unwrap();
        let report = doc
            .command(json!({"op":"replace_current_annotations"}))
            .unwrap();
        assert_eq!(
            fs::read(report["backup_path"].as_str().unwrap()).unwrap(),
            original
        );
        let reopened = fixture.open().command(json!({"op":"marks"})).unwrap();
        assert!(reopened["annotations"].as_array().unwrap().is_empty());
        assert_eq!(reopened["file_annotations"].as_array().unwrap().len(), 1);
        assert_eq!(reopened["bookmarks"][0]["title"], "My bookmark");
        assert!(fs::read_to_string(&sidecar).unwrap().contains(future));
    }
    #[test]
    fn damaged_or_externally_modified_sidecars_are_never_overwritten() {
        let fixture = Fixture::new("text-page.pdf");
        let sidecar = cache_path(&fixture.path);
        fs::write(&sidecar, b"damaged json").unwrap();
        let doc = fixture.open();
        assert!(doc.command(json!({"op":"marks"})).unwrap()["error"].is_string());
        assert!(
            doc.command(json!({"op":"bookmark_create","page":0,"title":"No","yPt":0}))
                .is_err()
        );
        assert_eq!(fs::read(&sidecar).unwrap(), b"damaged json");
        fs::write(&sidecar, b"[]").unwrap();
        let doc = fixture.open();
        fs::write(&sidecar, b"[ ]\n").unwrap();
        assert!(
            doc.command(json!({"op":"bookmark_create","page":0,"title":"No","yPt":0}))
                .is_err()
        );
        assert_eq!(fs::read(&sidecar).unwrap(), b"[ ]\n");
    }
    #[test]
    fn oversized_annotation_notes_roll_back_without_overwriting_the_saved_state() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        doc.command(json!({"op":"bookmark_create","page":0,"title":"Preserve me","yPt":0}))
            .unwrap();
        let path = cache_path(&fixture.path);
        let before = fs::read(&path).unwrap();
        let error=doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":1,"color":"#E8BC5552","note":"x".repeat(16*1024*1024)}})).unwrap_err();
        assert!(
            error.contains(&format!(
                "more than {} bytes of text",
                lyra_reader_edit::rules::MAX_NOTE_BYTES
            )),
            "{error}"
        );
        assert_eq!(fs::read(path).unwrap(), before);
        assert!(
            doc.command(json!({"op":"marks"})).unwrap()["annotations"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn page_history_reclaims_old_files_and_live_render_snapshots_keep_their_session() {
        let fixture = Fixture::new("multipage.pdf");
        let doc = fixture.open();
        doc.command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":0}}}))
            .unwrap();
        let source = crate::render_source::RenderSource::new(&doc, false).unwrap();
        let directory = doc
            .edits
            .lock()
            .unwrap()
            .directory
            .as_ref()
            .unwrap()
            .path
            .clone();
        for _ in 0..36 {
            doc.command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":0}}}))
                .unwrap();
        }
        let pdfs = fs::read_dir(&directory)
            .unwrap()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "pdf"))
            .count();
        // Thirty-two undo revisions, the current revision, and one externally leased snapshot.
        assert!(pdfs <= 34, "{pdfs} revisions retained");
        doc.command(json!({"op":"page_discard"})).unwrap();
        drop(doc);
        assert!(directory.exists());
        let image = source
            .render(
                0,
                1.0,
                lyra_reader_core::Rect::new(0., 0., 100., 100.),
                false,
                false,
            )
            .unwrap();
        assert_eq!(image.width_px, 100);
        drop(source);
        assert!(!directory.exists());
    }
    #[test]
    fn reply_threads_keep_identity_and_staged_deletion_cascades_to_every_depth() {
        let fixture = Fixture::new("annotated-replies.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        for op in ["file_adopt", "file_delete"] {
            assert!(doc.command(json!({"op":op,"id":"nm:reply-two"})).is_err());
        }
        let adopted = doc
            .command(json!({"op":"file_adopt","id":"nm:parent-highlight"}))
            .unwrap();
        let id = adopted["selected_id"].as_str().unwrap();
        assert!(
            adopted["annotations"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["fileIdentity"] == "nm:parent-highlight")
        );
        assert!(
            adopted["file_annotations"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["id"] == "nm:reply-two")
        );
        let deleted = doc.command(json!({"op":"mark_delete","id":id})).unwrap();
        for removed in [
            "nm:parent-highlight",
            "nm:reply-one",
            "nm:reply-two",
            "nm:reply-empty",
            "nm:reply-cross-page",
        ] {
            assert!(
                !deleted["file_annotations"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|a| a["id"] == removed),
                "{removed}"
            );
        }
        let restored = doc.command(json!({"op":"marks_undo"})).unwrap();
        assert!(
            restored["file_annotations"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["id"] == "nm:reply-two")
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn merge_and_split_preserve_marks_and_refuse_conflicting_outputs() {
        let fixture = Fixture::new("multipage.pdf");
        let other = Fixture::new("annotated.pdf");
        let source_bytes = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        for page in [0, 2] {
            doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":page,"start":0,"end":3,"color":"#E8BC5580","note":format!("mark-{page}")}})).unwrap();
        }
        let merged = fixture.directory.join("merged.pdf");
        let report = doc
            .command(json!({"op":"save_merge","others":[other.path],"destination":merged}))
            .unwrap();
        assert!(report["page_count"].as_u64().unwrap() > 3);
        assert!(
            report["appended_annotation_counts"]
                .as_array()
                .unwrap()
                .iter()
                .any(|n| n.as_u64().unwrap() > 0)
        );
        let merged_doc = open_fixture_document(&merged, None).unwrap();
        let marks = merged_doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(marks["annotations"].as_array().unwrap().len(), 2);
        let embedded = merged_doc.command(json!({"op":"annotations"})).unwrap();
        for note in ["mark-0", "mark-2"] {
            assert!(
                embedded
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|a| a["contents"] == note)
            );
        }
        assert!(
            doc.command(json!({"op":"save_merge","others":[other.path],"destination":merged}))
                .is_err()
        );
        let split_dir = fixture.directory.join("split");
        fs::create_dir(&split_dir).unwrap();
        let plan = doc
            .command(json!({"op":"split_plan","ranges":"3, 1-2","directory":split_dir}))
            .unwrap();
        assert_eq!(plan["parts"][0]["pages"], json!([0, 1]));
        let report = doc
            .command(json!({"op":"save_split","parts":plan["parts"]}))
            .unwrap();
        assert_eq!(report["parts"].as_array().unwrap().len(), 2);
        let last = PathBuf::from(report["parts"][1]["destination_path"].as_str().unwrap());
        let part = open_fixture_document(&last, None).unwrap();
        let marks = part.command(json!({"op":"marks"})).unwrap();
        assert_eq!(marks["annotations"][0]["page"], 0);
        assert_eq!(marks["annotations"][0]["note"], "mark-2");
        let embedded = part.command(json!({"op":"annotations"})).unwrap();
        assert!(
            embedded
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["contents"] == "mark-2" && a["page"] == 0)
        );
        assert!(
            doc.command(json!({"op":"save_split","parts":plan["parts"]}))
                .is_err()
        );
        let blocked = fixture.directory.join("blocked.pdf");
        fs::write(
            format!("{}.aris-annotations.json", blocked.display()),
            b"[]",
        )
        .unwrap();
        doc.command(json!({"op":"save_split","parts":[{"destination_path":blocked,"pages":[0]}]}))
            .unwrap();
        assert!(blocked.exists());
        assert_eq!(
            fs::read(format!("{}.aris-annotations.json", blocked.display())).unwrap(),
            b"[]"
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), source_bytes);
    }

    #[test]
    #[cfg(unix)]
    fn a_later_split_failure_keeps_earlier_outputs_with_their_marks() {
        use std::os::unix::fs::PermissionsExt;
        let fixture = Fixture::new("multipage.pdf");
        let doc = fixture.open();
        doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":3,"color":"#E8BC5580","note":"carried"}})).unwrap();
        let blocked = fixture.directory.join("readonly");
        fs::create_dir(&blocked).unwrap();
        fs::set_permissions(&blocked, fs::Permissions::from_mode(0o500)).unwrap();
        let first = fixture.directory.join("first.pdf");
        let outcome=doc.command(json!({"op":"save_split","parts":[{"destination_path":first,"pages":[0]},{"destination_path":blocked.join("second.pdf"),"pages":[2]}]}));
        fs::set_permissions(&blocked, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(outcome.unwrap_err().contains("1 completed outputs"));
        let first = open_fixture_document(&first, None).unwrap();
        let marks = first.command(json!({"op":"marks"})).unwrap();
        assert_eq!(marks["annotations"][0]["note"], "carried");
    }

    #[test]
    fn unknown_marks_survive_append_but_stop_unsafe_split_remapping() {
        let fixture = Fixture::new("multipage.pdf");
        let other = Fixture::new("text-page.pdf");
        let raw = r#"{"kind" : "future-entry", "page": 2, "unknown" : [1, 2]}"#;
        fs::write(cache_path(&fixture.path), format!("[{raw}]")).unwrap();
        let doc = fixture.open();
        let merged = fixture.directory.join("future-merged.pdf");
        doc.command(json!({"op":"save_merge","others":[other.path],"destination":merged}))
            .unwrap();
        assert!(
            fs::read_to_string(cache_path(&merged))
                .unwrap()
                .contains(raw)
        );
        let split = fixture.directory.join("unsafe.pdf");
        assert!(
            doc.command(
                json!({"op":"save_split","parts":[{"destination_path":split,"pages":[2]}]})
            )
            .is_err()
        );
        assert!(!split.exists());
    }

    #[test]
    fn discard_refreshes_the_signature_of_an_externally_replaced_source() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let original = fs::read(&fixture.path).unwrap();
        let signed = fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/signed-signature.pdf"),
        )
        .unwrap();
        fs::write(&fixture.path, &signed).unwrap();
        let discarded = doc.command(json!({"op":"document_discard"})).unwrap();
        assert_eq!(discarded["info"]["signature_status"]["signed"], true);
        assert_eq!(
            doc.command(json!({"op":"signature_status"})).unwrap()["signed"],
            true
        );
        assert!(doc.command(json!({"op":"document_save"})).is_err());
        assert_eq!(fs::read(&fixture.path).unwrap(), signed);
        fs::write(&fixture.path, &original).unwrap();
        let discarded = doc.command(json!({"op":"document_discard"})).unwrap();
        assert_eq!(discarded["info"]["signature_status"]["signed"], false);
    }

    fn replacement_command(doc: &DesktopDocument, text: &str) -> Value {
        let snapshot = doc
            .command(json!({"op":"content_objects","page":0}))
            .unwrap();
        let item = snapshot["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["kind"] == "text" && item["can_edit_text"] == true)
            .expect("editable synthetic text");
        json!({"ReplaceText":{"revision":snapshot["revision"],"target":item["id"],
            "text":text,"bounds":item["bounds"],"font":"Helvetica","size":12.0,
            "colour":[0,0,0,255],"alignment":0}})
    }
    fn stage_replacement(doc: &DesktopDocument, text: &str) -> Value {
        doc.command(json!({"op":"content_stage","page":0,"command":replacement_command(doc,text)}))
            .unwrap()
    }
    #[test]
    fn content_stage_materializes_marks_once_and_undo_redo_save_keep_the_source_contract() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let path = cache_path(&fixture.path);
        let foreign = r#"{ "kind":"future", "page":0, "precision":1.0000000000000001 }"#;
        fs::write(&path, format!("[{foreign}]")).unwrap();
        let doc = fixture.open();
        doc.command(json!({"op":"mark_create","entry":{"kind":"square","page":0,"version":1,
            "rect":{"x":20,"y":20,"width":30,"height":30},"strokeWidth":2,"color":"#1B7F3BFF","note":"Materialized once"}})).unwrap();
        doc.command(
            json!({"op":"bookmark_create","page":0,"title":"Preserved destination","yPt":12}),
        )
        .unwrap();
        let staged = stage_replacement(&doc, "Staged native text");
        assert_eq!(staged["marks"]["page_pending"], true);
        assert_eq!(staged["marks"]["annotations"].as_array().unwrap().len(), 0);
        assert_eq!(staged["marks"]["preserved"], 1);
        assert_eq!(
            doc.command(json!({"op":"annotations"}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(
            doc.command(json!({"op":"text","page":0})).unwrap()["text"]
                .as_str()
                .unwrap()
                .contains("Staged native text")
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        let undone = doc.command(json!({"op":"page_undo"})).unwrap();
        assert_eq!(undone["info"]["revision"], json!(fixture.path));
        assert_eq!(undone["marks"]["annotations"].as_array().unwrap().len(), 1);
        doc.command(json!({"op":"page_redo"})).unwrap();
        let saved = doc.command(json!({"op":"document_save"})).unwrap();
        assert_eq!(saved["marks"]["page_pending"], false);
        let reopened = fixture.open();
        assert!(
            reopened.command(json!({"op":"text","page":0})).unwrap()["text"]
                .as_str()
                .unwrap()
                .contains("Staged native text")
        );
        assert_eq!(
            reopened
                .command(json!({"op":"annotations"}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            reopened.command(json!({"op":"marks"})).unwrap()["bookmarks"][0]["title"],
            "Preserved destination"
        );
        assert!(
            fs::read_to_string(cache_path(&fixture.path))
                .unwrap()
                .contains(foreign)
        );
    }
    #[test]
    fn failed_first_content_edit_restores_original_cache_targets_and_keeps_marks() {
        let fixture = Fixture::new("text-page.pdf");
        let original_pdf = fs::read(&fixture.path).unwrap();
        let cache = cache_path(&fixture.path);
        let foreign = r#"{ "kind":"future-cache-kind", "number":1.0000, "text":"a\/b" }"#;
        fs::write(&cache, format!("[{foreign}]\n")).unwrap();
        let doc = fixture.open();
        let created = doc.command(json!({"op":"mark_create","entry":{"kind":"square","page":0,"version":1,
            "rect":{"x":20,"y":20,"width":30,"height":30},"strokeWidth":2,"color":"#1B7F3BFF","note":"Before the rejected first edit"}})).unwrap();
        let id = created["selected_id"].clone();
        doc.command(
            json!({"op":"bookmark_create","page":0,"title":"Keep the original bookmark","yPt":12}),
        )
        .unwrap();
        let before = fs::read(&cache).unwrap();
        let identity_path = cache.with_file_name("source.json");
        let identity = fs::read(&identity_path).unwrap();
        let snapshot = doc
            .command(json!({"op":"content_objects","page":0}))
            .unwrap();
        assert!(
            doc.command(json!({"op":"content_stage","page":0,"command":{"Delete":{
            "revision":snapshot["revision"],"target":"missing-first-content-target"}}}))
                .is_err()
        );
        assert!(!cache.with_file_name("session.json").exists());
        assert_eq!(cache_path(&fixture.path), cache);
        assert_eq!(fs::read(&cache).unwrap(), before);
        assert_eq!(fs::read(&identity_path).unwrap(), identity);
        let after = doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(after["page_session_active"], false);
        assert_eq!(after["page_pending"], false);
        assert_eq!(after["preserved"], 1);
        assert_eq!(after["annotations"].as_array().unwrap().len(), 1);
        assert_eq!(after["bookmarks"].as_array().unwrap().len(), 1);
        assert_eq!(after["annotations"][0]["id"], id);
        // A subsequent annotation edit must persist at the original DocumentId cache,
        // rather than a retired transaction directory which disappears on close.
        doc.command(
            json!({"op":"mark_update","id":id,"patch":{"note":"After the rejected first edit"}}),
        )
        .unwrap();
        assert!(fs::read_to_string(&cache).unwrap().contains(foreign));
        assert_eq!(fs::read(&fixture.path).unwrap(), original_pdf);
        drop(doc);
        let reopened = fixture.open();
        let saved = reopened.command(json!({"op":"marks"})).unwrap();
        assert_eq!(
            saved["annotations"][0]["note"],
            "After the rejected first edit"
        );
        assert_eq!(saved["annotations"][0]["id"], id);
        assert_eq!(saved["bookmarks"].as_array().unwrap().len(), 1);
        assert_eq!(saved["preserved"], 1);
        assert_eq!(saved["page_session_active"], false);
    }
    #[test]
    fn stale_content_commands_create_no_session_and_failed_edits_keep_redo() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let mut stale = replacement_command(&doc, "Never written");
        stale["ReplaceText"]["revision"] = json!("0".repeat(64));
        assert!(
            doc.command(json!({"op":"content_stage","page":0,"command":stale}))
                .unwrap_err()
                .contains("page changed")
        );
        assert!(
            !cache_path(&fixture.path)
                .with_file_name("session.json")
                .exists()
        );
        stage_replacement(&doc, "Redo survives failure");
        doc.command(json!({"op":"page_undo"})).unwrap();
        let snapshot = doc
            .command(json!({"op":"content_objects","page":0}))
            .unwrap();
        assert!(
            doc.command(json!({"op":"content_stage","page":0,"command":{"Delete":{
            "revision":snapshot["revision"],"target":"missing-target"}}}))
                .is_err()
        );
        let marks = doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(marks["can_page_redo"], true);
        doc.command(json!({"op":"page_redo"})).unwrap();
        assert!(
            doc.command(json!({"op":"text","page":0})).unwrap()["text"]
                .as_str()
                .unwrap()
                .contains("Redo survives failure")
        );
    }
    #[test]
    fn erase_removes_actual_text_and_a_copy_does_not_change_the_original() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let original = fs::read(&fixture.path).unwrap();
        let snapshot = doc
            .command(json!({"op":"content_objects","page":0}))
            .unwrap();
        let item = snapshot["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| {
                v["kind"] == "text"
                    && v["text"]
                        .as_str()
                        .is_some_and(|s| s.contains("LyraReader fixture"))
            })
            .unwrap();
        let command = json!({"Redact":{"revision":snapshot["revision"],"bounds":item["bounds"],"blackout":false}});
        let preflight = doc
            .command(json!({"op":"content_redaction_preflight","page":0,"command":command}))
            .unwrap();
        assert!(preflight.as_array().unwrap().is_empty());
        let staged = doc
            .command(json!({"op":"content_stage","page":0,"command":command}))
            .unwrap();
        assert!(
            staged["report"]["rasterized_pages"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let output = fixture.directory.join("erased.pdf");
        doc.command(json!({"op":"save_document_copy","destination":output}))
            .unwrap();
        let copy = open_fixture_document(&output, None).unwrap();
        assert!(
            !copy.command(json!({"op":"text","page":0})).unwrap()["text"]
                .as_str()
                .unwrap()
                .contains("LyraReader fixture")
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        doc.command(json!({"op":"page_undo"})).unwrap();
        assert!(
            doc.command(json!({"op":"text","page":0})).unwrap()["text"]
                .as_str()
                .unwrap()
                .contains("LyraReader fixture")
        );
    }
    #[test]
    fn content_image_export_preserves_revisions_source_permissions_and_failed_destinations() {
        let fixture = Fixture::new("text-page.pdf");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&fixture.directory, fs::Permissions::from_mode(0o750)).unwrap();
        }
        let doc = fixture.open();
        let original = fs::read(&fixture.path).unwrap();
        let input = fixture.directory.join("input.png");
        image::RgbaImage::from_pixel(4, 2, image::Rgba([255, 0, 0, 255]))
            .save(&input)
            .unwrap();
        let snapshot = doc
            .command(json!({"op":"content_objects","page":0}))
            .unwrap();
        doc.command(json!({"op":"content_stage","page":0,"command":{"InsertImage":{"revision":snapshot["revision"],"bounds":{"x":72,"y":500,"width":100,"height":50},"image_path":input}}})).unwrap();
        let snapshot = doc
            .command(json!({"op":"content_objects","page":0}))
            .unwrap();
        let item = snapshot["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["kind"] == "image")
            .unwrap();
        let destination = fixture.directory.join("image.png");
        let revision = doc.info().unwrap()["revision"].clone();
        let request = json!({"op":"save_content_image","page":0,"target":item["id"],"revision":snapshot["revision"],"destination":destination});
        let expected = doc
            .active()
            .unwrap()
            .content_image_png(
                0,
                item["id"].as_str().unwrap().into(),
                snapshot["revision"].as_str().unwrap().into(),
            )
            .unwrap();
        let result = doc.command(request.clone()).unwrap();
        assert_eq!(result["bytes"], expected.len());
        assert_eq!(fs::read(&destination).unwrap(), expected);
        assert_eq!(doc.info().unwrap()["revision"], revision);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&fixture.directory)
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o750
            );
        }
        let mut stale = request.clone();
        stale["revision"] = json!("stale");
        assert!(doc.command(stale).is_err());
        assert_eq!(fs::read(&destination).unwrap(), expected);
        let mut original_target = request.clone();
        original_target["destination"] = json!(fixture.path);
        assert!(
            doc.command(original_target)
                .unwrap_err()
                .contains("original PDF")
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        let blocked = fixture.directory.join("blocked.png");
        fs::create_dir(&blocked).unwrap();
        let mut failed = request.clone();
        failed["destination"] = json!(blocked);
        assert!(doc.command(failed).is_err());
        assert!(blocked.is_dir());
        assert_eq!(fs::read(&destination).unwrap(), expected);
        assert!(!fs::read_dir(&fixture.directory).unwrap().any(|e| {
            e.unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".lyra-image-")
        }));
        let mut wrong = request.clone();
        let wrong_path = fixture.directory.join("wrong.jpg");
        wrong["destination"] = json!(wrong_path);
        assert!(doc.command(wrong).unwrap_err().contains("PNG file name"));
        assert!(!wrong_path.exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let alias = fixture.directory.join("active.png");
            symlink(revision.as_str().unwrap(), &alias).unwrap();
            let before = fs::read(&alias).unwrap();
            let mut active = request;
            active["destination"] = json!(alias);
            assert!(
                doc.command(active)
                    .unwrap_err()
                    .contains("active PDF revision")
            );
            assert_eq!(fs::read(&alias).unwrap(), before);
        }
        assert_eq!(doc.info().unwrap()["revision"], revision);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn graphic_export_resolves_the_working_object_and_protects_existing_output() {
        let fixture = Fixture::new("form-text-pages.pdf");
        let doc = fixture.open();
        let original = fs::read(&fixture.path).unwrap();
        let snapshot = doc
            .command(json!({"op":"content_objects","page":0}))
            .unwrap();
        let graphic = snapshot["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["kind"] == "graphic")
            .unwrap();
        let mut moved = graphic["bounds"].clone();
        moved["x"] = json!(moved["x"].as_f64().unwrap() + 35.0);
        moved["y"] = json!(moved["y"].as_f64().unwrap() + 17.0);
        doc.command(json!({"op":"content_stage","page":0,"command":{"Transform":{"revision":snapshot["revision"],"target":graphic["id"],"bounds":moved,"rotation":0.0}}})).unwrap();
        let current = doc
            .command(json!({"op":"content_objects","page":0}))
            .unwrap();
        assert_ne!(current["revision"], snapshot["revision"]);
        let item = current["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| {
                i["kind"] == "graphic"
                    && (i["bounds"]["x"].as_f64().unwrap() - moved["x"].as_f64().unwrap()).abs()
                        < 0.1
            })
            .unwrap();
        let b = &item["bounds"];
        let expected = doc
            .active()
            .unwrap()
            .rasterize_region(
                0,
                2.0,
                b["x"].as_f64().unwrap(),
                b["y"].as_f64().unwrap(),
                b["width"].as_f64().unwrap(),
                b["height"].as_f64().unwrap(),
                false,
            )
            .unwrap();
        let destination = fixture.directory.join("graphic.png");
        // A forged UI rectangle cannot override the shared object's actual geometry.
        let request = json!({"op":"save_content_image","page":0,"kind":"graphic","target":item["id"],"revision":current["revision"],"destination":destination,"bounds":{"x":0,"y":0,"width":1,"height":1}});
        doc.command(request.clone()).unwrap();
        let written = fs::read(&destination).unwrap();
        let rgba = image::load_from_memory(&written).unwrap().into_rgba8();
        assert_eq!(rgba.dimensions(), (expected.width_px, expected.height_px));
        let mut brown = 0;
        for (x, y, pixel) in rgba.enumerate_pixels() {
            let offset = (y * expected.stride + x * 4) as usize;
            assert_eq!(
                pixel.0,
                [
                    expected.pixels[offset + 2],
                    expected.pixels[offset + 1],
                    expected.pixels[offset],
                    255
                ]
            );
            if pixel[0] > 110 && pixel[0] < 170 && pixel[1] > 50 && pixel[1] < 110 && pixel[2] < 90
            {
                brown += 1;
            }
        }
        assert!(brown > 10);
        let mut stale = request.clone();
        stale["revision"] = snapshot["revision"].clone();
        assert!(
            doc.command(stale)
                .unwrap_err()
                .contains("older document revision")
        );
        let text = current["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["kind"] == "text")
            .unwrap();
        let mut wrong = request.clone();
        wrong["target"] = text["id"].clone();
        assert!(doc.command(wrong).unwrap_err().contains("Select a graphic"));
        let mut malformed = request;
        malformed["kind"] = json!(42);
        assert!(
            doc.command(malformed)
                .unwrap_err()
                .contains("Invalid image kind")
        );
        assert_eq!(fs::read(&destination).unwrap(), written);
        assert_eq!(
            doc.command(json!({"op":"content_objects","page":0}))
                .unwrap()["revision"],
            current["revision"]
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn content_preview_pins_original_bytes_across_atomic_save_and_source_removal() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let input = fixture.directory.join("preview.png");
        image::RgbaImage::from_pixel(4, 2, image::Rgba([255, 0, 0, 255]))
            .save(&input)
            .unwrap();
        let snapshot = doc
            .command(json!({"op":"content_objects","page":0}))
            .unwrap();
        doc.command(json!({"op":"content_stage","page":0,"command":{"InsertImage":{"revision":snapshot["revision"],"bounds":{"x":72,"y":500,"width":100,"height":50},"image_path":input}}})).unwrap();
        doc.command(json!({"op":"document_save"})).unwrap();
        let snapshot = doc
            .command(json!({"op":"content_objects","page":0}))
            .unwrap();
        let item = snapshot["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|i| i["kind"] == "image")
            .unwrap();
        let target = item["id"].as_str().unwrap();
        let revision = snapshot["revision"].as_str().unwrap();
        let frozen = crate::render_source::RenderSource::new(&doc, false).unwrap();
        let expected = frozen.image_png(0, target, revision).unwrap();
        // A sparse, oversized source must be rejected before a source-sized allocation.
        let original = fs::read(&fixture.path).unwrap();
        let file = fs::OpenOptions::new()
            .write(true)
            .open(&fixture.path)
            .unwrap();
        file.set_len(512 * 1024 * 1024 + 1).unwrap();
        assert!(
            frozen
                .image_png(0, target, revision)
                .unwrap_err()
                .contains("too large")
        );
        drop(file);
        fs::write(&fixture.path, &original).unwrap();
        image::RgbaImage::from_pixel(4, 2, image::Rgba([0, 0, 255, 255]))
            .save(&input)
            .unwrap();
        doc.command(json!({"op":"content_stage","page":0,"command":{"ReplaceImage":{"revision":revision,"target":target,"image_path":input}}})).unwrap();
        doc.command(json!({"op":"document_save"})).unwrap();
        assert_eq!(frozen.image_png(0, target, revision).unwrap(), expected);
        drop(doc);
        fs::remove_file(&fixture.path).unwrap();
        assert_eq!(frozen.image_png(0, target, revision).unwrap(), expected);
        assert!(frozen.image_png(0, target, "stale").is_err());
    }

    #[test]
    fn region_captures_freeze_working_pixels_text_and_original_colours() {
        use base64::Engine as _;
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        stage_replacement(&doc, "Frozen area");
        let source = crate::render_source::RenderSource::new(&doc, false).unwrap();
        let request = json!({"op":"capture_region","page":0,"zoom":1.0,"rect":{"x":0,"y":0,"width":595,"height":842}});
        let before = source.query(request.clone()).unwrap();
        assert!(before["text"].as_str().unwrap().contains("Frozen area"));
        assert!(before["paper_plan"].is_object());
        assert!(before["paper_plan"]["split_pt"].is_null()); // Full-page region belongs at the row foot.
        assert!(before["paper_plan"]["warning"].is_null());
        let glyphs =
            serde_json::to_value(doc.active().unwrap().text_page(0).unwrap().chars).unwrap();
        let text_request = json!({"op":"capture_region","page":0,"zoom":1,"rect":{"x":0,"y":0,"width":595,"height":100},"glyphs":glyphs});
        let text_region = source.query(text_request.clone()).unwrap();
        assert!(!text_region["text"].as_str().unwrap().trim().is_empty());
        assert_eq!(text_region["paper_plan"]["split_pt"], 100.0);
        let mut indexed_request = text_request.clone();
        indexed_request["indexed_regions"] =
            json!([{"x_pt":0,"y_pt":95,"width_pt":595,"height_pt":110}]);
        let indexed = source.query(indexed_request).unwrap();
        assert_eq!(indexed["image_png"], text_region["image_png"]);
        assert_ne!(indexed["paper_plan"]["split_pt"], 100.0); // Never cut the already indexed figure.
        assert!(source.query(json!({"op":"capture_region","page":0,"zoom":1,"rect":{"x":0,"y":0,"width":595,"height":100},"indexed_regions":[{}]})).is_err());
        assert_eq!(
            (
                before["image_width_px"].as_u64(),
                before["image_height_px"].as_u64()
            ),
            (Some(1190), Some(1684))
        );
        let png = base64::engine::general_purpose::STANDARD
            .decode(before["image_png"].as_str().unwrap())
            .unwrap();
        let image = image::load_from_memory(&png).unwrap().into_rgba8();
        assert_eq!(image.get_pixel(0, 0).0, [255, 255, 255, 255]);
        stage_replacement(&doc, "Later area");
        doc.command(json!({"op":"document_save"})).unwrap();
        assert_eq!(source.query(request.clone()).unwrap(), before);
        doc.command(json!({"op":"document_discard"})).unwrap();
        assert_eq!(source.query(request).unwrap(), before);
        assert!(source.query(json!({"op":"capture_region","page":0,"zoom":1e300,"rect":{"x":0,"y":0,"width":10,"height":10}})).is_err());
        assert!(source.query(json!({"op":"capture_region","page":0,"zoom":1,"rect":{"x":0,"y":0,"width":1000000,"height":1000000}})).is_err());
        assert!(source.query(json!({"op":"capture_region","page":0,"zoom":1,"rect":{"x":0,"y":0,"width":20,"height":20}})).unwrap_err().contains("blank"));
        let rotated = Fixture::new("rotated.pdf");
        let doc = rotated.open();
        let source = crate::render_source::RenderSource::new(&doc, false).unwrap();
        let sizes = source.query(json!({"op":"info"})).unwrap();
        for (page, size) in sizes.as_array().unwrap().iter().enumerate() {
            let result=source.query(json!({"op":"capture_region","page":page,"zoom":1,"rect":{"x":0,"y":0,"width":size["width_pt"],"height":size["height_pt"]}})).unwrap();
            assert_eq!(
                result["image_width_px"].as_u64().unwrap(),
                (size["width_pt"].as_f64().unwrap() * 2.0).ceil() as u64
            );
            assert!(!result["text"].as_str().unwrap().is_empty());
        }
    }
    #[test]
    fn frozen_preview_layout_and_text_survive_later_edits_save_and_discard() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        stage_replacement(&doc, "Frozen preview");
        let source = crate::render_source::RenderSource::new(&doc, false).unwrap();
        let first = source
            .query(json!({"op":"layout","mode":"Continuous","gap":12}))
            .unwrap();
        stage_replacement(&doc, "Later revision");
        doc.command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":0}}}))
            .unwrap();
        doc.command(json!({"op":"document_save"})).unwrap();
        assert_eq!(
            source
                .query(json!({"op":"layout","mode":"Continuous","gap":12}))
                .unwrap(),
            first
        );
        assert_eq!(
            source
                .query(json!({"op":"layout","mode":"Facing","gap":18}))
                .unwrap()["pages"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(
            source.query(json!({"op":"text","page":0})).unwrap()["text"]
                .as_str()
                .unwrap()
                .contains("Frozen preview")
        );
        assert_eq!(doc.info().unwrap()["pages"].as_array().unwrap().len(), 2);
        let saved = fs::read(&fixture.path).unwrap();
        assert!(source.query(json!({"op":"document_discard"})).is_err());
        assert_eq!(fs::read(&fixture.path).unwrap(), saved);
        doc.command(json!({"op":"document_discard"})).unwrap();
        assert_eq!(
            source
                .query(json!({"op":"layout","mode":"Continuous","gap":12}))
                .unwrap(),
            first
        );
    }

    #[test]
    fn content_redaction_requires_explicit_raster_consent_and_keeps_other_pages() {
        let fixture = Fixture::new("form-text-pages.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let snapshot = doc
            .command(json!({"op":"content_objects","page":0}))
            .unwrap();
        let item = snapshot["items"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| {
                v["text"]
                    .as_str()
                    .is_some_and(|text| text.contains("In shared form"))
            })
            .unwrap();
        let command = json!({"Redact":{"revision":snapshot["revision"],"bounds":item["bounds"],"blackout":true}});
        assert_eq!(
            doc.command(json!({"op":"content_redaction_preflight","page":0,"command":command}))
                .unwrap(),
            json!([0])
        );
        assert!(
            doc.command(json!({"op":"content_stage","page":0,"command":command}))
                .is_err()
        );
        assert_eq!(
            doc.command(json!({"op":"marks"})).unwrap()["page_pending"],
            false
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        let staged = doc
            .command(json!({"op":"content_stage","page":0,"command":command,"allow_raster":true}))
            .unwrap();
        assert_eq!(staged["report"]["rasterized_pages"], json!([0]));
        assert!(
            doc.command(json!({"op":"text","page":0})).unwrap()["text"]
                .as_str()
                .unwrap()
                .trim()
                .is_empty()
        );
        assert!(
            !doc.command(json!({"op":"text","page":1})).unwrap()["text"]
                .as_str()
                .unwrap()
                .trim()
                .is_empty()
        );
        doc.command(json!({"op":"page_undo"})).unwrap();
        assert!(
            doc.command(json!({"op":"text","page":0})).unwrap()["text"]
                .as_str()
                .unwrap()
                .contains("In shared form")
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    #[ignore = "subprocess fixture used by the content recovery check"]
    fn write_content_revision_then_exit_without_running_destructors() {
        let path = PathBuf::from(std::env::var_os("LYRA_READER_TEST_RECOVERY_PATH").unwrap());
        let doc = open_fixture_document(&path, None).unwrap();
        stage_replacement(&doc, "Content recovered after exit");
        std::process::exit(0);
    }
    #[test]
    fn content_revisions_recover_after_process_exit_and_discard_restores_the_source() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "document::tests::write_content_revision_then_exit_without_running_destructors",
                "--ignored",
            ])
            .env("LYRA_READER_TEST_RECOVERY_PATH", &fixture.path)
            .status()
            .unwrap();
        assert!(status.success());
        let doc = fixture.open();
        assert!(
            doc.command(json!({"op":"text","page":0})).unwrap()["text"]
                .as_str()
                .unwrap()
                .contains("Content recovered after exit")
        );
        assert_eq!(
            doc.command(json!({"op":"marks"})).unwrap()["page_pending"],
            true
        );
        doc.command(json!({"op":"document_discard"})).unwrap();
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert_eq!(
            fixture.open().command(json!({"op":"marks"})).unwrap()["page_pending"],
            false
        );
    }

    #[test]
    fn flattened_export_uses_saved_pdf_bytes_and_keeps_the_working_drafts() {
        let fixture = Fixture::new("flatten.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        doc.command(json!({"op":"mark_create","entry":{"kind":"textBox","page":0,"version":1,"rect":{"x":20,"y":20,"width":100,"height":30},"fontSize":14,"note":"Unsaved draft","color":"#000000ff"}})).unwrap();
        let before = doc.command(json!({"op":"marks"})).unwrap();
        let destination = fixture.directory.join("flattened.pdf");
        let report = doc
            .command(json!({"op":"save_flattened_copy","destination":destination}))
            .unwrap();
        assert_eq!(report["flattened_annotations"], 6);
        assert!(report["kept_annotations"].is_array());
        assert!(report["kept_fields"].is_array());
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert_eq!(doc.command(json!({"op":"marks"})).unwrap(), before);
        let output = open_fixture_document(&destination, None).unwrap();
        let exported = output.command(json!({"op":"marks"})).unwrap();
        assert!(
            exported["file_annotations"]
                .as_array()
                .unwrap()
                .iter()
                .all(|a| a["contents"] != "Unsaved draft")
        );
        doc.command(json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}},"current_page":0,"selected_pages":[0]})).unwrap();
        let active = doc.info().unwrap();
        let staged_output = fixture.directory.join("working-flattened.pdf");
        doc.command(json!({"op":"save_flattened_copy","destination":staged_output}))
            .unwrap();
        let copied = open_fixture_document(&staged_output, None)
            .unwrap()
            .info()
            .unwrap();
        assert_eq!(copied["pages"][0]["width"], active["pages"][0]["width"]);
        assert_eq!(copied["pages"][0]["height"], active["pages"][0]["height"]);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert_eq!(
            doc.command(json!({"op":"marks"})).unwrap()["page_pending"],
            true
        );
    }

    #[test]
    fn flattened_export_strips_derivative_signature_and_never_replaces_the_source() {
        let fixture = Fixture::new("signed-signature.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        assert!(
            doc.command(json!({"op":"save_flattened_copy","destination":fixture.path}))
                .is_err()
        );
        let destination = fixture.directory.join("unsigned-flattened.pdf");
        let report = doc
            .command(json!({"op":"save_flattened_copy","destination":destination}))
            .unwrap();
        assert!(report["signature_fields_removed"].as_u64().unwrap() > 0);
        let copied = open_fixture_document(&destination, None).unwrap();
        assert_eq!(copied.info().unwrap()["signature_status"]["signed"], false);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert_eq!(doc.info().unwrap()["signature_status"]["signed"], true);
    }

    #[test]
    fn note_text_groups_use_shared_kinds_preserve_geometry_and_cancel_as_one_step() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let kinds = doc.info().unwrap()["annotation_rules"]["kind_flags"]
            .as_array()
            .unwrap()
            .clone();
        assert!(
            kinds
                .iter()
                .any(|k| k["kind"] == "stickyNote" && k["is_note"] == true)
        );
        assert!(
            kinds
                .iter()
                .any(|k| k["kind"] == "highlight" && k["is_text_markup"] == true)
        );
        for entry in [
            json!({"kind":"stickyNote","page":0,"version":1,"rect":{"x":70,"y":80,"width":22,"height":22},"fontSize":14,"note":"original","color":"#E8BC55ff"}),
            json!({"kind":"highlight","page":0,"start":0,"end":3,"note":"original","color":"#E8BC5552"}),
        ] {
            let created = doc
                .command(json!({"op":"mark_create","entry":entry}))
                .unwrap();
            let id = created["selected_id"].clone();
            let before = created["annotations"].clone();
            assert!(
                doc.command(json!({"op":"mark_text_begin","id":id,"created":false}))
                    .is_err()
            );
            let begun = doc
                .command(json!({"op":"mark_text_begin","id":id,"created":false,"note_only":true}))
                .unwrap();
            let token = begun["text_edit_token"].clone();
            assert!(doc.command(json!({"op":"mark_text_update","id":id,"edit_token":token,"patch":{"note":"forged","rect":{"x":0,"y":0,"width":200,"height":200}}})).is_err());
            for note in ["first", "second", "last"] {
                doc.command(json!({"op":"mark_text_update","id":id,"edit_token":token,"patch":{"note":note}})).unwrap();
            }
            let stored = fixture.open().command(json!({"op":"marks"})).unwrap();
            assert_eq!(
                stored["annotations"].as_array().unwrap().last().unwrap()["note"],
                "last"
            );
            doc.command(json!({"op":"mark_text_end","id":id,"edit_token":token,"cancel":false}))
                .unwrap();
            let undone = doc.command(json!({"op":"marks_undo"})).unwrap();
            assert_eq!(undone["annotations"], before);
            let begun = doc
                .command(json!({"op":"mark_text_begin","id":id,"created":false,"note_only":true}))
                .unwrap();
            let token = begun["text_edit_token"].clone();
            doc.command(json!({"op":"mark_text_update","id":id,"edit_token":token,"patch":{"note":"cancelled"}})).unwrap();
            let cancelled = doc
                .command(json!({"op":"mark_text_end","id":id,"edit_token":token,"cancel":true}))
                .unwrap();
            assert_eq!(cancelled["annotations"], before);
        }
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn cancelled_text_and_adoption_undo_keep_an_idle_page_transaction_clean() {
        let fixture = Fixture::new("flatten.pdf");
        let doc = fixture.open();
        doc.command(json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}},"current_page":0,"selected_pages":[0]})).unwrap();
        doc.command(json!({"op":"page_undo"})).unwrap();
        let state = doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(state["page_pending"], false);
        assert_eq!(state["pdf_dirty"], false);
        let annotation = state["file_annotations"]
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["kind"] == "freeText")
            .unwrap();
        let adopted = doc
            .command(json!({"op":"file_adopt","id":annotation["id"]}))
            .unwrap();
        let id = adopted["selected_id"].clone();
        let begun = doc
            .command(json!({"op":"mark_text_begin","id":id,"created":false}))
            .unwrap();
        let token = begun["text_edit_token"].clone();
        doc.command(json!({"op":"mark_text_update","id":id,"edit_token":token,"patch":{"note":"Cancelled native draft"}})).unwrap();
        doc.command(json!({"op":"mark_text_end","id":id,"edit_token":token,"cancel":true}))
            .unwrap();
        let undone = doc.command(json!({"op":"marks_undo"})).unwrap();
        assert_eq!(undone["pdf_dirty"], false);
        assert_eq!(undone["page_pending"], false);
        assert!(undone["annotations"].as_array().unwrap().is_empty());
        drop(doc);
        let reopened = fixture.open();
        let restored = reopened.command(json!({"op":"marks"})).unwrap();
        assert_eq!(restored["pdf_dirty"], false);
        assert_eq!(restored["page_pending"], false);
        assert!(restored["annotations"].as_array().unwrap().is_empty());
    }

    #[test]
    fn placed_text_flushes_coalesce_and_cancel_restores_creation_and_cache() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        doc.command(json!({"op":"bookmark_create","page":0,"title":"Keep"}))
            .unwrap();
        let created = doc.command(json!({"op":"mark_create","entry":{"kind":"textBox","page":0,"version":1,"rect":{"x":70,"y":80,"width":100,"height":30},"fontSize":14,"note":"original","color":"#000000ff"}})).unwrap();
        let id = created["selected_id"].as_str().unwrap();
        let begin = doc
            .command(json!({"op":"mark_text_begin","id":id,"created":true}))
            .unwrap();
        let token = &begin["text_edit_token"];
        for text in ["first", "second", "last"] {
            doc.command(
                json!({"op":"mark_text_update","id":id,"edit_token":token,"patch":{"note":text}}),
            )
            .unwrap();
        }
        // Coalesced writes are durable even when the editing session never ends.
        assert_eq!(
            fixture.open().command(json!({"op":"marks"})).unwrap()["annotations"][0]["note"],
            "last"
        );
        let cancelled = doc
            .command(json!({"op":"mark_text_end","id":id,"edit_token":token,"cancel":true}))
            .unwrap();
        assert_eq!(cancelled["annotations"], json!([]));
        assert_eq!(cancelled["bookmarks"].as_array().unwrap().len(), 1);
        let undone = doc.command(json!({"op":"marks_undo"})).unwrap();
        assert_eq!(undone["annotations"], json!([]));
        assert_eq!(undone["bookmarks"], json!([]));
    }

    #[test]
    fn placed_text_tokens_cannot_overwrite_interleaved_changes_or_saved_documents() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let created = doc.command(json!({"op":"mark_create","entry":{"kind":"textBox","page":0,"version":1,"rect":{"x":70,"y":80,"width":100,"height":30},"fontSize":14,"note":"before","color":"#000000ff"}})).unwrap();
        let id = created["selected_id"].as_str().unwrap();
        let begin = doc
            .command(json!({"op":"mark_text_begin","id":id,"created":false}))
            .unwrap();
        let token = &begin["text_edit_token"];
        assert!(
            doc.command(
                json!({"op":"mark_text_update","id":id,"edit_token":"stale","patch":{"note":"bad"}})
            )
            .is_err()
        );
        assert!(
            doc.command(
                json!({"op":"mark_text_update","id":id,"edit_token":token,"patch":{"kind":"stamp"}})
            )
            .is_err()
        );
        for text in ["one", "two", "final"] {
            doc.command(
                json!({"op":"mark_text_update","id":id,"edit_token":token,"patch":{"note":text}}),
            )
            .unwrap();
        }
        doc.command(json!({"op":"mark_text_end","id":id,"edit_token":token,"cancel":false}))
            .unwrap();
        assert_eq!(
            doc.command(json!({"op":"marks_undo"})).unwrap()["annotations"][0]["note"],
            "before"
        );
        assert_eq!(
            doc.command(json!({"op":"marks_redo"})).unwrap()["annotations"][0]["note"],
            "final"
        );
        let next = doc
            .command(json!({"op":"mark_text_begin","id":id,"created":false}))
            .unwrap();
        doc.command(json!({"op":"bookmark_create","page":0,"title":"Later"}))
            .unwrap();
        assert!(doc.command(json!({"op":"mark_text_end","id":id,"edit_token":next["text_edit_token"],"cancel":true})).is_err());
        let state = doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(state["annotations"][0]["note"], "final");
        assert_eq!(state["bookmarks"].as_array().unwrap().len(), 1);
        let final_edit = doc
            .command(json!({"op":"mark_text_begin","id":id,"created":false}))
            .unwrap();
        doc.command(json!({"op":"document_save"})).unwrap();
        assert!(doc.command(json!({"op":"mark_text_end","id":id,"edit_token":final_edit["text_edit_token"],"cancel":true})).is_err());
    }

    #[test]
    fn placed_text_write_failure_preserves_external_bytes_and_can_still_be_reviewed() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let created = doc.command(json!({"op":"mark_create","entry":{"kind":"textBox","page":0,"version":1,"rect":{"x":70,"y":80,"width":100,"height":30},"fontSize":14,"note":"before","color":"#000000ff"}})).unwrap();
        let id = created["selected_id"].as_str().unwrap();
        let begin = doc
            .command(json!({"op":"mark_text_begin","id":id,"created":true}))
            .unwrap();
        let path = Path::new(created["path"].as_str().unwrap());
        let mut external = fs::read(path).unwrap();
        external.push(b' ');
        fs::write(path, &external).unwrap();
        assert!(doc.command(json!({"op":"mark_text_update","id":id,"edit_token":begin["text_edit_token"],"patch":{"note":"must not publish"}})).is_err());
        assert!(doc.command(json!({"op":"mark_text_end","id":id,"edit_token":begin["text_edit_token"],"cancel":true})).is_err());
        assert_eq!(fs::read(path).unwrap(), external);
        let state = doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(state["annotations"][0]["note"], "before");
        assert_eq!(state["can_undo"], true);
    }

    #[test]
    fn placed_text_cancellation_keeps_the_working_page_transaction() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let staged = doc.command(json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}},"current_page":0,"selected_pages":[0]})).unwrap();
        assert!(staged["marks"]["page_pending"].as_bool().unwrap());
        // Page operations materialize pre-existing marks into the working PDF. Create the
        // editable box afterwards, in that private revision's annotation cache.
        let created = doc.command(json!({"op":"mark_create","entry":{"kind":"textBox","page":0,"version":1,"rect":{"x":70,"y":80,"width":100,"height":30},"fontSize":14,"note":"keep","color":"#000000ff"}})).unwrap();
        let id = created["selected_id"].as_str().unwrap();
        let begin = doc
            .command(json!({"op":"mark_text_begin","id":id,"created":false}))
            .unwrap();
        doc.command(json!({"op":"mark_text_update","id":id,"edit_token":begin["text_edit_token"],"patch":{"note":"cancel this"}})).unwrap();
        let cancelled = doc.command(json!({"op":"mark_text_end","id":id,"edit_token":begin["text_edit_token"],"cancel":true})).unwrap();
        assert_eq!(cancelled["annotations"][0]["note"], "keep");
        assert_eq!(cancelled["page_pending"], true);
        let saved = doc.command(json!({"op":"document_save"})).unwrap();
        assert_eq!(saved["marks"]["page_pending"], false);
        let embedded = fixture.open().command(json!({"op":"marks"})).unwrap();
        assert!(
            embedded["file_annotations"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["contents"] == "keep")
        );
    }

    #[test]
    fn private_working_pdf_cannot_remove_the_source_xfa_read_only_contract() {
        let fixture = Fixture::new("xfa-refusal.pdf");
        let working = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let source = fs::read(&fixture.path).unwrap();
        // Model a legacy recovered synthetic revision. Its plain PDF status cannot authorize
        // overwriting an XFA source or enabling annotation tools in the native shell.
        *doc.engine.write().unwrap() = working.open().active().unwrap();
        assert_eq!(doc.info().unwrap()["xfa_status"]["is_xfa"], true);
        assert!(doc.command(json!({"op":"mark_create"})).is_err());
        assert!(doc.command(json!({"op":"document_save"})).is_err());
        assert_eq!(fs::read(&fixture.path).unwrap(), source);
        doc.command(json!({"op":"document_discard"})).unwrap();
        assert_eq!(doc.info().unwrap()["xfa_status"]["is_xfa"], true);
    }

    #[test]
    fn xfa_all_write_routes_are_read_only_but_reading_bookmarks_survive() {
        let fixture = Fixture::new("xfa-refusal.pdf");
        let doc = fixture.open();
        let source = fs::read(&fixture.path).unwrap();
        let reason = doc.info().unwrap()["xfa_status"]["read_only_reason"]
            .as_str()
            .unwrap()
            .to_string();
        for op in [
            "mark_create",
            "mark_update",
            "mark_delete",
            "file_delete",
            "file_adopt",
            "marks_erase",
            "ink_erase_begin",
            "ink_erase_update",
            "ink_erase_commit",
            "content_stage",
            "content_redaction_preflight",
            "page_stage",
            "page_undo",
            "page_redo",
            "page_apply",
            "document_save",
            "page_operation",
            "extract_pages",
            "save_document_copy",
            "save_current_edited_copy",
            "save_current_annotations",
            "replace_current_annotations",
            "save_annotations",
            "replace_annotations",
            "save_forms",
            "save_flattened_copy",
            "save_content_image",
            "replace_forms",
            "save_properties",
            "replace_properties",
            "save_edited_copy",
            "replace_edited_pages",
            "save_merge",
            "save_split",
        ] {
            let output = fixture.directory.join(format!("{op}.pdf"));
            let error = doc
                .command(json!({"op":op,"destination":output}))
                .unwrap_err();
            assert_eq!(error, reason, "{op}");
            assert!(!output.exists(), "{op}");
            assert!(!cache_path(&fixture.path).exists(), "{op}");
            assert!(
                !cache_path(&fixture.path)
                    .with_file_name("session.json")
                    .exists()
            );
            assert_eq!(fs::read(&fixture.path).unwrap(), source);
        }
        assert!(!doc.render(0, 0.5, true).unwrap().pixels.is_empty());
        doc.command(json!({"op":"text","page":0})).unwrap();
        doc.command(json!({"op":"search","pattern":"form","limit":10}))
            .unwrap();
        doc.command(json!({"op":"layout","mode":"Facing","gap":12}))
            .unwrap();
        let created = doc.command(json!({"op":"bookmark_create","page":0,"title":"Local XFA reading position","yPt":0})).unwrap();
        let id = created["bookmarks"][0]["id"].as_str().unwrap();
        doc.command(json!({"op":"bookmark_update","id":id,"patch":{"title":"Kept locally"}}))
            .unwrap();
        doc.command(json!({"op":"marks_undo"})).unwrap();
        doc.command(json!({"op":"marks_redo"})).unwrap();
        let reopened = fixture.open().command(json!({"op":"marks"})).unwrap();
        assert_eq!(reopened["bookmarks"][0]["title"], "Kept locally");
        assert_eq!(fs::read(&fixture.path).unwrap(), source);
    }

    #[test]
    fn signed_original_status_survives_derived_page_revisions() {
        let fixture = Fixture::new("signed-signature.pdf");
        let doc = fixture.open();
        assert_eq!(doc.info().unwrap()["signature_status"]["signed"], true);
        let copy = fixture.directory.join("signed-split.pdf");
        doc.command(json!({"op":"save_split","parts":[{"destination_path":copy,"pages":[0]}]}))
            .unwrap();
        assert_eq!(
            open_fixture_document(&copy, None).unwrap().info().unwrap()["signature_status"]["signed"],
            false
        );

        let original = fs::read(&fixture.path).unwrap();
        assert!(doc.command(json!({"op":"document_save"})).is_err());
        let unsigned = fixture.directory.join("signed-document-copy.pdf");
        doc.command(json!({"op":"save_document_copy","destination":unsigned}))
            .unwrap();
        assert_eq!(
            open_fixture_document(&unsigned, None)
                .unwrap()
                .info()
                .unwrap()["signature_status"]["signed"],
            false
        );
        let staged = doc
            .command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":0}}}))
            .unwrap();
        assert_eq!(staged["info"]["signature_status"]["signed"], true);
        assert!(doc.command(json!({"op":"page_apply"})).is_err());
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }
    #[test]
    #[ignore = "subprocess fixture used by the crash-recovery check"]
    fn write_editing_session_then_exit_without_running_destructors() {
        let path = PathBuf::from(std::env::var_os("LYRA_READER_TEST_RECOVERY_PATH").unwrap());
        let doc = open_fixture_document(&path, None).unwrap();
        doc.command(json!({"op":"bookmark_create","page":2,"title":"Recovered bookmark","yPt":20}))
            .unwrap();
        let created=doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":3,"color":"#E8BC5552","note":"Before exit"}})).unwrap();
        let id = created["selected_id"].as_str().unwrap();
        doc.command(json!({"op":"page_stage","operation":{"Move":{"pages":[2],"destination":0}},"current_page":2,"selected_pages":[0,2]})).unwrap();
        doc.command(json!({"op":"page_stage","operation":{"Delete":{"pages":[1]}},"current_page":1,"selected_pages":[1,2]})).unwrap();
        doc.command(json!({"op":"page_undo","current_page":0,"selected_pages":[0]}))
            .unwrap();
        doc.command(json!({"op":"mark_update","id":id,"patch":{"note":"Recovered after undo"}}))
            .unwrap();
        // A process exit deliberately skips Drop, like an interrupted desktop process.
        std::process::exit(0);
    }

    #[test]
    fn process_exit_restores_revision_marks_location_and_both_history_directions() {
        let fixture = Fixture::new("multipage.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "document::tests::write_editing_session_then_exit_without_running_destructors",
                "--ignored",
                "--nocapture",
            ])
            .env("LYRA_READER_TEST_RECOVERY_PATH", &fixture.path)
            .output()
            .unwrap();
        assert!(
            child.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&child.stdout),
            String::from_utf8_lossy(&child.stderr)
        );
        let manifest = cache_path(&fixture.path)
            .parent()
            .unwrap()
            .join("session.json");
        let cached = fs::read(&manifest).unwrap();
        let doc = fixture.open();
        assert!(doc.info().unwrap()["recovery"]["error"].is_null());
        assert_eq!(
            doc.info().unwrap()["recovery"]["location"],
            json!({"page":1,"selection":[1,2]})
        );
        let marks = doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(marks["annotations"][0]["page"], 1);
        assert_eq!(marks["annotations"][0]["note"], "Recovered after undo");
        assert_eq!(marks["bookmarks"][0]["page"], 0);
        assert_eq!(marks["can_page_redo"], true);
        assert_eq!(
            fs::read(&manifest).unwrap(),
            cached,
            "opening must not rewrite recovery data"
        );
        assert_eq!(
            doc.command(json!({"op":"page_redo"})).unwrap()["info"]["pages"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        let undone = doc.command(json!({"op":"page_undo"})).unwrap();
        assert_eq!(
            undone["marks"]["annotations"][0]["note"],
            "Recovered after undo"
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        doc.command(json!({"op":"page_discard"})).unwrap();
        assert!(!manifest.exists());
    }

    #[test]
    fn rotation_materializes_marks_atomically_and_undo_restores_the_cached_selection() {
        let fixture = Fixture::new("multipage.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let created=doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":3,"color":"#E8BC5552","note":"Rotate me"}})).unwrap();
        let id = created["selected_id"].clone();
        let before = fs::read(cache_path(&fixture.path)).unwrap();
        let rotated=doc.command(json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}},"current_page":0,"selected_pages":[0,2]})).unwrap();
        assert!(
            rotated["marks"]["annotations"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let file_marks = doc.command(json!({"op":"annotations"})).unwrap();
        assert_eq!(file_marks.as_array().unwrap().len(), 1);
        assert_eq!(file_marks[0]["contents"], "Rotate me");
        assert_eq!(doc.active().unwrap().page_rotations().unwrap()[0], 1);
        let copy = fixture.directory.join("rotated-marked.pdf");
        doc.command(json!({"op":"save_current_edited_copy","destination":copy}))
            .unwrap();
        let copied = open_fixture_document(&copy, None).unwrap();
        assert_eq!(
            copied
                .command(json!({"op":"annotations"}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        let undo = doc.command(json!({"op":"page_undo"})).unwrap();
        assert_eq!(undo["marks"]["annotations"][0]["id"], id);
        assert_eq!(
            undo["marks"]["page_location"],
            json!({"page":0,"selection":[0,2]})
        );
        assert!(!undo["marks"]["can_page_undo"].as_bool().unwrap());
        assert_eq!(doc.active().unwrap().page_rotations().unwrap()[0], 0);
        assert!(
            doc.command(json!({"op":"annotations"}))
                .unwrap()
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(fs::read(cache_path(&fixture.path)).unwrap(), before);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn leased_revisions_survive_undo_branches_and_retired_sessions_cannot_remove_new_recovery() {
        let fixture = Fixture::new("multipage.pdf");
        let doc = fixture.open();
        doc.command(json!({"op":"page_stage","operation":{"Delete":{"pages":[0]}}}))
            .unwrap();
        let revision = PathBuf::from(doc.active().unwrap().path());
        let bytes = fs::read(&revision).unwrap();
        let render = crate::render_source::RenderSource::new(&doc, false).unwrap();
        doc.command(json!({"op":"page_undo"})).unwrap();
        doc.command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":0}}}))
            .unwrap();
        assert_ne!(PathBuf::from(doc.active().unwrap().path()), revision);
        assert_eq!(fs::read(&revision).unwrap(), bytes);
        assert_eq!(
            render
                .query(json!({"op":"info"}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            2
        );
        let other = fixture.open();
        assert!(
            other.info().unwrap()["recovery"]["error"]
                .as_str()
                .unwrap()
                .contains("another window")
        );
        assert!(
            other
                .command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":0}}}))
                .is_err()
        );
        drop(other);
        doc.command(json!({"op":"page_discard"})).unwrap();
        assert!(revision.exists());
        let next = fixture.open();
        next.command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":1}}}))
            .unwrap();
        let manifest = cache_path(&fixture.path)
            .parent()
            .unwrap()
            .join("session.json");
        let next_bytes = fs::read(&manifest).unwrap();
        drop(render);
        assert!(!revision.exists());
        assert_eq!(fs::read(&manifest).unwrap(), next_bytes);
        next.command(json!({"op":"page_discard"})).unwrap();
    }

    #[test]
    fn recovery_rejects_missing_and_escaped_revisions_without_rewriting_the_manifest() {
        for mode in ["missing", "outside", "symlink"] {
            let fixture = Fixture::new("multipage.pdf");
            let original = fs::read(&fixture.path).unwrap();
            let doc = fixture.open();
            doc.command(json!({"op":"page_stage","operation":{"Delete":{"pages":[0]}}}))
                .unwrap();
            let revision = PathBuf::from(doc.active().unwrap().path());
            drop(doc);
            let manifest = cache_path(&fixture.path)
                .parent()
                .unwrap()
                .join("session.json");
            let mut value: Value = serde_json::from_slice(&fs::read(&manifest).unwrap()).unwrap();
            match mode {
                "missing" => fs::remove_file(&revision).unwrap(),
                "outside" => {
                    let outside = fixture.directory.join("external-revision.pdf");
                    fs::copy(&revision, &outside).unwrap();
                    let url =
                        lyra_reader_edit::transaction::path_file_url(&outside, false).unwrap();
                    value["session"]["revisionURL"] = json!(url);
                    value["snapshot"]["revisionURL"] = json!(url);
                    fs::write(&manifest, serde_json::to_vec(&value).unwrap()).unwrap();
                }
                _ => {
                    #[cfg(unix)]
                    {
                        let outside = fixture.directory.join("external-revision.pdf");
                        fs::copy(&revision, &outside).unwrap();
                        fs::remove_file(&revision).unwrap();
                        std::os::unix::fs::symlink(&outside, &revision).unwrap();
                    }
                    #[cfg(not(unix))]
                    {
                        continue;
                    }
                }
            }
            let bytes = fs::read(&manifest).unwrap();
            let reopened = fixture.open();
            assert!(
                reopened.info().unwrap()["recovery"]["error"].is_string(),
                "{mode}"
            );
            assert_eq!(
                reopened.info().unwrap()["pages"].as_array().unwrap().len(),
                3
            );
            assert!(reopened.command(json!({"op":"page_apply"})).is_err());
            assert_eq!(fs::read(&manifest).unwrap(), bytes);
            assert_eq!(fs::read(&fixture.path).unwrap(), original);
        }
    }

    #[test]
    fn changed_recovery_manifest_blocks_writes_without_losing_source_or_external_bytes() {
        let fixture = Fixture::new("multipage.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        doc.command(json!({"op":"page_stage","operation":{"Delete":{"pages":[0]}}}))
            .unwrap();
        let manifest = cache_path(&fixture.path)
            .parent()
            .unwrap()
            .join("session.json");
        let mut external = fs::read(&manifest).unwrap();
        external.extend_from_slice(b" \n");
        fs::write(&manifest, &external).unwrap();
        assert!(doc.command(json!({"op":"page_apply"})).is_err());
        assert!(doc.command(json!({"op":"page_discard"})).is_err());
        assert!(
            doc.command(json!({"op":"bookmark_create","page":0,"title":"Must fail","yPt":20}))
                .is_err()
        );
        assert_eq!(fs::read(&manifest).unwrap(), external);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        drop(doc);
        fs::write(&manifest, b"{unreadable").unwrap();
        let reopened = fixture.open();
        assert_eq!(
            reopened.info().unwrap()["pages"].as_array().unwrap().len(),
            3
        );
        assert!(reopened.info().unwrap()["recovery"]["error"].is_string());
        assert!(
            reopened
                .command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":0}}}))
                .is_err()
        );
        assert_eq!(fs::read(&manifest).unwrap(), b"{unreadable");
    }

    #[test]
    fn a_saved_pdf_is_reported_as_saved_when_its_projected_cache_cannot_be_published() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let engine = doc.active().unwrap();
        let destination = fixture.directory.join("saved-with-cache-warning.pdf");
        let original = crate::marks::Marks::load_with_root(
            &destination,
            1,
            Some(&fixture_cache_root(&fixture.path)),
        );
        let target = PathBuf::from(original.state(&engine).unwrap()["path"].as_str().unwrap());
        let marks = doc.marks.lock().unwrap();
        let (report, published, _) = marks
            .publish_page_revision(&original, || {
                let report = engine
                    .save_edited_copy(destination.to_string_lossy().into_owned())
                    .map_err(|e| e.to_string())?;
                // Simulate a post-PDF cache publication failure without a production failpoint.
                fs::create_dir(&target).map_err(|e| e.to_string())?;
                Ok(report)
            })
            .unwrap();
        assert_eq!(Path::new(&report.destination_path), destination);
        assert!(destination.exists());
        assert!(
            published
                .error
                .as_deref()
                .unwrap()
                .contains("PDF was saved")
        );
        assert_eq!(
            open_fixture_document(&destination, None)
                .unwrap()
                .info()
                .unwrap()["pages"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn dirty_baseline_survives_reopen_undo_and_last_embedded_bookmark_deletion() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        assert_eq!(
            doc.command(json!({"op":"marks"})).unwrap()["pdf_dirty"],
            false
        );
        doc.command(json!({"op":"bookmark_create","page":0,"title":"First","yPt":10}))
            .unwrap();
        assert_eq!(
            doc.command(json!({"op":"marks_undo"})).unwrap()["pdf_dirty"],
            false
        );
        assert_eq!(
            doc.command(json!({"op":"marks_redo"})).unwrap()["pdf_dirty"],
            true
        );
        doc.command(json!({"op":"bookmark_create","page":0,"title":"Second","yPt":20}))
            .unwrap();
        let saved = doc.command(json!({"op":"document_save"})).unwrap();
        assert_eq!(saved["marks"]["pdf_dirty"], false);
        let bookmarks = saved["marks"]["bookmarks"].as_array().unwrap();
        let moved = doc
            .command(json!({"op":"bookmark_move","id":bookmarks[1]["id"],"delta":-1}))
            .unwrap();
        assert_eq!(moved["pdf_dirty"], true);
        assert_eq!(
            doc.command(json!({"op":"marks_undo"})).unwrap()["pdf_dirty"],
            false
        );
        for bookmark in bookmarks {
            doc.command(json!({"op":"bookmark_delete","id":bookmark["id"]}))
                .unwrap();
        }
        assert_eq!(
            doc.command(json!({"op":"marks"})).unwrap()["pdf_dirty"],
            true
        );
        drop(doc);
        let reopened = fixture.open();
        let marks = reopened.command(json!({"op":"marks"})).unwrap();
        assert!(marks["bookmarks"].as_array().unwrap().is_empty());
        assert_eq!(marks["pdf_dirty"], true);
        reopened.command(json!({"op":"document_save"})).unwrap();
        assert!(
            reopened
                .command(json!({"op":"outline"}))
                .unwrap()
                .as_array()
                .unwrap()
                .iter()
                .all(|entry| entry["is_bookmark_subtree"] != true)
        );
        let marks = fixture.open().command(json!({"op":"marks"})).unwrap();
        assert_eq!(marks["pdf_dirty"], false);
        assert!(marks["bookmarks"].as_array().unwrap().is_empty());
    }

    #[test]
    fn discard_known_drafts_preserves_foreign_bytes_and_refuses_changed_pending_state() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let path = cache_path(&fixture.path);
        let foreign = r#"{ "kind":"future", "id":"9CD73B7D-7A3A-4FB0-814A-AF0211B7DDEF", "page":0, "raw":1.0000000000000001 }"#;
        fs::write(&path, format!("[{foreign}]\n")).unwrap();
        let doc = fixture.open();
        doc.command(json!({"op":"bookmark_create","page":0,"title":"Drop me","yPt":20}))
            .unwrap();
        let discarded = doc.command(json!({"op":"document_discard"})).unwrap();
        assert_eq!(discarded["info"]["pages"].as_array().unwrap().len(), 1);
        assert_eq!(discarded["marks"]["preserved"], 1);
        assert_eq!(discarded["marks"]["pdf_dirty"], false);
        assert!(
            discarded["marks"]["bookmarks"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert!(fs::read_to_string(&path).unwrap().contains(foreign));
        doc.command(json!({"op":"bookmark_create","page":0,"title":"Must remain","yPt":40}))
            .unwrap();
        let pending = path.parent().unwrap().join("changes.json");
        let mut external = fs::read(&pending).unwrap();
        external.extend_from_slice(b" \n");
        fs::write(&pending, &external).unwrap();
        let records = fs::read(&path).unwrap();
        assert!(doc.command(json!({"op":"document_discard"})).is_err());
        assert_eq!(fs::read(&path).unwrap(), records);
        assert_eq!(fs::read(&pending).unwrap(), external);
        assert_eq!(
            doc.command(json!({"op":"marks"})).unwrap()["bookmarks"][0]["title"],
            "Must remain"
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn discard_page_session_rolls_back_root_drafts_if_retiring_the_manifest_fails() {
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":3,"color":"#E8BC5552","note":"Keep on failure"}})).unwrap();
        doc.command(json!({"op":"bookmark_create","page":0,"title":"Keep bookmark","yPt":20}))
            .unwrap();
        let records = cache_path(&fixture.path);
        let pending = records.parent().unwrap().join("changes.json");
        let before_records = fs::read(&records).unwrap();
        let before_pending = fs::read(&pending).unwrap();
        doc.command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":0}}}))
            .unwrap();
        let manifest = records.parent().unwrap().join("session.json");
        let mut foreign = fs::read(&manifest).unwrap();
        foreign.push(b' ');
        fs::write(&manifest, &foreign).unwrap();
        assert!(doc.command(json!({"op":"document_discard"})).is_err());
        assert_eq!(fs::read(&records).unwrap(), before_records);
        assert_eq!(fs::read(&pending).unwrap(), before_pending);
        assert_eq!(fs::read(&manifest).unwrap(), foreign);
        assert_eq!(doc.info().unwrap()["pages"].as_array().unwrap().len(), 2);
        drop(doc);
        let restored = fixture.open();
        let discarded = restored.command(json!({"op":"document_discard"})).unwrap();
        assert_eq!(discarded["info"]["pages"].as_array().unwrap().len(), 1);
        assert!(
            discarded["marks"]["annotations"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert!(
            discarded["marks"]["bookmarks"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(discarded["marks"]["pdf_dirty"], false);
        assert!(!manifest.exists());
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn damaged_pending_state_keeps_readable_records_and_explicit_recovery_backs_up_both_files() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        doc.command(json!({"op":"bookmark_create","page":0,"title":"Readable draft","yPt":40}))
            .unwrap();
        drop(doc);
        let path = cache_path(&fixture.path);
        let records = fs::read(&path).unwrap();
        let pending = path.parent().unwrap().join("changes.json");
        fs::write(&pending, b"broken pending JSON").unwrap();
        let reopened = fixture.open();
        let marks = reopened.command(json!({"op":"marks"})).unwrap();
        assert!(marks["error"].is_string());
        assert_eq!(marks["bookmarks"][0]["title"], "Readable draft");
        assert!(reopened.command(json!({"op":"document_save"})).is_err());
        let recovered = reopened.command(json!({"op":"marks_recover"})).unwrap();
        assert_eq!(recovered["pdf_dirty"], false);
        assert!(recovered["bookmarks"].as_array().unwrap().is_empty());
        let backup = fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(Result::unwrap)
            .find(|e| {
                e.file_name()
                    .to_string_lossy()
                    .starts_with("discard-recovery-")
            })
            .unwrap()
            .path();
        assert_eq!(fs::read(backup.join("annotations.json")).unwrap(), records);
        assert_eq!(
            fs::read(backup.join("changes.json")).unwrap(),
            b"broken pending JSON"
        );
    }

    #[test]
    #[ignore = "subprocess fixture used by the pending ink recovery check"]
    fn write_pending_ink_then_exit_without_running_destructors() {
        let path = PathBuf::from(std::env::var_os("LYRA_READER_TEST_RECOVERY_PATH").unwrap());
        let doc = open_fixture_document(&path, None).unwrap();
        doc.command(json!({"op":"ink_erase_begin","token":"crash","page":0,"zoom":1,"segments":[{"from":{"x":250,"y":200},"to":{"x":250,"y":350}}]})).unwrap();
        let cut = doc
            .command(json!({"op":"ink_erase_commit","token":"crash","segments":[]}))
            .unwrap();
        assert_eq!(cut["annotations"].as_array().unwrap().len(), 2);
        assert_eq!(cut["pending_deletions"], 1);
        std::process::exit(0);
    }

    #[test]
    fn process_exit_restores_pending_ink_without_duplication_and_discard_restores_the_source() {
        let fixture = Fixture::new("annotated-ink-review.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "document::tests::write_pending_ink_then_exit_without_running_destructors",
                "--ignored",
                "--nocapture",
            ])
            .env("LYRA_READER_TEST_RECOVERY_PATH", &fixture.path)
            .output()
            .unwrap();
        assert!(
            child.status.success(),
            "{}",
            String::from_utf8_lossy(&child.stderr)
        );
        let doc = fixture.open();
        let marks = doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(marks["annotations"].as_array().unwrap().len(), 2);
        assert_eq!(marks["pending_deletions"], 1);
        assert!(
            !marks["file_annotations"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a["id"] == "nm:review-ink-bare")
        );
        doc.command(json!({"op":"document_discard"})).unwrap();
        let marks = fixture.open().command(json!({"op":"marks"})).unwrap();
        assert!(marks["annotations"].as_array().unwrap().is_empty());
        assert_eq!(marks["pending_deletions"], 0);
        assert_eq!(marks["file_annotations"].as_array().unwrap().len(), 4);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn unified_save_keeps_xfa_read_only_and_creates_no_editing_session() {
        let fixture = Fixture::new("xfa-refusal.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        assert_eq!(doc.info().unwrap()["xfa_status"]["is_xfa"], true);
        assert!(doc.command(json!({"op":"document_save"})).is_err());
        let copy = fixture.directory.join("xfa-copy.pdf");
        assert!(
            doc.command(json!({"op":"save_document_copy","destination":copy}))
                .is_err()
        );
        assert!(!copy.exists());
        assert!(
            !cache_path(&fixture.path)
                .parent()
                .unwrap()
                .join("session.json")
                .exists()
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn unified_save_combines_page_revisions_marks_bookmarks_and_forms_and_reopens_the_source() {
        let fixture = Fixture::new("form-fields.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let initial_revision = doc.info().unwrap()["revision"].clone();
        doc.command(json!({"op":"bookmark_create","page":0,"title":"Saved bookmark","yPt":40}))
            .unwrap();
        doc.command(json!({"op":"mark_create","entry":{"kind":"square","version":1,"page":0,"rect":{"x":20,"y":50,"width":80,"height":40},"strokeWidth":2,"color":"#E8BC5580","note":"Saved shape"}})).unwrap();
        doc.command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":0}}}))
            .unwrap();
        let stale = fixture.directory.join("stale-copy.pdf");
        assert!(doc.command(json!({"op":"save_document_copy","destination":stale,"expected_revision":initial_revision})).is_err());
        assert!(!stale.exists());
        let fields = doc.command(json!({"op":"forms"})).unwrap();
        let field = fields["fields"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f["kind"] == "text")
            .unwrap();
        let forms = json!([{"field_id":field["id"],"text":"Unified form value","checked":null,"selected":null}]);
        let copy = fixture.directory.join("combined.pdf");
        doc.command(json!({"op":"save_document_copy","destination":copy,"forms":forms}))
            .unwrap();
        let copy_doc = open_fixture_document(&copy, None).unwrap();
        assert_eq!(
            copy_doc.info().unwrap()["pages"].as_array().unwrap().len(),
            3
        );
        assert_eq!(
            copy_doc.command(json!({"op":"annotations"})).unwrap()[0]["contents"],
            "Saved shape"
        );
        assert_eq!(
            copy_doc.command(json!({"op":"marks"})).unwrap()["bookmarks"][0]["page"],
            1
        );
        assert!(
            copy_doc.command(json!({"op":"forms"})).unwrap()["fields"]
                .as_array()
                .unwrap()
                .iter()
                .any(|f| f["value"] == "Unified form value")
        );
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert_eq!(
            doc.command(json!({"op":"marks"})).unwrap()["annotations"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        let result = doc
            .command(json!({"op":"document_save","forms":forms}))
            .unwrap();
        assert_eq!(
            fs::read(result["report"]["backup_path"].as_str().unwrap()).unwrap(),
            original
        );
        assert_eq!(result["marks"]["page_session_active"], false);
        assert!(
            result["marks"]["annotations"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            doc.command(json!({"op":"annotations"})).unwrap()[0]["contents"],
            "Saved shape"
        );
        assert!(
            doc.command(json!({"op":"forms"})).unwrap()["fields"]
                .as_array()
                .unwrap()
                .iter()
                .any(|f| f["value"] == "Unified form value")
        );
        assert_eq!(
            fixture.open().info().unwrap()["pages"]
                .as_array()
                .unwrap()
                .len(),
            3
        );
        assert!(doc.command(json!({"op":"page_undo"})).is_err());
    }

    #[test]
    fn failed_unified_form_save_keeps_drafts_recovery_and_the_original_pdf() {
        let fixture = Fixture::new("form-fields.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        doc.command(json!({"op":"bookmark_create","page":0,"title":"Keep draft","yPt":40}))
            .unwrap();
        let failed=doc.command(json!({"op":"document_save","forms":[{"field_id":"absent-field","text":"invalid","checked":null,"selected":null}]}));
        assert!(failed.is_err());
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert_eq!(
            doc.command(json!({"op":"marks"})).unwrap()["bookmarks"][0]["title"],
            "Keep draft"
        );
        let manifest = cache_path(&fixture.path)
            .parent()
            .unwrap()
            .join("session.json");
        assert!(manifest.exists());
        let directory = manifest.parent().unwrap();
        assert!(!fs::read_dir(directory).unwrap().any(|e| {
            e.unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with("save-")
        }));
        drop(doc);
        let reopened = fixture.open();
        assert!(reopened.info().unwrap()["recovery"]["error"].is_null());
        assert_eq!(
            reopened.command(json!({"op":"marks"})).unwrap()["bookmarks"][0]["title"],
            "Keep draft"
        );
        reopened.command(json!({"op":"page_discard"})).unwrap();
    }

    #[test]
    fn page_sessions_remap_marks_undo_without_touching_original_and_apply_with_backups() {
        let fixture = Fixture::new("multipage.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        doc.command(json!({"op":"bookmark_create","page":2,"title":"Last page","yPt":20}))
            .unwrap();
        doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":3,"color":"#E8BC5552","note":"Move with this page"}})).unwrap();
        let sidecar = cache_path(&fixture.path);
        let sidecar_before = fs::read(&sidecar).unwrap();
        let moved = doc
            .command(json!({"op":"page_stage","operation":{"Move":{"pages":[2],"destination":0}}}))
            .unwrap();
        assert_eq!(moved["marks"]["annotations"][0]["page"], 1);
        assert_eq!(moved["marks"]["bookmarks"][0]["page"], 0);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
        assert_eq!(fs::read(&sidecar).unwrap(), sidecar_before);
        let deleted = doc
            .command(json!({"op":"page_stage","operation":{"Delete":{"pages":[1]}}}))
            .unwrap();
        assert_eq!(deleted["info"]["pages"].as_array().unwrap().len(), 2);
        assert!(
            deleted["marks"]["annotations"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let undo = doc.command(json!({"op":"page_undo"})).unwrap();
        assert_eq!(undo["marks"]["annotations"][0]["page"], 1);
        let undo = doc.command(json!({"op":"page_undo"})).unwrap();
        assert_eq!(undo["marks"]["annotations"][0]["page"], 0);
        assert!(!undo["marks"]["page_pending"].as_bool().unwrap());
        doc.command(json!({"op":"page_redo"})).unwrap();
        doc.command(json!({"op":"page_redo"})).unwrap();
        assert!(
            doc.command(json!({"op":"save_current_annotations","destination":fixture.path}))
                .is_err()
        );
        let copy = fixture.directory.join("edited-copy.pdf");
        doc.command(json!({"op":"save_current_edited_copy","destination":copy}))
            .unwrap();
        let copied = open_fixture_document(&copy, None).unwrap();
        assert_eq!(copied.info().unwrap()["pages"].as_array().unwrap().len(), 2);
        assert_eq!(
            copied.command(json!({"op":"marks"})).unwrap()["bookmarks"][0]["page"],
            0
        );
        let applied = doc.command(json!({"op":"page_apply"})).unwrap();
        assert_eq!(
            fs::read(applied["report"]["backup_path"].as_str().unwrap()).unwrap(),
            original
        );
        assert_eq!(
            fs::read(applied["report"]["sidecar_backup_path"].as_str().unwrap()).unwrap(),
            sidecar_before
        );
        let reopened = fixture.open();
        assert_eq!(
            reopened.info().unwrap()["pages"].as_array().unwrap().len(),
            2
        );
        assert_eq!(
            reopened.command(json!({"op":"marks"})).unwrap()["bookmarks"][0]["page"],
            0
        );
    }

    #[test]
    fn summary_catalog_is_local_paginated_and_reuses_outline_ranges() {
        let fixture = Fixture::new("index-past-120.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let before = doc.active().unwrap().text_page_cache_stats().loads;
        let page = doc
            .command(json!({"op":"ai_summary_catalog","request":{"layer":"Page","offset":0}}))
            .unwrap();
        assert_eq!(page["total"], 130);
        assert_eq!(
            page["rows"].as_array().unwrap().len(),
            ai_summary_limits().max_requests_per_batch as usize
        );
        assert_eq!(page["rows"][0]["id"], "page:1");
        assert_eq!(page["rows"][0]["link_page"], 0);
        let last = doc
            .command(json!({"op":"ai_summary_catalog","request":{"layer":"Page","offset":129}}))
            .unwrap();
        assert_eq!(last["rows"].as_array().unwrap().len(), 1);
        assert_eq!(last["rows"][0]["id"], "page:130");
        assert_eq!(last["rows"][0]["page_span"], "Page 130 of 130");
        assert!(last["next_offset"].is_null());
        let abstract_row = doc
            .command(json!({"op":"ai_summary_catalog","request":{"layer":"Abstract"}}))
            .unwrap();
        assert_eq!(abstract_row["total"], 1);
        assert!(abstract_row["rows"][0]["link_page"].is_null());
        let sections = doc
            .command(json!({"op":"ai_summary_catalog","request":{"layer":"Section"}}))
            .unwrap();
        assert_eq!(sections["total"], 13);
        assert_eq!(sections["rows"][0]["unit"]["page_end"], 10);
        assert_eq!(doc.active().unwrap().text_page_cache_stats().loads, before);
        assert!(doc.ai.lock().unwrap().is_none());
        assert_eq!(fs::read(&fixture.path).unwrap(), original);

        let outlined_fixture = Fixture::new("outlined.pdf");
        let outlined = outlined_fixture.open();
        let active = outlined.active().unwrap();
        let expected = ai_summary_sections(active.outline().unwrap(), active.page_count());
        let rows = outlined
            .command(json!({"op":"ai_summary_catalog","request":{"layer":"Section"}}))
            .unwrap();
        assert_eq!(rows["total"], expected.len());
        for (row, section) in rows["rows"].as_array().unwrap().iter().zip(expected) {
            assert_eq!(row["unit"]["title"], section.title);
            assert_eq!(row["unit"]["page_start"], section.page_start);
            assert_eq!(row["unit"]["page_end"], section.page_end);
            assert_eq!(row["link_page"], section.link_page);
        }
    }

    #[test]
    fn summary_inspection_keeps_shared_dual_end_coverage_without_requests_or_writes() {
        let fixture = Fixture::new("index-past-120.pdf");
        let before = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let coverage = doc
            .command(json!({"op":"ai_summary_inspect","request":{"layer":"Abstract","index":0}}))
            .unwrap();
        assert_eq!(coverage["id"], "abstract");
        let pages = coverage["fingerprint"]["pages"].as_array().unwrap();
        assert_eq!(pages.len(), 24);
        assert_eq!(pages[0], 1);
        assert_eq!(pages[11], 12);
        assert_eq!(pages[12], 119);
        assert_eq!(pages[23], 130);
        assert!(coverage["fingerprint"]["truncated"].as_bool().unwrap());
        assert_eq!(
            coverage["fingerprint"]["text_hash"].as_str().unwrap().len(),
            64
        );
        assert!(!coverage.to_string().contains("request_body"));
        assert!(!coverage.to_string().contains("messages"));
        assert!(doc.ai.lock().unwrap().is_none());
        assert_eq!(fs::read(&fixture.path).unwrap(), before);
    }

    #[test]
    fn summary_catalog_and_inspection_reject_invalid_units_before_text_extraction() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let loads = doc.active().unwrap().text_page_cache_stats().loads;
        for request in [
            json!({"op":"ai_summary_catalog","request":{"layer":"page"}}),
            json!({"op":"ai_summary_catalog","request":{"layer":"Page","offset":-1}}),
            json!({"op":"ai_summary_catalog","request":{"layer":"Page","offset":1}}),
            json!({"op":"ai_summary_catalog","request":{"layer":"Page","offset":2}}),
            json!({"op":"ai_summary_catalog","request":{"layer":"Page","limit":4294967295u32}}),
            json!({"op":"ai_summary_inspect","request":{"layer":"Abstract","index":1}}),
            json!({"op":"ai_summary_inspect","request":{"layer":"Page","index":1}}),
            json!({"op":"ai_summary_inspect","request":{"layer":"Page","index":-1}}),
            json!({"op":"ai_summary_inspect","request":{"layer":"Page","index":0,"page_end":999}}),
        ] {
            assert!(doc.command(request).is_err());
        }
        assert_eq!(doc.active().unwrap().text_page_cache_stats().loads, loads);
        assert!(doc.ai.lock().unwrap().is_none());
    }

    #[test]
    fn summary_empty_text_is_reported_without_a_plan_or_provider_configuration() {
        let fixture = Fixture::new("thin-lines.pdf");
        let doc = fixture.open();
        let coverage = doc
            .command(json!({"op":"ai_summary_inspect","request":{"layer":"Page","index":0}}))
            .unwrap();
        assert_eq!(coverage["id"], "page:1");
        assert_eq!(coverage["fingerprint"]["characters"], 0);
        assert!(coverage["fingerprint"]["note"].is_null());
        assert!(doc.ai.lock().unwrap().is_none());
    }
    fn summary_settings() -> Value {
        json!({"action":"SummarizeDocument","document_knowledge":false,"current_page":0,
            "selection":null,"question":"UNSENT_QUESTION","language":null,"history":[],"region":null,
            "base_url":"http://localhost:11434/v1","model":"synthetic-summary",
            "temperature":null,"max_tokens":null,"reasoning_mode":"default","reasoning_encoding":"none",
            "document_knowledge_text":"UNVERIFIED_PARTIAL_CONTEXT","document_knowledge_pages":[1]})
    }

    #[test]
    fn chatgpt_native_actions_and_notes_keep_the_reviewed_account_and_wire() {
        use lyra_reader_ai::region_history::{AnswerState, History, Turn};
        let fixture = Fixture::new("text-page.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let mut request = summary_settings();
        request["chatgpt_account"] = json!("synthetic-unified");
        request["question"] = json!("What does LyraReader fixture say?");
        for action in ["SummarizePage", "AskSelection"] {
            request["action"] = json!(action);
            request["selection"] = if action == "AskSelection" {
                json!({"page":0,"start":0,"end":17})
            } else {
                Value::Null
            };
            let plan = doc
                .command(json!({"op":"ai_preview","request":request}))
                .unwrap();
            assert_eq!(plan["chatgpt_account"], "synthetic-unified");
            assert_eq!(
                plan["endpoint"],
                lyra_reader_ai::openai::CHATGPT_RESPONSES_ENDPOINT
            );
            assert!(
                doc.command(json!({"op":"ai_start","plan":plan,"api_key":"unused"}))
                    .unwrap_err()
                    .contains("connection changed")
            );
        }
        let id = saved_region(&doc);
        doc.command(json!({"op":"region_note","id":id,"text":"Original manually saved ideas"}))
            .unwrap();
        let revision = doc.command(json!({"op":"region_list"})).unwrap()["revision"].clone();
        let note = doc
            .command(
                json!({"op":"ai_reading_keep_region","id":id,"expected_history_revision":revision}),
            )
            .unwrap();
        let path = region_path(&fixture.path);
        drop(doc);
        let mut history = History::decode(&fs::read(&path).unwrap()).unwrap();
        let mut region = history.get(&id).unwrap().clone();
        region.turns.push(Turn {
            id: crate::marks::uuid().unwrap(),
            question: "SYNTHETIC_NOTE_QUESTION".into(),
            answer: "SYNTHETIC_NOTE_ANSWER".into(),
            state: AnswerState::Finished,
            error: None,
            created_at: 0.0,
            source_pages: Some(vec![1]),
        });
        history.put(region).unwrap();
        fs::write(&path, history.encode().unwrap()).unwrap();
        let stored = fs::read(&path).unwrap();
        let doc = fixture.open();
        let revision = doc.command(json!({"op":"region_list"})).unwrap()["revision"].clone();
        request["action"] = json!("SummarizeDocument");
        request["selection"] = Value::Null;
        for (kind, target) in [("region_note", json!(id)), ("note", note["id"].clone())] {
            let plan=doc.command(json!({"op":"ai_preview","request":request,"reading":{"kind":kind,"detail":"Standard","id":target,"expected_history_revision":revision}})).unwrap();
            assert_eq!(plan["chatgpt_account"], "synthetic-unified");
            assert_eq!(
                plan["endpoint"],
                lyra_reader_ai::openai::CHATGPT_RESPONSES_ENDPOINT
            );
            for part in plan["parts"].as_array().unwrap() {
                let body = part["wire_body"].as_str().unwrap();
                let wire: Value = serde_json::from_str(body).unwrap();
                assert_eq!(wire["stream"], true);
                assert_eq!(wire["store"], false);
                assert!(
                    body.contains("SYNTHETIC_NOTE_QUESTION")
                        && body.contains("SYNTHETIC_NOTE_ANSWER")
                );
            }
            let capture = doc.pending_note.lock().unwrap();
            let capture = capture.as_ref().unwrap();
            let record: AiPlanRecord = serde_json::from_value(plan.clone()).unwrap();
            assert!(capture.matches(
                plan["note_capture"].as_str().unwrap(),
                plan["kind"].as_str().unwrap(),
                &record,
                &doc.active().unwrap().document_identity().sha256,
                Some("synthetic-unified")
            ));
            assert!(!capture.matches(
                plan["note_capture"].as_str().unwrap(),
                plan["kind"].as_str().unwrap(),
                &record,
                &doc.active().unwrap().document_identity().sha256,
                Some("another-account")
            ));
            assert!(doc.ai.lock().unwrap().is_none());
        }
        assert_eq!(fs::read(path).unwrap(), stored);
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn chatgpt_whole_document_review_keeps_synthesis_bound_to_the_reviewed_account() {
        let fixture = Fixture::new("multipage.pdf");
        let doc = fixture.open();
        let account = "whole-document-connection";
        let mut request = summary_settings();
        request["chatgpt_account"] = json!(account);
        let summary = doc
            .command(json!({"op":"ai_preview","request":request,
            "reading":{"kind":"summary","detail":"Detailed","force":true}}))
            .unwrap();
        let translation = doc
            .command(json!({"op":"ai_preview","request":request,
            "reading":{"kind":"translation","detail":"Standard"}}))
            .unwrap();
        assert_eq!(summary["kind"], "reading_summary");
        assert_eq!(translation["kind"], "reading_translation");
        assert_eq!(translation["action"], "TranslateSelection");
        assert!(translation["reading_scope"]["selection"].is_null());
        for preview in [&summary, &translation] {
            assert_eq!(preview["chatgpt_account"], account);
            assert_eq!(
                preview["endpoint"],
                lyra_reader_ai::openai::CHATGPT_RESPONSES_ENDPOINT
            );
            assert_eq!(preview["source_pages"], json!([1, 2, 3]));
            for part in preview["parts"].as_array().unwrap() {
                let body = part["wire_body"].as_str().unwrap();
                let wire: Value = serde_json::from_str(body).unwrap();
                assert_eq!(wire["store"], false);
                assert!(wire["input"].is_array());
                assert!(!body.contains("UNVERIFIED_PARTIAL_CONTEXT"));
            }
        }

        let first_stage: AiPlanRecord = serde_json::from_value(summary).unwrap();
        let fingerprint = doc.engine.read().unwrap().document_identity().sha256;
        let capture = Arc::new(
            SummaryCapture::new(
                &first_stage,
                fingerprint,
                String::new(),
                "Detailed".into(),
                None,
            )
            .unwrap(),
        );
        let style = ReadingSummaryStyle {
            detail: "Detailed".into(),
            language: String::new(),
            reasoning_mode: "default".into(),
            reasoning_encoding: "none".into(),
        };
        let merge = consolidation_request(
            &first_stage,
            style.reasoning_mode.clone(),
            style.reasoning_encoding.clone(),
        )
        .unwrap();
        let count = merge.parts.len();
        let mut replies = ReadingReplies::new(
            ReadingOutput::Synthesis {
                request: Box::new(merge),
                style,
                capture,
                account: Some(account.into()),
            },
            count,
        );
        replies.replies = vec!["Reviewed synthetic partial answer.".into(); count];
        replies.done = true;
        let mut result = json!({});
        let Some(ReadingArchive::PendingSummary(pending)) = replies.publish(&mut result) else {
            panic!("Missing synthesis preview: {result}");
        };
        let synthesis = &result["synthesis_plan"];
        assert_eq!(synthesis["kind"], "summary_synthesis");
        assert_eq!(synthesis["chatgpt_account"], account);
        assert_eq!(
            synthesis["endpoint"],
            lyra_reader_ai::openai::CHATGPT_RESPONSES_ENDPOINT
        );
        assert_ne!(synthesis["summary_capture"], Value::Null);
        let body = synthesis["parts"][0]["wire_body"].as_str().unwrap();
        assert!(body.contains("Reviewed synthetic partial answer."));
        assert!(body.contains("Consolidate the part summaries"));
        assert!(!body.contains("UNSENT_QUESTION"));
        assert_eq!(serde_json::from_str::<Value>(body).unwrap()["store"], false);
        *doc.pending_summary.lock().unwrap() = Some(pending);

        let mut wrong = synthesis.clone();
        wrong["chatgpt_account"] = json!("another-account");
        assert!(
            doc.command(json!({"op":"ai_start","plan":wrong,
            "chatgpt_account":"another-account"}))
                .unwrap_err()
                .contains("synthesis request changed")
        );
        let mut modified = synthesis.clone();
        modified["parts"][0]["wire_body"] = json!(format!("{body} "));
        assert!(
            doc.command(json!({"op":"ai_start","plan":modified,
            "chatgpt_account":account}))
                .unwrap_err()
                .contains("synthesis request changed")
        );
        let mut fallback = synthesis.clone();
        fallback.as_object_mut().unwrap().remove("chatgpt_account");
        assert!(
            doc.command(json!({"op":"ai_start","plan":fallback}))
                .unwrap_err()
                .contains("synthesis request changed")
        );
        assert!(doc.ai.lock().unwrap().is_none());
    }

    #[test]
    fn summary_batch_previews_keep_independent_canonical_bodies_without_starting_requests() {
        let fixture = Fixture::new("multipage.pdf");
        let before = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        let mut expected = Vec::new();
        for index in 0..3 {
            let unit = doc.command(json!({"op":"ai_summary_prepare","unit":{"layer":"Page","index":index},"request":summary_settings()})).unwrap();
            expected.push(unit["plan"]["parts"][0]["wire_body"].clone());
        }
        let batch = doc.command(json!({"op":"ai_summary_batch_prepare","batch":{"layer":"Page","offset":0},"request":summary_settings()})).unwrap();
        assert_eq!(batch["plan"]["kind"], "summary_batch");
        assert!(
            batch["plan"]["token"]
                .as_str()
                .is_some_and(|token| !token.is_empty())
        );
        assert_eq!(batch["rows"].as_array().unwrap().len(), 3);
        assert_eq!(batch["plan"]["parts"].as_array().unwrap().len(), 3);
        for (index, body) in expected.into_iter().enumerate() {
            assert_eq!(
                batch["plan"]["summary_rows"][index]["id"],
                format!("page:{}", index + 1)
            );
            assert_eq!(batch["plan"]["summary_rows"][index]["part_index"], index);
            assert_eq!(batch["plan"]["parts"][index]["wire_body"], body);
        }
        assert!(doc.ai.lock().unwrap().is_none());
        assert_eq!(fs::read(&fixture.path).unwrap(), before);
    }

    #[test]
    fn chatgpt_summary_units_and_batch_use_the_same_reviewed_bodies() {
        let fixture = Fixture::new("multipage.pdf");
        let doc = fixture.open();
        let mut request = summary_settings();
        request["chatgpt_account"] = json!("synthetic-layered-connection");
        let mut expected = Vec::new();
        for index in 0..3 {
            let unit = doc.command(json!({"op":"ai_summary_prepare","unit":{"layer":"Page","index":index},"request":request})).unwrap();
            assert_eq!(
                unit["plan"]["chatgpt_account"],
                "synthetic-layered-connection"
            );
            assert_eq!(
                unit["plan"]["endpoint"],
                lyra_reader_ai::openai::CHATGPT_RESPONSES_ENDPOINT
            );
            expected.push(unit["plan"]["parts"][0]["wire_body"].clone());
        }
        let batch = doc.command(json!({"op":"ai_summary_batch_prepare","batch":{"layer":"Page","offset":0},"request":request})).unwrap();
        assert_eq!(
            batch["plan"]["chatgpt_account"],
            "synthetic-layered-connection"
        );
        for (index, body) in expected.into_iter().enumerate() {
            assert_eq!(batch["plan"]["parts"][index]["wire_body"], body);
            let wire: Value = serde_json::from_str(body.as_str().unwrap()).unwrap();
            assert_eq!(wire["store"], false);
            assert!(wire["input"].is_array());
        }
        let token = &batch["plan"]["token"];
        let other = json!({"op":"ai_summary_batch_start","token":token,
            "chatgpt_account":"another-connection","chatgpt_access_token":"synthetic-token"});
        assert!(
            doc.command(other)
                .unwrap_err()
                .contains("connection changed")
        );
        assert!(
            doc.command(json!({"op":"ai_summary_batch_start","token":token,"api_key":"synthetic"}))
                .is_err()
        );
        assert!(!doc.summary_batch.lock().unwrap().is_running());
        assert!(doc.ai.lock().unwrap().is_none());
    }
    #[test]
    fn summary_batch_admission_cancel_rejects_a_prepared_start_and_allows_a_new_preview() {
        let fixture = Fixture::new("multipage.pdf");
        let doc = fixture.open();
        let request = json!({"op":"ai_summary_batch_prepare","batch":{"layer":"Page","offset":0},"request":summary_settings()});
        let old = doc.command(request.clone()).unwrap();
        doc.request_summary_cancel();
        assert!(doc.command(json!({"op":"ai_summary_batch_start","token":old["plan"]["token"],"api_key":"synthetic"})).is_err());
        assert!(!doc.summary_batch.lock().unwrap().is_running());
        let fresh = doc.command(request).unwrap();
        assert_ne!(old["plan"]["token"], fresh["plan"]["token"]);
        assert!(doc.command(json!({"op":"ai_summary_batch_start","token":old["plan"]["token"],"api_key":"synthetic"})).is_err());
        assert!(doc.ai.lock().unwrap().is_none());
    }

    #[test]
    fn summary_unit_previews_render_shared_page_section_and_dual_end_bodies_locally() {
        let fixture = Fixture::new("index-past-120.pdf");
        let before = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        for (layer, index, action, expected_id) in [
            ("Abstract", 0, "SummarizeAbstract", "abstract"),
            ("Section", 0, "SummarizeSection", "section:0"),
            ("Page", 24, "SummarizePageLine", "page:25"),
        ] {
            let preview=doc.command(json!({"op":"ai_summary_prepare","unit":{"layer":layer,"index":index},"request":summary_settings()})).unwrap();
            assert_eq!(preview["id"], expected_id);
            let plan = &preview["plan"];
            assert_eq!(plan["action"], action);
            assert_eq!(plan["parts"].as_array().unwrap().len(), 1);
            let body = plan["parts"][0]["wire_body"].as_str().unwrap();
            assert!(serde_json::from_str::<Value>(body).is_ok());
            assert!(!body.contains("UNSENT_QUESTION"));
            assert!(!body.contains("UNVERIFIED_PARTIAL_CONTEXT"));
            let pages = plan["source_pages"].as_array().unwrap();
            if layer == "Abstract" {
                assert_eq!(pages.len(), 24);
                assert_eq!(pages[12], 119);
                assert_eq!(pages[23], 130);
            }
            if layer == "Page" {
                assert_eq!(pages, &vec![json!(25)]);
                assert_eq!(preview["page_span"], "Page 25 of 130");
            }
            assert!(doc.ai.lock().unwrap().is_none());
        }
        assert_eq!(fs::read(&fixture.path).unwrap(), before);
    }

    #[test]
    fn summary_unit_previews_reject_bad_rows_empty_text_and_bad_provider_without_sending() {
        let fixture = Fixture::new("thin-lines.pdf");
        let doc = fixture.open();
        for unit in [
            json!({"layer":"Page","index":1}),
            json!({"layer":"Page","index":0,"page_end":2}),
            json!({"layer":"Abstract","index":1}),
        ] {
            assert!(
                doc.command(
                    json!({"op":"ai_summary_prepare","unit":unit,"request":summary_settings()})
                )
                .is_err()
            );
        }
        let empty=doc.command(json!({"op":"ai_summary_prepare","unit":{"layer":"Page","index":0},"request":summary_settings()}));
        assert!(empty.is_err());
        assert!(doc.ai.lock().unwrap().is_none());
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        let mut bad = summary_settings();
        bad["base_url"] = json!("not-a-url");
        assert!(
            doc.command(
                json!({"op":"ai_summary_prepare","unit":{"layer":"Page","index":0},"request":bad})
            )
            .is_err()
        );
        assert!(doc.ai.lock().unwrap().is_none());
    }
}

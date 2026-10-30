//! Desktop transport over the same portable Rust control plane the macOS shell uses.
//! JSON only crosses the narrow C boundary; requests are decoded into typed engine records.
use lyra_reader_core::Size;
use lyra_reader_ffi::api::*;
use lyra_reader_runtime::{MAX_PAGE_BYTES, PAGE_GAP_PT, bounded_raster_scale};
use lyra_reader_session::{DocumentLayout, LayoutMode};
use serde::{Serialize, de::DeserializeOwned};
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
    ai: Mutex<Option<Arc<LyraReaderAiRequest>>>,
    pub(super) marks: Mutex<crate::marks::Marks>,
    pub(super) edits: Mutex<crate::pages::PageEdits>,
    pub(super) original_path: PathBuf,
    pub(super) recovery_status: Mutex<Value>,
    pub(super) password: Option<String>,
}

fn value<T: Serialize>(result: Result<T, LyraReaderFfiError>) -> Result<Value, String> {
    serde_json::to_value(result.map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}
fn arg<T: DeserializeOwned>(request: &Value, key: &str) -> Result<T, String> {
    serde_json::from_value(request.get(key).cloned().unwrap_or(Value::Null))
        .map_err(|e| format!("Invalid {key}: {e}"))
}
fn text(request: &Value, key: &str) -> Result<String, String> {
    arg(request, key)
}

pub(super) fn layout_value(source_layout: &DocumentLayout, r: &Value) -> Result<Value, String> {
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
    Ok(json!({"pages": layout.placements().iter().map(|p|json!({
        "index":p.index,"top":p.top_pt,"left":p.left_pt,"width":p.width_pt,"height":p.height_pt
    })).collect::<Vec<_>>(), "width":layout.content_width_pt(),"height":layout.content_height_pt(),"gap":gap}))
}

impl DesktopDocument {
    pub fn open(path: &Path, password: Option<&str>) -> Result<Self, String> {
        Self::open_with_cache_root(path, password, None)
    }
    fn open_with_cache_root(
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
        let document = Self {
            original_signature: engine.signature_status(),
            original_xfa: engine.xfa_status(),
            engine: RwLock::new(engine),
            layout: RwLock::new(DocumentLayout::new(sizes, PAGE_GAP_PT)),
            edits: Mutex::new(crate::pages::PageEdits::default()),
            original_path: path.to_path_buf(),
            recovery_status: Mutex::new(Value::Null),
            password: password.map(str::to_owned),
            ai: Mutex::new(None),
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
        let layout = self
            .layout
            .read()
            .map_err(|_| "Layout state is unavailable")?;
        Ok(json!({
            "pages":layout.placements().iter().map(|p|json!({"index":p.index,"width":p.width_pt,"height":p.height_pt,"top":p.top_pt,"left":p.left_pt})).collect::<Vec<_>>(),
            "width":layout.content_width_pt(),"height":layout.content_height_pt(),"gap":layout.gap_pt(),"path":self.original_path,"revision":self.active()?.path(),"signature_status":self.source_signature(&current),"xfa_status":self.source_xfa(&current),"annotation_rules":annotation_rules(),"ai_history_limit":ai_chat_history_limit(),"recovery":self.recovery_status.lock().map_err(|_|"Recovery state is unavailable")?.clone(),
        }))
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
                report["cache_cleanup_error"] = json!(published.error);
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
                value(d.resolve_citations_on(arg(&r, "page")?, arg(&r, "labels")?))
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
            "ai_preview" => value(
                d.prepare_ai_plan(arg(&r, "request")?)
                    .and_then(|plan| render_ai_plan(plan, AiWireTransport::ChatCompletions)),
            ),
            "ai_merge_preview" => value(
                build_ai_merge_plan(arg(&r, "request")?)
                    .and_then(|plan| render_ai_plan(plan, AiWireTransport::ChatCompletions)),
            ),
            "ai_endpoint" => value(inspect_ai_base_url(text(&r, "base_url")?)),
            "ai_start" => {
                let request = start_ai_request(arg(&r, "plan")?, text(&r, "api_key")?, false)
                    .map_err(|e| e.to_string())?;
                let mut current = self.ai.lock().map_err(|_| "AI state is unavailable")?;
                if let Some(old) = current.replace(request) {
                    old.cancel();
                }
                Ok(Value::Bool(true))
            }
            "ai_poll" => {
                let current = self.ai.lock().map_err(|_| "AI state is unavailable")?;
                if let Some(job) = current.as_ref() {
                    Ok(json!({"events":job.poll(),"finished":job.is_finished()}))
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
                    job.cancel();
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
    fn annotation_cache_uses_document_id_and_ignores_both_adjacent_formats() {
        let fixture = Fixture::new("text-page.pdf");
        let modern = format!("{}.lyra-reader-annotations.json", fixture.path.display());
        let legacy = format!("{}.aris-annotations.json", fixture.path.display());
        fs::write(&modern, b"deliberately unreadable adjacent file").unwrap();
        fs::write(&legacy, b"[]").unwrap();
        let doc = fixture.open();
        let state = doc.command(json!({"op":"marks"})).unwrap();
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
        let outline = doc.command(json!({"op":"outline"})).unwrap();
        assert!(!outline.as_array().unwrap().is_empty());
        let layout = doc
            .command(json!({"op":"layout","mode":"Facing","gap":18}))
            .unwrap();
        assert_eq!(layout["pages"][1]["top"], layout["pages"][2]["top"]);
        assert_ne!(layout["pages"][1]["left"], layout["pages"][2]["left"]);
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
}

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
    original_signature: SignatureStatusRecord,
    ai: Mutex<Option<Arc<LyraReaderAiRequest>>>,
    pub(super) marks: Mutex<crate::marks::Marks>,
    pub(super) edits: Mutex<crate::pages::PageEdits>,
    pub(super) original_path: PathBuf,
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

impl DesktopDocument {
    pub fn open(path: &Path, password: Option<&str>) -> Result<Self, String> {
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
        let mut mark_state = crate::marks::Marks::load(path, engine.page_count());
        if let Err(error) = mark_state.seed_bookmarks(&engine) {
            mark_state.error = Some(error);
        }
        let marks = Mutex::new(mark_state);
        Ok(Self {
            original_signature: engine.signature_status(),
            engine: RwLock::new(engine),
            layout: RwLock::new(DocumentLayout::new(sizes, PAGE_GAP_PT)),
            edits: Mutex::new(crate::pages::PageEdits::default()),
            original_path: path.to_path_buf(),
            password: password.map(str::to_owned),
            ai: Mutex::new(None),
            marks,
        })
    }

    pub(super) fn active(&self) -> Result<Arc<LyraReaderDocument>, String> {
        self.engine
            .read()
            .map(|d| Arc::clone(&d))
            .map_err(|_| "Document state is unavailable".into())
    }
    pub fn info(&self) -> Result<Value, String> {
        let layout = self
            .layout
            .read()
            .map_err(|_| "Layout state is unavailable")?;
        Ok(json!({
            "pages":layout.placements().iter().map(|p|json!({"index":p.index,"width":p.width_pt,"height":p.height_pt,"top":p.top_pt,"left":p.left_pt})).collect::<Vec<_>>(),
            "width":layout.content_width_pt(),"height":layout.content_height_pt(),"gap":layout.gap_pt(),"path":self.original_path,"signature_status":self.original_signature,
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
        if matches!(op, "save_merge" | "save_split" | "split_plan") {
            return self.export_command(op, &r);
        }
        if let Some(destination) = r.get("destination").and_then(Value::as_str) {
            if op.starts_with("save_")
                && [
                    format!("{destination}.lyra-reader-annotations.json"),
                    format!("{destination}.aris-annotations.json"),
                ]
                .iter()
                .any(|p| Path::new(p).exists())
            {
                return Err("The destination has an annotation sidecar. Choose another name so the existing marks are preserved.".into());
            }
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
            "page_stage" | "page_undo" | "page_redo" | "page_discard" | "page_apply"
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
        if op.starts_with("replace_") && d.path() != self.original_path.to_string_lossy() {
            return Err(
                "Apply or discard the staged page changes before replacing the original PDF".into(),
            );
        }
        if matches!(
            op,
            "marks"
                | "mark_create"
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
            let mut edits = self
                .edits
                .lock()
                .map_err(|_| "Page-edit state is unavailable")?;
            let mut marks = self
                .marks
                .lock()
                .map_err(|_| "Annotation state is unavailable")?;
            let active = self.active()?;
            let state = marks.command(op, &r, &active)?;
            if !matches!(op, "marks" | "marks_undo" | "marks_redo")
                && (op != "ink_erase_commit" || state["erase_changed"].as_u64().unwrap_or(0) > 0)
            {
                edits.clear_redo();
                edits.collect_garbage(Path::new(&active.path()));
            }
            return Ok(edits.annotate_state(state, &active, &self.original_path));
        }
        match op {
            "save_current_edited_copy" => {
                let marks = self
                    .marks
                    .lock()
                    .map_err(|_| "Annotation state is unavailable")?;
                let destination = text(&r, "destination")?;
                let original = crate::marks::Marks::load(Path::new(&destination), d.page_count());
                let sidecar = PathBuf::from(format!("{destination}.lyra-reader-annotations.json"));
                if sidecar.exists() {
                    return Err("The destination already has an annotation sidecar. Choose another name so its marks are preserved.".into());
                }
                let (report, _, _) = marks.publish_page_revision(&original, || {
                    d.save_edited_copy(destination).map_err(|e| e.to_string())
                })?;
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
                        1.0,
                    )
                } else {
                    d.replace_with_annotation_changes(
                        payload.annotations,
                        payload.bookmarks,
                        payload.updates,
                        payload.deletions,
                        1.0,
                    )
                }
                .map_err(|e| e.to_string())?;
                let cleanup = if op == "replace_current_annotations" {
                    marks.clear_saved(&payload.ids).err()
                } else {
                    None
                };
                let mut result = serde_json::to_value(report).map_err(|e| e.to_string())?;
                result["sidecar_cleanup_error"] = json!(cleanup);
                Ok(result)
            }
            "info" => self.info(),
            "outline" => value(d.outline()),
            "metadata" => value(d.metadata()),
            "signature_status" => {
                serde_json::to_value(&self.original_signature).map_err(|e| e.to_string())
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
                let source_layout = self
                    .layout
                    .read()
                    .map_err(|_| "Layout state is unavailable")?;
                let sizes = source_layout
                    .placements()
                    .iter()
                    .map(|p| (p.width_pt, p.height_pt));
                let layout = DocumentLayout::new_with_mode(sizes, gap, mode);
                Ok(json!({"pages": layout.placements().iter().map(|p|json!({
                    "index":p.index,"top":p.top_pt,"left":p.left_pt,"width":p.width_pt,"height":p.height_pt
                })).collect::<Vec<_>>(), "width":layout.content_width_pt(),"height":layout.content_height_pt(),"gap":gap}))
            }
            "bibtex" => Ok(Value::String(generate_bibtex_entry(arg(&r, "draft")?))),
            "font_coverage" => value(appearance_font_coverage(text(&r, "text")?)),
            "save_annotations" => value(d.save_annotation_changes_copy(
                text(&r, "destination")?,
                arg(&r, "annotations")?,
                arg(&r, "bookmarks")?,
                arg(&r, "updates")?,
                arg(&r, "deletions")?,
                1.0,
            )),
            "replace_annotations" => value(d.replace_with_annotation_changes(
                arg(&r, "annotations")?,
                arg(&r, "bookmarks")?,
                arg(&r, "updates")?,
                arg(&r, "deletions")?,
                1.0,
            )),
            "save_forms" => {
                value(d.save_filled_form_copy(text(&r, "destination")?, arg(&r, "values")?))
            }
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
            "preview_redactions" => value(d.preview_redactions(arg(&r, "areas")?)),
            "save_redactions" => {
                value(d.redact_to_copy(text(&r, "destination")?, arg(&r, "areas")?))
            }
            "replace_redactions" => value(d.replace_with_redactions(arg(&r, "areas")?)),
            "ai_preview" => value(d.prepare_ai_plan(arg(&r, "request")?)),
            "ai_merge_preview" => value(build_ai_merge_plan(arg(&r, "request")?)),
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
            DesktopDocument::open(&self.path, None).unwrap()
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
        let sidecar = format!("{}.lyra-reader-annotations.json", fixture.path.display());
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
        let saved = DesktopDocument::open(&output, None)
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
        let doc = fixture.open();
        doc.command(json!({"op":"file_adopt","id":"nm:review-ink-bare"}))
            .unwrap();
        let sidecar = format!("{}.lyra-reader-annotations.json", fixture.path.display());
        let before = fs::read(&sidecar).unwrap();
        let original = doc.command(json!({"op":"marks"})).unwrap()["annotations"].clone();
        doc.command(json!({"op":"ink_erase_begin","token":"cut","page":0,"zoom":1,"segments":[{"from":{"x":250,"y":200},"to":{"x":250,"y":350}}]})).unwrap();
        let cut = doc
            .command(json!({"op":"ink_erase_commit","token":"cut","segments":[]}))
            .unwrap();
        assert_eq!(cut["erase_requires_pdf_save"], true);
        assert_eq!(cut["annotations"].as_array().unwrap().len(), 2);
        assert_eq!(fs::read(&sidecar).unwrap(), before);
        let reopened = fixture.open().command(json!({"op":"marks"})).unwrap();
        assert_eq!(reopened["annotations"], original);
        assert_eq!(reopened["pending_deletions"], 0);
        // Cutting an already staged piece must keep its descendants staged too.
        doc.command(json!({"op":"ink_erase_begin","token":"again","page":0,"zoom":1,"segments":[{"from":{"x":150,"y":200},"to":{"x":150,"y":350}}]})).unwrap();
        let again = doc
            .command(json!({"op":"ink_erase_commit","token":"again","segments":[]}))
            .unwrap();
        assert_eq!(again["erase_requires_pdf_save"], true);
        assert_eq!(again["annotations"].as_array().unwrap().len(), 3);
        assert_eq!(fs::read(&sidecar).unwrap(), before);
        let undo = doc.command(json!({"op":"marks_undo"})).unwrap();
        assert_eq!(undo["annotations"], cut["annotations"]);
        doc.command(json!({"op":"marks_redo"})).unwrap();
        assert_eq!(fs::read(&sidecar).unwrap(), before);
        // Ordinary sidecar annotations made after the cut must still persist.
        let created=doc.command(json!({"op":"mark_create","entry":{"kind":"square","page":0,"version":1,"rect":{"x":10,"y":10,"width":20,"height":20},"strokeWidth":2,"color":"#000000FF","note":"keep square"}})).unwrap();
        assert_eq!(created["annotations"].as_array().unwrap().len(), 4);
        let reopened = fixture.open().command(json!({"op":"marks"})).unwrap();
        assert_eq!(reopened["annotations"].as_array().unwrap().len(), 2);
        assert_eq!(reopened["annotations"][0], original[0]);
        assert_eq!(reopened["annotations"][1]["kind"], "square");
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
        let copy_doc = DesktopDocument::open(&copy, None).unwrap();
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
        let reopened = DesktopDocument::open(&second, None)
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
        let sidecar = format!("{}.lyra-reader-annotations.json", fixture.path.display());
        let before = fs::read(&sidecar).unwrap();
        assert!(doc.command(json!({"op":"mark_create","entry":{"kind":"signature","page":0,"version":1,"color":"#000000FF","note":"","image":"invalid","rect":{"x":10,"y":10,"width":10,"height":10}}})).is_err());
        assert_eq!(before, fs::read(&sidecar).unwrap());
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
        let filled = DesktopDocument::open(&copy, None)
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
        let info = DesktopDocument::open(&properties, None)
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
        let sidecar = PathBuf::from(format!(
            "{}.lyra-reader-annotations.json",
            fixture.path.display()
        ));
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
        let copy_doc = DesktopDocument::open(&copy, None).unwrap();
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
        let sidecar = PathBuf::from(format!(
            "{}.lyra-reader-annotations.json",
            fixture.path.display()
        ));
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
    fn oversized_sidecar_changes_roll_back_without_overwriting_the_saved_state() {
        let fixture = Fixture::new("text-page.pdf");
        let doc = fixture.open();
        doc.command(json!({"op":"bookmark_create","page":0,"title":"Preserve me","yPt":0}))
            .unwrap();
        let path = PathBuf::from(format!(
            "{}.lyra-reader-annotations.json",
            fixture.path.display()
        ));
        let before = fs::read(&path).unwrap();
        let error=doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":1,"color":"#E8BC5552","note":"x".repeat(16*1024*1024)}})).unwrap_err();
        assert!(error.contains("16 MiB"));
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
            .0
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
        assert!(pdfs <= 33, "{pdfs} revisions retained");
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
        let merged_doc = DesktopDocument::open(&merged, None).unwrap();
        let marks = merged_doc.command(json!({"op":"marks"})).unwrap();
        assert_eq!(marks["annotations"].as_array().unwrap().len(), 2);
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
        let part = DesktopDocument::open(&last, None).unwrap();
        let marks = part.command(json!({"op":"marks"})).unwrap();
        assert_eq!(marks["annotations"][0]["page"], 0);
        assert_eq!(marks["annotations"][0]["note"], "mark-2");
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
        assert!(
            doc.command(
                json!({"op":"save_split","parts":[{"destination_path":blocked,"pages":[0]}]})
            )
            .is_err()
        );
        assert!(!blocked.exists());
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
        let first = DesktopDocument::open(&first, None).unwrap();
        let marks = first.command(json!({"op":"marks"})).unwrap();
        assert_eq!(marks["annotations"][0]["note"], "carried");
    }

    #[test]
    fn unknown_marks_survive_append_but_stop_unsafe_split_remapping() {
        let fixture = Fixture::new("multipage.pdf");
        let other = Fixture::new("text-page.pdf");
        let raw = r#"{"kind" : "future-entry", "page": 2, "unknown" : [1, 2]}"#;
        fs::write(
            format!("{}.lyra-reader-annotations.json", fixture.path.display()),
            format!("[{raw}]"),
        )
        .unwrap();
        let doc = fixture.open();
        let merged = fixture.directory.join("future-merged.pdf");
        doc.command(json!({"op":"save_merge","others":[other.path],"destination":merged}))
            .unwrap();
        assert!(
            fs::read_to_string(format!("{}.lyra-reader-annotations.json", merged.display()))
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
    fn signed_original_status_survives_derived_page_revisions() {
        let fixture = Fixture::new("signed-signature.pdf");
        let doc = fixture.open();
        assert_eq!(doc.info().unwrap()["signature_status"]["signed"], true);
        let copy = fixture.directory.join("signed-split.pdf");
        doc.command(json!({"op":"save_split","parts":[{"destination_path":copy,"pages":[0]}]}))
            .unwrap();
        assert_eq!(
            DesktopDocument::open(&copy, None).unwrap().info().unwrap()["signature_status"]["signed"],
            false
        );

        let original = fs::read(&fixture.path).unwrap();
        let staged = doc
            .command(json!({"op":"page_stage","operation":{"InsertBlank":{"index":0}}}))
            .unwrap();
        assert_eq!(staged["info"]["signature_status"]["signed"], true);
        assert!(doc.command(json!({"op":"page_apply"})).is_err());
        assert_eq!(fs::read(&fixture.path).unwrap(), original);
    }
    #[test]
    fn page_sessions_remap_marks_undo_without_touching_original_and_apply_with_backups() {
        let fixture = Fixture::new("multipage.pdf");
        let original = fs::read(&fixture.path).unwrap();
        let doc = fixture.open();
        doc.command(json!({"op":"bookmark_create","page":2,"title":"Last page","yPt":20}))
            .unwrap();
        doc.command(json!({"op":"mark_create","entry":{"kind":"highlight","page":0,"start":0,"end":3,"color":"#E8BC5552","note":"Move with this page"}})).unwrap();
        let sidecar = PathBuf::from(format!(
            "{}.lyra-reader-annotations.json",
            fixture.path.display()
        ));
        let sidecar_before = fs::read(&sidecar).unwrap();
        assert!(
            doc.command(
                json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}})
            )
            .is_err()
        );
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
        let copied = DesktopDocument::open(&copy, None).unwrap();
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

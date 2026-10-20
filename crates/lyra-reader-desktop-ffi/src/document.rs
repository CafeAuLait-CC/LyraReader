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
            if !matches!(op, "marks" | "marks_undo" | "marks_redo") {
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
            "annotations" => value(d.annotations()),
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
    fn signed_original_status_survives_derived_page_revisions() {
        let fixture = Fixture::new("signed-signature.pdf");
        let doc = fixture.open();
        assert_eq!(doc.info().unwrap()["signature_status"]["signed"], true);
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

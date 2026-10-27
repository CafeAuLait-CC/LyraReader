//! Thin native-shell adapter over the shared document transaction and PDF writers.
pub(super) use crate::session::SessionDirectory;
use crate::session::{SessionControl, SessionOwner, read_recovery};
use crate::{document::DesktopDocument, marks::Marks};
use lyra_reader_edit::transaction::{file_url_path, path_file_url};
use lyra_reader_ffi::api::*;
use lyra_reader_ffi::{
    DocumentTransactionInputRecord, DocumentTransactionStartRecord, DocumentTransactionStateRecord,
    start_document_transaction,
};
use lyra_reader_session::DocumentLayout;
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Default)]
pub struct PageEdits {
    pub(super) directory: Option<Arc<SessionDirectory>>,
    control: Option<Arc<SessionControl>>,
    original: Option<Marks>,
    view: Option<PageView>,
}
struct PageView {
    can_undo: bool,
    can_redo: bool,
    pending: bool,
    page: u32,
    selection: Vec<u32>,
    warning: Option<String>,
}
impl PageEdits {
    pub fn has_session(&self) -> bool {
        self.control.is_some()
    }
    fn adopt(&mut self, state: &DocumentTransactionStateRecord) {
        self.view = Some(PageView {
            can_undo: state.can_undo,
            can_redo: state.can_redo,
            pending: state.revision_url != state.original_url || !state.operations.is_empty(),
            page: state.current_page,
            selection: state.selection.clone(),
            warning: state.recovery_error.clone(),
        });
    }
    pub fn annotate_state(
        &self,
        mut state: Value,
        _document: &LyraReaderDocument,
        _original: &Path,
    ) -> Value {
        state["page_pending"] = json!(self.view.as_ref().is_some_and(|v| v.pending));
        state["page_session_active"] = json!(self.control.is_some());
        state["can_page_undo"] = json!(self.view.as_ref().is_some_and(|v| v.can_undo));
        state["can_page_redo"] = json!(self.view.as_ref().is_some_and(|v| v.can_redo));
        if let Some(view) = &self.view {
            state["page_location"] = json!({"page":view.page-1,"selection":view.selection});
            state["recovery_warning"] = json!(view.warning);
        }
        state
    }
    fn input(
        &self,
        marks: &Marks,
        request: &Value,
        count: u32,
    ) -> Result<DocumentTransactionInputRecord, String> {
        let page = match request.get("current_page") {
            Some(v) => v
                .as_u64()
                .and_then(|p| u32::try_from(p).ok())
                .and_then(|p| p.checked_add(1))
                .filter(|p| *p <= count)
                .ok_or("Invalid current page")?,
            None => self.view.as_ref().map(|v| v.page).unwrap_or(1),
        };
        let selection = match request.get("selected_pages") {
            Some(v) => serde_json::from_value::<Vec<u32>>(v.clone()).map_err(|e| e.to_string())?,
            None => self
                .view
                .as_ref()
                .map(|v| v.selection.clone())
                .unwrap_or_default(),
        };
        if selection.iter().any(|p| *p >= count) {
            return Err("Selected pages are outside the document".into());
        }
        marks.transaction_input(page, &selection)
    }
    fn request(
        &self,
        original: &LyraReaderDocument,
        marks: &Marks,
        directory: &Path,
        input: DocumentTransactionInputRecord,
        restore: bool,
    ) -> Result<DocumentTransactionStartRecord, String> {
        let cache = marks.cache_location()?;
        let identity = original.document_identity();
        Ok(DocumentTransactionStartRecord {
            original_url: path_file_url(&cache.document, false).map_err(|e| e.to_string())?,
            directory_url: if restore {
                String::new()
            } else {
                path_file_url(directory, true).map_err(|e| e.to_string())?
            },
            recovery_path: cache
                .directory
                .join("session.json")
                .to_string_lossy()
                .into_owned(),
            original_records_url: path_file_url(&cache.annotations(), false)
                .map_err(|e| e.to_string())?,
            title: cache
                .document
                .file_name()
                .ok_or("Missing document filename")?
                .to_string_lossy()
                .into_owned(),
            page_count: original.page_count(),
            original_rotations: if restore {
                Vec::new()
            } else {
                original.page_rotations().map_err(|e| e.to_string())?
            },
            original_signature_json: serde_json::to_string(&original.signature_status())
                .map_err(|e| e.to_string())?,
            source_size: identity.size,
            source_modified: None,
            source_sha256: identity.sha256,
            annotations_json: input.annotations_json,
            bookmarks_json: input.bookmarks_json,
            slots_json: input.slots_json,
            deletions_json: input.deletions_json,
            erased_ink_json: input.erased_ink_json,
            annotation_dirty: input.annotation_dirty,
            current_page: input.current_page,
            selection: input.selection,
            cache_directory_prefix: cache.directory.to_string_lossy().into_owned(),
            restore,
            xfa_read_only_reason: original.xfa_status().read_only_reason,
        })
    }
    fn begin(
        &mut self,
        original: &LyraReaderDocument,
        marks: &Marks,
        input: DocumentTransactionInputRecord,
    ) -> Result<DocumentTransactionStateRecord, String> {
        marks.validate_source()?;
        let cache = marks.cache_location()?;
        let path = cache.directory.join("session.json");
        if path.exists() {
            return Err("A cached editing session must be restored before starting another".into());
        }
        let owner = SessionOwner::acquire(&path)?;
        let directory = cache
            .directory
            .join(format!("session-{}", crate::marks::uuid()?));
        let mut options = fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            options.mode(0o700);
        }
        options.create(&directory).map_err(|e| e.to_string())?;
        let request = self.request(original, marks, &directory, input, false)?;
        let handle = start_document_transaction(request).map_err(|e| e.to_string())?;
        let control = SessionControl::new(handle, path)?;
        let state = control.handle.snapshot().map_err(|e| e.to_string())?;
        let mut original_marks = marks.page_snapshot();
        original_marks.owns_session();
        self.original = Some(original_marks);
        self.directory = Some(Arc::new(SessionDirectory::recoverable(
            directory,
            Arc::clone(&control),
            owner,
        )));
        self.control = Some(control);
        self.adopt(&state);
        Ok(state)
    }
    fn restore(
        &mut self,
        original: &LyraReaderDocument,
        marks: &Marks,
    ) -> Result<Option<DocumentTransactionStateRecord>, String> {
        let cache = marks.cache_location()?;
        let path = cache.directory.join("session.json");
        let Some(bytes) = read_recovery(&path)? else {
            return Ok(None);
        };
        cache.validate_pdf_source()?;
        let owner = SessionOwner::acquire(&path)?;
        let input = marks.transaction_input(1, &[])?;
        let request = self.request(original, marks, &cache.directory, input, true)?;
        let handle = start_document_transaction(request).map_err(|e| e.to_string())?;
        if read_recovery(&path)?.as_ref() != Some(&bytes) {
            return Err(
                "The cached editing session changed while opening; its files were kept".into(),
            );
        }
        let state = handle.snapshot().map_err(|e| e.to_string())?;
        let directory = validate_recovery_paths(&bytes, &state, &cache.directory, &cache.document)?;
        let control = SessionControl::new(handle, path)?;
        let mut original_marks = marks.page_snapshot();
        original_marks.owns_session();
        self.original = Some(original_marks);
        self.directory = Some(Arc::new(SessionDirectory::recoverable(
            directory,
            Arc::clone(&control),
            owner,
        )));
        self.control = Some(control);
        self.adopt(&state);
        Ok(Some(state))
    }
    fn retire(&mut self) -> Result<(), String> {
        if let Some(directory) = &self.directory {
            directory.retire()?;
        }
        self.control = None;
        self.directory = None;
        self.original = None;
        self.view = None;
        Ok(())
    }
    fn control(&self) -> Result<Arc<SessionControl>, String> {
        self.control
            .clone()
            .ok_or_else(|| "There is no active editing session".into())
    }
}

fn checked_local_path(url: &str) -> Result<PathBuf, String> {
    file_url_path(url)
        .ok_or_else(|| "The cached editing session contains an invalid local file URL".into())
}
fn validate_recovery_paths(
    bytes: &[u8],
    state: &DocumentTransactionStateRecord,
    cache: &Path,
    original: &Path,
) -> Result<PathBuf, String> {
    let directory = checked_local_path(&state.directory_url)?
        .canonicalize()
        .map_err(|e| e.to_string())?;
    let cache = cache.canonicalize().map_err(|e| e.to_string())?;
    if directory.parent() != Some(cache.as_path())
        || !directory
            .file_name()
            .is_some_and(|n| n.to_string_lossy().starts_with("session-"))
    {
        return Err(
            "The cached editing directory is outside this document's cache; its files were kept"
                .into(),
        );
    }
    let records = checked_local_path(&state.annotation_records_url)?;
    if records
        .parent()
        .and_then(|p| p.canonicalize().ok())
        .as_deref()
        != Some(directory.as_path())
    {
        return Err("The cached annotation path is outside the editing session".into());
    }
    let original = original.canonicalize().map_err(|e| e.to_string())?;
    fn check(value: &Value, directory: &Path, original: &Path) -> Result<(), String> {
        match value {
            Value::Array(values) => {
                for v in values {
                    check(v, directory, original)?;
                }
            }
            Value::Object(object) => {
                for (key, v) in object {
                    if key == "revisionURL" {
                        let path =
                            checked_local_path(v.as_str().ok_or("Invalid cached revision URL")?)?;
                        let path = path.canonicalize().map_err(|e| {
                            format!("A cached revision is missing or unreadable: {e}")
                        })?;
                        if path != original && path.parent() != Some(directory) {
                            return Err("A cached revision is outside the editing session; its files were kept".into());
                        }
                    } else {
                        check(v, directory, original)?;
                    }
                }
            }
            _ => {}
        }
        Ok(())
    }
    let document: Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    // The session metadata and both history stacks own revision paths. The root
    // snapshot's revisionURL is retained data after a legacy cache relocation.
    check(&document["session"], &directory, &original)?;
    Ok(directory)
}

impl DesktopDocument {
    fn activate(&self, document: Arc<LyraReaderDocument>, marks: Marks) -> Result<(), String> {
        let sizes = (0..document.page_count())
            .map(|p| {
                document
                    .page_size_pt(p)
                    .map(|s| (s.width_pt, s.height_pt))
                    .map_err(|e| e.to_string())
            })
            .collect::<Result<Vec<_>, _>>()?;
        *self
            .layout
            .write()
            .map_err(|_| "Layout state is unavailable")? =
            DocumentLayout::new(sizes, lyra_reader_runtime::PAGE_GAP_PT);
        *self
            .engine
            .write()
            .map_err(|_| "Document state is unavailable")? = document;
        *self
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")? = marks;
        Ok(())
    }
    fn revision(
        &self,
        state: &DocumentTransactionStateRecord,
    ) -> Result<Arc<LyraReaderDocument>, String> {
        let path = checked_local_path(&state.revision_url)?;
        let document = LyraReaderEngine::new()
            .open_document(path.to_string_lossy().into_owned(), self.password.clone())
            .map_err(|e| e.to_string())?;
        if state.current_page == 0
            || state.current_page > document.page_count()
            || state.current_to_original.len() != document.page_count() as usize
            || state.selection.iter().any(|p| *p >= document.page_count())
        {
            return Err("The cached editing snapshot has invalid page positions".into());
        }
        Ok(document)
    }
    pub(super) fn restore_cached_pages(&self) -> Result<(), String> {
        let state = self.page_command("page_restore", &json!({}))?;
        if state.is_object() {
            *self
                .recovery_status
                .lock()
                .map_err(|_| "Recovery state is unavailable")? =
                json!({"location":state["marks"]["page_location"]});
        }
        Ok(())
    }
    pub(super) fn page_command(&self, op: &str, r: &Value) -> Result<Value, String> {
        let mut edits = self
            .edits
            .lock()
            .map_err(|_| "Page-edit state is unavailable")?;
        let current = self.active()?;
        let mut marks = self
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")?;
        let mut report = Value::Null;
        let (document, next_marks) = match op {
            "page_restore" => {
                if edits.control.is_some() {
                    return Ok(Value::Null);
                }
                let Some(state) = edits.restore(&current, &marks)? else {
                    return Ok(Value::Null);
                };
                let result = (|| {
                    let next = self.revision(&state)?;
                    let restored = marks.restored_transaction(&state, edits.control()?, &next)?;
                    Ok::<_, String>((next, restored))
                })();
                if result.is_err() {
                    *edits = PageEdits::default();
                }
                result?
            }
            "page_stage" => {
                let operation: PageOperationRecord =
                    serde_json::from_value(r["operation"].clone()).map_err(|e| e.to_string())?;
                if edits.control.is_none() {
                    marks.can_stage(&operation)?;
                    let input = edits.input(&marks, r, current.page_count())?;
                    let state = edits.begin(&current, &marks, input)?;
                    *marks = marks.restored_transaction(&state, edits.control()?, &current)?;
                }
                marks.can_stage(&operation)?;
                let control = edits.control()?;
                let input = edits.input(&marks, r, current.page_count())?;
                let before = control.handle.snapshot().map_err(|e| e.to_string())?;
                let rollback_input =
                    marks.transaction_input(input.current_page, &input.selection)?;
                control.mutate(|h| h.begin_apply("Page change".into(), input))?;
                let staged = (|| -> Result<_, String> {
                    if marks.needs_materialization(&operation) {
                        let payload = marks.payload(&current)?;
                        let directory = edits
                            .directory
                            .as_ref()
                            .ok_or("Missing editing directory")?;
                        let path = directory
                            .path
                            .join(format!("marks-{}.pdf", crate::marks::uuid()?));
                        current
                            .save_annotation_changes_copy(
                                path.to_string_lossy().into_owned(),
                                payload.annotations,
                                payload.bookmarks,
                                payload.updates,
                                payload.deletions,
                            )
                            .map_err(|e| e.to_string())?;
                        let revision_url =
                            path_file_url(&path, false).map_err(|e| e.to_string())?;
                        let mut clean = marks.cleaned_for_save(&payload.ids);
                        let view = control.handle.snapshot().map_err(|e| e.to_string())?;
                        let input = clean.transaction_input(view.current_page, &view.selection)?;
                        control.mutate(|h| {
                            h.persist(
                                input,
                                revision_url,
                                view.revision_number,
                                control.recovery_path.to_string_lossy().into_owned(),
                            )
                        })?;
                        // The transaction uses the post-materialization state as the remap base,
                        // while its prepared snapshot remains the single undo step.
                        clean.owns_session();
                    }
                    control.mutate(|h| h.apply(operation))
                })();
                let outcome = match staged {
                    Ok(value) => value,
                    Err(error) => {
                        // Abandon only this prepared write; the current verified revision survives.
                        let rollback = control.mutate(|h| {
                            h.cancel_apply()?;
                            h.persist(
                                rollback_input,
                                before.revision_url.clone(),
                                before.revision_number,
                                control.recovery_path.to_string_lossy().into_owned(),
                            )
                        });
                        if let Err(e) = rollback {
                            marks.recovery_notice(format!(
                                "The failed page change needs recovery: {e}"
                            ));
                            return Err(error);
                        }
                        if before.revision_url == before.original_url
                            && before.operations.is_empty()
                        {
                            let root = marks.cache_root().map(Path::to_path_buf);
                            if let Err(e) = edits.retire() {
                                marks.recovery_notice(e);
                            } else {
                                *marks = Marks::load_opened(&current, root.as_deref());
                                marks.seed_bookmarks(&current)?;
                            }
                        }
                        return Err(error);
                    }
                };
                let mut outcome = outcome;
                let warning = outcome.state.recovery_error.take();
                outcome.state = control.mutate(|h| h.limit_history(32, 64 * 1024 * 1024))?;
                if outcome.state.recovery_error.is_none() {
                    outcome.state.recovery_error = warning;
                }
                if let Some(directory) = &edits.directory
                    && let Err(error) = directory.collect_garbage()
                {
                    outcome.state.recovery_error = Some(error);
                }
                let next = self.revision(&outcome.state)?;
                let next_marks = marks.restored_transaction(&outcome.state, control, &next)?;
                report = json!({"page_count":outcome.page_count,"page_map":outcome.page_map,"inserted_page":outcome.inserted_page,
                    "location":{"page":outcome.state.current_page-1,"selection":outcome.state.selection},"recovery_warning":outcome.state.recovery_error});
                edits.adopt(&outcome.state);
                (next, next_marks)
            }
            "page_undo" | "page_redo" => {
                marks.validate_source()?;
                let control = edits.control()?;
                let input = edits.input(&marks, r, current.page_count())?;
                let target = if op == "page_undo" {
                    control.mutate(|h| h.undo(input))?
                } else {
                    control.mutate(|h| h.redo(input))?
                };
                let state = target.ok_or("No page change to undo or redo")?;
                let next = self.revision(&state)?;
                let next_marks = marks.restored_transaction(&state, control, &next)?;
                report = json!({"location":{"page":state.current_page-1,"selection":state.selection},"recovery_warning":state.recovery_error});
                edits.adopt(&state);
                (next, next_marks)
            }
            "page_discard" => {
                let root = marks.cache_root().map(Path::to_path_buf);
                edits.retire()?;
                *self
                    .recovery_status
                    .lock()
                    .map_err(|_| "Recovery state is unavailable")? = Value::Null;
                let next = LyraReaderEngine::new()
                    .open_document(
                        self.original_path.to_string_lossy().into_owned(),
                        self.password.clone(),
                    )
                    .map_err(|e| e.to_string())?;
                let mut restored = Marks::load_opened(&next, root.as_deref());
                restored.seed_bookmarks(&next)?;
                (next, restored)
            }
            "page_apply" => {
                let original = edits
                    .original
                    .clone()
                    .ok_or("There are no staged page changes")?;
                let payload = marks.payload(&current)?;
                let directory = edits.directory.clone().ok_or("Missing editing directory")?;
                let clean = marks.cleaned_for_save(&payload.ids);
                let combined = if payload.is_empty() {
                    Arc::clone(&current)
                } else {
                    let combined = directory
                        .path
                        .join(format!("save-{}.pdf", crate::marks::uuid()?));
                    current
                        .save_annotation_changes_copy(
                            combined.to_string_lossy().into_owned(),
                            payload.annotations,
                            payload.bookmarks,
                            payload.updates,
                            payload.deletions,
                        )
                        .map_err(|e| e.to_string())?;
                    LyraReaderEngine::new()
                        .open_document(
                            combined.to_string_lossy().into_owned(),
                            self.password.clone(),
                        )
                        .map_err(|e| e.to_string())?
                };
                let mut cleanup = None;
                let (outcome, next_marks, backup) =
                    clean.publish_page_revision(&original, || {
                        let outcome = combined
                            .replace_with_edited_pages(
                                self.original_path.to_string_lossy().into_owned(),
                            )
                            .map_err(|e| e.to_string())?;
                        cleanup = directory.retire().err();
                        Ok(outcome)
                    })?;
                report = serde_json::to_value(outcome).map_err(|e| e.to_string())?;
                report["sidecar_backup_path"] = json!(backup);
                report["cache_cleanup_error"] = json!(cleanup);
                report["sidecar_error"] = json!(next_marks.error);
                edits.control = None;
                edits.directory = None;
                edits.original = None;
                edits.view = None;
                *self
                    .recovery_status
                    .lock()
                    .map_err(|_| "Recovery state is unavailable")? = Value::Null;
                let next = LyraReaderEngine::new()
                    .open_document(
                        self.original_path.to_string_lossy().into_owned(),
                        self.password.clone(),
                    )
                    .map_err(|e| e.to_string())?;
                let mut next_marks = next_marks;
                next_marks.seed_bookmarks(&next)?;
                (next, next_marks)
            }
            _ => return Err("Unknown page operation".into()),
        };
        drop(marks);
        self.activate(Arc::clone(&document), next_marks)?;
        let state = self
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")?
            .state(&document)?;
        Ok(
            json!({"info":self.info()?,"marks":edits.annotate_state(state,&document,&self.original_path),"report":report}),
        )
    }
}

use crate::{document::DesktopDocument, marks::Marks};
use lyra_reader_ffi::api::*;
use lyra_reader_session::DocumentLayout;
use serde_json::{Value, json};
use std::{fs, path::PathBuf, sync::Arc};

#[derive(Clone)]
struct Revision {
    path: PathBuf,
    marks: Marks,
}
#[derive(Default)]
pub struct PageEdits {
    directory: Option<PathBuf>,
    base: Option<Revision>,
    undo: Vec<Revision>,
    redo: Vec<Revision>,
    sequence: u64,
}
impl Drop for PageEdits {
    fn drop(&mut self) {
        self.base = None;
        self.undo.clear();
        self.redo.clear();
        if let Some(path) = &self.directory {
            let _ = fs::remove_dir_all(path);
        }
    }
}
impl PageEdits {
    fn trim_history(history: &mut Vec<Revision>) {
        let mut bytes = history
            .iter()
            .map(|r| r.marks.storage_bytes())
            .sum::<usize>();
        while history.len() > 1 && (history.len() > 32 || bytes > 64 * 1024 * 1024) {
            bytes = bytes.saturating_sub(history.remove(0).marks.storage_bytes());
        }
    }
    pub fn clear_redo(&mut self) {
        self.redo.clear();
    }
    pub fn annotate_state(
        &self,
        mut state: Value,
        document: &LyraReaderDocument,
        original: &std::path::Path,
    ) -> Value {
        state["page_pending"] = json!(document.path() != original.to_string_lossy());
        state["can_page_undo"] = json!(!self.undo.is_empty());
        state["can_page_redo"] = json!(!self.redo.is_empty());
        state
    }
}
impl DesktopDocument {
    fn activate(&self, document: Arc<LyraReaderDocument>, marks: Marks) -> Result<(), String> {
        let sizes = (0..document.page_count())
            .map(|page| {
                document
                    .page_size_pt(page)
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
            "page_stage" => {
                let operation: PageOperationRecord =
                    serde_json::from_value(r["operation"].clone()).map_err(|e| e.to_string())?;
                marks.can_stage(&operation)?;
                if current.path() == self.original_path.to_string_lossy() {
                    edits.base = Some(Revision {
                        path: PathBuf::from(current.path()),
                        marks: marks.page_snapshot(),
                    });
                }
                if edits.directory.is_none() {
                    let path = std::env::temp_dir()
                        .join(format!("LyraReaderPageEdits-{}", crate::marks::uuid()?));
                    fs::create_dir(&path).map_err(|e| e.to_string())?;
                    edits.directory = Some(path);
                }
                edits.sequence += 1;
                let destination = edits
                    .directory
                    .as_ref()
                    .unwrap()
                    .join(format!("revision-{}.pdf", edits.sequence));
                let outcome = current
                    .apply_page_operation(destination.to_string_lossy().into_owned(), operation)
                    .map_err(|e| e.to_string())?;
                let next = LyraReaderEngine::new()
                    .open_document(
                        destination.to_string_lossy().into_owned(),
                        self.password.clone(),
                    )
                    .map_err(|e| e.to_string())?;
                let next_marks =
                    marks.staging_copy(&destination, &outcome.page_map, &current, &next)?;
                marks.clear_redo();
                edits.undo.push(Revision {
                    path: PathBuf::from(current.path()),
                    marks: marks.page_snapshot(),
                });
                edits.redo.clear();
                report = serde_json::to_value(outcome).map_err(|e| e.to_string())?;
                (next, next_marks)
            }
            "page_undo" | "page_redo" => {
                let previous = if op == "page_undo" {
                    edits.undo.last().cloned()
                } else {
                    edits.redo.last().cloned()
                }
                .ok_or("No page change to undo")?;
                let previous_document = LyraReaderEngine::new()
                    .open_document(
                        previous.path.to_string_lossy().into_owned(),
                        self.password.clone(),
                    )
                    .map_err(|e| e.to_string())?;
                let snapshot = Revision {
                    path: PathBuf::from(current.path()),
                    marks: marks.page_snapshot(),
                };
                if op == "page_undo" {
                    edits.undo.pop();
                    edits.redo.push(snapshot)
                } else {
                    edits.redo.pop();
                    edits.undo.push(snapshot)
                }
                (previous_document, previous.marks)
            }
            "page_discard" => {
                let next = LyraReaderEngine::new()
                    .open_document(
                        self.original_path.to_string_lossy().into_owned(),
                        self.password.clone(),
                    )
                    .map_err(|e| e.to_string())?;
                let mut next_marks = Marks::load(&self.original_path, next.page_count());
                next_marks.seed_bookmarks(&next)?;
                edits.base = None;
                edits.undo.clear();
                edits.redo.clear();
                (next, next_marks)
            }
            "page_apply" => {
                if current.path() == self.original_path.to_string_lossy() {
                    return Err("There are no staged page changes".into());
                }
                let original = edits.base.as_ref().ok_or("Missing original page session")?;
                let (outcome, next_marks, sidecar_backup) =
                    marks.publish_page_revision(&original.marks, || {
                        current
                            .replace_with_edited_pages(
                                self.original_path.to_string_lossy().into_owned(),
                            )
                            .map_err(|e| e.to_string())
                    })?;
                report = serde_json::to_value(outcome).map_err(|e| e.to_string())?;
                report["sidecar_backup_path"] = json!(sidecar_backup);
                report["sidecar_error"] = json!(next_marks.error);
                let next = LyraReaderEngine::new()
                    .open_document(
                        self.original_path.to_string_lossy().into_owned(),
                        self.password.clone(),
                    )
                    .map_err(|e| e.to_string())?;
                edits.base = None;
                edits.undo.clear();
                edits.redo.clear();
                (next, next_marks)
            }
            _ => return Err("Unknown page operation".into()),
        };
        PageEdits::trim_history(&mut edits.undo);
        PageEdits::trim_history(&mut edits.redo);
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

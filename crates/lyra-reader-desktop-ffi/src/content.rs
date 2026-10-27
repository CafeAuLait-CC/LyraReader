//! Content-edit staging over the shared typed commands and document transaction.
use crate::{document::DesktopDocument, marks::Marks, pages::PageEdits};
use lyra_reader_edit::transaction::path_file_url;
use lyra_reader_ffi::api::*;
use serde_json::{Value, json};
use std::{fs, path::PathBuf, sync::Arc};

pub(super) struct ContentStage {
    pub document: Arc<LyraReaderDocument>,
    pub marks: Marks,
    pub report: Value,
}

fn snapshot_revision(document: &LyraReaderDocument, page: u32) -> Result<String, String> {
    let snapshot: Value =
        serde_json::from_str(&document.content_objects(page).map_err(|e| e.to_string())?)
            .map_err(|e| format!("Invalid content snapshot: {e}"))?;
    snapshot["revision"]
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| "The content snapshot has no source revision".into())
}

impl DesktopDocument {
    pub(super) fn stage_content(
        &self,
        request: &Value,
        edits: &mut PageEdits,
        current: &Arc<LyraReaderDocument>,
        marks: &mut Marks,
    ) -> Result<ContentStage, String> {
        let page: u32 = serde_json::from_value(request["page"].clone())
            .map_err(|e| format!("Invalid content page: {e}"))?;
        let command: ContentCommandRecord = serde_json::from_value(request["command"].clone())
            .map_err(|e| format!("Invalid content command: {e}"))?;
        let allow_raster = match request.get("allow_raster") {
            None => false,
            Some(value) => value.as_bool().ok_or("Invalid raster confirmation")?,
        };
        if allow_raster && !matches!(command, ContentCommandRecord::Redact { .. }) {
            return Err("Only a redaction can request a confirmed raster fallback".into());
        }
        // Validate the original SHA before materialization can rebase the command. Otherwise
        // a stale target could accidentally be authorized by the new working PDF's fingerprint.
        if command.revision() != snapshot_revision(current, page)? {
            return Err(
                "The page changed before this edit. Reload the page before retrying.".into(),
            );
        }
        let payload = marks.payload(current)?;
        if !edits.has_session() {
            let input = edits.input(marks, request, current.page_count())?;
            let state = edits.begin(current, marks, input)?;
            *marks = marks.restored_transaction(
                &state,
                edits.control()?,
                current,
                edits
                    .original
                    .as_ref()
                    .ok_or("Missing original annotation state")?,
            )?;
        }
        let control = edits.control()?;
        let before = control.handle.snapshot().map_err(|e| e.to_string())?;
        let input = edits.input(marks, request, current.page_count())?;
        let rollback_input = marks.transaction_input(input.current_page, &input.selection)?;
        control.mutate(|h| h.begin_apply("Content edit".into(), input))?;
        let mut output: Option<PathBuf> = None;
        let staged = (|| -> Result<_, String> {
            let directory = edits
                .directory
                .as_ref()
                .ok_or("Missing editing directory")?;
            let (source, staged_marks, effective) = if payload.is_empty() {
                (Arc::clone(current), marks.clone(), command)
            } else {
                let path = directory
                    .path
                    .join(format!("marks-{}.pdf", crate::marks::uuid()?));
                let clean = marks.cleaned_for_save(&payload.ids);
                current
                    .save_annotation_changes_copy(
                        path.to_string_lossy().into_owned(),
                        payload.annotations,
                        payload.bookmarks,
                        payload.updates,
                        payload.deletions,
                    )
                    .map_err(|e| e.to_string())?;
                let source = LyraReaderEngine::new()
                    .open_document(path.to_string_lossy().into_owned(), self.password.clone())
                    .map_err(|e| e.to_string())?;
                let effective = command.replacing_revision(snapshot_revision(&source, page)?);
                let input = clean.transaction_input(before.current_page, &before.selection)?;
                let revision_url = path_file_url(&path, false).map_err(|e| e.to_string())?;
                control.mutate(|h| {
                    h.persist(
                        input,
                        revision_url,
                        before.revision_number,
                        control.recovery_path.to_string_lossy().into_owned(),
                    )
                })?;
                (source, clean, effective)
            };
            let path = directory
                .path
                .join(format!("content-{}.pdf", crate::marks::uuid()?));
            output = Some(path.clone());
            let destination = path.to_string_lossy().into_owned();
            let rasterized = if allow_raster {
                source
                    .apply_content_edit_allowing_raster(page, effective, destination.clone())
                    .map_err(|e| e.to_string())?
            } else {
                source
                    .apply_content_edit(page, effective, destination.clone())
                    .map_err(|e| e.to_string())?;
                Vec::new()
            };
            let next = LyraReaderEngine::new()
                .open_document(destination, self.password.clone())
                .map_err(|e| e.to_string())?;
            if next.page_count() != current.page_count() {
                return Err("The content edit changed the page count unexpectedly".into());
            }
            let input = staged_marks.transaction_input(before.current_page, &before.selection)?;
            let revision_url = path_file_url(&path, false).map_err(|e| e.to_string())?;
            let number = before
                .revision_number
                .checked_add(1)
                .ok_or("The editing revision number overflowed")?;
            let committed = control.mutate(|h| {
                h.commit_revision(revision_url.clone(), number, "Content edit".into(), input)
            });
            let state = match committed {
                Ok(state) => state,
                Err(error) => {
                    // Publishing recovery data may fail after the shared transaction adopted
                    // the verified PDF. Keep that successful edit and report its recovery warning.
                    let mut state = control.handle.snapshot().map_err(|e| e.to_string())?;
                    if state.revision_url != revision_url {
                        return Err(error);
                    }
                    state.recovery_error = Some(error);
                    state
                }
            };
            Ok((next, state, rasterized))
        })();
        let (next, mut state, rasterized) = match staged {
            Ok(value) => value,
            Err(error) => {
                let rollback = control.mutate(|h| {
                    h.cancel_apply()?;
                    h.persist(
                        rollback_input,
                        before.revision_url.clone(),
                        before.revision_number,
                        control.recovery_path.to_string_lossy().into_owned(),
                    )
                });
                if let Err(rollback) = rollback {
                    marks.recovery_notice(format!(
                        "The failed content edit needs recovery: {rollback}"
                    ));
                    return Err(format!(
                        "{error}. The previous editing state could not be restored: {rollback}"
                    ));
                }
                if let Some(path) = output {
                    // This abandoned private output is not part of the restored manifest.
                    if let Err(cleanup) = fs::remove_file(path)
                        && cleanup.kind() != std::io::ErrorKind::NotFound
                    {
                        eprintln!(
                            "lyra-reader-content: could not remove an abandoned output: {cleanup}"
                        );
                    }
                }
                if before.revision_url == before.original_url
                    && before.operations.is_empty()
                    && !before.can_undo
                    && !before.can_redo
                {
                    let root = marks.cache_root().map(std::path::Path::to_path_buf);
                    if let Err(retire) = edits.retire() {
                        marks.recovery_notice(retire);
                    } else {
                        *marks = Marks::load_opened(current, root.as_deref());
                        marks.seed_bookmarks(current)?;
                    }
                }
                if let Some(directory) = &edits.directory
                    && let Err(cleanup) = directory.collect_garbage()
                {
                    marks.recovery_notice(format!("The abandoned edit needs cleanup: {cleanup}"));
                }
                return Err(error);
            }
        };
        let warning = state.recovery_error.take();
        match control.mutate(|h| h.limit_history(32, 64 * 1024 * 1024)) {
            Ok(next) => state = next,
            Err(error) => state.recovery_error = Some(error),
        }
        if state.recovery_error.is_none() {
            state.recovery_error = warning;
        }
        if let Some(directory) = &edits.directory
            && let Err(error) = directory.collect_garbage()
        {
            state.recovery_error = Some(error);
        }
        let next_marks = marks.restored_transaction(
            &state,
            control,
            &next,
            edits
                .original
                .as_ref()
                .ok_or("Missing original annotation state")?,
        )?;
        edits.adopt(&state);
        Ok(ContentStage {
            document: next,
            marks: next_marks,
            report: json!({"page_count":current.page_count(),
                "page_map":(0..current.page_count()).map(Some).collect::<Vec<_>>(),
                "location":{"page":state.current_page-1,"selection":state.selection},
                "edited_page":page,"rasterized_pages":rasterized,
                "recovery_warning":state.recovery_error}),
        })
    }
}

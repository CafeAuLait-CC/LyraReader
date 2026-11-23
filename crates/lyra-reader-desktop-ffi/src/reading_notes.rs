//! Native storage adapter for the shared reading-note records.
use crate::document::DesktopDocument;
use lyra_reader_ffi::api::LyraReaderDocument;
use serde_json::{Value, json};
use std::sync::Arc;

impl DesktopDocument {
    pub(super) fn keep_summary_note(
        &self,
        source: &Arc<LyraReaderDocument>,
        id: &str,
    ) -> Result<Value, String> {
        self.update_reading_workspace(source, |workspace, sha, cache| {
            let archived = workspace.records().into_iter().find(|record| {
                record.id == id && record.kind == "summary" && record.source_hash == sha
            });
            let summary = match archived {
                Some(record) => record,
                None => {
                    let mut record = crate::analysis_cache::summary_record(
                        cache,
                        sha,
                        source.page_count(),
                    )?
                    .filter(|record| record.id == id)
                    .ok_or(
                        "This version of the summary is unavailable. Open the saved summary again.",
                    )?;
                    // The understanding cache retains the original paragraphs. The note and its
                    // source record need the completed answer and its proven page set only.
                    record.originals.clear();
                    record.original_pages.clear();
                    workspace.put(record)?
                }
            };
            let note = workspace.keep(summary, crate::marks::uuid()?)?;
            Ok(json!({"id":note.id,"title":note.title}))
        })
    }

    pub(super) fn reading_notes(
        &self,
        source: &Arc<LyraReaderDocument>,
        query: &str,
    ) -> Result<Value, String> {
        self.read_workspace(source, false, |workspace| {
            Ok(
                json!(workspace.notes(query, true).into_iter().map(|note| json!({
                "id":note.id,"title":note.title,"status":note.status,"modified":note.modified
            })).collect::<Vec<_>>()),
            )
        })
    }

    pub(super) fn reading_note(
        &self,
        source: &Arc<LyraReaderDocument>,
        id: &str,
    ) -> Result<Value, String> {
        self.read_workspace(source, false, |workspace| {
            let note = workspace
                .records()
                .into_iter()
                .find(|note| note.id == id && note.kind == "note")
                .ok_or("This saved reading note is unavailable.")?;
            let pages = if note.status == "sourceChanged" || note.source_hash.is_empty() {
                Vec::new()
            } else {
                note.pages
                    .into_iter()
                    .filter(|page| *page > 0 && *page <= source.page_count())
                    .collect()
            };
            Ok(
                json!({"id":note.id,"title":note.title,"content":note.content,"status":note.status,
                "source_pages":pages}),
            )
        })
    }
}

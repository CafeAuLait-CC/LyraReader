//! Native storage adapter for the shared reading-note records.
use crate::document::DesktopDocument;
use lyra_reader_ai::workspace::{ReadingRecord, ReadingWorkspace};
use lyra_reader_ffi::api::LyraReaderDocument;
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Deserialize)]
pub(super) struct NoteDraft {
    id: String,
    expected_modified: String,
    title: Option<String>,
    content: Option<String>,
    thoughts: Option<String>,
}

impl DesktopDocument {
    pub(super) fn archive_selection_summary(
        &self,
        source: &Arc<LyraReaderDocument>,
        summary: ReadingRecord,
    ) -> Result<String, String> {
        self.update_reading_workspace(source, |workspace, sha, _| {
            if summary.source_hash != sha {
                return Err("The selected summary no longer matches this document.".into());
            }
            let record = workspace.put(summary)?;
            if workspace.task_selection(&record.id)?.is_none() {
                return Err("The selected summary is missing its passage.".into());
            }
            Ok(record.id)
        })
    }

    pub(super) fn keep_reading_note(
        &self,
        source: &Arc<LyraReaderDocument>,
        id: &str,
    ) -> Result<Value, String> {
        self.update_reading_workspace(source, |workspace, sha, cache| {
            let archived = workspace
                .records()
                .into_iter()
                .find(|record| record.id == id);
            let original = match archived {
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
            if !matches!(original.kind.as_str(), "summary" | "message")
                || original.source_hash != sha
                || original.status != "finished"
                || original.content.trim().is_empty()
                || original
                    .pages
                    .iter()
                    .any(|page| *page > source.page_count())
            {
                return Err(
                    "This answer is incomplete or belongs to an earlier PDF revision.".into(),
                );
            }
            let mut original = original;
            if original.title.is_empty() && original.kind == "message" {
                original.title = original.question.clone();
            }
            original.originals.clear();
            original.original_pages.clear();
            let note = workspace.keep(original, crate::marks::uuid()?)?;
            Ok(json!({"id":note.id,"title":note.title}))
        })
    }

    pub(super) fn reading_notes(
        &self,
        source: &Arc<LyraReaderDocument>,
        query: &str,
        recent: bool,
    ) -> Result<Value, String> {
        self.read_workspace(source, false, |workspace| {
            Ok(
                json!(workspace.notes(query, recent).into_iter().map(|note| json!({
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
            Ok(note_value(find_note(workspace, id)?, source))
        })
    }

    pub(super) fn save_reading_note(
        &self,
        source: &Arc<LyraReaderDocument>,
        draft: NoteDraft,
    ) -> Result<Value, String> {
        let expected = draft
            .expected_modified
            .parse::<u64>()
            .map_err(|_| "The reading note has an invalid saved version.")?;
        self.update_reading_workspace(source, |workspace, _, _| {
            let mut note = find_note(workspace, &draft.id)?;
            if note.modified != expected {
                return Err(
                    "This note changed in another window. Your unsaved text was kept.".into(),
                );
            }
            if draft
                .title
                .as_ref()
                .is_none_or(|title| title == &note.title)
                && draft
                    .content
                    .as_ref()
                    .is_none_or(|content| content == &note.content)
                && draft
                    .thoughts
                    .as_ref()
                    .is_none_or(|thoughts| thoughts == &note.thoughts)
            {
                return Ok(note_value(note, source));
            }
            if let Some(title) = draft.title {
                note.title = title;
            }
            if let Some(content) = draft.content {
                note.content = content;
            }
            if let Some(thoughts) = draft.thoughts {
                note.thoughts = thoughts;
            }
            let now = u64::try_from(chrono::Utc::now().timestamp_millis())
                .map_err(|_| "The local clock cannot date the reading note.")?;
            note.modified = now.max(
                note.modified
                    .checked_add(1)
                    .ok_or("The reading note version is outside the supported range.")?,
            );
            note.status = "saved".into();
            Ok(note_value(workspace.put(note)?, source))
        })
    }
}

fn find_note(workspace: &ReadingWorkspace, id: &str) -> Result<ReadingRecord, String> {
    workspace
        .records()
        .into_iter()
        .find(|note| note.id == id && note.kind == "note")
        .ok_or_else(|| "This saved reading note is unavailable.".into())
}

fn note_value(note: ReadingRecord, source: &LyraReaderDocument) -> Value {
    let verified = note.source_hash == source.document_identity().sha256;
    let pages = if verified {
        note.pages
            .into_iter()
            .filter(|page| *page > 0 && *page <= source.page_count())
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    let status = if verified {
        note.status.as_str()
    } else {
        "sourceChanged"
    };
    json!({"id":note.id,"title":note.title,"content":note.content,"thoughts":note.thoughts,
        "modified":note.modified.to_string(),"status":status,"source_pages":pages})
}

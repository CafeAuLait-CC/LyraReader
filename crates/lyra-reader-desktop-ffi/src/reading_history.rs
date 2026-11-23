//! Local disk adapter for the shared reading workspace. Archive snapshots and replay are separate
//! from the command that sends an approved request.
use crate::document::DesktopDocument;
use crate::document_cache::{DocumentCache, atomic_write, lock_reading_workspace, read_optional};
use lyra_reader_ai::workspace::{
    ReadingRecord, ReadingWorkspace, TranslationBlock, reading_scope_key, translation_blocks,
};
use lyra_reader_ffi::api::{
    AiActionRecord, AiPlanRecord, AiPlanRequestRecord, AiSelectionRecord, LyraReaderDocument,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fmt::Write;
use std::sync::Arc;

pub(super) const WORKSPACE_FILE: &str = "ai-reading-workspace.json";

#[derive(Deserialize, Serialize)]
pub(super) struct TranslationScope {
    pub selection: Option<AiSelectionRecord>,
    pub language: String,
    pub detail: String,
}

pub(super) struct PendingTranslation {
    record: ReadingRecord,
    request_pages: Vec<Vec<u32>>,
}

impl TranslationScope {
    pub fn capture(
        self,
        plan: &AiPlanRecord,
        source_hash: String,
    ) -> Result<PendingTranslation, String> {
        let selection = self.selection.map(|range| lyra_reader_ai::SelectionRange {
            page: range.page,
            start: range.start,
            end: range.end,
        });
        let record = ReadingRecord {
            id: crate::marks::uuid()?,
            kind: "translation".into(),
            source_id: reading_scope_key(selection),
            title: plan.document_title.clone(),
            pages: plan.source_pages.clone(),
            excerpt: plan.sources.first().map_or_else(String::new, |source| {
                source.snippet.chars().take(160).collect()
            }),
            language: self.language,
            detail: self.detail,
            model: plan.model.clone(),
            originals: plan
                .sources
                .iter()
                .map(|source| source.snippet.clone())
                .collect(),
            original_pages: plan.sources.iter().map(|source| source.page).collect(),
            source_hash,
            status: "finished".into(),
            ..ReadingRecord::default()
        };
        Ok(PendingTranslation {
            record,
            request_pages: plan.parts.iter().map(|part| part.pages.clone()).collect(),
        })
    }
}

fn rows_value(rows: &[TranslationBlock]) -> Value {
    Value::Array(rows.iter().map(|row| {
        json!({"original": row.original, "translation": row.translation, "page": row.page})
    }).collect())
}

impl PendingTranslation {
    pub fn finish(
        mut self,
        replies: &[String],
        failure: Option<&str>,
        result: &mut Value,
    ) -> Option<Result<ReadingRecord, String>> {
        if !replies.iter().any(|reply| !reply.trim().is_empty()) {
            if failure.is_none() {
                result["translation_warning"] =
                    json!("The response did not translate any source paragraphs.");
            }
            return None;
        }
        let rows = failure
            .map_or_else(
                || {
                    lyra_reader_ai::workspace::translation_blocks_from_parts(
                        &self.record.originals,
                        &self.record.original_pages,
                        replies.iter().map(String::as_str),
                    )
                },
                |message| Err(message.to_owned()),
            )
            .and_then(|rows| {
                if rows.is_empty() || rows.iter().any(|row| row.translation.is_empty()) {
                    return Err("The response did not translate every requested paragraph.".into());
                }
                Ok(rows)
            });
        Some((|| {
            match rows {
                Ok(rows) => {
                    result["translation_blocks"] = rows_value(&rows);
                    // Publish stable markers in approved order for either shell's shared parser.
                    for (index, row) in rows.iter().enumerate() {
                        writeln!(
                            &mut self.record.content,
                            "<!--lyra:{index}--> {}",
                            row.translation
                        )
                        .map_err(|error| error.to_string())?;
                    }
                }
                Err(error) => {
                    result["translation_warning"] = json!(error);
                    self.record.status = "partial".into();
                    self.record.content = replies.join("\n\n");
                    self.record.excerpt = self.record.content.trim().chars().take(160).collect();
                    self.record.originals.clear();
                    self.record.original_pages.clear();
                    // A part announcement precedes HTTP. Only received answer text
                    // establishes which reviewed requests contributed to this archive.
                    self.record.pages = replies
                        .iter()
                        .zip(self.request_pages)
                        .filter(|(reply, _)| !reply.trim().is_empty())
                        .flat_map(|(_, pages)| pages)
                        .collect();
                }
            }
            self.record.modified = u64::try_from(chrono::Utc::now().timestamp_millis())
                .map_err(|_| "The local clock cannot date this translation.")?;
            Ok(self.record)
        })())
    }
}

fn workspace(bytes: Option<&[u8]>, sha: String) -> Result<ReadingWorkspace, String> {
    let mut workspace =
        bytes.map_or_else(|| Ok(ReadingWorkspace::default()), ReadingWorkspace::decode)?;
    workspace.bind_source(sha);
    Ok(workspace)
}

impl DesktopDocument {
    fn with_reading_cache<T>(
        &self,
        source: &Arc<LyraReaderDocument>,
        validate_file: bool,
        action: impl FnOnce(&DocumentCache, String) -> Result<T, String>,
    ) -> Result<T, String> {
        let _edits = self
            .edits
            .lock()
            .map_err(|_| "Page-edit state is unavailable")?;
        if !Arc::ptr_eq(&self.active()?, source) {
            return Err("The document changed before its reading history operation.".into());
        }
        let marks = self
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")?;
        if validate_file {
            marks.validate_source()?;
        }
        action(marks.cache_location()?, source.document_identity().sha256)
    }

    pub(super) fn archive_translation(
        &self,
        source: &Arc<LyraReaderDocument>,
        record: ReadingRecord,
    ) -> Result<(), String> {
        self.with_reading_cache(source, true, |cache, sha| {
            if record.source_hash != sha {
                return Err("The PDF revision changed before archiving the translation.".into());
            }
            let _lease = lock_reading_workspace(&cache.directory)?;
            let path = cache.directory.join(WORKSPACE_FILE);
            let previous = read_optional(&path)?;
            let mut workspace = workspace(previous.as_deref(), sha)?;
            workspace.put(record)?;
            let bytes = workspace.encode()?;
            if read_optional(&path)? != previous {
                return Err(
                    "The AI reading workspace changed during the save. Its data was kept.".into(),
                );
            }
            if let Some(previous) = previous {
                atomic_write(
                    &cache.directory.join("ai-reading-workspace.previous.json"),
                    &previous,
                )?;
            }
            atomic_write(&path, &bytes)
        })
    }

    fn translations<T>(
        &self,
        source: &Arc<LyraReaderDocument>,
        validate_file: bool,
        action: impl FnOnce(&ReadingWorkspace) -> Result<T, String>,
    ) -> Result<T, String> {
        self.with_reading_cache(source, validate_file, |cache, sha| {
            let bytes = read_optional(&cache.directory.join(WORKSPACE_FILE))?;
            action(&workspace(bytes.as_deref(), sha)?)
        })
    }

    pub(super) fn translation_history(
        &self,
        source: &Arc<LyraReaderDocument>,
        selection: bool,
    ) -> Result<Value, String> {
        self.translations(source, false, |workspace| {
            Ok(Value::Array(workspace.translation_history(selection)?.into_iter().map(|record| {
                json!({"id": record.id, "excerpt": record.excerpt.chars().take(160).collect::<String>(),
                    "language": record.language, "modified": record.modified, "status": record.status,
                    "pages": record.pages})
            }).collect()))
        })
    }

    pub(super) fn translation_history_entry(
        &self,
        source: &Arc<LyraReaderDocument>,
        id: &str,
    ) -> Result<Value, String> {
        self.translations(source, false, |workspace| {
            let record = translation_record(workspace, id)?;
            if record.status == "partial" || record.originals.is_empty() {
                return Ok(json!({"id": record.id, "language": record.language, "status": record.status,
                    "can_replay": !record.source_hash.is_empty() && record.status != "sourceChanged",
                    "content": record.content, "blocks": []}));
            }
            let pairs =
                translation_blocks(&record.originals, &record.original_pages, &record.content);
            let (rows, warning) = match pairs {
                Ok(rows)
                    if !rows.is_empty() && rows.iter().all(|row| !row.translation.is_empty()) =>
                {
                    (rows_value(&rows), None)
                }
                Ok(_) => (
                    Value::Null,
                    Some("The saved response does not translate every source paragraph.".into()),
                ),
                Err(error) => (Value::Null, Some(error)),
            };
            Ok(
                json!({"id": record.id, "language": record.language, "status": record.status,
                "can_replay": !record.source_hash.is_empty() && record.status != "sourceChanged",
                "content": record.content, "blocks": rows, "warning": warning}),
            )
        })
    }

    pub(super) fn replay_translation_source(
        &self,
        source: &Arc<LyraReaderDocument>,
        id: &str,
        request: &mut AiPlanRequestRecord,
    ) -> Result<(), String> {
        self.translations(source, true, |workspace| {
            let record = translation_record(workspace, id)?;
            if record.source_hash.is_empty() {
                return Err(
                    "The saved translation has no verified PDF revision. Select the source again."
                        .into(),
                );
            }
            request.selection = workspace
                .task_selection(id)?
                .map(|range| AiSelectionRecord {
                    page: range.page,
                    start: range.start,
                    end: range.end,
                });
            request.action = if request.selection.is_some() {
                AiActionRecord::TranslateSelection
            } else {
                AiActionRecord::SummarizeDocument
            };
            request.language = Some(record.language);
            Ok(())
        })
    }
}

fn translation_record(workspace: &ReadingWorkspace, id: &str) -> Result<ReadingRecord, String> {
    workspace
        .records()
        .into_iter()
        .find(|record| record.id == id && record.kind == "translation")
        .ok_or_else(|| "The saved translation is unavailable.".into())
}

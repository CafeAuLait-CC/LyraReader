//! Local disk adapter for the shared reading workspace. Archive snapshots and replay are separate
//! from the command that sends an approved request.
use crate::document::DesktopDocument;
use crate::document_cache::{DocumentCache, atomic_write, lock_reading_workspace, read_optional};
use lyra_reader_ai::workspace::{
    ReadingRecord, ReadingWorkspace, TranslationBlock, reading_scope_key, translation_blocks,
};
use lyra_reader_ffi::api::{
    AiActionRecord, AiPlanRecord, AiPlanRequestRecord, AiSelectionRecord, AiSourceRecord,
    LyraReaderDocument,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fmt::Write;
use std::sync::Arc;

pub(super) const WORKSPACE_FILE: &str = "ai-reading-workspace.json";

#[derive(Deserialize)]
pub(super) struct ChatInput {
    session_id: String,
    expected_modified: Option<u64>,
    question: String,
    #[serde(default)]
    draft_snapshot: Option<String>,
}

pub(super) struct ChatArchive {
    session_id: String,
    expected_modified: Option<u64>,
    source_hash: String,
    draft_snapshot: String,
    turn: ChatTurn,
}

struct ChatTurn {
    id: String,
    question: String,
    answer: String,
    state: String,
    sources: Vec<AiSourceRecord>,
}

impl ChatInput {
    pub fn capture(self, plan: &AiPlanRecord, source_hash: String) -> Result<ChatArchive, String> {
        if lyra_reader_edit::records::normalize_uuid(&self.session_id).is_none() {
            return Err("The chat session identifier is invalid.".into());
        }
        let draft_snapshot = self.draft_snapshot.unwrap_or_else(|| self.question.clone());
        Ok(ChatArchive {
            session_id: self.session_id,
            expected_modified: self.expected_modified,
            source_hash,
            draft_snapshot,
            turn: ChatTurn {
                id: crate::marks::uuid()?,
                question: self.question,
                answer: String::new(),
                state: String::new(),
                sources: plan.sources.clone(),
            },
        })
    }
}

impl ChatArchive {
    pub fn with_reply(mut self, replies: &[String], state: &str) -> Self {
        self.turn.answer = replies.join("\n\n");
        self.turn.state = state.into();
        self
    }
}

#[derive(Deserialize, Serialize)]
pub(super) struct ReadingScope {
    pub selection: Option<AiSelectionRecord>,
    pub language: String,
    pub detail: String,
}

pub(super) struct PendingTranslation {
    record: ReadingRecord,
    request_pages: Vec<Vec<u32>>,
}

impl ReadingScope {
    pub fn capture_translation(
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

fn chat_revision<'a>(
    records: &'a [ReadingRecord],
    id: &str,
    expected: Option<u64>,
    sha: &str,
) -> Result<(Option<&'a ReadingRecord>, u64), String> {
    let old = records.iter().find(|record| record.id == id);
    if old.map(|record| record.modified) != expected
        || old.is_some_and(|record| record.kind != "conversation" || record.source_hash != sha)
    {
        return Err(
            "This chat changed in another window or PDF revision. Reopen it before saving.".into(),
        );
    }
    let now = u64::try_from(chrono::Utc::now().timestamp_millis())
        .map_err(|_| "The local clock cannot date the chat.")?;
    let modified = match old {
        Some(record) => now.max(
            record
                .modified
                .checked_add(1)
                .ok_or("The chat timestamp is outside its supported range.")?,
        ),
        None => now,
    };
    Ok((old, modified))
}

impl DesktopDocument {
    pub(super) fn with_reading_cache<T>(
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
        self.update_reading_workspace(source, |workspace, sha, _| {
            if record.source_hash != sha {
                return Err("The PDF revision changed before archiving the translation.".into());
            }
            workspace.put(record).map(|_| ())
        })
    }

    pub(super) fn update_reading_workspace<T>(
        &self,
        source: &Arc<LyraReaderDocument>,
        update: impl FnOnce(&mut ReadingWorkspace, &str, &DocumentCache) -> Result<T, String>,
    ) -> Result<T, String> {
        self.with_reading_cache(source, true, |cache, sha| {
            let _lease = lock_reading_workspace(&cache.directory)?;
            let path = cache.directory.join(WORKSPACE_FILE);
            let previous = read_optional(&path)?;
            let mut workspace = workspace(previous.as_deref(), sha.clone())?;
            let output = update(&mut workspace, &sha, cache)?;
            let bytes = workspace.encode()?;
            if read_optional(&path)? != previous {
                return Err(
                    "The AI reading workspace changed during the save. Its data was kept.".into(),
                );
            }
            if previous.as_deref() == Some(bytes.as_slice()) {
                return Ok(output);
            }
            if let Some(previous) = previous {
                atomic_write(
                    &cache.directory.join("ai-reading-workspace.previous.json"),
                    &previous,
                )?;
            }
            atomic_write(&path, &bytes)?;
            Ok(output)
        })
    }

    pub(super) fn read_workspace<T>(
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
        self.read_workspace(source, false, |workspace| {
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
        self.read_workspace(source, false, |workspace| {
            let record = translation_record(workspace, id)?;
            let selection = workspace.task_selection(id).is_ok_and(|range| range.is_some());
            if record.status == "partial" || record.originals.is_empty() {
                return Ok(json!({"id": record.id, "language": record.language, "status": record.status,
                    "can_replay": !record.source_hash.is_empty() && record.status != "sourceChanged",
                    "content": record.content, "blocks": [], "selection": selection}));
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
                "content": record.content, "blocks": rows, "warning": warning, "selection": selection}),
            )
        })
    }

    pub(super) fn replay_translation_source(
        &self,
        source: &Arc<LyraReaderDocument>,
        id: &str,
        request: &mut AiPlanRequestRecord,
    ) -> Result<(), String> {
        self.read_workspace(source, true, |workspace| {
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

    pub(super) fn chat_sessions(&self, source: &Arc<LyraReaderDocument>) -> Result<Value, String> {
        self.read_workspace(source, false, |workspace| {
            let mut sessions = workspace.records();
            sessions.retain(|record| {
                record.kind == "conversation"
                    && (record.status != "draft" || !record.question.is_empty())
            });
            sessions.sort_by_key(|record| std::cmp::Reverse(record.modified));
            Ok(json!(
                sessions
                    .into_iter()
                    .map(|session| json!({
                        "id": session.id, "title": session.title, "modified": session.modified,
                        "status": session.status
                    }))
                    .collect::<Vec<_>>()
            ))
        })
    }

    pub(super) fn chat_session(
        &self,
        source: &Arc<LyraReaderDocument>,
        id: &str,
    ) -> Result<Value, String> {
        self.read_workspace(source, false, |workspace| {
            let records = workspace.records();
            let session = records
                .iter()
                .find(|record| record.id == id && record.kind == "conversation")
                .ok_or("The saved chat session is unavailable.")?;
            let read_only = session.status == "sourceChanged" || session.source_hash.is_empty();
            let mut turns: Vec<_> = records
                .iter()
                .filter(|record| record.kind == "message" && record.conversation_id == id)
                .collect();
            turns.sort_by_key(|record| record.modified);
            let limit = lyra_reader_ai::chat::MAX_CHAT_HISTORY_TURNS;
            let limited = turns.len() > limit;
            if limited {
                turns.drain(..turns.len() - limit);
            }
            let mut remaining = 8 * 1024 * 1024;
            let previous_len = turns.len();
            let turns: Vec<_> = turns
                .into_iter()
                .rev()
                .take_while(|turn| {
                    let bytes = turn.content.len().saturating_add(turn.question.len());
                    if bytes > remaining {
                        return false;
                    }
                    remaining -= bytes;
                    true
                })
                .collect();
            let limited = limited || turns.len() != previous_len;
            let turns: Vec<_> = turns
                .into_iter()
                .rev()
                .map(|turn| {
                    let verified = !read_only && turn.source_hash == session.source_hash;
                    let sources: Vec<_> =
                        if verified {
                            turn.original_pages.iter().zip(&turn.originals)
                        .filter(|(page, _)| **page > 0 && **page <= source.page_count())
                        .map(|(page, snippet)| json!({"page":page,"snippet":snippet,"rects":[]}))
                        .collect()
                        } else {
                            Vec::new()
                        };
                    let state = match (verified, turn.status.as_str()) {
                        (false, _) => "archived",
                        (true, "finished") => "finished",
                        (true, "failed") => "failed",
                        (true, "cancelled") => "cancelled",
                        (true, _) if turn.content.is_empty() => "failed",
                        (true, _) => "partial",
                    };
                    json!({"id":turn.id,"question":turn.question,"answer":turn.content,
                    "state":state,"sources":sources,
                    "note_source":(state == "finished" && !turn.content.trim().is_empty()).then_some(&turn.id)})
                })
                .collect();
            Ok(
                json!({"id": session.id, "modified":session.modified, "draft":session.question,
                "turns":turns,"limited":limited,"read_only":read_only}),
            )
        })
    }

    pub(super) fn archive_chat(
        &self,
        source: &Arc<LyraReaderDocument>,
        archive: ChatArchive,
    ) -> Result<Value, String> {
        self.update_reading_workspace(source, |workspace, sha, _| {
            let records = workspace.records();
            if archive.source_hash != sha {
                return Err("The PDF revision changed before archiving the chat.".into());
            }
            let (old, modified) = chat_revision(
                &records,
                &archive.session_id,
                archive.expected_modified,
                sha,
            )?;
            let turn = archive.turn;
            if turn.id == archive.session_id || records.iter().any(|record| record.id == turn.id) {
                return Err("The archived chat exchange has a duplicate identity.".into());
            }
            let title = old.map_or_else(
                || turn.question.trim().chars().take(120).collect(),
                |record| record.title.clone(),
            );
            let checkpoint = json!({"modified":modified,"state":turn.state,
                "note_source":(turn.state == "finished").then_some(&turn.id)});
            let (original_pages, originals) = turn
                .sources
                .into_iter()
                .filter(|item| {
                    !turn.answer.trim().is_empty()
                        && item.page > 0
                        && item.page <= source.page_count()
                })
                .map(|item| (item.page, item.snippet))
                .unzip::<_, _, Vec<_>, Vec<_>>();
            workspace.put_all(vec![
                ReadingRecord {
                    id: turn.id,
                    kind: "message".into(),
                    conversation_id: archive.session_id.clone(),
                    question: turn.question.clone(),
                    content: turn.answer,
                    pages: original_pages.clone(),
                    originals,
                    original_pages,
                    status: turn.state,
                    source_hash: sha.into(),
                    modified,
                    ..ReadingRecord::default()
                },
                ReadingRecord {
                    id: archive.session_id,
                    kind: "conversation".into(),
                    title,
                    question: archive.draft_snapshot,
                    source_hash: sha.into(),
                    status: "finished".into(),
                    modified,
                    ..ReadingRecord::default()
                },
            ])?;
            Ok(checkpoint)
        })
    }

    pub(super) fn save_chat_draft(
        &self,
        source: &Arc<LyraReaderDocument>,
        draft: ChatInput,
    ) -> Result<Value, String> {
        if lyra_reader_edit::records::normalize_uuid(&draft.session_id).is_none() {
            return Err("The chat session identifier is invalid.".into());
        }
        self.update_reading_workspace(source, |workspace, sha, _| {
            let records = workspace.records();
            let (old, modified) =
                chat_revision(&records, &draft.session_id, draft.expected_modified, sha)?;
            let mut record = old.cloned().unwrap_or_else(|| ReadingRecord {
                id: draft.session_id,
                kind: "conversation".into(),
                status: "draft".into(),
                source_hash: sha.into(),
                ..ReadingRecord::default()
            });
            if record.status == "draft" {
                record.title = draft.question.trim().chars().take(120).collect();
            }
            record.question = draft.question;
            record.modified = modified;
            workspace.put(record)?;
            Ok(json!({"modified":modified}))
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

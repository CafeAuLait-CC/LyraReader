//! Native storage adapter for the shared reading-note records.
use crate::document::DesktopDocument;
use lyra_reader_ai::workspace::{ReadingRecord, ReadingWorkspace};
use lyra_reader_ffi::api::{
    AiActionRecord, AiConversationTurnRecord, AiPlanRecord, AiPlanRequestRecord,
    AiReadingOptionsRecord, AiWireTransport, LyraReaderDocument, ai_reading_note_input,
    render_ai_plan,
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::sync::Arc;

#[derive(Deserialize)]
pub(super) struct NoteDraft {
    id: String,
    expected_modified: String,
    title: Option<String>,
    content: Option<String>,
    thoughts: Option<String>,
}

#[derive(Deserialize)]
pub(super) struct NoteReview {
    id: String,
    expected_modified: String,
    expected_suggestion: u32,
    apply: bool,
}

pub(super) struct PendingNote {
    token: String,
    note_id: String,
    note_modified: u64,
    source_revision: u32,
    source_modified: u64,
    fingerprint: String,
    region_id: String,
    region_revision: String,
    covered_turns: u32,
    endpoint: String,
    wire_parts: Vec<[u8; 32]>,
}

impl PendingNote {
    pub(super) fn matches(&self, token: &str, plan: &AiPlanRecord, fingerprint: &str) -> bool {
        self.token == token
            && self.fingerprint == fingerprint
            && self.endpoint == plan.endpoint
            && self.wire_parts.len() == plan.parts.len()
            && self
                .wire_parts
                .iter()
                .zip(&plan.parts)
                .all(|(digest, part)| {
                    let actual: [u8; 32] = Sha256::digest(part.wire_body.as_bytes()).into();
                    actual == *digest
                })
    }
    fn original(&self, workspace: &ReadingWorkspace) -> Result<ReadingRecord, String> {
        let note = find_note(workspace, &self.note_id)?;
        let original = note_region_source(workspace, &note, &self.fingerprint)?;
        if note.modified != self.note_modified
            || original.revision != self.source_revision
            || original.modified != self.source_modified
        {
            return Err("The note or its suggestion changed. Preview it again.".into());
        }
        Ok(original)
    }
}

impl DesktopDocument {
    pub(super) fn prepare_note_review(
        &self,
        document: &Arc<LyraReaderDocument>,
        id: &str,
        mut request: AiPlanRequestRecord,
    ) -> Result<Value, String> {
        let fingerprint = document.document_identity().sha256;
        let (note, original) = self.read_workspace(document, true, |workspace| {
            let note = find_note(workspace, id)?;
            let original = note_region_source(workspace, &note, &fingerprint)?;
            if workspace.suggestion(id).is_some() {
                return Err("Review the existing suggestion before generating another.".into());
            }
            Ok((note, original))
        })?;
        let (page, question, covered_turns, region_revision) =
            self.with_reading_cache(document, true, |cache, sha| {
                crate::region_store::with_current_region(
                    cache,
                    document,
                    &sha,
                    &note.conversation_id,
                    None,
                    |region, revision| {
                        let count = u32::try_from(region.completed_turns().count())
                            .map_err(|_| "The saved discussion is too long.")?;
                        if count <= original.covered_turns {
                            return Err(
                                "This region has no new completed discussion to add.".into()
                            );
                        }
                        let bytes =
                            region
                                .completed_turns()
                                .try_fold(note.content.len(), |bytes, turn| {
                                    bytes
                                        .checked_add(turn.question.len())?
                                        .checked_add(turn.answer.len())
                                });
                        if bytes.is_none_or(|bytes| bytes > 16 * 1024 * 1024) {
                            return Err(
                                "This discussion exceeds the supported reading-task size.".into()
                            );
                        }
                        let turns = region
                            .completed_turns()
                            .map(|turn| AiConversationTurnRecord {
                                question: turn.question.into(),
                                answer: turn.answer.into(),
                            })
                            .collect();
                        Ok((
                            region.attachment.page,
                            ai_reading_note_input(turns, note.content),
                            count,
                            revision,
                        ))
                    },
                )
            })?;
        request.action = AiActionRecord::SummarizeDocument;
        request.current_page = page;
        request.selection = None;
        request.region = None;
        request.history.clear();
        request.document_knowledge = false;
        request.document_knowledge_text = None;
        request.document_knowledge_pages.clear();
        request.question = Some(question);
        let plan = document
            .prepare_ai_reading_task(
                request,
                AiReadingOptionsRecord {
                    kind: "note".into(),
                    detail: "Standard".into(),
                },
            )
            .and_then(|plan| render_ai_plan(plan, AiWireTransport::ChatCompletions))
            .map_err(|error| error.to_string())?;
        let capture = PendingNote {
            token: crate::marks::uuid()?,
            note_id: id.into(),
            note_modified: note.modified,
            source_revision: original.revision,
            source_modified: original.modified,
            fingerprint,
            region_id: note.conversation_id,
            region_revision,
            covered_turns,
            endpoint: plan.endpoint.clone(),
            wire_parts: plan
                .parts
                .iter()
                .map(|part| Sha256::digest(part.wire_body.as_bytes()).into())
                .collect(),
        };
        let mut result = serde_json::to_value(plan).map_err(|error| error.to_string())?;
        result["kind"] = json!("reading_note_suggestion");
        result["note_id"] = json!(capture.note_id);
        result["note_capture"] = json!(capture.token);
        *self
            .pending_note
            .lock()
            .map_err(|_| "Note review state is unavailable.")? = Some(capture);
        Ok(result)
    }

    pub(super) fn validate_note_review(
        &self,
        document: &Arc<LyraReaderDocument>,
        capture: &PendingNote,
    ) -> Result<(), String> {
        self.read_workspace(document, true, |workspace| {
            capture.original(workspace).map(|_| ())
        })?;
        self.with_reading_cache(document, true, |cache, sha| {
            crate::region_store::with_current_region(
                cache,
                document,
                &sha,
                &capture.region_id,
                Some(&capture.region_revision),
                |_, _| Ok(()),
            )
        })
    }

    pub(super) fn publish_note_review(
        &self,
        document: &Arc<LyraReaderDocument>,
        capture: PendingNote,
        answer: String,
    ) -> Result<Value, String> {
        self.update_reading_workspace(document, |workspace, sha, cache| {
            let mut original=capture.original(workspace)?;
            crate::region_store::with_current_region(cache,document,sha,&capture.region_id,Some(&capture.region_revision),|_,_|Ok(()))?;
            original.modified = next_note_modified(original.modified)?;
            original.covered_turns = capture.covered_turns;
            original.content=answer;
            workspace.put(original)?;
            Ok(json!({"id":capture.note_id,"available":workspace.suggestion(&capture.note_id).is_some()}))
        })
    }

    pub(super) fn resolve_note_review(
        &self,
        document: &Arc<LyraReaderDocument>,
        review: NoteReview,
    ) -> Result<Value, String> {
        self.update_reading_workspace(document, |workspace, sha, _| {
            let note = find_note(workspace, &review.id)?;
            let suggestion = workspace.suggestion(&review.id).filter(|record| {
                record.source_hash == sha && record.revision == review.expected_suggestion
            });
            if note.source_hash != sha
                || review.expected_modified.parse::<u64>().ok() != Some(note.modified)
                || suggestion.is_none()
            {
                return Err(
                    "The note or suggestion changed. Open it again before applying changes.".into(),
                );
            }
            let saved = workspace.apply_suggestion(
                &review.id,
                review.apply,
                next_note_modified(note.modified)?,
            )?;
            Ok(note_value(workspace, saved, document))
        })
    }

    pub(super) fn keep_region_note(
        &self,
        document: &Arc<LyraReaderDocument>,
        id: &str,
        reviewed_revision: &str,
    ) -> Result<Value, String> {
        self.update_reading_workspace(document, |workspace, sha, cache| {
            let current = crate::region_store::reading_note_source(
                cache,
                document,
                sha,
                id,
                reviewed_revision,
            )?;
            let original = match workspace
                .records()
                .into_iter()
                .find(|record| record.id == current.id)
            {
                Some(record) if record.source_hash == sha && record.kind == current.kind => record,
                Some(_) => {
                    return Err("This region note belongs to a different PDF revision.".into());
                }
                None => workspace.put(current)?,
            };
            let note = workspace.keep(original, crate::marks::uuid()?)?;
            Ok(json!({"id":note.id,"title":note.title}))
        })
    }

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
            Ok(note_value(workspace, find_note(workspace, id)?, source))
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
                return Ok(note_value(workspace, note, source));
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
            note.modified = next_note_modified(note.modified)?;
            note.status = "saved".into();
            let saved = workspace.put(note)?;
            Ok(note_value(workspace, saved, source))
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

fn next_note_modified(previous: u64) -> Result<u64, String> {
    let now = u64::try_from(chrono::Utc::now().timestamp_millis())
        .map_err(|_| "The local clock cannot date the reading note.")?;
    Ok(now.max(
        previous
            .checked_add(1)
            .ok_or("The reading note version is outside the supported range.")?,
    ))
}

fn note_region_source(
    workspace: &ReadingWorkspace,
    note: &ReadingRecord,
    sha: &str,
) -> Result<ReadingRecord, String> {
    if note.source_hash != sha
        || note.source_id != format!("interleaf:{}", note.conversation_id)
        || note.conversation_id.is_empty()
    {
        return Err("This note has no current Interleaf discussion.".into());
    }
    workspace
        .records()
        .into_iter()
        .find(|record| {
            record.id == note.source_id
                && record.kind == "message"
                && record.conversation_id == note.conversation_id
                && record.source_hash == sha
        })
        .ok_or_else(|| "The original Interleaf note is unavailable.".into())
}

fn note_value(
    workspace: &ReadingWorkspace,
    note: ReadingRecord,
    source: &LyraReaderDocument,
) -> Value {
    let verified = note.source_hash == source.document_identity().sha256;
    let suggestion = verified
        .then(|| workspace.suggestion(&note.id))
        .flatten()
        .filter(|record| record.source_hash == note.source_hash)
        .map(|record| json!({"content":record.content,"revision":record.revision}));
    let discussion_available = verified
        && !note.conversation_id.is_empty()
        && note.source_id == format!("interleaf:{}", note.conversation_id);
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
        "modified":note.modified.to_string(),"status":status,"source_pages":pages,
        "suggestion":suggestion,"discussion_available":discussion_available})
}

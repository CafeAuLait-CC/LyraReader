//! Native storage adapter for the shared reading-note records.
use crate::document::{DesktopDocument, consolidation_request};
use lyra_reader_ai::workspace::{ReadingRecord, ReadingWorkspace, reading_scope_key};
use lyra_reader_ffi::api::{
    AiActionRecord, AiConversationTurnRecord, AiMergePlanRequestRecord, AiPlanRecord,
    AiPlanRequestRecord, AiReadingOptionsRecord, AiWireTransport, LyraReaderDocument,
    ai_reading_note_input, build_ai_merge_plan, render_ai_plan, style_ai_reading_plan,
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

struct SavedNoteTarget {
    id: String,
    modified: u64,
    source_revision: u32,
    source_modified: u64,
}

pub(super) struct PendingNote {
    token: String,
    target: Option<SavedNoteTarget>,
    fingerprint: String,
    region_id: String,
    region_revision: String,
    covered_turns: u32,
    endpoint: String,
    wire_parts: Vec<[u8; 32]>,
    consolidation: Option<Box<AiMergePlanRequestRecord>>,
    language: String,
}

impl PendingNote {
    pub(super) fn kind(&self) -> &'static str {
        if self.target.is_some() {
            "reading_note_suggestion"
        } else {
            "region_knowledge_note"
        }
    }
    pub(super) fn result_key(&self) -> &'static str {
        if self.target.is_some() {
            "note_suggestion"
        } else {
            "region_note_candidate"
        }
    }
    pub(super) fn needs_consolidation(&self) -> bool {
        self.consolidation.is_some()
    }
    fn preview_value(
        &self,
        plan: AiPlanRecord,
        final_consolidation: bool,
    ) -> Result<Value, String> {
        let mut result = serde_json::to_value(plan).map_err(|error| error.to_string())?;
        result["kind"] = json!(self.kind());
        if let Some(target) = &self.target {
            result["note_id"] = json!(target.id);
        } else {
            result["region_id"] = json!(self.region_id);
        }
        result["note_capture"] = json!(self.token);
        if final_consolidation {
            result["consolidation"] = json!(true);
        }
        Ok(result)
    }
    pub(super) fn consolidate(mut self, answers: Vec<String>) -> Result<(Self, Value), String> {
        let mut request = self
            .consolidation
            .take()
            .ok_or("The note has no consolidation request.")?;
        if request.parts.len() != answers.len() {
            return Err("The note synthesis is missing reviewed part responses.".into());
        }
        for (part, answer) in request.parts.iter_mut().zip(answers) {
            part.summary = answer;
        }
        let plan = build_ai_merge_plan(*request)
            .and_then(|plan| {
                style_ai_reading_plan(
                    plan,
                    "note".into(),
                    "Standard".into(),
                    self.language.clone(),
                )
            })
            .and_then(|plan| render_ai_plan(plan, AiWireTransport::ChatCompletions))
            .map_err(|error| error.to_string())?;
        self.endpoint = plan.endpoint.clone();
        self.wire_parts = plan
            .parts
            .iter()
            .map(|part| Sha256::digest(part.wire_body.as_bytes()).into())
            .collect();
        self.token = crate::marks::uuid()?;
        let preview = self.preview_value(plan, true)?;
        Ok((self, preview))
    }
    pub(super) fn matches(
        &self,
        token: &str,
        kind: &str,
        plan: &AiPlanRecord,
        fingerprint: &str,
    ) -> bool {
        self.kind() == kind
            && self.token == token
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
        let target = self
            .target
            .as_ref()
            .ok_or("This request does not target a saved reading note.")?;
        let note = find_note(workspace, &target.id)?;
        let original = note_region_source(workspace, &note, &self.fingerprint)?;
        if note.modified != target.modified
            || original.revision != target.source_revision
            || original.modified != target.source_modified
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
        reviewed_region: Option<&str>,
        mut request: AiPlanRequestRecord,
    ) -> Result<Value, String> {
        let fingerprint = document.document_identity().sha256;
        let saved = if reviewed_region.is_none() {
            Some(self.read_workspace(document, true, |workspace| {
                let note = find_note(workspace, id)?;
                let original = note_region_source(workspace, &note, &fingerprint)?;
                if workspace.suggestion(id).is_some() {
                    return Err("Review the existing suggestion before generating another.".into());
                }
                Ok((note, original))
            })?)
        } else {
            None
        };
        let region_id = saved
            .as_ref()
            .map_or(id, |(note, _)| note.conversation_id.as_str())
            .to_owned();
        let (page, question, covered_turns, region_revision) =
            self.with_reading_cache(document, true, |cache, sha| {
                crate::region_store::with_current_region(
                    cache,
                    document,
                    &sha,
                    &region_id,
                    reviewed_region,
                    |region, revision| {
                        let count = u32::try_from(region.completed_turns().count())
                            .map_err(|_| "The saved discussion is too long.")?;
                        let (previous, covered) = saved
                            .as_ref()
                            .map_or((region.knowledge_note.as_str(), 0), |(note, original)| {
                                (note.content.as_str(), original.covered_turns)
                            });
                        if count <= covered {
                            return Err(
                                "This region has no new completed discussion to add.".into()
                            );
                        }
                        let bytes =
                            region
                                .completed_turns()
                                .try_fold(previous.len(), |bytes, turn| {
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
                            ai_reading_note_input(turns, previous.to_owned()),
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
        let language = request.language.clone().unwrap_or_default();
        let reasoning_mode = request.reasoning_mode.clone();
        let reasoning_encoding = request.reasoning_encoding.clone();
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
        let consolidation = (plan.parts.len() > 1)
            .then(|| consolidation_request(&plan, reasoning_mode, reasoning_encoding).map(Box::new))
            .transpose()?;
        let capture = PendingNote {
            token: crate::marks::uuid()?,
            target: saved.map(|(note, original)| SavedNoteTarget {
                id: note.id,
                modified: note.modified,
                source_revision: original.revision,
                source_modified: original.modified,
            }),
            fingerprint,
            region_id,
            region_revision,
            covered_turns,
            endpoint: plan.endpoint.clone(),
            wire_parts: plan
                .parts
                .iter()
                .map(|part| Sha256::digest(part.wire_body.as_bytes()).into())
                .collect(),
            consolidation,
            language,
        };
        let result = capture.preview_value(plan, false)?;
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
        if capture.target.is_some() {
            self.read_workspace(document, true, |workspace| {
                capture.original(workspace).map(|_| ())
            })?;
        }
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
        let Some(target) = &capture.target else {
            self.validate_note_review(document, &capture)?;
            return Ok(
                json!({"id":capture.region_id,"revision":capture.region_revision,"content":answer}),
            );
        };
        self.update_reading_workspace(document, |workspace, sha, cache| {
            let mut original = capture.original(workspace)?;
            crate::region_store::with_current_region(
                cache,
                document,
                sha,
                &capture.region_id,
                Some(&capture.region_revision),
                |_, _| Ok(()),
            )?;
            original.modified = next_note_modified(original.modified)?;
            original.covered_turns = capture.covered_turns;
            original.content = answer;
            workspace.put(original)?;
            Ok(json!({"id":target.id,"available":workspace.suggestion(&target.id).is_some()}))
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
            Ok(note_value(workspace, saved, document, true))
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

    pub(super) fn archive_summary_task(
        &self,
        source: &Arc<LyraReaderDocument>,
        summary: ReadingRecord,
    ) -> Result<String, String> {
        let selected = summary.source_id != reading_scope_key(None);
        self.update_reading_workspace(source, |workspace, sha, _| {
            if summary.source_hash != sha {
                return Err(if selected {
                    "The selected summary no longer matches this document."
                } else {
                    "The document summary no longer matches this document."
                }
                .into());
            }
            let record = workspace.put(summary)?;
            if selected && workspace.task_selection(&record.id)?.is_none() {
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
            let origins = workspace
                .records()
                .into_iter()
                .map(|record| (record.id, (record.kind, record.source_id)))
                .collect::<std::collections::HashMap<_, _>>();
            Ok(json!(
                workspace
                    .notes(query, recent)
                    .into_iter()
                    .map(|note| {
                        let modified = note.modified;
                        let origin = origins.get(&note.source_id);
                        // Lists keep the established fields used by search/copy.
                        // Original answers are materialized only for one opened detail.
                        let mut value = note_value(workspace, note, source, false);
                        value["origin_kind"] = json!(origin.map(|record| &record.0));
                        value["origin_scope"] = json!(origin.map(|record| &record.1));
                        // Preserve the existing list wire type; the detail's edit version is a string.
                        value["modified"] = json!(modified);
                        value
                    })
                    .collect::<Vec<_>>()
            ))
        })
    }

    /// Read the shared, versioned task store in one batch. Opening history never writes
    /// a cache or constructs a provider request, and never invents trusted source pages.
    pub(super) fn reading_tasks(
        &self,
        source: &Arc<LyraReaderDocument>,
        kind: &str,
        source_id: Option<&str>,
    ) -> Result<Value, String> {
        self.read_workspace(source, false, |workspace| {
            let fingerprint = source.document_identity().sha256;
            Ok(json!(workspace.task_history(kind, source_id)?.into_iter().map(|record| {
                let verified = record.source_hash == fingerprint;
                let source_pages = if verified {
                    record.pages.iter().copied().filter(|page| *page > 0 && *page <= source.page_count()).collect::<Vec<_>>()
                } else { Vec::new() };
                json!({"id":record.id,"kind":record.kind,"source_id":record.source_id,
                    "title":record.title,"content":record.content,"excerpt":record.excerpt,
                    "pages":record.pages,"source_pages":source_pages,"language":record.language,
                    "detail":record.detail,"model":record.model,"modified":record.modified.to_string(),
                    "status":if verified { record.status.as_str() } else { "sourceChanged" }})
            }).collect::<Vec<_>>()))
        })
    }

    pub(super) fn reading_note(
        &self,
        source: &Arc<LyraReaderDocument>,
        id: &str,
    ) -> Result<Value, String> {
        self.read_workspace(source, false, |workspace| {
            Ok(note_value(
                workspace,
                find_note(workspace, id)?,
                source,
                true,
            ))
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
                return Ok(note_value(workspace, note, source, true));
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
            Ok(note_value(workspace, saved, source, true))
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
    include_context: bool,
) -> Value {
    let context = include_context.then(|| workspace.note_source(&note, source.page_count()));
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
    let mut value = json!({"id":note.id,"title":note.title,"content":note.content,"thoughts":note.thoughts,"source_id":note.source_id,
        "modified":note.modified.to_string(),"status":status,"source_pages":pages,
        "suggestion":suggestion,"discussion_available":discussion_available});
    if let Some(context) = context {
        value["origin_kind"] = json!(context.kind);
        value["origin_scope"] = json!(context.scope);
        value["source"] = json!(context);
    }
    value
}

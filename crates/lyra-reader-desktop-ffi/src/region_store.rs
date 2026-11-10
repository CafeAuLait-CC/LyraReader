//! Host I/O over portable region history. The existing DocumentId cache carries this file
//! through Save/Save As. PDF bytes and annotation dirty state are never changed here.
use crate::document::DesktopDocument;
use crate::document_cache::{DocumentCache, atomic_write, read_optional};
use fs2::FileExt;
use lyra_reader_ai::region_history::{AnswerState, Attachment, Entry, History, Turn};
use lyra_reader_ffi::api::{AiActionRecord, AiConversationTurnRecord, AiPlanRequestRecord};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

use lyra_reader_ai::{
    AiError,
    openai::{RequestAudit, RequestOutcome},
};

pub(super) struct RequestProvenance {
    id: String,
    turn: String,
    pages: Vec<u32>,
    attempted: AtomicBool,
}
struct TrackedRequest {
    audit: Arc<dyn RequestAudit>,
    proof: Arc<RequestProvenance>,
}
impl RequestAudit for TrackedRequest {
    fn started(&self) -> Result<(), AiError> {
        self.audit.started()?;
        // This is the same hook immediately before actual HTTP, after durable audit admission.
        // A preview, PartStarted event or failed audit cannot manufacture sent-source evidence.
        self.proof.attempted.store(true, Ordering::Release);
        Ok(())
    }
    fn finished(&self, outcome: RequestOutcome) -> Result<(), AiError> {
        self.audit.finished(outcome)
    }
}
pub(super) fn track_request(
    audit: Arc<dyn RequestAudit>,
    id: String,
    turn: String,
    pages: Vec<u32>,
) -> (Arc<dyn RequestAudit>, Arc<RequestProvenance>) {
    let proof = Arc::new(RequestProvenance {
        id,
        turn,
        pages,
        attempted: AtomicBool::new(false),
    });
    (
        Arc::new(TrackedRequest {
            audit,
            proof: Arc::clone(&proof),
        }),
        proof,
    )
}

const FILE: &str = "region-conversations-v1.json";
#[derive(Default)]
pub(super) struct RegionStore {
    path: Option<PathBuf>,
    baseline: Option<Vec<u8>>,
    history: History,
    error: Option<String>,
}
impl RegionStore {
    fn revision(&self) -> String {
        Sha256::digest(self.baseline.as_deref().unwrap_or(b""))
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }
    fn load(&mut self, cache: &DocumentCache) -> Result<(), String> {
        let path = cache.directory.join(FILE);
        if self.path.as_ref() == Some(&path) {
            return Ok(());
        }
        let bytes = read_optional(&path)?;
        if self.path.is_some() && bytes != self.baseline {
            return Err("Reading notes changed during the document's cache migration; both copies were kept".into());
        }
        let (history, error) = match &bytes {
            Some(bytes) => match History::decode(bytes) {
                Ok(h) => (h, None),
                Err(e) => (History::default(), Some(e)),
            },
            None => (History::default(), None),
        };
        self.path = Some(path);
        self.baseline = bytes;
        self.history = history;
        self.error = error;
        Ok(())
    }
    fn persist(&mut self, cache: &DocumentCache, next: History) -> Result<(), String> {
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        let path = self.path.as_ref().ok_or("Reading notes are not loaded")?;
        let lock_path = cache.directory.join(".region-conversations.lock");
        let mut options = fs::OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let lock = options.open(lock_path).map_err(|e| e.to_string())?;
        // Waiting on another process must not hang a native document command indefinitely.
        FileExt::try_lock_exclusive(&lock)
            .map_err(|e| format!("Another window is saving reading notes. Try again: {e}"))?;
        if read_optional(path)? != self.baseline {
            return Err("Reading notes changed outside this window. Reopen before editing; original data was kept".into());
        }
        let bytes = next.encode()?;
        if self.baseline.as_deref() == Some(&bytes) {
            return Ok(());
        }
        if let Some(previous) = &self.baseline {
            atomic_write(
                &cache
                    .directory
                    .join("region-conversations-v1.previous.json"),
                previous,
            )?;
        }
        atomic_write(path,&bytes).map_err(|e|format!("Could not finish saving reading notes; the previous file was backed up. Reopen to check the saved state: {e}"))?;
        self.baseline = Some(bytes);
        self.history = next;
        Ok(())
    }
}
fn now() -> f64 {
    chrono::Utc::now().timestamp_millis() as f64 / 1000.0 - 978_307_200.0
}
fn field<'a>(r: &'a Value, k: &str) -> Result<&'a str, String> {
    r[k].as_str()
        .ok_or_else(|| format!("Missing reading-note {k}"))
}
fn page(r: &Value, k: &str) -> Result<u32, String> {
    r[k].as_u64()
        .and_then(|n| u32::try_from(n).ok())
        .ok_or_else(|| format!("Invalid capture {k}"))
}
fn number(r: &Value, k: &str) -> Result<f64, String> {
    r[k].as_f64()
        .filter(|n| n.is_finite())
        .ok_or_else(|| format!("Invalid capture {k}"))
}
impl DesktopDocument {
    /// Use the stored snapshot and completed context at the same boundary as request planning.
    pub(super) fn enrich_region_history(
        &self,
        request: &mut AiPlanRequestRecord,
        id: Option<&str>,
        sha: &str,
    ) -> Result<(), String> {
        let Some(id) = id else {
            return Ok(());
        };
        if request.action != AiActionRecord::RegionQuestion {
            return Err("Saved region context only belongs to a region question".into());
        }
        let _edits = self
            .edits
            .lock()
            .map_err(|_| "Page-edit state is unavailable")?;
        let marks = self
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")?;
        let mut store = self
            .regions
            .lock()
            .map_err(|_| "Reading-note state is unavailable")?;
        store.load(marks.cache_location()?)?;
        if store.history.writes_blocked || store.error.is_some() {
            return Err("Reading notes are protected. Keep the saved capture and resolve the cache warning before continuing".into());
        }
        let entry = store.history.get(id)?;
        let active = self.active()?;
        if active.document_identity().sha256 != sha {
            return Err("The document changed while preparing the saved conversation".into());
        }
        entry.validate_reopen(active.page_count(), sha)?;
        let region = request
            .region
            .as_ref()
            .ok_or("The saved region capture is missing")?;
        let [[x, y], [width, height]] = entry.attachment.rect;
        active
            .validate_view_region(entry.attachment.page, (x, y, width, height))
            .map_err(|e| e.to_string())?;
        if region.page != entry.attachment.page
            || region.x_pt != x
            || region.y_pt != y
            || region.width_pt != width
            || region.height_pt != height
            || region.text != entry.attachment.text
        {
            return Err("The region changed. Reopen its saved capture before continuing".into());
        }
        if let Some(image) = region.image_png.as_deref() {
            let saved = lyra_reader_edit::records::base64_decode(&entry.attachment.png)
                .ok_or("The saved region picture is unavailable")?;
            if image != saved {
                return Err("The region picture changed. Reopen its saved capture".into());
            }
        }
        request.history = entry
            .completed_turns()
            .map(|turn| AiConversationTurnRecord {
                question: turn.question.into(),
                answer: turn.answer.into(),
            })
            .collect();
        Ok(())
    }
    pub(super) fn region_command(&self, op: &str, r: &Value) -> Result<Value, String> {
        let _edits = self
            .edits
            .lock()
            .map_err(|_| "Page-edit state is unavailable")?;
        let marks = self
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")?;
        let cache = marks.cache_location()?;
        let active = self.active()?;
        let identity = active.document_identity();
        let key = cache
            .directory
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or("Invalid document cache identity")?;
        let mut store = self
            .regions
            .lock()
            .map_err(|_| "Reading-note state is unavailable")?;
        store.load(cache)?;
        if op == "region_list" {
            let mut state = store.history.summaries(key, &identity.sha256)?;
            state["error"] = json!(store.error);
            state["revision"] = json!(store.revision());
            return Ok(state);
        }
        if op == "region_thumbnail" {
            if field(r, "expected_history_revision")? != store.revision() {
                return Err("Reading notes changed. Refresh the saved captures".into());
            }
            // Borrow just one validated attachment; a virtual list must not clone every PNG.
            let entry = store.history.get(field(r, "id")?)?;
            return Ok(json!({"id":entry.id,"revision":store.revision(),
                "png":entry.attachment.png,"width":entry.attachment.pixel_width,
                "height":entry.attachment.pixel_height}));
        }
        if op == "region_reopen" {
            if store.history.writes_blocked || store.error.is_some() {
                return Err(
                    "Reading notes are protected. Resolve the cache warning before continuing"
                        .into(),
                );
            }
            if field(r, "expected_history_revision")? != store.revision() {
                return Err("Reading notes changed. Choose the conversation again".into());
            }
            let entry = store.history.get(field(r, "id")?)?;
            entry.validate_reopen(active.page_count(), &identity.sha256)?;
            let a = &entry.attachment;
            let [[x, y], [width, height]] = a.rect;
            active
                .validate_view_region(a.page, (x, y, width, height))
                .map_err(|e| e.to_string())?;
            let latest=entry.turns.last().map(|turn|json!({"turn_id":turn.id,"question":turn.question,
                "output":turn.answer,"state":turn.state,"status":turn.error,
                "source_pages":entry.navigable_sources(entry.turns.len()-1,active.page_count(),&identity.sha256)}))
                .or_else(||(!entry.question.is_empty()).then(||json!({"turn_id":entry.id,"question":entry.question,
                    "output":entry.answer,"state":entry.state,"status":entry.error,"source_pages":[]})));
            return Ok(json!({"history_id":entry.id,"persisted":true,"saved":true,
                "question":entry.draft_question.as_deref().unwrap_or(""),"page":a.page,
                "x_pt":x,"y_pt":y,"width_pt":width,"height_pt":height,
                "text":a.text,"text_truncated":a.text_truncated,"image_png":a.png,
                "image_width_px":a.pixel_width,"image_height_px":a.pixel_height,
                "capture_scale":a.capture_scale,"source_sha256":identity.sha256,
                "latest_turn":latest,"completed_turn_count":entry.completed_turns().count()}));
        }
        if op == "region_get" {
            let entry = store
                .history
                .migrated_entries(key)?
                .into_iter()
                .find(|e| e.id == r["id"])
                .ok_or("This region is unavailable")?;
            let mut value = serde_json::to_value(&entry).map_err(|e| e.to_string())?;
            let [[x, y], [width, height]] = entry.attachment.rect;
            let reopen_error = entry
                .validate_reopen(active.page_count(), &identity.sha256)
                .and_then(|()| {
                    active
                        .validate_view_region(entry.attachment.page, (x, y, width, height))
                        .map_err(|e| e.to_string())
                })
                .err();
            value["can_reopen"] = json!(reopen_error.is_none());
            value["reopen_error"] = json!(reopen_error);
            value["locationInvalidated"] = json!(
                entry.location_invalidated == Some(true)
                    || entry
                        .capture_sha256
                        .as_deref()
                        .is_some_and(|s| s != identity.sha256)
            );
            value["verified_source_pages"] = json!(
                (0..entry.turns.len())
                    .map(|turn| entry.navigable_sources(
                        turn,
                        active.page_count(),
                        &identity.sha256
                    ))
                    .collect::<Vec<_>>()
            );
            return Ok(value);
        }
        if op == "region_export_markdown" {
            if let Some(error) = &store.error {
                return Err(error.clone());
            }
            if field(r, "expected_history_revision")? != store.revision() {
                return Err("Reading notes changed. Open the export dialog again to review the current snapshot".into());
            }
            let history_path = store.path.as_ref().ok_or("Reading notes are not loaded")?;
            let mut options = fs::OpenOptions::new();
            options.create(true).truncate(false).read(true).write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let lock = options
                .open(cache.directory.join(".region-conversations.lock"))
                .map_err(|e| e.to_string())?;
            FileExt::try_lock_shared(&lock).map_err(|e| {
                format!("Another window is saving reading notes. Try exporting again: {e}")
            })?;
            let verify = || {
                if read_optional(history_path)? != store.baseline {
                    Err("Reading notes changed outside this window. Reopen before exporting; existing data was kept".into())
                } else {
                    Ok(())
                }
            };
            verify()?;
            let destination = std::path::Path::new(field(r, "destination")?);
            let stem = destination
                .file_stem()
                .and_then(|s| s.to_str())
                .ok_or("Invalid export filename")?;
            let folder = lyra_reader_ai::region_export::image_folder(stem)?;
            let file = self
                .original_path
                .file_name()
                .and_then(|s| s.to_str())
                .ok_or("The source filename cannot be represented in Markdown")?;
            let title = self
                .original_path
                .file_stem()
                .and_then(|s| s.to_str())
                .ok_or("The source title cannot be represented in Markdown")?;
            let document = lyra_reader_ai::region_export::render(
                title,
                file,
                &store.history.migrated_entries(key)?,
                store.history.foreign_count(),
                now(),
                &folder,
            )?;
            let count = document.images.len();
            let omitted = document.omitted;
            let warning = crate::region_export::publish(destination, &folder, document, verify)?;
            return Ok(
                json!({"image_count":count,"omitted_count":omitted,"unavailable_count":store.history.foreign_count(),"warning":warning}),
            );
        }
        marks.validate_source()?;
        if let Some(error) = &store.error {
            return Err(error.clone());
        }
        let mut next = store.history.clone();
        let id = field(r, "id")?.to_owned();
        if op == "region_delete" {
            next.remove(&id)?;
        } else {
            let mut entry = if op == "region_create" {
                if next.entries().any(|e| e.id == id) {
                    return Err("This region is already saved; refresh the reading notes".into());
                }
                let a = &r["attachment"];
                if field(a, "source_sha256")? != identity.sha256 {
                    return Err(
                        "This region belongs to an older document revision; capture it again"
                            .into(),
                    );
                }
                let attachment = Attachment {
                    page: page(a, "page")?,
                    rect: [
                        [number(a, "x_pt")?, number(a, "y_pt")?],
                        [number(a, "width_pt")?, number(a, "height_pt")?],
                    ],
                    text: field(a, "text")?.into(),
                    png: field(a, "image_png")?.into(),
                    pixel_width: page(a, "image_width_px")?,
                    pixel_height: page(a, "image_height_px")?,
                    capture_scale: number(a, "capture_scale")?,
                    text_truncated: a["text_truncated"]
                        .as_bool()
                        .ok_or("Missing region truncation status")?,
                };
                if attachment.page >= active.page_count() {
                    return Err("The captured region is outside this document".into());
                }
                let number = next
                    .migrated_entries(key)?
                    .iter()
                    .filter_map(|e| e.region_number)
                    .max()
                    .unwrap_or(0)
                    .checked_add(1)
                    .ok_or("Region numbering overflow")?;
                Entry {
                    id: id.clone(),
                    document_key: key.into(),
                    attachment,
                    question: String::new(),
                    answer: String::new(),
                    state: AnswerState::Empty,
                    error: None,
                    failure: None,
                    created_at: now(),
                    turns: Vec::new(),
                    knowledge_note: String::new(),
                    region_number: Some(number),
                    draft_question: None,
                    location_invalidated: None,
                    capture_sha256: Some(identity.sha256.clone()),
                }
            } else {
                next.migrated_entries(key)?
                    .into_iter()
                    .find(|e| e.id == id)
                    .ok_or("This region is unavailable")?
            };
            match op {
                "region_create" | "region_snapshot" => {
                    entry.draft_question = Some(field(r, "draft")?.into());
                    if let Some(turn) = r.get("turn").filter(|t| !t.is_null()) {
                        entry.materialize_legacy_turn();
                        let turn_id = field(turn, "id")?.to_owned();
                        let state: AnswerState = serde_json::from_value(turn["state"].clone())
                            .map_err(|e| e.to_string())?;
                        let provenance = self
                            .ai_region_sources
                            .lock()
                            .map_err(|_| "Region request state is unavailable")?;
                        let sources = provenance
                            .as_ref()
                            .filter(|proof| {
                                proof.id == id
                                    && proof.turn == turn_id
                                    && proof.attempted.load(Ordering::Acquire)
                            })
                            .map(|proof| proof.pages.clone());
                        let previous = entry.turns.iter().find(|t| t.id == turn_id);
                        let record = Turn {
                            id: turn_id.clone(),
                            question: field(turn, "question")?.into(),
                            answer: field(turn, "answer")?.into(),
                            state,
                            error: turn.get("error").and_then(Value::as_str).map(str::to_owned),
                            created_at: previous.map(|t| t.created_at).unwrap_or_else(now),
                            source_pages: previous.and_then(|t| t.source_pages.clone()).or(sources),
                        };
                        if let Some(old) = previous {
                            let active_request = provenance
                                .as_ref()
                                .is_some_and(|proof| proof.id == id && proof.turn == turn_id);
                            old.validate_snapshot_replacement(&record, active_request)?;
                        }
                        entry.question = record.question.clone();
                        entry.answer = record.answer.clone();
                        entry.state = state;
                        entry.error = record.error.clone();
                        if let Some(old) = entry.turns.iter_mut().find(|t| t.id == turn_id) {
                            *old = record;
                        } else {
                            entry.turns.push(record);
                        }
                    }
                }
                "region_note" => entry.knowledge_note = field(r, "text")?.into(),
                _ => return Err("Unknown reading-note operation".into()),
            }
            next.put(entry)?;
        }
        store.persist(cache, next)?;
        let mut state = store.history.summaries(key, &identity.sha256)?;
        state["revision"] = json!(store.revision());
        state["saved_id"] = json!(id);
        if op != "region_delete" {
            state["saved_completed_turn_count"] =
                json!(store.history.get(&id)?.completed_turns().count());
        }
        if op == "region_note" {
            state["saved_note"] = r["text"].clone();
        }
        Ok(state)
    }
}

/// Save As carries local notes without replacing an existing destination's different history.
/// PDF publication has already succeeded; callers report this failure as a cache warning.
pub(super) fn carry_notes(
    source: &DocumentCache,
    destination: &DocumentCache,
) -> Result<(), String> {
    if source.directory == destination.directory {
        return Ok(());
    }
    let Some(bytes) = read_optional(&source.directory.join(FILE))? else {
        return Ok(());
    };
    let mut options = fs::OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let lock = options
        .open(destination.directory.join(".region-conversations.lock"))
        .map_err(|e| format!("The PDF was saved, but its reading-note lock is unavailable: {e}"))?;
    FileExt::try_lock_exclusive(&lock).map_err(|e| {
        format!("The PDF was saved, but another window is saving destination reading notes: {e}")
    })?;
    let path = destination.directory.join(FILE);
    match read_optional(&path)? {
        Some(existing) if existing!=bytes=>Err("The PDF was saved, but destination reading notes differ. Both versions were kept in their original caches".into()),
        Some(_)=>Ok(()),
        None=>atomic_write(&path,&bytes).map_err(|e|format!("The PDF was saved, but reading notes could not be carried to the copy. Original notes were kept: {e}")),
    }
}

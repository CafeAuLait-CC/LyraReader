//! Portable region-conversation records. Unedited and foreign records retain their exact bytes.
//!
//! The legacy shape follows AIRegionHistoryEntry and Foundation's unkeyed CGRect encoding
//! ([[x,y],[width,height]]). Dates are seconds since 2001, not Unix seconds. File I/O and
//! DocumentId ownership stay with the host's existing document cache.
use lyra_reader_edit::records::{
    normalize_uuid, parse_array_elements, render_string, swift_number,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashSet;

pub const MAX_HISTORY_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_ENTRIES: usize = 1024;
const MAX_TURNS: usize = 512;
const MAX_TEXT_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnswerState {
    Finished,
    Cancelled,
    Failed,
    Empty,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Attachment {
    pub page: u32,
    /// Page-local view points, y down. Foundation CGRect consists of origin and size arrays.
    pub rect: [[f64; 2]; 2],
    pub text: String,
    pub png: String,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub capture_scale: f64,
    #[serde(default)]
    pub text_truncated: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Turn {
    pub id: String,
    pub question: String,
    pub answer: String,
    pub state: AnswerState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub created_at: f64,
    /// None means legacy/unverified. Only the host's actual sent plan can supply these pages.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_pages: Option<Vec<u32>>,
}

impl Turn {
    /// Only the host's current request can extend an unfinished snapshot. Final and
    /// orphaned historical exchanges remain immutable, including after reopening.
    pub fn validate_snapshot_replacement(
        &self,
        next: &Self,
        active_request: bool,
    ) -> Result<(), String> {
        if self.id != next.id
            || self.created_at != next.created_at
            || (self.source_pages.is_some() && self.source_pages != next.source_pages)
        {
            return Err("The saved turn identity, date or verified sources changed".into());
        }
        if self.question == next.question
            && self.answer == next.answer
            && self.state == next.state
            && self.error == next.error
        {
            return Ok(());
        }
        if active_request
            && self.state == AnswerState::Empty
            && self.error.is_none()
            && self.question == next.question
            && next.answer.starts_with(&self.answer)
        {
            return Ok(());
        }
        Err(
            "This answer was already saved with different contents; the historical turn was kept"
                .into(),
        )
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Entry {
    pub id: String,
    pub document_key: String,
    pub attachment: Attachment,
    pub question: String,
    pub answer: String,
    pub state: AnswerState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Swift's synthesized enum payload is retained, never inferred from an English message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<Value>,
    pub created_at: f64,
    #[serde(default)]
    pub turns: Vec<Turn>,
    #[serde(default)]
    pub knowledge_note: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub region_number: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub draft_question: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub location_invalidated: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capture_sha256: Option<String>,
}
pub struct DisplayTurn<'a> {
    pub question: &'a str,
    pub answer: &'a str,
    pub state: AnswerState,
}
impl Entry {
    /// The legacy producer stored one turn in the top-level fields, without a turns array.
    pub fn display_turns(&self) -> impl Iterator<Item = DisplayTurn<'_>> {
        let legacy = (self.turns.is_empty() && !self.question.is_empty()).then_some(DisplayTurn {
            question: &self.question,
            answer: &self.answer,
            state: self.state,
        });
        legacy
            .into_iter()
            .chain(self.turns.iter().map(|turn| DisplayTurn {
                question: &turn.question,
                answer: &turn.answer,
                state: turn.state,
            }))
    }
    pub fn has_answer(&self) -> bool {
        !self.knowledge_note.is_empty()
            || self
                .display_turns()
                .any(|turn| !turn.answer.trim().is_empty())
    }
    /// Completed exchanges are eligible request context; partial/error records remain readable.
    pub fn completed_turns(&self) -> impl Iterator<Item = DisplayTurn<'_>> {
        self.display_turns()
            .filter(|turn| turn.state == AnswerState::Finished && !turn.answer.is_empty())
    }
    pub fn validate_reopen(&self, page_count: u32, sha: &str) -> Result<(), String> {
        if self.location_invalidated == Some(true) || self.capture_sha256.as_deref() != Some(sha) {
            return Err("The saved region's document revision is unavailable. Its capture remains in Reading notes; select a new region to continue".into());
        }
        if self.attachment.page >= page_count {
            return Err("The saved region's original page is unavailable. Its conversation was kept in Reading notes".into());
        }
        Ok(())
    }
    /// Materialize the old top-level exchange before appending another turn.
    /// Its identity/time and missing provenance survive the explicit migration.
    pub fn materialize_legacy_turn(&mut self) {
        if self.turns.is_empty() && !self.question.is_empty() {
            self.turns.push(Turn {
                id: self.id.clone(),
                question: self.question.clone(),
                answer: self.answer.clone(),
                state: self.state,
                error: self.error.clone(),
                created_at: self.created_at,
                source_pages: None,
            });
        }
    }
    pub fn validate(&self) -> Result<(), String> {
        if normalize_uuid(&self.id).is_none()
            || !self.created_at.is_finite()
            || self.document_key.is_empty()
            || self.document_key.len() > 4096
            || self.region_number == Some(0)
            || self.turns.len() > MAX_TURNS
        {
            return Err("Invalid region identity, time or conversation count".into());
        }
        if self
            .capture_sha256
            .as_ref()
            .is_some_and(|s| s.len() != 64 || !s.bytes().all(|b| b.is_ascii_hexdigit()))
        {
            return Err("Invalid region capture revision".into());
        }
        let a = &self.attachment;
        let [[x, y], [w, h]] = a.rect;
        if ![x, y, w, h, a.capture_scale].iter().all(|n| n.is_finite())
            || x < 0.0
            || y < 0.0
            || w <= 0.0
            || h <= 0.0
            || !(x + w).is_finite()
            || !(y + h).is_finite()
            || a.capture_scale <= 0.0
            || a.pixel_width == 0
            || a.pixel_height == 0
            || a.pixel_width > 4096
            || a.pixel_height > 4096
            || u64::from(a.pixel_width) * u64::from(a.pixel_height) > 4_000_000
            || a.png.len() > crate::MAX_REGION_IMAGE_BYTES.div_ceil(3) * 4
            || a.text.len() > MAX_TEXT_BYTES
        {
            return Err("Invalid or oversized region attachment".into());
        }
        let png = lyra_reader_edit::records::base64_decode(&a.png)
            .ok_or("Invalid saved region PNG encoding")?;
        if png.len() > crate::MAX_REGION_IMAGE_BYTES
            || png.len() < 24
            || &png[..8] != b"\x89PNG\r\n\x1a\n"
            || &png[12..16] != b"IHDR"
            || png[16..20] != a.pixel_width.to_be_bytes()
            || png[20..24] != a.pixel_height.to_be_bytes()
        {
            return Err("Saved region PNG dimensions do not match its capture".into());
        }
        let mut ids = HashSet::new();
        for t in &self.turns {
            let id = normalize_uuid(&t.id).ok_or("Invalid region turn identity")?;
            if !ids.insert(id)
                || !t.created_at.is_finite()
                || t.source_pages
                    .as_ref()
                    .is_some_and(|p| p.len() > 4096 || p.contains(&0))
            {
                return Err("Invalid region turn time, sources or duplicate identity".into());
            }
            for s in [&t.question, &t.answer] {
                if s.len() > MAX_TEXT_BYTES {
                    return Err("Saved region text exceeds the local storage bound".into());
                }
            }
            if t.error.as_ref().is_some_and(|s| s.len() > MAX_TEXT_BYTES) {
                return Err("Saved region error exceeds the local storage bound".into());
            }
        }
        for s in [&self.question, &self.answer, &self.knowledge_note] {
            if s.len() > MAX_TEXT_BYTES {
                return Err("Saved region text exceeds the local storage bound".into());
            }
        }
        if self
            .draft_question
            .as_ref()
            .is_some_and(|s| s.len() > MAX_TEXT_BYTES)
            || self
                .error
                .as_ref()
                .is_some_and(|s| s.len() > MAX_TEXT_BYTES)
        {
            return Err("Saved region draft exceeds the local storage bound".into());
        }
        Ok(())
    }
    /// Missing provenance is deliberately empty; model-written page labels are not evidence.
    pub fn verified_sources(&self, turn: usize) -> &[u32] {
        self.turns
            .get(turn)
            .and_then(|t| t.source_pages.as_deref())
            .unwrap_or(&[])
    }
    /// One-based pages actually sent for this turn, valid only for the captured revision.
    /// An answer's page markers and an older capture without a fingerprint prove nothing.
    pub fn navigable_sources(&self, turn: usize, page_count: u32, sha: &str) -> Vec<u32> {
        if self.location_invalidated == Some(true)
            || self.capture_sha256.as_deref() != Some(sha)
            || self.attachment.page >= page_count
        {
            return Vec::new();
        }
        let mut pages: Vec<_> = self
            .verified_sources(turn)
            .iter()
            .copied()
            .filter(|page| *page > 0 && *page <= page_count)
            .collect();
        pages.sort_unstable();
        pages.dedup();
        pages
    }
}

#[derive(Clone)]
struct Slot {
    raw: String,
    entry: Option<Entry>,
    changed: bool,
}
#[derive(Clone, Default)]
pub struct History {
    slots: Vec<Slot>,
    pub warnings: Vec<String>,
    pub writes_blocked: bool,
}

impl History {
    pub fn decode(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > MAX_HISTORY_BYTES {
            return Err("Region history exceeds 64 MiB; original data was kept".into());
        }
        let elements = parse_array_elements(bytes)
            .map_err(|e| format!("Reading notes could not be read; original data was kept: {e}"))?;
        if elements.len() > MAX_ENTRIES {
            return Err("Region history contains too many entries; original data was kept".into());
        }
        let mut history = Self::default();
        let mut ids = HashSet::new();
        for raw in elements {
            let value: Value = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
            if let Some(id) = value
                .get("id")
                .and_then(Value::as_str)
                .and_then(normalize_uuid)
            {
                if !ids.insert(id) {
                    history.writes_blocked = true;
                    history
                        .warnings
                        .push("Duplicate region identities; writes are blocked".into());
                }
            } else {
                history.writes_blocked = true;
                history
                    .warnings
                    .push("A region identity is damaged; writes are blocked".into());
            }
            let foreign = has_foreign_fields(&value);
            let entry = if foreign {
                history.warnings.push(
                    "A reading note from another version was retained without editing".into(),
                );
                None
            } else {
                match serde_json::from_str::<Entry>(&raw) {
                    Ok(e) => match e.validate() {
                        Ok(()) => Some(e),
                        Err(error) => {
                            history.writes_blocked = true;
                            history.warnings.push(error);
                            None
                        }
                    },
                    Err(_error) => {
                        // Foreign fields/types are retained verbatim. No mutation of that entry is
                        // possible. Structurally incomplete known records block all writes as well.
                        history.writes_blocked = true;
                        history
                            .warnings
                            .push("A saved reading note is incomplete or incompatible. Writes are blocked; original records were kept".into());
                        None
                    }
                }
            };
            history.slots.push(Slot {
                raw,
                entry,
                changed: false,
            });
        }
        Ok(history)
    }
    pub fn entries(&self) -> impl Iterator<Item = &Entry> {
        self.slots.iter().filter_map(|s| s.entry.as_ref())
    }
    pub fn foreign_count(&self) -> usize {
        self.slots.iter().filter(|s| s.entry.is_none()).count()
    }
    pub fn get(&self, id: &str) -> Result<&Entry, String> {
        let id = normalize_uuid(id).ok_or("Invalid region identity")?;
        self.entries()
            .find(|e| normalize_uuid(&e.id).as_ref() == Some(&id))
            .ok_or_else(|| "This region is unavailable or belongs to another version".into())
    }
    /// A host uses this view only; migration is persisted with the next explicit change.
    pub fn migrated_entries(&self, key: &str) -> Result<Vec<Entry>, String> {
        let mut entries: Vec<_> = self.entries().cloned().collect();
        let mut next = self
            .slots
            .iter()
            .filter_map(|s| {
                serde_json::from_str::<Value>(&s.raw)
                    .ok()
                    .and_then(|v| v["regionNumber"].as_u64())
            })
            .try_fold(0u32, |max, n| {
                u32::try_from(n)
                    .map(|n| max.max(n))
                    .map_err(|_| "A saved region number exceeds this version's range")
            })?;
        next = next.max(
            entries
                .iter()
                .filter_map(|e| e.region_number)
                .max()
                .unwrap_or(0),
        );
        let mut order: Vec<_> = (0..entries.len()).collect();
        order.sort_by(|a, b| {
            entries[*a]
                .created_at
                .total_cmp(&entries[*b].created_at)
                .then_with(|| entries[*a].id.cmp(&entries[*b].id))
        });
        for i in order {
            entries[i].document_key = key.into();
            if entries[i].region_number.is_none() {
                next = next.checked_add(1).ok_or("Region numbering overflow")?;
                entries[i].region_number = Some(next);
            }
        }
        Ok(entries)
    }
    pub fn put(&mut self, entry: Entry) -> Result<(), String> {
        if self.writes_blocked {
            return Err("Reading-note writes are blocked; original records were kept".into());
        }
        entry.validate()?;
        let id = normalize_uuid(&entry.id).ok_or("Invalid region identity")?;
        if let Some(s) = self.slots.iter_mut().find(|s| {
            s.entry
                .as_ref()
                .and_then(|e| normalize_uuid(&e.id))
                .as_ref()
                == Some(&id)
        }) {
            s.entry = Some(entry);
            s.changed = true;
        } else {
            if self.slots.len() >= MAX_ENTRIES {
                return Err("The local region history is full; no records were removed".into());
            }
            // A foreign record with the same identity must never be replaced.
            if self.slots.iter().any(|s| {
                serde_json::from_str::<Value>(&s.raw)
                    .ok()
                    .and_then(|v| v["id"].as_str().and_then(normalize_uuid))
                    .as_ref()
                    == Some(&id)
            }) {
                return Err("This region belongs to another version; its data was kept".into());
            }
            self.slots.push(Slot {
                raw: String::new(),
                entry: Some(entry),
                changed: true,
            });
        }
        Ok(())
    }
    pub fn remove(&mut self, id: &str) -> Result<(), String> {
        if self.writes_blocked {
            return Err("Reading-note writes are blocked; original records were kept".into());
        }
        self.get(id)?;
        let id = normalize_uuid(id).ok_or("Invalid region identity")?;
        self.slots.retain(|s| {
            s.entry
                .as_ref()
                .and_then(|e| normalize_uuid(&e.id))
                .as_ref()
                != Some(&id)
        });
        Ok(())
    }
    pub fn encode(&self) -> Result<Vec<u8>, String> {
        if self.writes_blocked {
            return Err("Reading-note writes are blocked; original records were kept".into());
        }
        let mut output = String::from("[");
        for (i, s) in self.slots.iter().enumerate() {
            let text = if s.changed {
                foundation_json(
                    &serde_json::to_value(s.entry.as_ref().ok_or("Missing changed region")?)
                        .map_err(|e| e.to_string())?,
                )?
            } else {
                s.raw.clone()
            };
            let needed = output
                .len()
                .checked_add(text.len())
                .and_then(|n| n.checked_add(2))
                .ok_or("Region history size overflow")?;
            if needed > MAX_HISTORY_BYTES {
                return Err("Region history exceeds 64 MiB; no records were removed".into());
            }
            if i > 0 {
                output.push(',');
            }
            output.push_str(&text);
        }
        output.push(']');
        Ok(output.into_bytes())
    }
    pub fn summaries(&self, key: &str, sha: &str) -> Result<Value, String> {
        // Sort the presentation view only. Raw slots keep their original order and bytes.
        // Stable equal-date ordering also treats positive and negative zero alike.
        let mut entries = self.migrated_entries(key)?;
        entries.sort_by(|a, b| {
            if a.created_at == b.created_at {
                std::cmp::Ordering::Equal
            } else {
                b.created_at.total_cmp(&a.created_at)
            }
        });
        let entries = entries.into_iter().map(|e| {
            // Legacy single-turn records have no turns array, matching the producer's allTurns.
            let turns = e.display_turns().count();
            json!({
                "id": e.id,
                "page": e.attachment.page,
                "number": e.region_number,
                "created_at": e.created_at,
                "question": e.question.chars().take(160).collect::<String>(),
                "draft": e.draft_question.as_deref().unwrap_or("").chars().take(160).collect::<String>(),
                "state": e.state,
                "turns": turns,
                "has_note": !e.knowledge_note.is_empty(),
                "has_answer": e.has_answer(),
                "location_invalidated": e.location_invalidated == Some(true)
                    || e.capture_sha256.as_deref().is_some_and(|s| s != sha)
            })
        }).collect::<Vec<_>>();
        Ok(
            json!({"entries":entries,"foreign_count":self.foreign_count(),"warnings":self.warnings,"writes_blocked":self.writes_blocked}),
        )
    }
}

/// Deterministic compact encoding; legacy unedited records bypass this writer completely.
/// Foundation's default key order is unspecified, so compatibility assertions compare keys
/// semantically while freezing primitive/rectangle/date bytes and foreign entries exactly.
fn foundation_json(value: &Value) -> Result<String, String> {
    Ok(match value {
        Value::Null => "null".into(),
        Value::Bool(b) => b.to_string(),
        Value::String(s) => render_string(s),
        Value::Number(n) => {
            if n.is_i64() || n.is_u64() {
                n.to_string()
            } else {
                swift_number(n.as_f64().ok_or("Invalid region number")?)
            }
        }
        Value::Array(a) => format!(
            "[{}]",
            a.iter()
                .map(foundation_json)
                .collect::<Result<Vec<_>, _>>()?
                .join(",")
        ),
        Value::Object(o) => format!(
            "{{{}}}",
            o.iter()
                .map(|(k, v)| Ok(format!("{}:{}", render_string(k), foundation_json(v)?)))
                .collect::<Result<Vec<_>, String>>()?
                .join(",")
        ),
    })
}

fn has_foreign_fields(v: &Value) -> bool {
    fn extra(v: &Value, keys: &[&str]) -> bool {
        v.as_object()
            .is_some_and(|o| o.keys().any(|k| !keys.contains(&k.as_str())))
    }
    if extra(
        v,
        &[
            "id",
            "documentKey",
            "attachment",
            "question",
            "answer",
            "state",
            "error",
            "failure",
            "createdAt",
            "turns",
            "knowledgeNote",
            "regionNumber",
            "draftQuestion",
            "locationInvalidated",
            "captureSha256",
        ],
    ) || extra(
        &v["attachment"],
        &[
            "page",
            "rect",
            "text",
            "png",
            "pixelWidth",
            "pixelHeight",
            "captureScale",
            "textTruncated",
        ],
    ) {
        return true;
    }
    if v["turns"].as_array().is_some_and(|turns| {
        turns.iter().any(|t| {
            extra(
                t,
                &[
                    "id",
                    "question",
                    "answer",
                    "state",
                    "error",
                    "createdAt",
                    "sourcePages",
                ],
            )
        })
    }) {
        return true;
    }
    // Swift synthesized Codable enum payloads are objects with one empty-object case.
    if let Some(f) = v.get("failure").filter(|f| !f.is_null()) {
        return !f.as_object().is_some_and(|o| {
            o.len() == 1
                && o.iter().all(|(k, p)| {
                    ["other", "offline", "localServer"].contains(&k.as_str())
                        && p.as_object().is_some_and(|p| p.is_empty())
                })
        });
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Vec<u8> {
        include_bytes!("../../../tests/fixtures/region-history/legacy-synthetic.json").to_vec()
    }
    fn sample() -> Entry {
        History::decode(&fixture())
            .unwrap()
            .entries()
            .next()
            .unwrap()
            .clone()
    }
    #[test]
    fn only_the_current_unfinished_turn_can_grow_or_finish() {
        let turn = Turn {
            id: "00000000-0000-4000-8000-000000000001".into(),
            question: "Question".into(),
            answer: "partial".into(),
            state: AnswerState::Empty,
            error: None,
            created_at: 1.0,
            source_pages: None,
        };
        let mut next = turn.clone();
        next.answer.push_str(" answer");
        assert!(turn.validate_snapshot_replacement(&next, true).is_ok());
        assert!(turn.validate_snapshot_replacement(&next, false).is_err());
        next.question = "Changed".into();
        assert!(turn.validate_snapshot_replacement(&next, true).is_err());
        next.question = turn.question.clone();
        next.answer = "replacement".into();
        assert!(turn.validate_snapshot_replacement(&next, true).is_err());
        next.answer = turn.answer.clone();
        for state in [
            AnswerState::Finished,
            AnswerState::Cancelled,
            AnswerState::Failed,
        ] {
            next.state = state;
            assert!(turn.validate_snapshot_replacement(&next, true).is_ok());
            let mut later = next.clone();
            later.answer.push('!');
            assert!(next.validate_snapshot_replacement(&later, true).is_err());
            assert!(next.validate_snapshot_replacement(&next, false).is_ok());
        }
    }
    #[test]
    fn legacy_materialization_keeps_the_original_exchange_date_identity_and_missing_proof() {
        let mut entry = sample();
        entry.question = "LEGACY_QUESTION".into();
        entry.answer = "LEGACY_ANSWER".into();
        entry.state = AnswerState::Finished;
        entry.materialize_legacy_turn();
        assert_eq!(entry.turns.len(), 1);
        assert_eq!(entry.turns[0].id, entry.id);
        assert_eq!(entry.turns[0].created_at, entry.created_at);
        assert_eq!(entry.turns[0].question, "LEGACY_QUESTION");
        assert_eq!(entry.turns[0].answer, "LEGACY_ANSWER");
        assert!(entry.turns[0].source_pages.is_none());
        entry.materialize_legacy_turn();
        assert_eq!(entry.turns.len(), 1);
    }
    #[test]
    fn reopening_requires_a_known_revision_and_context_excludes_unfinished_turns() {
        let mut entry = sample();
        let sha = "a".repeat(64);
        assert!(entry.validate_reopen(1, &sha).is_err());
        entry.capture_sha256 = Some(sha.clone());
        assert!(entry.validate_reopen(1, &sha).is_ok());
        assert!(entry.validate_reopen(0, &sha).is_err());
        entry.location_invalidated = Some(true);
        assert!(entry.validate_reopen(1, &sha).is_err());
        entry.location_invalidated = None;
        entry.turns = [
            AnswerState::Finished,
            AnswerState::Cancelled,
            AnswerState::Failed,
            AnswerState::Empty,
        ]
        .into_iter()
        .enumerate()
        .map(|(i, state)| Turn {
            id: format!("00000000-0000-4000-8000-{:012}", i),
            question: format!("question {i}"),
            answer: format!("answer {i}"),
            state,
            error: None,
            created_at: i as f64,
            source_pages: None,
        })
        .collect();
        let completed: Vec<_> = entry.completed_turns().map(|t| t.answer).collect();
        assert_eq!(completed, ["answer 0"]);
    }
    #[test]
    fn source_navigation_needs_sent_turn_pages_and_the_same_capture_revision() {
        let mut entry = sample();
        entry.capture_sha256 = Some("a".repeat(64));
        entry.turns = vec![Turn {
            id: entry.id.clone(),
            question: "Synthetic question".into(),
            answer: "Unverified marker [p.99]".into(),
            state: AnswerState::Finished,
            error: None,
            created_at: 0.0,
            source_pages: Some(vec![2, 1, 2, 3, 0, u32::MAX]),
        }];
        let sha = "a".repeat(64);
        assert_eq!(entry.navigable_sources(0, 2, &sha), [1, 2]);
        assert!(entry.navigable_sources(1, 2, &sha).is_empty());
        assert!(entry.navigable_sources(0, 2, &"b".repeat(64)).is_empty());
        assert!(entry.navigable_sources(0, 0, &sha).is_empty());
        entry.location_invalidated = Some(true);
        assert!(entry.navigable_sources(0, 2, &sha).is_empty());
        entry.location_invalidated = None;
        entry.capture_sha256 = None;
        assert!(entry.navigable_sources(0, 2, &sha).is_empty());
        entry.capture_sha256 = Some(sha.clone());
        entry.turns[0].source_pages = None;
        assert!(entry.navigable_sources(0, 2, &sha).is_empty());
    }
    #[test]
    fn legacy_rectangle_date_and_unverified_sources_survive_without_reencoding() {
        let bytes = fixture();
        let history = History::decode(&bytes).unwrap();
        let entry = history.entries().next().unwrap();
        assert_eq!(entry.attachment.rect, [[10.25, 20.5], [4.0, 4.0]]);
        assert_eq!(entry.created_at, 804000000.5);
        assert_eq!(entry.attachment.text, "α/β\r\nA synthetic capture");
        assert_eq!(history.encode().unwrap(), bytes[..bytes.len() - 1]);
        assert!(entry.verified_sources(0).is_empty());
        let mut changed = history.clone();
        let mut entry = entry.clone();
        entry.draft_question = Some("New / draft".into());
        changed.put(entry).unwrap();
        let encoded = String::from_utf8(changed.encode().unwrap()).unwrap();
        assert!(encoded.contains("\"rect\":[[10.25,20.5],[4,4]]"));
        assert!(encoded.contains("\"createdAt\":804000000.5"));
        assert!(encoded.contains("New \\/ draft"));
        assert_eq!(
            History::decode(encoded.as_bytes())
                .unwrap()
                .entries()
                .next()
                .unwrap()
                .draft_question
                .as_deref(),
            Some("New / draft")
        );
    }
    #[test]
    fn foreign_nested_records_keep_exact_bytes_and_damaged_records_block_overwrite() {
        let good = String::from_utf8(fixture()).unwrap();
        let mut other: Value = serde_json::from_str(&good).unwrap();
        other[0]["id"] = json!("00000002-1111-4222-8333-000000000002");
        other[0]["attachment"]["future"] = json!({"number":1.0});
        let foreign = serde_json::to_string(&other[0])
            .unwrap()
            .replace("1.0", "1.000000")
            .replace("/", "\\/");
        let joined = format!("[{},{}]", &good[1..good.trim_end().len() - 1], foreign);
        let mut h = History::decode(joined.as_bytes()).unwrap();
        assert!(!h.writes_blocked);
        assert_eq!(h.foreign_count(), 1);
        let mut e = sample();
        e.knowledge_note = "Edited known record".into();
        h.put(e).unwrap();
        assert!(
            String::from_utf8(h.encode().unwrap())
                .unwrap()
                .contains(&foreign)
        );
        let bad = format!(
            "[{},{{\"id\":\"00000003-1111-4222-8333-000000000003\"}}]",
            &good[1..good.trim_end().len() - 1]
        );
        let mut h = History::decode(bad.as_bytes()).unwrap();
        assert_eq!(h.entries().count(), 1);
        assert!(h.writes_blocked);
        assert!(h.remove(&sample().id).is_err());
        assert!(h.encode().is_err());
        assert!(History::decode(b"[{broken").is_err());
    }
    #[test]
    fn migration_numbers_are_stable_without_regenerating_identity_time_or_sources() {
        let mut h = History::default();
        let mut a = sample();
        a.region_number = Some(7);
        h.put(a.clone()).unwrap();
        let mut b = a.clone();
        b.id = "00000002-1111-4222-8333-000000000002".into();
        b.region_number = None;
        b.created_at -= 1.0;
        h.put(b.clone()).unwrap();
        let migrated = h.migrated_entries("new-document-id").unwrap();
        assert_eq!(migrated[0].region_number, Some(7));
        assert_eq!(migrated[1].region_number, Some(8));
        assert_eq!(migrated[1].id, b.id);
        assert_eq!(migrated[1].created_at, b.created_at);
        assert_eq!(migrated[1].document_key, "new-document-id");
        assert!(migrated[0].verified_sources(0).is_empty());
        let mut duplicate: Value = serde_json::from_slice(&fixture()).unwrap();
        let repeated = duplicate[0].clone();
        duplicate.as_array_mut().unwrap().push(repeated);
        assert!(
            History::decode(&serde_json::to_vec(&duplicate).unwrap())
                .unwrap()
                .writes_blocked
        );
    }
    #[test]
    fn summary_view_is_newest_first_with_stable_ties_and_legacy_turn_counts() {
        let mut history = History::default();
        for (index, time) in [10.0, 30.0, 30.0, -0.0, 0.0].into_iter().enumerate() {
            let mut entry = sample();
            entry.id = format!("00000000-1111-4222-8333-{:012}", index + 1);
            entry.created_at = time;
            entry.turns.clear();
            entry.question = if index == 0 {
                String::new()
            } else {
                "Legacy question".into()
            };
            history.put(entry).unwrap();
        }
        let bytes = history.encode().unwrap();
        let view = history.summaries("current-key", &"a".repeat(64)).unwrap();
        let entries = view["entries"].as_array().unwrap();
        let ids: Vec<_> = entries.iter().map(|v| v["id"].as_str().unwrap()).collect();
        assert_eq!(
            ids,
            [2, 3, 1, 4, 5].map(|i| format!("00000000-1111-4222-8333-{i:012}"))
        );
        assert_eq!(entries[0]["turns"], 1);
        assert_eq!(entries[2]["turns"], 0);
        assert_eq!(history.encode().unwrap(), bytes);
    }
    #[test]
    fn malicious_attachment_geometry_and_lengths_are_rejected_before_decode_or_allocation() {
        for v in [f64::INFINITY, f64::NAN, -1.0, 0.0] {
            let mut e = sample();
            e.attachment.rect[1][0] = v;
            assert!(e.validate().is_err());
        }
        let mut e = sample();
        e.attachment.pixel_width = 4097;
        assert!(e.validate().is_err());
        e = sample();
        e.attachment.pixel_width = 7;
        assert!(e.validate().is_err());
        e = sample();
        e.attachment.png = "invalid".into();
        assert!(e.validate().is_err());
        e = sample();
        e.capture_sha256 = Some("../escape".into());
        assert!(e.validate().is_err());
        e = sample();
        e.turns.push(Turn {
            id: e.id.clone(),
            question: "q".into(),
            answer: "a [p.99]".into(),
            state: AnswerState::Finished,
            error: None,
            created_at: 0.0,
            source_pages: Some(vec![1]),
        });
        assert_eq!(e.verified_sources(0), &[1]);
        e.turns[0].source_pages = Some(vec![0]);
        assert!(e.validate().is_err());
    }
}

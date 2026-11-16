//! Durable reading tasks, conversations and notes. Native shells own presentation and I/O;
//! this module owns identity, versions, note deduplication, search and generation instructions.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ReadingRecord {
    pub id: String,
    /// summary, translation, conversation, message, or note.
    pub kind: String,
    /// The result/message/Interleaf session this record was derived from.
    pub source_id: String,
    pub conversation_id: String,
    pub title: String,
    pub content: String,
    pub thoughts: String,
    pub question: String,
    /// One-based pages actually used, never pages merely mentioned by a model.
    pub pages: Vec<u32>,
    pub excerpt: String,
    pub language: String,
    pub model: String,
    pub detail: String,
    pub status: String,
    pub modified: u64,
    pub revision: u32,
    pub source_revision: u32,
    pub originals: Vec<String>,
    pub original_pages: Vec<u32>,
    pub source_hash: String,
    pub covered_turns: u32,
    /// Older generated and edited content remains recoverable.
    pub versions: Vec<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ReadingWorkspace {
    records: Vec<ReadingRecord>,
    source_hash: String,
    #[serde(flatten)]
    extra: BTreeMap<String, serde_json::Value>,
}

impl ReadingWorkspace {
    pub fn decode(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > 64 * 1024 * 1024 {
            return Err(
                "The saved AI workspace exceeds the supported size. Its file was kept.".into(),
            );
        }
        let result: Self = serde_json::from_slice(bytes).map_err(|e| {
            format!("The saved AI workspace could not be read. Its file was kept: {e}")
        })?;
        for record in &result.records {
            validate_record(record)?;
        }
        Ok(result)
    }

    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let bytes = serde_json::to_vec(self)
            .map_err(|e| format!("Could not save the AI workspace: {e}"))?;
        if bytes.len() > 64 * 1024 * 1024 {
            return Err("The AI workspace is too large to save. Export your notes before adding more. The previous saved file is preserved.".into());
        }
        Ok(bytes)
    }

    pub fn bind_source(&mut self, fingerprint: String) {
        self.source_hash = fingerprint;
    }

    pub fn records(&self) -> Vec<ReadingRecord> {
        self.records
            .iter()
            .cloned()
            .map(|mut r| {
                if !r.source_hash.is_empty() && r.source_hash != self.source_hash {
                    r.status = "sourceChanged".into();
                }
                r
            })
            .collect()
    }

    pub fn put(&mut self, mut record: ReadingRecord) -> Result<ReadingRecord, String> {
        validate_record(&record)?;
        record.pages.sort_unstable();
        record.pages.dedup();
        if record.source_hash.is_empty() {
            record.source_hash = self.source_hash.clone();
        }
        if let Some(old) = self.records.iter_mut().find(|old| old.id == record.id) {
            record.versions = old.versions.clone();
            if old.content != record.content {
                record.versions.push(old.content.clone());
                record.revision = old
                    .revision
                    .checked_add(1)
                    .ok_or("The note has too many versions.")?;
            } else {
                record.revision = old.revision;
            }
            record.extra = old.extra.clone();
            *old = record.clone();
        } else {
            record.revision = 1;
            self.records.push(record.clone());
        }
        Ok(record)
    }

    /// A native save publishes a whole session atomically, never one file write per message.
    pub fn put_all(&mut self, records: Vec<ReadingRecord>) -> Result<(), String> {
        let mut next = self.clone();
        for record in records {
            next.put(record)?;
        }
        *self = next;
        Ok(())
    }

    /// Saving a result twice resolves to the same note and preserves all manual edits.
    pub fn keep(
        &mut self,
        source: ReadingRecord,
        note_id: String,
    ) -> Result<ReadingRecord, String> {
        if let Some(note) = self
            .records
            .iter()
            .find(|r| r.kind == "note" && r.source_id == source.id)
        {
            return Ok(note.clone());
        }
        let mut note = source;
        note.source_revision = note.revision;
        note.source_id = note.id;
        note.id = note_id;
        note.kind = "note".into();
        note.status = "saved".into();
        note.title = note_title(&note.content, &note.title);
        self.put(note)
    }

    pub fn suggestion(&self, note_id: &str) -> Option<ReadingRecord> {
        let note = self
            .records
            .iter()
            .find(|r| r.id == note_id && r.kind == "note")?;
        self.records
            .iter()
            .find(|r| r.id == note.source_id && r.revision > note.source_revision)
            .cloned()
    }

    pub fn apply_suggestion(
        &mut self,
        note_id: &str,
        apply: bool,
        modified: u64,
    ) -> Result<ReadingRecord, String> {
        let source = self
            .suggestion(note_id)
            .ok_or("There are no new ideas to apply.")?;
        let mut note = self
            .records
            .iter()
            .find(|r| r.id == note_id)
            .cloned()
            .ok_or("The note is unavailable.")?;
        if apply {
            note.content = source.content;
        }
        note.source_revision = source.revision;
        note.covered_turns = source.covered_turns;
        note.question = source.question;
        note.modified = modified;
        self.put(note)
    }

    pub fn notes(&self, query: &str, recent: bool) -> Vec<ReadingRecord> {
        let query = query.to_lowercase();
        let mut notes: Vec<_> = self
            .records()
            .into_iter()
            .filter(|r| {
                r.kind == "note"
                    && format!("{}\n{}\n{}", r.title, r.content, r.thoughts)
                        .to_lowercase()
                        .contains(&query)
            })
            .collect();
        if recent {
            notes.sort_by_key(|r| std::cmp::Reverse(r.modified));
        } else {
            notes.sort_by_key(|r| (r.pages.first().copied().unwrap_or(0), r.modified));
        }
        notes
    }
}

fn note_title(content: &str, fallback: &str) -> String {
    let line = content.lines().map(str::trim).find(|line| {
        !line.is_empty()
            && !matches!(
                line.trim_start_matches('#').trim(),
                "Overview" | "Key ideas" | "By section"
            )
    });
    match line {
        Some(line) => line
            .trim_start_matches(['#', '-', ' '])
            .chars()
            .take(80)
            .collect(),
        None => fallback.to_string(),
    }
}

pub fn document_fingerprint(path: &str) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let mut file = std::fs::File::open(path)
        .map_err(|e| format!("Could not inspect the source document: {e}"))?;
    let mut digest = Sha256::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let length = file
            .read(&mut buffer)
            .map_err(|e| format!("Could not inspect the source document: {e}"))?;
        if length == 0 {
            break;
        }
        digest.update(&buffer[..length]);
    }
    Ok(digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn validate_record(record: &ReadingRecord) -> Result<(), String> {
    if record.id.is_empty()
        || !matches!(
            record.kind.as_str(),
            "summary" | "translation" | "conversation" | "message" | "note"
        )
    {
        return Err("The AI record has an invalid identity or type.".into());
    }
    if record.pages.contains(&0) {
        return Err("AI source pages must be one-based.".into());
    }
    if record.content.len() > 16 * 1024 * 1024 {
        return Err("The AI record exceeds the supported size.".into());
    }
    Ok(())
}

/// Source identity is shared by every shell; request builders validate the actual range.
pub fn reading_scope_key(selection: Option<crate::SelectionRange>) -> String {
    match selection {
        None => "document".into(),
        Some(selection) => format!(
            "selection:{}:{}:{}",
            u64::from(selection.page) + 1,
            selection.start,
            selection.end
        ),
    }
}

/// A prereading choice gates every AI entry point, including inline conversations.
pub fn reading_gate(policy: &str, state: &str, has_cache: bool) -> Result<String, String> {
    if !matches!(policy, "ask" | "always" | "never") {
        return Err("Unknown document prereading preference.".into());
    }
    Ok(if state == "reading" || state == "preparing" {
        "wait"
    } else if has_cache || state == "skipped" || policy == "never" {
        "ready"
    } else if policy == "always" {
        "read"
    } else {
        "ask"
    }
    .into())
}

/// The actual request is decorated before rendering, so both transports preview these bytes.
pub fn reading_instructions(kind: &str, detail: &str, language: &str) -> Result<String, String> {
    let length = match detail {
        "Brief" => "Be brief: one overview and at most three key ideas.",
        "Standard" => "Give one overview, key ideas and concise section summaries.",
        "Detailed" => "Give an overview, key ideas, section summaries, evidence and limitations.",
        _ => return Err("Unknown summary detail level.".into()),
    };
    let language = if language.trim().is_empty() {
        "the document's language"
    } else {
        language.trim()
    };
    Ok(match kind {
        "summary" => format!(
            "\nReading task: {length} Use Markdown headings: Overview, Key ideas, By section. For a selection, explain its meaning and key ideas without inventing sections. Cite only the supplied pages using [p.N]. Respond in {language}."
        ),
        "translation" => format!(
            "\nReading task: translate the supplied text into {language}. Preserve all paragraphs, equations, variables, units and reference numbers. Use terminology consistently across the document. Return only the translation, with [p.N] source markers at paragraph boundaries. Do not summarise or add commentary."
        ),
        "term" => format!(
            "Explain the requested technical term in {language}. Use the supplied document passages as evidence, cite only their pages, and distinguish a general explanation from claims made by this document. Be concise."
        ),
        "note" => format!(
            "\nDistil the supplied discussion into a reading note in {language}. Start with a short descriptive Markdown heading, then key ideas and unresolved questions. Preserve evidence and valid page citations. Do not repeat the entire conversation."
        ),
        _ => return Err("Unknown reading task.".into()),
    })
}

#[derive(Clone, Debug, PartialEq)]
pub struct TranslationBlock {
    pub original: String,
    pub translation: String,
    pub page: u32,
}

/// Markers bind model output to actual source paragraphs. Missing or malformed markers never
/// cause a guessed pairing; the shell can show the raw partial response with an explanation.
pub fn translation_blocks(
    originals: &[String],
    pages: &[u32],
    response: &str,
) -> Result<Vec<TranslationBlock>, String> {
    if originals.len() != pages.len() {
        return Err("The translation source map is incomplete.".into());
    }
    let mut translated = BTreeMap::new();
    for section in response.split("<!--lyra:").skip(1) {
        let Some((index, content)) = section.split_once("-->") else {
            continue;
        };
        let Ok(index) = index.parse::<usize>() else {
            return Err("The translation returned an invalid paragraph reference.".into());
        };
        if index >= originals.len()
            || translated
                .insert(index, content.trim().to_string())
                .is_some()
        {
            return Err(
                "The translation returned an unknown or duplicate paragraph reference.".into(),
            );
        }
    }
    Ok(originals
        .iter()
        .zip(pages)
        .enumerate()
        .map(|(i, (original, page))| TranslationBlock {
            original: original.clone(),
            translation: translated.remove(&i).unwrap_or_default(),
            page: *page,
        })
        .collect())
}

/// Compose an update input from typed turns, independently of any native shell.
pub fn note_input(turns: &[crate::ConversationTurn], previous: &str) -> String {
    let mut text = format!(
        "Existing saved knowledge (preserve its useful ideas):\n{previous}\n\nComplete discussion:\n"
    );
    for turn in turns {
        text.push_str(&format!(
            "Reader: {}\nLyra: {}\n\n",
            turn.question, turn.answer
        ));
    }
    text
}

/// Candidate labels are copied from source text; clicking one explicitly requests an explanation.
pub fn translation_terms(originals: &[String]) -> Vec<String> {
    let mut terms = Vec::new();
    for word in originals
        .iter()
        .flat_map(|s| s.split(|c: char| !c.is_alphanumeric() && c != '-'))
    {
        if (2..=40).contains(&word.chars().count())
            && word.chars().any(char::is_uppercase)
            && !matches!(
                word,
                "The"
                    | "This"
                    | "That"
                    | "We"
                    | "Our"
                    | "In"
                    | "For"
                    | "With"
                    | "And"
                    | "These"
                    | "It"
            )
            && !terms.iter().any(|t| t == word)
        {
            terms.push(word.to_string());
            if terms.len() == 8 {
                break;
            }
        }
    }
    terms
}

#[cfg(test)]
mod tests {
    use super::*;
    fn source() -> ReadingRecord {
        ReadingRecord {
            id: "result:1".into(),
            kind: "summary".into(),
            content: "An idea".into(),
            ..Default::default()
        }
    }
    #[test]
    fn keeping_twice_preserves_edits_and_thoughts() {
        let mut w = ReadingWorkspace::default();
        let mut note = w.keep(source(), "note:1".into()).unwrap();
        note.content = "My corrected idea".into();
        note.thoughts = "Check the evidence".into();
        note = w.put(note).unwrap();
        assert_eq!(w.keep(source(), "note:2".into()).unwrap(), note);
        assert_eq!(w.notes("evidence", false).len(), 1);
        let restored = ReadingWorkspace::decode(&w.encode().unwrap()).unwrap();
        assert_eq!(restored.records(), w.records());
        assert_eq!(restored.records()[0].versions, vec!["An idea"]);
        w.bind_source("original-source".into());
        let mut fresh = source();
        fresh.id = "result:2".into();
        let fresh = w.put(fresh).unwrap();
        w.keep(fresh, "note:3".into()).unwrap();
        w.bind_source("revised-source".into());
        assert_eq!(w.notes("", false).last().unwrap().status, "sourceChanged");
    }
    #[test]
    fn future_workspace_and_record_fields_survive_edits() {
        let mut workspace = ReadingWorkspace::default();
        workspace.put(source()).unwrap();
        let mut json = serde_json::to_value(&workspace).unwrap();
        json["future_workspace"] = serde_json::json!({"enabled": true});
        json["records"][0]["future_record"] = serde_json::json!(["retained", 42]);
        let mut restored = ReadingWorkspace::decode(&serde_json::to_vec(&json).unwrap()).unwrap();
        let mut edited = restored.records()[0].clone();
        edited.content = "Edited".into();
        restored.put(edited).unwrap();
        let encoded: serde_json::Value =
            serde_json::from_slice(&restored.encode().unwrap()).unwrap();
        assert_eq!(encoded["future_workspace"], json["future_workspace"]);
        assert_eq!(
            encoded["records"][0]["future_record"],
            json["records"][0]["future_record"]
        );
    }
    #[test]
    fn corrupt_cache_is_not_an_empty_workspace() {
        assert!(
            ReadingWorkspace::decode(b"{bad")
                .unwrap_err()
                .contains("file was kept")
        );
        let mut s = source();
        s.pages = vec![0];
        assert!(ReadingWorkspace::default().put(s).is_err());
    }
    #[test]
    fn updated_ideas_require_an_explicit_application_and_keep_personal_thoughts() {
        let mut workspace = ReadingWorkspace::default();
        let mut initial = source();
        initial.covered_turns = 1;
        initial = workspace.put(initial).unwrap();
        let mut note = workspace.keep(initial.clone(), "note".into()).unwrap();
        note.thoughts = "Personal reasoning".into();
        note.content = "Hand edited knowledge".into();
        workspace.put(note).unwrap();
        let mut update = initial;
        update.content = "New distilled ideas".into();
        update.covered_turns = 3;
        workspace.put(update).unwrap();
        assert_eq!(
            workspace.notes("", false)[0].content,
            "Hand edited knowledge"
        );
        assert!(workspace.suggestion("note").is_some());
        let applied = workspace.apply_suggestion("note", true, 42).unwrap();
        assert_eq!(applied.content, "New distilled ideas");
        assert_eq!(applied.thoughts, "Personal reasoning");
        assert_eq!(applied.covered_turns, 3);
        assert!(applied.versions.contains(&"Hand edited knowledge".into()));
        assert!(workspace.suggestion("note").is_none());
    }
    #[test]
    fn prereading_never_allows_an_overlapping_action() {
        for policy in ["ask", "always", "never"] {
            assert_eq!(reading_gate(policy, "reading", false).unwrap(), "wait");
        }
        assert_eq!(reading_gate("ask", "idle", false).unwrap(), "ask");
        assert_eq!(reading_gate("always", "idle", false).unwrap(), "read");
        assert_eq!(reading_gate("never", "idle", false).unwrap(), "ready");
        assert_eq!(reading_gate("ask", "idle", true).unwrap(), "ready");
    }
}

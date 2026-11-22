//! Shared, source-bound document analysis. Shells execute tasks and perform disk I/O;
//! this module owns reuse, in-flight ownership, invalidation and durable serialization.

use crate::workspace::ReadingRecord;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use unicode_segmentation::UnicodeSegmentation;

pub const MAX_BYTES: usize = 32 * 1024 * 1024;
pub const ANALYSIS_PART_CHARS: usize = 24_000;
pub const FULL_CHAT_PREFIX_CHARS: usize = 12_000;

/// Summarizing already reads its approved source, translating needs original paragraphs, and
/// distilling a note needs its discussion. None should launch a second whole-document request.
pub fn needs_prior(kind: &str) -> bool {
    !matches!(kind, "summary" | "translation" | "note")
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Saved {
    version: u32,
    record: ReadingRecord,
    #[serde(flatten)]
    extra: BTreeMap<String, serde_json::Value>,
}

#[derive(Clone, Debug)]
struct Lease {
    token: u64,
    source: String,
    language: String,
    detail: String,
}

pub enum Claim {
    Start(u64),
    Ready(Box<ReadingRecord>),
    Waiting,
}

#[derive(Default)]
pub struct DocumentUnderstanding {
    saved: Option<Saved>,
    active: Option<Lease>,
    next_token: u64,
}

impl DocumentUnderstanding {
    pub fn load(&mut self, bytes: &[u8], source: &str) -> Result<bool, String> {
        if bytes.len() > MAX_BYTES {
            return Err("The saved document understanding is too large. Its file was kept.".into());
        }
        let saved: Saved = serde_json::from_slice(bytes).map_err(|e| {
            format!("Could not read the saved document understanding. Its file was kept: {e}")
        })?;
        if saved.version != 2 {
            return Err(
                "This document understanding uses an unsupported version. Its file was kept."
                    .into(),
            );
        }
        validate(&saved.record)?;
        if saved.record.source_hash != source {
            return Ok(false);
        }
        self.saved = Some(saved);
        Ok(true)
    }

    pub fn encode(&self) -> Result<Vec<u8>, String> {
        let saved = self
            .saved
            .as_ref()
            .ok_or("There is no completed document understanding to save.")?;
        let bytes = serde_json::to_vec(saved)
            .map_err(|e| format!("Could not save document understanding: {e}"))?;
        if bytes.len() > MAX_BYTES {
            return Err(
                "The document understanding exceeds the cache limit. The previous file was kept."
                    .into(),
            );
        }
        Ok(bytes)
    }

    pub fn record(&self, source: &str) -> Option<ReadingRecord> {
        self.saved
            .as_ref()
            .filter(|s| s.record.source_hash == source)
            .map(|s| s.record.clone())
    }

    pub fn reusable(&self, source: &str, language: &str, detail: &str) -> Option<ReadingRecord> {
        self.record(source)
            .filter(|r| same_language(&r.language, language) && r.detail == detail)
    }

    pub fn begin(
        &mut self,
        source: String,
        language: String,
        detail: String,
        force: bool,
    ) -> Result<Claim, String> {
        if source.len() != 64 || !source.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Err("The document analysis has no valid source fingerprint.".into());
        }
        if !matches!(detail.as_str(), "Brief" | "Standard" | "Detailed") {
            return Err("Unknown document analysis detail level.".into());
        }
        if self.active.as_ref().is_some_and(|l| l.source == source) {
            return Ok(Claim::Waiting);
        }
        if !force && let Some(record) = self.reusable(&source, &language, &detail) {
            return Ok(Claim::Ready(Box::new(record)));
        }
        self.next_token = self
            .next_token
            .checked_add(1)
            .ok_or("The analysis task counter is exhausted. Reopen the document.")?;
        let token = self.next_token;
        self.active = Some(Lease {
            token,
            source,
            language,
            detail,
        });
        Ok(Claim::Start(token))
    }

    /// Only a completed, current task may publish. Cancellation cannot clear a newer lease.
    pub fn finish(&mut self, token: u64, mut record: ReadingRecord) -> Result<bool, String> {
        let Some(lease) = &self.active else {
            return Ok(false);
        };
        if lease.token != token {
            return Ok(false);
        }
        if record.source_hash != lease.source
            || !same_language(&record.language, &lease.language)
            || record.detail != lease.detail
        {
            return Err(
                "The completed analysis does not match its source or requested format.".into(),
            );
        }
        validate(&record)?;
        if let Some(old) = self
            .saved
            .as_ref()
            .filter(|s| s.record.source_hash == record.source_hash)
        {
            for (key, value) in &old.record.extra {
                record
                    .extra
                    .entry(key.clone())
                    .or_insert_with(|| value.clone());
            }
        }
        // Preserve unknown cache metadata when replacing the same source's generated analysis.
        let extra = self
            .saved
            .as_ref()
            .filter(|s| s.record.source_hash == record.source_hash)
            .map(|s| s.extra.clone())
            .unwrap_or_default();
        self.saved = Some(Saved {
            version: 2,
            record,
            extra,
        });
        self.active = None;
        Ok(true)
    }

    pub fn cancel(&mut self, token: u64) {
        if self.active.as_ref().is_some_and(|l| l.token == token) {
            self.active = None;
        }
    }
}

fn same_language(a: &str, b: &str) -> bool {
    a.trim().eq_ignore_ascii_case(b.trim())
}

fn validate(r: &ReadingRecord) -> Result<(), String> {
    let source_bytes = r
        .originals
        .iter()
        .try_fold(0usize, |n, s| n.checked_add(s.len()))
        .ok_or("The document analysis source size overflowed.")?;
    if r.kind != "summary"
        || r.source_id != crate::workspace::reading_scope_key(None)
        || r.status != "finished"
        || r.content.trim().is_empty()
        || r.content.len() > 1024 * 1024
        || source_bytes > 16 * 1024 * 1024
        || r.originals.is_empty()
        || r.originals.len() != r.original_pages.len()
        || r.pages.is_empty()
        || r.pages.contains(&0)
        || r.pages.windows(2).any(|pair| pair[0] >= pair[1])
        || r.original_pages
            .iter()
            .any(|p| r.pages.binary_search(p).is_err())
        || r.source_hash.len() != 64
        || !r.source_hash.bytes().all(|c| c.is_ascii_hexdigit())
    {
        return Err("The document analysis is incomplete or has an invalid source map. The previous understanding was kept.".into());
    }
    Ok(())
}

/// Navigational generated data, never a claim-to-source mapping. Only original source records
/// may authorize citations. The Markdown body remains unchanged for direct Summary display.
fn section_index(text: &str) -> Vec<(String, String)> {
    let mut sections: Vec<(String, String)> = Vec::new();
    for line in text.lines() {
        if line.starts_with('#') {
            sections.push((
                line.trim_start_matches('#').trim().to_string(),
                String::new(),
            ));
        } else if let Some((_, body)) = sections.last_mut() {
            body.push_str(line);
            body.push('\n');
        }
    }
    sections
}

/// A compact global map for long-document questions. The full generated summary stays on disk;
/// the prefix is stable and bounded independently of the current question.
pub fn context(text: &str) -> String {
    let sections = section_index(text);
    if sections.is_empty() || text.graphemes(true).count() <= 6_000 {
        return text.graphemes(true).take(6_000).collect();
    }
    // Share the budget across headings, including the final conclusions/limitations, instead
    // of repeatedly sending the beginning while silently discarding the end of the analysis.
    let allowance = 6_000 / sections.len();
    let mut output = String::new();
    for (title, body) in sections {
        let entry = format!("## {title}\n{body}");
        output.extend(entry.graphemes(true).take(allowance.saturating_sub(1)));
        output.push('\n');
    }
    output.graphemes(true).take(6_000).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn record() -> ReadingRecord {
        ReadingRecord {
            id: "analysis".into(),
            kind: "summary".into(),
            source_id: "document".into(),
            content: "# Overview\nA synthetic finding [p.1].\n## Method\nSynthetic evidence."
                .into(),
            status: "finished".into(),
            detail: "Standard".into(),
            pages: vec![1],
            originals: vec!["A synthetic source with actual document evidence.".into()],
            original_pages: vec![1],
            source_hash: "a".repeat(64),
            ..Default::default()
        }
    }
    #[test]
    fn summary_and_prereading_share_one_current_lease_and_result() {
        let mut memory = DocumentUnderstanding::default();
        let r = record();
        let Claim::Start(token) = memory
            .begin(r.source_hash.clone(), "".into(), "Standard".into(), false)
            .unwrap()
        else {
            panic!()
        };
        assert!(matches!(
            memory
                .begin(
                    r.source_hash.clone(),
                    "English".into(),
                    "Detailed".into(),
                    true
                )
                .unwrap(),
            Claim::Waiting
        ));
        assert!(!memory.finish(token + 1, r.clone()).unwrap());
        assert!(memory.finish(token, r.clone()).unwrap());
        assert!(matches!(
            memory
                .begin(r.source_hash.clone(), "".into(), "Standard".into(), false)
                .unwrap(),
            Claim::Ready(_)
        ));
        assert!(
            memory
                .reusable(&r.source_hash, "English", "Standard")
                .is_none()
        );
        assert!(memory.record(&"b".repeat(64)).is_none());
        let encoded = memory.encode().unwrap();
        let mut reopened = DocumentUnderstanding::default();
        assert!(reopened.load(&encoded, &r.source_hash).unwrap());
        assert_eq!(reopened.record(&r.source_hash).unwrap().content, r.content);
    }
    #[test]
    fn cancellation_partial_results_and_unknown_fields_are_lossless() {
        let mut memory = DocumentUnderstanding::default();
        let mut r = record();
        let Claim::Start(old) = memory
            .begin(r.source_hash.clone(), "".into(), "Standard".into(), true)
            .unwrap()
        else {
            panic!()
        };
        memory.cancel(old);
        let Claim::Start(new) = memory
            .begin(r.source_hash.clone(), "".into(), "Standard".into(), true)
            .unwrap()
        else {
            panic!()
        };
        memory.cancel(old);
        assert!(!memory.finish(old, r.clone()).unwrap());
        r.status = "partial".into();
        assert!(memory.finish(new, r.clone()).is_err());
        r.status = "finished".into();
        assert!(memory.finish(new, r.clone()).unwrap());
        let mut value: serde_json::Value =
            serde_json::from_slice(&memory.encode().unwrap()).unwrap();
        value["future"] = serde_json::json!({"keep": true});
        value["record"]["future_record"] = serde_json::json!([1, 2]);
        memory
            .load(&serde_json::to_vec(&value).unwrap(), &r.source_hash)
            .unwrap();
        let roundtrip: serde_json::Value =
            serde_json::from_slice(&memory.encode().unwrap()).unwrap();
        assert_eq!(roundtrip["future"], value["future"]);
        assert_eq!(
            roundtrip["record"]["future_record"],
            value["record"]["future_record"]
        );
        assert!(memory.load(b"{truncated", &r.source_hash).is_err());
        assert_eq!(memory.record(&r.source_hash).unwrap().content, r.content);
    }
}

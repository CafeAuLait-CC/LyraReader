//! Linux file adapter for the shared source-bound document understanding.
use crate::document::DesktopDocument;
use crate::document_cache::{
    DocumentCache, atomic_write, lock_understanding_cache, read_optional_bounded,
};
use lyra_reader_ai::knowledge::DocumentReading;
use lyra_reader_ai::understanding::{Claim, DocumentUnderstanding, MAX_BYTES};
use lyra_reader_ai::workspace::{ReadingRecord, reading_scope_key};
use lyra_reader_ffi::api::{AiPlanRecord, LyraReaderDocument};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::sync::Arc;

pub(super) const FILE: &str = "document-understanding-v2.json";

pub(super) struct SummaryCapture {
    record: ReadingRecord,
}

impl SummaryCapture {
    pub(super) fn new(
        plan: &AiPlanRecord,
        source_hash: String,
        language: String,
        detail: String,
    ) -> Result<Self, String> {
        Ok(Self {
            record: ReadingRecord {
                id: crate::marks::uuid()?,
                kind: "summary".into(),
                source_id: reading_scope_key(None),
                title: plan.document_title.clone(),
                pages: plan.source_pages.clone(),
                language,
                detail,
                status: "finished".into(),
                originals: plan
                    .sources
                    .iter()
                    .map(|source| source.snippet.clone())
                    .collect(),
                original_pages: plan.sources.iter().map(|source| source.page).collect(),
                source_hash,
                ..ReadingRecord::default()
            },
        })
    }

    pub(super) fn ready(mut self, model: String, answer: String) -> Result<ReadingRecord, String> {
        self.record.model = model;
        self.record.content = answer;
        self.record.modified = u64::try_from(chrono::Utc::now().timestamp_millis())
            .map_err(|_| "The local clock cannot date the document summary.")?;
        Ok(self.record)
    }
}

pub(super) struct PendingSummary {
    pub(super) token: String,
    capture: Arc<SummaryCapture>,
    body_digest: [u8; 32],
}

impl PendingSummary {
    pub(super) fn new(capture: Arc<SummaryCapture>, body: &str) -> Result<Self, String> {
        Ok(Self {
            token: crate::marks::uuid()?,
            capture,
            body_digest: Sha256::digest(body.as_bytes()).into(),
        })
    }

    pub(super) fn matches(&self, token: &str, body: &str, fingerprint: &str) -> bool {
        if self.token != token || self.capture.record.source_hash != fingerprint {
            return false;
        }
        let digest: [u8; 32] = Sha256::digest(body.as_bytes()).into();
        digest == self.body_digest
    }

    pub(super) fn capture(&self) -> Arc<SummaryCapture> {
        Arc::clone(&self.capture)
    }
}

impl Clone for SummaryCapture {
    fn clone(&self) -> Self {
        Self {
            record: self.record.clone(),
        }
    }
}

fn load(
    cache: &DocumentCache,
    fingerprint: &str,
) -> Result<(DocumentUnderstanding, Option<Vec<u8>>), String> {
    let bytes = read_optional_bounded(&cache.directory.join(FILE), MAX_BYTES as u64)?;
    let mut state = DocumentUnderstanding::default();
    if let Some(bytes) = &bytes {
        state.load(bytes, fingerprint)?;
    }
    Ok((state, bytes))
}

pub(super) fn context(
    cache: &DocumentCache,
    fingerprint: &str,
    page_count: u32,
) -> Result<Option<DocumentReading>, String> {
    Ok(summary_record(cache, fingerprint, page_count)?
        .as_ref()
        .map(context_record))
}

pub(super) fn summary_record(
    cache: &DocumentCache,
    fingerprint: &str,
    page_count: u32,
) -> Result<Option<ReadingRecord>, String> {
    let (state, _) = load(cache, fingerprint)?;
    state
        .record(fingerprint)
        .map(|record| {
            verify_pages(&record, page_count)?;
            Ok(record)
        })
        .transpose()
}

fn context_record(record: &ReadingRecord) -> DocumentReading {
    // The optional-reading panel still consumes the v1 in-memory DTO. The v2
    // file remains the authoritative record for format and original sources.
    DocumentReading {
        version: 1,
        source_hash: record.source_hash.clone(),
        summary: record.content.clone(),
        pages: record.pages.clone(),
        model: record.model.clone(),
        read_at: record.modified as f64 / 1000.0 - 978_307_200.0,
        unknown: Default::default(),
    }
}

fn verify_pages(record: &ReadingRecord, page_count: u32) -> Result<(), String> {
    if record.pages.iter().any(|page| *page > page_count) {
        return Err(
            "The saved document summary contains a page outside this PDF. Its file was kept."
                .into(),
        );
    }
    Ok(())
}

impl DesktopDocument {
    pub(super) fn cached_document_summary(
        &self,
        source: &Arc<LyraReaderDocument>,
        language: &str,
        detail: &str,
    ) -> Result<Option<Value>, String> {
        self.with_reading_cache(source, true, |cache, sha| {
            let (state, _) = load(cache, &sha)?;
            state.reusable(&sha, language, detail).map(|record| {
                verify_pages(&record, source.page_count())?;
                    Ok(json!({"id":record.id,"output":record.content,"title":record.title,"source_pages":record.pages}))
            }).transpose()
        })
    }

    pub(super) fn publish_summary(
        &self,
        source: &Arc<LyraReaderDocument>,
        record: ReadingRecord,
    ) -> Result<(DocumentReading, String), String> {
        let context = context_record(&record);
        let id = record.id.clone();
        self.with_reading_cache(source, true, |cache, sha| {
            if record.source_hash != sha {
                return Err("The PDF revision changed before saving the summary.".into());
            }
            verify_pages(&record, source.page_count())?;
            let _lease = lock_understanding_cache(&cache.directory)?;
            let (mut state, before) = load(cache, &sha)?;
            let Claim::Start(token) =
                state.begin(sha, record.language.clone(), record.detail.clone(), true)?
            else {
                return Err("The completed summary could not claim its cache record.".into());
            };
            if !state.finish(token, record)? {
                return Err("The completed summary did not match its cache record.".into());
            }
            let bytes = state.encode()?;
            let destination = cache.directory.join(FILE);
            if read_optional_bounded(&destination, MAX_BYTES as u64)? != before {
                return Err(
                    "Document understanding changed while saving. Its file was kept.".into(),
                );
            }
            if let Some(before) = before {
                atomic_write(
                    &cache
                        .directory
                        .join("document-understanding-v2.previous.json"),
                    &before,
                )?;
            }
            atomic_write(&destination, &bytes)
        })?;
        Ok((context, id))
    }
}

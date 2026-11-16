//! Typed workspace adapter; all record rules and serialization live in lyra-reader-ai.
use crate::api::ErrorSeverity;
use crate::api::LyraReaderFfiError;
use lyra_reader_ai::workspace::{ReadingRecord, ReadingWorkspace};
use std::sync::{Arc, Mutex};

fn error(message: String) -> LyraReaderFfiError {
    LyraReaderFfiError::InvalidArgument {
        message,
        severity: ErrorSeverity::Recoverable,
    }
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct AiReadingRecord {
    pub id: String,
    pub kind: String,
    pub source_id: String,
    pub conversation_id: String,
    pub title: String,
    pub content: String,
    pub thoughts: String,
    pub question: String,
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
    pub versions: Vec<String>,
}
impl From<ReadingRecord> for AiReadingRecord {
    fn from(r: ReadingRecord) -> Self {
        Self {
            id: r.id,
            kind: r.kind,
            source_id: r.source_id,
            conversation_id: r.conversation_id,
            title: r.title,
            content: r.content,
            thoughts: r.thoughts,
            question: r.question,
            pages: r.pages,
            excerpt: r.excerpt,
            language: r.language,
            model: r.model,
            detail: r.detail,
            status: r.status,
            modified: r.modified,
            revision: r.revision,
            source_revision: r.source_revision,
            originals: r.originals,
            original_pages: r.original_pages,
            source_hash: r.source_hash,
            covered_turns: r.covered_turns,
            versions: r.versions,
        }
    }
}
impl From<AiReadingRecord> for ReadingRecord {
    fn from(r: AiReadingRecord) -> Self {
        Self {
            id: r.id,
            kind: r.kind,
            source_id: r.source_id,
            conversation_id: r.conversation_id,
            title: r.title,
            content: r.content,
            thoughts: r.thoughts,
            question: r.question,
            pages: r.pages,
            excerpt: r.excerpt,
            language: r.language,
            model: r.model,
            detail: r.detail,
            status: r.status,
            modified: r.modified,
            revision: r.revision,
            source_revision: r.source_revision,
            originals: r.originals,
            original_pages: r.original_pages,
            source_hash: r.source_hash,
            covered_turns: r.covered_turns,
            versions: r.versions,
            extra: Default::default(),
        }
    }
}
#[derive(uniffi::Object)]
pub struct LyraReadingWorkspace {
    state: Mutex<ReadingWorkspace>,
}
#[uniffi::export]
impl LyraReadingWorkspace {
    #[uniffi::constructor]
    pub fn new(bytes: Option<Vec<u8>>) -> Result<Arc<Self>, LyraReaderFfiError> {
        let state = match bytes {
            Some(bytes) => ReadingWorkspace::decode(&bytes).map_err(error)?,
            None => ReadingWorkspace::default(),
        };
        Ok(Arc::new(Self {
            state: Mutex::new(state),
        }))
    }
    pub fn bind_source(&self, fingerprint: String) -> Result<(), LyraReaderFfiError> {
        lyra_reader_core::sync::lock(&self.state)?.bind_source(fingerprint);
        Ok(())
    }
    pub fn suggestion(
        &self,
        note_id: String,
    ) -> Result<Option<AiReadingRecord>, LyraReaderFfiError> {
        Ok(lyra_reader_core::sync::lock(&self.state)?
            .suggestion(&note_id)
            .map(Into::into))
    }
    pub fn apply_suggestion(
        &self,
        note_id: String,
        apply: bool,
        modified: u64,
    ) -> Result<AiReadingRecord, LyraReaderFfiError> {
        Ok(lyra_reader_core::sync::lock(&self.state)?
            .apply_suggestion(&note_id, apply, modified)
            .map_err(error)?
            .into())
    }
    pub fn records(&self) -> Result<Vec<AiReadingRecord>, LyraReaderFfiError> {
        Ok(lyra_reader_core::sync::lock(&self.state)?
            .records()
            .into_iter()
            .map(Into::into)
            .collect())
    }
    pub fn put_all(&self, records: Vec<AiReadingRecord>) -> Result<(), LyraReaderFfiError> {
        lyra_reader_core::sync::lock(&self.state)?
            .put_all(records.into_iter().map(Into::into).collect())
            .map_err(error)
    }
    pub fn put(&self, record: AiReadingRecord) -> Result<AiReadingRecord, LyraReaderFfiError> {
        Ok(lyra_reader_core::sync::lock(&self.state)?
            .put(record.into())
            .map_err(error)?
            .into())
    }
    pub fn keep(
        &self,
        source: AiReadingRecord,
        note_id: String,
    ) -> Result<AiReadingRecord, LyraReaderFfiError> {
        Ok(lyra_reader_core::sync::lock(&self.state)?
            .keep(source.into(), note_id)
            .map_err(error)?
            .into())
    }
    pub fn notes(
        &self,
        query: String,
        recent: bool,
    ) -> Result<Vec<AiReadingRecord>, LyraReaderFfiError> {
        Ok(lyra_reader_core::sync::lock(&self.state)?
            .notes(&query, recent)
            .into_iter()
            .map(Into::into)
            .collect())
    }
    pub fn encode(&self) -> Result<Vec<u8>, LyraReaderFfiError> {
        lyra_reader_core::sync::lock(&self.state)?
            .encode()
            .map_err(error)
    }
}
#[uniffi::export]
pub fn ai_reading_gate(
    policy: String,
    state: String,
    has_cache: bool,
) -> Result<String, LyraReaderFfiError> {
    lyra_reader_ai::workspace::reading_gate(&policy, &state, has_cache).map_err(error)
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct AiTranslationBlock {
    pub original: String,
    pub translation: String,
    pub page: u32,
}
#[uniffi::export]
pub fn ai_translation_blocks(
    originals: Vec<String>,
    pages: Vec<u32>,
    response: String,
) -> Result<Vec<AiTranslationBlock>, LyraReaderFfiError> {
    Ok(
        lyra_reader_ai::workspace::translation_blocks(&originals, &pages, &response)
            .map_err(error)?
            .into_iter()
            .map(|b| AiTranslationBlock {
                original: b.original,
                translation: b.translation,
                page: b.page,
            })
            .collect(),
    )
}
#[uniffi::export]
pub fn ai_reading_note_prompt(language: String) -> Result<String, LyraReaderFfiError> {
    lyra_reader_ai::workspace::reading_instructions("note", "Standard", &language).map_err(error)
}

#[uniffi::export]
pub fn ai_document_fingerprint(path: String) -> Result<String, LyraReaderFfiError> {
    lyra_reader_ai::workspace::document_fingerprint(&path).map_err(error)
}

#[uniffi::export]
pub fn ai_translation_terms(originals: Vec<String>) -> Vec<String> {
    lyra_reader_ai::workspace::translation_terms(&originals)
}

#[uniffi::export]
pub fn ai_reading_scope_key(selection: Option<crate::api::AiSelectionRecord>) -> String {
    lyra_reader_ai::workspace::reading_scope_key(selection.map(|s| {
        lyra_reader_ai::SelectionRange {
            page: s.page,
            start: s.start,
            end: s.end,
        }
    }))
}

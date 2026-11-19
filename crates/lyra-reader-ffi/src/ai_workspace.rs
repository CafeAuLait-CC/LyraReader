//! Typed reading adapters; portable rules and serialization live in lyra-reader-ai.
use crate::api::ErrorSeverity;
use crate::api::LyraReaderFfiError;
use lyra_reader_ai::workspace::{ReadingRecord, ReadingWorkspace};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, uniffi::Enum)]
pub enum AiAnalysisClaim {
    Start { token: u64 },
    Ready,
    Waiting,
}

/// Control-plane adapter. All cache and in-flight ownership rules live in lyra-reader-ai.
#[derive(uniffi::Object, Default)]
pub struct LyraDocumentUnderstanding {
    state: Mutex<lyra_reader_ai::understanding::DocumentUnderstanding>,
}

#[uniffi::export]
impl LyraDocumentUnderstanding {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }
    pub fn load(&self, bytes: Vec<u8>, source: String) -> Result<bool, LyraReaderFfiError> {
        lyra_reader_core::sync::lock(&self.state)?
            .load(&bytes, &source)
            .map_err(error)
    }
    pub fn encode(&self) -> Result<Vec<u8>, LyraReaderFfiError> {
        lyra_reader_core::sync::lock(&self.state)?
            .encode()
            .map_err(error)
    }
    pub fn record(&self, source: String) -> Result<Option<AiReadingRecord>, LyraReaderFfiError> {
        Ok(lyra_reader_core::sync::lock(&self.state)?
            .record(&source)
            .map(Into::into))
    }
    pub fn reusable(
        &self,
        source: String,
        language: String,
        detail: String,
    ) -> Result<Option<AiReadingRecord>, LyraReaderFfiError> {
        Ok(lyra_reader_core::sync::lock(&self.state)?
            .reusable(&source, &language, &detail)
            .map(Into::into))
    }
    pub fn begin(
        &self,
        source: String,
        language: String,
        detail: String,
        force: bool,
    ) -> Result<AiAnalysisClaim, LyraReaderFfiError> {
        use lyra_reader_ai::understanding::Claim;
        Ok(
            match lyra_reader_core::sync::lock(&self.state)?
                .begin(source, language, detail, force)
                .map_err(error)?
            {
                Claim::Start(token) => AiAnalysisClaim::Start { token },
                Claim::Ready(_) => AiAnalysisClaim::Ready,
                Claim::Waiting => AiAnalysisClaim::Waiting,
            },
        )
    }
    pub fn finish(&self, token: u64, record: AiReadingRecord) -> Result<bool, LyraReaderFfiError> {
        lyra_reader_core::sync::lock(&self.state)?
            .finish(token, record.into())
            .map_err(error)
    }
    pub fn cancel(&self, token: u64) -> Result<(), LyraReaderFfiError> {
        lyra_reader_core::sync::lock(&self.state)?.cancel(token);
        Ok(())
    }
}

#[uniffi::export]
pub fn ai_document_understanding_context(text: String) -> String {
    lyra_reader_ai::understanding::context(&text)
}

#[uniffi::export]
pub fn ai_needs_document_understanding(kind: String) -> bool {
    lyra_reader_ai::understanding::needs_prior(&kind)
}

#[uniffi::export]
pub fn ai_document_understanding_cache_limit() -> u64 {
    lyra_reader_ai::understanding::MAX_BYTES as u64
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct AiResponseUsage {
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
    pub reasoning_tokens: Option<u64>,
    pub cached_tokens: Option<u64>,
}

#[uniffi::export]
pub fn ai_response_usage(json: String) -> Result<Option<AiResponseUsage>, LyraReaderFfiError> {
    Ok(
        lyra_reader_ai::openai::response_usage_json(&json)?.map(|u| AiResponseUsage {
            prompt_tokens: u.prompt_tokens,
            completion_tokens: u.completion_tokens,
            total_tokens: u.total_tokens,
            reasoning_tokens: u.reasoning_tokens,
            cached_tokens: u.cached_tokens,
        }),
    )
}

fn error(message: String) -> LyraReaderFfiError {
    LyraReaderFfiError::InvalidArgument {
        message,
        severity: ErrorSeverity::Recoverable,
    }
}

#[uniffi::export]
pub fn ai_math_render_source(source: String) -> String {
    lyra_reader_ai::math::render_source(&source)
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
    pub fn task_history(
        &self,
        kind: String,
        source_id: Option<String>,
    ) -> Result<Vec<AiReadingRecord>, LyraReaderFfiError> {
        Ok(lyra_reader_core::sync::lock(&self.state)?
            .task_history(&kind, source_id.as_deref())
            .map_err(error)?
            .into_iter()
            .map(Into::into)
            .collect())
    }
    pub fn translation_history(
        &self,
        selection: bool,
    ) -> Result<Vec<AiReadingRecord>, LyraReaderFfiError> {
        Ok(lyra_reader_core::sync::lock(&self.state)?
            .translation_history(selection)
            .map_err(error)?
            .into_iter()
            .map(Into::into)
            .collect())
    }
    pub fn task_selection(
        &self,
        id: String,
    ) -> Result<Option<crate::api::AiSelectionRecord>, LyraReaderFfiError> {
        Ok(lyra_reader_core::sync::lock(&self.state)?
            .task_selection(&id)
            .map_err(error)?
            .map(|selection| crate::api::AiSelectionRecord {
                page: selection.page,
                start: selection.start,
                end: selection.end,
            }))
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

//! UniFFI control plane: the object graph the shell drives.
//!
//! Scope for T0.8 is deliberately small — just enough to prove the generated-bindings
//! pipeline end to end and to replace the shell's mock engine with something real:
//!
//! * [`LyraReaderEngine`] — version/backend information plus [`LyraReaderEngine::probe_document`],
//!   which opens a PDF through the PDFium backend and returns a value-typed
//!   [`DocumentSummary`].
//!
//! The full object graph (long-lived documents, sessions, viewports, event streams)
//! lands in M1; its shape is specified in `docs/05-ffi.md` §3–§4.

use crate::index_cache::{
    CacheRead, CachedReferenceList, CachedReferences, ContentIdentity, IndexCacheFile, cache_path,
    disabled_by_environment, write_cache,
};

/// Cache-management location for the native shell; does not open or index the document.
#[uniffi::export]
pub fn document_index_cache_path(path: String) -> String {
    cache_path(Path::new(&path)).display().to_string()
}
use lyra_reader_ai::MockProvider;
use lyra_reader_ai::chat::{
    Action as AiAction, CONNECTION_TEST_MAX_TOKENS, ChatImage, ChatPlan, ChatSettings,
    ChatTransport, ChatWire, ConversationTurn, DocumentChatRequest, DocumentKnowledgeInput,
    MergePart, MergePlanRequest, NOTHING_RELEVANT_MESSAGE, PageChar, PageText, PlanRequest,
    ReasoningEncoding, ReasoningField, ReasoningMode, RegionQuestionRequest, RegionRect,
    SUMMARY_ABSTRACT_MAX_CHARS, SUMMARY_ABSTRACT_MAX_PAGES, SUMMARY_MAX_CONCURRENT_REQUESTS,
    SUMMARY_MAX_REQUESTS_PER_BATCH, SUMMARY_PAGE_MAX_CHARS, SUMMARY_SECTION_MAX_CHARS,
    SelectionRange as AiSelectionRange, SourceRect as AiSourceRect, SummaryLayer,
    SummaryLayerRequest, SummaryUnitRequest, abstract_sample_page_indices,
    build_connection_test_plan, build_document_chat_plan, build_document_knowledge_plan,
    build_merge_plan, build_plan, build_region_question_plan, build_summary_layer,
    inspect_base_url, inspect_summary_layer, summary_coverage_note, validate_model,
};
use lyra_reader_ai::openai::{
    CancellationToken, RunEvent, StreamDiagnostics, TokenUsage, preview_headers, run_plan,
};
use lyra_reader_ai::{SummaryOutlineEntry, plan_summary_sections};
use lyra_reader_core::{
    AnnotationAlignment, AnnotationDrawing, DocumentBackend, ENGINE_VERSION, EngineConfig,
    ErrorCode, PageGeometry, PageIndex, Point, RasterRequest, RawAnnotationLine, Transform2D,
};
use lyra_reader_edit::{
    kind::{AnnotationKind as TaxonomyKind, WriteKind as TaxonomyWriteKind},
    records as annotation_records, rules as annotation_rules,
};
use lyra_reader_metadata::{BibEntry, MetadataSource, RecognizedMetadata, recognize};
use lyra_reader_pdfium::{
    DEFAULT_BOOKMARK_TITLE, EmbeddedBookmarks, PageOperation, PdfiumBackend, SaveMode, SplitPart,
    WriteAnnotation, WriteAnnotationKind, WriteBookmark, backend_description, merge_documents,
    read_embedded_bookmarks, split_pages,
};
use lyra_reader_render::plan as render_plan;
use lyra_reader_session::{DocumentLayout, LayoutMode};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Pages the reference-list locator reads.
///
/// The locator compares several candidate runs across the pages it is given (a paper's own
/// bibliography, an appendix's independent one, a list continued under a second numbering), so it
/// needs those pages' text together; that is the one index component whose working set grows with
/// its window. It is deliberately kept at the historical 120 pages for a document longer than
/// that: the reference list of a real paper is near its body, and pages beyond this window are
/// still read once, for the citation index ([`LyraReaderDocument::citations`]). The visible
/// consequence for a book whose bibliography is printed after page 120 is stated by
/// [`LyraReaderDocument::references`]: the locator returns no entries, and citations are derived from
/// the page shapes alone. Captions have no such window; see [`LyraReaderDocument::figures`].
const REFERENCE_SCAN_PAGES: u32 = 120;

/// Size used only to keep the scrolling layout stable for a page PDFium could not measure.
///
/// This is the historical US Letter fallback. It is not reported as the page's size:
/// [`PagePlacementRecord`] carries `None` for such a page and the shell applies its own
/// fallback, which is the same 612 × 792 box users see today.
const UNKNOWN_LAYOUT_PAGE_SIZE: (f64, f64) = (612.0, 792.0);

/// Lazy page-size cache. Each entry is `None` when PDFium could not measure that page.
type CachedPageSizes = Vec<Option<(f64, f64)>>;

/// How many pages of line-aware selection geometry one document keeps.
///
/// The cache exists so a pointer event is one synchronous FFI call: the alternative is a
/// `text_page` round trip per event (measured at ~1.4 ms in Rust and ~4.8 ms through the
/// Swift boundary, versus ~0.7 µs for the cached line-aware hit). Five pages covers the pages
/// a reader is actually pointing at, including the previous/next page during a scroll. The
/// five corpus pages measured by `hit_bench` total ~858 KiB of selection geometry, so all five
/// fit under the byte ceiling; larger pages evict oldest-first instead of exceeding it.
const TEXT_PAGE_CACHE_MAX_ENTRIES: usize = 5;
/// Byte ceiling for the same cache (~1.5 MiB). A page that cannot fit alone is still usable;
/// it is simply not retained.
const TEXT_PAGE_CACHE_MAX_BYTES: usize = 3 * 512 * 1024;

/// One cached page: the Swift-parity line decomposition plus the per-character Unicode
/// scalars range→string needs, and its estimated heap cost.
struct CachedTextPage {
    page: u32,
    value: Arc<lyra_reader_text::SelectionTextPage>,
    bytes: usize,
    last_used: u64,
}

/// Per-document LRU of page text geometry.
///
/// `loads` counts hit-test cache misses that had to extract the page through PDFium; `hits`
/// counts cache reads. The counters exist so the regression check can prove that a second
/// pointer event on the same page never re-enters PDFium.
#[derive(Default)]
struct TextPageCache {
    entries: Vec<CachedTextPage>,
    tick: u64,
    loads: u64,
    hits: u64,
    evictions: u64,
}

impl TextPageCache {
    fn get(&mut self, page: u32) -> Option<Arc<lyra_reader_text::SelectionTextPage>> {
        self.tick += 1;
        let tick = self.tick;
        let entry = self.entries.iter_mut().find(|entry| entry.page == page)?;
        entry.last_used = tick;
        self.hits += 1;
        Some(Arc::clone(&entry.value))
    }

    fn insert(&mut self, page: u32, value: Arc<lyra_reader_text::SelectionTextPage>, bytes: usize) {
        if bytes > TEXT_PAGE_CACHE_MAX_BYTES {
            // A single page larger than the whole budget is never retained; the caller still
            // gets the value it just built.
            return;
        }
        self.tick += 1;
        self.entries.retain(|entry| entry.page != page);
        self.entries.push(CachedTextPage {
            page,
            value,
            bytes,
            last_used: self.tick,
        });
        while self.entries.len() > TEXT_PAGE_CACHE_MAX_ENTRIES
            || self.entries.iter().map(|entry| entry.bytes).sum::<usize>()
                > TEXT_PAGE_CACHE_MAX_BYTES
        {
            let Some((oldest, _)) = self
                .entries
                .iter()
                .enumerate()
                .min_by_key(|(_, entry)| entry.last_used)
            else {
                break;
            };
            self.entries.remove(oldest);
            self.evictions += 1;
        }
    }

    fn bytes(&self) -> usize {
        self.entries.iter().map(|entry| entry.bytes).sum()
    }

    fn pages_oldest_first(&self) -> Vec<u32> {
        let mut entries: Vec<&CachedTextPage> = self.entries.iter().collect();
        entries.sort_by_key(|entry| entry.last_used);
        entries.iter().map(|entry| entry.page).collect()
    }
}

/// Facts about one document's text-page cache, for the regression checks and diagnostics.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TextPageCacheStats {
    /// Pages currently retained.
    pub entries: u32,
    /// Entry limit (5).
    pub max_entries: u32,
    /// Estimated retained bytes, including per-character scalars and the line decomposition.
    pub bytes: u64,
    /// Byte ceiling (~1.5 MiB).
    pub max_bytes: u64,
    /// Hit-test cache misses that extracted a page through PDFium.
    pub loads: u64,
    /// Hit-test calls served from the cache.
    pub hits: u64,
    /// Entries removed to stay under the entry or byte limit.
    pub evictions: u64,
    /// Retained pages, least recently used first.
    pub pages: Vec<u32>,
}

/// The stable category of an AI failure, for the error record and for stream events.
///
/// This is the machine contract the shell maps to its audit vocabulary and to the offline hint.
/// It is assigned **once**, from the Rust error variant that failed — never from a provider's
/// message text. `NothingRelevant` and `VisionUnsupported` are split out of `EmptyContext` because
/// the shell has always shown them as distinct refusal categories; they are still decided by the
/// Rust builder that produced the error, not by the shell matching substrings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiErrorCode {
    /// No provider configured.
    NotConfigured,
    /// A transport failure that is not one of the recognized categories below.
    Unreachable,
    /// The request never left this Mac: no route / network down / name resolution failed.
    Offline,
    /// The endpoint is loopback and nothing is listening there.
    LocalServer,
    /// Authentication failed (invalid or expired key).
    Unauthorized,
    /// Rate or quota limit exceeded.
    RateLimited,
    /// Cancelled by the user or the system.
    Cancelled,
    /// The model does not support the requested capability.
    UnsupportedCapability,
    /// The reader's settings are not usable.
    InvalidSettings,
    /// The requested context has nothing to send.
    EmptyContext,
    /// Retrieval found no passage relevant to the question.
    NothingRelevant,
    /// The question needs image input, which is off for this model.
    VisionUnsupported,
    /// The provider answered with a non-2xx HTTP status.
    HttpStatus,
    /// The response was not the streaming protocol this client speaks.
    Protocol,
    /// The connection or the stream took too long.
    Timeout,
    /// Any other error.
    Other,
}

impl AiErrorCode {
    /// The stable category of an [`lyra_reader_ai::AiError`]. This is the **only** place message
    /// structure is interpreted, and only for the two refusals the Rust builder has no dedicated
    /// variant for yet (`NothingRelevant`, `VisionUnsupported`).
    fn of(error: &lyra_reader_ai::AiError) -> Self {
        use lyra_reader_ai::AiError;
        match error {
            AiError::NotConfigured => Self::NotConfigured,
            AiError::Unreachable(_) => Self::Unreachable,
            AiError::Offline(_) => Self::Offline,
            AiError::LocalServer(_) => Self::LocalServer,
            AiError::Unauthorized => Self::Unauthorized,
            AiError::RateLimited => Self::RateLimited,
            AiError::Cancelled => Self::Cancelled,
            AiError::UnsupportedCapability(_) => Self::UnsupportedCapability,
            AiError::InvalidSettings(_) => Self::InvalidSettings,
            AiError::EmptyContext(message) => {
                if message == NOTHING_RELEVANT_MESSAGE {
                    Self::NothingRelevant
                } else if message.contains("Turn on image input") {
                    Self::VisionUnsupported
                } else {
                    Self::EmptyContext
                }
            }
            AiError::HttpStatus(_) => Self::HttpStatus,
            AiError::Protocol(_) => Self::Protocol,
            AiError::Timeout(_) => Self::Timeout,
            AiError::Other(_) => Self::Other,
        }
    }
}

/// How the shell should present an error.
///
/// This mirrors [`lyra_reader_core::Severity`] as a UniFFI enum so every thrown error carries the
/// decision with it. The shell maps one severity to one presentation (`alert` for `Fatal` and
/// `Document`, `banner`/`status` for `Recoverable`); it never re-derives severity from the
/// message or from the error variant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ErrorSeverity {
    /// One feature failed; the document and reading are still usable.
    Recoverable,
    /// The requested document operation failed; the reader must be told.
    Document,
    /// The engine cannot be trusted until it is restarted.
    Fatal,
}

impl From<lyra_reader_core::Severity> for ErrorSeverity {
    fn from(severity: lyra_reader_core::Severity) -> Self {
        match severity {
            lyra_reader_core::Severity::Recoverable => Self::Recoverable,
            lyra_reader_core::Severity::Document => Self::Document,
            lyra_reader_core::Severity::Fatal => Self::Fatal,
        }
    }
}

impl From<ErrorSeverity> for lyra_reader_core::Severity {
    fn from(severity: ErrorSeverity) -> Self {
        match severity {
            ErrorSeverity::Recoverable => Self::Recoverable,
            ErrorSeverity::Document => Self::Document,
            ErrorSeverity::Fatal => Self::Fatal,
        }
    }
}

impl AiErrorCode {
    /// The presentation severity of an AI failure.
    ///
    /// AI failures are shown beside the request that failed (the assistant panel keeps its
    /// conversation and its inline message), so most are `Recoverable`. A configuration or
    /// authentication problem is `Document`: the reader has to fix the connection before the
    /// feature works at all.
    pub fn severity(self) -> ErrorSeverity {
        match self {
            Self::NotConfigured
            | Self::Unauthorized
            | Self::UnsupportedCapability
            | Self::InvalidSettings => ErrorSeverity::Document,
            Self::Unreachable
            | Self::Offline
            | Self::LocalServer
            | Self::RateLimited
            | Self::Cancelled
            | Self::EmptyContext
            | Self::NothingRelevant
            | Self::VisionUnsupported
            | Self::HttpStatus
            | Self::Protocol
            | Self::Timeout
            | Self::Other => ErrorSeverity::Recoverable,
        }
    }
}

/// Errors crossing the FFI boundary (they surface as Swift `throws`).
#[derive(Debug, uniffi::Error)]
pub enum LyraReaderFfiError {
    /// The file could not be read or parsed.
    Document {
        message: String,
        /// How the shell presents this failure.
        severity: ErrorSeverity,
    },
    /// No usable PDF backend (for example, PDFium could not be loaded).
    Backend {
        message: String,
        /// How the shell presents this failure.
        severity: ErrorSeverity,
    },
    /// The caller passed something invalid.
    InvalidArgument {
        message: String,
        /// How the shell presents this failure.
        severity: ErrorSeverity,
    },
    /// The AI layer could not build a plan or run a request.
    Ai {
        message: String,
        /// Stable category; the shell maps this to its audit vocabulary.
        code: AiErrorCode,
        /// How the shell presents this failure; derived from `code`.
        severity: ErrorSeverity,
    },
}

impl LyraReaderFfiError {
    /// The presentation severity carried by this error.
    pub fn severity(&self) -> ErrorSeverity {
        match self {
            Self::Document { severity, .. }
            | Self::Backend { severity, .. }
            | Self::InvalidArgument { severity, .. }
            | Self::Ai { severity, .. } => *severity,
        }
    }
}

impl std::fmt::Display for LyraReaderFfiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Document { message, .. } => write!(f, "document error: {message}"),
            Self::Backend { message, .. } => write!(f, "backend error: {message}"),
            Self::InvalidArgument { message, .. } => write!(f, "invalid argument: {message}"),
            Self::Ai { message, .. } => write!(f, "AI error: {message}"),
        }
    }
}

impl From<lyra_reader_ai::AiError> for LyraReaderFfiError {
    fn from(error: lyra_reader_ai::AiError) -> Self {
        let code = AiErrorCode::of(&error);
        Self::Ai {
            severity: code.severity(),
            code,
            message: error.to_string(),
        }
    }
}

impl std::error::Error for LyraReaderFfiError {}

impl From<lyra_reader_core::LyraReaderError> for LyraReaderFfiError {
    fn from(error: lyra_reader_core::LyraReaderError) -> Self {
        let severity = ErrorSeverity::from(error.severity);
        let message = error.to_string();
        match error.code {
            ErrorCode::BackendUnavailable | ErrorCode::GpuUnavailable => {
                Self::Backend { message, severity }
            }
            ErrorCode::InvalidArgument => Self::InvalidArgument { message, severity },
            // A read-only document is a policy refusal, not a parse failure; keep the sentence
            // exactly as the signature status reports it (no `ReadOnly:` prefix).
            ErrorCode::ReadOnly => Self::Document {
                message: error.message,
                severity,
            },
            _ => Self::Document { message, severity },
        }
    }
}

/// Value-typed document summary, safe to copy across the boundary.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DocumentSummary {
    /// Absolute or user-supplied path the document was opened from.
    pub path: String,
    /// The one identity every cache uses: canonical path + SHA-256 of the bytes.
    ///
    /// The shell gets the same value from [`LyraReaderDocument::document_id`] when it keeps the
    /// document open; a probe returns it so one-shot callers (the CLI, checks) can compute the
    /// same keys without opening twice.
    pub document_id: String,
    pub page_count: u32,
    /// First page size in points, already accounting for `/Rotate` and `/UserUnit`.
    pub first_page_width_pt: f64,
    pub first_page_height_pt: f64,
    /// `/Rotate` of the first page, in degrees (0/90/180/270).
    pub rotation_degrees: i32,
    pub is_encrypted: bool,
    /// True when the file is an XFA form; the page count and size then describe the synthetic
    /// read-only rendering, not the (usually blank) PDF page tree.
    pub is_xfa: bool,
    /// Which backend produced this summary (for diagnostics in the UI).
    pub backend: String,
}

/// One kind of evidence that a document carries a digital signature.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SignatureEvidenceRecord {
    /// Stable machine name: `sigFlags`, `docMdp`, `signatureField`, `dss` or `pdfium`.
    pub kind: String,
    /// The concrete dictionary fact, for the read-only banner and the logs.
    pub detail: String,
}

/// What the signature check found when a document was opened.
///
/// A signed document is read-only **in place**: every command that would rewrite the file itself
/// is refused by the engine with [`Self::read_only_reason`], and the shell disables those
/// commands and shows the same sentence. Commands that write a new file (extract, merge, split,
/// save edited/filled/properties copy, annotation copy export) remain available; a modified copy
/// has its signature material stripped so it cannot look signed but be invalid.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SignatureStatusRecord {
    pub signed: bool,
    pub evidence: Vec<SignatureEvidenceRecord>,
    /// The one explanation every in-place write refusal uses; `None` for an unsigned document.
    pub read_only_reason: Option<String>,
}

/// One widget of an AcroForm field, in view space (points, top-left origin).
#[derive(Debug, Clone, uniffi::Record)]
pub struct FormWidgetRecord {
    /// 0-based page the widget annotation is on.
    pub page: u32,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
    /// `/AS`: the button state name; empty for a text widget.
    pub state: String,
}

/// One option of a choice or radio field.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FormOptionRecord {
    /// The value written to `/V`.
    pub value: String,
    /// The label the reader shows.
    pub label: String,
}

/// One AcroForm field, read from the widget dictionaries.
///
/// `kind` is one of `text`, `checkBox`, `radio`, `comboBox`, `listBox`, `signature`. Every
/// rectangle is in view space — the same convention as [`AnnotationRecord`] — and comes from the
/// widget's `/Rect` through the page's `/CropBox`, `/Rotate` and `/UserUnit`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FormFieldRecord {
    /// Stable identity for a save: `f<object number>` of the field dictionary.
    pub id: String,
    /// Fully-qualified `/T` name.
    pub name: String,
    pub kind: String,
    /// Page of the first widget.
    pub page: u32,
    /// The first widget's rectangle, view space.
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
    /// `/V` for a text or choice field, or the selected state name of a button.
    pub value: Option<String>,
    /// Selected option indices for a choice or radio field.
    pub selected: Vec<u32>,
    /// Whether a check box's `/V`/`/AS` is on.
    pub checked: bool,
    pub widgets: Vec<FormWidgetRecord>,
    pub options: Vec<FormOptionRecord>,
    /// False for a signature field, a read-only field, or any field while the file is encrypted.
    pub editable: bool,
    pub multiline: bool,
    pub max_length: Option<u32>,
    pub font_size_pt: f64,
    pub required: bool,
}

/// The form facts and fields of a document.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FormInfoRecord {
    pub fields: Vec<FormFieldRecord>,
    /// Encrypted files are read (when the caller has the password) but refused for filling.
    pub encrypted: bool,
    /// The file header's version, e.g. `1.7`.
    pub pdf_version: String,
    pub page_count: u32,
    /// Why filling is disabled, when it is. Readable and shown to the reader.
    pub refusal: Option<String>,
}

/// One field value the shell asks the writer to put into the document.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FormFieldValueRecord {
    pub field_id: String,
    /// A text field's new value, or a choice's chosen value.
    pub text: Option<String>,
    /// A check box's new state.
    pub checked: Option<bool>,
    /// A radio group's or choice's selected option index.
    pub selected: Option<u32>,
}

/// What a successful form save did.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FormSaveReport {
    pub destination_path: String,
    pub written_field_ids: Vec<String>,
    pub appended_bytes: u64,
    pub backup_path: Option<String>,
    pub cleaned_temporary_files: u32,
    pub source_bytes_preserved: bool,
}

/// One kind of annotation or field a flattened copy baked, and how many of it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FlattenKindCountRecord {
    pub kind: String,
    pub count: u32,
}

/// One annotation a flattened copy deliberately keeps, with the reason a person can read.
#[derive(Debug, Clone, uniffi::Record)]
pub struct KeptAnnotationRecord {
    pub page: u32,
    pub kind: String,
    pub reason: String,
    pub has_comment: bool,
}

/// One form field a flattened copy deliberately keeps.
#[derive(Debug, Clone, uniffi::Record)]
pub struct KeptFieldRecord {
    pub name: String,
    pub kind: String,
    pub reason: String,
}

/// What a successful flattened copy did.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FlattenReportRecord {
    pub destination_path: String,
    pub pages: u32,
    pub flattened_annotations: u32,
    pub flattened_annotation_kinds: Vec<FlattenKindCountRecord>,
    pub flattened_fields: u32,
    pub flattened_field_kinds: Vec<FlattenKindCountRecord>,
    pub kept_annotations: Vec<KeptAnnotationRecord>,
    pub kept_fields: Vec<KeptFieldRecord>,
    pub sticky_notes_kept: u32,
    pub links_kept: u32,
    pub comments_not_carried: u32,
    pub signature_fields_removed: u32,
    pub output_bytes: u64,
    pub cleaned_temporary_files: u32,
}

/// The facts and editable `/Info` entries of a document.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DocumentInfoRecord {
    pub title: String,
    pub author: String,
    pub subject: String,
    pub keywords: String,
    pub page_count: u32,
    pub pdf_version: String,
    pub is_encrypted: bool,
    pub has_info_dictionary: bool,
}

/// What a successful properties save did.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PropertiesSaveReport {
    pub destination_path: String,
    pub written_keys: Vec<String>,
    pub appended_bytes: u64,
    pub backup_path: Option<String>,
    pub cleaned_temporary_files: u32,
    pub source_bytes_preserved: bool,
}

/// How the session lays pages out horizontally.
///
/// Separate from the older [`lyra_reader_session::Layout`] command enum because only the two
/// modes the shell can actually draw cross the FFI boundary today. `Facing` means the book
/// convention: page 1 alone, then 2–3, 4–5, … with odd pages on the right.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ReaderLayout {
    Continuous,
    Facing,
}

impl ReaderLayout {
    fn session(self) -> LayoutMode {
        match self {
            Self::Continuous => LayoutMode::Continuous,
            Self::Facing => LayoutMode::Facing,
        }
    }
}

/// The engine handle owned by the shell.
///
/// It carries no per-document state yet, so it is cheap to construct and safe to hand
/// to several views; long-lived documents arrive with M1.
#[derive(Debug, uniffi::Object)]
pub struct LyraReaderEngine {
    config: EngineConfig,
}

#[uniffi::export]
impl LyraReaderEngine {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            config: EngineConfig::default(),
        })
    }

    /// Engine version (from the crate metadata).
    pub fn version(&self) -> String {
        ENGINE_VERSION.to_string()
    }

    /// Which PDF backend this build uses.
    pub fn backend(&self) -> String {
        backend_description().to_string()
    }

    /// How many raster threads the engine would use on this machine.
    pub fn raster_threads(&self) -> u32 {
        self.config.effective_raster_threads() as u32
    }

    /// Opens `path`, summarizes it and closes it again.
    ///
    /// Long-lived document handles, page textures and event streams are M1 work; this
    /// method exists so the shell can show real page counts today and so the control
    /// plane is exercised end to end.
    pub fn probe_document(
        &self,
        path: String,
        password: Option<String>,
    ) -> Result<DocumentSummary, LyraReaderFfiError> {
        let source = std::path::Path::new(&path);
        let prepared = match lyra_reader_xfa::prepare(source, password.as_deref()) {
            Ok(prepared) => prepared,
            Err(lyra_reader_xfa::XfaError::PasswordRequired) => {
                return Err(lyra_reader_core::LyraReaderError::new(
                    ErrorCode::Encrypted,
                    "the document is password protected",
                )
                .into());
            }
            Err(_) => None,
        };
        let backend = match prepared.as_ref() {
            Some(prepared) => match &prepared.pdf {
                Some(bytes) => PdfiumBackend::open_bytes(bytes.clone(), source)?,
                None => PdfiumBackend::open(source, password.as_deref())?,
            },
            None => PdfiumBackend::open(source, password.as_deref())?,
        };

        let page_count = backend.page_count();
        let (width, height, rotation) = if page_count > 0 {
            let info = backend.page_info(PageIndex(0))?;
            let view = info.geometry.view_size(1.0);
            (view.width, view.height, info.geometry.rotation.degrees())
        } else {
            (0.0, 0.0, 0)
        };

        let document_id = crate::document_id::DocumentId::of(source)?
            .key()
            .to_string();
        Ok(DocumentSummary {
            path,
            document_id,
            page_count,
            first_page_width_pt: width,
            first_page_height_pt: height,
            rotation_degrees: rotation,
            is_encrypted: prepared
                .as_ref()
                .map(|prepared| prepared.file.encrypted)
                .unwrap_or_else(|| backend.is_encrypted()),
            is_xfa: prepared.is_some(),
            backend: backend_description().to_string(),
        })
    }
}

/// Which fit preset a zoom request asks for.
///
/// `FitPage` is the shipping macOS "Fit Page": it fits the page's **height** only. Width is
/// `FitWidth`'s job, and a page shorter than the window stays vertically scrollable.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ZoomModeRecord {
    /// A toolbar/pointer step from `percent` by `delta`, clamped to the reader's range.
    Percent,
    /// Fit the page width into the viewport width, leaving the preset inset per side.
    FitWidth,
    /// Fit the page height into the viewport height, leaving the preset inset per side.
    FitPage,
}

/// One zoom resolution request.
///
/// All lengths are points. `calibration` is the display's physical-density factor (`1.0` for
/// the uncalibrated convention); a fit divides the calibrated content size into the available
/// viewport. Only the fields the selected mode needs are read.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct ZoomPolicyRecord {
    pub mode: ZoomModeRecord,
    /// Current whole percentage, for `Percent`.
    pub percent: u32,
    /// Step in whole percent, for `Percent` (may be negative).
    pub delta: i32,
    /// Page (or facing-row) width at 100%, for `FitWidth`.
    pub page_width_pt: f64,
    /// Page (or facing-row) height at 100%, for `FitPage`.
    pub page_height_pt: f64,
    /// Viewport width, for `FitWidth`.
    pub viewport_width_pt: f64,
    /// Viewport height, for `FitPage`.
    pub viewport_height_pt: f64,
    /// Display calibration factor; `100%` is actual size when this is the physical factor.
    pub calibration: f64,
}

/// The one zoom policy: integer percent, 25–400, fit inset 8 pt per side, floor rounding.
///
/// Returns `None` when a fit has no usable geometry (zero/non-finite sizes, viewport not larger
/// than the inset, non-positive calibration), which is exactly when the shell's preset must
/// leave the zoom alone.
#[uniffi::export]
pub fn resolve_zoom(policy: ZoomPolicyRecord) -> Option<u32> {
    use lyra_reader_core::Size;
    use lyra_reader_session::ZoomRequest;
    let request = match policy.mode {
        ZoomModeRecord::Percent => ZoomRequest::Step {
            percent: policy.percent,
            delta: policy.delta,
        },
        ZoomModeRecord::FitWidth => ZoomRequest::FitWidth,
        ZoomModeRecord::FitPage => ZoomRequest::FitPage,
    };
    lyra_reader_session::resolve_zoom_percent(
        request,
        Size::new(policy.page_width_pt, policy.page_height_pt),
        Size::new(policy.viewport_width_pt, policy.viewport_height_pt),
        policy.calibration,
    )
}

/// Clamp a scroll offset to `0 … max(0, content height − viewport height)`.
#[uniffi::export]
pub fn clamp_scroll(offset_pt: f64, content_height_pt: f64, viewport_height_pt: f64) -> f64 {
    lyra_reader_session::clamp_scroll(offset_pt, content_height_pt, viewport_height_pt)
}

/// Lowest offered zoom percentage; the shell reads it instead of hard-coding 25.
#[uniffi::export]
pub fn zoom_min_percent() -> u32 {
    lyra_reader_session::MIN_ZOOM_PERCENT
}

/// Highest offered zoom percentage; the shell reads it instead of hard-coding 400.
#[uniffi::export]
pub fn zoom_max_percent() -> u32 {
    lyra_reader_session::MAX_ZOOM_PERCENT
}

/// Inset the fit presets leave on each side; the shell reads it instead of hard-coding 8.
#[uniffi::export]
pub fn zoom_preset_inset_pt() -> f64 {
    lyra_reader_session::ZOOM_PRESET_INSET_PT
}

/// One page placement for [`plan_tiles`], in content points (top-left origin).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct TilePlanPageRecord {
    pub page: u32,
    pub top_pt: f64,
    pub left_pt: f64,
    /// Display width; a facing spread's second page carries its horizontal offset in `left_pt`.
    pub width_pt: f64,
    /// Display height (a torn page's paper height, without the gap).
    pub height_pt: f64,
    /// The page's display top with region-card gaps applied. Only the torn branch reads it.
    pub display_top_pt: f64,
    /// Page-local Y of an inside-page tear, when one is open on this page.
    pub tear_split_pt: Option<f64>,
    /// Height of the tear's gap, in content points (0 when the page is not torn).
    pub tear_gap_pt: f64,
}

/// One tile the shell's cache holds right now, with its real bitmap size.
///
/// The prefetch ring's byte estimate uses these instead of a full-tile estimate: an edge tile
/// is a fraction of a full one, and the ring decision is about bytes (ADR 0007).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct TilePlanCachedTileRecord {
    pub page: u32,
    pub lod: u8,
    pub x: u32,
    pub y: u32,
    /// Exact `PageImage.bgra.count`, not a size inferred from the tile edge.
    pub bytes: u64,
}

/// One tile quad the shell drew last update, for the drawer-retention rule.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct TilePlanPriorTileRecord {
    pub page: u32,
    pub lod: u8,
    pub x: u32,
    pub y: u32,
    /// Content-space left edge of the quad (not the page's).
    pub left_pt: f64,
}

/// Everything one viewport update needs for its tile plan.
///
/// Lengths are points, `zoom` is the viewer scale, `lod` the tile-pyramid level (`2^lod` is the
/// raster scale), and `tile_size_px` the LOD-0 tile edge in device pixels. The prefetch settings
/// are the shell's resolved values for its measurement environment overrides; `None` means the
/// measured default (`max(8 MiB, cache_budget / 3)` for the band, the ladder for the ring).
#[derive(Debug, Clone, uniffi::Record)]
pub struct TilePlanRequestRecord {
    /// The visible content rect: what the reader can actually see.
    pub viewport_x_pt: f64,
    pub viewport_y_pt: f64,
    pub viewport_width_pt: f64,
    pub viewport_height_pt: f64,
    /// `+1` while moving down, `-1` while moving up; only the sign is read.
    pub scroll_direction: f64,
    /// Viewer scale (`zoomPercent / 100 × calibration`).
    pub zoom: f64,
    pub tile_size_px: u32,
    pub lod: u8,
    pub cache_budget_bytes: u64,
    /// `LYRA_READER_PREFETCH_BAND_MIB` in bytes, when the measurement override is set.
    pub band_budget_override_bytes: Option<u64>,
    /// `LYRA_READER_PREFETCH_RING_VH`, when the measurement override is set.
    pub ring_override_vh: Option<f64>,
    /// `LYRA_READER_PREFETCH_COLUMNS` (columns kept ready beyond the on-screen ones).
    pub prefetch_columns: u32,
    /// `LYRA_READER_PREFETCH_ALL_COLUMNS=1`: the pre-change "every column" measurement mode.
    pub want_all_columns: bool,
    /// Width of the open right drawer in screen points (0 when no drawer is open).
    pub drawer_width_pt: f64,
    /// True while the drawer is still animating.
    pub right_panel_layout_moving: bool,
    pub pages: Vec<TilePlanPageRecord>,
    pub cached_tiles: Vec<TilePlanCachedTileRecord>,
    pub prior_tiles: Vec<TilePlanPriorTileRecord>,
}

/// What class of work a planned tile belongs to.
///
/// The planner emits `Visible` and `TargetLodPrefetch`; the other two are the scheduler's
/// vocabulary for tasks the shell does not queue today (a lower-LOD preview is drawn from the
/// cache, thumbnails never go through this path).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TilePriorityRecord {
    Visible,
    TargetLodPrefetch,
    OneLodLower,
    Thumbnail,
}

/// A tile identity without its payload.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TilePlanKeyRecord {
    pub page: u32,
    pub lod: u8,
    pub x: u32,
    pub y: u32,
}

/// One page's band, in tile rows and columns.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TilePlanPageSpansRecord {
    pub page: u32,
    pub first_column: u32,
    pub last_column: u32,
    pub first_row: u32,
    pub last_row: u32,
}

/// One tile to rasterize, in submission order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TilePlanTileRecord {
    pub page: u32,
    pub lod: u8,
    pub x: u32,
    pub y: u32,
    pub priority: TilePriorityRecord,
    /// True when the tile is outside the viewport (ring work).
    pub prefetch: bool,
}

/// The batch plan for one viewport update.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TilePlanRecord {
    pub lod: u8,
    /// The chosen prefetch-ring distance, in viewport heights.
    pub ring_vh: f64,
    /// Every page the band covers, in placement order.
    pub pages: Vec<TilePlanPageSpansRecord>,
    /// Every tile of the band, visible first, then the ring by distance.
    pub tiles: Vec<TilePlanTileRecord>,
    /// The pinned set: every band tile plus the drawer-retained columns.
    pub pinned: Vec<TilePlanKeyRecord>,
    /// Prior tile quads kept because an open drawer covers them (pinned, not scheduled).
    pub retained: Vec<TilePlanKeyRecord>,
}

/// Compute the tile plan for **one** viewport update (ADR 0007 / audit C5).
///
/// The shell keeps the cache, the eviction order, the texture upload and rasterization; this
/// call owns the decision — the prefetch ring, each page's band rows and columns, the pinned
/// set and the raster submission order. One call per viewport update, never one per tile.
///
/// `None` means the request violated an invariant the shell cannot produce (non-finite
/// geometry, a zero tile edge, an out-of-range LOD, oversized lists). The caller reports it
/// instead of fabricating a plan.
#[uniffi::export]
pub fn plan_tiles(request: TilePlanRequestRecord) -> Option<TilePlanRecord> {
    let plan_request = render_plan::PlanRequest {
        viewport: render_plan::PlanRect::new(
            request.viewport_x_pt,
            request.viewport_y_pt,
            request.viewport_width_pt,
            request.viewport_height_pt,
        ),
        scroll_direction: request.scroll_direction,
        zoom: request.zoom,
        tile_size_px: request.tile_size_px,
        lod: request.lod,
        cache_budget_bytes: request.cache_budget_bytes,
        band_budget_override_bytes: request.band_budget_override_bytes,
        ring_override_vh: request.ring_override_vh,
        prefetch_columns: request.prefetch_columns,
        want_all_columns: request.want_all_columns,
        drawer_width_pt: request.drawer_width_pt,
        right_panel_layout_moving: request.right_panel_layout_moving,
        pages: request
            .pages
            .iter()
            .map(|page| render_plan::PlanPage {
                page: page.page,
                top_pt: page.top_pt,
                left_pt: page.left_pt,
                width_pt: page.width_pt,
                height_pt: page.height_pt,
                display_top_pt: page.display_top_pt,
                tear_split_pt: page.tear_split_pt,
                tear_gap_pt: page.tear_gap_pt,
            })
            .collect(),
        cached_tiles: request
            .cached_tiles
            .iter()
            .map(|tile| render_plan::CachedTile {
                page: tile.page,
                lod: tile.lod,
                x: tile.x,
                y: tile.y,
                bytes: tile.bytes,
            })
            .collect(),
        prior_tiles: request
            .prior_tiles
            .iter()
            .map(|tile| render_plan::PriorTile {
                page: tile.page,
                lod: tile.lod,
                x: tile.x,
                y: tile.y,
                left_pt: tile.left_pt,
            })
            .collect(),
    };
    let plan = render_plan::plan_tiles(&plan_request)?;
    let key = |key: render_plan::PlannedKey| TilePlanKeyRecord {
        page: key.page,
        lod: key.lod,
        x: key.x,
        y: key.y,
    };
    Some(TilePlanRecord {
        lod: plan.lod,
        ring_vh: plan.ring_vh,
        pages: plan
            .pages
            .iter()
            .map(|page| TilePlanPageSpansRecord {
                page: page.page,
                first_column: page.first_column,
                last_column: page.last_column,
                first_row: page.first_row,
                last_row: page.last_row,
            })
            .collect(),
        tiles: plan
            .tiles
            .iter()
            .map(|tile| TilePlanTileRecord {
                page: tile.page,
                lod: tile.lod,
                x: tile.x,
                y: tile.y,
                priority: match tile.priority {
                    render_plan::TilePriority::Visible => TilePriorityRecord::Visible,
                    render_plan::TilePriority::TargetLodPrefetch => {
                        TilePriorityRecord::TargetLodPrefetch
                    }
                    render_plan::TilePriority::OneLodLower => TilePriorityRecord::OneLodLower,
                    render_plan::TilePriority::Thumbnail => TilePriorityRecord::Thumbnail,
                },
                prefetch: tile.prefetch,
            })
            .collect(),
        pinned: plan
            .pinned
            .iter()
            .map(|key_value| key(*key_value))
            .collect(),
        retained: plan
            .retained
            .iter()
            .map(|key_value| key(*key_value))
            .collect(),
    })
}

/// `Page 3`, `Pages 1-3`, `Pages 1, 3, 5` (1-based, sorted and de-duplicated).
#[uniffi::export]
pub fn page_label(pages: Vec<u32>) -> String {
    crate::format::page_label(&pages)
}

/// `1-12 and 109-120` (1-based, sorted into inclusive runs).
#[uniffi::export]
pub fn page_ranges_label(pages: Vec<u32>) -> String {
    crate::format::page_ranges_label(&pages)
}

/// `1-3, 5, 8-9` (1-based, sorted and de-duplicated).
#[uniffi::export]
pub fn compact_page_ranges(pages: Vec<u32>) -> String {
    crate::format::compact_page_ranges(&pages)
}

/// `page 1`, `pages 1–3`, `pages 1, 3, 5` (**0-based** input, as the page menus hold it).
#[uniffi::export]
pub fn page_list(pages: Vec<u32>) -> String {
    crate::format::page_list(&pages)
}

/// The layered-summary row's span label; `kind` is `abstract`, `sections` or `pages`.
#[uniffi::export]
#[allow(clippy::too_many_arguments)]
pub fn page_span_label(
    kind: String,
    pages: Vec<u32>,
    page_start: u32,
    page_end: u32,
    covered_page_end: u32,
    truncated: bool,
    page_count: u32,
) -> String {
    crate::format::page_span_label(
        &kind,
        &pages,
        page_start,
        page_end,
        covered_page_end,
        truncated,
        page_count,
    )
}

/// The historical sidebar/passages display of a PDF `/M` value: clock digits as written.
///
/// A zoned value is deliberately **not** converted; see the crate's format module. `None`
/// means the annotation has no `/M`; an unrecognized string is returned unchanged.
#[uniffi::export]
pub fn pdf_date_display(value: String) -> Option<String> {
    crate::format::pdf_date_display(&value)
}

/// The instant a PDF date names, in milliseconds since the Unix epoch, applying its offset.
///
/// `None` for a string that is not the PDF date shape (the export then sorts it last rather
/// than inventing a time).
#[uniffi::export]
pub fn pdf_date_millis(value: String) -> Option<i64> {
    crate::format::pdf_date_millis(&value)
}

/// Size of a page in points, already accounting for `/Rotate`.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct PageSize {
    pub width_pt: f64,
    pub height_pt: f64,
    pub rotation_degrees: i32,
}

/// A rasterized page, ready to be uploaded to the GPU.
///
/// `pixels` is BGRA (sRGB), exactly what the GPU layer expects — see
/// `docs/03-rendering.md` §5. The shell uploads it and draws a quad; until the tile
/// pipeline lands (T1.5–T1.7) a whole page is one texture.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PageBitmap {
    pub width_px: u32,
    pub height_px: u32,
    pub stride: u32,
    pub width_pt: f64,
    pub height_pt: f64,
    /// Scale actually used. May be **lower** than requested: see
    /// [`LyraReaderDocument::rasterize_page`]'s clamp, which keeps a single page texture inside
    /// a sane memory budget until tiles land (T1.5).
    pub scale_used: f64,
    pub pixels: Vec<u8>,
}

/// Where a metadata field came from, as the panel shows it.
///
/// `Absent` is the only correct source of an empty field: "no value" is not a guess.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum, serde::Serialize, serde::Deserialize)]
pub enum MetadataSourceKind {
    Absent,
    Xmp,
    Info,
    FirstPage,
    PageFurniture,
    Text,
    ArxivDerived,
    Edited,
}

/// One field with its value(s) and the source that produced them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MetadataFieldRecord {
    pub values: Vec<String>,
    pub source: MetadataSourceKind,
    /// Stable code for logs and checks (`xmp`, `first-page`, …).
    pub source_code: String,
    /// Short human label (`XMP`, `page 1 guess`, …).
    pub source_label: String,
    /// `embedded`, `identified`, `guessed`, `edited`, or `none`.
    pub trust: String,
    /// Whether the panel must mark this value as a guess.
    pub guessed: bool,
}

/// The recognised metadata for one document, plus the BibTeX its values generate.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DocumentMetadataRecord {
    pub title: MetadataFieldRecord,
    pub authors: MetadataFieldRecord,
    pub venue: MetadataFieldRecord,
    pub year: MetadataFieldRecord,
    pub doi: MetadataFieldRecord,
    pub arxiv_id: MetadataFieldRecord,
    pub bibtex: String,
}

/// The values the shell sends back after the reader corrected a field.
///
/// Provenance is not part of the request: an edited value is the reader's, not the file's.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MetadataDraftRecord {
    pub title: String,
    pub authors: Vec<String>,
    pub venue: String,
    pub year: String,
    pub doi: String,
    pub arxiv_id: String,
}

fn metadata_kind(source: Option<MetadataSource>) -> MetadataSourceKind {
    match source {
        None => MetadataSourceKind::Absent,
        Some(MetadataSource::Xmp) => MetadataSourceKind::Xmp,
        Some(MetadataSource::Info) => MetadataSourceKind::Info,
        Some(MetadataSource::FirstPage) => MetadataSourceKind::FirstPage,
        Some(MetadataSource::PageFurniture) => MetadataSourceKind::PageFurniture,
        Some(MetadataSource::Text) => MetadataSourceKind::Text,
        Some(MetadataSource::ArxivDerived) => MetadataSourceKind::ArxivDerived,
        Some(MetadataSource::Edited) => MetadataSourceKind::Edited,
    }
}

fn metadata_field(field: &lyra_reader_metadata::MetadataField) -> MetadataFieldRecord {
    MetadataFieldRecord {
        values: field.values.clone(),
        source: metadata_kind(field.source),
        source_code: field.source_code().to_string(),
        source_label: field.source_label().to_string(),
        trust: field.trust().to_string(),
        guessed: field.is_guessed(),
    }
}

fn metadata_report(metadata: &RecognizedMetadata) -> DocumentMetadataRecord {
    DocumentMetadataRecord {
        title: metadata_field(&metadata.title),
        authors: metadata_field(&metadata.authors),
        venue: metadata_field(&metadata.venue),
        year: metadata_field(&metadata.year),
        doi: metadata_field(&metadata.doi),
        arxiv_id: metadata_field(&metadata.arxiv_id),
        bibtex: metadata.bibtex(),
    }
}

/// Generates the BibTeX entry for the values currently in the panel.
///
/// The same Rust function generates the preview, the clipboard payload and the `.bib` file,
/// so those three cannot disagree with each other.
#[uniffi::export]
pub fn generate_bibtex_entry(draft: MetadataDraftRecord) -> String {
    BibEntry {
        title: draft.title,
        authors: draft.authors,
        venue: draft.venue,
        year: draft.year,
        doi: draft.doi,
        arxiv_id: draft.arxiv_id,
    }
    .to_bibtex()
}

/// What the bundled appearance font can and cannot draw in a given string.
///
/// The text-box editor calls this while typing. A missing character is not rejected and does not
/// become `?`: the writer encodes it through `.notdef` with its exact Unicode in `/ToUnicode`, so
/// `/Contents` and text extraction stay exact while the page shows a missing-glyph box.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppearanceCoverageRecord {
    /// Family name of the bundled font (currently `LyraReader Sans SC`).
    pub family: String,
    /// Glyphs in the shipped subset, for the diagnostics line.
    pub glyph_count: u32,
    /// Characters the font cannot draw, de-duplicated, in first-appearance order.
    pub missing: Vec<String>,
}

/// Reports which characters of `text` the bundled appearance font cannot draw.
///
/// This is a read-only query; it never changes the document and never rejects input.
#[uniffi::export]
pub fn appearance_font_coverage(
    text: String,
) -> Result<AppearanceCoverageRecord, LyraReaderFfiError> {
    let coverage = lyra_reader_pdfium::appearance_coverage(&text)?;
    Ok(AppearanceCoverageRecord {
        family: coverage.family,
        glyph_count: u32::from(coverage.glyph_count),
        missing: coverage
            .missing
            .into_iter()
            .map(|character| character.to_string())
            .collect(),
    })
}

/// The XFA facts the shell needs to explain the document and to disable write commands.
///
/// An XFA form is rendered **read-only from its XML** into a synthetic in-memory PDF. There is
/// no annotation write-back, no form filling, no content editing and no "save a copy" of edits:
/// every command that would write is refused with [`Self::read_only_reason`], and the shell
/// disables those controls with the same sentence. Reading aids (zoom, scroll, search,
/// selection, summaries) are unaffected because they run on the synthetic PDF.
#[derive(Clone, Debug, uniffi::Record)]
pub struct XfaStatusRecord {
    /// True when the file carries `/AcroForm /XFA`; false for every ordinary PDF.
    pub is_xfa: bool,
    /// True when the synthetic PDF was produced and is what the document handle renders.
    pub rendered: bool,
    /// Pages in the rendering (not the source PDF's page tree).
    pub page_count: u32,
    /// Fields found in the template.
    pub field_count: u32,
    /// Packet names in `/XFA` order.
    pub packet_names: Vec<String>,
    /// What the renderer could not draw, in a person's words. Empty only for a complete form.
    pub skipped: Vec<String>,
    /// Set when the template was detected but could not be rendered; the original PDF is open.
    pub error: Option<String>,
    /// The one explanation every XFA write refusal uses; `None` for an ordinary PDF.
    pub read_only_reason: Option<String>,
    /// The source file carries an encryption dictionary (even if it opened without a prompt).
    pub encrypted: bool,
}

/// An open document.
///
/// Long-lived by design: the shell opens once and then asks for pages as the reader
/// navigates. Threading follows `docs/02-architecture.md` §3 — the backend is
/// `Send + Sync`, and rasterization happens on the caller's thread for now (the raster
/// pool arrives with T1.3).
#[derive(uniffi::Object)]
pub struct LyraReaderDocument {
    backend: PdfiumBackend,
    path: String,
    /// Canonical path + content hash, computed once at open. Every cache key and every tab
    /// identity derives from this, so a symlink and its target are one document.
    document_id: crate::document_id::DocumentId,
    /// Kept so [`LyraReaderDocument::reopen`] can hand a worker its own copy.
    password: Option<String>,
    /// XFA state, when this document is a form rendered from its XML. The synthetic bytes are
    /// kept so a worker copy can open its own PDFium handle without touching the source file.
    xfa: Option<XfaState>,
    /// Signature evidence, read once when the document was opened.
    ///
    /// The decision is a property of the file's bytes, and the file is not written while this
    /// handle lives (a replacement marks the handle stale), so the status cannot change. Worker
    /// copies inherit it instead of paying for a second structural read.
    signature: lyra_reader_pdfium::SignatureStatus,
    /// Page sizes in points, measured lazily on the first layout request.
    ///
    /// `None` means PDFium could not measure that page. The engine must not invent a size for
    /// it: layout still uses [`UNKNOWN_LAYOUT_PAGE_SIZE`] to keep the scrolling geometry users
    /// already see, but placement records report the size as absent and the shell applies the
    /// fallback explicitly. Measuring is deliberately not part of open: a 900-page document
    /// would pay 900 PDFium page loads before its first frame.
    page_sizes: Mutex<Option<CachedPageSizes>>,
    /// Last computed layout, keyed by the mode and page gap it was built for.
    layout: Mutex<Option<(ReaderLayout, f64, Arc<DocumentLayout>)>>,
    /// Parsed reference list, with the citation style it implies (scanning the tail pages is
    /// not free, and neither ever changes while the document is open).
    ///
    /// `Arc` so [`LyraReaderDocument::citations`] can borrow the style without cloning a hundred
    /// entries per page. The persistent index cache stores exactly these records.
    references: Mutex<Option<Arc<ReferenceCache>>>,
    /// Figure/table captions with their preview regions; same caching rule as `references`.
    figures: Mutex<Option<Vec<FigureRecord>>>,
    /// Annotations already stored in the PDF, in view space; same caching rule as `figures`.
    /// The cached scan also carries what could not be decoded, so callers cannot see the
    /// readable half without being able to ask for the unreadable count.
    annotations: Mutex<Option<AnnotationScanCache>>,
    /// Recognised metadata; page one does not change while the document is open.
    metadata: Mutex<Option<DocumentMetadataRecord>>,
    /// Outline, flattened once. Cheap to store and part of the cached index, so a warm open does
    /// not touch the PDF's outline tree at all.
    outline: Mutex<Option<Vec<OutlineEntry>>>,
    /// Citation spans per page, in view space. Filled by the reference scan (which already has
    /// every page's text in hand) and from the cache; pages outside the scan window fall back to
    /// a one-page read. This is what makes a warm click independent of the PDF text layer.
    citations: Mutex<Option<std::collections::BTreeMap<u32, Vec<CitationRecord>>>>,
    /// State of the persistent index cache: whether it was looked up, what was found, and the
    /// timings/counters the checks and the measurement report.
    index: Mutex<IndexRuntime>,
    /// Set when [`LyraReaderDocument::replace_with_annotations`] has replaced the file on disk. The
    /// in-memory PDFium document is the pre-replacement one, so every content read would be a
    /// stale answer; the shell reopens the file immediately and this makes a missed reopen a
    /// loud error instead of a quiet one.
    replaced: std::sync::atomic::AtomicBool,
    /// Plain text per page, extracted once for AI context building. Text cannot change while
    /// the document is open (the annotation writer replaces the file, and then the shell
    /// reopens it), so this cache has the document's lifetime.
    ai_text: Mutex<std::collections::HashMap<u32, (String, Vec<PageChar>)>>,
    /// Line-aware selection geometry, one small LRU per document. Kept separate from the AI
    /// text cache (which has the document's lifetime) because the selection structure is
    /// rebuilt per page and is much larger.
    text_pages: Mutex<TextPageCache>,
}

/// The XFA handle state: the shell-facing facts plus the in-memory synthetic PDF.
#[derive(Clone)]
struct XfaState {
    status: XfaStatusRecord,
    synthetic_pdf: Option<std::sync::Arc<Vec<u8>>>,
}

/// The parsed reference list together with the citation style it implies.
///
/// One cache rather than two: both are derived from the same scan of the document, and the
/// detector must judge a superscript run against exactly the list the resolver will answer from.
///
/// `bibliography` is the live attribution view built from the same records as `lists`; keeping
/// it here means a click does not rebuild (or re-parse) the lists. `lists` is what the persistent
/// cache stores, and `bibliography` derives from it on a cache hit.
#[derive(Clone)]
struct ReferenceCache {
    /// The document-wide list's records: what [`LyraReaderDocument::references`] returns.
    records: Vec<ReferenceRecord>,
    style: lyra_reader_text::CitationStyle,
    /// Every list, in reading order, as the persistent cache stores it.
    lists: Vec<crate::index_cache::CachedReferenceList>,
    /// The same lists as live `lyra_reader_text` values, with the sections/regions a citation
    /// attribution reads.
    bibliography: lyra_reader_text::Bibliography,
}

/// One resolved reference entry and the list a citation on a page was attributed to.
///
/// Returning both in one record matters for the shell and for the checks: the entry is what the
/// preview draws, and the list fields are the evidence that it came from the right bibliography
/// rather than from whichever list happened to print that number.
#[derive(Debug, Clone, PartialEq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResolvedReference {
    /// The entry to preview, with the same geometry [`ReferenceRecord`] always carried.
    pub reference: ReferenceRecord,
    /// Index of the attributed list in reading order (0-based).
    pub list_index: u32,
    /// How many reference lists the document prints.
    pub list_count: u32,
    /// The attributed list's heading, when the document printed one.
    pub list_heading: Option<String>,
    /// First and last page an entry of the attributed list starts on.
    pub list_first_page: Option<u32>,
    pub list_last_page: Option<u32>,
    /// Whether the attributed list is the document-wide one — the list
    /// [`LyraReaderDocument::resolve_citations`] answers from when it has no page.
    pub document_wide: bool,
    /// Why this list was chosen, in one sentence (the `cite` CLI prints the same words).
    pub reason: String,
    /// True when another list also carries the label and no section separated the two; the
    /// document-wide list is then used, as the documented rule requires.
    pub ambiguous: bool,
}

/// What the persistent index cache lookup found when a document was first indexed.
///
/// Reported for checks and measurements (and visible in the app's stderr log), not shown in the
/// UI. `Hit` means no index component was derived from the PDF for this document instance.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IndexCacheOutcome {
    /// No index access has happened yet, so nothing was looked up.
    NotAttempted,
    /// A current-format cache matched the PDF's content identity.
    Hit,
    /// No cache file exists.
    Missing,
    /// A cache exists but was built from different bytes (or a different page count).
    Stale,
    /// The cache could not be parsed. A complete re-index may replace it.
    Corrupt,
    /// The cache has fields this build does not understand; it is preserved and ignored.
    Incompatible,
    /// The cache's format version is newer than this build; it is preserved and ignored.
    FutureVersion,
    /// The cache is disabled for this process (`LYRA_READER_INDEX_CACHE`).
    Disabled,
    /// The cache could not be read (permissions, I/O, oversize); it is preserved.
    Unreadable,
}

/// Counters and timings for one document's index cache.
///
/// All times are microseconds spent in the current process for the current document instance.
/// `derived_parts` is the number of index components built from the PDF (references, figures,
/// metadata, outline); a cache hit leaves it at zero, which is the check that a second open did
/// not reparse anything.
#[derive(Clone, Debug)]
pub struct IndexCacheReport {
    pub outcome: IndexCacheOutcome,
    pub cache_path: String,
    pub cache_bytes: u64,
    /// Time spent hashing the PDF and reading/validating the cache.
    pub validation_micros: u64,
    /// Index components derived from the PDF in this document instance.
    pub derived_parts: u32,
    /// Total time spent deriving those components.
    pub derived_micros: u64,
    /// SHA-256 of the PDF this document's cache is bound to; `None` when hashing was skipped.
    pub content_sha256: Option<String>,
    /// True after a read-only/future file was seen or a write failed: this document will not
    /// write to the cache path.
    pub write_disabled: bool,
    /// Last write failure, for diagnostics; `None` when no write was attempted or it succeeded.
    pub write_error: Option<String>,
}

/// Mutable cache bookkeeping, guarded by `LyraReaderDocument::index`.
struct IndexRuntime {
    attempted: bool,
    outcome: IndexCacheOutcome,
    identity: Option<ContentIdentity>,
    cache_path: Option<PathBuf>,
    cache_bytes: u64,
    validation: Duration,
    derived_parts: u32,
    derived: Duration,
    write_disabled: bool,
    write_error: Option<String>,
}

impl Default for IndexRuntime {
    fn default() -> Self {
        Self {
            attempted: false,
            outcome: IndexCacheOutcome::NotAttempted,
            identity: None,
            cache_path: None,
            cache_bytes: 0,
            validation: Duration::ZERO,
            derived_parts: 0,
            derived: Duration::ZERO,
            write_disabled: false,
            write_error: None,
        }
    }
}

/// Converts a typed content command and its view-space rectangle to PDF user space.
///
/// Shared by the staging methods so the pre-flight and the write it confirms address exactly the
/// same region, including rotated and cropped pages. A free function (not a method) so UniFFI's
/// export of [`LyraReaderDocument`] does not ask its internal command type to cross the FFI.
fn prepare_content_command(
    document: &LyraReaderDocument,
    page: u32,
    command: ContentCommandRecord,
) -> Result<lyra_reader_pdfium::content_edit::ContentCommand, LyraReaderFfiError> {
    use lyra_reader_pdfium::content_edit::ContentCommand;
    document.ensure_not_xfa()?;
    if document.replaced.load(std::sync::atomic::Ordering::Acquire)
        || document.backend.needs_password()
    {
        return Err(LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: "Reopen an unencrypted document before editing its contents.".into(),
        });
    }
    // Convert after the read-only pre-flight: a refused document keeps its exact refusal even if
    // the (unused) command payload is malformed.
    let mut command = content_command(command)?;
    let transform = document
        .backend
        .page_info(PageIndex(page))?
        .geometry
        .view_to_page(1.0)
        .ok_or_else(|| LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: "Singular page geometry".into(),
        })?;
    match &mut command {
        ContentCommand::Transform { bounds, .. }
        | ContentCommand::ReplaceText { bounds, .. }
        | ContentCommand::InsertText { bounds, .. }
        | ContentCommand::Redact { bounds, .. }
        | ContentCommand::InsertImage { bounds, .. }
        | ContentCommand::SetLink { bounds, .. } => {
            *bounds = transform
                .apply_rect(lyra_reader_core::Rect::new(
                    bounds.x,
                    bounds.y,
                    bounds.width,
                    bounds.height,
                ))
                .into();
        }
        ContentCommand::Delete { .. }
        | ContentCommand::ReplaceImage { .. }
        | ContentCommand::CropImage { .. } => {}
    }
    // The shell's positive angle turns clockwise in its Y-down view space. PDF content matrices
    // use Y-up coordinates, including on pages with an intrinsic /Rotate.
    if let ContentCommand::Transform { rotation, .. } = &mut command {
        *rotation = -*rotation;
    }
    Ok(command)
}

/// The page a selection-only AI action sends.
///
/// The request validation already rejects a missing selection for these actions. Keeping the
/// conversion fallible here means widening `requires_selection` (or adding an action to the
/// selection-only set) can never turn a missing field into a process abort.
fn selection_only_page(selection: Option<AiSelectionRange>) -> Result<u32, LyraReaderFfiError> {
    selection
        .map(|selection| selection.page)
        .ok_or_else(|| LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: "a selection-only request has no selection".to_string(),
        })
}

/// Page sizes in document order. `None` is an explicit "PDFium could not measure this page".
///
/// A failed lookup must not become a fabricated US Letter size. Layout keeps the historical
/// fallback so existing documents scroll exactly as before, but the per-page record says the
/// size is unknown and the shell chooses the fallback on its side.
fn collect_page_sizes<F>(count: u32, mut page_size: F) -> Vec<Option<(f64, f64)>>
where
    F: FnMut(u32) -> Result<(f64, f64), LyraReaderFfiError>,
{
    let mut sizes = Vec::with_capacity(count as usize);
    for index in 0..count {
        sizes.push(page_size(index).ok());
    }
    sizes
}

fn document_knowledge_input(
    text: Option<String>,
    pages: Vec<u32>,
) -> Option<DocumentKnowledgeInput> {
    text.map(|text| DocumentKnowledgeInput { text, pages })
}

#[uniffi::export]
impl LyraReaderDocument {
    /// The path this document was opened from.
    pub fn path(&self) -> String {
        self.path.clone()
    }

    /// The document's stable identity: canonical path + SHA-256 of its bytes.
    ///
    /// Computed once when the document was opened and valid for this handle's lifetime. The
    /// shell uses it as the key for the annotation/edit cache, AI conversations, translations,
    /// summaries, document knowledge, recent covers and the index cache. Two paths that resolve
    /// to the same file return the same value; a file whose bytes change gets a new one (the
    /// open handle still describes the bytes it parsed, which is what its other records mean).
    pub fn document_id(&self) -> String {
        self.document_id.key().to_string()
    }

    pub fn page_count(&self) -> u32 {
        self.backend.page_count()
    }

    /// The digital-signature evidence this document was opened with.
    ///
    /// `signed: true` means every command that would rewrite the file itself is refused with
    /// `read_only_reason`; the shell uses the same record to disable those commands and show
    /// the banner. Reading, selection, search, previews, copy exports and saving an annotated
    /// **copy** stay available.
    pub fn signature_status(&self) -> SignatureStatusRecord {
        SignatureStatusRecord {
            signed: self.signature.is_signed(),
            evidence: self
                .signature
                .evidence
                .iter()
                .map(|evidence| SignatureEvidenceRecord {
                    kind: evidence.kind.code().to_string(),
                    detail: evidence.detail.clone(),
                })
                .collect(),
            read_only_reason: self.signature.read_only_reason(),
        }
    }

    /// The XFA facts for this document. `is_xfa: false` for an ordinary PDF.
    ///
    /// The shell uses this record for its short "XFA form · read-only" banner, for the detailed
    /// XFA diagnostics outside the banner, and to disable annotation/form/editing commands. The
    /// engine refuses those commands itself, so a stale button cannot write.
    pub fn xfa_status(&self) -> XfaStatusRecord {
        self.xfa
            .as_ref()
            .map(|state| state.status.clone())
            .unwrap_or(XfaStatusRecord {
                is_xfa: false,
                rendered: false,
                page_count: 0,
                field_count: 0,
                packet_names: Vec::new(),
                skipped: Vec::new(),
                error: None,
                read_only_reason: None,
                encrypted: false,
            })
    }

    /// Page size in points (`/Rotate` applied).
    pub fn page_size_pt(&self, page: u32) -> Result<PageSize, LyraReaderFfiError> {
        let info = self.backend.page_info(PageIndex(page))?;
        let view = info.geometry.view_size(1.0);
        Ok(PageSize {
            width_pt: view.width,
            height_pt: view.height,
            rotation_degrees: info.geometry.rotation.degrees(),
        })
    }

    /// Rasterizes `page` at `scale` (1.0 = 72 dpi) into a BGRA buffer.
    ///
    /// # Clamping
    ///
    /// A whole page is one texture until the tile pipeline lands, so deep zoom would
    /// allocate enormous bitmaps (400% on A4 is 32 MP ≈ 128 MB). The request is therefore
    /// clamped to [`EngineConfig::full_page_max_pixels`] (and to a maximum edge length),
    /// and the scale actually used is reported back in [`PageBitmap::scale_used`]; the
    /// shell keeps drawing the quad at its layout size, so the GPU upscales.
    ///
    /// # Threading
    ///
    /// Callable from any thread: the PDFium backend serialises rendering process-wide,
    /// because PDFium's renderer is not thread-safe even across documents. The shell still
    /// keeps its own queue so the main thread never blocks.
    pub fn rasterize_page(&self, page: u32, scale: f64) -> Result<PageBitmap, LyraReaderFfiError> {
        self.rasterize_page_bitmap(page, scale, false)
    }

    /// Rasterizes `page` with the file's own annotations burned in, for a thumbnail.
    ///
    /// The same page, clamp and threading rules as [`LyraReaderDocument::rasterize_page`]; the only
    /// difference is PDFium's `FPDF_ANNOT` flag. The canvas must keep using the plain method:
    /// it draws annotations itself, with live editing and the app's own cached marks. This one
    /// is for a small preview whose job is to show *where the marks are* — including marks the
    /// canvas does not model. It does not include the reader's cached annotations, which are not part of the PDF.
    pub fn rasterize_page_with_annotations(
        &self,
        page: u32,
        scale: f64,
    ) -> Result<PageBitmap, LyraReaderFfiError> {
        self.rasterize_page_bitmap(page, scale, true)
    }

    fn rasterize_page_bitmap(
        &self,
        page: u32,
        scale: f64,
        annotations: bool,
    ) -> Result<PageBitmap, LyraReaderFfiError> {
        if !(scale.is_finite() && scale > 0.0) {
            return Err(LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: format!("scale must be positive and finite, got {scale}"),
            });
        }

        let page_count = self.backend.page_count();
        lyra_reader_core::checked_page_index(page, page_count, |page| {
            LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: lyra_reader_core::page_out_of_range_message(page, page_count),
            }
        })?;
        let sizes = self.page_sizes();
        let size = match sizes.get(page as usize).copied() {
            Some(Some(size)) => size,
            Some(None) => {
                return Err(LyraReaderFfiError::Document {
                    severity: ErrorSeverity::Document,
                    message: format!(
                        "page {page} has no measurable size; PDFium could not report its geometry"
                    ),
                });
            }
            None => {
                return Err(LyraReaderFfiError::InvalidArgument {
                    severity: ErrorSeverity::Document,
                    message: lyra_reader_core::page_out_of_range_message(page, page_count),
                });
            }
        };
        let scale = clamp_scale(size, scale);

        let mut request = RasterRequest::full_page(PageIndex(page), scale);
        request.flags.annotations = annotations;
        let tile = self.backend.rasterize(&request)?;
        let info = self.backend.page_info(PageIndex(page))?;
        let view = info.geometry.view_size(1.0);

        Ok(PageBitmap {
            width_px: tile.size.width.round() as u32,
            height_px: tile.size.height.round() as u32,
            stride: tile.stride as u32,
            width_pt: view.width,
            height_pt: view.height,
            scale_used: scale,
            pixels: tile.pixels,
        })
    }

    /// Opens an independent copy of this document for another worker thread.
    ///
    /// PDFium documents must not be shared between threads, so a raster pool keeps one
    /// copy per worker; [`LyraReaderDocument::rasterize_tile`] on each copy then runs in
    /// parallel with the others.
    pub fn reopen(&self) -> Result<Arc<LyraReaderDocument>, LyraReaderFfiError> {
        let backend = match self
            .xfa
            .as_ref()
            .and_then(|state| state.synthetic_pdf.as_ref())
        {
            Some(bytes) => {
                PdfiumBackend::open_bytes((**bytes).clone(), std::path::Path::new(&self.path))?
            }
            None => {
                PdfiumBackend::open(std::path::Path::new(&self.path), self.password.as_deref())?
            }
        };
        Ok(Arc::new(LyraReaderDocument {
            backend,
            path: self.path.clone(),
            document_id: self.document_id.clone(),
            password: self.password.clone(),
            xfa: self.xfa.clone(),
            signature: self.signature.clone(),
            page_sizes: Mutex::new(None),
            layout: Mutex::new(None),
            references: Mutex::new(None),
            figures: Mutex::new(None),
            annotations: Mutex::new(None),
            metadata: Mutex::new(None),
            outline: Mutex::new(None),
            citations: Mutex::new(None),
            index: Mutex::new(IndexRuntime::default()),
            replaced: std::sync::atomic::AtomicBool::new(false),
            ai_text: Mutex::new(std::collections::HashMap::new()),
            text_pages: Mutex::new(TextPageCache::default()),
        }))
    }

    /// Rasterizes one tile of `page` at a discrete LOD (`scale = 2^lod`).
    ///
    /// Tile `(tile_x, tile_y)` covers device pixels `[x·S, y·S, S, S]` at that scale,
    /// which is `S / 2^lod` points of view space. Deep zoom costs more tiles rather than
    /// one unbounded bitmap — the memory clamp in [`LyraReaderDocument::rasterize_page`] never
    /// applies here, because a tile is small by construction.
    pub fn rasterize_tile(
        &self,
        page: u32,
        lod: u8,
        tile_x: u32,
        tile_y: u32,
        tile_size: u32,
    ) -> Result<TileBitmap, LyraReaderFfiError> {
        let max_lod = EngineConfig::default().max_lod;
        if lod > max_lod {
            return Err(LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: format!("lod {lod} exceeds the maximum of {max_lod}"),
            });
        }
        if tile_size == 0 || tile_size > 4096 {
            return Err(LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: format!("tile size {tile_size} is outside 1..=4096"),
            });
        }
        let page_count = self.backend.page_count();
        lyra_reader_core::checked_page_index(page, page_count, |page| {
            LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: lyra_reader_core::page_out_of_range_message(page, page_count),
            }
        })?;

        let scale = 2f64.powi(i32::from(lod));
        let tile_size_pt = f64::from(tile_size) / scale;
        let request = RasterRequest::tile(
            PageIndex(page),
            scale,
            (
                f64::from(tile_x) * tile_size_pt,
                f64::from(tile_y) * tile_size_pt,
            ),
            (tile_size_pt, tile_size_pt),
        );

        let tile = self.backend.rasterize(&request)?;
        Ok(TileBitmap {
            page,
            lod,
            tile_x,
            tile_y,
            size_px: tile.size.width.round() as u32,
            pixels: tile.pixels,
        })
    }

    /// Rasterizes an arbitrary rectangle of `page`, in **view space** (points, top-left origin).
    ///
    /// The tile path proves PDFium's matrix rendering is exact; this exposes the same
    /// capability for a rectangle the caller chooses, which is what a figure or table preview
    /// needs (a citation points at a region, not at a whole page).
    ///
    /// `transparent_background` asks for the page's own paper to be left unpainted, so the
    /// returned bitmap has an alpha channel: white page background becomes alpha 0 while every
    /// mark the PDF draws keeps its coverage (a light-grey rule stays opaque grey, not
    /// translucent grey). PDF pages paint no paper themselves, so this is the renderer's native
    /// output rather than a colour key. The alpha is **straight (unpremultiplied)** — the form
    /// the canvas's alpha-over blend consumes — and the opaque path is byte-for-byte unchanged.
    // The six geometry arguments are the shape the C ABI exposes; `transparent_background` is
    // the only new axis and splitting them into a record would make the Swift call site worse.
    #[allow(clippy::too_many_arguments)]
    pub fn rasterize_region(
        &self,
        page: u32,
        scale: f64,
        x_pt: f64,
        y_pt: f64,
        width_pt: f64,
        height_pt: f64,
        transparent_background: bool,
    ) -> Result<PageBitmap, LyraReaderFfiError> {
        if !(scale.is_finite() && scale > 0.0) {
            return Err(LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: format!("scale must be positive and finite, got {scale}"),
            });
        }
        let page_count = self.backend.page_count();
        lyra_reader_core::checked_page_index(page, page_count, |page| {
            LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: lyra_reader_core::page_out_of_range_message(page, page_count),
            }
        })?;
        if !(x_pt.is_finite()
            && y_pt.is_finite()
            && width_pt.is_finite()
            && height_pt.is_finite()
            && width_pt > 0.0
            && height_pt > 0.0
            && (x_pt + width_pt).is_finite()
            && (y_pt + height_pt).is_finite())
        {
            return Err(LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: format!(
                    "region ({x_pt}, {y_pt}, {width_pt}×{height_pt}) must be finite with positive dimensions"
                ),
            });
        }
        let geometry = self.backend.page_info(PageIndex(page))?.geometry;
        let page_size = geometry.view_size(1.0);
        let tolerance = 1e-6;
        if x_pt < -tolerance
            || y_pt < -tolerance
            || x_pt + width_pt > page_size.width + tolerance
            || y_pt + height_pt > page_size.height + tolerance
        {
            return Err(LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: format!(
                    "region ({x_pt}, {y_pt}, {width_pt}×{height_pt}) is outside the page bounds ({}, {})",
                    page_size.width, page_size.height
                ),
            });
        }

        // A caller can request an arbitrary region, so apply the same pixel and edge limits as a
        // whole-page bitmap before asking PDFium to allocate it.
        let scale = clamp_scale((width_pt, height_pt), scale);
        if !(scale.is_finite() && scale > 0.0 && (scale as f32) > 0.0) {
            return Err(LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: "region dimensions exceed the renderer's supported range".to_string(),
            });
        }
        let mut request =
            RasterRequest::tile(PageIndex(page), scale, (x_pt, y_pt), (width_pt, height_pt));
        if transparent_background {
            // A zero-alpha clear: the page background stays clear, the content PDFium draws
            // supplies the coverage alpha. The RGB of a fully clear pixel is irrelevant to
            // alpha-over, which weights it by zero.
            request.background = [0, 0, 0, 0];
        }
        let tile = self.backend.rasterize(&request)?;

        Ok(PageBitmap {
            width_px: tile.size.width.round() as u32,
            height_px: tile.size.height.round() as u32,
            stride: tile.stride as u32,
            width_pt,
            height_pt,
            scale_used: scale,
            pixels: tile.pixels,
        })
    }

    /// Extracts the text layer of `page`.
    ///
    /// Character boxes come back in **view space** (points, top-left origin), which is what
    /// hit-testing needs, so the shell never touches page space. The order is the engine's
    /// character order, not necessarily visual reading order (see `docs/03-rendering.md`).
    ///
    /// This method deliberately stays *uncached*: a caller asking for the text layer gets a
    /// fresh read, and the build also warms the selection cache as a side effect, so the page
    /// the shell just loaded answers its first pointer event without another PDFium read.
    pub fn text_page(&self, page: u32) -> Result<TextPage, LyraReaderFfiError> {
        let model = self.extract_text_page(page)?;
        let selection = Arc::new(lyra_reader_text::SelectionTextPage::new(model.clone()));
        self.retain_selection_text_page(page, selection);
        Ok(text_page_record(page, &model))
    }

    /// Line-aware hit test (Swift `TextPage.characterIndex`), served from the page cache.
    ///
    /// Synchronous by design: a pointer event is one FFI call and, after the page's first
    /// event, no PDFium read. The returned index addresses the same `chars` array as
    /// [`LyraReaderDocument::text_page`].
    pub fn text_character_index(
        &self,
        page: u32,
        x_pt: f64,
        y_pt: f64,
        extending_selection: bool,
    ) -> Result<Option<u32>, LyraReaderFfiError> {
        let page = self.selection_text_page(page)?;
        Ok(page
            .char_index_at(Point::new(x_pt, y_pt), extending_selection)
            .map(|index| index.0))
    }

    /// Box→range with Swift's acceptance rule (`TextPage.characterRange`), from the cache.
    ///
    /// The result is the span from the first to the last intersecting stop; see
    /// [`lyra_reader_text::SelectionLayout::character_range`] for the cross-column caveat.
    pub fn text_character_range(
        &self,
        page: u32,
        x_pt: f64,
        y_pt: f64,
        width_pt: f64,
        height_pt: f64,
    ) -> Result<Option<TextRange>, LyraReaderFfiError> {
        let page = self.selection_text_page(page)?;
        Ok(page
            .character_range(lyra_reader_core::Rect::new(x_pt, y_pt, width_pt, height_pt))
            .map(|(first, last)| TextRange {
                start: first.0,
                end: last.0,
            }))
    }

    /// Range→string with Swift's `TextPage.string(in:)` semantics, from the cache.
    ///
    /// This is the single Rust implementation the shell's copy command, annotation export and
    /// reference extraction call. Invalid Unicode scalars are dropped and the range is clamped
    /// exactly like Swift.
    pub fn text_range_string(
        &self,
        page: u32,
        start: u32,
        end: u32,
    ) -> Result<String, LyraReaderFfiError> {
        let page = self.selection_text_page(page)?;
        Ok(page.string_in_range(start, end))
    }

    /// Extract the text layer inside a page-local rectangle.
    ///
    /// This is the rectangle-coverage selection mode in `lyra-reader-text::selection`, the same
    /// module that answers pointer hit-testing and box→range selection. Region cards use it so
    /// their quotes and the copied text come from one page/whitespace model. The text is capped
    /// at the region limit and the result says whether the cap cut it.
    pub fn region_text(
        &self,
        page: u32,
        x_pt: f64,
        y_pt: f64,
        width_pt: f64,
        height_pt: f64,
    ) -> Result<AiRegionTextRecord, LyraReaderFfiError> {
        let model = self.extract_text_page(page)?;
        let (text, truncated) = lyra_reader_text::region_text(
            &model.chars,
            lyra_reader_core::Rect::new(x_pt, y_pt, width_pt, height_pt),
            lyra_reader_text::MAX_REGION_TEXT_CHARS,
        );
        Ok(AiRegionTextRecord { text, truncated })
    }

    /// Current text-page cache state; used by the cache regression checks.
    pub fn text_page_cache_stats(&self) -> TextPageCacheStats {
        let cache = self
            .text_pages
            // Pure cache (immutable entries keyed by page): poisoning can only cost a miss.
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        TextPageCacheStats {
            entries: cache.entries.len() as u32,
            max_entries: TEXT_PAGE_CACHE_MAX_ENTRIES as u32,
            bytes: cache.bytes() as u64,
            max_bytes: TEXT_PAGE_CACHE_MAX_BYTES as u64,
            loads: cache.loads,
            hits: cache.hits,
            evictions: cache.evictions,
            pages: cache.pages_oldest_first(),
        }
    }

    /// Searches every page for `pattern` (ASCII-case-insensitive).
    ///
    /// Returns at most `limit` hits in reading order. A hit is a **character range** into
    /// the page's text layer, which is exactly what the shell's selection and highlighting
    /// already address, so showing a hit needs no new machinery.
    pub fn search(
        &self,
        pattern: String,
        limit: u32,
    ) -> Result<Vec<SearchHit>, LyraReaderFfiError> {
        if pattern.trim().is_empty() {
            return Ok(Vec::new());
        }

        let mut hits = Vec::new();
        let page_count = self.backend.page_count();
        for page in 0..page_count {
            let raw = self.backend.raw_text_page(PageIndex(page))?;
            let haystack = text_of(&raw);
            for hit in lyra_reader_text::find_all(&haystack, &pattern) {
                if hits.len() >= limit as usize {
                    return Ok(hits);
                }
                let snippet: String = haystack
                    .chars()
                    .skip(hit.start.saturating_sub(24))
                    .take((hit.end - hit.start) + 48)
                    .collect();
                hits.push(SearchHit {
                    page,
                    start: hit.start as u32,
                    end: hit.end as u32,
                    snippet,
                });
            }
        }
        Ok(hits)
    }

    /// Citations in the body text of `page`, boxed in view space.
    ///
    /// A page's citations are not a page-local question any more: a superscript numeral is only
    /// a citation when the document's bibliography carries its label, so this call depends on
    /// the document's reference list and its citation style. The first access builds that index
    /// (or loads it from the index cache); the reference scan already holds the scanned pages' text,
    /// so it records each page's spans at the same time and reads the pages past its window for
    /// this purpose. A cached index therefore makes this call independent of the PDF text layer
    /// for every page of the document.
    ///
    /// Every page is in the index: the reference scan reads the whole document once and stores
    /// one record per page, so this call is a lookup for a page 800 as it is for page 8. The
    /// one-page read below remains as the fallback for a page the index could not read (and for
    /// documents opened before the index exists, where it is the first read). The result is
    /// produced by the same `find_citations_with` call with the same style either way.
    pub fn citations(&self, page: u32) -> Result<Vec<CitationRecord>, LyraReaderFfiError> {
        self.ensure_index_loaded();

        // Superscript numerals are only reported when the document's own bibliography
        // corroborates them, which is why this reads the shared style rather than the page.
        let style = self.reference_cache()?.style.clone();
        if let Ok(cache) = self.citations.lock()
            && let Some(cached) = cache.as_ref().and_then(|pages| pages.get(&page))
        {
            return Ok(cached.clone());
        }

        let raw = self.backend.raw_text_page(PageIndex(page))?;
        let transform = self
            .backend
            .page_info(PageIndex(page))?
            .geometry
            .page_to_view(1.0);
        let records = citation_records(&raw, &style, page, transform);

        // Remember the page for repeated clicks even when it is outside the scan window. It is
        // not written back to the cache: the cache is complete for every page the scan saw,
        // and a late page is a one-page read, not a reason to rewrite the document index.
        if let Ok(mut cache) = self.citations.lock() {
            cache
                .get_or_insert_with(std::collections::BTreeMap::new)
                .insert(page, records.clone());
        }
        Ok(records)
    }

    /// `Figure N` / `Fig. N` / `Table N` / `Algorithm N` references in the body text of `page`,
    /// boxed in view space.
    ///
    /// These are the click targets: `kind` + `label` are the key into
    /// [`LyraReaderDocument::figures`], which carries the region to preview, and the box is where the
    /// pointer has to be. The caption's own label is not among them (it is already on screen);
    /// see `lyra_reader_text::find_caption_mentions`.
    ///
    /// Not cached, for the same reason as [`LyraReaderDocument::citations`]: it reads one page.
    pub fn caption_mentions(
        &self,
        page: u32,
    ) -> Result<Vec<CaptionMentionRecord>, LyraReaderFfiError> {
        let raw = self.backend.raw_text_page(PageIndex(page))?;
        let transform = self
            .backend
            .page_info(PageIndex(page))?
            .geometry
            .page_to_view(1.0);

        Ok(lyra_reader_text::find_caption_mentions(&raw)
            .into_iter()
            .map(|mention| {
                // Page boxes use a bottom-left origin, so the mention's top edge is its y.
                let top_left = Point::new(mention.rect.origin.x, mention.rect.max_y());
                let view = transform.apply(top_left);
                CaptionMentionRecord {
                    page,
                    kind: mention.kind,
                    label: mention.label,
                    start: mention.start as u32,
                    end: mention.end as u32,
                    x_pt: view.x,
                    y_pt: view.y,
                    width_pt: mention.rect.size.width,
                    height_pt: mention.rect.size.height,
                }
            })
            .collect())
    }

    /// The document's reference list, parsed once and cached.
    ///
    /// This is what makes a citation work **without** a link annotation: the shell resolves
    /// `[12]` to an entry and previews the entry's own rectangle.
    pub fn references(&self) -> Result<Vec<ReferenceRecord>, LyraReaderFfiError> {
        self.ensure_index_loaded();
        Ok(self.reference_cache()?.records.clone())
    }

    /// Resolves every label of a citation against the **document-wide** reference list.
    ///
    /// A citation routinely names several works at once — `[1,2]`, `(He et al. 2024; Kim 2023)`
    /// — and the reader expects all of them, so the plural form exists: the shell asks once for
    /// the whole group instead of resolving label by label and re-implementing the matching
    /// conventions (exact label match, then position for a numeric citation against an
    /// unnumbered list) on the Swift side. Entries come back in label order and are
    /// de-duplicated by `(label, page)`. An empty vector means nothing in the group could be
    /// resolved, which is an ordinary outcome for the caller to report, not an error.
    ///
    /// This signature has no page, and a label list alone cannot say which section a citation is
    /// in. It therefore keeps the pre-T4.42 behaviour — the list the document-wide selection
    /// chose — and is the right call for a whole-document label list. A citation clicked in the
    /// reader has a page: use [`LyraReaderDocument::resolve_citations_on`], which is what the shell's
    /// click path does. Adding the page as a distinct method rather than an optional argument
    /// keeps every existing caller source-compatible and makes the two behaviours explicit.
    pub fn resolve_citations(
        &self,
        labels: Vec<String>,
    ) -> Result<Vec<ReferenceRecord>, LyraReaderFfiError> {
        let references = self.references()?;
        let parsed: Vec<lyra_reader_text::ReferenceEntry> = references
            .iter()
            .map(|record| lyra_reader_text::ReferenceEntry {
                label: record.label.clone(),
                text: record.text.clone(),
                page: record.page,
                start: 0,
                end: 0,
                // Only labels and pages matter for resolution; the record handed back below
                // carries the geometry the cache built.
                fragments: Vec::new(),
            })
            .collect();

        Ok(lyra_reader_text::resolve_references(&labels, &parsed)
            .into_iter()
            .filter_map(|entry| {
                // Resolution ran against `parsed`, whose entries mirror `references` one to
                // one; `(label, page)` is also the key the resolver de-duplicates by, so it
                // identifies the record to hand back.
                references
                    .iter()
                    .find(|record| record.label == entry.label && record.page == entry.page)
                    .cloned()
            })
            .collect())
    }

    /// Resolves every label of a citation found on `page`, against the list that page's section
    /// cites.
    ///
    /// This is the app's click path: a click knows the page it was made on, and that page is the
    /// evidence which decides between several reference lists. A citation in the GPT-4 system
    /// card appendix resolves into the appendix's own list; the same bracket number in the
    /// report's main text resolves into the report's list. The return type names the attributed
    /// list and the reason, so a caller can show (or log) why the preview is what it is.
    ///
    /// The attribution and its ambiguity rule live in `lyra_reader_text`; this method only hands
    /// the page through and maps the resolved entry back to the record the preview draws. With
    /// one reference list in the document the attributed list is that list, so the result is the
    /// same entry [`LyraReaderDocument::resolve_citations`] returns.
    pub fn resolve_citations_on(
        &self,
        page: u32,
        labels: Vec<String>,
    ) -> Result<Vec<ResolvedReference>, LyraReaderFfiError> {
        self.ensure_index_loaded();
        let cache = self.reference_cache()?;
        let bibliography = &cache.bibliography;
        let Some(attribution) = lyra_reader_text::attribute_citation(bibliography, page, &labels)
        else {
            return Ok(Vec::new());
        };
        let list = &bibliography.lists[attribution.list];
        let cached_list = &cache.lists[attribution.list];
        let mut resolved = Vec::new();
        for entry in lyra_reader_text::resolve_references(&labels, &list.entries) {
            // The live entries are built from the cached records one to one, so an entry's index
            // is its preview record's index too.
            let Some(index) = list
                .entries
                .iter()
                .position(|candidate| std::ptr::eq(candidate, entry))
            else {
                continue;
            };
            let Some(reference) = cached_list.records.get(index) else {
                continue;
            };
            resolved.push(ResolvedReference {
                reference: reference.clone(),
                list_index: attribution.list as u32,
                list_count: bibliography.lists.len() as u32,
                list_heading: cached_list.heading.clone(),
                list_first_page: cached_list.records.iter().map(|record| record.page).min(),
                list_last_page: cached_list.records.iter().map(|record| record.page).max(),
                document_wide: attribution.list == bibliography.document_wide,
                reason: attribution.reason.explanation().to_string(),
                ambiguous: attribution.ambiguous,
            });
        }
        Ok(resolved)
    }

    /// Figure, table, and algorithm captions across the document, each with the region to preview.
    ///
    /// This is what makes a `Figure 3` in the body work **without** a link annotation: the shell
    /// resolves the mention's `kind` + `label` here and previews the record's own box. Cached
    /// like [`LyraReaderDocument::references`], and for the same reason — the caption set cannot change
    /// while the document is open.
    ///
    /// Unlike the reference scan there is nothing to stop early on: a figure index is wanted for
    /// the whole readable body, so every page is scanned. The scan keeps no page's text or
    /// geometry after the page is read — only the caption records themselves — so a 900-page
    /// document costs one page of working memory, not nine hundred.
    ///
    /// The box is the region `lyra_reader_text::caption_region_from` derives, converted to **view
    /// space** so it can be handed straight to [`LyraReaderDocument::rasterize_region`]: the caption
    /// plus the table grid for a `Table` whose borders are drawn, the caption plus its nearby
    /// image object for a raster figure, and the full page when neither can be bounded reliably
    /// (vector figures, `booktabs` tables with too few rules, algorithms).
    pub fn figures(&self) -> Result<Vec<FigureRecord>, LyraReaderFfiError> {
        self.ensure_index_loaded();
        if let Ok(cache) = self.figures.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(cached.clone());
        }

        let started = Instant::now();
        let total = self.backend.page_count();
        let mut records = Vec::new();
        for index in 0..total {
            let Ok(text) = self.backend.raw_text_page(PageIndex(index)) else {
                continue;
            };
            let Ok(info) = self.backend.page_info(PageIndex(index)) else {
                continue;
            };
            // Images are a best-effort input: a caption with no image object still previews its
            // own box, so a page whose objects cannot be read is not a page with no figures.
            let (images, _rule_count) = self
                .backend
                .page_object_summary(PageIndex(index))
                .unwrap_or_default();
            // A table has no object of its own; its grid is in the page's vector geometry, and
            // the text inside the cells is what confirms it. Both are best-effort for the same
            // reason the images are.
            let rules = self
                .backend
                .page_line_segments(PageIndex(index))
                .unwrap_or_default();
            let lines = lyra_reader_text::lines_from(&text);
            let evidence = lyra_reader_text::PageEvidence {
                images: &images,
                rules: &rules,
                lines: &lines,
            };
            // Regions are derived in page space and clamped to the full visible CropBox; its
            // origin can be non-zero. Transforming all four corners below also handles /Rotate.
            let page_bounds = info.geometry.crop_box;

            for caption in lyra_reader_text::find_captions(&text) {
                let region = lyra_reader_text::caption_region_from(&caption, evidence, page_bounds);
                let view = page_region_to_view(region, info.geometry);
                records.push(FigureRecord {
                    kind: caption.kind,
                    label: caption.label,
                    page: index,
                    caption_text: caption.text,
                    x_pt: view.origin.x,
                    y_pt: view.origin.y,
                    width_pt: view.size.width,
                    height_pt: view.size.height,
                });
            }
        }

        if let Ok(mut cache) = self.figures.lock() {
            *cache = Some(records.clone());
        }
        self.note_derived(started.elapsed());
        self.maybe_write_index();
        Ok(records)
    }

    /// Links on `page`, in **view space** (points, top-left origin).
    ///
    /// Only actionable links come back: a page to jump to, a URL to open, or both.
    pub fn links(&self, page: u32) -> Result<Vec<LinkRecord>, LyraReaderFfiError> {
        let geometry = self.backend.page_info(PageIndex(page))?.geometry;

        Ok(self
            .backend
            .link_targets(PageIndex(page))?
            .into_iter()
            .map(|link| {
                let view = page_region_to_view(link.rect, geometry);
                // The destination region lives on the *target* page, so it needs that page's
                // full transform, including its rotation and CropBox origin.
                let region = link.dest_rect.and_then(|rect| {
                    let target = link.page?;
                    let target_geometry = self.backend.page_info(target).ok()?.geometry;
                    let view = page_region_to_view(rect, target_geometry);
                    Some(LinkRegion {
                        x_pt: view.origin.x,
                        y_pt: view.origin.y,
                        width_pt: view.size.width,
                        height_pt: view.size.height,
                    })
                });

                LinkRecord {
                    x_pt: view.origin.x,
                    y_pt: view.origin.y,
                    width_pt: view.size.width,
                    height_pt: view.size.height,
                    uri: link.uri,
                    page: link.page.map(|page| page.get()),
                    region,
                }
            })
            .collect())
    }

    /// Document outline, flattened depth-first with a depth per entry.
    ///
    /// Flat is what a sidebar list wants; nesting is carried by `depth` instead of nested
    /// records, which keeps the FFI surface small. Stored in the index cache like the rest of
    /// the derived data: a warm open does not read the outline tree.
    pub fn outline(&self) -> Result<Vec<OutlineEntry>, LyraReaderFfiError> {
        self.ensure_index_loaded();
        if let Ok(cache) = self.outline.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(cached.clone());
        }

        let started = Instant::now();
        let mut entries = Vec::new();
        flatten_outline(&self.backend.outline()?, 0, &mut entries);
        // Our own bookmark subtree is written into the outline. Adopt its identities and
        // page-local positions so a click lands where the bookmark was set and the bookmarks tab
        // can show the file's copy rather than a duplicate cached entry. The lopdf parse is only
        // attempted when the title we would have written is present, which keeps ordinary
        // documents from paying for a whole-file parse on open.
        if entries
            .iter()
            .any(|entry| entry.depth == 0 && entry.title.starts_with(DEFAULT_BOOKMARK_TITLE))
            && let Ok(Some(embedded)) =
                read_embedded_bookmarks(Path::new(&self.path), self.password.as_deref())
        {
            merge_embedded_bookmarks(&mut entries, &embedded);
        }
        if let Ok(mut cache) = self.outline.lock() {
            *cache = Some(entries.clone());
        }
        self.note_derived(started.elapsed());
        self.maybe_write_index();
        Ok(entries)
    }

    /// The document's recognised metadata, with the source of every field.
    ///
    /// The three sources are read once and cached: XMP, `/Info`, then page one's text layer
    /// for anything the file did not state. An empty field is returned empty with source
    /// `absent`; this call never invents a title, author, venue, year, DOI or arXiv id.
    ///
    /// The BibTeX string in the report is generated from exactly these values. After the
    /// reader edits a field, [`generate_bibtex_entry`] regenerates the entry from the draft.
    pub fn metadata(&self) -> Result<DocumentMetadataRecord, LyraReaderFfiError> {
        self.ensure_index_loaded();
        if let Ok(cache) = self.metadata.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(cached.clone());
        }

        let started = Instant::now();
        let embedded = self.backend.embedded_metadata()?;
        let first_page = self.backend.raw_text_page(PageIndex(0)).ok();
        // The text boxes are in unrotated PDF user space; the footer band is measured there.
        let page_height = self
            .backend
            .page_info(PageIndex(0))?
            .geometry
            .crop_box
            .size
            .height;
        let recognized = recognize(&embedded, first_page.as_ref(), page_height);
        let report = metadata_report(&recognized);
        if let Ok(mut cache) = self.metadata.lock() {
            *cache = Some(report.clone());
        }
        self.note_derived(started.elapsed());
        self.maybe_write_index();
        Ok(report)
    }

    /// Annotations the document **already carries**, from every page, in **view space**.
    ///
    /// This is the other half of this application's annotation story: the annotation cache holds what the
    /// reader wrote, and this reads what is in the file — a PDF marked up in Preview, or one
    /// somebody else annotated. Every page is scanned: a cap like the reference index's 120 pages
    /// would silently hide notes in the back matter, and an annotation-free page costs one page
    /// load and one count (measured 2026-10-15 on the generated 300-page fixture through
    /// `FPDF_LoadPage` + `FPDFPage_GetAnnotCount`: 6.7 ms for all 300, 22 µs per page — a one-off
    /// cost on the open path, cached below).
    ///
    /// Cached for the lifetime of the open document, like [`LyraReaderDocument::figures`]: a PDF cannot
    /// change under us while it is open, and the canvas would otherwise re-scan on every rebuild.
    ///
    /// This returns every annotation that reads. An annotation that cannot be decoded is not a
    /// reason to fail the document: it is counted by [`Self::annotation_read_status`] and the
    /// shell warns and blocks rewrites around content the engine could not see.
    pub fn annotations(&self) -> Result<Vec<AnnotationRecord>, LyraReaderFfiError> {
        Ok(self.annotation_scan()?.0)
    }

    /// What the document-wide annotation read could not decode.
    ///
    /// Shares the cache with [`Self::annotations`], so the count and the readable records come
    /// from exactly one scan. The shell calls this after `annotations()` and shows the count as
    /// a one-line notice instead of failing the page.
    pub fn annotation_read_status(&self) -> Result<AnnotationReadStatus, LyraReaderFfiError> {
        Ok(self.annotation_scan()?.1)
    }

    /// The `/Rotate` of every page, in quarter turns (0–3).
    ///
    /// The shell reads this once when a page-edit session starts. "Reset to the file's original
    /// rotation" is a property of that snapshot: after a reorder the page has moved, and after a
    /// rotation the file no longer says what the original was.
    pub fn page_rotations(&self) -> Result<Vec<u32>, LyraReaderFfiError> {
        let count = self.backend.page_count();
        let mut rotations = Vec::with_capacity(count as usize);
        for page in 0..count {
            let info = self.backend.page_info(PageIndex(page))?;
            rotations.push((info.geometry.rotation.degrees().rem_euclid(360) / 90) as u32);
        }
        Ok(rotations)
    }

    /// Actual page objects in top-left view points. Identity is bound to the file's SHA-256.
    pub fn content_objects(&self, page: u32) -> Result<String, LyraReaderFfiError> {
        let mut snapshot =
            lyra_reader_pdfium::content_edit::inspect_content(Path::new(&self.path), page)?;
        let transform = self
            .backend
            .page_info(PageIndex(page))?
            .geometry
            .page_to_view(1.0);
        for item in &mut snapshot.items {
            item.bounds = transform
                .apply_rect(lyra_reader_core::Rect::new(
                    item.bounds.x,
                    item.bounds.y,
                    item.bounds.width,
                    item.bounds.height,
                ))
                .into();
        }
        serde_json::to_string(&snapshot).map_err(|e| LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: e.to_string(),
        })
    }

    pub fn content_image_png(
        &self,
        page: u32,
        target: String,
        revision: String,
    ) -> Result<Vec<u8>, LyraReaderFfiError> {
        Ok(lyra_reader_pdfium::content_edit::content_image(
            Path::new(&self.path),
            page,
            &target,
            &revision,
        )?)
    }

    /// Stages a content edit in a separate working revision; publication uses the existing
    /// signature-aware page-edit save transaction.
    ///
    /// A redaction that would need the whole-page raster fallback is refused: the shell must
    /// ask first and then call [`Self::apply_content_edit_allowing_raster`].
    pub fn apply_content_edit(
        &self,
        page: u32,
        command: ContentCommandRecord,
        destination: String,
    ) -> Result<(), LyraReaderFfiError> {
        let command = prepare_content_command(self, page, command)?;
        lyra_reader_pdfium::content_edit::edit_content(
            Path::new(&self.path),
            Path::new(&destination),
            page,
            &command,
        )?;
        Ok(())
    }

    /// The pages staging this redaction would replace with a raster image, computed without
    /// writing anything.
    ///
    /// This is what the Edit workspace asks before showing its confirmation. The engine still
    /// decides the actual outcome when the edit is staged; this method only names the pages that
    /// would lose their text layer.
    pub fn content_redaction_raster_pages(
        &self,
        page: u32,
        command: ContentCommandRecord,
    ) -> Result<Vec<u32>, LyraReaderFfiError> {
        let command = prepare_content_command(self, page, command)?;
        Ok(
            lyra_reader_pdfium::content_edit::content_redaction_raster_pages(
                Path::new(&self.path),
                page,
                &command,
            )?,
        )
    }

    /// Stages a content edit after the reader has accepted the raster fallback.
    ///
    /// Returns the 0-based pages that were actually replaced by an image, in ascending order.
    /// Empty for an ordinary edit and for a redaction that needed no fallback.
    pub fn apply_content_edit_allowing_raster(
        &self,
        page: u32,
        command: ContentCommandRecord,
        destination: String,
    ) -> Result<Vec<u32>, LyraReaderFfiError> {
        let command = prepare_content_command(self, page, command)?;
        let report = lyra_reader_pdfium::content_edit::edit_content_allowing_raster(
            Path::new(&self.path),
            Path::new(&destination),
            page,
            &command,
        )?;
        let mut pages: Vec<u32> = report
            .into_iter()
            .flat_map(|report| report.pages)
            .filter(|page| page.rasterized)
            .map(|page| page.page)
            .collect();
        pages.sort_unstable();
        pages.dedup();
        Ok(pages)
    }

    /// Applies a page operation to a **copy** of this document and writes it to `destination`.
    ///
    /// This object's file is never modified. The written file is verified to have the requested
    /// page count, rotations and page sizes before the final rename. `page_map[old] = Some(new)`
    /// lets the shell remap its cached annotations; `None` means the page was removed.
    pub fn apply_page_operation(
        &self,
        destination: String,
        operation: PageOperationRecord,
    ) -> Result<PageEditReport, LyraReaderFfiError> {
        self.ensure_not_xfa()?;
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            return Err(LyraReaderFfiError::Document {
                severity: ErrorSeverity::Document,
                message: "the document was replaced on disk; reopen it before editing pages"
                    .to_string(),
            });
        }
        if self.backend.needs_password() {
            return Err(LyraReaderFfiError::Document {
                severity: ErrorSeverity::Document,
                message:
                    "this document is encrypted; page editing is not supported for encrypted files"
                        .to_string(),
            });
        }
        // This writes a page-edit **revision**, not a user-facing copy: a signed document may
        // be edited in the staged session (the final copy is sanitised by `save_edited_copy`,
        // and applying the revision to the original is refused by `replace_with_edited_pages`).
        let operation = page_operation(operation);
        let report = lyra_reader_pdfium::stage_page_operation(
            Path::new(&self.path),
            Path::new(&destination),
            &operation,
            self.password.as_deref(),
        )?;
        Ok(page_edit_report(report))
    }

    /// Extracts `pages` into a new PDF at `destination`; this document is not modified.
    pub fn extract_pages(
        &self,
        destination: String,
        pages: Vec<u32>,
    ) -> Result<PageEditReport, LyraReaderFfiError> {
        self.ensure_not_xfa()?;
        if self.backend.needs_password() {
            return Err(LyraReaderFfiError::Document {
                severity: ErrorSeverity::Document,
                message:
                    "this document is encrypted; page editing is not supported for encrypted files"
                        .to_string(),
            });
        }
        let report = lyra_reader_pdfium::extract_pages(
            Path::new(&self.path),
            Path::new(&destination),
            &pages,
            self.password.as_deref(),
        )?;
        Ok(page_edit_report(report))
    }

    /// Appends `others` to this document and writes a **new** file at `destination`.
    ///
    /// This document is not modified. Encrypted inputs, a document merged into itself, the same
    /// document selected twice, and an output that would overwrite an input are refused with a
    /// readable error and no file. The first document's outline is kept; each appended document's
    /// outline is imported as one labelled top-level group, its entries nested beneath it and its
    /// destinations remapped to the merged pages. File-owned annotations on appended pages travel
    /// with their pages. The reader's cached marks are the shell's concern: appending does not
    /// move existing pages, so their page indices are unchanged and the appended pages start with
    /// no cached marks.
    pub fn merge_documents(
        &self,
        others: Vec<String>,
        destination: String,
    ) -> Result<MergeReportRecord, LyraReaderFfiError> {
        self.ensure_not_xfa()?;
        if self.backend.needs_password() {
            return Err(LyraReaderFfiError::Document { severity: ErrorSeverity::Document,
                message:
                    "this document is encrypted; merging an encrypted document is refused and no output was written"
                        .to_string(),
            });
        }
        let others: Vec<PathBuf> = others.into_iter().map(PathBuf::from).collect();
        let report = merge_documents(
            Path::new(&self.path),
            &others,
            Path::new(&destination),
            self.password.as_deref(),
        )?;
        Ok(merge_report(report))
    }

    /// Writes disjoint selections of this document into separate files.
    ///
    /// This document is not modified. See [`lyra_reader_pdfium::split_pages`] for the failure
    /// model: each output is individually verified and atomically renamed, and a later failure
    /// leaves earlier outputs complete (the error says how many).
    pub fn split_pages(
        &self,
        parts: Vec<SplitPartRecord>,
    ) -> Result<SplitReportRecord, LyraReaderFfiError> {
        self.ensure_not_xfa()?;
        if self.backend.needs_password() {
            return Err(LyraReaderFfiError::Document { severity: ErrorSeverity::Document,
                message:
                    "this document is encrypted; splitting an encrypted document is refused and no output was written"
                        .to_string(),
            });
        }
        let parts: Vec<SplitPart> = parts
            .into_iter()
            .map(|part| SplitPart {
                destination: PathBuf::from(part.destination_path),
                pages: part.pages,
            })
            .collect();
        let report = split_pages(Path::new(&self.path), &parts, self.password.as_deref())?;
        Ok(split_report(report))
    }

    /// Publishes the current page-edit revision as a new file, without touching the original.
    pub fn save_edited_copy(
        &self,
        destination: String,
    ) -> Result<PageEditReport, LyraReaderFfiError> {
        self.ensure_not_xfa()?;
        let report = lyra_reader_pdfium::publish_edited_copy(
            Path::new(&self.path),
            Path::new(&destination),
            self.backend.page_count(),
        )?;
        Ok(page_edit_report(report))
    }

    /// Replaces `original_path` with this page-edit revision.
    ///
    /// This is the explicitly destructive command. A byte-identical backup of `original_path` is
    /// written and verified first; the revision is written into a temporary file beside it,
    /// verified, and only then renamed over the original. The in-memory handle is marked stale so
    /// the shell must reopen the file rather than quietly reading the old page tree.
    pub fn replace_with_edited_pages(
        &self,
        original_path: String,
    ) -> Result<PageEditReport, LyraReaderFfiError> {
        self.ensure_not_xfa()?;
        // The revision is a working copy, so its own signature status (normally signed) is not
        // the authority for an in-place write: check the file that would actually change.
        let original = Path::new(&original_path);
        if let Some(reason) =
            lyra_reader_pdfium::detect_signature(original, None, 0).read_only_reason()
        {
            return Err(LyraReaderFfiError::Document {
                severity: ErrorSeverity::Document,
                message: reason,
            });
        }
        self.ensure_writable()?;
        if self.backend.needs_password() {
            return Err(LyraReaderFfiError::Document {
                severity: ErrorSeverity::Document,
                message:
                    "this document is encrypted; page editing is not supported for encrypted files"
                        .to_string(),
            });
        }
        let report = lyra_reader_pdfium::replace_original_with_edit(
            Path::new(&self.path),
            Path::new(&original_path),
            self.backend.page_count(),
        )?;
        self.replaced
            .store(true, std::sync::atomic::Ordering::Release);
        Ok(page_edit_report(report))
    }

    /// The name to offer when saving an annotated copy: `<name> (annotated).pdf`.
    pub fn suggested_copy_path(&self) -> String {
        lyra_reader_pdfium::suggested_copy_path(Path::new(&self.path))
            .to_string_lossy()
            .into_owned()
    }

    /// Writes `annotations` into a **new PDF** at `destination`.
    ///
    /// The document that is open is not modified, and neither is its annotation cache. `annotations`
    /// cross the boundary as view-space geometry at `zoom`; Rust converts it to page space with
    /// the page's own `/CropBox`, `/Rotate` and `/UserUnit`, so the same highlight saved at 100%
    /// and at 300% lands in the same PDF coordinates.
    ///
    /// The write is append-only: the destination begins with every byte of the source. It is
    /// written to a temporary file beside `destination`, flushed, reopened, verified annotation
    /// by annotation, and only then renamed into place. A failure leaves the source untouched.
    pub fn save_annotations_copy(
        &self,
        destination: String,
        annotations: Vec<WriteAnnotationRecord>,
        bookmarks: Vec<WriteBookmarkRecord>,
        zoom: f64,
    ) -> Result<AnnotationSaveReport, LyraReaderFfiError> {
        self.save_annotations_to(
            std::path::PathBuf::from(destination),
            annotations,
            bookmarks,
            Vec::new(),
            Vec::new(),
            zoom,
            SaveMode::Copy,
        )
    }

    /// Writes a new PDF at `destination` with additions, edits and deletions of annotations.
    ///
    /// Additions behave exactly like [`Self::save_annotations_copy`]. `updates` name annotations
    /// the file already carries by the identity [`Self::annotations`] reported; only the fields
    /// this reader models are changed and every other key of the foreign annotation is preserved.
    /// `deletions` remove the annotation, its `/IRT` reply thread and its `/Popup` window from
    /// the page's `/Annots`. The document that is open is not modified.
    pub fn save_annotation_changes_copy(
        &self,
        destination: String,
        annotations: Vec<WriteAnnotationRecord>,
        bookmarks: Vec<WriteBookmarkRecord>,
        updates: Vec<AnnotationUpdateRecord>,
        deletions: Vec<AnnotationDeleteRecord>,
        zoom: f64,
    ) -> Result<AnnotationSaveReport, LyraReaderFfiError> {
        self.save_annotations_to(
            std::path::PathBuf::from(destination),
            annotations,
            bookmarks,
            updates,
            deletions,
            zoom,
            SaveMode::Copy,
        )
    }

    /// Replaces the document that is open with a version carrying additions, edits and deletions.
    ///
    /// The same verified-backup and atomic-rename contract as [`Self::replace_with_annotations`].
    pub fn replace_with_annotation_changes(
        &self,
        annotations: Vec<WriteAnnotationRecord>,
        bookmarks: Vec<WriteBookmarkRecord>,
        updates: Vec<AnnotationUpdateRecord>,
        deletions: Vec<AnnotationDeleteRecord>,
        zoom: f64,
    ) -> Result<AnnotationSaveReport, LyraReaderFfiError> {
        self.save_annotations_to(
            std::path::PathBuf::from(&self.path),
            annotations,
            bookmarks,
            updates,
            deletions,
            zoom,
            SaveMode::ReplaceOriginal,
        )
    }

    /// Replaces the document that is open with a version carrying `annotations`.
    ///
    /// This is the explicit second choice, never the default. A byte-identical backup is written
    /// first to `<name>.lyra-reader-backup-<unix>-<n>.<ext>`; if it cannot be written *and verified*,
    /// the save aborts before the original is touched. The replacement itself is the atomic
    /// rename of a verified temporary file, so a crash leaves the original readable.
    pub fn replace_with_annotations(
        &self,
        annotations: Vec<WriteAnnotationRecord>,
        bookmarks: Vec<WriteBookmarkRecord>,
        zoom: f64,
    ) -> Result<AnnotationSaveReport, LyraReaderFfiError> {
        self.save_annotations_to(
            std::path::PathBuf::from(&self.path),
            annotations,
            bookmarks,
            Vec::new(),
            Vec::new(),
            zoom,
            SaveMode::ReplaceOriginal,
        )
    }

    /// The document's AcroForm fields, in reading order and in **view space**.
    ///
    /// The geometry and type come from the widget dictionaries (`/AcroForm` → `/Fields` with
    /// the `/Kids` hierarchy and inherited `/FT`, `/Ff`, `/V`, `/Opt`, `/DA`), read with the
    /// same `lopdf` parser the appearance writer uses. PDFium's public form API enumerates no
    /// fields at all: it is an event/render API (`FORM_OnChar`, `FPDF_FFLDraw`) with no
    /// field-count or field-value accessors, so the dictionaries are both the normative source
    /// and the only one that survives every producer.
    ///
    /// This call never writes. An encrypted file is reported with `encrypted: true` and a
    /// readable `refusal`; filling it is refused by [`Self::save_filled_form_copy`] as well.
    pub fn form_info(&self) -> Result<FormInfoRecord, LyraReaderFfiError> {
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            return Err(LyraReaderFfiError::Document {
                severity: ErrorSeverity::Document,
                message: "the document was replaced on disk; reopen it before reading its form"
                    .to_string(),
            });
        }
        let path = Path::new(&self.path);
        if let Some(state) = &self.xfa {
            // The synthetic PDF has no fillable fields: drawing a control in a picture does not
            // create a widget. Report the refusal and the source's encryption state so the shell
            // explains why the form tool is not offered, instead of showing an empty form.
            let reason = state
                .status
                .read_only_reason
                .clone()
                .unwrap_or_else(|| lyra_reader_xfa::READ_ONLY_REASON.to_string());
            return Ok(FormInfoRecord {
                fields: Vec::new(),
                encrypted: state.status.encrypted,
                pdf_version: lyra_reader_pdfium::read_document_facts_unencrypted_header(
                    path,
                    self.backend.page_count(),
                )
                .pdf_version,
                page_count: self.backend.page_count(),
                refusal: Some(reason),
            });
        }
        if !self.backend.has_acro_form()? {
            // No AcroForm: skip the whole-file dictionary parse. The PDF version is still a
            // fact the information panel would ask for, and reading the header is cheap.
            return Ok(FormInfoRecord {
                fields: Vec::new(),
                encrypted: self.backend.is_encrypted(),
                pdf_version: lyra_reader_pdfium::read_document_facts_unencrypted_header(
                    path,
                    self.backend.page_count(),
                )
                .pdf_version,
                page_count: self.backend.page_count(),
                refusal: None,
            });
        }
        let form = match lyra_reader_pdfium::read_form_document(path, self.password.as_deref()) {
            Ok(form) => form,
            Err(error) if error.code == ErrorCode::Encrypted => {
                return Ok(FormInfoRecord {
                    fields: Vec::new(),
                    encrypted: true,
                    pdf_version: lyra_reader_pdfium::read_document_facts_unencrypted_header(
                        path,
                        self.backend.page_count(),
                    )
                    .pdf_version,
                    page_count: self.backend.page_count(),
                    refusal: Some(
                        "This PDF is encrypted. The reader will not fill it: writing form                          values would require rewriting its security envelope, and a file                          written anyway might not open in another viewer."
                            .to_string(),
                    ),
                });
            }
            Err(error) => return Err(error.into()),
        };
        let mut geometries: std::collections::HashMap<u32, PageGeometry> =
            std::collections::HashMap::new();
        let mut fields = Vec::with_capacity(form.fields.len());
        for field in &form.fields {
            let mut widgets = Vec::with_capacity(field.widgets.len());
            let mut field_rect = None;
            for widget in &field.widgets {
                let geometry = match geometries.get(&widget.page) {
                    Some(geometry) => *geometry,
                    None => {
                        let geometry = self.backend.page_info(PageIndex(widget.page))?.geometry;
                        geometries.insert(widget.page, geometry);
                        geometry
                    }
                };
                let view = page_region_to_view(widget.rect, geometry);
                if field_rect.is_none() {
                    field_rect = Some(view);
                }
                widgets.push(FormWidgetRecord {
                    page: widget.page,
                    x_pt: view.origin.x,
                    y_pt: view.origin.y,
                    width_pt: view.size.width,
                    height_pt: view.size.height,
                    state: widget.state.clone(),
                });
            }
            let rect = field_rect.unwrap_or(lyra_reader_core::Rect::new(0.0, 0.0, 0.0, 0.0));
            fields.push(FormFieldRecord {
                id: field.id.clone(),
                name: field.name.clone(),
                kind: field.kind.code().to_string(),
                page: field.page().unwrap_or(0),
                x_pt: rect.origin.x,
                y_pt: rect.origin.y,
                width_pt: rect.size.width,
                height_pt: rect.size.height,
                value: field.value.clone(),
                selected: field.selected.clone(),
                checked: field.checked,
                widgets,
                options: field
                    .options
                    .iter()
                    .map(|option| FormOptionRecord {
                        value: option.value.clone(),
                        label: option.label.clone(),
                    })
                    .collect(),
                editable: field.editable && !form.encrypted,
                multiline: field.multiline,
                max_length: field.max_length,
                font_size_pt: field.font_size,
                required: field.required,
            });
        }
        Ok(FormInfoRecord {
            fields,
            encrypted: form.encrypted,
            pdf_version: form.pdf_version,
            page_count: form.page_count,
            refusal: form.encrypted.then(|| {
                "This PDF is encrypted. The reader will not fill it: writing form values would                  require rewriting its security envelope, and a file written anyway might not                  open in another viewer."
                    .to_string()
            }),
        })
    }

    /// Writes `values` into a **new PDF** at `destination`; the open document is untouched.
    ///
    /// The output begins with every byte of the source and every unfilled field and annotation
    /// is verified unchanged before the temporary file is renamed. The widgets stay interactive:
    /// `/AcroForm`, `/Fields`, the widget dictionaries and their `/AP` are kept, and the writer
    /// only adds the appearance streams a viewer draws when it does not synthesize one.
    pub fn save_filled_form_copy(
        &self,
        destination: String,
        values: Vec<FormFieldValueRecord>,
    ) -> Result<FormSaveReport, LyraReaderFfiError> {
        self.save_filled_form_to(PathBuf::from(destination), values, SaveMode::Copy)
    }

    /// Replaces the open document with one carrying `values`, after a verified backup.
    pub fn replace_with_filled_form(
        &self,
        values: Vec<FormFieldValueRecord>,
    ) -> Result<FormSaveReport, LyraReaderFfiError> {
        self.save_filled_form_to(PathBuf::from(&self.path), values, SaveMode::ReplaceOriginal)
    }

    /// The name to offer when saving a filled copy: `<name> (filled).pdf`.
    pub fn suggested_filled_copy_path(&self) -> String {
        lyra_reader_pdfium::suggested_filled_copy_path(Path::new(&self.path))
            .to_string_lossy()
            .into_owned()
    }

    /// Writes a flattened copy of the open document to `destination`.
    ///
    /// The annotations' appearances and the filled form widgets are painted into the page
    /// content, then those annotations and the `/AcroForm` entry are removed. The text layer and
    /// the vectors stay text and vectors; nothing is rasterised. Sticky notes and links are kept
    /// as annotations, and a field whose appearance cannot be baked faithfully is kept and
    /// reported. A signed document may be copied: the copy is a derived copy and has its
    /// signature material stripped. An XFA form is refused with its existing read-only reason.
    ///
    /// This is not tamper-proof: the painted bytes are still editable by a content editor, and
    /// only a digital signature can detect later changes.
    pub fn flatten_to_copy(
        &self,
        destination: String,
    ) -> Result<FlattenReportRecord, LyraReaderFfiError> {
        self.ensure_not_xfa()?;
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            return Err(LyraReaderFfiError::Document {
                severity: ErrorSeverity::Document,
                message: "the document was replaced on disk; reopen it before flattening"
                    .to_string(),
            });
        }
        let report = lyra_reader_pdfium::flatten_to_copy(
            Path::new(&self.path),
            Path::new(&destination),
            self.password.as_deref(),
        )?;
        Ok(FlattenReportRecord {
            destination_path: report.destination.to_string_lossy().into_owned(),
            pages: report.pages,
            flattened_annotations: report.flattened_annotations,
            flattened_annotation_kinds: report
                .flattened_annotation_kinds
                .into_iter()
                .map(|count| FlattenKindCountRecord {
                    kind: count.kind,
                    count: count.count,
                })
                .collect(),
            flattened_fields: report.flattened_fields,
            flattened_field_kinds: report
                .flattened_field_kinds
                .into_iter()
                .map(|count| FlattenKindCountRecord {
                    kind: count.kind,
                    count: count.count,
                })
                .collect(),
            kept_annotations: report
                .kept_annotations
                .into_iter()
                .map(|kept| KeptAnnotationRecord {
                    page: kept.page,
                    kind: kept.kind,
                    reason: kept.reason,
                    has_comment: kept.has_comment,
                })
                .collect(),
            kept_fields: report
                .kept_fields
                .into_iter()
                .map(|kept| KeptFieldRecord {
                    name: kept.name,
                    kind: kept.kind,
                    reason: kept.reason,
                })
                .collect(),
            sticky_notes_kept: report.sticky_notes_kept,
            links_kept: report.links_kept,
            comments_not_carried: report.comments_not_carried,
            signature_fields_removed: report.signature_fields_removed,
            output_bytes: report.output_bytes,
            cleaned_temporary_files: lyra_reader_core::saturating_u32(report.cleaned_temporaries),
        })
    }

    /// The name to offer when exporting a flattened copy: `<name> (flattened).pdf`.
    pub fn suggested_flatten_copy_path(&self) -> String {
        lyra_reader_pdfium::suggested_flatten_copy_path(Path::new(&self.path))
            .to_string_lossy()
            .into_owned()
    }

    /// The document facts and the four editable `/Info` entries.
    ///
    /// Page count, PDF version and encryption state are read-only facts. An encrypted document
    /// is reported with `is_encrypted: true` even when its dictionaries cannot be decrypted with
    /// the caller's password; the panel then explains why the save is refused.
    pub fn document_info(&self) -> Result<DocumentInfoRecord, LyraReaderFfiError> {
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            return Err(LyraReaderFfiError::Document {
                severity: ErrorSeverity::Document,
                message: "the document was replaced on disk; reopen it to read its information"
                    .to_string(),
            });
        }
        let path = Path::new(&self.path);
        if let Some(state) = &self.xfa {
            // The page count must describe what the handle renders (the synthetic form), while
            // the `/Info` entries still come from the source the reader opened.
            let mut record =
                match lyra_reader_pdfium::read_document_info(path, self.password.as_deref()) {
                    Ok(info) => DocumentInfoRecord {
                        title: info.properties.title,
                        author: info.properties.author,
                        subject: info.properties.subject,
                        keywords: info.properties.keywords,
                        page_count: info.facts.page_count,
                        pdf_version: info.facts.pdf_version,
                        is_encrypted: info.facts.is_encrypted,
                        has_info_dictionary: info.has_info_dictionary,
                    },
                    Err(_) => {
                        let facts = lyra_reader_pdfium::read_document_facts_unencrypted_header(
                            path,
                            self.backend.page_count(),
                        );
                        DocumentInfoRecord {
                            title: String::new(),
                            author: String::new(),
                            subject: String::new(),
                            keywords: String::new(),
                            page_count: facts.page_count,
                            pdf_version: facts.pdf_version,
                            is_encrypted: true,
                            has_info_dictionary: false,
                        }
                    }
                };
            record.page_count = self.backend.page_count();
            record.is_encrypted = state.status.encrypted;
            return Ok(record);
        }
        match lyra_reader_pdfium::read_document_info(path, self.password.as_deref()) {
            Ok(info) => Ok(DocumentInfoRecord {
                title: info.properties.title,
                author: info.properties.author,
                subject: info.properties.subject,
                keywords: info.properties.keywords,
                page_count: info.facts.page_count,
                pdf_version: info.facts.pdf_version,
                is_encrypted: info.facts.is_encrypted,
                has_info_dictionary: info.has_info_dictionary,
            }),
            Err(error) if error.code == ErrorCode::Encrypted => {
                let facts = lyra_reader_pdfium::read_document_facts_unencrypted_header(
                    path,
                    self.backend.page_count(),
                );
                Ok(DocumentInfoRecord {
                    title: String::new(),
                    author: String::new(),
                    subject: String::new(),
                    keywords: String::new(),
                    page_count: facts.page_count,
                    pdf_version: facts.pdf_version,
                    is_encrypted: true,
                    has_info_dictionary: false,
                })
            }
            Err(error) => Err(error.into()),
        }
    }

    /// Writes the four `/Info` entries into a **new PDF** at `destination`.
    pub fn save_document_properties_copy(
        &self,
        destination: String,
        title: String,
        author: String,
        subject: String,
        keywords: String,
    ) -> Result<PropertiesSaveReport, LyraReaderFfiError> {
        self.save_document_properties_to(
            PathBuf::from(destination),
            title,
            author,
            subject,
            keywords,
            SaveMode::Copy,
        )
    }

    /// Replaces the open document's `/Info` entries, after a verified backup.
    pub fn replace_with_document_properties(
        &self,
        title: String,
        author: String,
        subject: String,
        keywords: String,
    ) -> Result<PropertiesSaveReport, LyraReaderFfiError> {
        self.save_document_properties_to(
            PathBuf::from(&self.path),
            title,
            author,
            subject,
            keywords,
            SaveMode::ReplaceOriginal,
        )
    }

    /// The name to offer when saving an edited-properties copy: `<name> (properties).pdf`.
    pub fn suggested_properties_copy_path(&self) -> String {
        lyra_reader_pdfium::suggested_properties_copy_path(Path::new(&self.path))
            .to_string_lossy()
            .into_owned()
    }

    /// Whether a previous save of this document was interrupted.
    ///
    /// A save is only applied by the final rename, so a `<name>.lyra-reader-save-*.tmp` file beside the
    /// document means the save never reached that point and the document is still the last good
    /// copy. The shell reports this on open; the next save removes the leftovers.
    pub fn interrupted_save_note(&self) -> Option<String> {
        lyra_reader_pdfium::interrupted_save_note(Path::new(&self.path))
    }

    /// Total height of the scrolling content for the given page gap and layout.
    ///
    /// The three-argument `content_height_pt` below is the continuous mode this reader
    /// shipped before facing pages existed; it stays for callers that only know one layout.
    pub fn content_height_pt_for(&self, layout: ReaderLayout, gap_pt: f64) -> f64 {
        self.layout(layout, gap_pt).content_height_pt()
    }

    /// Total height of the scrolling content in continuous layout.
    pub fn content_height_pt(&self, gap_pt: f64) -> f64 {
        self.content_height_pt_for(ReaderLayout::Continuous, gap_pt)
    }

    /// Width of the widest page, or of the whole spread in facing layout.
    pub fn content_width_pt_for(&self, layout: ReaderLayout, gap_pt: f64) -> f64 {
        self.layout(layout, gap_pt).content_width_pt()
    }

    /// Width of the widest page in continuous layout.
    pub fn content_width_pt(&self, gap_pt: f64) -> f64 {
        self.content_width_pt_for(ReaderLayout::Continuous, gap_pt)
    }

    /// Top edge of a page in content space (for "go to page" and anchoring).
    pub fn page_top_pt_for(&self, page: u32, layout: ReaderLayout, gap_pt: f64) -> f64 {
        self.layout(layout, gap_pt).page_top_pt(page).unwrap_or(0.0)
    }

    /// Top edge of a page in continuous layout.
    pub fn page_top_pt(&self, page: u32, gap_pt: f64) -> f64 {
        self.page_top_pt_for(page, ReaderLayout::Continuous, gap_pt)
    }

    /// Page occupying the viewport top — the "current page" for the HUD.
    ///
    /// In facing layout a spread names its left page (see `DocumentLayout::page_at`).
    pub fn page_index_at_for(&self, scroll_y_pt: f64, layout: ReaderLayout, gap_pt: f64) -> u32 {
        self.layout(layout, gap_pt).page_at(scroll_y_pt)
    }

    /// Page occupying the viewport top in continuous layout.
    pub fn page_index_at(&self, scroll_y_pt: f64, gap_pt: f64) -> u32 {
        self.page_index_at_for(scroll_y_pt, ReaderLayout::Continuous, gap_pt)
    }

    /// Pages overlapping the viewport, in reading order.
    ///
    /// `margin_pt` widens the window so the shell can prefetch the next page.
    pub fn visible_pages_for(
        &self,
        scroll_y_pt: f64,
        viewport_height_pt: f64,
        layout: ReaderLayout,
        gap_pt: f64,
        margin_pt: f64,
    ) -> Vec<PagePlacementRecord> {
        // Ensure the lazy size pass has run; the placement then reports whether this page's
        // width/height are real or unknown. Geometry still uses the historical fallback.
        let sizes = self.page_sizes();
        self.layout(layout, gap_pt)
            .visible_pages(scroll_y_pt, viewport_height_pt, margin_pt)
            .iter()
            .map(|page| {
                let size = sizes.get(page.index as usize).copied().flatten();
                PagePlacementRecord {
                    index: page.index,
                    top_pt: page.top_pt,
                    left_pt: page.left_pt,
                    width_pt: size.map(|(width, _)| width),
                    height_pt: size.map(|(_, height)| height),
                }
            })
            .collect()
    }

    /// Pages overlapping the viewport in continuous layout.
    pub fn visible_pages(
        &self,
        scroll_y_pt: f64,
        viewport_height_pt: f64,
        gap_pt: f64,
        margin_pt: f64,
    ) -> Vec<PagePlacementRecord> {
        self.visible_pages_for(
            scroll_y_pt,
            viewport_height_pt,
            ReaderLayout::Continuous,
            gap_pt,
            margin_pt,
        )
    }

    /// Build the context and request plan for the AI panel.
    ///
    /// This is local work: it reads the document's text layer, selects blocks, and assembles the
    /// prompts and JSON bodies. It does not read an API key and does not open a connection. The
    /// shell shows the returned plan and starts a request only after the reader presses Send.
    pub fn prepare_ai_plan(
        &self,
        request: AiPlanRequestRecord,
    ) -> Result<AiPlanRecord, LyraReaderFfiError> {
        let action = match request.action {
            AiActionRecord::SummarizePage => AiAction::SummarizePage,
            AiActionRecord::SummarizeSelection => AiAction::SummarizeSelection,
            AiActionRecord::SummarizeDocument => AiAction::SummarizeDocument,
            AiActionRecord::AskSelection => AiAction::AskSelection,
            AiActionRecord::TranslateSelection => AiAction::TranslateSelection,
            AiActionRecord::DocumentChat => AiAction::DocumentChat,
            AiActionRecord::RegionQuestion => AiAction::RegionQuestion,
            AiActionRecord::SummarizeAbstract
            | AiActionRecord::SummarizeSection
            | AiActionRecord::SummarizePageLine => {
                return Err(LyraReaderFfiError::Ai {
                    severity: AiErrorCode::Other.severity(),
                    code: AiErrorCode::Other,
                    message: "A layered summary uses its own per-unit request builder.".to_string(),
                });
            }
        };
        let page_count = self.page_count();
        if page_count == 0 {
            return Err(LyraReaderFfiError::Ai {
                severity: AiErrorCode::EmptyContext.severity(),
                code: AiErrorCode::EmptyContext,
                message: "This document has no pages.".to_string(),
            });
        }
        if request.current_page >= page_count {
            return Err(LyraReaderFfiError::Ai {
                severity: AiErrorCode::EmptyContext.severity(),
                code: AiErrorCode::EmptyContext,
                message: format!(
                    "The current page {} is outside this document ({} pages).",
                    request.current_page + 1,
                    page_count
                ),
            });
        }
        let selection = request.selection.map(|selection| AiSelectionRange {
            page: selection.page,
            start: selection.start,
            end: selection.end,
        });
        if action.requires_selection() && selection.is_none() {
            return Err(LyraReaderFfiError::Ai {
                severity: AiErrorCode::Other.severity(),
                code: AiErrorCode::Other,
                message: "Select text first; there is no selection to send.".to_string(),
            });
        }
        if let Some(selection) = selection
            && selection.page >= page_count
        {
            return Err(LyraReaderFfiError::Ai {
                severity: AiErrorCode::EmptyContext.severity(),
                code: AiErrorCode::EmptyContext,
                message: format!(
                    "The selected page {} is outside this document.",
                    selection.page + 1
                ),
            });
        }

        let knowledge = document_knowledge_input(
            request.document_knowledge_text.clone(),
            request.document_knowledge_pages.clone(),
        );

        // A region image is exactly the selected rectangle. Once document knowledge has been
        // established, bounded related source passages can connect it to the full document.
        if action == AiAction::RegionQuestion {
            let region = request.region.ok_or_else(|| LyraReaderFfiError::Ai {
                severity: AiErrorCode::Other.severity(),
                code: AiErrorCode::Other,
                message: "The region question has no region; nothing was sent.".to_string(),
            })?;
            if region.page >= page_count {
                return Err(LyraReaderFfiError::Ai {
                    severity: AiErrorCode::EmptyContext.severity(),
                    code: AiErrorCode::EmptyContext,
                    message: format!(
                        "The selected region is on page {}, outside this document ({} pages).",
                        region.page + 1,
                        page_count
                    ),
                });
            }
            let temperature = request.temperature.and_then(|value| {
                if value.is_finite() {
                    Some(value as f32)
                } else {
                    None
                }
            });
            let temperature = if request.temperature.is_some_and(|value| !value.is_finite()) {
                Some(f32::NAN)
            } else {
                temperature
            };
            let reasoning_mode =
                ReasoningMode::from_wire(&request.reasoning_mode).ok_or_else(|| {
                    LyraReaderFfiError::InvalidArgument {
                        severity: ErrorSeverity::Document,
                        message: format!(
                            "Unknown reasoning mode {}. Use default, off, low, high or max.",
                            request.reasoning_mode
                        ),
                    }
                })?;
            let reasoning_encoding = ReasoningEncoding::from_wire(&request.reasoning_encoding)
                .ok_or_else(|| LyraReaderFfiError::InvalidArgument { severity: ErrorSeverity::Document,
                    message: format!(
                        "Unknown reasoning encoding {}. Use none, thinking, reasoning_effort, output_config or reasoning.effort.",
                        request.reasoning_encoding
                    ),
                })?;
            let settings = ChatSettings {
                base_url: request.base_url,
                model: request.model,
                temperature,
                max_tokens: request.max_tokens,
                reasoning_mode,
                reasoning_encoding,
            };
            let document_title = Path::new(&self.path)
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or("Document")
                .to_string();
            let image = match (
                region.image_png,
                region.image_width_px,
                region.image_height_px,
            ) {
                (Some(png), Some(width), Some(height)) => Some(ChatImage {
                    width_px: width,
                    height_px: height,
                    png,
                }),
                (None, _, _) => None,
                _ => {
                    return Err(LyraReaderFfiError::InvalidArgument {
                        severity: ErrorSeverity::Document,
                        message: "The region picture is missing its pixel size.".to_string(),
                    });
                }
            };
            let mut document_pages = Vec::new();
            if region.include_document_context {
                for page in 0..page_count {
                    let (text, chars) = self.ai_page(page)?;
                    document_pages.push(PageText { page, text, chars });
                }
            }
            let plan = build_region_question_plan(RegionQuestionRequest {
                document_title,
                page_count,
                page: region.page,
                document_pages,
                rect: RegionRect {
                    x_pt: region.x_pt,
                    y_pt: region.y_pt,
                    width_pt: region.width_pt,
                    height_pt: region.height_pt,
                },
                text: region.text,
                image,
                send_image: region.send_image,
                question: request.question.unwrap_or_default(),
                history: request
                    .history
                    .into_iter()
                    .map(|turn| ConversationTurn {
                        question: turn.question,
                        answer: turn.answer,
                    })
                    .collect(),
                settings,
                document_knowledge: knowledge,
            })?;
            return Ok(ai_plan_record(plan));
        }

        // Selection-only summary and translation send only the exact selected target.
        // Questions can retrieve context; a document summary needs every page.
        let page_list: Vec<u32> = if matches!(
            action,
            AiAction::TranslateSelection | AiAction::SummarizeSelection
        ) {
            vec![selection_only_page(selection)?]
        } else {
            (0..page_count).collect()
        };
        let mut pages = Vec::with_capacity(page_list.len());
        for page in page_list {
            let (text, chars) = self.ai_page(page)?;
            pages.push(PageText { page, text, chars });
        }

        let temperature = request.temperature.and_then(|value| {
            if value.is_finite() {
                Some(value as f32)
            } else {
                None
            }
        });
        // A non-finite value becomes None, which would silently drop the field; keep the
        // validation honest by passing NaN through so the core rejects it.
        let temperature = if request.temperature.is_some_and(|value| !value.is_finite()) {
            Some(f32::NAN)
        } else {
            temperature
        };
        let reasoning_mode =
            ReasoningMode::from_wire(&request.reasoning_mode).ok_or_else(|| {
                LyraReaderFfiError::InvalidArgument {
                    severity: ErrorSeverity::Document,
                    message: format!(
                        "Unknown reasoning mode {}. Use default, off, low, high or max.",
                        request.reasoning_mode
                    ),
                }
            })?;
        let reasoning_encoding = ReasoningEncoding::from_wire(&request.reasoning_encoding)
            .ok_or_else(|| LyraReaderFfiError::InvalidArgument { severity: ErrorSeverity::Document,
                message: format!(
                    "Unknown reasoning encoding {}. Use none, thinking, reasoning_effort, output_config or reasoning.effort.",
                    request.reasoning_encoding
                ),
            })?;
        let settings = ChatSettings {
            base_url: request.base_url,
            model: request.model,
            temperature,
            max_tokens: request.max_tokens,
            reasoning_mode,
            reasoning_encoding,
        };
        let document_title = Path::new(&self.path)
            .file_stem()
            .and_then(|stem| stem.to_str())
            .unwrap_or("Document")
            .to_string();
        let plan = if action == AiAction::DocumentChat {
            build_document_chat_plan(DocumentChatRequest {
                document_title,
                page_count,
                current_page: request.current_page,
                question: request.question.unwrap_or_default(),
                history: request
                    .history
                    .into_iter()
                    .map(|turn| ConversationTurn {
                        question: turn.question,
                        answer: turn.answer,
                    })
                    .collect(),
                pages,
                settings,
                document_knowledge: knowledge,
            })?
        } else {
            let input = PlanRequest {
                action,
                document_title,
                page_count,
                current_page: request.current_page,
                selection,
                question: request.question,
                language: request.language,
                pages,
                settings,
                document_knowledge: knowledge,
            };
            if request.document_knowledge {
                build_document_knowledge_plan(input)?
            } else {
                build_plan(input)?
            }
        };
        Ok(ai_plan_record(plan))
    }

    /// Inspect one layered-summary level without building prompts or wire bodies. The panel
    /// calls this when it opens: every unit returns the hash of exactly the text it would send,
    /// so a cached summary can be matched (or marked stale) with no request.
    pub fn inspect_ai_summary(
        &self,
        request: AiSummaryRequestRecord,
    ) -> Result<Vec<AiSummaryFingerprintRecord>, LyraReaderFfiError> {
        let page_count = self.page_count();
        if page_count == 0 {
            return Err(LyraReaderFfiError::Ai {
                severity: AiErrorCode::EmptyContext.severity(),
                code: AiErrorCode::EmptyContext,
                message: "This document has no pages.".to_string(),
            });
        }
        let layer = summary_layer_from_record(request.layer);
        let pages = summary_page_texts(self, layer, &request.units, page_count)?;
        let units = summary_units(&request.units);
        let settings = ChatSettings {
            base_url: "http://127.0.0.1".to_string(),
            model: "inspect".to_string(),
            temperature: None,
            max_tokens: None,
            reasoning_mode: ReasoningMode::Off,
            reasoning_encoding: ReasoningEncoding::Thinking,
        };
        let core = SummaryLayerRequest {
            layer,
            document_title: request.document_title,
            page_count,
            language: request.language,
            units,
            pages,
            settings,
            document_knowledge: None,
        };
        let coverages = inspect_summary_layer(&core)?;
        Ok(core
            .units
            .iter()
            .zip(coverages)
            .map(|(unit, coverage)| {
                let note = summary_coverage_note(layer, unit, &coverage, page_count);
                AiSummaryFingerprintRecord {
                    index: unit.index,
                    kind: summary_layer_record(unit.kind),
                    requested_page_start: unit.page_start,
                    requested_page_end: unit.page_end,
                    covered_page_start: coverage.covered_page_start,
                    covered_page_end: coverage.covered_page_end,
                    pages: coverage.pages,
                    truncated: coverage.truncated,
                    text_hash: coverage.text_hash,
                    characters: coverage.characters,
                    note,
                }
            })
            .collect())
    }

    /// Build one preview per unit of a layered-summary level. This never opens a connection;
    /// the shell previews the requests and starts them only after the reader presses Send.
    pub fn prepare_ai_summary(
        &self,
        request: AiSummaryRequestRecord,
    ) -> Result<AiSummaryPlanRecord, LyraReaderFfiError> {
        let page_count = self.page_count();
        if page_count == 0 {
            return Err(LyraReaderFfiError::Ai {
                severity: AiErrorCode::EmptyContext.severity(),
                code: AiErrorCode::EmptyContext,
                message: "This document has no pages.".to_string(),
            });
        }
        let layer = summary_layer_from_record(request.layer);
        let settings = summary_settings(&request)?;
        let pages = summary_page_texts(self, layer, &request.units, page_count)?;
        let units = summary_units(&request.units);
        let document_title = if request.document_title.trim().is_empty() {
            Path::new(&self.path)
                .file_stem()
                .and_then(|stem| stem.to_str())
                .unwrap_or("Document")
                .to_string()
        } else {
            request.document_title
        };
        let core = SummaryLayerRequest {
            layer,
            document_title,
            page_count,
            language: request.language,
            units,
            pages,
            settings,
            document_knowledge: document_knowledge_input(
                request.document_knowledge_text,
                request.document_knowledge_pages,
            ),
        };
        let plan = build_summary_layer(core)?;
        Ok(ai_summary_plan_record(plan))
    }
}

/// Page text for exactly the pages a layer can send. The abstract reads only its two bounded
/// end windows; section and page units read their own ranges. Deduplicated, so a 20-section
/// document extracts each page once.
fn summary_page_texts(
    document: &LyraReaderDocument,
    layer: SummaryLayer,
    units: &[AiSummaryUnitRequestRecord],
    page_count: u32,
) -> Result<Vec<PageText>, LyraReaderFfiError> {
    let mut needed = std::collections::BTreeSet::new();
    match layer {
        SummaryLayer::Abstract => {
            needed.extend(abstract_sample_page_indices(page_count));
        }
        SummaryLayer::Section | SummaryLayer::Page => {
            for unit in units {
                if unit.page_start == 0 {
                    continue;
                }
                let start = unit.page_start.min(page_count);
                let end = unit.page_end.max(unit.page_start).min(page_count);
                for page in start..=end {
                    needed.insert(page - 1);
                }
            }
        }
    }
    let mut pages = Vec::with_capacity(needed.len());
    for page in needed {
        let (text, chars) = document.ai_page(page)?;
        pages.push(PageText { page, text, chars });
    }
    Ok(pages)
}

fn summary_layer_record(layer: SummaryLayer) -> AiSummaryLayerRecord {
    match layer {
        SummaryLayer::Abstract => AiSummaryLayerRecord::Abstract,
        SummaryLayer::Section => AiSummaryLayerRecord::Section,
        SummaryLayer::Page => AiSummaryLayerRecord::Page,
    }
}

fn summary_layer_from_record(layer: AiSummaryLayerRecord) -> SummaryLayer {
    match layer {
        AiSummaryLayerRecord::Abstract => SummaryLayer::Abstract,
        AiSummaryLayerRecord::Section => SummaryLayer::Section,
        AiSummaryLayerRecord::Page => SummaryLayer::Page,
    }
}

fn summary_units(units: &[AiSummaryUnitRequestRecord]) -> Vec<SummaryUnitRequest> {
    units
        .iter()
        .map(|unit| SummaryUnitRequest {
            kind: summary_layer_from_record(unit.kind),
            index: unit.index,
            title: unit.title.clone(),
            number: unit.number.clone(),
            depth: unit.depth,
            page_start: unit.page_start,
            page_end: unit.page_end,
        })
        .collect()
}

fn summary_settings(request: &AiSummaryRequestRecord) -> Result<ChatSettings, LyraReaderFfiError> {
    let temperature = request.temperature.and_then(|value| {
        if value.is_finite() {
            Some(value as f32)
        } else {
            None
        }
    });
    let temperature = if request.temperature.is_some_and(|value| !value.is_finite()) {
        Some(f32::NAN)
    } else {
        temperature
    };
    let reasoning_mode = ReasoningMode::from_wire(&request.reasoning_mode).ok_or_else(|| {
        LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: format!(
                "Unknown reasoning mode {}. Use default, off, low, high or max.",
                request.reasoning_mode
            ),
        }
    })?;
    let reasoning_encoding =
        ReasoningEncoding::from_wire(&request.reasoning_encoding).ok_or_else(|| {
            LyraReaderFfiError::InvalidArgument { severity: ErrorSeverity::Document,
                message: format!(
                    "Unknown reasoning encoding {}. Use none, thinking, reasoning_effort, output_config or reasoning.effort.",
                    request.reasoning_encoding
                ),
            }
        })?;
    Ok(ChatSettings {
        base_url: request.base_url.clone(),
        model: request.model.clone(),
        temperature,
        max_tokens: request.max_tokens,
        reasoning_mode,
        reasoning_encoding,
    })
}

fn ai_summary_plan_record(plan: lyra_reader_ai::SummaryLayerPlan) -> AiSummaryPlanRecord {
    AiSummaryPlanRecord {
        layer: summary_layer_record(plan.layer),
        page_count: plan.page_count,
        units: plan
            .units
            .into_iter()
            .map(|unit| AiSummaryUnitRecord {
                index: unit.unit.index,
                kind: summary_layer_record(unit.unit.kind),
                title: unit.unit.title,
                number: unit.unit.number,
                depth: unit.unit.depth,
                page_start: unit.unit.page_start,
                page_end: unit.unit.page_end,
                covered_page_end: unit.coverage.covered_page_end,
                pages: unit.coverage.pages,
                truncated: unit.coverage.truncated,
                text_hash: unit.coverage.text_hash,
                characters: unit.coverage.characters,
                note: unit.note,
                plan: unit.plan.map(ai_plan_record),
                error: unit.error,
            })
            .collect(),
        note: plan.note,
        max_requests_per_batch: SUMMARY_MAX_REQUESTS_PER_BATCH as u32,
        max_concurrent_requests: SUMMARY_MAX_CONCURRENT_REQUESTS as u32,
    }
}

pub(crate) fn page_operation(record: PageOperationRecord) -> PageOperation {
    match record {
        PageOperationRecord::Rotate {
            pages,
            quarter_turns,
        } => PageOperation::Rotate {
            pages,
            quarter_turns,
        },
        PageOperationRecord::SetRotation {
            pages,
            quarter_turns,
        } => PageOperation::SetRotation {
            pages,
            quarter_turns,
        },
        PageOperationRecord::Delete { pages } => PageOperation::Delete { pages },
        PageOperationRecord::Move { pages, destination } => {
            PageOperation::Move { pages, destination }
        }
        PageOperationRecord::InsertBlank { index } => PageOperation::InsertBlank { index },
    }
}

fn page_edit_report(report: lyra_reader_pdfium::PageOperationReport) -> PageEditReport {
    PageEditReport {
        destination_path: report.destination.to_string_lossy().into_owned(),
        page_count: report.page_count,
        page_map: report.page_map,
        rotations: report.rotations,
        inserted_page: report.inserted_page,
        backup_path: report
            .backup_path
            .map(|path| path.to_string_lossy().into_owned()),
        output_bytes: report.output_bytes,
        cleaned_temporary_files: lyra_reader_core::saturating_u32(report.cleaned_temporaries),
    }
}

fn merge_report(report: lyra_reader_pdfium::MergeReport) -> MergeReportRecord {
    MergeReportRecord {
        destination_path: report.destination.to_string_lossy().into_owned(),
        page_count: report.page_count,
        first_page_count: report.first_page_count,
        appended_page_counts: report.appended_page_counts,
        appended_annotation_counts: report
            .appended_annotation_counts
            .into_iter()
            .map(lyra_reader_core::saturating_u32)
            .collect(),
        rotations: report.rotations,
        first_outline_entries: lyra_reader_core::saturating_u32(report.first_outline_entries),
        appended_outline_entries: lyra_reader_core::saturating_u32(report.appended_outline_entries),
        appended_outline_group_titles: report.appended_outline_group_titles,
        output_bytes: report.output_bytes,
        cleaned_temporary_files: lyra_reader_core::saturating_u32(report.cleaned_temporaries),
    }
}

fn split_report(report: lyra_reader_pdfium::SplitReport) -> SplitReportRecord {
    SplitReportRecord {
        parts: report
            .parts
            .into_iter()
            .map(|part| SplitOutputRecord {
                destination_path: part.destination.to_string_lossy().into_owned(),
                page_count: part.page_count,
                source_pages: part.source_pages,
                rotations: part.rotations,
                output_bytes: part.output_bytes,
            })
            .collect(),
        source_page_count: report.source_page_count,
        cleaned_temporary_files: lyra_reader_core::saturating_u32(report.cleaned_temporaries),
    }
}

impl LyraReaderDocument {
    /// Extracts a page and builds its Swift-parity line decomposition.
    ///
    /// This is the one place that performs the page-space→view-space Y flip for selection; the
    /// cache, the hit test and the box→range methods all read the same geometry.
    fn extract_text_page(
        &self,
        page: u32,
    ) -> Result<lyra_reader_text::TextPage, LyraReaderFfiError> {
        let raw = self.backend.raw_text_page(PageIndex(page))?;
        let geometry = self.backend.page_info(PageIndex(page))?.geometry;

        let chars = raw
            .chars
            .iter()
            .map(|character| {
                // Page boxes use a bottom-left origin, so the glyph's *top* edge is what
                // maps to the view-space y after the single Y-flip.
                let top_left = Point::new(
                    character.rect.origin.x,
                    character.rect.origin.y + character.rect.size.height,
                );
                // `page_to_view(1.0)` is the page→view transform at 100%: character boxes are
                // reported in content points, and the canvas applies the zoom itself.
                let view = geometry.page_to_view(1.0).apply(top_left);
                lyra_reader_text::CharBox {
                    rect: lyra_reader_core::Rect::new(
                        view.x,
                        view.y,
                        character.rect.size.width,
                        character.rect.size.height,
                    ),
                    origin: view,
                    unicode: character.unicode,
                    font_size: character.rect.size.height,
                    logical_order: 0,
                }
            })
            .collect();

        Ok(lyra_reader_text::TextPage {
            page: PageIndex(page),
            chars,
            blocks: Vec::new(),
            text: raw.text,
            is_generated: raw.is_generated,
            has_unicode_map_error: raw.has_unicode_map_error,
        })
    }

    fn retain_selection_text_page(
        &self,
        page: u32,
        value: Arc<lyra_reader_text::SelectionTextPage>,
    ) {
        let bytes = value.estimated_bytes();
        self.text_pages
            // Pure cache (immutable entries keyed by page): poisoning can only cost a miss.
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(page, value, bytes);
    }

    /// The cache read path: a hit avoids PDFium entirely, a miss extracts the page once.
    fn selection_text_page(
        &self,
        page: u32,
    ) -> Result<Arc<lyra_reader_text::SelectionTextPage>, LyraReaderFfiError> {
        if let Some(value) = self
            .text_pages
            // Pure cache (immutable entries keyed by page): poisoning can only cost a miss.
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(page)
        {
            return Ok(value);
        }

        let value = Arc::new(lyra_reader_text::SelectionTextPage::new(
            self.extract_text_page(page)?,
        ));
        {
            let mut cache = self
                .text_pages
                // Pure cache (immutable entries keyed by page): poisoning can only cost a miss.
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            cache.loads += 1;
            // Another thread may have filled the page while PDFium was extracting. Keep the
            // first value so both callers hold the same geometry.
            if let Some(existing) = cache.get(page) {
                return Ok(existing);
            }
            let bytes = value.estimated_bytes();
            cache.insert(page, Arc::clone(&value), bytes);
        }
        Ok(value)
    }
}

impl LyraReaderDocument {
    fn annotation_scan(
        &self,
    ) -> Result<(Vec<AnnotationRecord>, AnnotationReadStatus), LyraReaderFfiError> {
        if self.xfa.is_some() {
            // The synthetic PDF is a picture of the form, not an annotation carrier. Reading the
            // source's annotations through a handle whose page count is the rendering's would
            // ask the original one-page file for page 2. There is nothing to offer: annotation
            // tools are disabled for an XFA document.
            return Ok((Vec::new(), AnnotationReadStatus::default()));
        }
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            return Err(LyraReaderFfiError::Document {
                severity: ErrorSeverity::Document,
                message: "the document was replaced on disk; reopen it before reading annotations"
                    .to_string(),
            });
        }
        if let Ok(cache) = self.annotations.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok((cached.records.clone(), cached.status.clone()));
        }

        let mut records = Vec::new();
        let mut status = AnnotationReadStatus::default();
        let mut geometries: std::collections::HashMap<u32, lyra_reader_core::PageGeometry> =
            std::collections::HashMap::new();

        for page in 0..self.backend.page_count() {
            let geometry = match geometries.get(&page) {
                Some(geometry) => *geometry,
                None => match self.backend.page_info(PageIndex(page)) {
                    Ok(info) => {
                        let geometry = info.geometry;
                        geometries.insert(page, geometry);
                        geometry
                    }
                    Err(error) => {
                        // No geometry means even the annotations that read could not be placed.
                        // Count the page and keep the other pages readable.
                        status.unreadable_annotations =
                            status.unreadable_annotations.saturating_add(1);
                        status.pages.push(page);
                        status.details.push(format!("page {}: {error}", page + 1));
                        continue;
                    }
                },
            };

            let report = match self.backend.annotation_page_report(PageIndex(page)) {
                Ok(report) => report,
                Err(error) => {
                    status.unreadable_annotations = status.unreadable_annotations.saturating_add(1);
                    status.pages.push(page);
                    status.details.push(format!("page {}: {error}", page + 1));
                    continue;
                }
            };
            for unreadable in report.unreadable {
                status.unreadable_annotations = status.unreadable_annotations.saturating_add(1);
                if status.pages.last().copied() != Some(page) {
                    status.pages.push(page);
                }
                let slot = unreadable
                    .slot
                    .map(|slot| format!(" annotation {slot}"))
                    .unwrap_or_default();
                status
                    .details
                    .push(format!("page {}{slot}: {}", page + 1, unreadable.reason));
            }

            for annotation in report.annotations {
                let view = page_region_to_view(annotation.rect, geometry);
                // Classified before the record is built: the answer travels with the annotation
                // rather than being re-derived by every consumer from `kind` and `visible`.
                let drawing = annotation.drawing();
                let quads = annotation
                    .quads
                    .into_iter()
                    .map(|quad| {
                        let view = page_region_to_view(quad, geometry);
                        AnnotationQuad {
                            x_pt: view.origin.x,
                            y_pt: view.origin.y,
                            width_pt: view.size.width,
                            height_pt: view.size.height,
                        }
                    })
                    .collect();
                let to_view = geometry.page_to_view(1.0);
                let ink_paths = annotation
                    .ink_paths
                    .iter()
                    .map(|path| {
                        path.iter()
                            .map(|point| {
                                let view = to_view.apply(*point);
                                AnnotationPoint {
                                    x_pt: view.x,
                                    y_pt: view.y,
                                }
                            })
                            .collect()
                    })
                    .collect();
                let (line_start, line_end) = match annotation.line {
                    Some(line) => {
                        let start = to_view.apply(line.start);
                        let end = to_view.apply(line.end);
                        (
                            Some(AnnotationPoint {
                                x_pt: start.x,
                                y_pt: start.y,
                            }),
                            Some(AnnotationPoint {
                                x_pt: end.x,
                                y_pt: end.y,
                            }),
                        )
                    }
                    None => (None, None),
                };
                let kind = if annotation.kind == lyra_reader_core::RawAnnotationKind::Line
                    && annotation.line_arrow
                {
                    "arrow".to_string()
                } else {
                    annotation.kind.as_str().to_string()
                };
                let kind_flags = TaxonomyKind::from_document_kind(&kind).flags();
                let (editable, unsupported_reason) =
                    document_editability(AnnotationEditabilityInput {
                        kind: &kind,
                        is_reply: annotation.is_reply,
                        visible: annotation.visible,
                        ink_paths_empty: annotation.ink_paths.is_empty(),
                        line_missing: annotation.line.is_none(),
                        stamp_text_empty: annotation.stamp.as_ref().is_none_or(|stamp| {
                            stamp.text.as_deref().unwrap_or("").trim().is_empty()
                        }),
                        stamp_has_image: annotation
                            .stamp
                            .as_ref()
                            .is_some_and(|stamp| stamp.image.is_some()),
                        stamp_image_error: annotation
                            .stamp
                            .as_ref()
                            .and_then(|stamp| stamp.image_error.as_deref()),
                        drawing,
                    });

                records.push(AnnotationRecord {
                    page,
                    page_label: crate::format::page_label(&[page.saturating_add(1)]),
                    id: annotation.id,
                    parent_id: annotation.parent_id,
                    is_reply: annotation.is_reply,
                    has_popup: annotation.has_popup,
                    kind,
                    x_pt: view.origin.x,
                    y_pt: view.origin.y,
                    width_pt: view.size.width,
                    height_pt: view.size.height,
                    quads,
                    ink_paths,
                    line_start,
                    line_end,
                    line_arrow: annotation.line_arrow,
                    border_width_pt: annotation.border_width,
                    color: annotation.color.map(|color| AnnotationColorRecord {
                        red: color.red,
                        green: color.green,
                        blue: color.blue,
                    }),
                    opacity: annotation.opacity,
                    blend: annotation.blend.as_str().to_string(),
                    contents: annotation.contents,
                    author: annotation.author,
                    display_date: annotation
                        .modified
                        .as_deref()
                        .and_then(crate::format::pdf_date_display),
                    modified: annotation.modified,
                    font_size_pt: annotation.font_size_pt,
                    alignment: annotation.alignment.as_str().to_string(),
                    stamp: annotation.stamp.as_ref().map(|stamp| StampRecord {
                        text: stamp.text.clone(),
                        style: stamp.style.clone(),
                        image: stamp
                            .image
                            .as_ref()
                            .map(|image| image.data.clone())
                            .unwrap_or_default(),
                        image_encoding: stamp
                            .image
                            .as_ref()
                            .map(|image| image.encoding.as_str().to_string())
                            .unwrap_or_default(),
                        image_width: stamp.image.as_ref().map_or(0, |image| image.width),
                        image_height: stamp.image.as_ref().map_or(0, |image| image.height),
                        image_error: stamp.image_error.clone(),
                    }),
                    drawing: drawing.as_str().to_string(),
                    skip_reason: match drawing {
                        AnnotationDrawing::Skipped(reason) => Some(reason.as_str().to_string()),
                        _ => None,
                    },
                    visible: annotation.visible,
                    is_markup: kind_flags.is_markup,
                    is_geometry: kind_flags.is_geometry,
                    is_note: kind_flags.is_note,
                    editable,
                    unsupported_reason,
                });
            }
        }

        let scan = AnnotationScanCache {
            records: records.clone(),
            status: status.clone(),
        };
        if let Ok(mut cache) = self.annotations.lock() {
            *cache = Some(scan);
        }
        Ok((records, status))
    }

    /// The one gate for every command that would **rewrite the signed file itself**.
    ///
    /// The policy is "a signed document must not be modified", not "nothing may be derived from
    /// it": `extract_pages`, `merge_documents`, `split_pages`, `save_edited_copy`, and the
    /// annotation/form/properties copy saves write a new file and are allowed. Every `replace_*`
    /// command (and applying a staged page edit to the original) must
    /// call this before it touches the path. Keeping the decision in one place is what makes
    /// "the same explanation" true: the shell gets the sentence from
    /// [`Self::signature_status`] and an error carries the same string, so a disabled button and
    /// a refused direct call cannot disagree.
    fn ensure_writable(&self) -> Result<(), LyraReaderFfiError> {
        match self.signature.read_only_reason() {
            Some(message) => {
                Err(lyra_reader_core::LyraReaderError::new(ErrorCode::ReadOnly, message).into())
            }
            None => Ok(()),
        }
    }

    /// The gate for every command that writes an XFA derivative, including copies.
    ///
    /// A signed document may still be exported to a new file; an XFA form may not, because the
    /// synthetic PDF is not the source and a copy of it would be a picture of the form rather
    /// than a form. The refusal sentence is the one the banner shows.
    fn ensure_not_xfa(&self) -> Result<(), LyraReaderFfiError> {
        if let Some(state) = &self.xfa {
            let message = state
                .status
                .read_only_reason
                .clone()
                .unwrap_or_else(|| lyra_reader_xfa::READ_ONLY_REASON.to_string());
            return Err(
                lyra_reader_core::LyraReaderError::new(ErrorCode::ReadOnly, message).into(),
            );
        }
        Ok(())
    }

    /// Plain text and character boxes for one page, extracted once and kept for the
    /// document's lifetime. The boxes and the text come from the same `raw.chars` sequence, so
    /// the context builder's gutter rule and the canvas's selection indices agree.
    fn save_filled_form_to(
        &self,
        destination: PathBuf,
        values: Vec<FormFieldValueRecord>,
        mode: SaveMode,
    ) -> Result<FormSaveReport, LyraReaderFfiError> {
        // Writing values into the signed file is refused; a filled **copy** is a new file and
        // is allowed (and stripped of the signature material it would otherwise carry). An XFA
        // form has no fillable fields in its synthetic PDF, so both modes are refused.
        self.ensure_not_xfa()?;
        if mode == SaveMode::ReplaceOriginal {
            self.ensure_writable()?;
        }
        let updates: Vec<lyra_reader_pdfium::FormValueUpdate> = values
            .into_iter()
            .map(|value| lyra_reader_pdfium::FormValueUpdate {
                field_id: value.field_id,
                text: value.text,
                checked: value.checked,
                selected: value.selected,
            })
            .collect();
        let report = lyra_reader_pdfium::save_form_pdf(
            Path::new(&self.path),
            &destination,
            &updates,
            self.password.as_deref(),
            mode,
        )?;
        if mode == SaveMode::ReplaceOriginal {
            self.replaced
                .store(true, std::sync::atomic::Ordering::Release);
        }
        Ok(FormSaveReport {
            destination_path: report.destination.to_string_lossy().into_owned(),
            written_field_ids: report.written_fields,
            appended_bytes: report.appended_bytes,
            backup_path: report
                .backup_path
                .map(|path| path.to_string_lossy().into_owned()),
            cleaned_temporary_files: lyra_reader_core::saturating_u32(report.cleaned_temporaries),
            source_bytes_preserved: report.source_bytes_preserved,
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn save_document_properties_to(
        &self,
        destination: PathBuf,
        title: String,
        author: String,
        subject: String,
        keywords: String,
        mode: SaveMode,
    ) -> Result<PropertiesSaveReport, LyraReaderFfiError> {
        // In-place property writing is refused; a properties **copy** is a new file and is
        // allowed (and stripped of signature material). An XFA form allows neither.
        self.ensure_not_xfa()?;
        if mode == SaveMode::ReplaceOriginal {
            self.ensure_writable()?;
        }
        let properties = lyra_reader_pdfium::DocumentProperties {
            title,
            author,
            subject,
            keywords,
        };
        let report = lyra_reader_pdfium::save_document_properties(
            Path::new(&self.path),
            &destination,
            &properties,
            self.password.as_deref(),
            mode,
        )?;
        if mode == SaveMode::ReplaceOriginal {
            self.replaced
                .store(true, std::sync::atomic::Ordering::Release);
        }
        Ok(PropertiesSaveReport {
            destination_path: report.destination.to_string_lossy().into_owned(),
            written_keys: report.written_keys,
            appended_bytes: report.appended_bytes,
            backup_path: report
                .backup_path
                .map(|path| path.to_string_lossy().into_owned()),
            cleaned_temporary_files: lyra_reader_core::saturating_u32(report.cleaned_temporaries),
            source_bytes_preserved: report.source_bytes_preserved,
        })
    }

    fn ai_page(&self, page: u32) -> Result<(String, Vec<PageChar>), LyraReaderFfiError> {
        let page_count = self.backend.page_count();
        lyra_reader_core::checked_page_index(page, page_count, |page| {
            LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: lyra_reader_core::page_out_of_range_message(page, page_count),
            }
        })?;
        if let Some(cached) = self
            .ai_text
            // Pure cache (immutable entries keyed by page): poisoning can only cost a miss.
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(&page)
        {
            return Ok(cached.clone());
        }
        let raw = self.backend.raw_text_page(PageIndex(page))?;
        let geometry = self.backend.page_info(PageIndex(page))?.geometry;
        let chars: Vec<PageChar> = raw
            .chars
            .iter()
            .map(|character| {
                let top_left = Point::new(
                    character.rect.origin.x,
                    character.rect.origin.y + character.rect.size.height,
                );
                let view = geometry.page_to_view(1.0).apply(top_left);
                PageChar {
                    unicode: character.unicode,
                    x_pt: view.x,
                    y_pt: view.y,
                    width_pt: character.rect.size.width,
                    height_pt: character.rect.size.height,
                }
            })
            .collect();
        let text = text_of(&raw);
        self.ai_text
            // Pure cache (immutable entries keyed by page): poisoning can only cost a miss.
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(page, (text.clone(), chars.clone()));
        Ok((text, chars))
    }

    /// Refuses a rewrite when the annotation scan found content it could not decode.
    ///
    /// The shell has the same sentence on its copy button: rewriting around an annotation this
    /// engine could not read would drop somebody else's content. The engine enforces it too, so
    /// a caller that skipped the status check cannot lose the annotation.
    fn annotation_write_gate(&self) -> Result<(), LyraReaderFfiError> {
        let (_, status) = self.annotation_scan()?;
        if status.unreadable_annotations == 0 {
            return Ok(());
        }
        let pages = status
            .pages
            .iter()
            .map(|page| (page + 1).to_string())
            .collect::<Vec<_>>()
            .join(", ");
        let message = format!(
            "saving annotations is blocked because {} annotation(s) on page(s) {pages} could not be read; saving would drop them",
            status.unreadable_annotations
        );
        Err(
            lyra_reader_core::LyraReaderError::new(ErrorCode::ReadOnly, message)
                .with_detail(status.details.join("; "))
                .into(),
        )
    }

    // The result of merging three independent write-back features (annotations, edits/deletes,
    // bookmarks) into one verified save: one argument per record list, plus the destination,
    // zoom and mode. Splitting it would only move the same values into a struct.
    #[allow(clippy::too_many_arguments)]
    fn save_annotations_to(
        &self,
        destination: std::path::PathBuf,
        annotations: Vec<WriteAnnotationRecord>,
        bookmarks: Vec<WriteBookmarkRecord>,
        updates: Vec<AnnotationUpdateRecord>,
        deletions: Vec<AnnotationDeleteRecord>,
        zoom: f64,
        mode: SaveMode,
    ) -> Result<AnnotationSaveReport, LyraReaderFfiError> {
        // A copy writes a new file and is allowed for a signed document. Replacing the original
        // would invalidate the signature, so it is refused here; the copy is then stripped of
        // the signature material it would otherwise carry. An XFA form allows neither.
        self.ensure_not_xfa()?;
        // A document with an annotation the reader could not decode must not be rewritten:
        // the unknown content would be dropped. This is the engine half of the shell's
        // "annotation writes blocked" state; it also covers callers that never read the status.
        self.annotation_write_gate()?;
        if mode == SaveMode::ReplaceOriginal {
            self.ensure_writable()?;
        }
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            return Err(LyraReaderFfiError::Document {
                severity: ErrorSeverity::Document,
                message: "the document was replaced on disk; reopen it before saving again"
                    .to_string(),
            });
        }
        if self.backend.needs_password() {
            return Err(LyraReaderFfiError::Document { severity: ErrorSeverity::Document,
                message:
                    "this document is encrypted; saving annotations or bookmarks into it is not supported yet"
                        .to_string(),
            });
        }
        if !(zoom.is_finite() && zoom > 0.0 && zoom <= 64.0) {
            return Err(LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: format!("zoom must be positive, finite and at most 64, got {zoom}"),
            });
        }
        let page_count = self.backend.page_count();
        // One rule set with the outline writer and the shell's creation-time check.
        let bookmark_limits: Vec<annotation_rules::BookmarkSpec<'_>> = bookmarks
            .iter()
            .map(|record| annotation_rules::BookmarkSpec {
                id: &record.id,
                page: i64::from(record.page),
                title: &record.title,
                y_pt: record.y_pt,
            })
            .collect();
        annotation_rules::validate_bookmarks(&bookmark_limits, page_count as usize)
            .map_err(annotation_rule_error)?;
        let mut geometries: std::collections::HashMap<u32, PageGeometry> =
            std::collections::HashMap::new();
        let mut bookmark_specs = Vec::with_capacity(bookmarks.len());
        for record in bookmarks {
            bookmark_specs.push(WriteBookmark {
                id: record.id,
                page: PageIndex(record.page),
                title: record.title,
                y_pt: record.y_pt,
            });
        }
        let mut additions = Vec::with_capacity(annotations.len());
        for record in &annotations {
            additions.push(self.convert_write_annotation(
                record,
                page_count,
                zoom,
                &mut geometries,
            )?);
        }
        let mut changed = Vec::with_capacity(updates.len());
        for update in &updates {
            let values = self.convert_write_annotation(
                &update.annotation,
                page_count,
                zoom,
                &mut geometries,
            )?;
            changed.push(lyra_reader_pdfium::AnnotationUpdate {
                target: update.target.clone(),
                values,
                assign_name: update.assign_name.clone(),
            });
        }
        let removed = deletions
            .iter()
            .map(|deletion| lyra_reader_pdfium::AnnotationDelete {
                target: deletion.target.clone(),
            })
            .collect::<Vec<_>>();
        let report = lyra_reader_pdfium::save_annotation_changes(
            Path::new(&self.path),
            &destination,
            &lyra_reader_pdfium::AnnotationChanges {
                additions,
                updates: changed,
                deletions: removed,
            },
            &bookmark_specs,
            self.password.as_deref(),
            mode,
        )?;
        if mode == SaveMode::ReplaceOriginal {
            // The open backend still holds the pre-replacement in-memory document; the shell
            // reopens it after a replace, and every read before that reopen is refused rather
            // than answered from the old file.
            self.replaced
                .store(true, std::sync::atomic::Ordering::Release);
            if let Ok(mut cache) = self.annotations.lock() {
                *cache = None;
            }
        }
        Ok(AnnotationSaveReport {
            destination_path: report.destination.to_string_lossy().into_owned(),
            written_ids: report.written_ids,
            appended_bytes: report.appended_bytes,
            backup_path: report
                .backup_path
                .map(|path| path.to_string_lossy().into_owned()),
            preexisting_annotation_count: lyra_reader_core::saturating_u32(
                report.preexisting_annotation_count,
            ),
            written_bookmark_ids: report.written_bookmark_ids,
            bookmark_outline_title: report.bookmark_outline_title,
            preexisting_outline_entry_count: lyra_reader_core::saturating_u32(
                report.preexisting_outline_entry_count,
            ),
            cleaned_temporary_files: lyra_reader_core::saturating_u32(report.cleaned_temporaries),
            deleted_file_ids: report.deleted_ids,
            deleted_reply_count: lyra_reader_core::saturating_u32(report.deleted_reply_count),
            deleted_popup_count: lyra_reader_core::saturating_u32(report.deleted_popup_count),
            assigned_names: report.assigned_names,
            source_bytes_preserved: report.source_bytes_preserved,
            full_rewrite: report.full_rewrite,
        })
    }

    /// Converts one shell write record into the page-space annotation the writer expects.
    ///
    /// Geometry crosses the FFI in view space at `zoom`, exactly what the canvas draws; the page
    /// geometry inverts that once, so a mark saved at 100% and the same mark saved at 300% land
    /// in the same PDF coordinates. Split out of the save loop so an edit and an addition go
    /// through exactly the same conversion.
    fn convert_write_annotation(
        &self,
        record: &WriteAnnotationRecord,
        page_count: u32,
        zoom: f64,
        geometries: &mut std::collections::HashMap<u32, PageGeometry>,
    ) -> Result<WriteAnnotation, LyraReaderFfiError> {
        annotation_rules::validate_page(&record.id, i64::from(record.page), page_count as usize)
            .map_err(annotation_rule_error)?;
        // The text/opacity/date limits the write-back used to discover later; refused here with
        // the same sentence the shell now uses at creation.
        annotation_rules::validate_opacity(&record.id, record.opacity)
            .map_err(annotation_rule_error)?;
        annotation_rules::validate_note(&record.id, &record.contents)
            .map_err(annotation_rule_error)?;
        annotation_rules::validate_author(&record.id, &record.author)
            .map_err(annotation_rule_error)?;
        annotation_rules::validate_pdf_date(&record.id, &record.modified)
            .map_err(annotation_rule_error)?;
        let geometry = match geometries.get(&record.page) {
            Some(geometry) => *geometry,
            None => {
                let geometry = self.backend.page_info(PageIndex(record.page))?.geometry;
                geometries.insert(record.page, geometry);
                geometry
            }
        };
        let inverse =
            geometry
                .view_to_page(zoom)
                .ok_or_else(|| LyraReaderFfiError::InvalidArgument {
                    severity: ErrorSeverity::Document,
                    message: format!("page {} has no invertible geometry", record.page + 1),
                })?;
        let quads = record
            .quads
            .iter()
            .map(|quad| view_box_to_page_rect(quad, inverse, &geometry))
            .collect::<Result<Vec<_>, _>>()?;
        let supplied_rect = view_box_to_page_rect(&record.rect, inverse, &geometry)?;
        let geometry_border = |id: &str, width: f64| -> Result<f64, LyraReaderFfiError> {
            annotation_rules::validate_border_width(id, width).map_err(annotation_rule_error)?;
            Ok(width)
        };
        let view_point = |point: &AnnotationPoint| -> Point {
            inverse.apply(Point::new(point.x_pt, point.y_pt))
        };
        let (kind, rect, quads, ink_paths, line, line_arrow, border_width, font_size, alignment) =
            match record.kind {
                AnnotationWriteKind::Note => (
                    WriteAnnotationKind::Text,
                    supplied_rect,
                    Vec::new(),
                    Vec::new(),
                    None,
                    false,
                    0.0,
                    0.0,
                    AnnotationAlignment::Left,
                ),
                AnnotationWriteKind::FreeText => {
                    annotation_rules::validate_font_size(&record.id, record.font_size_pt)
                        .map_err(annotation_rule_error)?;
                    annotation_rules::validate_alignment(&record.id, &record.text_alignment)
                        .map_err(annotation_rule_error)?;
                    let alignment = match record.text_alignment.as_str() {
                        "left" => AnnotationAlignment::Left,
                        "center" => AnnotationAlignment::Center,
                        "right" => AnnotationAlignment::Right,
                        _ => unreachable!("validated above"),
                    };
                    (
                        WriteAnnotationKind::FreeText,
                        supplied_rect,
                        Vec::new(),
                        Vec::new(),
                        None,
                        false,
                        0.0,
                        record.font_size_pt,
                        alignment,
                    )
                }
                AnnotationWriteKind::Highlight
                | AnnotationWriteKind::Underline
                | AnnotationWriteKind::StrikeOut
                | AnnotationWriteKind::Squiggly => {
                    if quads.is_empty() {
                        return Err(LyraReaderFfiError::InvalidArgument {
                            severity: ErrorSeverity::Document,
                            message: format!("annotation {:?} has no quads to write", record.id),
                        });
                    }
                    let mut union = quads[0];
                    for quad in &quads[1..] {
                        union = union.union(*quad);
                    }
                    if !rects_close(union, supplied_rect) {
                        return Err(LyraReaderFfiError::InvalidArgument {
                            severity: ErrorSeverity::Document,
                            message: format!(
                                "annotation {:?} has a rect that does not cover its quads",
                                record.id
                            ),
                        });
                    }
                    let kind = match record.kind {
                        AnnotationWriteKind::Highlight => WriteAnnotationKind::Highlight,
                        AnnotationWriteKind::Underline => WriteAnnotationKind::Underline,
                        AnnotationWriteKind::StrikeOut => WriteAnnotationKind::StrikeOut,
                        AnnotationWriteKind::Squiggly => WriteAnnotationKind::Squiggly,
                        _ => unreachable!("handled by the outer match"),
                    };
                    (
                        kind,
                        union,
                        quads,
                        Vec::new(),
                        None,
                        false,
                        0.0,
                        0.0,
                        AnnotationAlignment::Left,
                    )
                }
                AnnotationWriteKind::Ink => {
                    if record.ink_paths.is_empty() {
                        return Err(LyraReaderFfiError::InvalidArgument {
                            severity: ErrorSeverity::Document,
                            message: format!(
                                "ink annotation {:?} has no strokes to write",
                                record.id
                            ),
                        });
                    }
                    let border = geometry_border(&record.id, record.border_width_pt)?;
                    let paths: Vec<Vec<Point>> = record
                        .ink_paths
                        .iter()
                        .map(|path| path.iter().map(view_point).collect())
                        .collect();
                    (
                        WriteAnnotationKind::Ink,
                        supplied_rect,
                        Vec::new(),
                        paths,
                        None,
                        false,
                        border,
                        0.0,
                        AnnotationAlignment::Left,
                    )
                }
                AnnotationWriteKind::Square | AnnotationWriteKind::Circle => {
                    let border = geometry_border(&record.id, record.border_width_pt)?;
                    let kind = match record.kind {
                        AnnotationWriteKind::Square => WriteAnnotationKind::Square,
                        AnnotationWriteKind::Circle => WriteAnnotationKind::Circle,
                        _ => unreachable!("handled by the outer match"),
                    };
                    (
                        kind,
                        supplied_rect,
                        Vec::new(),
                        Vec::new(),
                        None,
                        false,
                        border,
                        0.0,
                        AnnotationAlignment::Left,
                    )
                }
                AnnotationWriteKind::Line => {
                    let border = geometry_border(&record.id, record.border_width_pt)?;
                    let (Some(start), Some(end)) = (record.line_start, record.line_end) else {
                        return Err(LyraReaderFfiError::InvalidArgument {
                            severity: ErrorSeverity::Document,
                            message: format!(
                                "line annotation {:?} has no endpoints to write",
                                record.id
                            ),
                        });
                    };
                    (
                        WriteAnnotationKind::Line,
                        supplied_rect,
                        Vec::new(),
                        Vec::new(),
                        Some(RawAnnotationLine {
                            start: view_point(&start),
                            end: view_point(&end),
                        }),
                        record.line_arrow,
                        border,
                        0.0,
                        AnnotationAlignment::Left,
                    )
                }
                AnnotationWriteKind::Stamp => {
                    annotation_rules::validate_stamp_text(&record.id, &record.contents)
                        .map_err(annotation_rule_error)?;
                    annotation_rules::validate_stamp_style(&record.id, &record.stamp_style)
                        .map_err(annotation_rule_error)?;
                    (
                        WriteAnnotationKind::Stamp,
                        supplied_rect,
                        Vec::new(),
                        Vec::new(),
                        None,
                        false,
                        0.0,
                        0.0,
                        AnnotationAlignment::Left,
                    )
                }
                AnnotationWriteKind::Signature => {
                    if !record.contents.is_empty() {
                        return Err(LyraReaderFfiError::InvalidArgument {
                            severity: ErrorSeverity::Document,
                            message: format!(
                                "signature annotation {:?} must not carry text",
                                record.id
                            ),
                        });
                    }
                    annotation_rules::validate_signature_dimensions(
                        &record.id,
                        record.signature_width,
                        record.signature_height,
                        record.signature_rgba.len(),
                    )
                    .map_err(annotation_rule_error)?;
                    (
                        WriteAnnotationKind::Signature,
                        supplied_rect,
                        Vec::new(),
                        Vec::new(),
                        None,
                        false,
                        0.0,
                        0.0,
                        AnnotationAlignment::Left,
                    )
                }
            };
        let (stamp_style, stamp_image) = match record.kind {
            AnnotationWriteKind::Stamp => (Some(record.stamp_style.clone()), None),
            AnnotationWriteKind::Signature => (
                None,
                Some(lyra_reader_pdfium::WriteStampImage {
                    width: record.signature_width,
                    height: record.signature_height,
                    rgba: record.signature_rgba.clone(),
                }),
            ),
            _ => (None, None),
        };
        Ok(WriteAnnotation {
            id: record.id.clone(),
            page: PageIndex(record.page),
            kind,
            rect,
            quads,
            ink_paths,
            line,
            line_arrow,
            border_width,
            font_size,
            alignment,
            stamp_style,
            stamp_image,
            color: [record.color.red, record.color.green, record.color.blue],
            opacity: record.opacity,
            contents: text_or_none(&record.contents),
            author: text_or_none(&record.author),
            modified: text_or_none(&record.modified),
        })
    }

    /// Builds (and caches) the layout for `layout` and `gap_pt`.
    ///
    /// The cache key carries both: the same gap produces a different layout in facing mode,
    /// and a mode switch must not be answered from the previous mode's placements.
    fn layout(&self, layout: ReaderLayout, gap_pt: f64) -> Arc<DocumentLayout> {
        // Rust 2024 let-chains keep the lookups flat.
        if let Ok(cache) = self.layout.lock()
            && let Some((cached_layout, cached_gap, placements)) = cache.as_ref()
            && *cached_layout == layout
            && (*cached_gap - gap_pt).abs() < f64::EPSILON
        {
            return Arc::clone(placements);
        }

        let sizes = self.page_sizes();
        let placements = Arc::new(DocumentLayout::new_with_mode(
            // Unknown pages keep the historical fallback here so existing documents scroll
            // exactly as before. The placement record below still reports them as unknown.
            sizes
                .iter()
                .map(|size| size.unwrap_or(UNKNOWN_LAYOUT_PAGE_SIZE)),
            gap_pt,
            layout.session(),
        ));

        if let Ok(mut cache) = self.layout.lock() {
            *cache = Some((layout, gap_pt, Arc::clone(&placements)));
        }
        placements
    }

    /// Page sizes in points, measured lazily on the first layout/raster request.
    fn page_sizes(&self) -> CachedPageSizes {
        if let Ok(cache) = self.page_sizes.lock()
            && let Some(sizes) = cache.as_ref()
        {
            return sizes.clone();
        }

        let count = self.backend.page_count();
        let sizes = collect_page_sizes(count, |index| {
            let info = self.backend.page_info(PageIndex(index))?;
            let view = info.geometry.view_size(1.0);
            Ok((view.width, view.height))
        });
        let unknown = sizes.iter().filter(|size| size.is_none()).count();
        if unknown > 0 {
            // Once per document: the size list is cached, and the fallback is applied by the
            // shell. Logging every layout would repeat the same fact on every scroll frame.
            eprintln!(
                "lyra-reader-ffi: {unknown} of {count} page(s) in {} have no measurable size; \
                 their placement records report an unknown size (layout keeps the historical fallback)",
                self.path,
            );
        }

        if let Ok(mut cache) = self.page_sizes.lock() {
            *cache = Some(sizes.clone());
        }
        sizes
    }

    /// The reference list plus the citation style it implies, parsed once.
    ///
    /// [`LyraReaderDocument::citations`] needs the same list: a superscript numeral is only a citation
    /// if the bibliography carries its label and the body does not bracket its citations. Both
    /// answers come from this one scan, so the detector can never disagree with the resolver
    /// about which labels exist.
    ///
    /// The scan reads every page's text and records each page's citation spans here as well.
    /// That is the same work a first click on a page would do, done once for the whole document
    /// and stored in the persistent cache: a citation on page 800 costs a map lookup, not a text
    /// extraction, and a 900-page book holds one citation record per span rather than one text
    /// layer per page. The reference-list locator itself still reads the first
    /// [`REFERENCE_SCAN_PAGES`] pages (see that constant).
    fn reference_cache(&self) -> Result<Arc<ReferenceCache>, LyraReaderFfiError> {
        self.ensure_index_loaded();
        if let Ok(cache) = self.references.lock()
            && let Some(cached) = cache.as_ref()
        {
            return Ok(Arc::clone(cached));
        }

        let started = Instant::now();
        // Scanning from the front with a window, rather than only the tail: real papers put the
        // list anywhere from a third of the way in (with appendices after it) to the very end.
        // The window is what keeps a 2000-page manual's reference locator from holding every
        // page's text at once; the citation index still reads the remaining pages below.
        let total = self.backend.page_count();
        let scan_end = total.min(REFERENCE_SCAN_PAGES);
        let mut pages = Vec::new();
        for index in 0..scan_end {
            if let Ok(text) = self.backend.raw_text_page(PageIndex(index)) {
                pages.push((index, text));
            }
        }

        // Ground-truth pass: a paper that links its citations into the bibliography is telling us
        // exactly where each entry starts, and those landings beat any numbering rule. Collect
        // them first, then let the shared locator decide page by page.
        let mut landings: std::collections::BTreeMap<u32, Vec<f64>> =
            std::collections::BTreeMap::new();
        if let Some(first_list_page) =
            lyra_reader_text::find_references(pages.iter().map(|(page, text)| (*page, text)), 2000)
                .iter()
                .map(|entry| entry.page)
                .min()
        {
            // Only the body can point into the list, so there is no need to scan past it.
            for body_page in 0..first_list_page {
                let Ok(links) = self.backend.link_targets(PageIndex(body_page)) else {
                    continue;
                };
                for link in links {
                    if let (Some(target), Some(top)) = (link.page, link.dest_top_y)
                        && target.get() >= first_list_page
                    {
                        landings.entry(target.get()).or_default().push(top);
                    }
                }
            }
        }

        // Every reference list, with the document-wide one rebuilt from the link landings exactly
        // as the app has always resolved against it. The other lists are what a page-aware
        // citation needs; they are parsed once here and persisted with the index.
        let bibliography =
            lyra_reader_text::find_reference_lists_with_landings(&pages, &landings, 2000);
        let document_wide_entries = bibliography
            .document_wide_list()
            .map(|list| list.entries.clone())
            .unwrap_or_default();
        let style = lyra_reader_text::CitationStyle::for_document(&pages, &document_wide_entries);
        // One page → view transform per page, not per fragment: a bibliography page holds dozens
        // of entries and each of their fragments asks for the same page again.
        let mut transforms: std::collections::HashMap<u32, lyra_reader_core::Transform2D> =
            std::collections::HashMap::new();
        let mut lists = Vec::with_capacity(bibliography.lists.len());
        for list in &bibliography.lists {
            let records = reference_records(&self.backend, &mut transforms, &list.entries);
            lists.push(cached_reference_list(list, records));
        }
        let records = lists
            .get(bibliography.document_wide)
            .map(|list| list.records.clone())
            .unwrap_or_default();
        // Resolution and attribution run on the records the cache carries, so an entry index is
        // also its preview record's index.
        let bibliography = bibliography_from_cached(&lists, bibliography.document_wide);

        // The body pages are in `pages` already; turn their text into click targets now, with
        // the same function and style a per-page call would use. Empty pages stay in the map so
        // a click on them is a lookup, not a second text extraction.
        let mut citations = std::collections::BTreeMap::new();
        for (index, text) in &pages {
            let Some(transform) = document_page_view(&self.backend, &mut transforms, *index) else {
                continue;
            };
            citations.insert(*index, citation_records(text, &style, *index, transform));
        }
        // The reference locator stops at its window, but the citation index does not: every page
        // past it is read once here, with the style the document's own list implied, and stored
        // in the same map (and in the cache). This is the difference between a 900-page book
        // indexing every page once and re-extracting a page on every click.
        for index in scan_end..total {
            let Ok(text) = self.backend.raw_text_page(PageIndex(index)) else {
                continue;
            };
            let Some(transform) = document_page_view(&self.backend, &mut transforms, index) else {
                continue;
            };
            citations.insert(index, citation_records(&text, &style, index, transform));
        }

        let cache = Arc::new(ReferenceCache {
            records,
            style,
            lists,
            bibliography,
        });
        if let Ok(mut guard) = self.references.lock() {
            *guard = Some(Arc::clone(&cache));
        }
        if let Ok(mut guard) = self.citations.lock() {
            *guard = Some(citations);
        }
        self.note_derived(started.elapsed());
        self.maybe_write_index();
        Ok(cache)
    }
}

/// Index-cache bookkeeping and the persistent-index report.
///
/// These stay outside the `#[uniffi::export]` block: the shell does not need a new method, and
/// the report is a Rust-side check/measurement surface. Every accessor above funnels through
/// [`LyraReaderDocument::ensure_index_loaded`], so the lookup happens exactly once per document.
impl LyraReaderDocument {
    /// The cache state for this document, for checks and measurements.
    ///
    /// Calling this first performs the one cache lookup (hashing the PDF and reading the
    /// index cache); it does not build any index component. `derived_parts` then says how much work
    /// the following accessors actually did.
    pub fn index_cache_report(&self) -> IndexCacheReport {
        self.ensure_index_loaded();
        if let Ok(runtime) = self.index.lock() {
            return IndexCacheReport {
                outcome: runtime.outcome,
                cache_path: runtime
                    .cache_path
                    .as_ref()
                    .map(|path| path.display().to_string())
                    .unwrap_or_default(),
                cache_bytes: runtime.cache_bytes,
                validation_micros: micros(runtime.validation),
                derived_parts: runtime.derived_parts,
                derived_micros: micros(runtime.derived),
                content_sha256: runtime
                    .identity
                    .as_ref()
                    .map(|identity| identity.sha256.clone()),
                write_disabled: runtime.write_disabled,
                write_error: runtime.write_error.clone(),
            };
        }
        IndexCacheReport {
            outcome: IndexCacheOutcome::NotAttempted,
            cache_path: String::new(),
            cache_bytes: 0,
            validation_micros: 0,
            derived_parts: 0,
            derived_micros: 0,
            content_sha256: None,
            write_disabled: true,
            write_error: Some("the index cache state is poisoned".to_string()),
        }
    }

    /// Looks the index cache up once and, on a hit, fills every in-memory index component with it.
    ///
    /// Lazy with respect to the **cache file**: opening reads the bytes to compute the document
    /// identity (the shell needs it for every cache), but does not read or validate the index
    /// cache, so the first paint does not wait for the cache lookup. The shell's background
    /// loaders are what call the accessors that reach this point.
    fn ensure_index_loaded(&self) {
        let mut runtime = match self.index.lock() {
            Ok(runtime) => runtime,
            Err(_) => return,
        };
        if runtime.attempted {
            return;
        }
        runtime.attempted = true;

        let path = crate::index_cache::cache_path_for_key(self.document_id.key());
        runtime.cache_path = Some(path.clone());
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            // The file on disk is no longer the file the backend parsed. A cache bound to
            // either set of bytes would be a guess; let the shell reopen first.
            runtime.outcome = IndexCacheOutcome::Unreadable;
            runtime.write_disabled = true;
            runtime.write_error = Some(
                "the document was replaced on disk before the index cache was read".to_string(),
            );
            return;
        }
        if disabled_by_environment() {
            runtime.outcome = IndexCacheOutcome::Disabled;
            runtime.write_disabled = true;
            return;
        }

        let started = Instant::now();
        let identity = self.document_id.content.clone();
        runtime.identity = Some(identity.clone());

        // The new key is authoritative. When it has no file, an older build's path-only cache
        // is read and a hit is copied forward; the old file is left in place so a downgrade (or
        // a user inspecting it) still has the cache it wrote. Reading the legacy file also
        // preserves the "stale cache" outcome after an in-place byte change: the new key is
        // missing, the old path still holds the previous bytes' values, and `read_cache` says
        // `Stale` rather than silently claiming there was never a cache.
        let legacy = crate::index_cache::legacy_cache_path(Path::new(&self.path));
        let read = crate::index_cache::read_cache_with_migration(
            &path,
            &legacy,
            &identity,
            self.backend.page_count(),
        );
        runtime.cache_bytes = std::fs::metadata(&path)
            .map(|metadata| metadata.len())
            .unwrap_or(0);

        match read {
            CacheRead::Hit(file) => {
                let IndexCacheFile {
                    outline,
                    references,
                    figures,
                    metadata,
                    citations,
                    ..
                } = *file;
                if let Ok(mut cache) = self.references.lock() {
                    let bibliography = bibliography_from_cached(
                        &references.lists,
                        references.document_wide as usize,
                    );
                    *cache = Some(Arc::new(ReferenceCache {
                        records: references.records,
                        style: references.style,
                        lists: references.lists,
                        bibliography,
                    }));
                }
                if let Ok(mut cache) = self.figures.lock() {
                    *cache = Some(figures);
                }
                if let Ok(mut cache) = self.metadata.lock() {
                    *cache = Some(metadata);
                }
                if let Ok(mut cache) = self.outline.lock() {
                    *cache = Some(outline);
                }
                if let Ok(mut cache) = self.citations.lock() {
                    *cache = Some(citations);
                }
                runtime.outcome = IndexCacheOutcome::Hit;
                runtime.validation = started.elapsed();
                eprintln!(
                    "lyra-reader-index: hit {} ({} bytes, sha256 {}…, validated in {:.1} ms)",
                    path.display(),
                    runtime.cache_bytes,
                    &identity.sha256[..identity.sha256.len().min(12)],
                    runtime.validation.as_secs_f64() * 1000.0,
                );
            }
            CacheRead::Stale => {
                runtime.outcome = IndexCacheOutcome::Stale;
                runtime.validation = started.elapsed();
                eprintln!(
                    "lyra-reader-index: stale cache (content changed), falling back to a full parse"
                );
            }
            CacheRead::Missing => {
                runtime.outcome = IndexCacheOutcome::Missing;
                runtime.validation = started.elapsed();
                eprintln!(
                    "lyra-reader-index: no cache (hashed in {:.1} ms), the index will be built",
                    runtime.validation.as_secs_f64() * 1000.0,
                );
            }
            CacheRead::Corrupt { detail } => {
                runtime.outcome = IndexCacheOutcome::Corrupt;
                runtime.validation = started.elapsed();
                eprintln!(
                    "lyra-reader-index: ignoring a corrupt cache ({detail}); the document will be parsed"
                );
            }
            CacheRead::Incompatible { detail } => {
                runtime.outcome = IndexCacheOutcome::Incompatible;
                runtime.write_disabled = true;
                runtime.validation = started.elapsed();
                eprintln!(
                    "lyra-reader-index: keeping an incompatible cache untouched ({detail}); using a full parse"
                );
            }
            CacheRead::FutureVersion { version } => {
                runtime.outcome = IndexCacheOutcome::FutureVersion;
                runtime.write_disabled = true;
                runtime.validation = started.elapsed();
                eprintln!(
                    "lyra-reader-index: cache format {version} is newer than this build (format {}); preserving it and using a full parse",
                    crate::index_cache::FORMAT_VERSION,
                );
            }
            CacheRead::Unreadable { detail } => {
                runtime.outcome = IndexCacheOutcome::Unreadable;
                runtime.write_disabled = true;
                runtime.validation = started.elapsed();
                eprintln!(
                    "lyra-reader-index: cannot read the cache ({detail}); using a full parse and preserving it"
                );
            }
        }
    }

    /// Writes the complete index once, the first time all four components are available.
    ///
    /// A partial index is never persisted: a cache without, say, its figures would make the next
    /// open return an empty figure set until the missing part was rebuilt, and a cache that can
    /// answer only half a question is exactly the silent-wrong-answer failure this task exists to
    /// prevent. If the write fails, the document keeps its in-memory index; the only cost is that
    /// the next open parses again.
    fn maybe_write_index(&self) {
        let mut runtime = match self.index.lock() {
            Ok(runtime) => runtime,
            Err(_) => return,
        };
        if self.replaced.load(std::sync::atomic::Ordering::Acquire) {
            return;
        }
        if !runtime.attempted
            || runtime.write_disabled
            || matches!(
                runtime.outcome,
                IndexCacheOutcome::Hit
                    | IndexCacheOutcome::Disabled
                    | IndexCacheOutcome::FutureVersion
                    | IndexCacheOutcome::Incompatible
                    | IndexCacheOutcome::Unreadable
            )
        {
            return;
        }
        let Some(path) = runtime.cache_path.clone() else {
            return;
        };
        let Some(identity) = runtime.identity.clone() else {
            return;
        };
        let Some(references) = self
            .references
            .lock()
            .ok()
            .and_then(|cache| cache.as_ref().cloned())
        else {
            return;
        };
        let Some(figures) = self.figures.lock().ok().and_then(|cache| cache.clone()) else {
            return;
        };
        let Some(metadata) = self.metadata.lock().ok().and_then(|cache| cache.clone()) else {
            return;
        };
        let Some(outline) = self.outline.lock().ok().and_then(|cache| cache.clone()) else {
            return;
        };
        let citations = self
            .citations
            .lock()
            .ok()
            .and_then(|cache| cache.clone())
            .unwrap_or_default();

        let file = IndexCacheFile {
            kind: crate::index_cache::KIND.to_string(),
            format_version: crate::index_cache::FORMAT_VERSION,
            engine_version: ENGINE_VERSION.to_string(),
            content: identity,
            page_count: self.backend.page_count(),
            outline,
            references: CachedReferences {
                style: references.style.clone(),
                records: references.records.clone(),
                lists: references.lists.clone(),
                document_wide: references.bibliography.document_wide as u32,
            },
            figures,
            metadata,
            citations,
        };
        let started = Instant::now();
        match write_cache(&path, &file) {
            Ok(bytes) => {
                runtime.cache_bytes = bytes;
                // Keep the historical path-only file in step. It is not read when the new key
                // exists; it is the anchor that makes a later byte change report `Stale` and
                // that a downgrade can still use. A failure to mirror is not a document failure.
                let legacy = crate::index_cache::legacy_cache_path(Path::new(&self.path));
                if legacy != path {
                    let _ = write_cache(&legacy, &file);
                }
                eprintln!(
                    "lyra-reader-index: wrote {} ({} bytes, {:.1} ms)",
                    path.display(),
                    bytes,
                    started.elapsed().as_secs_f64() * 1000.0,
                );
            }
            Err(error) => {
                runtime.write_disabled = true;
                runtime.write_error = Some(error.to_string());
                eprintln!(
                    "lyra-reader-index: cache not writable at {} ({error}); continuing with the in-memory index",
                    path.display()
                );
            }
        }
    }

    /// Records that one index component was derived from the PDF, with its elapsed time.
    fn note_derived(&self, elapsed: Duration) {
        if let Ok(mut runtime) = self.index.lock() {
            runtime.derived_parts = runtime.derived_parts.saturating_add(1);
            runtime.derived = runtime.derived.saturating_add(elapsed);
        }
    }
}

fn micros(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}

/// Largest edge length a single page texture may have.
///
/// 8192 is safe across the Metal/Vulkan/DX12 backends we target; the pixel-count clamp
/// below is usually the tighter of the two.
const MAX_PAGE_EDGE_PX: f64 = 8192.0;

/// Reduces `scale` so that the resulting bitmap stays within the engine's budget.
fn clamp_scale(page_size_pt: (f64, f64), requested: f64) -> f64 {
    let config = EngineConfig::default();
    let (width_pt, height_pt) = page_size_pt;
    if width_pt <= 0.0 || height_pt <= 0.0 {
        return requested;
    }

    let requested_pixels = width_pt * requested * height_pt * requested;
    let budget = config.full_page_max_pixels as f64;
    let mut scale = requested;

    if requested_pixels > budget {
        scale *= (budget / requested_pixels).sqrt();
    }

    let longest_edge = width_pt.max(height_pt) * scale;
    if longest_edge > MAX_PAGE_EDGE_PX {
        scale *= MAX_PAGE_EDGE_PX / longest_edge;
    }

    scale
}

/// One link: a clickable box plus where it leads.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LinkRecord {
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
    /// External URL, when the link is a URI action.
    pub uri: Option<String>,
    /// Internal target page (0-based), when the link is a local destination.
    pub page: Option<u32>,
    /// Region of the target page the citation points at, when the destination is a `/FitR`.
    pub region: Option<LinkRegion>,
}

/// A rectangle on a page, in view space (points, top-left origin).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct LinkRegion {
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// One annotation that was already inside the PDF, boxed in **view space**.
///
/// `kind` is what this reader can act on: `highlight`, `underline`, `strikeout`, `squiggly`,
/// `text` (a sticky note) and `freeText`, or — for a subtype this build does not model — the
/// PDF's own `/Subtype` name (`Ink`, `Stamp`, …), so the shell can still list it.
///
/// The rectangle and the quads are in view space (points, top-left origin), the same convention
/// as [`LinkRecord`] and [`ReferenceFragment`]; `/QuadPoints` is what markup annotations are
/// really drawn from, so prefer `quads` and fall back to `x_pt`/`y_pt`/`width_pt`/`height_pt`
/// when it is empty.
/// One `/Stamp` annotation's content, as the reader found it.
///
/// `image` is encoded bytes ready for the shell's image decoder: `image_encoding` is `png` for a
/// FlateDecode image this reader re-encoded (including this reader's own image signatures) and
/// `jpeg` for a DCTDecode image passed through from another producer. `image_error` is set when
/// the file carries an image this reader cannot decode; the stamp is then listed with the reason
/// instead of drawn as an empty box.
#[derive(Debug, Clone, uniffi::Record)]
pub struct StampRecord {
    pub text: Option<String>,
    /// `approved`, `reviewed`, `draft`, `confidential`, `date`, `signature` or `custom`.
    pub style: String,
    pub image: Vec<u8>,
    /// `png`, `jpeg`, or empty when there is no image.
    pub image_encoding: String,
    pub image_width: u32,
    pub image_height: u32,
    pub image_error: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AnnotationRecord {
    /// Page the annotation is on (0-based).
    pub page: u32,
    /// The reader-facing label for that page, from the one page formatter: `Page 4`.
    pub page_label: String,
    /// The annotation's identity: `nm:<NM>` when the file names it, otherwise a stable
    /// fingerprint (`fp:<hex>`) of its dictionary. This is what `/IRT` entries name, and it is
    /// unique among the annotations this reader reports for one document.
    pub id: String,
    /// The [`AnnotationRecord::id`] of the annotation this one replies to via `/IRT`; `None`
    /// when it is not a reply, or when `/IRT` is present but PDFium cannot resolve it.
    pub parent_id: Option<String>,
    /// Whether this annotation carries an `/IRT` entry, whether or not its parent could be read.
    ///
    /// The parent may be on another page, hidden from the page, or skipped from the reader's
    /// annotation list. Those are the shell's cases to resolve, not reasons to drop the reply.
    pub is_reply: bool,
    /// Whether the file links a `/Popup` window to this annotation.
    ///
    /// The popup is structural and is not listed separately, but its text belongs to this
    /// annotation's review thread and is deleted with it.
    pub has_popup: bool,
    /// `highlight`, `underline`, `strikeout`, `squiggly`, `text`, `freeText`, or the PDF subtype.
    pub kind: String,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
    /// `/QuadPoints`, one box per quadrilateral; empty when the file has none.
    pub quads: Vec<AnnotationQuad>,
    /// `/InkList`, one polyline per stroke, each point in view space (top-left origin).
    pub ink_paths: Vec<Vec<AnnotationPoint>>,
    /// A `/Line` annotation's endpoints in view space; `None` for every other kind.
    pub line_start: Option<AnnotationPoint>,
    pub line_end: Option<AnnotationPoint>,
    /// Whether a line annotation carries an arrowhead (`/LE`, or `/Subj (Arrow)`).
    pub line_arrow: bool,
    /// `/BS /W`, in points, when the file states one.
    pub border_width_pt: Option<f64>,
    /// `/C` as 8-bit sRGB; `None` when the file carries no colour (sticky notes usually do not).
    pub color: Option<AnnotationColorRecord>,
    /// `/CA` constant opacity in `0.0..=1.0`; `None` when the file does not state one, which
    /// means opaque.
    pub opacity: Option<f64>,
    /// The blend mode the annotation is composited with: the file's `/BM` when it states one
    /// (`normal`, `multiply`, …), otherwise the mode that kind is drawn with by every renderer.
    ///
    /// Highlights are normally stored as `multiply`, and a highlight drawn with plain alpha-over
    /// does **not** look like the same highlight in Preview — the canvas answers that with
    /// `QuadBlend::Multiply`. Most producers (Preview among them) do not put `/BM` on the
    /// annotation at all: they composite through the appearance stream's `ExtGState`, which
    /// PDFium's C API does not expose, so a markup annotation with no `/BM` is reported with the
    /// blend it is drawn with (`lyra-reader-pdfium` measures and documents that table).
    pub blend: String,
    /// `/Contents`.
    pub contents: Option<String>,
    /// `/T`.
    pub author: Option<String>,
    /// The historical display string for `/M` (`YYYY-MM-DD HH:mm`, clock as written), or the
    /// file's own string when it is not the PDF date shape. Computed by the one date parser.
    pub display_date: Option<String>,
    /// `/M`, as the file writes it (`D:YYYYMMDDHHmmSS±HH'mm'`).
    pub modified: Option<String>,
    /// The font size `/DA` states for this annotation's text, in points; `None` when the file
    /// states none, or states one no reader should draw (zero, negative, or page-sized — see
    /// `lyra-reader-pdfium::annotations`).
    ///
    /// This is what a `/FreeText` annotation's size lives in, and it is read for every kind
    /// because the key is legal on all of them. The shell draws free text at this size when it has
    /// one, and otherwise at its own default, which it reports.
    pub font_size_pt: Option<f64>,
    /// `/Q`: `left`, `center` or `right` — how a `/FreeText` annotation's text is aligned in its
    /// rectangle. Always one of the three: the PDF's own default (left) stands in when the file
    /// says nothing, so the shell never has to decide what "no alignment" means.
    pub alignment: String,
    /// The stamp's content, for a `/Stamp` annotation; `None` for every other kind. Both the
    /// stamps this reader writes and the ones another producer writes carry their words and
    /// picture here.
    pub stamp: Option<StampRecord>,
    /// What to put on the page, and the reason when the answer is "nothing": `markup` (a tinted
    /// box per quad), `noteIcon` (a `/Text` sticky note), `freeText` (a `/FreeText` annotation's
    /// own text), or `skipped`.
    ///
    /// Stated by the reader rather than re-derived by each consumer, so the dump, the checks and
    /// the canvas cannot disagree about which annotations are supposed to appear.
    pub drawing: String,
    /// Why nothing is drawn, when `drawing` is `skipped`: `hidden` (the file's `/F` says so),
    /// `empty-rect` (no box to draw in) or `unmodelled` (a subtype this build has no rule for).
    /// `None` for every drawn annotation.
    pub skip_reason: Option<String>,
    /// False when the file marks the annotation hidden/invisible/`/NoView`.
    pub visible: bool,
    /// Whether this is one of the four text-markup kinds, as the one kind table states it.
    pub is_markup: bool,
    /// Whether this is drawn from page-space geometry rather than a text quad.
    pub is_geometry: bool,
    /// Whether this is a note (`/Text` or `/FreeText`), something to read rather than markup.
    pub is_note: bool,
    /// Whether the reader can move, resize, recolour or delete this annotation.
    ///
    /// This is the whole policy the shell used to re-derive: the kind half comes from the one
    /// kind table, and the instance half (a reply, a hidden annotation, empty ink, a line with no
    /// endpoints, an unreadable stamp picture, an annotation the reader does not draw) is applied
    /// here so every surface asks one question.
    pub editable: bool,
    /// Why [`Self::editable`] is false; the reader-facing sentence.
    pub unsupported_reason: Option<String>,
}

/// What a document-wide annotation read could not decode.
///
/// The readable annotations are still returned by [`LyraReaderDocument::annotations`]. This
/// record is the explicit remainder: the shell shows a one-line notice and blocks writes that
/// would rewrite around content the engine could not see.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct AnnotationReadStatus {
    /// Total annotations that could not be read, across all pages.
    pub unreadable_annotations: u32,
    /// Pages carrying at least one unreadable annotation (0-based, document order).
    pub pages: Vec<u32>,
    /// Human-readable reason per unreadable annotation, naming the page, slot and field when
    /// the reader could diagnose it.
    pub details: Vec<String>,
}

/// The cached result of one document-wide annotation scan.
#[derive(Clone)]
struct AnnotationScanCache {
    records: Vec<AnnotationRecord>,
    status: AnnotationReadStatus,
}

/// One point of an ink stroke or a line, in view space (points, top-left origin).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct AnnotationPoint {
    pub x_pt: f64,
    pub y_pt: f64,
}

/// One quadrilateral of an annotation's `/QuadPoints`, in view space.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct AnnotationQuad {
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// An annotation colour, 8-bit sRGB.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct AnnotationColorRecord {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

/// The PDF annotation a pending write becomes.
///
/// `Note` is a sticky note (`/Subtype /Text`): its `rect` is the icon box and its contents are
/// the note. `Highlight`/`Underline`/`StrikeOut`/`Squiggly` are the quad-based text marks: their
/// `quads` are the text boxes and `contents` is the comment attached to the mark (what the
/// shell's `note` field is).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AnnotationWriteKind {
    Highlight,
    Underline,
    /// `/StrikeOut`: a line through the middle of the selected glyphs.
    StrikeOut,
    /// `/Squiggly`: a mark beside the text. The shell does not create it, but a foreign file may
    /// carry one and this writer can re-emit it with an appearance stream.
    Squiggly,
    Note,
    /// `/FreeText`: text in `rect`, at `font_size_pt`, aligned by `text_alignment`, with
    /// `/DA` and an appearance stream.
    FreeText,
    /// `/Ink`: `ink_paths` are the strokes, in view space.
    Ink,
    /// `/Square`: `rect` is the stroked rectangle.
    Square,
    /// `/Circle`: `rect` is the stroked ellipse.
    Circle,
    /// `/Line`: `line_start`/`line_end` are the endpoints; `line_arrow` adds a head.
    Line,
    /// `/Stamp`: a text stamp. `contents` is the words and `stamp_style` is one of
    /// `approved`, `reviewed`, `draft`, `confidential`, `date` or `custom`.
    Stamp,
    /// `/Stamp`: an image signature. `signature_width`, `signature_height` and
    /// `signature_rgba` are the decoded picture; `contents` must be empty.
    Signature,
}

/// One RGBA colour of the durable annotation cache (`#RRGGBBAA` in the file).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct AnnotationRecordColor {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
    pub alpha: u8,
}

/// One page-space point of a stored ink stroke or line.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct AnnotationRecordPoint {
    pub x: f64,
    pub y: f64,
}

/// One page-space rectangle of a stored shape, box or fixed quad.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct AnnotationRecordRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// One annotation as `annotations.json` stores it.
///
/// This mirrors the shell's `AppState.Annotation` field for field; `created_at` is seconds since
/// 2001-01-01 because that is the number Foundation's `JSONEncoder` writes. The codec in
/// `lyra-reader-edit` owns the file format; this record is only the boundary.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CachedAnnotationRecord {
    /// UUID text. The codec normalises it to the upper-case hyphenated shape Foundation writes.
    pub id: String,
    /// The `"kind"` value: `highlight`, `underline`, `strikeout`, `ink`, `square`, `circle`,
    /// `line`, `arrow`, `stickyNote`, `textBox`, `stamp` or `signature`.
    pub kind: String,
    pub page: i64,
    pub start: i64,
    pub end: i64,
    pub color: AnnotationRecordColor,
    pub note: String,
    /// Seconds since 2001-01-01 (Foundation's `Date` interval).
    pub created_at: f64,
    pub ink_paths: Vec<Vec<AnnotationRecordPoint>>,
    pub shape_rect: Option<AnnotationRecordRect>,
    pub line_start: Option<AnnotationRecordPoint>,
    pub line_end: Option<AnnotationRecordPoint>,
    pub stroke_width: f64,
    pub font_size: f64,
    pub file_identity: Option<String>,
    pub file_quads: Option<Vec<AnnotationRecordRect>>,
    pub text_alignment: Option<String>,
    pub stamp_style: Option<String>,
    /// The picture of an image signature, exactly the bytes the reader chose (PNG or JPEG).
    pub image_data: Option<Vec<u8>>,
}

/// One user bookmark as `annotations.json` stores it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CachedBookmarkRecord {
    pub id: String,
    pub page: i64,
    pub title: String,
    /// Page-local Y in points, 0 at the top of the page.
    pub y_pt: f64,
    /// Seconds since 2001-01-01.
    pub created_at: f64,
}

/// Where an entry came from, so a save can reproduce the file's original order.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CachedAnnotationSlot {
    Annotation {
        id: String,
    },
    Bookmark {
        id: String,
    },
    /// The verbatim JSON text of an entry this version does not understand.
    Opaque {
        raw: String,
    },
}

/// A decoded `annotations.json`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CachedAnnotationContents {
    pub annotations: Vec<CachedAnnotationRecord>,
    pub bookmarks: Vec<CachedBookmarkRecord>,
    pub slots: Vec<CachedAnnotationSlot>,
    /// How many entries were preserved verbatim because this version cannot interpret them.
    pub preserved_count: u32,
}

/// The flags every surface derives from one annotation kind.
///
/// This is the FFI projection of `lyra_reader_edit::kind`: the shell's display enum no longer
/// computes `isGeometry`/`isTextMarkup`/… itself, and the write-request mapping is a field rather
/// than a second `switch`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AnnotationKindFlagsRecord {
    /// The stable table key: the cache kind name (`highlight` … `signature`).
    pub kind: String,
    /// The `"kind"` value written to the cache, when this kind can be stored there.
    pub record_kind: Option<String>,
    /// The name the PDF reader reports (`text`, `freeText`, `arrow`, …).
    pub document_kind: String,
    /// The write request this kind becomes, when this build can write it.
    pub write_kind: Option<AnnotationWriteKind>,
    pub is_markup: bool,
    /// The shell's text-markup creation predicate (it excludes `squiggly`).
    pub is_text_markup: bool,
    pub is_geometry: bool,
    pub is_note: bool,
    pub is_placed_text: bool,
    pub is_stamp_artwork: bool,
    pub is_placement: bool,
    /// `markup`, `noteIcon`, `freeText`, `geometry`, `stamp` or `skipped`.
    pub drawing: String,
    /// The annotation-cache schema version written for this kind; `None` for text markup.
    pub schema_version: Option<u32>,
    pub in_records: bool,
    /// The kind half of the file-annotation editability policy.
    pub editable: bool,
    /// Why a `squiggly` or an unmodelled subtype cannot be edited; instance reasons are applied
    /// by [`AnnotationRecord::unsupported_reason`].
    pub unsupported_reason: Option<String>,
}

/// The limits and defaults of the durable annotation model.
///
/// The shell reads these instead of restating them, so a change to a limit or a default is one
/// Rust edit and both sides move together.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct AnnotationRulesRecord {
    pub max_annotations: u32,
    pub max_bookmarks: u32,
    pub max_id_bytes: u32,
    pub max_bookmark_title_bytes: u32,
    pub max_note_bytes: u32,
    pub max_author_bytes: u32,
    pub max_stamp_text_bytes: u32,
    pub max_quads: u32,
    pub max_ink_paths: u32,
    pub max_ink_points: u32,
    pub max_stamp_image_side: u32,
    pub max_border_width_pt: f64,
    pub min_font_size_pt: f64,
    pub max_font_size_pt: f64,
    pub min_opacity: f64,
    pub max_opacity: f64,
    /// The record schema versions the cache writes.
    pub geometry_version: u32,
    pub placed_text_version: u32,
    pub stamp_version: u32,
    pub signature_version: u32,
    /// The shell's creation defaults, in points.
    pub default_stroke_width_pt: f64,
    pub default_text_box_font_size_pt: f64,
    pub sticky_note_width_pt: f64,
    pub sticky_note_height_pt: f64,
    pub default_stamp_width_pt: f64,
    pub default_stamp_height_pt: f64,
    pub default_signature_height_pt: f64,
    pub default_picture_height_pt: f64,
    pub min_text_box_width_pt: f64,
    pub min_text_box_height_pt: f64,
}

fn annotation_rule_error(error: annotation_rules::RuleError) -> LyraReaderFfiError {
    LyraReaderFfiError::InvalidArgument {
        severity: ErrorSeverity::Document,
        message: error.message,
    }
}

fn taxonomy_write_kind(kind: TaxonomyWriteKind) -> AnnotationWriteKind {
    match kind {
        TaxonomyWriteKind::Highlight => AnnotationWriteKind::Highlight,
        TaxonomyWriteKind::Underline => AnnotationWriteKind::Underline,
        TaxonomyWriteKind::StrikeOut => AnnotationWriteKind::StrikeOut,
        TaxonomyWriteKind::Squiggly => AnnotationWriteKind::Squiggly,
        TaxonomyWriteKind::Note => AnnotationWriteKind::Note,
        TaxonomyWriteKind::FreeText => AnnotationWriteKind::FreeText,
        TaxonomyWriteKind::Ink => AnnotationWriteKind::Ink,
        TaxonomyWriteKind::Square => AnnotationWriteKind::Square,
        TaxonomyWriteKind::Circle => AnnotationWriteKind::Circle,
        TaxonomyWriteKind::Line => AnnotationWriteKind::Line,
        TaxonomyWriteKind::Stamp => AnnotationWriteKind::Stamp,
        TaxonomyWriteKind::Signature => AnnotationWriteKind::Signature,
    }
}

/// One read annotation's facts that the editability policy needs beyond its kind.
struct AnnotationEditabilityInput<'a> {
    kind: &'a str,
    is_reply: bool,
    visible: bool,
    ink_paths_empty: bool,
    line_missing: bool,
    stamp_text_empty: bool,
    stamp_has_image: bool,
    stamp_image_error: Option<&'a str>,
    drawing: AnnotationDrawing,
}

/// The whole file-annotation editability policy, in the shell's historical order and wording.
fn document_editability(input: AnnotationEditabilityInput<'_>) -> (bool, Option<String>) {
    let AnnotationEditabilityInput {
        kind,
        is_reply,
        visible,
        ink_paths_empty,
        line_missing,
        stamp_text_empty,
        stamp_has_image,
        stamp_image_error,
        drawing,
    } = input;
    if is_reply {
        return (
            false,
            Some(
                "This is a reply. Edit or delete the annotation at the top of the thread; the \
                 replies stay attached to it."
                    .to_string(),
            ),
        );
    }
    if !visible {
        return (
            false,
            Some("This annotation is hidden by the file (/F).".to_string()),
        );
    }
    let kind = TaxonomyKind::from_document_kind(kind);
    let (editable, reason) = kind.kind_editability();
    if !editable {
        return (editable, reason);
    }
    if kind == TaxonomyKind::Ink && ink_paths_empty {
        return (
            false,
            Some("This ink annotation carries no /InkList to move or draw.".to_string()),
        );
    }
    if kind == TaxonomyKind::Line && line_missing {
        return (
            false,
            Some("This line annotation carries no /L endpoints.".to_string()),
        );
    }
    if kind == TaxonomyKind::Stamp
        && !stamp_has_image
        && stamp_text_empty
        && let Some(reason) = stamp_image_error
    {
        return (
            false,
            Some(format!(
                "This stamp's picture could not be decoded ({reason}), so it can be deleted here \
                 but not moved, resized or edited."
            )),
        );
    }
    if matches!(drawing, AnnotationDrawing::Skipped(_)) {
        return (
            false,
            Some("This annotation is not drawn by the reader.".to_string()),
        );
    }
    (true, None)
}

fn kind_flags_record(kind: &TaxonomyKind) -> AnnotationKindFlagsRecord {
    let flags = kind.flags();
    let (editable, unsupported_reason) = kind.kind_editability();
    AnnotationKindFlagsRecord {
        kind: kind
            .record_name()
            .unwrap_or(kind.document_name())
            .to_string(),
        record_kind: kind.record_name().map(str::to_string),
        document_kind: kind.document_name().to_string(),
        write_kind: flags.write_kind.map(taxonomy_write_kind),
        is_markup: flags.is_markup,
        is_text_markup: flags.is_text_markup,
        is_geometry: flags.is_geometry,
        is_note: flags.is_note,
        is_placed_text: flags.is_placed_text,
        is_stamp_artwork: flags.is_stamp_artwork,
        is_placement: flags.is_placement,
        drawing: flags.drawing.as_str().to_string(),
        schema_version: flags.schema_version,
        in_records: flags.in_records,
        editable,
        unsupported_reason,
    }
}

/// The one kind table: every kind the durable model can store.
///
/// The shell builds its `Annotation.Kind` flag lookups from this once; nothing re-derives
/// `isGeometry`, `isTextMarkup` or the write-request mapping. The row order and key set are
/// `AnnotationKind::RECORD_KINDS`, so this projection cannot grow a second list of kind names.
#[uniffi::export]
pub fn annotation_kind_flags() -> Vec<AnnotationKindFlagsRecord> {
    TaxonomyKind::RECORD_KINDS
        .iter()
        .map(kind_flags_record)
        .collect()
}

/// The kind table for a PDF annotation's reported kind (`text`, `freeText`, `squiggly`, …).
#[uniffi::export]
pub fn document_annotation_kind_flags(kind: String) -> AnnotationKindFlagsRecord {
    kind_flags_record(&TaxonomyKind::from_document_kind(&kind))
}

/// The limits and defaults of the durable annotation model.
#[uniffi::export]
pub fn annotation_rules() -> AnnotationRulesRecord {
    AnnotationRulesRecord {
        max_annotations: annotation_rules::MAX_ANNOTATIONS as u32,
        max_bookmarks: annotation_rules::MAX_BOOKMARKS as u32,
        max_id_bytes: annotation_rules::MAX_ID_BYTES as u32,
        max_bookmark_title_bytes: annotation_rules::MAX_BOOKMARK_TITLE_BYTES as u32,
        max_note_bytes: annotation_rules::MAX_NOTE_BYTES as u32,
        max_author_bytes: annotation_rules::MAX_AUTHOR_BYTES as u32,
        max_stamp_text_bytes: annotation_rules::MAX_STAMP_TEXT_BYTES as u32,
        max_quads: annotation_rules::MAX_QUADS as u32,
        max_ink_paths: annotation_rules::MAX_INK_PATHS as u32,
        max_ink_points: annotation_rules::MAX_INK_POINTS as u32,
        max_stamp_image_side: annotation_rules::MAX_STAMP_IMAGE_SIDE,
        max_border_width_pt: annotation_rules::MAX_BORDER_WIDTH_PT,
        min_font_size_pt: annotation_rules::MIN_FONT_SIZE_PT,
        max_font_size_pt: annotation_rules::MAX_FONT_SIZE_PT,
        min_opacity: annotation_rules::MIN_OPACITY,
        max_opacity: annotation_rules::MAX_OPACITY,
        geometry_version: 1,
        placed_text_version: 1,
        stamp_version: 1,
        signature_version: 1,
        default_stroke_width_pt: 2.0,
        default_text_box_font_size_pt: 14.0,
        sticky_note_width_pt: 22.0,
        sticky_note_height_pt: 22.0,
        default_stamp_width_pt: 150.0,
        default_stamp_height_pt: 50.0,
        default_signature_height_pt: 64.0,
        default_picture_height_pt: 140.0,
        min_text_box_width_pt: 24.0,
        min_text_box_height_pt: 24.0,
    }
}

/// `/CA` as the reader draws it: a malformed opacity becomes the nearest legal one.
#[uniffi::export]
pub fn clamp_annotation_opacity(opacity: f64) -> f64 {
    annotation_rules::clamp_opacity(opacity)
}

#[uniffi::export]
pub fn clamp_annotation_border_width(width: f64) -> f64 {
    annotation_rules::clamp_border_width(width)
}

#[uniffi::export]
pub fn clamp_annotation_font_size(size: f64) -> f64 {
    annotation_rules::clamp_font_size(size)
}

fn edit_color(color: AnnotationRecordColor) -> annotation_records::PaletteColor {
    annotation_records::PaletteColor::new(color.red, color.green, color.blue, color.alpha)
}

fn cached_color(color: annotation_records::PaletteColor) -> AnnotationRecordColor {
    AnnotationRecordColor {
        red: color.red,
        green: color.green,
        blue: color.blue,
        alpha: color.alpha,
    }
}

fn edit_point(point: AnnotationRecordPoint) -> annotation_records::StoredPoint {
    annotation_records::StoredPoint::new(point.x, point.y)
}

fn cached_point(point: annotation_records::StoredPoint) -> AnnotationRecordPoint {
    AnnotationRecordPoint {
        x: point.x,
        y: point.y,
    }
}

fn edit_rect(rect: AnnotationRecordRect) -> annotation_records::StoredRect {
    annotation_records::StoredRect::new(rect.x, rect.y, rect.width, rect.height)
}

fn cached_rect(rect: annotation_records::StoredRect) -> AnnotationRecordRect {
    AnnotationRecordRect {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height,
    }
}

fn edit_annotation(
    record: CachedAnnotationRecord,
) -> Result<annotation_records::RecordAnnotation, LyraReaderFfiError> {
    let kind = TaxonomyKind::from_record_kind(&record.kind).ok_or_else(|| {
        LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: format!("unknown annotation-cache kind {:?}", record.kind),
        }
    })?;
    Ok(annotation_records::RecordAnnotation {
        id: record.id,
        kind,
        page: record.page,
        start: record.start,
        end: record.end,
        color: edit_color(record.color),
        note: record.note,
        created_at: record.created_at,
        ink_paths: record
            .ink_paths
            .into_iter()
            .map(|path| path.into_iter().map(edit_point).collect())
            .collect(),
        shape_rect: record.shape_rect.map(edit_rect),
        line_start: record.line_start.map(edit_point),
        line_end: record.line_end.map(edit_point),
        stroke_width: record.stroke_width,
        font_size: record.font_size,
        file_identity: record.file_identity,
        file_quads: record
            .file_quads
            .map(|quads| quads.into_iter().map(edit_rect).collect()),
        text_alignment: record.text_alignment,
        stamp_style: record.stamp_style,
        image_data: record.image_data,
    })
}

fn cached_annotation(record: &annotation_records::RecordAnnotation) -> CachedAnnotationRecord {
    CachedAnnotationRecord {
        id: record.id.clone(),
        kind: record.kind.record_name().unwrap_or("highlight").to_string(),
        page: record.page,
        start: record.start,
        end: record.end,
        color: cached_color(record.color),
        note: record.note.clone(),
        created_at: record.created_at,
        ink_paths: record
            .ink_paths
            .iter()
            .map(|path| path.iter().copied().map(cached_point).collect())
            .collect(),
        shape_rect: record.shape_rect.map(cached_rect),
        line_start: record.line_start.map(cached_point),
        line_end: record.line_end.map(cached_point),
        stroke_width: record.stroke_width,
        font_size: record.font_size,
        file_identity: record.file_identity.clone(),
        file_quads: record
            .file_quads
            .as_ref()
            .map(|quads| quads.iter().copied().map(cached_rect).collect()),
        text_alignment: record.text_alignment.clone(),
        stamp_style: record.stamp_style.clone(),
        image_data: record.image_data.clone(),
    }
}

fn edit_bookmark(record: CachedBookmarkRecord) -> annotation_records::RecordBookmark {
    annotation_records::RecordBookmark {
        id: record.id,
        page: record.page,
        title: record.title,
        y_pt: record.y_pt,
        created_at: record.created_at,
    }
}

fn cached_bookmark(record: &annotation_records::RecordBookmark) -> CachedBookmarkRecord {
    CachedBookmarkRecord {
        id: record.id.clone(),
        page: record.page,
        title: record.title.clone(),
        y_pt: record.y_pt,
        created_at: record.created_at,
    }
}

fn edit_slot(slot: CachedAnnotationSlot) -> annotation_records::Slot {
    match slot {
        CachedAnnotationSlot::Annotation { id } => annotation_records::Slot::Annotation(id),
        CachedAnnotationSlot::Bookmark { id } => annotation_records::Slot::Bookmark(id),
        CachedAnnotationSlot::Opaque { raw } => annotation_records::Slot::Opaque(raw),
    }
}

fn cached_slot(slot: &annotation_records::Slot) -> CachedAnnotationSlot {
    match slot {
        annotation_records::Slot::Annotation(id) => {
            CachedAnnotationSlot::Annotation { id: id.clone() }
        }
        annotation_records::Slot::Bookmark(id) => CachedAnnotationSlot::Bookmark { id: id.clone() },
        annotation_records::Slot::Opaque(raw) => CachedAnnotationSlot::Opaque { raw: raw.clone() },
    }
}

/// Decodes `annotations.json` through the one Rust codec.
///
/// `page_count` is the open document's page count; `palette` is the shell's legacy highlight
/// palette in order, which is how an older entry's `colorIndex` becomes a colour. The returned
/// slots are the file's entry order, with foreign entries carrying their exact source text.
#[uniffi::export]
pub fn decode_annotation_cache(
    data: Vec<u8>,
    page_count: u32,
    palette: Vec<AnnotationRecordColor>,
) -> Result<CachedAnnotationContents, LyraReaderFfiError> {
    let palette: Vec<_> = palette.into_iter().map(edit_color).collect();
    let contents =
        annotation_records::decode(&data, page_count as usize, &palette).map_err(|error| {
            LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: error.detail,
            }
        })?;
    Ok(CachedAnnotationContents {
        annotations: contents.annotations.iter().map(cached_annotation).collect(),
        bookmarks: contents.bookmarks.iter().map(cached_bookmark).collect(),
        slots: contents.slots.iter().map(cached_slot).collect(),
        preserved_count: contents.preserved_count() as u32,
    })
}

/// Encodes `annotations.json` through the one Rust codec.
///
/// The output is byte-for-byte what the Swift encoder wrote before this moved: same key order,
/// same two-space pretty printing, same `Date`/`UUID`/base64 shapes, and foreign entries spliced
/// back exactly as they were read.
#[uniffi::export]
pub fn encode_annotation_cache(
    annotations: Vec<CachedAnnotationRecord>,
    bookmarks: Vec<CachedBookmarkRecord>,
    slots: Vec<CachedAnnotationSlot>,
    palette: Vec<AnnotationRecordColor>,
) -> Result<Vec<u8>, LyraReaderFfiError> {
    let annotations: Vec<_> = annotations
        .into_iter()
        .map(edit_annotation)
        .collect::<Result<_, _>>()?;
    let bookmarks: Vec<_> = bookmarks.into_iter().map(edit_bookmark).collect();
    let slots: Vec<_> = slots.into_iter().map(edit_slot).collect();
    let palette: Vec<_> = palette.into_iter().map(edit_color).collect();
    annotation_records::encode(&annotations, &bookmarks, &slots, &palette).map_err(|error| {
        LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: error.detail,
        }
    })
}

/// The creation-time validation of one cached annotation.
///
/// The shell calls this before it appends a new entry, so the limits that used to be discovered
/// only when saving into the PDF are refused at creation with the same sentence. `existing_ids`
/// are the annotations already in the cache (uniqueness is checked across them).
#[uniffi::export]
pub fn validate_cached_annotation(
    annotation: CachedAnnotationRecord,
    page_count: u32,
    existing_ids: Vec<String>,
) -> Result<(), LyraReaderFfiError> {
    let annotation = edit_annotation(annotation)?;
    annotation_rules::validate_annotation(&annotation, page_count as usize, &existing_ids).map_err(
        |error| LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: error.message,
        },
    )
}

/// The creation-time validation of one cached bookmark, with the outline writer's rules.
#[uniffi::export]
pub fn validate_cached_bookmark(
    bookmark: CachedBookmarkRecord,
    page_count: u32,
    existing_ids: Vec<String>,
) -> Result<(), LyraReaderFfiError> {
    let bookmark = edit_bookmark(bookmark);
    annotation_rules::validate_bookmark(&bookmark, page_count as usize, &existing_ids).map_err(
        |error| LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: error.message,
        },
    )
}

/// One bookmark the shell asks the writer to put into the document's `/Outlines`.
///
/// `y_pt` is page-local view space (0 at the page top), the same value the annotation cache stores, so a
/// bookmark survives a zoom change, a resize and a layout switch.
#[derive(Debug, Clone, uniffi::Record)]
pub struct WriteBookmarkRecord {
    /// The cached bookmark's UUID string, written as the private `/LyraReaderID` key so a
    /// reopened document can adopt the file's bookmarks with their identities intact.
    pub id: String,
    pub page: u32,
    pub title: String,
    pub y_pt: f64,
}

/// One annotation the shell asks the writer to put into a PDF.
///
/// Geometry is **view space at `zoom`** (points, top-left origin), exactly the space the canvas
/// draws in. The Rust side owns the single conversion into page space, so a highlight saved at
/// 100% and the same highlight saved at 300% produce identical PDF coordinates.
#[derive(Debug, Clone, uniffi::Record)]
pub struct WriteAnnotationRecord {
    /// Stable identity written as `/NM`; the shell uses the cached annotation's UUID string so a saved
    /// annotation can be recognised after reopening.
    pub id: String,
    pub page: u32,
    pub kind: AnnotationWriteKind,
    /// View-space box at `zoom`. For a note this is its icon; for markup the union of `quads`
    /// is used and this box is validated for consistency.
    pub rect: AnnotationQuad,
    /// View-space `/QuadPoints` at `zoom`; empty for notes and for the stroked kinds.
    pub quads: Vec<AnnotationQuad>,
    /// View-space `/InkList` at `zoom`, one stroke per entry; only for [`AnnotationWriteKind::Ink`].
    pub ink_paths: Vec<Vec<AnnotationPoint>>,
    /// View-space `/L` endpoints at `zoom`; required for [`AnnotationWriteKind::Line`].
    pub line_start: Option<AnnotationPoint>,
    pub line_end: Option<AnnotationPoint>,
    /// Write `/LE [/None /ClosedArrow]`; only meaningful for a line.
    pub line_arrow: bool,
    /// `/BS /W` in points, for the stroked kinds.
    pub border_width_pt: f64,
    pub color: AnnotationColorRecord,
    /// `/CA`; the shell's colour alpha carries it (0…1).
    pub opacity: f64,
    /// `/Contents` — the highlight comment or the note body.
    pub contents: String,
    /// `/T`.
    pub author: String,
    /// `/M`, PDF date format (`D:YYYYMMDDHHmmSSOHH'mm'`).
    pub modified: String,
    /// `/DA` font size, in points. Used by [`AnnotationWriteKind::FreeText`]; ignored for every
    /// other kind.
    pub font_size_pt: f64,
    /// `/Q` text alignment for [`AnnotationWriteKind::FreeText`]: `left`, `center` or `right`.
    /// Any other value is refused rather than silently becoming left.
    pub text_alignment: String,
    /// The stamp's style, for [`AnnotationWriteKind::Stamp`]: `approved`, `reviewed`, `draft`,
    /// `confidential`, `date` or `custom`. Ignored for every other kind.
    pub stamp_style: String,
    /// The image signature's width in pixels, for [`AnnotationWriteKind::Signature`].
    pub signature_width: u32,
    /// The image signature's height in pixels.
    pub signature_height: u32,
    /// Straight (non-premultiplied) RGBA, `width × height × 4` bytes, top row first.
    pub signature_rgba: Vec<u8>,
}

/// One annotation the shell asks the writer to **edit** in place.
///
/// `target` is the identity [`AnnotationRecord::id`] reported for the file's annotation
/// (`nm:<NM>` or `fp:<fingerprint>`). `annotation` is the full replacement model; the writer keeps
/// the file's `/NM` (unless `assign_name` fills in a missing one), author, flags, popup, parent,
/// reply links and every key this reader does not model.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AnnotationUpdateRecord {
    pub target: String,
    pub annotation: WriteAnnotationRecord,
    /// `/NM` to assign when the file's annotation has none. Required for an `fp:` target: the
    /// fingerprint is derived from `/Contents` and `/M`, which this edit changes.
    pub assign_name: Option<String>,
}

/// One annotation the shell asks the writer to remove, with its reply thread and popup.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AnnotationDeleteRecord {
    pub target: String,
    /// Page the annotation is on, for a clearer refusal when it has moved. The writer resolves
    /// the identity across the document because replies live on their own pages.
    pub page: u32,
}

/// What a successful write did. Every value is about the *file that was written*, not about the
/// request: `written_ids` comes back so the shell removes exactly those cached entries.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AnnotationSaveReport {
    pub destination_path: String,
    pub written_ids: Vec<String>,
    /// Bytes appended to the original (the original prefix is kept byte-for-byte), or 0 for a
    /// pruned full rewrite (see [`Self::full_rewrite`]).
    pub appended_bytes: u64,
    /// Present only when the original was replaced; the file is verified byte-identical.
    pub backup_path: Option<String>,
    /// Content annotations the source already had; every one the save did not edit or delete
    /// was verified unchanged.
    pub preexisting_annotation_count: u32,
    /// Bookmark identities written into the outline, so the shell removes exactly those cached
    /// entries after a replacement.
    pub written_bookmark_ids: Vec<String>,
    /// Title of the rewritten bookmark subtree; `None` when the bookmark list was empty.
    pub bookmark_outline_title: Option<String>,
    /// Outline nodes the document already had outside the reader's subtree; all were verified
    /// unchanged.
    pub preexisting_outline_entry_count: u32,
    /// Identities of every annotation removed from the annotation tree, including the `/IRT`
    /// replies and `/Popup` window that depended on it. Empty for an append-only save.
    pub deleted_file_ids: Vec<String>,
    /// Replies among [`Self::deleted_file_ids`].
    pub deleted_reply_count: u32,
    /// Popup windows among [`Self::deleted_file_ids`].
    pub deleted_popup_count: u32,
    /// Identities given an `/NM` because the file had none and the edit needed a stable one.
    pub assigned_names: Vec<String>,
    /// Stale `.lyra-reader-save-*.tmp` files removed before this save.
    pub cleaned_temporary_files: u32,
    /// True when the written file's prefix equals the source byte-for-byte. False when the save
    /// pruned the file (see [`Self::full_rewrite`]).
    pub source_bytes_preserved: bool,
    /// True when the output is a fresh, pruned document: a deletion was requested, so the
    /// removed annotation objects and every other unreachable byte are gone from the file.
    pub full_rewrite: bool,
}

/// A rectangle in PDF user space (origin at the page's bottom-left corner).
///
/// Content command bounds arrive in the shell's top-left view space; [`prepare_content_command`]
/// converts them with the open page's own geometry before the engine sees them. `crop` is the
/// exception: it is a normalized fraction of the image and is already independent of page space.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct ContentBoxRecord {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl From<ContentBoxRecord> for lyra_reader_pdfium::content_edit::ContentBox {
    fn from(value: ContentBoxRecord) -> Self {
        Self {
            x: value.x,
            y: value.y,
            width: value.width,
            height: value.height,
        }
    }
}

/// The shell's request to edit page content.
///
/// This is a typed, field-for-field mirror of [`lyra_reader_pdfium::content_edit::ContentCommand`].
/// Every variant carries the source revision it was built against; the engine refuses a command
/// whose revision does not match the page it inspected. `colour` is RGBA with four components,
/// validated by [`content_command`] because UniFFI has no fixed-length array type. `alignment`
/// stays the engine's integer form (0 left, 1 centre, 2 right), validated by the layout writer.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum ContentCommandRecord {
    Transform {
        revision: String,
        target: String,
        bounds: ContentBoxRecord,
        /// Clockwise degrees in the shell's Y-down view space; the FFI negates it for PDF Y-up.
        rotation: f64,
    },
    ReplaceText {
        revision: String,
        target: String,
        text: String,
        bounds: ContentBoxRecord,
        font: String,
        size: f64,
        colour: Vec<u8>,
        alignment: u8,
    },
    InsertText {
        revision: String,
        text: String,
        bounds: ContentBoxRecord,
        font: String,
        size: f64,
        colour: Vec<u8>,
        alignment: u8,
    },
    Delete {
        revision: String,
        target: String,
    },
    Redact {
        revision: String,
        bounds: ContentBoxRecord,
        blackout: bool,
    },
    InsertImage {
        revision: String,
        bounds: ContentBoxRecord,
        image_path: String,
    },
    ReplaceImage {
        revision: String,
        target: String,
        image_path: String,
    },
    CropImage {
        revision: String,
        target: String,
        crop: ContentBoxRecord,
    },
    SetLink {
        revision: String,
        target: Option<String>,
        bounds: ContentBoxRecord,
        page: Option<u32>,
        uri: Option<String>,
    },
}

/// Converts the typed shell request into the engine command.
///
/// The only structural check left is the colour length; everything else (revision, geometry,
/// text style, target identity) is validated by the engine with the same sentences as before.
fn content_command(
    record: ContentCommandRecord,
) -> Result<lyra_reader_pdfium::content_edit::ContentCommand, LyraReaderFfiError> {
    use lyra_reader_pdfium::content_edit::ContentCommand;
    fn colour(value: Vec<u8>) -> Result<[u8; 4], LyraReaderFfiError> {
        value
            .try_into()
            .map_err(|value: Vec<u8>| LyraReaderFfiError::InvalidArgument {
                severity: ErrorSeverity::Document,
                message: format!(
                    "The text colour must have exactly four components (red, green, blue, alpha); got {}.",
                    value.len()
                ),
            })
    }
    Ok(match record {
        ContentCommandRecord::Transform {
            revision,
            target,
            bounds,
            rotation,
        } => ContentCommand::Transform {
            revision,
            target,
            bounds: bounds.into(),
            rotation,
        },
        ContentCommandRecord::ReplaceText {
            revision,
            target,
            text,
            bounds,
            font,
            size,
            colour: value,
            alignment,
        } => ContentCommand::ReplaceText {
            revision,
            target,
            text,
            bounds: bounds.into(),
            font,
            size,
            colour: colour(value)?,
            alignment,
        },
        ContentCommandRecord::InsertText {
            revision,
            text,
            bounds,
            font,
            size,
            colour: value,
            alignment,
        } => ContentCommand::InsertText {
            revision,
            text,
            bounds: bounds.into(),
            font,
            size,
            colour: colour(value)?,
            alignment,
        },
        ContentCommandRecord::Delete { revision, target } => {
            ContentCommand::Delete { revision, target }
        }
        ContentCommandRecord::Redact {
            revision,
            bounds,
            blackout,
        } => ContentCommand::Redact {
            revision,
            bounds: bounds.into(),
            blackout,
        },
        ContentCommandRecord::InsertImage {
            revision,
            bounds,
            image_path,
        } => ContentCommand::InsertImage {
            revision,
            bounds: bounds.into(),
            image_path,
        },
        ContentCommandRecord::ReplaceImage {
            revision,
            target,
            image_path,
        } => ContentCommand::ReplaceImage {
            revision,
            target,
            image_path,
        },
        ContentCommandRecord::CropImage {
            revision,
            target,
            crop,
        } => ContentCommand::CropImage {
            revision,
            target,
            crop: crop.into(),
        },
        ContentCommandRecord::SetLink {
            revision,
            target,
            bounds,
            page,
            uri,
        } => ContentCommand::SetLink {
            revision,
            target,
            bounds: bounds.into(),
            page,
            uri,
        },
    })
}

/// A destructive-ish page operation requested by the shell.
///
/// Every variant operates on a copy; the source path is this document's file. Page numbers are
/// 0-based. `Move.destination` is the index in the list **after** the moved pages are removed,
/// which is what PDFium's `FPDF_MovePages` expects; for a single page, moving it up is
/// `destination = page - 1` and moving it down is `destination = page` on a document with at
/// least one page after it.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum PageOperationRecord {
    Rotate {
        pages: Vec<u32>,
        quarter_turns: i32,
    },
    SetRotation {
        pages: Vec<u32>,
        quarter_turns: Vec<u32>,
    },
    Delete {
        pages: Vec<u32>,
    },
    Move {
        pages: Vec<u32>,
        destination: u32,
    },
    InsertBlank {
        index: u32,
    },
}

/// The result of a page operation or of publishing a page-edit revision.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PageEditReport {
    /// The file that was written.
    pub destination_path: String,
    pub page_count: u32,
    /// `page_map[old] = Some(new)` for surviving pages, `None` for removed/not-extracted ones.
    pub page_map: Vec<Option<u32>>,
    /// `/Rotate` of every written page, in quarter turns.
    pub rotations: Vec<u32>,
    /// The inserted blank page's index, when the operation inserted one.
    pub inserted_page: Option<u32>,
    /// The verified backup, only when the original was replaced.
    pub backup_path: Option<String>,
    pub output_bytes: u64,
    /// Stale `.lyra-reader-save-*.tmp` files removed before writing.
    pub cleaned_temporary_files: u32,
}

/// One output of a split, as the shell requested it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SplitPartRecord {
    /// Where this part should be written.
    pub destination_path: String,
    /// 0-based pages from the open document. Sorted ascending by the engine; duplicates refused.
    pub pages: Vec<u32>,
}

/// What a split wrote for one part.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SplitOutputRecord {
    pub destination_path: String,
    pub page_count: u32,
    /// The source pages this output carries, in output order (0-based).
    pub source_pages: Vec<u32>,
    pub rotations: Vec<u32>,
    pub output_bytes: u64,
}

/// What a split wrote.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SplitReportRecord {
    pub parts: Vec<SplitOutputRecord>,
    pub source_page_count: u32,
    pub cleaned_temporary_files: u32,
}

/// What a merge wrote.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MergeReportRecord {
    pub destination_path: String,
    /// Sum of every input's page count.
    pub page_count: u32,
    pub first_page_count: u32,
    /// Pages each appended document contributed, in the order requested.
    pub appended_page_counts: Vec<u32>,
    /// File-owned content annotations on the appended pages, per appended document.
    pub appended_annotation_counts: Vec<u32>,
    pub rotations: Vec<u32>,
    /// Flattened outline entries kept from the first document.
    pub first_outline_entries: u32,
    /// Flattened entries imported from the appended documents (group labels are not counted).
    pub appended_outline_entries: u32,
    /// Titles of the top-level groups added for appended documents, in request order.
    pub appended_outline_group_titles: Vec<String>,
    pub output_bytes: u64,
    pub cleaned_temporary_files: u32,
}

/// One outline entry.
#[derive(Debug, Clone, PartialEq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OutlineEntry {
    pub title: String,
    /// Target page (0-based), when the destination resolves to one.
    pub page: Option<u32>,
    /// Nesting level; 0 is a top-level entry.
    pub depth: u32,
    /// The cached bookmark's UUID when this entry belongs to the reader's own saved subtree.
    /// `None` for every node the document's author wrote.
    pub bookmark_id: Option<String>,
    /// Page-local Y (points, 0 at the page top) when the destination names a position. This is
    /// what lets a click land on the bookmarked paragraph, not merely on the page.
    pub y_pt: Option<f64>,
    /// True for the top-level `My bookmarks` node the reader wrote. Its children carry
    /// `bookmark_id`; a document author's node with a similar title is not this.
    pub is_bookmark_subtree: bool,
}

/// Flattens an outline tree into sidebar rows.
fn flatten_outline(
    nodes: &[lyra_reader_core::OutlineNode],
    depth: u32,
    out: &mut Vec<OutlineEntry>,
) {
    for node in nodes {
        out.push(OutlineEntry {
            title: node.title.clone(),
            page: node.page.map(|page| page.get()),
            depth,
            bookmark_id: None,
            y_pt: None,
            is_bookmark_subtree: false,
        });
        flatten_outline(&node.children, depth + 1, out);
    }
}

/// Attaches the reader's own bookmark identities to the flattened outline.
///
/// The PDFium outline supplies the tree; the marked subtree supplies `/LyraReaderID` and the
/// page-local Y that PDFium's bookmark API does not expose. The subtree is located by its
/// top-level title and its child count/titles, which the writer made unique among top-level
/// nodes. A foreign node with the same title is not ours and does not match both conditions.
fn merge_embedded_bookmarks(entries: &mut [OutlineEntry], embedded: &EmbeddedBookmarks) {
    let mut matched: Option<(usize, Vec<usize>)> = None;
    for (index, entry) in entries.iter().enumerate() {
        if entry.depth != 0 || entry.title != embedded.title {
            continue;
        }
        let children: Vec<usize> = entries
            .iter()
            .enumerate()
            .skip(index + 1)
            .take_while(|(_, entry)| entry.depth > 0)
            .map(|(index, _)| index)
            .collect();
        if children.len() != embedded.bookmarks.len() {
            continue;
        }
        let titles_match = children
            .iter()
            .zip(&embedded.bookmarks)
            .all(|(index, bookmark)| {
                entries[*index].title == bookmark.title && entries[*index].page == bookmark.page
            });
        if titles_match {
            matched = Some((index, children));
            break;
        }
    }
    let Some((root, children)) = matched else {
        return;
    };
    entries[root].is_bookmark_subtree = true;
    for (index, bookmark) in children.into_iter().zip(&embedded.bookmarks) {
        entries[index].bookmark_id = (!bookmark.id.is_empty()).then(|| bookmark.id.clone());
        entries[index].y_pt = bookmark.y_pt;
    }
}

/// A citation in the body text, boxed in **view space**.

#[derive(Debug, Clone, PartialEq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CitationRecord {
    pub page: u32,
    /// As it appears, e.g. `[12,13]` or `He et al. 2024`.
    pub text: String,
    /// Reference labels it names (`12`, `13`, …), or the year for author-year styles.
    pub labels: Vec<String>,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// One entry of the reference list, with the box it occupies on its page.
///
/// `x_pt`/`y_pt`/`width_pt`/`height_pt` are the entry's box **on `page`**, which is what the
/// preview has always drawn: for an entry that fits in one column that box is unchanged, and for
/// one that is split it is the union of the pieces on `page` (see `fragments`). The pieces
/// themselves are in `fragments`; an entry spanning two pages has one there per page, and the
/// single box here can only ever describe `page`.
#[derive(Debug, Clone, PartialEq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReferenceRecord {
    pub label: String,
    pub text: String,
    /// Page the entry starts on (0-based).
    pub page: u32,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
    /// The pieces the entry is drawn in, in reading order, in **view space**.
    ///
    /// One element for the common case — one column, one page — where it equals the box above.
    /// Two or more when the entry crosses a column gutter or continues on the next page; a
    /// preview that draws a rectangle per fragment never spans a gutter. Empty when the page's
    /// text layer offered no boxes at all, in which case the box above is the only geometry.
    pub fragments: Vec<ReferenceFragment>,
}

/// One piece of a reference entry: the page to draw on and the box to show, in **view space**.
#[derive(Debug, Clone, PartialEq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReferenceFragment {
    /// Page the fragment is drawn on (0-based).
    pub page: u32,
    /// Box in view space (points, top-left origin), ready for `rasterize_region`.
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// A figure or table caption, with the region of its page a floating preview should show.
#[derive(Debug, Clone, PartialEq, uniffi::Record, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FigureRecord {
    /// `Figure`, `Table`, or `Algorithm`.
    pub kind: String,
    /// The number as printed: `3`, `12`.
    pub label: String,
    /// Page the caption lives on (0-based); the region is on that same page.
    pub page: u32,
    /// Caption text after the label, for the preview's title bar.
    pub caption_text: String,
    /// Region to preview, in **view space** (points, top-left origin).
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// A `Figure N` / `Fig. N` / `Table N` / `Algorithm N` reference in the body text, boxed in **view space**.
///
/// `kind` + `label` resolve against [`FigureRecord`]s; `start`/`end` address the page's text
/// layer, the same range [`CitationRecord`] uses for a citation.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CaptionMentionRecord {
    pub page: u32,
    pub kind: String,
    pub label: String,
    /// First character of the mention inside its page's text layer.
    pub start: u32,
    /// One past the last character of the mention.
    pub end: u32,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// One search hit: a character range in a page's text layer.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SearchHit {
    pub page: u32,
    /// First matching character index.
    pub start: u32,
    /// One past the last matching character.
    pub end: u32,
    /// Surrounding text, for the results list.
    pub snippet: String,
}

/// Union of a run of character boxes (page space), or `None` when the run is empty.
fn union_of_char_boxes(chars: &[lyra_reader_core::RawCharBox]) -> Option<lyra_reader_core::Rect> {
    chars
        .iter()
        .fold(None::<lyra_reader_core::Rect>, |accumulated, character| {
            let rect = character.rect;
            Some(match accumulated {
                None => rect,
                Some(current) => {
                    let min_x = current.origin.x.min(rect.origin.x);
                    let min_y = current.origin.y.min(rect.origin.y);
                    let max_x = (current.origin.x + current.size.width)
                        .max(rect.origin.x + rect.size.width);
                    let max_y = (current.origin.y + current.size.height)
                        .max(rect.origin.y + rect.size.height);
                    lyra_reader_core::Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
                }
            })
        })
}

/// Converts a page-space rectangle to its view-space bounding rectangle, including page rotation.
fn page_region_to_view(
    region: lyra_reader_core::Rect,
    geometry: lyra_reader_core::PageGeometry,
) -> lyra_reader_core::Rect {
    geometry.page_to_view(1.0).apply_rect(region)
}

/// One view-space box at `zoom`, converted into page space.
///
/// The inverse of [`page_region_to_view`]'s transform, with the zoom the canvas is drawing at.
/// The returned rectangle is axis-aligned in page space: `/Rotate` is a multiple of 90° in PDF,
/// so a view rectangle maps to another axis-aligned rectangle (the canvas only ever produces
/// horizontal text boxes anyway). Bounds are checked against `/CropBox` with one point of slack
/// so a hairline round-off at the page edge is not turned into a refusal.
fn view_box_to_page_rect(
    view: &AnnotationQuad,
    inverse: Transform2D,
    geometry: &PageGeometry,
) -> Result<lyra_reader_core::Rect, LyraReaderFfiError> {
    let values = [view.x_pt, view.y_pt, view.width_pt, view.height_pt];
    if !values.iter().all(|value| value.is_finite())
        || view.width_pt <= 0.0
        || view.height_pt <= 0.0
    {
        return Err(LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: format!(
                "a view-space box has no area or is not finite: {:?}",
                values
            ),
        });
    }
    let top_left = inverse.apply(Point::new(view.x_pt, view.y_pt));
    let bottom_right = inverse.apply(Point::new(
        view.x_pt + view.width_pt,
        view.y_pt + view.height_pt,
    ));
    let rect = lyra_reader_core::Rect::new(
        top_left.x.min(bottom_right.x),
        top_left.y.min(bottom_right.y),
        (top_left.x - bottom_right.x).abs(),
        (top_left.y - bottom_right.y).abs(),
    );
    if !rect.origin.x.is_finite()
        || !rect.origin.y.is_finite()
        || !rect.size.width.is_finite()
        || !rect.size.height.is_finite()
        || rect.size.width <= 0.0
        || rect.size.height <= 0.0
    {
        return Err(LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: "a view-space box converted to an empty page-space box".to_string(),
        });
    }
    let crop = geometry.crop_box;
    const SLACK: f64 = 1.0;
    if rect.min_x() < crop.min_x() - SLACK
        || rect.min_y() < crop.min_y() - SLACK
        || rect.max_x() > crop.max_x() + SLACK
        || rect.max_y() > crop.max_y() + SLACK
    {
        return Err(LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: format!("annotation box {rect:?} falls outside the page's crop box {crop:?}"),
        });
    }
    Ok(rect)
}

/// An empty optional string means "the file should not carry this key".
fn text_or_none(text: &str) -> Option<String> {
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

/// Whether two page-space rectangles agree to within half a point.
fn rects_close(left: lyra_reader_core::Rect, right: lyra_reader_core::Rect) -> bool {
    (left.min_x() - right.min_x()).abs() <= 0.5
        && (left.min_y() - right.min_y()).abs() <= 0.5
        && (left.max_x() - right.max_x()).abs() <= 0.5
        && (left.max_y() - right.max_y()).abs() <= 0.5
}

/// The view transform of `page`, remembered in `cache` for the rest of the scan.
fn document_page_view(
    backend: &PdfiumBackend,
    cache: &mut std::collections::HashMap<u32, lyra_reader_core::Transform2D>,
    page: u32,
) -> Option<lyra_reader_core::Transform2D> {
    if let Some(transform) = cache.get(&page) {
        return Some(*transform);
    }
    let transform = backend
        .page_info(PageIndex(page))
        .ok()?
        .geometry
        .page_to_view(1.0);
    cache.insert(page, transform);
    Some(transform)
}

/// Citation spans in one page's text layer, converted to the view space the canvas draws in.
///
/// One function for the per-page path and the document scan, so a cached span can never differ
/// from the span a fresh `citations(page)` call would produce.
fn citation_records(
    raw: &lyra_reader_core::RawTextPage,
    style: &lyra_reader_text::CitationStyle,
    page: u32,
    transform: lyra_reader_core::Transform2D,
) -> Vec<CitationRecord> {
    lyra_reader_text::find_citations_with(raw, style)
        .into_iter()
        .map(|citation| {
            let top_left = Point::new(
                citation.rect.origin.x,
                citation.rect.origin.y + citation.rect.size.height,
            );
            let view = transform.apply(top_left);
            CitationRecord {
                page,
                text: citation.text,
                labels: citation.labels,
                x_pt: view.x,
                y_pt: view.y,
                width_pt: citation.rect.size.width,
                height_pt: citation.rect.size.height,
            }
        })
        .collect()
}

/// The preview records for one reference list, in view space.
///
/// The single rectangle stays the box on the entry's own page. For one fragment that is the
/// fragment's own box, unchanged; when the entry is split, it is the union of the pieces that
/// page carries. A continuation on another page cannot be part of a box here: the record names
/// one page, and the preview rasterizes that page.
fn reference_records(
    backend: &PdfiumBackend,
    transforms: &mut std::collections::HashMap<u32, lyra_reader_core::Transform2D>,
    entries: &[lyra_reader_text::ReferenceEntry],
) -> Vec<ReferenceRecord> {
    let mut records = Vec::with_capacity(entries.len());
    for entry in entries {
        // The entry's box comes from the character boxes of its own range, so the preview can
        // show exactly the entry rather than a whole page.
        let Ok(text) = backend.raw_text_page(PageIndex(entry.page)) else {
            continue;
        };
        if document_page_view(backend, transforms, entry.page).is_none() {
            continue;
        }
        let on_page = entry
            .fragments
            .iter()
            .filter(|fragment| fragment.page == entry.page)
            .map(|fragment| fragment.rect)
            .reduce(lyra_reader_core::Rect::union);
        let rect = match on_page {
            Some(rect) => rect,
            // No fragment geometry (the text layer offered no boxes): fall back to the
            // character boxes of the entry's own range, as this used to read.
            None => {
                let slice =
                    &text.chars[entry.start.min(text.chars.len())..entry.end.min(text.chars.len())];
                let Some(rect) = union_of_char_boxes(slice) else {
                    continue;
                };
                rect
            }
        };
        let Some(view) = view_box(backend, transforms, entry.page, rect) else {
            continue;
        };

        let mut fragments = Vec::with_capacity(entry.fragments.len());
        for fragment in &entry.fragments {
            let Some(view) = view_box(backend, transforms, fragment.page, fragment.rect) else {
                continue;
            };
            fragments.push(ReferenceFragment {
                page: fragment.page,
                x_pt: view.x,
                y_pt: view.y,
                width_pt: fragment.rect.size.width,
                height_pt: fragment.rect.size.height,
            });
        }

        records.push(ReferenceRecord {
            label: entry.label.clone(),
            text: entry.text.clone(),
            page: entry.page,
            x_pt: view.x,
            y_pt: view.y,
            width_pt: rect.size.width,
            height_pt: rect.size.height,
            fragments,
        });
    }
    records
}

/// A live attribution view built from the records the cache carries.
///
/// Resolution and attribution need labels, text and pages only; geometry stays with the records
/// that are handed back for the preview. Building the entries from the same records means a
/// resolved entry's index is also its record's index, so the preview cannot drift from the
/// thing that was resolved.
fn bibliography_from_cached(
    lists: &[CachedReferenceList],
    document_wide: usize,
) -> lyra_reader_text::Bibliography {
    let lists = lists
        .iter()
        .map(|list| lyra_reader_text::ReferenceList {
            entries: list
                .records
                .iter()
                .map(|record| lyra_reader_text::ReferenceEntry {
                    label: record.label.clone(),
                    text: record.text.clone(),
                    page: record.page,
                    start: 0,
                    end: 0,
                    fragments: Vec::new(),
                })
                .collect(),
            numbered: list.numbered,
            heading: list.heading.clone(),
            heading_page: list.heading_page,
            section: list.section.clone(),
            region_start: list.region_start,
        })
        .collect();
    lyra_reader_text::Bibliography {
        lists,
        document_wide,
        sections: Vec::new(),
    }
}

/// The persistent form of one live reference list.
fn cached_reference_list(
    list: &lyra_reader_text::ReferenceList,
    records: Vec<ReferenceRecord>,
) -> CachedReferenceList {
    CachedReferenceList {
        records,
        numbered: list.numbered,
        heading: list.heading.clone(),
        heading_page: list.heading_page,
        section: list.section.clone(),
        region_start: list.region_start,
    }
}
/// A page-space box as its view-space **top-left corner**, the convention the preview uses.
fn view_box(
    backend: &PdfiumBackend,
    cache: &mut std::collections::HashMap<u32, lyra_reader_core::Transform2D>,
    page: u32,
    rect: lyra_reader_core::Rect,
) -> Option<Point> {
    let transform = document_page_view(backend, cache, page)?;
    Some(transform.apply(Point::new(rect.origin.x, rect.origin.y + rect.size.height)))
}

/// The page text **rebuilt from the character sequence**, so indices address the same
/// array that selection uses (PDFium's own string may insert separators that have no
/// character box).
fn text_of(raw: &lyra_reader_core::RawTextPage) -> String {
    raw.chars
        .iter()
        .map(|character| char::from_u32(character.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect()
}

/// One character of a page's text layer, boxed in **view space** (points, top-left origin).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct TextChar {
    pub unicode: u32,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// A page's text layer plus the whole-page string.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TextPage {
    pub page: u32,
    pub chars: Vec<TextChar>,
    /// Whole-page text, aligned with `chars` (line breaks as `\n`).
    pub text: String,
    /// The Unicode mapping has errors, which makes search unreliable.
    pub has_unicode_map_error: bool,
}

/// One closed character range into a page's text layer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct TextRange {
    pub start: u32,
    pub end: u32,
}

/// Convert the Rust text model into the FFI record.
fn text_page_record(page: u32, model: &lyra_reader_text::TextPage) -> TextPage {
    TextPage {
        page,
        chars: model
            .chars
            .iter()
            .map(|character| TextChar {
                unicode: character.unicode,
                x_pt: character.rect.origin.x,
                y_pt: character.rect.origin.y,
                width_pt: character.rect.size.width,
                height_pt: character.rect.size.height,
            })
            .collect(),
        text: model.text.clone(),
        has_unicode_map_error: model.has_unicode_map_error,
    }
}

/// One rasterized tile of a page.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TileBitmap {
    pub page: u32,
    /// Pyramid level; the raster scale is `2^lod`.
    pub lod: u8,
    pub tile_x: u32,
    pub tile_y: u32,
    /// Actual edge length in pixels (BGRA, tightly packed).
    pub size_px: u32,
    pub pixels: Vec<u8>,
}

/// Where one page sits in the scrolling content (mirrors `PagePlacement`).
///
/// `width_pt`/`height_pt` are `None` when PDFium could not measure the page. The shell applies
/// its own fallback for those pages, so the visible geometry matches the historical US Letter
/// box while the engine no longer reports a size it does not have.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct PagePlacementRecord {
    pub index: u32,
    pub top_pt: f64,
    pub left_pt: f64,
    pub width_pt: Option<f64>,
    pub height_pt: Option<f64>,
}

#[uniffi::export]
impl LyraReaderEngine {
    /// Opens a document and keeps it open (contrast with [`LyraReaderEngine::probe_document`],
    /// which is a one-shot summary).
    pub fn open_document(
        &self,
        path: String,
        password: Option<String>,
    ) -> Result<Arc<LyraReaderDocument>, LyraReaderFfiError> {
        let source = std::path::Path::new(&path);
        // One full structural read at open. The same document is used for the XFA probe and the
        // signature policy; previously each probe loaded and parsed the whole file, which was
        // pure waste on every ordinary PDF. A blank page is not evidence of XFA: the decision
        // comes from `/AcroForm /XFA`. The empty user password is handled by the standard
        // security handler, so a permission-encrypted form opens without a prompt.
        let structural = lyra_reader_xfa::load_document(source, password.as_deref());
        let xfa = match &structural {
            Ok(document) => {
                match lyra_reader_xfa::prepare_in_document(document, password.as_deref()) {
                    Ok(prepared) => prepared,
                    Err(error) => {
                        // A damaged XFA packet is not an ordinary PDF. Keep the normal open path
                        // (the fallback page is still the honest fallback) and let PDFium report
                        // what it can; the status names the error when the packet read got far
                        // enough to build one.
                        eprintln!("lyra-reader-xfa: detection failed: {error}");
                        None
                    }
                }
            }
            Err(lyra_reader_xfa::XfaError::PasswordRequired) => {
                return Err(lyra_reader_core::LyraReaderError::new(
                    ErrorCode::Encrypted,
                    "the document is password protected",
                )
                .with_detail(format!("path: {}", source.display()))
                .into());
            }
            Err(error) => {
                // A structural parse failure on an otherwise openable PDF: signature detection
                // below keeps its old fallback (PDFium's signature count), and PDFium decides
                // whether the document itself can open.
                eprintln!("lyra-reader-xfa: structural read failed: {error}");
                None
            }
        };
        let (backend, xfa_state) = match xfa {
            Some(prepared) => {
                let backend = match &prepared.pdf {
                    Some(bytes) => PdfiumBackend::open_bytes(bytes.clone(), source)?,
                    None => PdfiumBackend::open(source, password.as_deref())?,
                };
                let status = XfaStatusRecord {
                    is_xfa: true,
                    rendered: prepared.status.rendered,
                    page_count: if prepared.status.rendered {
                        prepared.status.page_count
                    } else {
                        backend.page_count()
                    },
                    field_count: prepared.status.field_count,
                    packet_names: prepared.status.packet_names.clone(),
                    skipped: prepared.status.skipped.clone(),
                    error: prepared.status.error.clone(),
                    read_only_reason: Some(prepared.status.read_only_reason.clone()),
                    encrypted: prepared.file.encrypted,
                };
                let state = XfaState {
                    status,
                    synthetic_pdf: prepared.pdf.map(std::sync::Arc::new),
                };
                (backend, Some(state))
            }
            None => (PdfiumBackend::open(source, password.as_deref())?, None),
        };
        // The decision cannot change while this handle lives and worker copies inherit it.
        // Reuse the document loaded above when it parsed; only a failed structural read falls
        // back to the path-based signature probe, whose PDFium signature count is the last
        // resort for a structure lopdf could not read.
        let signature = match &structural {
            Ok(document) => lyra_reader_pdfium::detect_signature_in_document(
                document,
                backend.signature_count()?,
            ),
            Err(_) => lyra_reader_pdfium::detect_signature(
                source,
                password.as_deref(),
                backend.signature_count()?,
            ),
        };
        // Page sizes stay lazy: opening a 900-page document must not pay 900 page loads
        // before the first frame. The first layout request measures them (see `page_sizes`).

        // One identity for every cache and every tab: canonical path + content hash. Hashing is
        // the same sequential read the index cache needs later, and is done once here so the
        // shell never has to derive a second key.
        let document_id = crate::document_id::DocumentId::of(source)?;
        Ok(Arc::new(LyraReaderDocument {
            backend,
            path,
            document_id,
            password,
            xfa: xfa_state,
            signature,
            page_sizes: Mutex::new(None),
            layout: Mutex::new(None),
            references: Mutex::new(None),
            figures: Mutex::new(None),
            annotations: Mutex::new(None),
            metadata: Mutex::new(None),
            outline: Mutex::new(None),
            citations: Mutex::new(None),
            index: Mutex::new(IndexRuntime::default()),
            replaced: std::sync::atomic::AtomicBool::new(false),
            ai_text: Mutex::new(std::collections::HashMap::new()),
            text_pages: Mutex::new(TextPageCache::default()),
        }))
    }
}

// ── AI assistant: plans and streaming requests ──────────────────────────────────────────────

/// What the reader asked the assistant to do, as the Swift panel names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiActionRecord {
    SummarizePage,
    SummarizeSelection,
    SummarizeDocument,
    AskSelection,
    TranslateSelection,
    DocumentChat,
    RegionQuestion,
    /// One request for the abstract-level summary of the whole document.
    SummarizeAbstract,
    /// One request for one outline section's summary.
    SummarizeSection,
    /// One request for one page's one-line decision aid.
    SummarizePageLine,
}

/// A selected character range on one page (0-based, inclusive).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct AiSelectionRecord {
    pub page: u32,
    pub start: u32,
    pub end: u32,
}

/// A marquee-selected page region. `page` is 0-based; the rectangle is page-local view space in
/// points, top-left origin, exactly what `rasterize_region` and the text layer use.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiRegionRecord {
    pub page: u32,
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
    /// Text extracted from the text layer inside the rectangle. May be empty for a picture.
    pub text: String,
    /// The PNG capture, when the shell produced one.
    pub image_png: Option<Vec<u8>>,
    pub image_width_px: Option<u32>,
    pub image_height_px: Option<u32>,
    /// Whether the configured model accepts image input. False degrades to text only.
    pub send_image: bool,
    pub include_document_context: bool,
}

/// Text extracted from a marquee-selected region, and whether the cap cut it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiRegionTextRecord {
    pub text: String,
    pub truncated: bool,
}

/// One previous document-chat exchange. `answer` is what the reader saw; the shell trims the
/// list to the bound before asking for a plan.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiConversationTurnRecord {
    pub question: String,
    pub answer: String,
}

/// Everything needed to build a preview. The API key is deliberately absent.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiPlanRequestRecord {
    pub action: AiActionRecord,
    pub document_knowledge: bool,
    pub current_page: u32,
    pub selection: Option<AiSelectionRecord>,
    pub question: Option<String>,
    pub language: Option<String>,
    /// Oldest first. Only used by document chat.
    pub history: Vec<AiConversationTurnRecord>,
    /// Present only for `region_question`.
    pub region: Option<AiRegionRecord>,
    pub base_url: String,
    pub model: String,
    pub temperature: Option<f64>,
    pub max_tokens: Option<u32>,
    /// One of `default`, `off`, `low`, `high`, `max`.
    pub reasoning_mode: String,
    /// One of `none`, `thinking`, `reasoning_effort`, `output_config`, `reasoning.effort`.
    pub reasoning_encoding: String,
    /// Shared document understanding from a completed reading, added by the planner. `None`
    /// means this request carries no prior and the prompts are unchanged.
    pub document_knowledge_text: Option<String>,
    /// 1-based pages the reading covered; carried with the text as one input record.
    pub document_knowledge_pages: Vec<u32>,
}

/// One part summary used by the consolidation request.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiMergePartRecord {
    pub index: u32,
    pub total: u32,
    pub pages: Vec<u32>,
    pub summary: String,
}

/// The local input to the consolidation request. It carries part summaries, not page text.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiMergePlanRequestRecord {
    pub document_title: String,
    pub parts: Vec<AiMergePartRecord>,
    pub base_url: String,
    pub model: String,
    pub temperature: Option<f64>,
    pub max_tokens: Option<u32>,
    pub reasoning_mode: String,
    pub reasoning_encoding: String,
    /// Shared document understanding added to the consolidation request.
    pub document_knowledge_text: Option<String>,
    pub document_knowledge_pages: Vec<u32>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AiHeaderRecord {
    pub name: String,
    pub value: String,
}

/// The exact PNG one request carries. The plan carries these captured bytes, not an encoded
/// copy; the selected transport encodes them once into its own data URL.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiPlanImageRecord {
    pub png: Vec<u8>,
    pub width_px: u32,
    pub height_px: u32,
}

/// One request in the preview. The freshly built plan describes the text, the page labels and
/// the capture; `wire_body` is empty until the shell materialises the body for the selected
/// transport with [`render_ai_plan`]. The API key is added only when the reader presses Send, so
/// it can never appear here.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiPlanPartRecord {
    pub index: u32,
    pub total: u32,
    pub label: String,
    pub primary_page: u32,
    pub pages: Vec<u32>,
    pub page_characters: u64,
    pub request_characters: u64,
    pub system_prompt: String,
    pub user_prompt: String,
    /// Empty in a freshly planned request. [`render_ai_plan`] fills it with the one body for the
    /// selected transport; the preview and the send use that same string.
    pub wire_body: String,
    pub note: Option<String>,
    /// Present only when this exact request carries a region picture.
    pub image: Option<AiPlanImageRecord>,
}

/// The wire shape to materialise for a preview. Exactly one is selected per request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiWireTransport {
    /// The OpenAI-compatible `chat/completions` body used by the API-key connection.
    ChatCompletions,
    /// The documented Responses body used by the ChatGPT plan connection.
    Responses,
}

/// A page-local rectangle of a retrieved passage, in 100% view space. The shell highlights these
/// briefly when a citation chip is clicked; they are never written to the PDF or the annotation cache.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct AiSourceRectRecord {
    pub x_pt: f64,
    pub y_pt: f64,
    pub width_pt: f64,
    pub height_pt: f64,
}

/// One retrieved passage attached to a plan. `page` is 1-based and matches `[p.N]`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiSourceRecord {
    pub page: u32,
    pub snippet: String,
    pub rects: Vec<AiSourceRectRecord>,
}

/// The complete, previewable plan for one action.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiPlanRecord {
    pub action: AiActionRecord,
    pub action_label: String,
    pub document_title: String,
    pub page_count: u32,
    pub base_url: String,
    pub endpoint: String,
    pub host: String,
    pub is_local: bool,
    pub model: String,
    pub temperature: Option<f64>,
    pub max_tokens: Option<u32>,
    /// Whether the rendered body asks the provider to stream.
    pub stream: bool,
    /// Whether the rendered body includes the optional `stream_options` usage field. It is
    /// false after this endpoint/model has rejected the field once.
    pub include_stream_options: bool,
    /// The one provider-specific reasoning field, or `None`. `reasoning_value` is the field's
    /// JSON literal (for example `{"type":"disabled"}`), never a request body.
    pub reasoning_field: Option<String>,
    pub reasoning_value: Option<String>,
    pub parts: Vec<AiPlanPartRecord>,
    pub source_pages: Vec<u32>,
    pub note: Option<String>,
    /// Retrieved passages, with snippets and page geometry. Empty for consolidations.
    pub sources: Vec<AiSourceRecord>,
    /// Previous exchanges included in a document-chat request, after the bound.
    pub history_turns: u32,
    pub preview_headers: Vec<AiHeaderRecord>,
    pub estimated_tokens: u64,
}

/// A validated base URL: the settings panel and the preview show the same normalised values.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiEndpointRecord {
    pub base_url: String,
    pub endpoint: String,
    pub host: String,
    pub is_local: bool,
}

/// Build the Settings > AI connection test without touching the network.
///
/// The plan carries one fixed `ping` user message and no document, history, image or retrieval.
/// It goes through the same prompt/body builder as every other request, so `start_ai_request`
/// sends it with the same transport, SSE parser and error mapping. The key is never part of this
/// record; it crosses the FFI only when the test starts.
#[uniffi::export]
pub fn build_ai_connection_test_plan(
    base_url: String,
    model: String,
) -> Result<AiPlanRecord, LyraReaderFfiError> {
    let plan = build_connection_test_plan(ChatSettings {
        base_url,
        model,
        // A connection test measures reachability, not generation quality: no temperature and a
        // small completion budget keep the request as close to a ping as the protocol allows.
        temperature: None,
        max_tokens: Some(CONNECTION_TEST_MAX_TOKENS),
        reasoning_mode: ReasoningMode::Default,
        reasoning_encoding: ReasoningEncoding::None,
    })?;
    Ok(ai_plan_record(plan))
}

/// Validate and normalise a base URL without touching the network.
#[uniffi::export]
pub fn inspect_ai_base_url(base_url: String) -> Result<AiEndpointRecord, LyraReaderFfiError> {
    let endpoint = inspect_base_url(&base_url)?;
    Ok(AiEndpointRecord {
        base_url: endpoint.base_url,
        endpoint: endpoint.endpoint,
        host: endpoint.host,
        is_local: endpoint.is_local,
    })
}

/// Validate a model name without touching the network.
#[uniffi::export]
pub fn validate_ai_model(model: String) -> Result<String, LyraReaderFfiError> {
    Ok(validate_model(&model)?)
}

// ── Layered summaries ───────────────────────────────────────────────────────────────────────

/// One level of the layered summary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiSummaryLayerRecord {
    /// One paragraph for the whole document, from a bounded prefix of its pages.
    Abstract,
    /// One entry per outline section, or per page range when there is no outline.
    Section,
    /// One line per page.
    Page,
}

/// One planned outline-section row of the layered summary.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AiSummarySectionRecord {
    /// Row title, including the outline number when there is one ("2.1 Method").
    pub title: String,
    /// Outline number when the row came from an outline; empty for fallback rows.
    pub number: String,
    pub depth: u32,
    /// 1-based, inclusive.
    pub page_start: u32,
    /// 1-based, inclusive.
    pub page_end: u32,
    /// 0-based page a click on this row opens.
    pub link_page: u32,
}

/// What the shell asks one layer to build. The outline lives in the shell's sidebar model, so
/// the section ranges arrive here rather than being derived a second time.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiSummaryUnitRequestRecord {
    pub kind: AiSummaryLayerRecord,
    /// 0-based position within the layer; the row identity for matching results.
    pub index: u32,
    /// Row title: "Abstract", "1.1 Background" or "Page 3".
    pub title: String,
    /// Outline number when the section came from an outline.
    pub number: Option<String>,
    pub depth: u32,
    /// 1-based, inclusive. The abstract ignores these and starts at page 1.
    pub page_start: u32,
    pub page_end: u32,
}

/// One layer's build request: no key, no network.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiSummaryRequestRecord {
    pub layer: AiSummaryLayerRecord,
    pub units: Vec<AiSummaryUnitRequestRecord>,
    /// `None` means the document's own language.
    pub language: Option<String>,
    pub document_title: String,
    pub base_url: String,
    pub model: String,
    pub temperature: Option<f64>,
    pub max_tokens: Option<u32>,
    /// One of `default`, `off`, `low`, `high`, `max`.
    pub reasoning_mode: String,
    /// One of `none`, `thinking`, `reasoning_effort`, `output_config`, `reasoning.effort`.
    pub reasoning_encoding: String,
    /// Shared document understanding added to every unit's request.
    pub document_knowledge_text: Option<String>,
    pub document_knowledge_pages: Vec<u32>,
}

/// The text one unit sends and the hash the cache keys on, without prompts.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiSummaryFingerprintRecord {
    pub index: u32,
    pub kind: AiSummaryLayerRecord,
    /// The pages the row asked for (1-based, inclusive).
    pub requested_page_start: u32,
    pub requested_page_end: u32,
    /// The pages actually sent (1-based, inclusive). For a long document's abstract this is the
    /// beginning window followed by the end window, with the middle absent.
    pub covered_page_start: u32,
    pub covered_page_end: u32,
    pub pages: Vec<u32>,
    pub truncated: bool,
    /// SHA-256 of exactly the covered text. The cache key includes this.
    pub text_hash: String,
    pub characters: u64,
    /// The honest coverage line, identical to the preview's ("Summarised from pages 1-12 and
    /// 109-120 of 120."). `None` when the unit has no text.
    pub note: Option<String>,
}

/// One previewable request of one layer.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiSummaryUnitRecord {
    pub index: u32,
    pub kind: AiSummaryLayerRecord,
    pub title: String,
    pub number: Option<String>,
    pub depth: u32,
    /// The pages the row asked for (1-based, inclusive).
    pub page_start: u32,
    pub page_end: u32,
    /// The last page actually sent; smaller than `page_end` when the budget cut the unit.
    /// For an abstract that samples both ends this is the end window's last page; `pages`
    /// lists the beginning window followed by the end window.
    pub covered_page_end: u32,
    pub pages: Vec<u32>,
    pub truncated: bool,
    pub text_hash: String,
    pub characters: u64,
    /// The honest coverage line ("Summarised from pages 1-12 and 109-120 of 120.").
    pub note: Option<String>,
    /// Exactly what one request will send. `None` when the unit has no extractable text.
    pub plan: Option<AiPlanRecord>,
    /// Why this unit cannot be requested, when `plan` is `None`.
    pub error: Option<String>,
}

/// One layer's preview: every request one Generate press may start.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiSummaryPlanRecord {
    pub layer: AiSummaryLayerRecord,
    pub page_count: u32,
    pub units: Vec<AiSummaryUnitRecord>,
    /// The batch/concurrency bounds and what each request sends.
    pub note: String,
    pub max_requests_per_batch: u32,
    pub max_concurrent_requests: u32,
}

/// The bounds the panel states before anything is sent.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct AiSummaryLimitsRecord {
    /// Per end of the document: the abstract reads up to this many pages from the beginning
    /// and the same number from the end.
    pub abstract_max_pages: u32,
    /// Per end, like `abstract_max_pages`.
    pub abstract_max_chars: u64,
    pub section_max_chars: u64,
    pub page_max_chars: u64,
    pub max_requests_per_batch: u32,
    pub max_concurrent_requests: u32,
}

/// Turn the shell's flattened outline into the layered summary's section rows.
///
/// This is the one implementation of the outline range/title rules: the shell's section layer
/// calls it, and the Rust summary builder enriches the rows it returns. Reader bookmarks are
/// excluded; a missing destination is filled from the next (then previous) entry; a section ends
/// before the next entry that starts later; no usable outline falls back to ten-page ranges.
#[uniffi::export]
pub fn ai_summary_sections(
    outline: Vec<OutlineEntry>,
    page_count: u32,
) -> Vec<AiSummarySectionRecord> {
    let entries: Vec<SummaryOutlineEntry> = outline
        .into_iter()
        .map(|entry| SummaryOutlineEntry {
            title: entry.title,
            page: entry.page,
            depth: entry.depth,
            bookmark_id: entry.bookmark_id,
            is_bookmark_subtree: entry.is_bookmark_subtree,
        })
        .collect();
    plan_summary_sections(&entries, page_count)
        .into_iter()
        .map(|section| AiSummarySectionRecord {
            title: section.title,
            number: section.number,
            depth: section.depth,
            page_start: section.page_start,
            page_end: section.page_end,
            link_page: section.link_page,
        })
        .collect()
}

/// The layered-summary bounds, available before a plan is built so the panel can state them.
#[uniffi::export]
pub fn ai_summary_limits() -> AiSummaryLimitsRecord {
    AiSummaryLimitsRecord {
        abstract_max_pages: SUMMARY_ABSTRACT_MAX_PAGES as u32,
        abstract_max_chars: SUMMARY_ABSTRACT_MAX_CHARS as u64,
        section_max_chars: SUMMARY_SECTION_MAX_CHARS as u64,
        page_max_chars: SUMMARY_PAGE_MAX_CHARS as u64,
        max_requests_per_batch: SUMMARY_MAX_REQUESTS_PER_BATCH as u32,
        max_concurrent_requests: SUMMARY_MAX_CONCURRENT_REQUESTS as u32,
    }
}

/// Per-request instrumentation. Counts and byte totals only; no content.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AiStreamDiagnostics {
    pub http_status: u16,
    pub bytes: u64,
    pub frames: u32,
    pub data_frames: u32,
    pub content_frames: u32,
    pub reasoning_frames: u32,
    pub role_only_frames: u32,
    pub empty_frames: u32,
    pub usage_frames: u32,
    pub content_shape: String,
    pub finish_reason: Option<String>,
    pub prompt_tokens: Option<u64>,
    pub completion_tokens: Option<u64>,
    pub total_tokens: Option<u64>,
    pub reasoning_tokens: Option<u64>,
}

/// The stable category of a transport failure. The panel and the audit trail read this instead
/// of matching error text; `Other` keeps the existing error display unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AiFailureRecord {
    Other,
    /// The request never left this Mac: no route / network down / name resolution failed.
    Offline,
    /// The endpoint is loopback and nothing is listening there.
    LocalServer,
}

impl From<lyra_reader_ai::AiFailure> for AiFailureRecord {
    fn from(failure: lyra_reader_ai::AiFailure) -> Self {
        match failure {
            lyra_reader_ai::AiFailure::Other => Self::Other,
            lyra_reader_ai::AiFailure::Offline => Self::Offline,
            lyra_reader_ai::AiFailure::LocalServer => Self::LocalServer,
        }
    }
}

/// One event from a running request. The shell polls a handle and renders these in order.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum AiEventRecord {
    PartStarted {
        index: u32,
        total: u32,
        label: String,
    },
    Delta {
        text: String,
    },
    /// The provider's reasoning/thinking channel. The shell shows it separately and never
    /// appends it to the answer.
    ReasoningDelta {
        text: String,
    },
    Usage {
        prompt_tokens: Option<u64>,
        completion_tokens: Option<u64>,
        total_tokens: Option<u64>,
        reasoning_tokens: Option<u64>,
    },
    Diagnostics {
        diagnostics: AiStreamDiagnostics,
    },
    Done,
    Error {
        message: String,
        cancelled: bool,
        /// Why the transport failed, as a fixed category. `Other` for every error that is not a
        /// recognized offline/local-server transport failure.
        failure: AiFailureRecord,
        /// Stable AI error category. Assigned once from the Rust error variant; the shell maps
        /// it to its audit vocabulary instead of matching message text.
        code: AiErrorCode,
    },
}

struct AiJob {
    events: Mutex<std::collections::VecDeque<AiEventRecord>>,
    finished: std::sync::atomic::AtomicBool,
    cancel: CancellationToken,
}

impl Default for AiJob {
    fn default() -> Self {
        Self {
            events: Mutex::new(std::collections::VecDeque::new()),
            finished: std::sync::atomic::AtomicBool::new(false),
            cancel: CancellationToken::new(),
        }
    }
}

impl AiJob {
    fn push_event(&self, event: RunEvent) {
        let event = match event {
            RunEvent::PartStarted {
                index,
                total,
                label,
            } => AiEventRecord::PartStarted {
                index,
                total,
                label,
            },
            RunEvent::Delta(text) => AiEventRecord::Delta { text },
            RunEvent::ReasoningDelta(text) => AiEventRecord::ReasoningDelta { text },
            RunEvent::Usage(TokenUsage {
                prompt_tokens,
                completion_tokens,
                total_tokens,
                reasoning_tokens,
            }) => AiEventRecord::Usage {
                prompt_tokens,
                completion_tokens,
                total_tokens,
                reasoning_tokens,
            },
            RunEvent::Diagnostics(StreamDiagnostics {
                http_status,
                bytes,
                frames,
                data_frames,
                content_frames,
                reasoning_frames,
                role_only_frames,
                empty_frames,
                usage_frames,
                content_shape,
                finish_reason,
                usage,
            }) => AiEventRecord::Diagnostics {
                diagnostics: AiStreamDiagnostics {
                    http_status,
                    bytes,
                    frames,
                    data_frames,
                    content_frames,
                    reasoning_frames,
                    role_only_frames,
                    empty_frames,
                    usage_frames,
                    content_shape,
                    finish_reason,
                    prompt_tokens: usage.prompt_tokens,
                    completion_tokens: usage.completion_tokens,
                    total_tokens: usage.total_tokens,
                    reasoning_tokens: usage.reasoning_tokens,
                },
            },
            RunEvent::Done => AiEventRecord::Done,
        };
        self.push(event);
    }

    fn push(&self, event: AiEventRecord) {
        self.events
            // Append-only queue of independent records; no cross-event invariant is guarded.
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push_back(event);
    }
}

/// A running AI request. The worker thread owns the key for the duration of the request and
/// drops it when the worker ends; this handle holds only events and a cancellation flag.
#[derive(uniffi::Object)]
pub struct LyraReaderAiRequest {
    job: Arc<AiJob>,
}

impl Drop for LyraReaderAiRequest {
    fn drop(&mut self) {
        // The Swift handle owns this object. If the panel goes away without calling cancel, the
        // worker must still stop rather than stream into a queue nobody reads.
        self.job.cancel.cancel();
    }
}

#[uniffi::export]
impl LyraReaderAiRequest {
    /// Events queued since the previous poll, oldest first.
    pub fn poll(&self) -> Vec<AiEventRecord> {
        let mut events = self
            .job
            .events
            // Append-only queue of independent records; no cross-event invariant is guarded.
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        std::mem::take(&mut *events).into_iter().collect()
    }

    /// Ask the worker to stop. The transports observe this flag and the HTTP request is closed.
    pub fn cancel(&self) {
        self.job.cancel.cancel();
    }

    /// Whether the worker has stopped. A final `poll()` may still return the last events.
    pub fn is_finished(&self) -> bool {
        self.job.finished.load(std::sync::atomic::Ordering::SeqCst)
    }
}

/// Materialise the exact body for the transport the reader selected.
///
/// This is the only place a body is built for a shell preview: one image is base64-encoded once
/// for the selected transport, never for both. The returned plan's `wire_body` is the exact
/// previewed string, and sending it reuses those bytes instead of encoding again. A freshly
/// built plan has empty bodies, so it can never carry a stale chat-completions body into a
/// ChatGPT request.
#[uniffi::export]
pub fn render_ai_plan(
    plan: AiPlanRecord,
    transport: AiWireTransport,
) -> Result<AiPlanRecord, LyraReaderFfiError> {
    let chat_plan = chat_plan_from_record(plan.clone())?;
    let chat_transport = match transport {
        AiWireTransport::ChatCompletions => ChatTransport::ChatCompletions,
        AiWireTransport::Responses => ChatTransport::Responses,
    };
    let mut rendered = plan;
    for (part, target) in chat_plan.parts.iter().zip(rendered.parts.iter_mut()) {
        target.wire_body = chat_plan.render_body(part, chat_transport);
    }
    Ok(rendered)
}

/// Start a request for a previously previewed plan.
///
/// `api_key` crosses the FFI boundary here and is moved into the worker thread; it is not stored
/// in [`LyraReaderAiRequest`], the job, or any record. `use_mock_provider` is the deterministic,
/// network-free path used by the checks; the app always passes `false`.
#[uniffi::export]
pub fn start_ai_request(
    plan: AiPlanRecord,
    api_key: String,
    use_mock_provider: bool,
) -> Result<Arc<LyraReaderAiRequest>, LyraReaderFfiError> {
    if api_key.is_empty() {
        return Err(LyraReaderFfiError::Ai {
            severity: AiErrorCode::Unauthorized.severity(),
            code: AiErrorCode::Unauthorized,
            message: "No API key is configured. Add one in Settings > AI; nothing was sent."
                .to_string(),
        });
    }
    if api_key.chars().any(|character| character.is_control()) {
        return Err(LyraReaderFfiError::Ai {
            severity: AiErrorCode::InvalidSettings.severity(),
            code: AiErrorCode::InvalidSettings,
            message: "The API key contains a control character or line break, so it was not sent."
                .to_string(),
        });
    }
    let plan = chat_plan_from_record(plan)?;
    let job = Arc::new(AiJob::default());
    let worker_job = Arc::clone(&job);
    std::thread::Builder::new()
        .name("lyra-reader-ai-request".to_string())
        .spawn(move || {
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let mut emit = |event: RunEvent| worker_job.push_event(event);
                if use_mock_provider {
                    MockProvider::preset().run(&plan, &worker_job.cancel, &mut emit)
                } else {
                    run_plan(&plan, &api_key, &worker_job.cancel, &mut emit)
                }
            }));
            match outcome {
                Ok(Ok(())) => {}
                Ok(Err(lyra_reader_ai::AiError::Cancelled)) => {
                    worker_job.push(AiEventRecord::Error {
                        message: "Cancelled".to_string(),
                        cancelled: true,
                        failure: AiFailureRecord::Other,
                        code: AiErrorCode::Cancelled,
                    });
                }
                Ok(Err(error)) => {
                    worker_job.push(AiEventRecord::Error {
                        message: error.to_string(),
                        cancelled: false,
                        failure: AiFailureRecord::from(error.failure()),
                        code: AiErrorCode::of(&error),
                    });
                }
                Err(_) => {
                    worker_job.push(AiEventRecord::Error {
                        message: "The AI request worker stopped unexpectedly.".to_string(),
                        cancelled: false,
                        failure: AiFailureRecord::Other,
                        code: AiErrorCode::Other,
                    });
                }
            }
            worker_job
                .finished
                .store(true, std::sync::atomic::Ordering::SeqCst);
        })
        .map_err(|error| LyraReaderFfiError::Ai {
            severity: AiErrorCode::Other.severity(),
            code: AiErrorCode::Other,
            message: format!("could not start the AI request worker: {error}"),
        })?;
    Ok(Arc::new(LyraReaderAiRequest { job }))
}

/// Build the previewable consolidation request from part summaries. This never touches the
/// network; it is the same preview-before-send path as the part requests.
#[uniffi::export]
pub fn build_ai_merge_plan(
    request: AiMergePlanRequestRecord,
) -> Result<AiPlanRecord, LyraReaderFfiError> {
    let temperature = request.temperature.and_then(|value| {
        if value.is_finite() {
            Some(value as f32)
        } else {
            None
        }
    });
    let reasoning_mode = ReasoningMode::from_wire(&request.reasoning_mode).ok_or_else(|| {
        LyraReaderFfiError::InvalidArgument {
            severity: ErrorSeverity::Document,
            message: format!(
                "Unknown reasoning mode {}. Use default, off, low, high or max.",
                request.reasoning_mode
            ),
        }
    })?;
    let reasoning_encoding =
        ReasoningEncoding::from_wire(&request.reasoning_encoding).ok_or_else(|| {
            LyraReaderFfiError::InvalidArgument { severity: ErrorSeverity::Document,
                message: format!(
                    "Unknown reasoning encoding {}. Use none, thinking, reasoning_effort, output_config or reasoning.effort.",
                    request.reasoning_encoding
                ),
            }
        })?;
    let plan = build_merge_plan(MergePlanRequest {
        document_title: request.document_title,
        settings: ChatSettings {
            base_url: request.base_url,
            model: request.model,
            temperature,
            max_tokens: request.max_tokens,
            reasoning_mode,
            reasoning_encoding,
        },
        parts: request
            .parts
            .into_iter()
            .map(|part| MergePart {
                index: part.index,
                total: part.total,
                pages: part.pages,
                summary: part.summary,
            })
            .collect(),
        document_knowledge: document_knowledge_input(
            request.document_knowledge_text,
            request.document_knowledge_pages,
        ),
    })?;
    Ok(ai_plan_record(plan))
}

fn ai_plan_record(plan: ChatPlan) -> AiPlanRecord {
    let estimated_tokens = plan.estimated_tokens();
    let history_turns = plan.history_turns;
    let stream = plan.wire.stream;
    let include_stream_options = plan.wire.include_stream_options;
    let reasoning_field = plan
        .wire
        .reasoning
        .as_ref()
        .map(|field| field.field.clone());
    let reasoning_value = plan
        .wire
        .reasoning
        .as_ref()
        .map(|field| field.value.to_string());
    let sources = plan
        .sources
        .into_iter()
        .map(|source| AiSourceRecord {
            page: source.page,
            snippet: source.snippet,
            rects: source
                .rects
                .into_iter()
                .map(|rect| AiSourceRectRecord {
                    x_pt: rect.x_pt,
                    y_pt: rect.y_pt,
                    width_pt: rect.width_pt,
                    height_pt: rect.height_pt,
                })
                .collect(),
        })
        .collect();
    AiPlanRecord {
        action: ai_action_record(plan.action),
        action_label: plan.action.label().to_string(),
        document_title: plan.document_title,
        page_count: plan.page_count,
        base_url: plan.base_url,
        endpoint: plan.endpoint,
        host: plan.host,
        is_local: plan.is_local,
        model: plan.model,
        temperature: plan.temperature.map(f64::from),
        max_tokens: plan.max_tokens,
        stream,
        include_stream_options,
        reasoning_field,
        reasoning_value,
        parts: plan
            .parts
            .into_iter()
            .map(|part| AiPlanPartRecord {
                index: part.index,
                total: part.total,
                label: part.label,
                primary_page: part.primary_page,
                pages: part.pages,
                page_characters: part.page_characters,
                request_characters: part.request_characters,
                system_prompt: part.system_prompt,
                user_prompt: part.user_prompt,
                wire_body: part.wire_body.unwrap_or_default(),
                note: part.note,
                image: part.image.map(|image| AiPlanImageRecord {
                    png: image.png,
                    width_px: image.width_px,
                    height_px: image.height_px,
                }),
            })
            .collect(),
        source_pages: plan.source_pages,
        note: plan.note,
        sources,
        history_turns,
        preview_headers: preview_headers()
            .into_iter()
            .map(|(name, value)| AiHeaderRecord { name, value })
            .collect(),
        estimated_tokens,
    }
}

fn ai_action_record(action: AiAction) -> AiActionRecord {
    match action {
        AiAction::SummarizePage => AiActionRecord::SummarizePage,
        AiAction::SummarizeSelection => AiActionRecord::SummarizeSelection,
        AiAction::SummarizeDocument => AiActionRecord::SummarizeDocument,
        AiAction::AskSelection => AiActionRecord::AskSelection,
        AiAction::TranslateSelection => AiActionRecord::TranslateSelection,
        AiAction::DocumentChat => AiActionRecord::DocumentChat,
        AiAction::RegionQuestion => AiActionRecord::RegionQuestion,
        AiAction::SummarizeAbstract => AiActionRecord::SummarizeAbstract,
        AiAction::SummarizeSection => AiActionRecord::SummarizeSection,
        AiAction::SummarizePageLine => AiActionRecord::SummarizePageLine,
    }
}

fn chat_plan_from_record(plan: AiPlanRecord) -> Result<ChatPlan, LyraReaderFfiError> {
    let action = match plan.action {
        AiActionRecord::SummarizePage => AiAction::SummarizePage,
        AiActionRecord::SummarizeSelection => AiAction::SummarizeSelection,
        AiActionRecord::SummarizeDocument => AiAction::SummarizeDocument,
        AiActionRecord::AskSelection => AiAction::AskSelection,
        AiActionRecord::TranslateSelection => AiAction::TranslateSelection,
        AiActionRecord::DocumentChat => AiAction::DocumentChat,
        AiActionRecord::RegionQuestion => AiAction::RegionQuestion,
        AiActionRecord::SummarizeAbstract => AiAction::SummarizeAbstract,
        AiActionRecord::SummarizeSection => AiAction::SummarizeSection,
        AiActionRecord::SummarizePageLine => AiAction::SummarizePageLine,
    };
    if !(plan.endpoint.starts_with("http://") || plan.endpoint.starts_with("https://")) {
        return Err(LyraReaderFfiError::Ai {
            severity: AiErrorCode::InvalidSettings.severity(),
            code: AiErrorCode::InvalidSettings,
            message: "The request preview has an invalid endpoint.".to_string(),
        });
    }
    if plan.parts.is_empty() {
        return Err(LyraReaderFfiError::Ai {
            severity: AiErrorCode::Other.severity(),
            code: AiErrorCode::Other,
            message: "The request preview has no requests.".to_string(),
        });
    }
    let reasoning = match (plan.reasoning_field.as_ref(), plan.reasoning_value.as_ref()) {
        (Some(field), Some(value)) => Some(ReasoningField {
            field: field.clone(),
            value: serde_json::from_str(value).map_err(|_| LyraReaderFfiError::Ai {
                severity: AiErrorCode::InvalidSettings.severity(),
                code: AiErrorCode::InvalidSettings,
                message: "The request preview has an invalid reasoning field.".to_string(),
            })?,
        }),
        (None, None) => None,
        _ => {
            return Err(LyraReaderFfiError::Ai {
                severity: AiErrorCode::InvalidSettings.severity(),
                code: AiErrorCode::InvalidSettings,
                message: "The request preview names only half of its reasoning field.".to_string(),
            });
        }
    };
    let wire = ChatWire {
        reasoning,
        stream: plan.stream,
        include_stream_options: plan.include_stream_options,
    };
    let parts = plan
        .parts
        .into_iter()
        .map(|part| lyra_reader_ai::ChatPart {
            index: part.index,
            total: part.total,
            label: part.label,
            pages: part.pages,
            primary_page: part.primary_page,
            page_characters: part.page_characters,
            request_characters: part.request_characters,
            system_prompt: part.system_prompt,
            user_prompt: part.user_prompt,
            image: part.image.map(|image| ChatImage {
                width_px: image.width_px,
                height_px: image.height_px,
                png: image.png,
            }),
            wire_body: (!part.wire_body.is_empty()).then_some(part.wire_body),
            note: part.note,
        })
        .collect();
    Ok(ChatPlan {
        action,
        document_title: plan.document_title,
        page_count: plan.page_count,
        base_url: plan.base_url,
        endpoint: plan.endpoint,
        host: plan.host,
        is_local: plan.is_local,
        model: plan.model,
        temperature: plan.temperature.map(|value| value as f32),
        max_tokens: plan.max_tokens,
        wire,
        parts,
        source_pages: plan.source_pages,
        note: plan.note,
        sources: plan
            .sources
            .into_iter()
            .map(|source| lyra_reader_ai::chat::ChatSource {
                page: source.page,
                snippet: source.snippet,
                rects: source
                    .rects
                    .into_iter()
                    .map(|rect| AiSourceRect {
                        x_pt: rect.x_pt,
                        y_pt: rect.y_pt,
                        width_pt: rect.width_pt,
                        height_pt: rect.height_pt,
                    })
                    .collect(),
            })
            .collect(),
        history_turns: plan.history_turns,
        estimated_tokens_override: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::ErrorKind;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// One representative error per severity class crosses the FFI boundary with its severity.
    #[test]
    fn every_severity_class_crosses_the_ffi_payload() {
        let rows = [
            (
                lyra_reader_core::LyraReaderError::new(ErrorCode::RenderFailed, "a tile failed"),
                ErrorSeverity::Recoverable,
            ),
            (
                lyra_reader_core::LyraReaderError::new(
                    ErrorCode::CorruptDocument,
                    "the page tree is damaged",
                ),
                ErrorSeverity::Document,
            ),
            (
                lyra_reader_core::LyraReaderError::new(
                    ErrorCode::GpuDeviceLost,
                    "the device was lost",
                ),
                ErrorSeverity::Fatal,
            ),
        ];
        for (error, expected) in rows {
            let converted: LyraReaderFfiError = error.into();
            assert_eq!(converted.severity(), expected);
        }

        // Explicit per-path overrides survive the conversion too: a call site can classify a
        // RenderFailed write failure as Document without changing its code or message.
        let overridden =
            lyra_reader_core::LyraReaderError::new(ErrorCode::RenderFailed, "the save failed")
                .with_severity(lyra_reader_core::Severity::Document);
        let converted: LyraReaderFfiError = overridden.into();
        assert_eq!(converted.severity(), ErrorSeverity::Document);

        // The AI payload derives its severity from the stable code, not from its message.
        for (code, expected) in [
            (AiErrorCode::RateLimited, ErrorSeverity::Recoverable),
            (AiErrorCode::InvalidSettings, ErrorSeverity::Document),
        ] {
            assert_eq!(code.severity(), expected);
        }
        let ai: LyraReaderFfiError = lyra_reader_ai::AiError::RateLimited.into();
        assert!(matches!(ai, LyraReaderFfiError::Ai { .. }));
        assert_eq!(ai.severity(), ErrorSeverity::Recoverable);
    }

    #[test]
    fn a_missing_ai_selection_is_an_error_not_a_panic() {
        let error = selection_only_page(None).expect_err("no selection must not panic");
        match error {
            LyraReaderFfiError::InvalidArgument { message, .. } => {
                assert!(message.contains("selection"), "{message}");
            }
            other => panic!("expected InvalidArgument, got {other:?}"),
        }
        assert_eq!(
            selection_only_page(Some(AiSelectionRange {
                page: 4,
                start: 0,
                end: 1,
            }))
            .expect("a present selection"),
            4
        );
    }

    #[test]
    fn a_failed_page_info_is_unknown_not_us_letter() {
        let sizes = collect_page_sizes(2, |index| match index {
            0 => Ok((612.0, 792.0)),
            _ => Err(LyraReaderFfiError::Document {
                severity: ErrorSeverity::Document,
                message: "page 2 could not be measured".to_string(),
            }),
        });
        assert_eq!(
            sizes,
            vec![Some((612.0, 792.0)), None],
            "a failed page_info must be reported as unknown, not as a default size"
        );
        assert_ne!(
            sizes[1],
            Some((612.0, 792.0)),
            "US Letter must not be fabricated for an unmeasured page"
        );
    }

    #[test]
    fn transport_failures_cross_the_ffi_as_fixed_categories() {
        // The shell and the audit trail read this enum, never the message string.
        assert_eq!(
            AiFailureRecord::from(lyra_reader_ai::AiFailure::Offline),
            AiFailureRecord::Offline
        );
        assert_eq!(
            AiFailureRecord::from(lyra_reader_ai::AiFailure::LocalServer),
            AiFailureRecord::LocalServer
        );
        assert_eq!(
            AiFailureRecord::from(lyra_reader_ai::AiFailure::Other),
            AiFailureRecord::Other
        );
        assert_eq!(
            AiFailureRecord::from(
                lyra_reader_ai::AiError::Offline("no route".to_string()).failure()
            ),
            AiFailureRecord::Offline
        );
    }

    /// Resolves a committed fixture at run time.
    ///
    /// `CARGO_MANIFEST_DIR` is compiled into the binary. When several checkouts share one
    /// `target/` directory, cargo can run a binary that was built in a checkout which has since
    /// been deleted; the committed fixtures then exist only in the checkout running the tests.
    /// The working directory (the package root) and an explicit override are therefore searched
    /// as well.
    fn fixture(name: &str) -> std::path::PathBuf {
        let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut roots = Vec::new();
        if let Some(override_dir) = std::env::var_os("LYRA_READER_TEST_FIXTURES")
            && !override_dir.is_empty()
        {
            roots.push(std::path::PathBuf::from(override_dir));
        }
        // The checkout currently running the tests wins over the one that compiled the binary.
        if let Ok(current_dir) = std::env::current_dir() {
            roots.extend(
                current_dir
                    .ancestors()
                    .map(|ancestor| ancestor.join("tests/fixtures")),
            );
        }
        roots.push(manifest.join("../../tests/fixtures"));
        let mut tried = Vec::new();
        for root in roots {
            let candidate = root.join(name);
            if candidate.is_file() {
                return candidate;
            }
            tried.push(candidate);
        }
        let tried = tried
            .iter()
            .map(|path| format!("  {}", path.display()))
            .collect::<Vec<_>>()
            .join("\n");
        panic!("test fixture {name:?} was not found. Tried:\n{tried}");
    }

    /// A scratch directory owned by one test and removed when the test ends (or panics).
    ///
    /// The name includes a process-wide sequence number as well as the pid and clock, and the
    /// directory itself is reserved with `create_dir`, so two tests can never share it.
    struct ScratchDir {
        path: std::path::PathBuf,
    }

    impl std::ops::Deref for ScratchDir {
        type Target = std::path::Path;
        fn deref(&self) -> &std::path::Path {
            &self.path
        }
    }

    impl AsRef<std::path::Path> for ScratchDir {
        fn as_ref(&self) -> &std::path::Path {
            &self.path
        }
    }

    impl Drop for ScratchDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn scratch(label: &str) -> ScratchDir {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let root = std::env::temp_dir();
        std::fs::create_dir_all(&root).unwrap_or_else(|error| {
            panic!(
                "could not create the temporary directory {}: {error}",
                root.display()
            )
        });
        let root = std::fs::canonicalize(&root).unwrap_or(root);
        let label: String = label
            .chars()
            .map(|character| {
                if character.is_ascii_alphanumeric() || character == '-' || character == '_' {
                    character
                } else {
                    '_'
                }
            })
            .take(48)
            .collect();
        for _ in 0..128 {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or(0);
            let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
            let path = root.join(format!(
                "lyra-reader-ffi-test-{}-{sequence}-{nanos}-{label}",
                std::process::id()
            ));
            match std::fs::create_dir(&path) {
                Ok(()) => return ScratchDir { path },
                Err(error) if error.kind() == ErrorKind::AlreadyExists => continue,
                Err(error) => panic!(
                    "could not create test scratch directory {}: {error}",
                    path.display()
                ),
            }
        }
        panic!(
            "could not find a free test scratch directory under {}",
            root.display()
        );
    }

    #[test]
    fn figure_region_bounds_are_transformed_with_rotation_and_crop_origin() {
        let geometry = lyra_reader_core::PageGeometry::new(
            lyra_reader_core::Rect::new(0.0, 0.0, 500.0, 700.0),
            lyra_reader_core::Rect::new(100.0, 200.0, 200.0, 300.0),
            lyra_reader_core::Rotation::Clockwise90,
            1.0,
        );
        let region = lyra_reader_core::Rect::new(120.0, 240.0, 30.0, 20.0);
        let view = page_region_to_view(region, geometry);
        assert!((view.size.width - 20.0).abs() < 1e-9);
        assert!((view.size.height - 30.0).abs() < 1e-9);
        assert!(view.origin.x >= 0.0 && view.origin.y >= 0.0);
        let page = geometry.view_size(1.0);
        assert!(view.max_x() <= page.width && view.max_y() <= page.height);
    }

    #[test]
    fn engine_reports_version_and_backend() {
        let engine = LyraReaderEngine::new();
        assert_eq!(engine.version(), ENGINE_VERSION);
        assert!(engine.backend().contains("pdfium") || engine.backend().contains("stub"));
        assert!(engine.raster_threads() >= 1);
    }

    /// Every page-taking entry point must read the same sentence for the same condition.
    ///
    /// The table is the contract: one canonical 1-based message for "page N is outside the
    /// document", one severity (`Document`), and both numbers preserved. It covers the four
    /// FFI-side call sites; the PDFium-side ones are covered by the backend's own table test.
    #[test]
    fn out_of_range_page_messages_are_one_canonical_sentence() {
        if !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let path = fixture("multipage.pdf");
        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(path.display().to_string(), None)
            .expect("open fixture");
        let page_count = document.page_count();
        let page = page_count + 1;
        let expected = lyra_reader_core::page_out_of_range_message(page, page_count);
        assert!(expected.starts_with(&format!("page {} ", page + 1)));

        let errors: Vec<(&str, LyraReaderFfiError)> = vec![
            (
                "rasterize_page",
                document
                    .rasterize_page(page, 1.0)
                    .expect_err("out of range"),
            ),
            (
                "rasterize_tile",
                document
                    .rasterize_tile(page, 0, 0, 0, 256)
                    .expect_err("out of range"),
            ),
            (
                "rasterize_region",
                document
                    .rasterize_region(page, 1.0, 0.0, 0.0, 10.0, 10.0, false)
                    .expect_err("out of range"),
            ),
        ];
        // `ai_page` is private to the document type; the test module is a child, so it can call
        // it exactly as the AI plan builder does.
        let ai_error = document.ai_page(page).expect_err("out of range");
        let mut errors = errors;
        errors.push(("ai_page", ai_error));

        for (name, error) in errors {
            let LyraReaderFfiError::InvalidArgument { message, severity } = &error else {
                panic!("{name} must report InvalidArgument, got {error:?}");
            };
            assert_eq!(message, &expected, "{name} keeps the canonical sentence");
            assert_eq!(*severity, ErrorSeverity::Document, "{name} severity");
        }

        // In-range pages still succeed: the helper must not reject page 0 or the last page.
        for page in [0, page_count - 1] {
            document
                .rasterize_page(page, 1.0)
                .unwrap_or_else(|error| panic!("page {page} is in range: {error:?}"));
        }
    }

    #[test]
    fn probing_a_missing_file_is_a_document_error() {
        // Without a PDFium library the engine fails before it can look at the path, so it
        // answers `BackendUnavailable` and the mapping pinned down here is unreachable. Same
        // guard as the other engine-backed tests below: the Linux CI job has no PDFium, and
        // scripts/fetch-pdfium.sh only downloads the macOS build.
        if !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }

        let engine = LyraReaderEngine::new();
        let result = engine.probe_document("/nonexistent/lyra-reader.pdf".to_string(), None);
        match result {
            Err(LyraReaderFfiError::Document { message, .. }) => assert!(!message.is_empty()),
            other => panic!("expected a document error, got {other:?}"),
        }
    }

    #[test]
    fn text_page_returns_boxes_inside_the_page() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/text-page.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        let text = document.text_page(0).expect("text page");
        assert!(!text.text.is_empty(), "the fixture has a text layer");
        assert!(
            text.chars.len() > 50,
            "only {} characters",
            text.chars.len()
        );

        let size = document.page_size_pt(0).expect("page size");
        for character in &text.chars {
            assert!(
                character.x_pt >= -1.0 && character.x_pt <= size.width_pt + 1.0,
                "character x {} outside the page width {}",
                character.x_pt,
                size.width_pt
            );
            // View space: y grows downwards from the top edge.
            assert!(
                character.y_pt >= -1.0 && character.y_pt <= size.height_pt + 1.0,
                "character y {} outside the page height {}",
                character.y_pt,
                size.height_pt
            );
        }

        // The whole-page string is what search will run on, so it must be the same text.
        assert!(
            text.text.chars().count() >= text.chars.len() / 2,
            "the page string looks truncated: {} chars of text for {} boxes",
            text.text.chars().count(),
            text.chars.len()
        );
    }

    #[test]
    fn citations_and_references_are_reported_without_erroring() {
        // The fixtures carry neither citations nor a reference list, so the contract to pin
        // down is "absent means empty, not an error". Real-document behaviour is measured by
        // `lyra-reader-cli cite` against the sample corpus.
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/text-page.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        let citations = document.citations(0).expect("citations");
        assert!(citations.is_empty(), "the fixture has no citations");

        let references = document.references().expect("references");
        assert!(references.is_empty(), "the fixture has no reference list");

        let size = document.page_size_pt(0).expect("page size");
        for citation in document.citations(0).expect("citations") {
            assert!(citation.x_pt >= -1.0 && citation.x_pt <= size.width_pt + 1.0);
            assert!(citation.y_pt >= -1.0 && citation.y_pt <= size.height_pt + 1.0);
        }
    }

    #[test]
    fn figures_and_caption_mentions_are_reported_without_erroring() {
        // The fixture's text is placeholder prose with no captions, so the contract to pin down
        // is "absent means empty, not an error" plus well-formed boxes when there are any. The
        // real-document behaviour is measured by `lyra-reader-cli figures` against the corpus.
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/text-page.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        let figures = document.figures().expect("figures");
        assert!(figures.is_empty(), "the fixture has no figure captions");
        assert!(
            document.figures().expect("cached figures").is_empty(),
            "the cached read must agree with the first"
        );
        assert!(document.caption_mentions(0).expect("mentions").is_empty());

        // The same well-formedness rules as citations: a record that exists must be boxed
        // inside its page.
        let size = document.page_size_pt(0).expect("page size");
        for figure in &figures {
            assert_eq!(figure.page, 0);
            assert!(figure.x_pt >= -1.0 && figure.x_pt <= size.width_pt + 1.0);
            assert!(figure.y_pt >= -1.0 && figure.y_pt <= size.height_pt + 1.0);
            assert!(figure.width_pt > 0.0 && figure.height_pt > 0.0);
        }
        for mention in document.caption_mentions(0).expect("mentions") {
            assert!(mention.x_pt >= -1.0 && mention.x_pt <= size.width_pt + 1.0);
            assert!(mention.y_pt >= -1.0 && mention.y_pt <= size.height_pt + 1.0);
            assert!(mention.width_pt > 0.0 && mention.height_pt > 0.0);
            assert!(mention.end > mention.start);
        }
    }

    #[test]
    fn links_are_reported_in_view_space() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/multipage.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        // The fixture has no link annotations, so the contract is "empty, not an error" --
        // and every link that does exist must be actionable and inside the page.
        let size = document.page_size_pt(0).expect("page size");
        for page in 0..document.page_count() {
            for link in document.links(page).expect("links") {
                assert!(
                    link.uri.is_some() || link.page.is_some(),
                    "a link with no target should not be reported"
                );
                assert!(link.x_pt >= -1.0 && link.x_pt <= size.width_pt + 1.0);
                assert!(link.y_pt >= -1.0 && link.y_pt <= size.height_pt + 1.0);
                assert!(link.width_pt > 0.0 && link.height_pt > 0.0);
                if let Some(target) = link.page {
                    assert!(target < document.page_count());
                }
            }
        }
    }

    #[test]
    fn a_damaged_annotation_is_reported_and_blocks_saves() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotations-damaged.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: damaged-annotation fixture or PDFium unavailable");
            return;
        }

        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");
        let annotations = document.annotations().expect("the valid annotations load");
        assert_eq!(annotations.len(), 2, "the two valid annotations are kept");

        let status = document
            .annotation_read_status()
            .expect("the unreadable count is available");
        assert_eq!(status.unreadable_annotations, 1);
        assert_eq!(status.pages, vec![0]);
        assert!(
            status.details.iter().any(|detail| detail.contains("/L")),
            "the detail names the field: {:?}",
            status.details
        );
        // The status is cached with the scan: asking again does not grow the count per page.
        assert_eq!(
            document.annotation_read_status().expect("cached status"),
            status
        );

        let scratch = scratch("ffi-damaged-annotation");
        let destination = scratch.join("saved.pdf");
        let error = document
            .save_annotations_copy(
                destination.display().to_string(),
                Vec::new(),
                Vec::new(),
                1.0,
            )
            .expect_err("saving around an unreadable annotation must be refused");
        match error {
            LyraReaderFfiError::Document { message, .. } => {
                assert!(message.contains("blocked"), "{message}");
                assert!(message.contains("page(s) 1"), "{message}");
            }
            other => panic!("expected a document refusal, got {other:?}"),
        }
        assert!(!destination.exists(), "the refused save wrote a file");
    }

    #[test]
    fn annotations_already_in_the_pdf_cross_the_ffi_intact() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotated.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: annotated fixture or PDFium unavailable");
            return;
        }

        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");
        let records = document.annotations().expect("annotations");
        assert_eq!(
            document
                .annotation_read_status()
                .expect("healthy status")
                .unreadable_annotations,
            0,
            "a fully readable fixture reports no unreadable annotations"
        );

        assert_eq!(records.len(), 7, "five on page 1, two on page 2");
        assert_eq!(
            records
                .iter()
                .map(|record| record.kind.as_str())
                .collect::<Vec<_>>(),
            vec![
                "highlight",
                "underline",
                "strikeout",
                "text",
                "freeText",
                "squiggly",
                "highlight"
            ]
        );

        let highlight = &records[0];
        assert_eq!(highlight.page, 0);
        // View space, top-left origin: `/Rect [72 671 460 701]` on an 842 pt page has its top edge
        // 842 - 701 = 141 pt below the top, and keeps its width and height.
        assert_eq!(highlight.x_pt, 72.0);
        assert_eq!(highlight.y_pt, 842.0 - 701.0);
        assert_eq!(highlight.width_pt, 388.0);
        assert_eq!(highlight.height_pt, 30.0);
        assert_eq!(highlight.quads.len(), 2, "the highlight spans two lines");
        assert_eq!(highlight.quads[1].x_pt, 72.0);
        assert_eq!(highlight.quads[1].y_pt, 842.0 - 686.0);
        assert_eq!(highlight.quads[1].width_pt, 288.0);
        assert_eq!(highlight.quads[1].height_pt, 15.0);

        // The colour the file carries, not a palette index: `/C [0.2 0.6 1]`.
        let color = highlight.color.expect("the highlight has a colour");
        assert_eq!((color.red, color.green, color.blue), (51, 153, 255));
        assert_eq!(highlight.opacity, Some(0.5));
        // The blend mode has to arrive with it: it is what makes the colour look the same here
        // as in the viewer that wrote the file.
        assert_eq!(highlight.blend, "multiply");
        assert_eq!(
            highlight.contents.as_deref(),
            Some("Highlight contents for the round trip.")
        );
        assert_eq!(highlight.author.as_deref(), Some("Reviewer A"));
        assert_eq!(highlight.modified.as_deref(), Some("D:20240102030405Z"));
        assert!(highlight.visible);

        // A sticky note keeps its text and reports no colour rather than inventing black.
        let sticky = &records[3];
        assert_eq!(sticky.kind, "text");
        assert_eq!(sticky.color, None);
        assert_eq!(sticky.contents.as_deref(), Some("A sticky note body."));
        assert_eq!(sticky.author.as_deref(), Some("Reviewer D"));
        // …and it arrives with the reader's own answer about what to do with it, so the shell
        // does not have to re-derive the rule from `kind` (the two drifted apart once already).
        assert_eq!(sticky.drawing, "noteIcon");
        assert_eq!(sticky.skip_reason, None);
        assert_eq!(sticky.alignment, "left", "no /Q is the PDF's own default");
        assert_eq!(sticky.font_size_pt, None, "a sticky note carries no /DA");

        // The free text is the annotation whose layout needs what only the file can say.
        let free_text = &records[4];
        assert_eq!(free_text.kind, "freeText");
        assert_eq!(free_text.drawing, "freeText");
        assert_eq!(free_text.font_size_pt, Some(10.0), "/DA (/Helv 10 Tf 0 g)");
        assert_eq!(free_text.alignment, "left");

        // Every record says either what to draw or why nothing is drawn; a record with neither
        // would be an annotation the reader reports and then loses.
        for record in &records {
            match record.drawing.as_str() {
                "skipped" => assert!(
                    record.skip_reason.is_some(),
                    "{record:?} is skipped without a reason"
                ),
                "markup" | "noteIcon" | "freeText" => assert_eq!(
                    record.skip_reason, None,
                    "{record:?} is drawn and also carries a skip reason"
                ),
                other => panic!("{record:?} has no drawing classification: {other}"),
            }
        }

        // Every record has to be inside its own page: a Y flip that quietly dropped the crop
        // origin would put one of these outside the box.
        let height = document.page_size_pt(0).expect("page size").height_pt;
        for record in &records {
            assert!(
                record.x_pt >= -1.0 && record.x_pt + record.width_pt <= 595.0 + 1.0,
                "{record:?} is outside the page horizontally"
            );
            assert!(
                record.y_pt >= -1.0 && record.y_pt + record.height_pt <= height + 1.0,
                "{record:?} is outside the page vertically"
            );
        }
    }

    /// `/IRT` parent identities cross the FFI, including for a parent on a different page, a
    /// parent the reader does not list, and a malformed two-annotation cycle.
    #[test]
    fn reply_parent_identities_cross_the_ffi() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotated-replies.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: reply fixture or PDFium unavailable");
            return;
        }
        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open reply fixture");
        let records = document.annotations().expect("annotations");

        assert_eq!(
            records.len(),
            11,
            "eight replies and three parents/other marks"
        );
        let by_id: std::collections::HashMap<&str, &AnnotationRecord> = records
            .iter()
            .map(|record| (record.id.as_str(), record))
            .collect();
        assert_eq!(
            by_id.len(),
            records.len(),
            "every annotation gets its own identity"
        );

        let nested = by_id["nm:reply-two"];
        assert!(nested.is_reply);
        assert_eq!(nested.parent_id.as_deref(), Some("nm:reply-one"));
        assert_eq!(
            nested.contents.as_deref(),
            Some("Second-level reply, answering the first reply.")
        );
        assert_eq!(nested.author.as_deref(), Some("Reviewer C"));
        assert_eq!(nested.modified.as_deref(), Some("D:20240102032000Z"));

        // The parent is on page 1, the reply on page 2; the identity is document-wide.
        let cross_page = by_id["nm:reply-cross-page"];
        assert_eq!(cross_page.page, 1);
        assert_eq!(cross_page.parent_id.as_deref(), Some("nm:parent-highlight"));
        assert_eq!(by_id["nm:parent-highlight"].page, 0);

        // A link is not a content annotation, so a reply to one has a parent identity that is
        // absent from the annotation list. The shell reports that as an orphan, not a crash.
        let to_link = by_id["nm:reply-to-link"];
        assert_eq!(to_link.parent_id.as_deref(), Some("nm:structural-parent"));
        assert!(!by_id.contains_key("nm:structural-parent"));

        // A two-annotation cycle arrives as two parent links; detecting it is the shell's job.
        assert_eq!(by_id["nm:cycle-a"].parent_id.as_deref(), Some("nm:cycle-b"));
        assert_eq!(by_id["nm:cycle-b"].parent_id.as_deref(), Some("nm:cycle-a"));

        // The hidden reply without /Contents still crosses the FFI as a reply.
        let empty = by_id["nm:reply-empty"];
        assert!(empty.is_reply && empty.contents.is_none());
        assert_eq!(empty.parent_id.as_deref(), Some("nm:parent-highlight"));
    }

    /// The user's question at the FFI boundary: somebody else's colour is reported as it is.
    #[test]
    fn a_colour_outside_the_palette_survives_the_ffi() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotated.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: annotated fixture or PDFium unavailable");
            return;
        }
        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");
        let records = document.annotations().expect("annotations");

        // The four colours `AppState.highlightPalette` used to be limited to, as RGB.
        let old_palette = [
            (255, 216, 64),
            (112, 208, 96),
            (96, 160, 240),
            (224, 112, 176),
        ];
        let blue = records[0].color.expect("colour");
        assert_eq!((blue.red, blue.green, blue.blue), (51, 153, 255));
        assert!(
            !old_palette.contains(&(blue.red, blue.green, blue.blue)),
            "the fixture's blue is deliberately outside the old palette"
        );
        // …and the same file's other annotations keep their own colours, not this one.
        let red = records[1].color.expect("underline colour");
        assert_eq!((red.red, red.green, red.blue), (229, 25, 25));
    }

    /// The shape Preview writes, at the boundary the shell reads: colour behind an appearance
    /// stream, and a blend mode the annotation dictionary never states.
    ///
    /// Before this was fixed, `FPDFAnnot_GetColor` refused every annotation in
    /// `annotated-appearance.pdf`, `AnnotationRecord::color` came through as `None`, and the
    /// canvas substituted an opaque grey — the highlight covered the text it was meant to tint.
    #[test]
    fn an_appearance_stream_annotation_arrives_with_its_colour_and_blend() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotated-appearance.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: appearance-stream fixture or PDFium unavailable");
            return;
        }
        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");
        let records = document.annotations().expect("annotations");
        assert_eq!(records.len(), 4);

        let highlight = &records[0];
        let color = highlight.color.expect("the highlight's /C is readable");
        assert_eq!((color.red, color.green, color.blue), (255, 255, 0));
        let opacity = highlight.opacity.expect("/CA 0.968627");
        assert!(
            (opacity - 0.968627).abs() < 1e-6,
            "/CA arrives exactly: {opacity}"
        );
        assert_eq!(
            highlight.blend, "multiply",
            "the shell draws through the multiply pipeline, not over the glyphs"
        );

        // A highlight whose colour the file never states: no colour, but the opacity is still
        // the file's, and the shell draws a neutral tint with it rather than an opaque bar.
        let colourless = &records[2];
        assert_eq!(colourless.color, None);
        assert_eq!(colourless.blend, "multiply");
        let opacity = colourless.opacity.expect("/CA 0.35");
        assert!(
            (opacity - 0.35).abs() < 1e-6,
            "/CA arrives exactly: {opacity}"
        );
    }

    #[test]
    fn outline_is_reported_flat_with_depths() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/multipage.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        // The fixture has no bookmarks, so the contract to pin down is "no outline is an
        // empty list, not an error" plus well-formed entries when there are some.
        let entries = document.outline().expect("outline");
        for entry in &entries {
            assert!(!entry.title.is_empty() || entry.page.is_some());
            assert!(
                entry.depth < 32,
                "implausible nesting depth {}",
                entry.depth
            );
            if let Some(page) = entry.page {
                assert!(page < document.page_count());
            }
        }
    }

    /// The outline fixture is three levels deep, and one section has no destination but does
    /// have children. `flatten_outline` has always carried a `depth`; before this fixture the
    /// backend put every bookmark at depth 0, so the sidebar could not number a hierarchy at all.
    #[test]
    fn outline_keeps_three_levels_and_a_section_without_a_page() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/outlined.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: outline fixture or PDFium unavailable");
            return;
        }
        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open outline fixture");
        let entries = document.outline().expect("outline");

        assert_eq!(
            entries
                .iter()
                .map(|entry| (entry.title.as_str(), entry.depth, entry.page))
                .collect::<Vec<_>>(),
            vec![
                ("Chapter One", 0, Some(0)),
                ("Background", 1, Some(0)),
                ("Prior work", 2, Some(1)),
                ("Chapter Two", 0, None),
                ("Method", 1, Some(1)),
                ("Detail", 2, Some(2)),
                ("Setup", 1, Some(2)),
                ("Chapter Three", 0, Some(2)),
            ],
            "the fixture's outline, depth-first with its real depths"
        );
    }

    #[test]
    fn search_finds_text_across_pages() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/multipage.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        // Every page of this fixture carries "Page N of 3".
        let hits = document.search("page".to_string(), 50).expect("search");
        assert!(hits.len() >= 3, "only {} hits", hits.len());
        assert_eq!(hits[0].page, 0, "hits come back in reading order");
        assert!(
            hits.iter().any(|hit| hit.page == 2),
            "page 3 was not searched"
        );
        assert!(hits[0].end > hits[0].start);
        assert!(!hits[0].snippet.is_empty());

        // A pattern that cannot occur returns nothing rather than erroring.
        assert!(
            document
                .search("zzzzz".to_string(), 50)
                .expect("search")
                .is_empty()
        );
        assert!(
            document
                .search("   ".to_string(), 50)
                .expect("blank")
                .is_empty()
        );
    }

    #[test]
    fn deep_zoom_is_clamped_to_the_page_budget() {
        let budget = EngineConfig::default().full_page_max_pixels as f64;

        // 400% on A4 is 2380x3368 = 8 MP, which still fits the 16.7 MP budget: untouched.
        assert_eq!(clamp_scale((595.0, 842.0), 4.0), 4.0);

        // 800% is 32 MP, so the scale comes down until the page fits (rounding the pixel
        // dimensions up can leave a few hundred pixels over, hence the 1% tolerance).
        let clamped = clamp_scale((595.0, 842.0), 8.0);
        assert!(clamped < 8.0, "scale should be reduced, got {clamped}");
        let pixels = 595.0 * clamped * 842.0 * clamped;
        assert!(
            pixels <= budget * 1.01,
            "clamped page is still {pixels:.0} px"
        );

        // The edge cap covers long, narrow pages whose pixel count alone would pass.
        let narrow = clamp_scale((20.0, 20_000.0), 1.0);
        assert!(
            20_000.0 * narrow <= MAX_PAGE_EDGE_PX * 1.01,
            "edge not clamped: {narrow}"
        );
    }

    #[test]
    fn rasterizing_a_fixture_page_reports_the_scale_used() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/text-page.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        let bitmap = document.rasterize_page(0, 2.0).expect("rasterize");
        assert_eq!(
            bitmap.scale_used, 2.0,
            "a normal request must not be clamped"
        );
        assert_eq!(bitmap.width_px, 1190);
        assert_eq!(bitmap.height_px, 1684);

        let huge = document.rasterize_page(0, 8.0).expect("rasterize huge");
        assert!(huge.scale_used < 8.0, "deep zoom must be clamped");
        let pixels = u64::from(huge.width_px) * u64::from(huge.height_px);
        let budget = EngineConfig::default().full_page_max_pixels;
        assert!(
            pixels <= budget + budget / 100,
            "clamped page is {pixels} px"
        );

        let region = document
            .rasterize_region(0, 1000.0, 0.0, 0.0, 595.0, 842.0, false)
            .expect("rasterize bounded region");
        assert!(region.scale_used < 1000.0);
        assert_eq!((region.width_pt, region.height_pt), (595.0, 842.0));
        let region_pixels = u64::from(region.width_px) * u64::from(region.height_px);
        assert!(
            region_pixels <= budget + budget / 100,
            "clamped region is {region_pixels} px"
        );

        assert!(matches!(
            document.rasterize_region(0, 1.0, f64::NAN, 0.0, 10.0, 10.0, false),
            Err(LyraReaderFfiError::InvalidArgument { .. })
        ));
        assert!(matches!(
            document.rasterize_region(0, 1.0, 0.0, 0.0, f64::INFINITY, 10.0, false),
            Err(LyraReaderFfiError::InvalidArgument { .. })
        ));
        assert!(matches!(
            document.rasterize_region(0, 1.0, 0.0, 0.0, 10_000.0, 10.0, false),
            Err(LyraReaderFfiError::InvalidArgument { .. })
        ));

        // The transparent crop path: the page's unpainted paper becomes alpha 0 while the
        // fixture's black text stays opaque. This is the flag the figure preview asks for.
        let transparent = document
            .rasterize_region(0, 1.0, 0.0, 0.0, 595.0, 842.0, true)
            .expect("rasterize transparent region");
        let pixels = transparent.pixels.as_chunks::<4>().0;
        assert!(
            pixels.iter().any(|pixel| pixel[3] == 0),
            "transparent crop must leave the paper clear"
        );
        assert!(
            pixels
                .iter()
                .any(|pixel| pixel[3] == 255 && pixel[0] < 32 && pixel[1] < 32 && pixel[2] < 32),
            "transparent crop must keep the fixture's black text opaque"
        );
    }

    /// The thumbnail path asks PDFium to burn the file's annotations into the raster; the canvas
    /// path must keep asking for a plain page. `annotated-appearance.pdf`'s highlight carries an
    /// `/AP` (the shape Preview writes) and paints yellow, which the fixture's black text and blue
    /// page border cannot produce.
    #[test]
    fn the_thumbnail_raster_carries_the_files_marks() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotated-appearance.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: annotated fixture or PDFium unavailable");
            return;
        }
        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(fixture.display().to_string(), None)
            .expect("open fixture");

        let plain = document.rasterize_page(0, 1.0).expect("plain page");
        let marked = document
            .rasterize_page_with_annotations(0, 1.0)
            .expect("thumbnail page");
        assert_eq!(
            (plain.width_px, plain.height_px),
            (marked.width_px, marked.height_px)
        );
        assert_ne!(
            plain.pixels, marked.pixels,
            "the annotated raster must differ from the plain one"
        );

        // BGRA. The yellow highlight covers the first body line; the page's own blue rectangle
        // is at a different height, so limiting the sample to the highlight's box distinguishes
        // the mark from the page artwork. The highlight's view-space box is x 72…460, y 141…156.
        let width = marked.width_px as usize;
        let yellow_in_highlight = |pixels: &[u8]| {
            let mut count = 0;
            for y in 141..=156 {
                for x in 72..=460 {
                    let offset = (y * width + x) * 4;
                    let (b, g, r) = (
                        u16::from(pixels[offset]),
                        u16::from(pixels[offset + 1]),
                        u16::from(pixels[offset + 2]),
                    );
                    if r > 200 && g > 180 && b < 150 {
                        count += 1;
                    }
                }
            }
            count
        };
        assert!(
            yellow_in_highlight(&marked.pixels) > 100,
            "the thumbnail carries the highlight ({} yellow pixels)",
            yellow_in_highlight(&marked.pixels)
        );
        assert_eq!(
            yellow_in_highlight(&plain.pixels),
            0,
            "the canvas raster must stay annotation-free"
        );
    }

    #[test]
    fn probing_the_fixture_reports_an_a4_page() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/text-page.pdf");
        if !fixture.exists() || !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: fixture or PDFium unavailable");
            return;
        }

        let engine = LyraReaderEngine::new();
        let summary = engine
            .probe_document(fixture.display().to_string(), None)
            .expect("probe fixture");

        assert_eq!(summary.page_count, 1);
        assert_eq!(summary.first_page_width_pt, 595.0);
        assert_eq!(summary.first_page_height_pt, 842.0);
        assert_eq!(summary.rotation_degrees, 0);
        assert!(!summary.is_encrypted);
    }

    // ── Annotation write-back ──────────────────────────────────────────────────────────

    /// A scratch copy of the committed annotated fixture, or `None` when PDFium is absent.
    fn writeback_fixture(name: &str) -> Option<ScratchDir> {
        if !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return None;
        }
        let directory = scratch(name);
        let copy = directory.join("source.pdf");
        std::fs::copy(fixture("annotated.pdf"), &copy).expect("copy fixture");
        Some(directory)
    }

    fn zoom_annotation(zoom: f64) -> WriteAnnotationRecord {
        let box_at_zoom = |x: f64, y: f64, width: f64, height: f64| AnnotationQuad {
            x_pt: x * zoom,
            y_pt: y * zoom,
            width_pt: width * zoom,
            height_pt: height * zoom,
        };
        WriteAnnotationRecord {
            id: "33333333-3333-3333-3333-333333333333".to_string(),
            page: 0,
            kind: AnnotationWriteKind::Highlight,
            rect: box_at_zoom(72.0, 141.0, 388.0, 15.0),
            // View space at 100% is page space y-flipped: page [72 686 388 15] on an 842 pt
            // page is view (72, 842 - 686 - 15) = (72, 141).
            quads: vec![box_at_zoom(72.0, 141.0, 388.0, 15.0)],
            ink_paths: Vec::new(),
            line_start: None,
            line_end: None,
            line_arrow: false,
            border_width_pt: 0.0,
            color: AnnotationColorRecord {
                red: 255,
                green: 216,
                blue: 64,
            },
            opacity: 0.4,
            contents: "Saved at an arbitrary zoom.".to_string(),
            author: "LyraReader".to_string(),
            modified: "D:20261016213000-07'00'".to_string(),
            font_size_pt: 0.0,
            text_alignment: "left".to_string(),
            stamp_style: String::new(),
            signature_width: 0,
            signature_height: 0,
            signature_rgba: Vec::new(),
        }
    }

    fn zoom_stroke(zoom: f64) -> WriteAnnotationRecord {
        let point = |x: f64, y: f64| AnnotationPoint {
            x_pt: x * zoom,
            y_pt: y * zoom,
        };
        let box_at_zoom = |x: f64, y: f64, width: f64, height: f64| AnnotationQuad {
            x_pt: x * zoom,
            y_pt: y * zoom,
            width_pt: width * zoom,
            height_pt: height * zoom,
        };
        WriteAnnotationRecord {
            id: "44444444-4444-4444-4444-444444444444".to_string(),
            page: 0,
            kind: AnnotationWriteKind::Ink,
            // The outer box at view 100%: page [72 600 200 60] on an 842 pt page is
            // view (72, 842 - 600 - 60) = (72, 182), inflated by the stroke's half width.
            rect: box_at_zoom(72.0, 181.0, 201.0, 61.0),
            quads: Vec::new(),
            ink_paths: vec![vec![
                point(73.0, 182.0),
                point(120.0, 220.0),
                point(180.0, 190.0),
                point(272.0, 240.0),
            ]],
            line_start: None,
            line_end: None,
            line_arrow: false,
            border_width_pt: 2.5,
            color: AnnotationColorRecord {
                red: 220,
                green: 40,
                blue: 30,
            },
            opacity: 0.8,
            contents: "Stroked at an arbitrary zoom.".to_string(),
            author: "LyraReader".to_string(),
            modified: "D:20261017120000-07'00'".to_string(),
            font_size_pt: 0.0,
            text_alignment: "left".to_string(),
            stamp_style: String::new(),
            signature_width: 0,
            signature_height: 0,
            signature_rgba: Vec::new(),
        }
    }

    #[test]
    fn write_back_converts_view_space_at_any_zoom_to_the_same_page_space() {
        let Some(directory) = writeback_fixture("zoom") else {
            return;
        };
        let engine = LyraReaderEngine::new();
        let source = directory.join("source.pdf");
        let document = engine
            .open_document(source.display().to_string(), None)
            .expect("open source");
        assert_eq!(document.annotations().expect("annotations").len(), 7);
        let source_bytes = std::fs::read(&source).expect("source readable");

        assert!(
            document
                .suggested_copy_path()
                .ends_with("source (annotated).pdf"),
            "the suggested name is <name> (annotated).pdf"
        );

        let at_100 = directory.join("at-100.pdf");
        let at_300 = directory.join("at-300.pdf");
        let report_100 = document
            .save_annotations_copy(
                at_100.display().to_string(),
                vec![zoom_annotation(1.0)],
                Vec::new(),
                1.0,
            )
            .expect("save at 100%");
        let report_300 = document
            .save_annotations_copy(
                at_300.display().to_string(),
                vec![zoom_annotation(3.0)],
                Vec::new(),
                3.0,
            )
            .expect("save at 300%");

        assert_eq!(report_100.written_ids, vec![zoom_annotation(1.0).id]);
        assert_eq!(report_100.backup_path, None);
        assert_eq!(report_100.preexisting_annotation_count, 7);
        assert!(report_100.appended_bytes > 0);
        assert!(report_100.source_bytes_preserved);
        assert_eq!(
            std::fs::read(&source).expect("source readable"),
            source_bytes,
            "a copy save leaves the open document untouched"
        );
        assert_eq!(report_300.preexisting_annotation_count, 7);

        // The two saves were made from different view-space geometry and zoom factors. Their
        // page-space output must be identical, which is the promise that a highlight saved at
        // one zoom reloads in the same place at another.
        let page_space = |path: &std::path::Path| {
            let backend = PdfiumBackend::open(path, None).expect("reopen saved copy");
            let annotations = backend.annotations(PageIndex(0)).expect("page annotations");
            annotations
                .into_iter()
                .find(|annotation| annotation.id == "nm:33333333-3333-3333-3333-333333333333")
                .expect("written annotation")
        };
        let first = page_space(&at_100);
        let second = page_space(&at_300);
        assert_eq!(first, second, "zoom must not change page-space geometry");
        assert_eq!(
            first.rect,
            lyra_reader_core::Rect::new(72.0, 686.0, 388.0, 15.0)
        );
        assert_eq!(
            first.quads,
            vec![lyra_reader_core::Rect::new(72.0, 686.0, 388.0, 15.0)]
        );

        // Reopening through the FFI at "another zoom" is the same file-space geometry: the
        // reader reports view space at 100%, and the canvas scales it. Both saved files agree
        // with the original view box, so the annotation reloads at the same place.
        for path in [&at_100, &at_300] {
            let reopened = engine
                .open_document(path.display().to_string(), None)
                .expect("reopen saved copy");
            let records = reopened.annotations().expect("annotations");
            let ours: Vec<_> = records
                .iter()
                .filter(|record| record.id == "nm:33333333-3333-3333-3333-333333333333")
                .collect();
            assert_eq!(ours.len(), 1, "exactly one copy of the written annotation");
            assert!((ours[0].x_pt - 72.0).abs() < 1e-6);
            assert!((ours[0].y_pt - 141.0).abs() < 1e-6);
            assert!((ours[0].width_pt - 388.0).abs() < 1e-6);
            assert!((ours[0].height_pt - 15.0).abs() < 1e-6);
            assert_eq!(
                ours[0].contents.as_deref(),
                Some("Saved at an arbitrary zoom.")
            );
            assert_eq!(ours[0].author.as_deref(), Some("LyraReader"));
            assert_eq!(ours[0].blend, "multiply");
        }

        let bad_zoom = document.save_annotations_copy(
            directory.join("bad.pdf").display().to_string(),
            vec![zoom_annotation(1.0)],
            Vec::new(),
            0.0,
        );
        assert!(bad_zoom.is_err(), "a zero zoom is refused before any write");

        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn stroke_write_back_converts_view_space_at_any_zoom_to_the_same_page_space() {
        let Some(directory) = writeback_fixture("stroke-zoom") else {
            return;
        };
        let engine = LyraReaderEngine::new();
        let source = directory.join("source.pdf");
        let document = engine
            .open_document(source.display().to_string(), None)
            .expect("open source");
        let at_100 = directory.join("stroke-100.pdf");
        let at_300 = directory.join("stroke-300.pdf");
        document
            .save_annotations_copy(
                at_100.display().to_string(),
                vec![zoom_stroke(1.0)],
                Vec::new(),
                1.0,
            )
            .expect("save stroke at 100%");
        document
            .save_annotations_copy(
                at_300.display().to_string(),
                vec![zoom_stroke(3.0)],
                Vec::new(),
                3.0,
            )
            .expect("save stroke at 300%");

        let page_space = |path: &std::path::Path| {
            let backend = PdfiumBackend::open(path, None).expect("reopen saved copy");
            backend
                .annotations(PageIndex(0))
                .expect("page annotations")
                .into_iter()
                .find(|annotation| annotation.id == "nm:44444444-4444-4444-4444-444444444444")
                .expect("written stroke")
        };
        let first = page_space(&at_100);
        let second = page_space(&at_300);
        assert_eq!(
            first, second,
            "zoom must not change the stroke's page-space points"
        );
        assert_eq!(first.kind, lyra_reader_core::RawAnnotationKind::Ink);
        assert_eq!(first.ink_paths.len(), 1);
        let expected = [
            (73.0, 182.0),
            (120.0, 220.0),
            (180.0, 190.0),
            (272.0, 240.0),
        ];
        for (point, (x, y)) in first.ink_paths[0].iter().zip(expected) {
            // The view points above are page-space top-left; the writer's inverse flips them
            // back into PDF page space, so compare the y flip explicitly.
            assert!((point.x - x).abs() < 0.01, "{point:?} vs {x}");
            assert!((point.y - (842.0 - y)).abs() < 0.01, "{point:?} vs {y}");
        }
        assert_eq!(first.border_width, Some(2.5));
        assert!((first.opacity.expect("opacity") - 0.8).abs() < 0.01);
        let _ = std::fs::remove_dir_all(directory);
    }

    #[test]
    fn replacing_the_fixture_reports_a_verified_backup_and_reopens_once() {
        let Some(directory) = writeback_fixture("replace") else {
            return;
        };
        let engine = LyraReaderEngine::new();
        let source = directory.join("source.pdf");
        let document = engine
            .open_document(source.display().to_string(), None)
            .expect("open source");
        let original = std::fs::read(&source).expect("source readable");

        // A next-open report can only be produced from a leftover temporary, and must not
        // change the document.
        let stale = directory.join("source.pdf.lyra-reader-save-42-1.tmp");
        std::fs::write(&stale, b"partial").expect("write stale temp");
        let note = document
            .interrupted_save_note()
            .expect("interrupted save is reported");
        assert!(note.contains("interrupted"), "{note}");
        std::fs::remove_file(&stale).expect("remove stale temp");
        assert!(document.interrupted_save_note().is_none());

        let report = document
            .replace_with_annotations(vec![zoom_annotation(1.0)], Vec::new(), 1.0)
            .expect("replace original");
        let backup = report.backup_path.expect("backup path");
        let backup_bytes = std::fs::read(&backup).expect("backup readable");
        assert_eq!(
            backup_bytes, original,
            "the backup is byte-identical to the original"
        );
        assert!(
            document.annotations().is_err(),
            "reads from the pre-replacement document are refused until the shell reopens it"
        );

        let reopened = engine
            .open_document(source.display().to_string(), None)
            .expect("reopen replaced source");
        let records = reopened.annotations().expect("annotations");
        assert_eq!(
            records.len(),
            8,
            "the seven pre-existing content annotations plus the new one"
        );
        assert_eq!(
            records
                .iter()
                .filter(|record| record.id == "nm:33333333-3333-3333-3333-333333333333")
                .count(),
            1,
            "the saved annotation appears exactly once"
        );
        assert!(
            std::fs::read(&source)
                .expect("replaced source")
                .starts_with(&original),
            "the replaced file still begins with the original bytes"
        );

        let _ = std::fs::remove_dir_all(directory);
    }

    // ── Bookmark outline write-back ────────────────────────────────────────────────────

    fn bookmark_record(id: &str, page: u32, title: &str, y_pt: f64) -> WriteBookmarkRecord {
        WriteBookmarkRecord {
            id: id.to_string(),
            page,
            title: title.to_string(),
            y_pt,
        }
    }

    #[test]
    fn bookmarks_are_written_as_an_outline_subtree_and_read_back_with_identity_and_position() {
        if !lyra_reader_pdfium::is_available() {
            eprintln!("skipping: PDFium unavailable");
            return;
        }
        let directory = scratch("bookmark-outline");
        let source = directory.join("outlined.pdf");
        std::fs::copy(fixture("outlined.pdf"), &source).expect("copy outlined fixture");
        let source_bytes = std::fs::read(&source).expect("source readable");

        let engine = LyraReaderEngine::new();
        let document = engine
            .open_document(source.display().to_string(), None)
            .expect("open outlined fixture");
        assert_eq!(
            document.outline().expect("outline").len(),
            8,
            "the fixture's own outline"
        );

        let bookmarks = vec![
            bookmark_record("11111111-1111-1111-1111-111111111101", 0, "Alpha", 120.0),
            bookmark_record("11111111-1111-1111-1111-111111111102", 1, "Beta", 340.0),
            bookmark_record("11111111-1111-1111-1111-111111111103", 2, "Gamma", 50.0),
        ];
        let saved = directory.join("saved.pdf");
        let report = document
            .save_annotations_copy(
                saved.display().to_string(),
                Vec::new(),
                bookmarks.clone(),
                1.0,
            )
            .expect("a document with only bookmarks can still be saved");
        assert_eq!(
            report.written_bookmark_ids,
            bookmarks.iter().map(|b| b.id.clone()).collect::<Vec<_>>()
        );
        assert_eq!(report.preexisting_outline_entry_count, 8);
        assert_eq!(
            report.bookmark_outline_title.as_deref(),
            Some("My bookmarks")
        );
        assert_eq!(
            std::fs::read(&source).expect("source readable"),
            source_bytes,
            "a copy save leaves the open document untouched"
        );

        let reopened = engine
            .open_document(saved.display().to_string(), None)
            .expect("reopen saved copy");
        let entries = reopened.outline().expect("outline after saving");
        assert_eq!(entries.len(), 12, "eight of the document's, four of ours");
        assert_eq!(
            &entries[..8],
            &document.outline().expect("original outline")[..]
        );
        assert_eq!(entries[8].title, "My bookmarks");
        assert_eq!(entries[8].depth, 0);
        assert_eq!(
            entries[9..]
                .iter()
                .map(|entry| entry.title.as_str())
                .collect::<Vec<_>>(),
            vec!["Alpha", "Beta", "Gamma"]
        );
        assert!(entries[9..].iter().all(|entry| entry.depth == 1));
        assert_eq!(
            entries[9..]
                .iter()
                .map(|entry| entry.page)
                .collect::<Vec<_>>(),
            vec![Some(0), Some(1), Some(2)]
        );
        assert_eq!(
            entries[9..]
                .iter()
                .map(|entry| entry.bookmark_id.clone())
                .collect::<Vec<_>>(),
            bookmarks
                .iter()
                .map(|bookmark| Some(bookmark.id.clone()))
                .collect::<Vec<_>>(),
            "the reader adopts the file's bookmark identities"
        );
        for (entry, expected) in entries[9..].iter().zip(&bookmarks) {
            let y = entry.y_pt.expect("page-local position");
            assert!(
                (y - expected.y_pt).abs() <= 0.01,
                "{} lands at its page-local Y, got {y}",
                expected.id
            );
        }

        // Saving the reopened copy again rewrites the same subtree; it cannot accumulate.
        let again = directory.join("saved-again.pdf");
        let reopened_bookmarks: Vec<WriteBookmarkRecord> = entries[9..]
            .iter()
            .map(|entry| {
                bookmark_record(
                    entry.bookmark_id.as_deref().expect("bookmark id"),
                    entry.page.expect("page"),
                    &entry.title,
                    entry.y_pt.unwrap_or(0.0),
                )
            })
            .collect();
        reopened
            .save_annotations_copy(
                again.display().to_string(),
                Vec::new(),
                reopened_bookmarks,
                1.0,
            )
            .expect("second save");
        let second = engine
            .open_document(again.display().to_string(), None)
            .expect("reopen second save");
        let second_entries = second.outline().expect("outline of second save");
        assert_eq!(second_entries.len(), 12);
        assert_eq!(
            second_entries
                .iter()
                .filter(|entry| entry.title == "My bookmarks")
                .count(),
            1,
            "one subtree, not two"
        );
    }

    /// The FFI table is a projection of the taxonomy, not a second list of kind names.
    ///
    /// The shell compares the same rows with `AppState.Annotation.Kind`, so between the two
    /// checks a cache kind cannot exist on one side only, and a renamed wire value fails here
    /// rather than reaching `AnnotationRecordRules.flags`, which traps.
    #[test]
    fn the_kind_table_projects_every_cache_kind_once() {
        let rows = annotation_kind_flags();
        assert_eq!(rows.len(), TaxonomyKind::RECORD_KINDS.len());
        let kinds: Vec<&str> = rows.iter().map(|row| row.kind.as_str()).collect();
        assert_eq!(
            kinds.iter().collect::<std::collections::HashSet<_>>().len(),
            kinds.len(),
            "each cache kind appears once: {kinds:?}"
        );
        for kind in TaxonomyKind::RECORD_KINDS {
            let record_name = kind.record_name().expect("a cache kind is named");
            let row = rows
                .iter()
                .find(|row| row.record_kind.as_deref() == Some(record_name))
                .unwrap_or_else(|| panic!("no row for {kind:?}"));
            assert_eq!(row.kind, record_name);
            assert_eq!(row.document_kind, kind.document_name());
            if *kind != TaxonomyKind::Signature {
                // A `/Stamp` is the one subtype whose cache kind depends on the instance (words
                // or a picture), so its document name cannot round-trip to `signature`.
                assert_eq!(
                    document_annotation_kind_flags(kind.document_name().to_string()).record_kind,
                    Some(record_name.to_string()),
                    "{kind:?}"
                );
            }
        }
        assert_eq!(
            document_annotation_kind_flags("stamp".to_string()).record_kind,
            Some("stamp".to_string())
        );
    }
}

#[cfg(test)]
mod ai_code_tests {
    use super::*;
    use lyra_reader_ai::AiError;

    #[test]
    fn the_stable_code_comes_from_the_error_variant_not_its_message() {
        let cases = [
            (AiError::NotConfigured, AiErrorCode::NotConfigured),
            (
                AiError::Unreachable("refused".into()),
                AiErrorCode::Unreachable,
            ),
            (AiError::Offline("no route".into()), AiErrorCode::Offline),
            (
                AiError::LocalServer("nothing listening".into()),
                AiErrorCode::LocalServer,
            ),
            (AiError::Unauthorized, AiErrorCode::Unauthorized),
            (AiError::RateLimited, AiErrorCode::RateLimited),
            (AiError::Cancelled, AiErrorCode::Cancelled),
            (
                AiError::UnsupportedCapability("image input"),
                AiErrorCode::UnsupportedCapability,
            ),
            (
                AiError::InvalidSettings("The model is not usable.".into()),
                AiErrorCode::InvalidSettings,
            ),
            (
                AiError::EmptyContext("This document has no pages.".into()),
                AiErrorCode::EmptyContext,
            ),
            (
                AiError::HttpStatus("HTTP 500".into()),
                AiErrorCode::HttpStatus,
            ),
            (
                AiError::Protocol("bad stream".into()),
                AiErrorCode::Protocol,
            ),
            (AiError::Timeout("too long".into()), AiErrorCode::Timeout),
            (AiError::Other("anything".into()), AiErrorCode::Other),
        ];
        for (error, code) in cases {
            assert_eq!(AiErrorCode::of(&error), code, "{error:?}");
        }
        assert_eq!(
            AiErrorCode::of(&AiError::EmptyContext(NOTHING_RELEVANT_MESSAGE.into())),
            AiErrorCode::NothingRelevant
        );
        assert_eq!(
            AiErrorCode::of(&AiError::EmptyContext(
                "Turn on image input in Settings > AI.".into()
            )),
            AiErrorCode::VisionUnsupported
        );
    }

    #[test]
    fn the_ffi_error_carries_the_message_unchanged_and_the_code_beside_it() {
        let converted: LyraReaderFfiError =
            AiError::Timeout("The stream took too long.".into()).into();
        match converted {
            LyraReaderFfiError::Ai { message, code, .. } => {
                assert_eq!(code, AiErrorCode::Timeout);
                assert_eq!(message, "The stream took too long.");
            }
            other => panic!("expected an AI error, got {other:?}"),
        }
    }
}

#[cfg(test)]
mod content_command_tests {
    use super::*;
    use lyra_reader_pdfium::content_edit::{ContentBox, ContentCommand};

    fn revision() -> String {
        "sha256:the-page-revision".into()
    }

    /// Every typed variant must produce exactly the engine variant and payload it replaced.
    ///
    /// The expected values are written literally rather than round-tripped through the record, so
    /// a renamed, dropped or added field fails here even when the conversion itself was updated
    /// consistently.
    #[test]
    fn every_content_command_record_maps_to_its_engine_command() {
        let bounds = ContentBoxRecord {
            x: 12.5,
            y: -3.25,
            width: 40.0,
            height: 18.0,
        };
        let crop = ContentBoxRecord {
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.4,
        };
        let cases: Vec<(ContentCommandRecord, ContentCommand)> = vec![
            (
                ContentCommandRecord::Transform {
                    revision: revision(),
                    target: "1.2".into(),
                    bounds,
                    rotation: 12.5,
                },
                ContentCommand::Transform {
                    revision: revision(),
                    target: "1.2".into(),
                    bounds: ContentBox {
                        x: 12.5,
                        y: -3.25,
                        width: 40.0,
                        height: 18.0,
                    },
                    rotation: 12.5,
                },
            ),
            (
                ContentCommandRecord::ReplaceText {
                    revision: revision(),
                    target: "2".into(),
                    text: "new words".into(),
                    bounds,
                    font: "Helvetica".into(),
                    size: 11.5,
                    colour: vec![10, 20, 30, 40],
                    alignment: 2,
                },
                ContentCommand::ReplaceText {
                    revision: revision(),
                    target: "2".into(),
                    text: "new words".into(),
                    bounds: ContentBox {
                        x: 12.5,
                        y: -3.25,
                        width: 40.0,
                        height: 18.0,
                    },
                    font: "Helvetica".into(),
                    size: 11.5,
                    colour: [10, 20, 30, 40],
                    alignment: 2,
                },
            ),
            (
                ContentCommandRecord::InsertText {
                    revision: revision(),
                    text: "inserted".into(),
                    bounds,
                    font: "Original".into(),
                    size: 9.0,
                    colour: vec![0, 0, 0, 255],
                    alignment: 0,
                },
                ContentCommand::InsertText {
                    revision: revision(),
                    text: "inserted".into(),
                    bounds: ContentBox {
                        x: 12.5,
                        y: -3.25,
                        width: 40.0,
                        height: 18.0,
                    },
                    font: "Original".into(),
                    size: 9.0,
                    colour: [0, 0, 0, 255],
                    alignment: 0,
                },
            ),
            (
                ContentCommandRecord::Delete {
                    revision: revision(),
                    target: "3.1".into(),
                },
                ContentCommand::Delete {
                    revision: revision(),
                    target: "3.1".into(),
                },
            ),
            (
                ContentCommandRecord::Redact {
                    revision: revision(),
                    bounds,
                    blackout: true,
                },
                ContentCommand::Redact {
                    revision: revision(),
                    bounds: ContentBox {
                        x: 12.5,
                        y: -3.25,
                        width: 40.0,
                        height: 18.0,
                    },
                    blackout: true,
                },
            ),
            (
                ContentCommandRecord::InsertImage {
                    revision: revision(),
                    bounds,
                    image_path: "/tmp/insert.png".into(),
                },
                ContentCommand::InsertImage {
                    revision: revision(),
                    bounds: ContentBox {
                        x: 12.5,
                        y: -3.25,
                        width: 40.0,
                        height: 18.0,
                    },
                    image_path: "/tmp/insert.png".into(),
                },
            ),
            (
                ContentCommandRecord::ReplaceImage {
                    revision: revision(),
                    target: "4".into(),
                    image_path: "/tmp/replace.png".into(),
                },
                ContentCommand::ReplaceImage {
                    revision: revision(),
                    target: "4".into(),
                    image_path: "/tmp/replace.png".into(),
                },
            ),
            (
                ContentCommandRecord::CropImage {
                    revision: revision(),
                    target: "5".into(),
                    crop,
                },
                ContentCommand::CropImage {
                    revision: revision(),
                    target: "5".into(),
                    crop: ContentBox {
                        x: 0.1,
                        y: 0.2,
                        width: 0.3,
                        height: 0.4,
                    },
                },
            ),
            (
                ContentCommandRecord::SetLink {
                    revision: revision(),
                    target: Some("6".into()),
                    bounds,
                    page: Some(7),
                    uri: Some("https://example.test/".into()),
                },
                ContentCommand::SetLink {
                    revision: revision(),
                    target: Some("6".into()),
                    bounds: ContentBox {
                        x: 12.5,
                        y: -3.25,
                        width: 40.0,
                        height: 18.0,
                    },
                    page: Some(7),
                    uri: Some("https://example.test/".into()),
                },
            ),
            (
                ContentCommandRecord::SetLink {
                    revision: revision(),
                    target: None,
                    bounds,
                    page: None,
                    uri: None,
                },
                ContentCommand::SetLink {
                    revision: revision(),
                    target: None,
                    bounds: ContentBox {
                        x: 12.5,
                        y: -3.25,
                        width: 40.0,
                        height: 18.0,
                    },
                    page: None,
                    uri: None,
                },
            ),
        ];
        for (record, expected) in cases {
            assert_eq!(
                content_command(record.clone()).expect("a well-formed record converts"),
                expected,
                "{record:?}"
            );
        }
    }

    #[test]
    fn a_content_colour_must_have_exactly_four_components() {
        let bounds = ContentBoxRecord {
            x: 0.0,
            y: 0.0,
            width: 1.0,
            height: 1.0,
        };
        for colour in [vec![], vec![0, 0, 0], vec![0, 0, 0, 0, 0]] {
            let command = ContentCommandRecord::InsertText {
                revision: revision(),
                text: "x".into(),
                bounds,
                font: "Helvetica".into(),
                size: 12.0,
                colour,
                alignment: 0,
            };
            match content_command(command) {
                Err(LyraReaderFfiError::InvalidArgument { severity, message }) => {
                    assert_eq!(severity, ErrorSeverity::Document);
                    assert!(message.contains("exactly four components"), "{message}");
                }
                other => panic!("expected an invalid-argument error, got {other:?}"),
            }
        }
    }
}

//! The page-edit transaction FFI object.
//!
//! This is the shell's one handle on a page-editing session: start (fresh or from recovery),
//! apply, undo, redo, snapshot and close. The state machine, the revision chain and the recovery
//! manifest live in [`lyra_reader_edit::transaction`]; this module is the PDFium/UniFFI edge:
//! it stages the operation on the current revision with `lyra-reader-pdfium`, hands the verified
//! report to the transaction, and converts the transaction's state to a UniFFI record.
//!
//! The shell keeps opening the revision it renders and keeps its annotation model; the
//! transaction owns only the session state that used to live in `AppState`.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use lyra_reader_core::sync::lock;
use lyra_reader_core::{ErrorCode, LyraReaderError};
use lyra_reader_edit::transaction::{
    AnnotationState, AnnotationStateJson, DocumentTransaction, PageOperationReport, StartRequest,
};
use lyra_reader_pdfium::stage_page_operation;

use crate::api::{ErrorSeverity, LyraReaderFfiError, PageOperationRecord, page_operation};

/// Retargets a legacy-layout `session.json` into the current `DocumentId` cache directory.
///
/// The old cache was keyed by the canonical path alone; its manifest names that old directory,
/// and the restore path deliberately rejects a session directory outside the cache prefix. This
/// wrapper exposes the pure string rewriting in `lyra-reader-edit` so the shell can migrate the
/// manifest after copying the session files. It does no file I/O: a failure leaves the caller's
/// files exactly where they are.
#[uniffi::export]
pub fn retarget_recovery_manifest(
    manifest_json: String,
    old_directory_url: String,
    new_directory_url: String,
) -> Result<String, LyraReaderFfiError> {
    lyra_reader_edit::transaction::retarget_recovery_manifest(
        &manifest_json,
        &old_directory_url,
        &new_directory_url,
    )
    .map_err(document_error)
}

/// Everything the shell knows when it prepares a page-editing session, plus the pieces needed to
/// restore one from `session.json`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DocumentTransactionStartRecord {
    /// The PDF the session started from (Foundation `file://` URL).
    pub original_url: String,
    /// The freshly created session directory (Foundation `file://` URL, trailing slash).
    pub directory_url: String,
    /// The document-cache `session.json` this session writes.
    pub recovery_path: String,
    /// The original document's annotation cache path.
    pub original_records_url: String,
    pub title: String,
    pub page_count: u32,
    pub original_rotations: Vec<u32>,
    /// `DocumentSignature` encoded by the shell; opaque to the transaction.
    pub original_signature_json: String,
    pub source_size: u64,
    pub source_modified: Option<f64>,
    pub source_sha256: String,
    pub annotations_json: String,
    pub bookmarks_json: String,
    pub slots_json: String,
    pub deletions_json: String,
    pub erased_ink_json: String,
    pub annotation_dirty: bool,
    pub current_page: u32,
    pub selection: Vec<u32>,
    /// The document cache directory (path, trailing slash) the session must live under.
    pub cache_directory_prefix: String,
    /// True to read `recovery_path`; false to start a fresh session.
    pub restore: bool,
    /// The exact XFA read-only sentence, when this document is an XFA form. The transaction
    /// refuses a page write with it instead of staging a revision of the synthetic rendering.
    pub xfa_read_only_reason: Option<String>,
}

/// The shell's current annotation state at the moment of a call.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DocumentTransactionInputRecord {
    pub annotations_json: String,
    pub bookmarks_json: String,
    pub slots_json: String,
    pub deletions_json: String,
    pub erased_ink_json: String,
    pub annotation_dirty: bool,
    pub current_page: u32,
    pub selection: Vec<u32>,
}

impl DocumentTransactionInputRecord {
    fn state(&self) -> Result<AnnotationState, LyraReaderFfiError> {
        AnnotationState::from_json(
            AnnotationStateJson {
                annotations: &self.annotations_json,
                bookmarks: &self.bookmarks_json,
                slots: &self.slots_json,
                deletions: &self.deletions_json,
                erased_ink: &self.erased_ink_json,
            },
            self.annotation_dirty,
            self.current_page,
            &self.selection,
        )
        .map_err(document_error)
    }
}

/// The transaction state the shell mirrors for its banners and tabs.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DocumentTransactionStateRecord {
    pub active: bool,
    pub original_url: String,
    pub directory_url: String,
    pub annotation_records_url: String,
    pub original_records_url: String,
    pub title: String,
    pub original_rotations: Vec<u32>,
    pub revision_url: String,
    pub revision_number: u32,
    pub current_to_original: Vec<i32>,
    pub operations: Vec<String>,
    pub can_undo: bool,
    pub can_redo: bool,
    pub annotations_json: String,
    pub bookmarks_json: String,
    pub slots_json: String,
    pub deletions_json: String,
    pub erased_ink_json: String,
    pub annotation_dirty: bool,
    pub current_page: u32,
    pub selection: Vec<u32>,
    pub original_signature_json: String,
    pub source_size: u64,
    pub source_modified: Option<f64>,
    pub source_sha256: String,
    /// The snapshot label the last undo/redo restored, for the status line.
    pub last_label: Option<String>,
    /// A recovery-write failure the shell should report; the page change itself succeeded.
    pub recovery_error: Option<String>,
}

/// What one page operation wrote, plus the state after it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DocumentTransactionApplyRecord {
    pub state: DocumentTransactionStateRecord,
    pub page_map: Vec<Option<u32>>,
    pub page_count: u32,
    pub inserted_page: Option<u32>,
}

/// One page-editing session. Obtained from [`start_document_transaction`].
#[derive(uniffi::Object)]
pub struct LyraReaderDocumentTransaction {
    inner: Mutex<DocumentTransaction>,
    /// The exact XFA refusal sentence for this document, if it is an XFA form. Staging a
    /// revision on the synthetic pages would edit something that is not the file the reader
    /// opened, so the transaction refuses before touching a file.
    xfa_read_only_reason: Option<String>,
}

/// Starts a page-editing session, or restores the one recorded in `session.json`.
#[uniffi::export]
pub fn start_document_transaction(
    request: DocumentTransactionStartRecord,
) -> Result<Arc<LyraReaderDocumentTransaction>, LyraReaderFfiError> {
    let xfa_read_only_reason = request.xfa_read_only_reason.clone();
    let transaction = DocumentTransaction::start(StartRequest {
        original_url: request.original_url,
        directory_url: request.directory_url,
        recovery_path: PathBuf::from(request.recovery_path),
        original_records_url: request.original_records_url,
        title: request.title,
        page_count: request.page_count,
        original_rotations: request.original_rotations,
        original_signature_json: request.original_signature_json,
        source_size: request.source_size,
        source_modified: request.source_modified,
        source_sha256: request.source_sha256,
        annotations_json: request.annotations_json,
        bookmarks_json: request.bookmarks_json,
        slots_json: request.slots_json,
        deletions_json: request.deletions_json,
        erased_ink_json: request.erased_ink_json,
        annotation_dirty: request.annotation_dirty,
        current_page: request.current_page,
        selection: request.selection,
        cache_directory_prefix: request.cache_directory_prefix,
        restore: request.restore,
    })
    .map_err(document_error)?;
    Ok(Arc::new(LyraReaderDocumentTransaction {
        inner: Mutex::new(transaction),
        xfa_read_only_reason,
    }))
}

#[uniffi::export]
impl LyraReaderDocumentTransaction {
    /// Applies a page operation to the current revision and adopts the verified `rev-N.pdf`.
    ///
    /// The PDF write happens here (through the same `stage_page_operation` the shell used); the
    /// transaction computes the next revision name, keeps the pre-operation snapshot and remaps
    /// the reader's annotations/bookmarks through the report's page map.
    pub fn begin_apply(
        &self,
        label: String,
        input: DocumentTransactionInputRecord,
    ) -> Result<DocumentTransactionStateRecord, LyraReaderFfiError> {
        if let Some(reason) = &self.xfa_read_only_reason {
            return Err(LyraReaderError::new(ErrorCode::ReadOnly, reason.clone()).into());
        }
        let input = input.state()?;
        let mut transaction = lock(&self.inner)?;
        transaction
            .begin_apply(&label, input)
            .map(|()| state_record(&transaction.state()))
            .map_err(document_error)
    }

    /// Applies the prepared page operation to the current revision and adopts `rev-N.pdf`.
    pub fn apply(
        &self,
        operation: PageOperationRecord,
    ) -> Result<DocumentTransactionApplyRecord, LyraReaderFfiError> {
        if let Some(reason) = &self.xfa_read_only_reason {
            return Err(LyraReaderError::new(ErrorCode::ReadOnly, reason.clone()).into());
        }
        let mut transaction = lock(&self.inner)?;
        let target = transaction.next_revision();
        let source = transaction.current_revision_path().ok_or_else(|| {
            document_error(lyra_reader_edit::transaction::TransactionError(
                "the editing session's current revision is not a file URL".to_string(),
            ))
        })?;
        let report =
            match stage_page_operation(&source, &target.path, &page_operation(operation), None) {
                Ok(report) => report,
                Err(error) => {
                    let _ = std::fs::remove_file(&target.path);
                    transaction.cancel_apply();
                    return Err(error.into());
                }
            };
        let page_count = report.page_count;
        let page_map = report.page_map.clone();
        let inserted_page = report.inserted_page;
        let view = match transaction.apply_report(
            target.clone(),
            &PageOperationReport {
                page_count,
                page_map: page_map.clone(),
                inserted_page,
            },
        ) {
            Ok(view) => view,
            Err(error) => {
                let _ = std::fs::remove_file(&target.path);
                transaction.cancel_apply();
                return Err(document_error(error));
            }
        };
        Ok(DocumentTransactionApplyRecord {
            state: state_record(&view),
            page_map,
            page_count,
            inserted_page,
        })
    }

    /// Forgets the snapshot captured by `begin_apply` after the operation failed or was
    /// abandoned before a revision existed.
    pub fn cancel_apply(&self) -> Result<(), LyraReaderFfiError> {
        let mut transaction = lock(&self.inner)?;
        transaction.cancel_apply();
        Ok(())
    }

    /// Adopts a revision the shell wrote outside the page-operation path (a content edit).
    ///
    /// The prepared snapshot from [`Self::begin_apply`] is the undo entry, so undo crosses the
    /// content edit and any annotation materialisation that preceded it.
    pub fn commit_revision(
        &self,
        revision_url: String,
        revision_number: u32,
        label: String,
        input: DocumentTransactionInputRecord,
    ) -> Result<DocumentTransactionStateRecord, LyraReaderFfiError> {
        let input = input.state()?;
        let mut transaction = lock(&self.inner)?;
        transaction
            .commit_external(revision_url, revision_number, &label, input)
            .map(|view| state_record(&view))
            .map_err(document_error)
    }

    /// Undoes the last page operation. `None` means the undo stack was already empty.
    pub fn undo(
        &self,
        input: DocumentTransactionInputRecord,
    ) -> Result<Option<DocumentTransactionStateRecord>, LyraReaderFfiError> {
        let input = input.state()?;
        let mut transaction = lock(&self.inner)?;
        transaction
            .undo(input)
            .map(|state| state.map(|view| state_record(&view)))
            .map_err(document_error)
    }

    /// Redoes the last undone page operation. `None` means the redo stack was already empty.
    pub fn redo(
        &self,
        input: DocumentTransactionInputRecord,
    ) -> Result<Option<DocumentTransactionStateRecord>, LyraReaderFfiError> {
        let input = input.state()?;
        let mut transaction = lock(&self.inner)?;
        transaction
            .redo(input)
            .map(|state| state.map(|view| state_record(&view)))
            .map_err(document_error)
    }

    /// The current state, without writing anything.
    pub fn snapshot(&self) -> Result<DocumentTransactionStateRecord, LyraReaderFfiError> {
        let transaction = lock(&self.inner)?;
        Ok(state_record(&transaction.state()))
    }

    /// Adopts the shell's current state and (re)writes `session.json`.
    ///
    /// Called after an annotation/bookmark edit and after the shell materialises the marks into
    /// a `marks-<uuid>.pdf` revision; neither changes the revision number or the undo chain.
    pub fn persist(
        &self,
        input: DocumentTransactionInputRecord,
        revision_url: String,
        revision_number: u32,
        recovery_path: String,
    ) -> Result<DocumentTransactionStateRecord, LyraReaderFfiError> {
        let input = input.state()?;
        let mut transaction = lock(&self.inner)?;
        transaction
            .persist(
                input,
                revision_url,
                revision_number,
                std::path::PathBuf::from(recovery_path),
            )
            .map(|view| state_record(&view))
            .map_err(document_error)
    }

    /// Ends the session. `delete_files` retires the session directory and recovery manifest;
    /// false keeps them for the shell's cleanup-retry message after a failed save.
    pub fn close(&self, delete_files: bool) -> Result<(), LyraReaderFfiError> {
        let mut transaction = lock(&self.inner)?;
        transaction.close(delete_files);
        Ok(())
    }
}

fn state_record(view: &lyra_reader_edit::transaction::State) -> DocumentTransactionStateRecord {
    DocumentTransactionStateRecord {
        active: view.active,
        original_url: view.session.original_url.clone(),
        directory_url: view.session.directory_url.clone(),
        annotation_records_url: view.session.annotation_records_url.clone(),
        original_records_url: view.session.original_records_url.clone(),
        title: view.session.title.clone(),
        original_rotations: view.session.original_rotations.clone(),
        revision_url: view.revision_url.clone(),
        revision_number: view.revision_number,
        current_to_original: view.current_to_original.clone(),
        operations: view.operations.clone(),
        can_undo: view.can_undo,
        can_redo: view.can_redo,
        annotations_json: view.state.annotations_json(),
        bookmarks_json: view.state.bookmarks_json(),
        slots_json: view.state.slots_json(),
        deletions_json: view.state.deletions_json(),
        erased_ink_json: view.state.erased_ink_json(),
        annotation_dirty: view.state.annotation_dirty,
        current_page: view.state.current_page,
        selection: view.state.selection.clone(),
        original_signature_json: lyra_reader_edit::transaction::canonical_json(
            &view.session.original_signature,
        ),
        source_size: view.session.source_size,
        source_modified: view.session.source_modified,
        source_sha256: view.session.source_sha256.clone(),
        last_label: view.last_label.clone(),
        recovery_error: view.recovery_error.clone(),
    }
}

fn document_error(error: lyra_reader_edit::transaction::TransactionError) -> LyraReaderFfiError {
    LyraReaderFfiError::Document {
        message: error.0,
        severity: ErrorSeverity::Document,
    }
}

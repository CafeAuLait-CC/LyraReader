//! Edit layer: the annotation-kind taxonomy, the durable annotation-record codec, the limits
//! the shell and the PDF writer share, and the page-edit transaction.
//!
//! The shell keeps the PDFium handle it renders and the annotation model it draws; this crate
//! owns the parts that must be stated once:
//!
//! - [`kind`] is the annotation-kind taxonomy: the cache name, the PDF name, the drawing and
//!   editability flags, and the write kind a shell request becomes.
//! - [`records`] decodes and encodes the durable annotation cache (`annotations.json`), including
//!   the forward-compatible handling of entries this build does not understand.
//! - [`rules`] holds the annotation and bookmark limits the shell enforces at creation and
//!   PDFium enforces when writing the file, so both refuse with the same sentence.
//! - [`transaction`] owns the page-edit revision chain, page map, undo/redo snapshots and the
//!   recovery manifest.
//!
//! Writing annotations and pages into the PDF, choosing an incremental or full rewrite, and the
//! signature consequences of that choice belong to `lyra-reader-pdfium` and the shell; this crate
//! does not define a save policy.

pub mod kind;
pub mod records;
pub mod rules;
pub mod transaction;

pub use kind::{Drawing, KindFlags, WriteKind};
pub use records::{
    Contents, PaletteColor, RecordAnnotation, RecordBookmark, RecordError, Slot, StoredPoint,
    StoredRect,
};
pub use rules::RuleError;
pub use transaction::{
    AnnotationState, AnnotationStateJson, DocumentTransaction, PageMap, PageOperationReport,
    RevisionTarget, Snapshot, StartRequest, State as TransactionState, TransactionError,
};

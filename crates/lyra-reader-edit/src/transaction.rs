//! Page-edit transactions: the revision chain, the page map, undo/redo and recovery.
//!
//! The shell used to keep all of this in `AppState`: every page command wrote `rev-N.pdf` into
//! a session directory, remapped the reader's annotations and bookmarks, pushed a snapshot on an
//! undo stack and rewrote `session.json` (the recovery manifest). This module owns that state
//! machine. The shell still owns the PDFium handle it renders and the annotation model it draws;
//! the FFI layer stages the actual page operation through `lyra-reader-pdfium` and hands the
//! verified report to [`DocumentTransaction`].
//!
//! # What is owned here
//!
//! * the session directory layout (`rev-N.pdf`, the recovery manifest, and the annotation
//!   records inside the session directory);
//! * the revision number and URL chain, including a materialised-annotation revision (a
//!   `marks-<uuid>.pdf` file the shell writes before it needs the marks in the PDF);
//! * the current page map (current page → original page), composed across operations;
//! * one undo snapshot per page operation (the exact state before it, annotations and bookmarks
//!   included), and the redo stack that a new operation clears;
//! * the recovery manifest, read and written in the same JSON shape the Swift shell produced.
//!
//! # Recovery JSON
//!
//! `session.json` is the shell's crash-recovery manifest: the session metadata plus the current
//! snapshot and both stacks. Foundation's `JSONEncoder` writes object keys in a per-process
//! random order, so the pre-change capture was key-sorted with `JSONSerialization` before it was
//! frozen. This module writes the same canonical shape: compact JSON, object keys sorted, `/`
//! escaped the way Foundation writes a URL (`\/`), integral numbers written without `.0`, and
//! UUIDs upper-case. Everything else is the shell's own JSON (annotations, bookmarks, slots,
//! deletions, erased ink) spliced through as values, so the model cannot drift here.

use std::collections::HashSet;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Map, Number, Value};

/// The recovery shape this module writes and reads. The shell refuses newer versions rather than
/// guessing at fields it does not know.
pub const RECOVERY_VERSION: u32 = 1;
/// Bound recovery parsing before allocating buffers controlled by a cached file.
pub const MAX_RECOVERY_BYTES: u64 = 64 * 1024 * 1024;

/// The one sentence the shell shows when a recovery file no longer matches the file on disk.
///
/// The Swift implementation used the same sentence; keeping it here means a validation failure
/// is reported identically after the move.
pub const RECOVERY_SOURCE_CHANGED: &str = "The PDF or its cached editing session changed outside LyraReader. The cached page edits were kept.";

/// Error text returned to the caller. The shell owns presentation; this is the one sentence to
/// show, not a new taxonomy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TransactionError(pub String);

impl std::fmt::Display for TransactionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(formatter)
    }
}

impl std::error::Error for TransactionError {}

fn error(message: impl Into<String>) -> TransactionError {
    TransactionError(message.into())
}

/// A page map: `page_map[old] = Some(new)` for a surviving page, `None` for a removed one.
pub type PageMap = Vec<Option<u32>>;

/// The annotation/bookmark state at one revision.
///
/// The shell's model is rich (kinds, geometry, ink, stamps, foreign entries), so the state is
/// carried as its JSON values instead of a second model in this crate. The transaction still
/// **owns** the snapshot: it stores one per revision, remaps the `page` field of annotations and
/// bookmarks, filters the slot list, and writes them back into the recovery manifest.
#[derive(Clone, Debug, PartialEq)]
pub struct AnnotationState {
    pub annotations: Vec<Value>,
    pub bookmarks: Vec<Value>,
    pub slots: Vec<Value>,
    pub deletions: Vec<Value>,
    pub erased_ink: Vec<Value>,
    pub annotation_dirty: bool,
    pub current_page: u32,
    pub selection: Vec<u32>,
}

impl Default for AnnotationState {
    fn default() -> Self {
        Self {
            annotations: Vec::new(),
            bookmarks: Vec::new(),
            slots: Vec::new(),
            deletions: Vec::new(),
            erased_ink: Vec::new(),
            annotation_dirty: false,
            current_page: 1,
            selection: Vec::new(),
        }
    }
}

/// The five JSON arrays that make up [`AnnotationState`], borrowed from the caller.
#[derive(Clone, Copy, Debug)]
pub struct AnnotationStateJson<'a> {
    pub annotations: &'a str,
    pub bookmarks: &'a str,
    pub slots: &'a str,
    pub deletions: &'a str,
    pub erased_ink: &'a str,
}

impl AnnotationState {
    /// Parses the shell's JSON fragments. A fragment that is not an array is a caller bug, not a
    /// document problem: refuse instead of silently dropping the reader's marks.
    pub fn from_json(
        json: AnnotationStateJson<'_>,
        annotation_dirty: bool,
        current_page: u32,
        selection: &[u32],
    ) -> Result<Self, TransactionError> {
        fn array(json: &str, name: &str) -> Result<Vec<Value>, TransactionError> {
            let value: Value = serde_json::from_str(json)
                .map_err(|parse| error(format!("the {name} snapshot is not JSON: {parse}")))?;
            match value {
                Value::Array(values) => Ok(values),
                _ => Err(error(format!("the {name} snapshot is not a JSON array"))),
            }
        }
        let mut erased_ink = array(json.erased_ink, "erased-ink")?;
        // Erased ink is a set; sort it so the recovery bytes are deterministic. The order
        // carries no meaning (undo restores the set, not a sequence).
        erased_ink.sort_by(|left, right| {
            left.as_str()
                .unwrap_or_default()
                .cmp(right.as_str().unwrap_or_default())
        });
        Ok(Self {
            annotations: array(json.annotations, "annotation")?,
            bookmarks: array(json.bookmarks, "bookmark")?,
            slots: array(json.slots, "slot")?,
            deletions: array(json.deletions, "deletion")?,
            erased_ink,
            annotation_dirty,
            current_page,
            selection: sorted(selection),
        })
    }

    pub fn annotations_json(&self) -> String {
        canonical_json(&Value::Array(self.annotations.clone()))
    }

    pub fn bookmarks_json(&self) -> String {
        canonical_json(&Value::Array(self.bookmarks.clone()))
    }

    pub fn slots_json(&self) -> String {
        canonical_json(&Value::Array(self.slots.clone()))
    }

    pub fn deletions_json(&self) -> String {
        canonical_json(&Value::Array(self.deletions.clone()))
    }

    pub fn erased_ink_json(&self) -> String {
        canonical_json(&Value::Array(self.erased_ink.clone()))
    }

    /// Copies the state and moves every annotation/bookmark page through `page_map`.
    ///
    /// Marks on a removed page disappear; a mark on a surviving page moves to its new index.
    /// Slots follow their ids (an opaque slot is preserved untouched, as before), and the
    /// pending file deletions and erased ink are not page-addressed, so they stay as they are.
    pub fn remapped(&self, page_map: &PageMap) -> Self {
        let mut state = self.clone();
        let mut surviving_annotations = Vec::new();
        for mut annotation in self.annotations.clone() {
            if let Some(page) = mapped_page(&annotation, page_map)
                && set_page(&mut annotation, page)
            {
                surviving_annotations.push(annotation);
            }
        }
        let mut surviving_bookmarks = Vec::new();
        for mut bookmark in self.bookmarks.clone() {
            if let Some(page) = mapped_page(&bookmark, page_map)
                && set_page(&mut bookmark, page)
            {
                surviving_bookmarks.push(bookmark);
            }
        }
        let annotation_ids: Vec<&str> = surviving_annotations
            .iter()
            .filter_map(|annotation| annotation.get("id").and_then(Value::as_str))
            .collect();
        let bookmark_ids: Vec<&str> = surviving_bookmarks
            .iter()
            .filter_map(|bookmark| bookmark.get("id").and_then(Value::as_str))
            .collect();
        state.slots = self
            .slots
            .iter()
            .filter(|slot| slot_survives(slot, &annotation_ids, &bookmark_ids))
            .cloned()
            .collect();
        state.annotations = surviving_annotations;
        state.bookmarks = surviving_bookmarks;
        state
    }
}

fn sorted(values: &[u32]) -> Vec<u32> {
    let mut values = values.to_vec();
    values.sort_unstable();
    values.dedup();
    values
}

fn mapped_page(value: &Value, page_map: &PageMap) -> Option<u32> {
    let page = value.get("page")?.as_u64()? as usize;
    page_map.get(page).copied().flatten()
}

fn set_page(value: &mut Value, page: u32) -> bool {
    match value {
        Value::Object(object) => {
            object.insert("page".to_string(), Value::Number(Number::from(page)));
            true
        }
        _ => false,
    }
}

fn slot_survives(slot: &Value, annotation_ids: &[&str], bookmark_ids: &[&str]) -> bool {
    let Some(object) = slot.as_object() else {
        return true;
    };
    if let Some(annotation) = object.get("annotation") {
        return annotation
            .get("_0")
            .and_then(Value::as_str)
            .is_some_and(|id| annotation_ids.contains(&id));
    }
    if let Some(bookmark) = object.get("bookmark") {
        return bookmark
            .get("_0")
            .and_then(Value::as_str)
            .is_some_and(|id| bookmark_ids.contains(&id));
    }
    // An opaque entry this version does not understand is preserved, exactly as before.
    true
}

/// One revision plus the reader's marks at that revision.
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub revision_url: String,
    pub revision_number: u32,
    pub current_to_original: Vec<i32>,
    pub operations: Vec<String>,
    pub state: AnnotationState,
    pub label: String,
}

/// Where the next page operation should be written.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RevisionTarget {
    pub number: u32,
    pub path: PathBuf,
    pub url: String,
}

/// The session metadata the recovery manifest records and the shell needs again after a restart.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionMetadata {
    pub original_url: String,
    pub original_signature: Value,
    pub source_size: u64,
    pub source_modified: Option<f64>,
    pub source_sha256: String,
    pub original_records_url: String,
    pub title: String,
    pub directory_url: String,
    pub annotation_records_url: String,
    pub original_rotations: Vec<u32>,
}

/// What the caller passes to start a fresh session or restore one.
#[derive(Clone, Debug)]
pub struct StartRequest {
    pub original_url: String,
    /// Session directory URL, ending in `/` (Foundation's `isDirectory` form).
    pub directory_url: String,
    /// `session.json` in the document cache.
    pub recovery_path: PathBuf,
    pub original_records_url: String,
    pub title: String,
    pub page_count: u32,
    pub original_rotations: Vec<u32>,
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
    /// The directory the session directory must live under (the document's cache directory,
    /// with a trailing slash). Used only when restoring.
    pub cache_directory_prefix: String,
    /// True to read `recovery_path` instead of preparing a fresh session.
    pub restore: bool,
}

/// The shell-facing state after any call. It is a value, not a handle: the shell may keep it in
/// its tab state, and the transaction remains the source of truth for the stacks and the chain.
#[derive(Clone, Debug, PartialEq)]
pub struct State {
    pub active: bool,
    pub session: SessionMetadata,
    pub revision_url: String,
    pub revision_number: u32,
    pub current_to_original: Vec<i32>,
    pub operations: Vec<String>,
    pub can_undo: bool,
    pub can_redo: bool,
    pub state: AnnotationState,
    /// The label of a snapshot undone/redone by the last call, for the status line.
    pub last_label: Option<String>,
    /// A recovery-write failure. The page operation still succeeded (as before); the shell
    /// shows this sentence instead of losing the change.
    pub recovery_error: Option<String>,
}

/// The page-edit transaction.
#[derive(Clone, Debug)]
pub struct DocumentTransaction {
    session: SessionMetadata,
    recovery_path: PathBuf,
    revision_url: String,
    revision_number: u32,
    current_to_original: Vec<i32>,
    operations: Vec<String>,
    state: AnnotationState,
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
    /// The snapshot captured before the shell materialises annotations or stages a content
    /// edit. It is consumed by the next `apply_report`/`commit_external` so an undo across a
    /// materialisation returns to the revision *before* it, exactly as the shell did.
    pending: Option<Snapshot>,
    /// True when the shell persisted a new current state between `begin_apply` and the
    /// operation (annotation materialisation). The new state is then the base for the page
    /// remap; the pending snapshot is still the undo entry.
    pending_state_changed: bool,
    active: bool,
}

impl DocumentTransaction {
    /// Starts a fresh session. The transaction writes its recovery manifest immediately, as the
    /// shell did when it prepared the working copy.
    pub fn start(request: StartRequest) -> Result<Self, TransactionError> {
        if request.restore {
            return Self::restore(request);
        }
        let signature: Value = serde_json::from_str(&request.original_signature_json)
            .map_err(|parse| error(format!("the original signature is not JSON: {parse}")))?;
        let state = AnnotationState::from_json(
            AnnotationStateJson {
                annotations: &request.annotations_json,
                bookmarks: &request.bookmarks_json,
                slots: &request.slots_json,
                deletions: &request.deletions_json,
                erased_ink: &request.erased_ink_json,
            },
            request.annotation_dirty,
            request.current_page,
            &request.selection,
        )?;
        let directory_url = directory_form(&request.directory_url);
        let annotation_records_url = format!("{directory_url}annotations.json");
        let session = SessionMetadata {
            original_url: request.original_url.clone(),
            original_signature: signature,
            source_size: request.source_size,
            source_modified: request.source_modified,
            source_sha256: request.source_sha256,
            original_records_url: request.original_records_url,
            title: request.title,
            directory_url,
            annotation_records_url,
            original_rotations: request.original_rotations,
        };
        let transaction = Self {
            session,
            recovery_path: request.recovery_path,
            revision_url: request.original_url,
            revision_number: 0,
            current_to_original: (0..request.page_count as i32).collect(),
            operations: Vec::new(),
            state,
            undo: Vec::new(),
            redo: Vec::new(),
            pending: None,
            pending_state_changed: false,
            active: true,
        };
        transaction.write_recovery()?;
        Ok(transaction)
    }

    fn restore(request: StartRequest) -> Result<Self, TransactionError> {
        let file = fs::File::open(&request.recovery_path)
            .map_err(|e| error(format!("The cached editing session could not be read: {e}")))?;
        if file.metadata().map_err(|e| error(e.to_string()))?.len() > MAX_RECOVERY_BYTES {
            return Err(error(
                "The cached editing session exceeds the 64 MiB read limit; its data was kept.",
            ));
        }
        let mut bytes = Vec::new();
        file.take(MAX_RECOVERY_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| error(e.to_string()))?;
        if bytes.len() as u64 > MAX_RECOVERY_BYTES {
            return Err(error(
                "The cached editing session exceeds the 64 MiB read limit; its data was kept.",
            ));
        }
        let document: Value = serde_json::from_slice(&bytes)
            .map_err(|parse| error(format!("The cached editing session is not JSON: {parse}")))?;
        validate_recovery_schema(&document)?;
        let session_value = document
            .get("session")
            .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?;
        let snapshot_value = document
            .get("snapshot")
            .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?;
        let version = document.get("version").and_then(Value::as_u64).unwrap_or(0);
        if version != u64::from(RECOVERY_VERSION) {
            return Err(error(format!(
                "The cached editing session uses version {version}; this build only reads version {RECOVERY_VERSION}. The cached page edits were kept."
            )));
        }
        let original_url = string_field(session_value, "originalURL")?;
        let directory_url = string_field(session_value, "directory")?;
        let annotation_records_url = string_field(session_value, "annotationRecordsURL")?;
        let original_records_url = string_field(session_value, "originalRecordsURL")?;
        let title = string_field(session_value, "title")?;
        let original_signature = session_value
            .get("originalSignature")
            .cloned()
            .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?;
        let source = session_value
            .get("sourceStamp")
            .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?;
        let source_size = source.get("size").and_then(Value::as_u64).unwrap_or(0);
        let source_modified = source.get("modified").and_then(Value::as_f64);
        let source_sha256 = source
            .get("sha256")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let original_rotations = u32_array(
            session_value
                .get("originalRotations")
                .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?,
        )?;
        let revision_url = string_field(session_value, "revisionURL")?;
        let revision_number = u32_field(session_value, "revisionNumber")?;
        let current_to_original = i32_array(
            session_value
                .get("currentToOriginal")
                .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?,
        )?;
        let operations = string_array(
            session_value
                .get("operations")
                .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?,
        )?;
        let undo = snapshot_array(
            session_value
                .get("undo")
                .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?,
        )?;
        let redo = snapshot_array(
            session_value
                .get("redo")
                .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?,
        )?;
        let state = snapshot_state(snapshot_value)?;
        for (mapping, state) in std::iter::once((&current_to_original, &state)).chain(
            undo.iter()
                .chain(&redo)
                .map(|s| (&s.current_to_original, &s.state)),
        ) {
            let count = mapping.len();
            if count == 0
                || state.current_page == 0
                || state.current_page as usize > count
                || state.selection.iter().any(|p| *p as usize >= count)
                || mapping
                    .iter()
                    .any(|p| *p < -1 || i64::from(*p) >= i64::from(request.page_count))
            {
                return Err(error(
                    "The cached editing session has invalid page positions; its files were kept.",
                ));
            }
        }

        // The same checks the shell used to make after decoding: the file must still be the one
        // the session was started for, the session directory must still be inside that
        // document's cache, and every revision URL must be the original or inside the session.
        let original_path =
            file_url_path(&original_url).ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?;
        let expected_path =
            file_url_path(&request.original_url).ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?;
        if !same_file(&original_path, &expected_path)
            || source_size != request.source_size
            || source_sha256 != request.source_sha256
        {
            return Err(error(RECOVERY_SOURCE_CHANGED));
        }
        let directory_path =
            file_url_path(&directory_url).ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?;
        let cache_prefix = Path::new(&request.cache_directory_prefix);
        if !path_has_prefix(&directory_path, cache_prefix) {
            return Err(error(RECOVERY_SOURCE_CHANGED));
        }
        let records_path =
            file_url_path(&annotation_records_url).ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?;
        if !path_has_prefix(&records_path, &directory_path) {
            return Err(error(RECOVERY_SOURCE_CHANGED));
        }
        for url in std::iter::once(&revision_url)
            .chain(undo.iter().map(|snapshot| &snapshot.revision_url))
            .chain(redo.iter().map(|snapshot| &snapshot.revision_url))
        {
            let path = file_url_path(url).ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?;
            if path != original_path && !path_has_prefix(&path, &directory_path) {
                return Err(error(RECOVERY_SOURCE_CHANGED));
            }
        }

        let session = SessionMetadata {
            original_url,
            original_signature,
            source_size,
            source_modified,
            source_sha256,
            original_records_url,
            title,
            directory_url,
            annotation_records_url,
            original_rotations,
        };
        Ok(Self {
            session,
            recovery_path: request.recovery_path,
            revision_url,
            revision_number,
            current_to_original,
            operations,
            state,
            undo,
            redo,
            pending: None,
            pending_state_changed: false,
            active: true,
        })
    }

    /// The file behind the revision the shell is showing.
    pub fn current_revision_path(&self) -> Option<PathBuf> {
        file_url_path(&self.revision_url)
    }

    /// Selects an unused revision path, including after undo branches. Existing files may
    /// still belong to immutable render/print snapshots even after leaving the undo chain.
    pub fn next_revision(&self) -> Result<RevisionTarget, TransactionError> {
        let mut number = self
            .revision_number
            .checked_add(1)
            .ok_or_else(|| error("The editing revision number overflowed."))?;
        let directory = file_url_path(&self.session.directory_url)
            .ok_or_else(|| error("The editing session has an invalid directory URL."))?;
        let path = loop {
            let path = directory.join(format!("rev-{number}.pdf"));
            match fs::symlink_metadata(&path) {
                Ok(_) => {
                    number = number
                        .checked_add(1)
                        .ok_or_else(|| error("The editing revision number overflowed."))?
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => break path,
                Err(e) => {
                    return Err(error(format!(
                        "The next editing revision could not be checked: {e}"
                    )));
                }
            }
        };
        Ok(RevisionTarget {
            number,
            url: format!("{}rev-{number}.pdf", self.session.directory_url),
            path,
        })
    }

    /// Captures the pre-operation snapshot before the shell materialises annotations for this
    /// operation. `apply_report` consumes it.
    ///
    /// Rotating a page that has cached text-position marks first writes those marks into a
    /// working PDF, which changes the revision URL. Undo must still return to the revision the
    /// reader saw *before* that materialisation, so the snapshot is taken here instead of when
    /// the operation is adopted.
    pub fn begin_apply(
        &mut self,
        label: &str,
        input: AnnotationState,
    ) -> Result<(), TransactionError> {
        if !self.active {
            return Err(error("The page-editing session is closed."));
        }
        if self.pending.is_some() {
            return Err(error("a page operation is already prepared"));
        }
        self.pending = Some(self.current_snapshot(label, input));
        self.pending_state_changed = false;
        Ok(())
    }

    /// Forgets a prepared snapshot after a failed operation.
    pub fn cancel_apply(&mut self) {
        self.pending = None;
        self.pending_state_changed = false;
    }

    /// Adopts a verified page-operation report.
    ///
    /// `input` is the state the shell has right now (including note edits that have not reached
    /// disk yet); the prepared snapshot (from [`Self::begin_apply`]) takes precedence for the
    /// undo entry. The returned state carries the remapped marks.
    pub fn apply_report(
        &mut self,
        target: RevisionTarget,
        report: &PageOperationReport,
    ) -> Result<State, TransactionError> {
        if !self.active {
            return Err(error("The page-editing session is closed."));
        }
        let snapshot = self
            .pending
            .take()
            .ok_or_else(|| error("no page operation was prepared"))?;
        let base = if self.pending_state_changed {
            self.state.clone()
        } else {
            snapshot.state.clone()
        };
        let mut mapping = vec![-1i32; report.page_count as usize];
        for (old, new) in report.page_map.iter().enumerate() {
            let Some(new) = *new else { continue };
            let Some(slot) = mapping.get_mut(new as usize) else {
                continue;
            };
            *slot = self.current_to_original.get(old).copied().unwrap_or(-1);
        }
        let remapped = base.remapped(&report.page_map);
        let (page, selection) = remap_page_selection(
            base.current_page,
            &base.selection,
            &report.page_map,
            report.inserted_page,
            report.page_count,
        );
        self.revision_url = target.url;
        self.revision_number = target.number;
        self.current_to_original = mapping;
        self.operations.push(snapshot.label.clone());
        self.state = AnnotationState {
            current_page: page,
            selection,
            ..remapped
        };
        self.undo.push(snapshot);
        self.redo.clear();
        self.pending_state_changed = false;
        let recovery_error = self.write_recovery().err().map(|error| error.0);
        let mut view = self.view();
        view.recovery_error = recovery_error;
        Ok(view)
    }

    /// Adopts a revision the shell wrote outside the page-operation path (a content edit).
    ///
    /// The prepared snapshot (from [`Self::begin_apply`]) is the undo entry, so undo crosses the
    /// content edit *and* any annotation materialisation that preceded it. `current` is the state
    /// on screen after the edit; the content edit itself does not change the reader's marks.
    pub fn commit_external(
        &mut self,
        revision_url: String,
        revision_number: u32,
        label: &str,
        current: AnnotationState,
    ) -> Result<State, TransactionError> {
        if !self.active {
            return Err(error("The page-editing session is closed."));
        }
        let snapshot = self
            .pending
            .take()
            .unwrap_or_else(|| self.current_snapshot(label, current.clone()));
        self.pending_state_changed = false;
        self.revision_url = revision_url;
        self.revision_number = revision_number;
        self.operations.push(label.to_string());
        self.state = current;
        self.undo.push(snapshot);
        self.redo.clear();
        self.pending_state_changed = false;
        let recovery_error = self.write_recovery().err().map(|error| error.0);
        let mut view = self.view();
        view.recovery_error = recovery_error;
        Ok(view)
    }

    /// Undoes the last page operation. `input` is the shell's current state (it becomes the redo
    /// snapshot, so annotation edits made after the operation are not lost).
    pub fn undo(&mut self, input: AnnotationState) -> Result<Option<State>, TransactionError> {
        let Some(target) = self.undo.pop() else {
            return Ok(None);
        };
        let label = target.label.clone();
        self.pending = None;
        self.pending_state_changed = false;
        let current = self.current_snapshot("undo", input);
        self.redo.push(current);
        self.adopt(target);
        let recovery_error = self.write_recovery().err().map(|error| error.0);
        let mut view = self.view();
        view.last_label = Some(label);
        view.recovery_error = recovery_error;
        Ok(Some(view))
    }

    /// Redoes the last undone page operation.
    pub fn redo(&mut self, input: AnnotationState) -> Result<Option<State>, TransactionError> {
        let Some(target) = self.redo.pop() else {
            return Ok(None);
        };
        let label = target.label.clone();
        self.pending = None;
        self.pending_state_changed = false;
        let current = self.current_snapshot("redo", input);
        self.undo.push(current);
        self.adopt(target);
        let recovery_error = self.write_recovery().err().map(|error| error.0);
        let mut view = self.view();
        view.last_label = Some(label);
        view.recovery_error = recovery_error;
        Ok(Some(view))
    }

    fn current_snapshot(&self, label: &str, state: AnnotationState) -> Snapshot {
        Snapshot {
            revision_url: self.revision_url.clone(),
            revision_number: self.revision_number,
            current_to_original: self.current_to_original.clone(),
            operations: self.operations.clone(),
            state,
            label: label.to_string(),
        }
    }

    fn adopt(&mut self, snapshot: Snapshot) {
        self.revision_url = snapshot.revision_url;
        self.revision_number = snapshot.revision_number;
        self.current_to_original = snapshot.current_to_original;
        self.operations = snapshot.operations;
        self.state = snapshot.state;
    }

    /// Updates the current revision/payload without an undo step.
    ///
    /// Used when the shell writes the reader's marks into a working revision
    /// (`marks-<uuid>.pdf`) or when an annotation edit changes the current state. The revision
    /// number and the undo chain do not change, exactly as before.
    pub fn persist(
        &mut self,
        input: AnnotationState,
        revision_url: String,
        revision_number: u32,
        recovery_path: PathBuf,
    ) -> Result<State, TransactionError> {
        if !self.active {
            return Err(error("The page-editing session is closed."));
        }
        self.state = input;
        self.revision_url = revision_url;
        self.revision_number = revision_number;
        if self.pending.is_some() {
            self.pending_state_changed = true;
        }
        // The document cache is keyed by canonical path + content hash. If the PDF changed
        // outside LyraReader the cache directory moves; the shell re-resolves the manifest path
        // on every write, so recovery data follows the document rather than a stale directory.
        self.recovery_path = recovery_path;
        let recovery_error = self.write_recovery().err().map(|error| error.0);
        let mut view = self.view();
        view.recovery_error = recovery_error;
        Ok(view)
    }

    pub fn state(&self) -> State {
        self.view()
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    /// Applies a shell's explicit history policy without changing other platforms' defaults.
    /// The byte budget measures serialized snapshots, not process memory. Keep one undo
    /// snapshot even if that one record exceeds the nominal budget.
    pub fn limit_history(&mut self, steps: u32, bytes: u64) -> Result<State, TransactionError> {
        if steps == 0 || bytes == 0 {
            return Err(error("History limits must be positive."));
        }
        fn trim(
            history: &mut Vec<Snapshot>,
            steps: usize,
            limit: u64,
        ) -> Result<bool, TransactionError> {
            let sizes = history
                .iter()
                .map(|s| {
                    serde_json::to_vec(&DocumentTransaction::snapshot_value(s))
                        .map(|v| v.len() as u64)
                        .map_err(|e| error(e.to_string()))
                })
                .collect::<Result<Vec<_>, _>>()?;
            let mut total = sizes.iter().try_fold(0u64, |a, b| {
                a.checked_add(*b)
                    .ok_or_else(|| error("The history byte count overflowed."))
            })?;
            let mut remove = 0;
            while history.len() - remove > 1 && (history.len() - remove > steps || total > limit) {
                total -= sizes[remove];
                remove += 1;
            }
            if remove > 0 {
                history.drain(..remove);
            }
            Ok(remove > 0)
        }
        let changed = trim(&mut self.undo, steps as usize, bytes)?
            | trim(&mut self.redo, steps as usize, bytes)?;
        let mut state = self.view();
        if changed {
            state.recovery_error = self.write_recovery().err().map(|e| e.0);
        }
        Ok(state)
    }

    /// Removes only generated revisions unreachable from history or an immutable render lease.
    pub fn collect_revision_garbage(&self, protected: &[String]) -> Result<u32, TransactionError> {
        let directory = file_url_path(&self.session.directory_url)
            .ok_or_else(|| error("Invalid editing directory URL."))?;
        let mut retained: HashSet<PathBuf> = std::iter::once(self.revision_url.as_str())
            .chain(self.undo.iter().map(|s| s.revision_url.as_str()))
            .chain(self.redo.iter().map(|s| s.revision_url.as_str()))
            .chain(self.pending.iter().map(|s| s.revision_url.as_str()))
            .chain(protected.iter().map(String::as_str))
            .filter_map(file_url_path)
            .collect();
        retained.insert(
            file_url_path(&self.session.original_url)
                .ok_or_else(|| error("Invalid original URL."))?,
        );
        let mut count = 0u32;
        for entry in fs::read_dir(&directory).map_err(|e| error(e.to_string()))? {
            let entry = entry.map_err(|e| error(e.to_string()))?;
            if !entry
                .file_type()
                .map_err(|e| error(e.to_string()))?
                .is_file()
            {
                continue;
            }
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            let generated = name.strip_suffix(".pdf").is_some_and(|stem| {
                stem.strip_prefix("rev-")
                    .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
                    || ["marks-", "save-"].iter().any(|prefix| {
                        stem.strip_prefix(prefix)
                            .is_some_and(|id| crate::records::normalize_uuid(id).is_some())
                    })
            });
            if generated && !retained.contains(&entry.path()) {
                fs::remove_file(entry.path())
                    .map_err(|e| error(format!("A retired revision could not be removed: {e}")))?;
                count = count
                    .checked_add(1)
                    .ok_or_else(|| error("The revision count overflowed."))?;
            }
        }
        Ok(count)
    }

    /// Retires the public recovery entry before render snapshots release this session's files.
    /// A later `close(true)` targets only the private retired entry, so it cannot delete a new
    /// session another window started for the same original document.
    pub fn retire_recovery(&mut self) -> Result<(), TransactionError> {
        let directory = file_url_path(&self.session.directory_url)
            .ok_or_else(|| error("The editing session has no local directory URL."))?;
        let retired = directory.join("retired-session.json");
        if self.recovery_path != retired {
            fs::rename(&self.recovery_path, &retired)
                .map_err(|e| error(format!("Could not retire the cached editing session: {e}")))?;
            let previous_parent = self.recovery_path.parent().map(Path::to_path_buf);
            self.recovery_path = retired;
            #[cfg(unix)]
            {
                if let Some(parent) = previous_parent {
                    fs::File::open(parent).and_then(|f| f.sync_all()).map_err(|e|error(format!("The recovery entry was retired, but its directory could not be flushed: {e}")))?;
                }
                fs::File::open(&directory)
                    .and_then(|f| f.sync_all())
                    .map_err(|e| {
                        error(format!(
                            "The retired session directory could not be flushed: {e}"
                        ))
                    })?;
            }
            #[cfg(not(unix))]
            let _ = previous_parent;
        }
        self.pending = None;
        self.pending_state_changed = false;
        self.active = false;
        Ok(())
    }

    /// Deletes the session directory and its recovery manifest (on Save, Replace or Discard).
    /// `delete_files == false` keeps them for a failed cleanup the shell will retry.
    pub fn close(&mut self, delete_files: bool) -> Result<(), TransactionError> {
        self.pending = None;
        self.pending_state_changed = false;
        self.active = false;
        if delete_files {
            let directory = file_url_path(&self.session.directory_url).ok_or_else(|| {
                error("The editing session has an invalid cleanup directory URL.")
            })?;
            if let Err(e) = fs::remove_dir_all(directory)
                && e.kind() != std::io::ErrorKind::NotFound
            {
                return Err(error(format!(
                    "The document was kept, but its retired editing files could not be removed: {e}"
                )));
            }
            if let Err(e) = fs::remove_file(&self.recovery_path)
                && e.kind() != std::io::ErrorKind::NotFound
            {
                return Err(error(format!(
                    "The retired editing manifest could not be removed: {e}"
                )));
            }
        }
        Ok(())
    }

    fn view(&self) -> State {
        State {
            active: self.active,
            session: self.session.clone(),
            revision_url: self.revision_url.clone(),
            revision_number: self.revision_number,
            current_to_original: self.current_to_original.clone(),
            operations: self.operations.clone(),
            can_undo: self.can_undo(),
            can_redo: self.can_redo(),
            state: self.state.clone(),
            last_label: None,
            recovery_error: None,
        }
    }

    fn write_recovery(&self) -> Result<(), TransactionError> {
        let value = self.recovery_value();
        let text = canonical_json(&value);
        if text.len() as u64 > MAX_RECOVERY_BYTES {
            return Err(error(
                "The editing session exceeds the 64 MiB recovery limit; the previous recovery file was kept.",
            ));
        }
        write_atomic(&self.recovery_path, text.as_bytes())
            .map_err(|write| error(format!("Could not cache the editing session: {write}")))
    }

    fn recovery_value(&self) -> Value {
        let mut session = Map::new();
        session.insert(
            "originalURL".to_string(),
            Value::String(self.session.original_url.clone()),
        );
        session.insert(
            "originalSignature".to_string(),
            self.session.original_signature.clone(),
        );
        let mut source = Map::new();
        source.insert(
            "size".to_string(),
            Value::Number(Number::from(self.session.source_size)),
        );
        if let Some(modified) = self.session.source_modified {
            source.insert("modified".to_string(), number(modified));
        }
        source.insert(
            "sha256".to_string(),
            Value::String(self.session.source_sha256.clone()),
        );
        session.insert("sourceStamp".to_string(), Value::Object(source));
        session.insert(
            "originalRecordsURL".to_string(),
            Value::String(self.session.original_records_url.clone()),
        );
        session.insert(
            "title".to_string(),
            Value::String(self.session.title.clone()),
        );
        session.insert(
            "directory".to_string(),
            Value::String(self.session.directory_url.clone()),
        );
        session.insert(
            "annotationRecordsURL".to_string(),
            Value::String(self.session.annotation_records_url.clone()),
        );
        session.insert(
            "originalRotations".to_string(),
            Value::Array(
                self.session
                    .original_rotations
                    .iter()
                    .map(|rotation| Value::Number(Number::from(*rotation)))
                    .collect(),
            ),
        );
        session.insert(
            "revisionURL".to_string(),
            Value::String(self.revision_url.clone()),
        );
        session.insert(
            "revisionNumber".to_string(),
            Value::Number(Number::from(self.revision_number)),
        );
        session.insert(
            "currentToOriginal".to_string(),
            Value::Array(
                self.current_to_original
                    .iter()
                    .map(|page| Value::Number(Number::from(*page)))
                    .collect(),
            ),
        );
        session.insert(
            "operations".to_string(),
            Value::Array(
                self.operations
                    .iter()
                    .map(|operation| Value::String(operation.clone()))
                    .collect(),
            ),
        );
        session.insert(
            "undo".to_string(),
            Value::Array(self.undo.iter().map(Self::snapshot_value).collect()),
        );
        session.insert(
            "redo".to_string(),
            Value::Array(self.redo.iter().map(Self::snapshot_value).collect()),
        );
        let snapshot = self.current_snapshot("Recovered editing session", self.state.clone());
        let mut document = Map::new();
        document.insert(
            "version".to_string(),
            Value::Number(Number::from(RECOVERY_VERSION)),
        );
        document.insert("session".to_string(), Value::Object(session));
        document.insert("snapshot".to_string(), Self::snapshot_value(&snapshot));
        Value::Object(document)
    }

    fn snapshot_value(snapshot: &Snapshot) -> Value {
        let mut value = Map::new();
        value.insert(
            "revisionURL".to_string(),
            Value::String(snapshot.revision_url.clone()),
        );
        value.insert(
            "revisionNumber".to_string(),
            Value::Number(Number::from(snapshot.revision_number)),
        );
        value.insert(
            "currentToOriginal".to_string(),
            Value::Array(
                snapshot
                    .current_to_original
                    .iter()
                    .map(|page| Value::Number(Number::from(*page)))
                    .collect(),
            ),
        );
        value.insert(
            "operations".to_string(),
            Value::Array(
                snapshot
                    .operations
                    .iter()
                    .map(|operation| Value::String(operation.clone()))
                    .collect(),
            ),
        );
        value.insert(
            "annotations".to_string(),
            Value::Array(snapshot.state.annotations.clone()),
        );
        value.insert(
            "bookmarks".to_string(),
            Value::Array(snapshot.state.bookmarks.clone()),
        );
        value.insert(
            "slots".to_string(),
            Value::Array(snapshot.state.slots.clone()),
        );
        value.insert(
            "deletions".to_string(),
            Value::Array(snapshot.state.deletions.clone()),
        );
        value.insert(
            "erasedInk".to_string(),
            Value::Array(snapshot.state.erased_ink.clone()),
        );
        value.insert(
            "annotationDirty".to_string(),
            Value::Bool(snapshot.state.annotation_dirty),
        );
        value.insert(
            "currentPage".to_string(),
            Value::Number(Number::from(snapshot.state.current_page)),
        );
        value.insert(
            "selection".to_string(),
            Value::Array(
                snapshot
                    .state
                    .selection
                    .iter()
                    .map(|page| Value::Number(Number::from(*page)))
                    .collect(),
            ),
        );
        value.insert("label".to_string(), Value::String(snapshot.label.clone()));
        Value::Object(value)
    }
}

/// What `stage_page_operation` verified. The transaction only needs the page map and the new
/// page count; the FFI layer builds this from the engine's report.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageOperationReport {
    pub page_count: u32,
    pub page_map: PageMap,
    pub inserted_page: Option<u32>,
}

/// Remaps the current page and the thumbnail selection through an operation's page map.
///
/// This reproduces the shell's historical rule exactly: the page the reader is looking at stays
/// the same page unless it was removed; an inserted blank page becomes current; a selection
/// maps one-to-one and a removed selected page simply disappears from the selection.
pub fn remap_page_selection(
    current_page: u32,
    selection: &[u32],
    page_map: &PageMap,
    inserted_page: Option<u32>,
    page_count: u32,
) -> (u32, Vec<u32>) {
    let previous = current_page.saturating_sub(1) as usize;
    let last = page_map.len().saturating_sub(1);
    let previous = previous.min(last);
    let mapped = inserted_page.or_else(|| {
        page_map
            .get(previous)
            .copied()
            .flatten()
            .or_else(|| Some(previous.min(page_count.saturating_sub(1) as usize) as u32))
    });
    let page = mapped.unwrap_or(0) + 1;
    let mut mapped_selection: Vec<u32> = selection
        .iter()
        .filter_map(|selected| page_map.get(*selected as usize).copied().flatten())
        .collect();
    if let Some(inserted) = inserted_page {
        mapped_selection = vec![inserted];
    }
    (page, sorted(&mapped_selection))
}

fn snapshot_state(value: &Value) -> Result<AnnotationState, TransactionError> {
    let arrays = |name: &str| -> Result<Vec<Value>, TransactionError> {
        value
            .get(name)
            .and_then(Value::as_array)
            .cloned()
            .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))
    };
    Ok(AnnotationState {
        annotations: arrays("annotations")?,
        bookmarks: arrays("bookmarks")?,
        slots: arrays("slots")?,
        deletions: arrays("deletions")?,
        erased_ink: arrays("erasedInk")?,
        annotation_dirty: value
            .get("annotationDirty")
            .and_then(Value::as_bool)
            .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?,
        current_page: u32_field(value, "currentPage")?,
        selection: u32_array(
            value
                .get("selection")
                .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?,
        )?,
    })
}

fn snapshot_array(value: &Value) -> Result<Vec<Snapshot>, TransactionError> {
    let values = value
        .as_array()
        .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?;
    let mut snapshots = Vec::with_capacity(values.len());
    for value in values {
        snapshots.push(Snapshot {
            revision_url: string_field(value, "revisionURL")?,
            revision_number: u32_field(value, "revisionNumber")?,
            current_to_original: i32_array(
                value
                    .get("currentToOriginal")
                    .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?,
            )?,
            operations: string_array(
                value
                    .get("operations")
                    .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?,
            )?,
            state: snapshot_state(value)?,
            label: string_field(value, "label")?,
        });
    }
    Ok(snapshots)
}

fn string_field(value: &Value, name: &str) -> Result<String, TransactionError> {
    value
        .get(name)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))
}

fn u32_field(value: &Value, name: &str) -> Result<u32, TransactionError> {
    value
        .get(name)
        .and_then(Value::as_u64)
        .and_then(|n| u32::try_from(n).ok())
        .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))
}

/// Unknown transaction structure cannot safely be rewritten by this version. Annotation
/// objects and opaque slots remain values and keep their own forward-compatible fields.
fn validate_recovery_schema(value: &Value) -> Result<(), TransactionError> {
    fn keys(value: &Value, allowed: &[&str]) -> Result<(), TransactionError> {
        let object = value
            .as_object()
            .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?;
        if object.keys().any(|key| !allowed.contains(&key.as_str())) {
            return Err(error(
                "The cached editing session contains fields this build cannot safely rewrite; its data was kept.",
            ));
        }
        Ok(())
    }
    const SNAPSHOT: &[&str] = &[
        "revisionURL",
        "revisionNumber",
        "currentToOriginal",
        "operations",
        "annotations",
        "bookmarks",
        "slots",
        "deletions",
        "erasedInk",
        "annotationDirty",
        "currentPage",
        "selection",
        "label",
    ];
    keys(value, &["version", "session", "snapshot"])?;
    let session = &value["session"];
    keys(
        session,
        &[
            "originalURL",
            "originalSignature",
            "sourceStamp",
            "originalRecordsURL",
            "title",
            "directory",
            "annotationRecordsURL",
            "originalRotations",
            "revisionURL",
            "revisionNumber",
            "currentToOriginal",
            "operations",
            "undo",
            "redo",
        ],
    )?;
    keys(&session["sourceStamp"], &["size", "modified", "sha256"])?;
    keys(&value["snapshot"], SNAPSHOT)?;
    for name in ["undo", "redo"] {
        for snapshot in session[name]
            .as_array()
            .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?
        {
            keys(snapshot, SNAPSHOT)?;
        }
    }
    Ok(())
}

fn string_array(value: &Value) -> Result<Vec<String>, TransactionError> {
    value
        .as_array()
        .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?
        .iter()
        .map(|item| {
            item.as_str()
                .map(str::to_string)
                .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))
        })
        .collect()
}

fn u32_array(value: &Value) -> Result<Vec<u32>, TransactionError> {
    value
        .as_array()
        .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?
        .iter()
        .map(|item| {
            item.as_u64()
                .and_then(|number| u32::try_from(number).ok())
                .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))
        })
        .collect()
}

fn i32_array(value: &Value) -> Result<Vec<i32>, TransactionError> {
    value
        .as_array()
        .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))?
        .iter()
        .map(|item| {
            item.as_i64()
                .and_then(|number| i32::try_from(number).ok())
                .ok_or_else(|| error(RECOVERY_SOURCE_CHANGED))
        })
        .collect()
}

/// The canonical JSON shape the recovery freeze uses: sorted object keys, compact separators,
/// Foundation's `\/` escape for slashes, and no `.0` on an integral number.
pub fn canonical_json(value: &Value) -> String {
    let text = serde_json::to_string(value).unwrap_or_else(|_| "null".to_string());
    text.replace('/', "\\/")
}

/// Which manifest URLs name the editing session rather than the original document.
///
/// The session directory and the records inside it move with the cache; the original document
/// stays where it is. A revision URL that still equals the original document URL is the "no page
/// operation yet" form and is left untouched.
struct ManifestRetarget<'a> {
    old_directory_url: &'a str,
    old_directory: &'a Path,
    new_directory_url: &'a str,
    new_directory: &'a Path,
    original_url: &'a str,
}

impl ManifestRetarget<'_> {
    fn url(
        &self,
        url: &str,
        field: &str,
        allow_original: bool,
    ) -> Result<String, TransactionError> {
        if allow_original && url == self.original_url {
            return Ok(url.to_string());
        }
        let path = file_url_path(url).ok_or_else(|| {
            error(format!(
                "The cached editing session's {field} is not a local file URL: {url}"
            ))
        })?;
        // A manifest that was already retargeted is returned unchanged; this is what makes the
        // helper safe to call again when a migration was interrupted after writing the new copy.
        if path_has_prefix(&path, self.new_directory) {
            return Ok(url.to_string());
        }
        if !path_has_prefix(&path, self.old_directory) {
            return Err(error(format!(
                "The cached editing session's {field} is outside the previous cache directory, so it cannot be retargeted safely: {url}"
            )));
        }
        let relative = path.strip_prefix(self.old_directory).map_err(|_| {
            error(format!(
                "The cached editing session's {field} is not a plain file below the previous cache directory: {url}"
            ))
        })?;
        if relative
            .components()
            .any(|component| !matches!(component, std::path::Component::Normal(_)))
        {
            return Err(error(format!(
                "The cached editing session's {field} is not a plain file below the previous cache directory: {url}"
            )));
        }
        // Prefer splicing the raw URL string: it preserves the encoding Foundation used for the
        // unchanged part of the path. The decoded fallback handles a prefix spelled with
        // different percent escapes.
        if let Some(suffix) = url.strip_prefix(self.old_directory_url) {
            return Ok(format!("{}{suffix}", self.new_directory_url));
        }
        append_relative_url(self.new_directory_url, relative, field)
    }
}

/// Appends a decoded relative path to a directory URL, percent-encoding bytes that are not safe
/// in a path. The names the transaction generates (`session-<uuid>/rev-N.pdf`) are unaffected;
/// this exists so a cache under a path with spaces still gets a valid URL.
fn append_relative_url(
    directory_url: &str,
    relative: &Path,
    field: &str,
) -> Result<String, TransactionError> {
    let mut encoded = String::new();
    for component in relative.components() {
        let std::path::Component::Normal(component) = component else {
            return Err(error(format!(
                "The cached editing session's {field} is not a plain file below the previous cache directory."
            )));
        };
        let text = component.to_str().ok_or_else(|| {
            error(format!(
                "The cached editing session's {field} is not valid UTF-8."
            ))
        })?;
        if !encoded.is_empty() {
            encoded.push('/');
        }
        for byte in text.bytes() {
            let unreserved = byte.is_ascii_alphanumeric()
                || matches!(
                    byte,
                    b'-' | b'.'
                        | b'_'
                        | b'~'
                        | b'!'
                        | b'$'
                        | b'&'
                        | b'\''
                        | b'('
                        | b')'
                        | b'*'
                        | b'+'
                        | b','
                        | b';'
                        | b'='
                        | b':'
                        | b'@'
                );
            if unreserved {
                encoded.push(char::from(byte));
            } else {
                encoded.push_str(&format!("%{byte:02X}"));
            }
        }
    }
    Ok(format!("{directory_url}{encoded}"))
}

/// Rewrites the URLs in one `session.json` recovery manifest from the previous cache directory
/// to the current `DocumentId` directory.
///
/// The old layout keyed the cache by the canonical path alone; the current one appends the
/// document's content hash. A verbatim copy of the manifest would still name the old session
/// directory, and the restore path would reject it against the new cache prefix (its
/// directory-boundary check is deliberately strict). This function is the migration step:
/// it retargets `session.directory`, `annotationRecordsURL`, `originalRecordsURL`, `revisionURL`
/// and every undo/redo `revisionURL`. `originalURL` is never touched, and a revision URL that is
/// still the original document URL is kept as-is.
///
/// A URL that is neither below the old directory nor already below the new one is a foreign
/// path. Guessing what the reader meant would risk importing an unrestorable session, so that
/// case is an error and the caller must leave the legacy manifest in place.
///
/// The result uses the same canonical serialisation [`DocumentTransaction`] writes for
/// `session.json` (sorted object keys, compact separators, Foundation's `\/` escapes), so values
/// keep their meaning and a second call targeting the same directory is byte-identical.
pub fn retarget_recovery_manifest(
    manifest_json: &str,
    old_directory_url: &str,
    new_directory_url: &str,
) -> Result<String, TransactionError> {
    let mut document: Value = serde_json::from_str(manifest_json)
        .map_err(|parse| error(format!("The cached editing session is not JSON: {parse}")))?;
    let old_directory_url = directory_form(old_directory_url);
    let new_directory_url = directory_form(new_directory_url);
    let old_directory = file_url_path(&old_directory_url).ok_or_else(|| {
        error("The previous cache location is not a local file URL and cannot be migrated.")
    })?;
    let new_directory = file_url_path(&new_directory_url).ok_or_else(|| {
        error("The current cache location is not a local file URL and cannot receive the session.")
    })?;

    // A manifest this build cannot restore must not be imported and retired: refusing here
    // leaves the old files untouched and makes the shell report the shape it could not migrate.
    let version = document.get("version").and_then(Value::as_u64).unwrap_or(0);
    if version != u64::from(RECOVERY_VERSION) {
        return Err(error(format!(
            "The cached editing session uses version {version}; this build only migrates version {RECOVERY_VERSION}. The cached page edits were kept."
        )));
    }
    if !document.get("snapshot").is_some_and(Value::is_object) {
        return Err(error(
            "The cached editing session has no snapshot object and cannot be restored.",
        ));
    }
    let session = document
        .get_mut("session")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| error("The cached editing session has no session object."))?;
    let original_url = session
        .get("originalURL")
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| error("The cached editing session names no original document URL."))?;
    let retarget = ManifestRetarget {
        old_directory_url: &old_directory_url,
        old_directory: &old_directory,
        new_directory_url: &new_directory_url,
        new_directory: &new_directory,
        original_url: &original_url,
    };

    for (field, allow_original) in [
        ("directory", false),
        ("annotationRecordsURL", false),
        ("originalRecordsURL", false),
        ("revisionURL", true),
    ] {
        let url = session
            .get(field)
            .and_then(Value::as_str)
            .ok_or_else(|| error(format!("The cached editing session has no {field}.")))?;
        let rewritten = retarget.url(url, field, allow_original)?;
        session.insert(field.to_string(), Value::String(rewritten));
    }

    for stack in ["undo", "redo"] {
        let snapshots = session
            .get_mut(stack)
            .and_then(Value::as_array_mut)
            .ok_or_else(|| {
                error(format!(
                    "The cached editing session has no {stack} snapshot array."
                ))
            })?;
        for (index, snapshot) in snapshots.iter_mut().enumerate() {
            let snapshot = snapshot.as_object_mut().ok_or_else(|| {
                error(format!(
                    "The cached editing session's {stack}[{index}] is not an object."
                ))
            })?;
            let field = format!("{stack}[{index}].revisionURL");
            let url = snapshot
                .get("revisionURL")
                .and_then(Value::as_str)
                .ok_or_else(|| error(format!("The cached editing session has no {field}.")))?;
            let rewritten = retarget.url(url, &field, true)?;
            snapshot.insert("revisionURL".to_string(), Value::String(rewritten));
        }
    }

    Ok(canonical_json(&document))
}

fn number(value: f64) -> Value {
    if value.is_finite()
        && value.fract() == 0.0
        && let Ok(integer) = i64::try_from(value as i128)
    {
        return Value::Number(Number::from(integer));
    }
    Number::from_f64(value)
        .map(Value::Number)
        .unwrap_or(Value::Null)
}

fn directory_form(url: &str) -> String {
    if url.ends_with('/') {
        url.to_string()
    } else {
        format!("{url}/")
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".session-{}-{}.tmp",
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        #[cfg(unix)]
        fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        // Only the private temporary file from this write is disposable.
        let _ = fs::remove_file(temporary);
    }
    result
}

fn path_has_prefix(path: &Path, prefix: &Path) -> bool {
    path.starts_with(prefix)
}

fn same_file(left: &Path, right: &Path) -> bool {
    let left = fs::canonicalize(left).unwrap_or_else(|_| left.to_path_buf());
    let right = fs::canonicalize(right).unwrap_or_else(|_| right.to_path_buf());
    left == right
}

/// Encodes a local absolute path in the same file-URL vocabulary the native shells persist.
/// The platform adapter uses this boundary instead of maintaining another URL codec.
pub fn path_file_url(path: &Path, directory: bool) -> Result<String, TransactionError> {
    if !path.is_absolute() {
        return Err(error("A recovery file URL must name an absolute path."));
    }
    let text = path
        .to_str()
        .ok_or_else(|| error("The recovery path is not valid UTF-8."))?;
    #[cfg(windows)]
    let text = text.replace('\\', "/");
    #[cfg(windows)]
    let text = text.as_str();
    const ESCAPED: &percent_encoding::AsciiSet = &percent_encoding::CONTROLS
        .add(b'\\')
        .add(b' ')
        .add(b'%')
        .add(b'#')
        .add(b'?')
        .add(b'"')
        .add(b'<')
        .add(b'>')
        .add(b'`')
        .add(b'{')
        .add(b'}');
    let encoded = percent_encoding::utf8_percent_encode(text, ESCAPED);
    #[cfg(windows)]
    let mut url = if text.starts_with("//") {
        format!("file:{encoded}")
    } else {
        format!("file:///{encoded}")
    };
    #[cfg(not(windows))]
    let mut url = format!("file://{encoded}");
    if directory && !url.ends_with('/') {
        url.push('/');
    }
    Ok(url)
}

/// Decodes local file URLs, including drive and UNC paths on Windows.
pub fn file_url_path(url: &str) -> Option<PathBuf> {
    let rest = url.strip_prefix("file://")?;
    #[cfg(not(windows))]
    let text = if rest.starts_with('/') {
        rest
    } else {
        let local = rest.strip_prefix("localhost")?;
        if !local.starts_with('/') {
            return None;
        }
        local
    };
    #[cfg(windows)]
    let text = if rest.starts_with('/') {
        if rest.as_bytes().get(2) == Some(&b':') {
            &rest[1..]
        } else {
            rest
        }
    } else if let Some(local) = rest.strip_prefix("localhost/") {
        local
    } else {
        return Some(PathBuf::from(format!(
            "//{}",
            percent_encoding::percent_decode_str(rest)
                .decode_utf8()
                .ok()?
        )));
    };
    Some(PathBuf::from(
        percent_encoding::percent_decode_str(text)
            .decode_utf8()
            .ok()?
            .as_ref(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn annotation(id: &str, page: u32) -> Value {
        serde_json::json!({"id": id, "kind": "highlight", "page": page, "start": 0, "end": 3})
    }

    fn bookmark(id: &str, page: u32) -> Value {
        serde_json::json!({"id": id, "kind": "bookmark", "page": page, "title": id, "yPt": 1})
    }

    fn slot(annotation: Option<&str>, bookmark: Option<&str>) -> Value {
        if let Some(id) = annotation {
            return serde_json::json!({"annotation": {"_0": id}});
        }
        if let Some(id) = bookmark {
            return serde_json::json!({"bookmark": {"_0": id}});
        }
        serde_json::json!({"opaque": {"_0": "{\"future\":true}"}})
    }

    fn state() -> AnnotationState {
        AnnotationState {
            annotations: vec![annotation("a", 0), annotation("b", 1)],
            bookmarks: vec![bookmark("m", 1)],
            slots: vec![
                slot(Some("a"), None),
                slot(Some("b"), None),
                slot(None, Some("m")),
                slot(None, None),
            ],
            deletions: Vec::new(),
            erased_ink: Vec::new(),
            annotation_dirty: true,
            current_page: 1,
            selection: vec![0],
        }
    }

    #[test]
    fn remap_follows_pages_and_drops_removed_marks() {
        let mapped = state().remapped(&vec![Some(0), None, Some(1)]);
        assert_eq!(mapped.annotations.len(), 1);
        assert_eq!(mapped.annotations[0]["id"], "a");
        assert_eq!(mapped.annotations[0]["page"], 0);
        assert!(mapped.bookmarks.is_empty());
        assert_eq!(
            mapped.slots.len(),
            2,
            "the removed mark's slot is dropped, opaque kept"
        );
    }

    #[test]
    fn remap_composes_current_to_original() {
        let directory = tempdir();
        let request = StartRequest {
            original_url: "file:///tmp/original.pdf".to_string(),
            directory_url: format!("file://{}/", directory.display()),
            recovery_path: directory.join("session.json"),
            original_records_url: "file:///tmp/annotations.json".to_string(),
            title: "T".to_string(),
            page_count: 3,
            original_rotations: vec![0, 0, 0],
            original_signature_json: "{\"evidence\":[],\"signed\":false}".to_string(),
            source_size: 1,
            source_modified: Some(700_000_000.0),
            source_sha256: "x".to_string(),
            annotations_json: "[]".to_string(),
            bookmarks_json: "[]".to_string(),
            slots_json: "[]".to_string(),
            deletions_json: "[]".to_string(),
            erased_ink_json: "[]".to_string(),
            annotation_dirty: false,
            current_page: 1,
            selection: vec![0],
            cache_directory_prefix: directory.display().to_string(),
            restore: false,
        };
        let mut transaction = DocumentTransaction::start(request).unwrap();
        let target = transaction.next_revision().unwrap();
        transaction.begin_apply("Insert", state()).unwrap();
        let applied = transaction
            .apply_report(
                target,
                &PageOperationReport {
                    page_count: 4,
                    page_map: vec![Some(0), Some(2), Some(3)],
                    inserted_page: Some(1),
                },
            )
            .unwrap();
        assert_eq!(applied.current_to_original, vec![0, -1, 1, 2]);
        assert_eq!(applied.state.current_page, 2);
        assert_eq!(applied.state.selection, vec![1]);
        assert!(applied.can_undo && !applied.can_redo);
        let undone = transaction.undo(applied.state.clone()).unwrap().unwrap();
        assert_eq!(undone.revision_number, 0);
        assert_eq!(undone.state.annotations[1]["page"], 1);
        assert!(undone.can_redo);
        std::fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn next_revision_is_one_ahead_and_in_the_session_directory() {
        let directory = tempdir();
        fs::create_dir_all(&directory).unwrap();
        let request = StartRequest {
            original_url: "file:///tmp/original.pdf".to_string(),
            directory_url: format!("file://{}/", directory.display()),
            recovery_path: directory.join("session.json"),
            original_records_url: "file:///tmp/annotations.json".to_string(),
            title: "T".to_string(),
            page_count: 1,
            original_rotations: vec![0],
            original_signature_json: "{\"evidence\":[],\"signed\":false}".to_string(),
            source_size: 1,
            source_modified: None,
            source_sha256: "x".to_string(),
            annotations_json: "[]".to_string(),
            bookmarks_json: "[]".to_string(),
            slots_json: "[]".to_string(),
            deletions_json: "[]".to_string(),
            erased_ink_json: "[]".to_string(),
            annotation_dirty: false,
            current_page: 1,
            selection: Vec::new(),
            cache_directory_prefix: directory.display().to_string(),
            restore: false,
        };
        let mut transaction = DocumentTransaction::start(request).unwrap();
        let first = transaction.next_revision().unwrap();
        assert_eq!(
            first.url,
            format!("file://{}/rev-1.pdf", directory.display())
        );
        transaction
            .begin_apply("Rotate", AnnotationState::default())
            .unwrap();
        transaction
            .apply_report(
                first,
                &PageOperationReport {
                    page_count: 1,
                    page_map: vec![Some(0)],
                    inserted_page: None,
                },
            )
            .unwrap();
        let second = transaction.next_revision().unwrap();
        assert_eq!(
            second.url,
            format!("file://{}/rev-2.pdf", directory.display())
        );
        transaction.close(true).unwrap();
        std::fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn a_materialised_annotation_revision_is_not_the_undo_target() {
        let directory = tempdir();
        fs::create_dir_all(&directory).unwrap();
        let request = StartRequest {
            original_url: "file:///tmp/original.pdf".to_string(),
            directory_url: format!("file://{}/", directory.display()),
            recovery_path: directory.join("session.json"),
            original_records_url: "file:///tmp/annotations.json".to_string(),
            title: "T".to_string(),
            page_count: 1,
            original_rotations: vec![0],
            original_signature_json: "{\"evidence\":[],\"signed\":false}".to_string(),
            source_size: 1,
            source_modified: None,
            source_sha256: "x".to_string(),
            annotations_json: "[]".to_string(),
            bookmarks_json: "[]".to_string(),
            slots_json: "[]".to_string(),
            deletions_json: "[]".to_string(),
            erased_ink_json: "[]".to_string(),
            annotation_dirty: false,
            current_page: 1,
            selection: Vec::new(),
            cache_directory_prefix: directory.display().to_string(),
            restore: false,
        };
        let mut transaction = DocumentTransaction::start(request).unwrap();
        let input = state();
        transaction.begin_apply("Rotate", input.clone()).unwrap();
        // The shell materialises the marks into `marks-<uuid>.pdf` before rotating; that
        // changes the revision URL but must not become the undo target.
        let marks_url = format!("file://{}/marks-test.pdf", directory.display());
        transaction
            .persist(
                AnnotationState::default(),
                marks_url.clone(),
                0,
                directory.join("session.json"),
            )
            .unwrap();
        let target = transaction.next_revision().unwrap();
        transaction
            .apply_report(
                target,
                &PageOperationReport {
                    page_count: 1,
                    page_map: vec![Some(0)],
                    inserted_page: None,
                },
            )
            .unwrap();
        let undone = transaction
            .undo(AnnotationState::default())
            .unwrap()
            .unwrap();
        assert_eq!(undone.revision_url, "file:///tmp/original.pdf");
        assert_eq!(undone.state.annotations.len(), 2);
        transaction.close(true).unwrap();
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn canonical_json_matches_foundation_url_escaping_and_integral_numbers() {
        let value = serde_json::json!({
            "url": "file:///tmp/a/b.pdf",
            "n": 700_000_000.0,
            "d": 12.5,
            "u": "11111111-2222-3333-4444-555555555555",
        });
        let text = canonical_json(&value);
        assert!(
            text.contains("\"url\":\"file:\\/\\/\\/tmp\\/a\\/b.pdf\""),
            "{text}"
        );
        assert!(text.contains("\"n\":700000000"), "{text}");
        assert!(text.contains("\"d\":12.5"), "{text}");
    }

    const LEGACY_DIRECTORY: &str = "file:///tmp/lyra-migration/legacy-key/";
    const NEW_DIRECTORY: &str = "file:///tmp/lyra-migration/new-identity/";
    const ORIGINAL_URL: &str = "file:///tmp/lyra-migration/paper.pdf";

    /// A manifest with every URL-bearing field the old layout wrote, plus one unknown key that
    /// the migration must pass through untouched.
    fn migration_manifest() -> String {
        serde_json::json!({
            "version": RECOVERY_VERSION,
            "session": {
                "originalURL": ORIGINAL_URL,
                "originalSignature": {"evidence": [], "readOnlyReason": null, "signed": false},
                "sourceStamp": {"size": 1234, "sha256": "abc"},
                "originalRecordsURL": "file:///tmp/lyra-migration/legacy-key/annotations.json",
                "title": "paper",
                "directory": "file:///tmp/lyra-migration/legacy-key/session-AAAA/",
                "annotationRecordsURL": "file:///tmp/lyra-migration/legacy-key/session-AAAA/annotations.json",
                "originalRotations": [0, 0, 0],
                "revisionURL": "file:///tmp/lyra-migration/legacy-key/session-AAAA/rev-1.pdf",
                "revisionNumber": 1,
                "currentToOriginal": [0, -1, 1, 2],
                "operations": ["Insert a blank page before page 2"],
                "undo": [{
                    "revisionURL": ORIGINAL_URL,
                    "revisionNumber": 0,
                    "currentToOriginal": [0, 1, 2],
                    "operations": [],
                    "annotations": [],
                    "bookmarks": [],
                    "slots": [],
                    "deletions": [],
                    "erasedInk": [],
                    "annotationDirty": false,
                    "currentPage": 1,
                    "selection": [],
                    "label": "Original"
                }],
                "redo": [{
                    "revisionURL": "file:///tmp/lyra-migration/legacy-key/session-AAAA/rev-2.pdf",
                    "revisionNumber": 2,
                    "currentToOriginal": [0, -1, 1, 2],
                    "operations": ["Insert a blank page before page 2"],
                    "annotations": [],
                    "bookmarks": [],
                    "slots": [],
                    "deletions": [],
                    "erasedInk": [],
                    "annotationDirty": false,
                    "currentPage": 1,
                    "selection": [],
                    "label": "Redo"
                }],
                "futureSessionField": {"keep": [1, 2, 3]}
            },
            "snapshot": {
                "revisionURL": "file:///tmp/lyra-migration/legacy-key/session-AAAA/rev-1.pdf",
                "revisionNumber": 1,
                "currentToOriginal": [0, -1, 1, 2],
                "operations": ["Insert a blank page before page 2"],
                "annotations": [],
                "bookmarks": [],
                "slots": [],
                "deletions": [],
                "erasedInk": [],
                "annotationDirty": false,
                "currentPage": 1,
                "selection": [],
                "label": "Insert a blank page before page 2"
            }
        })
        .to_string()
    }

    fn migrate(json: &str) -> Result<String, TransactionError> {
        retarget_recovery_manifest(json, LEGACY_DIRECTORY, NEW_DIRECTORY)
    }

    #[test]
    fn retarget_rewrites_every_session_url_and_preserves_other_values() {
        let migrated = migrate(&migration_manifest()).unwrap();
        let value: Value = serde_json::from_str(&migrated).unwrap();
        let session = &value["session"];
        assert_eq!(
            session["directory"],
            "file:///tmp/lyra-migration/new-identity/session-AAAA/"
        );
        assert_eq!(
            session["annotationRecordsURL"],
            "file:///tmp/lyra-migration/new-identity/session-AAAA/annotations.json"
        );
        assert_eq!(
            session["originalRecordsURL"],
            "file:///tmp/lyra-migration/new-identity/annotations.json"
        );
        assert_eq!(
            session["revisionURL"],
            "file:///tmp/lyra-migration/new-identity/session-AAAA/rev-1.pdf"
        );
        assert_eq!(
            session["undo"][0]["revisionURL"], ORIGINAL_URL,
            "a revision URL that is still the original document stays the original"
        );
        assert_eq!(
            session["redo"][0]["revisionURL"],
            "file:///tmp/lyra-migration/new-identity/session-AAAA/rev-2.pdf"
        );
        assert_eq!(
            session["originalURL"], ORIGINAL_URL,
            "the original document URL is never rewritten"
        );
        assert_eq!(
            session["futureSessionField"],
            serde_json::json!({"keep": [1, 2, 3]}),
            "unknown fields pass through with their value"
        );
        assert_eq!(
            value["snapshot"]["revisionURL"],
            "file:///tmp/lyra-migration/legacy-key/session-AAAA/rev-1.pdf",
            "the snapshot is the transaction's data, not a URL the shell restores from"
        );
        // The output is the crate's canonical `session.json` shape: compact, sorted keys, `/`
        // escaped the way Foundation writes a URL.
        assert!(
            migrated.contains("\\/tmp\\/lyra-migration\\/new-identity\\/session-AAAA\\/rev-1.pdf"),
            "{migrated}"
        );
    }

    #[test]
    fn retarget_rejects_a_foreign_url_instead_of_guessing() {
        let mut value: Value = serde_json::from_str(&migration_manifest()).unwrap();
        value["session"]["revisionURL"] =
            Value::String("file:///tmp/somewhere-else/rev-1.pdf".to_string());
        let failure = migrate(&value.to_string()).unwrap_err();
        assert!(
            failure.0.contains("outside the previous cache directory"),
            "{failure}"
        );

        let mut value: Value = serde_json::from_str(&migration_manifest()).unwrap();
        value["session"]["undo"][0]["revisionURL"] =
            Value::String("file:///tmp/somewhere-else/rev-0.pdf".to_string());
        let failure = migrate(&value.to_string()).unwrap_err();
        assert!(failure.0.contains("undo[0].revisionURL"), "{failure}");

        // A sibling directory that merely shares the string prefix is not inside the old cache.
        let mut value: Value = serde_json::from_str(&migration_manifest()).unwrap();
        value["session"]["annotationRecordsURL"] = Value::String(
            "file:///tmp/lyra-migration/legacy-key-evil/annotations.json".to_string(),
        );
        let failure = migrate(&value.to_string()).unwrap_err();
        assert!(failure.0.contains("annotationRecordsURL"), "{failure}");
    }

    #[test]
    fn retarget_leaves_the_original_document_url_untouched() {
        let migrated = migrate(&migration_manifest()).unwrap();
        let value: Value = serde_json::from_str(&migrated).unwrap();
        assert_eq!(value["session"]["originalURL"], ORIGINAL_URL);
        assert_eq!(value["session"]["undo"][0]["revisionURL"], ORIGINAL_URL);
        assert!(
            !migrated.contains("new-identity/paper.pdf"),
            "the original document must not be redirected into the cache: {migrated}"
        );
    }

    #[test]
    fn retarget_rejects_invalid_json_and_unsupported_shapes() {
        let failure = migrate("{this is not json").unwrap_err();
        assert!(failure.0.contains("not JSON"), "{failure}");

        let failure = migrate(r#"{"version":1}"#).unwrap_err();
        assert!(failure.0.contains("snapshot"), "{failure}");

        let mut future: Value = serde_json::from_str(&migration_manifest()).unwrap();
        future["version"] = serde_json::json!(RECOVERY_VERSION + 1);
        let failure = migrate(&future.to_string()).unwrap_err();
        assert!(failure.0.contains("version"), "{failure}");

        let mut missing: Value = serde_json::from_str(&migration_manifest()).unwrap();
        missing["session"]
            .as_object_mut()
            .unwrap()
            .remove("directory");
        let failure = migrate(&missing.to_string()).unwrap_err();
        assert!(failure.0.contains("directory"), "{failure}");
    }

    #[test]
    fn retarget_is_idempotent_once_the_prefix_is_new() {
        let once = migrate(&migration_manifest()).unwrap();
        let twice = retarget_recovery_manifest(&once, LEGACY_DIRECTORY, NEW_DIRECTORY).unwrap();
        assert_eq!(once, twice);
    }

    #[test]
    fn retarget_handles_percent_escaped_and_spaced_directories() {
        let manifest = migration_manifest()
            .replace("legacy-key", "legacy%20key")
            .replace(ORIGINAL_URL, "file:///tmp/lyra-migration/paper.pdf");
        let migrated = retarget_recovery_manifest(
            &manifest,
            "file:///tmp/lyra-migration/legacy%20key/",
            "file:///tmp/lyra-migration/new%20identity/",
        )
        .unwrap();
        let value: Value = serde_json::from_str(&migrated).unwrap();
        assert_eq!(
            value["session"]["revisionURL"],
            "file:///tmp/lyra-migration/new%20identity/session-AAAA/rev-1.pdf"
        );
    }

    #[test]
    fn local_file_urls_round_trip_unicode_and_reserved_filename_characters() {
        let root = tempdir();
        let path = root.join("论文 100% #?.pdf");
        let url = path_file_url(&path, false).unwrap();
        assert!(
            url.contains("%20")
                && url.contains("%25")
                && url.contains("%23")
                && url.contains("%3F")
        );
        assert_eq!(file_url_path(&url), Some(path));
        let directory = path_file_url(&root, true).unwrap();
        assert!(directory.ends_with('/'));
        assert_eq!(file_url_path(&directory), Some(root.clone()));
        assert!(path_file_url(Path::new("relative.pdf"), false).is_err());
        assert!(file_url_path("https://example.invalid/paper.pdf").is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn explicit_history_limits_collect_only_unreachable_generated_files_and_honor_leases() {
        let root = tempdir();
        let directory = root.join("session-history");
        fs::create_dir(&directory).unwrap();
        let mut transaction = DocumentTransaction::start(test_request(&root, &directory)).unwrap();
        for number in 1..=4 {
            let path = directory.join(format!("rev-{number}.pdf"));
            fs::write(&path, b"revision").unwrap();
            transaction
                .begin_apply("Change", AnnotationState::default())
                .unwrap();
            transaction
                .commit_external(
                    path_file_url(&path, false).unwrap(),
                    number,
                    "Change",
                    AnnotationState::default(),
                )
                .unwrap();
        }
        transaction.limit_history(2, u64::MAX).unwrap();
        assert_eq!(transaction.undo.len(), 2);
        let leased = path_file_url(&directory.join("rev-1.pdf"), false).unwrap();
        fs::write(directory.join("unrelated.pdf"), b"external").unwrap();
        assert_eq!(transaction.collect_revision_garbage(&[leased]).unwrap(), 0);
        assert_eq!(transaction.collect_revision_garbage(&[]).unwrap(), 1);
        assert!(!directory.join("rev-1.pdf").exists());
        assert!(directory.join("unrelated.pdf").exists());
        transaction.limit_history(2, 1).unwrap();
        assert_eq!(
            transaction.undo.len(),
            1,
            "one undo remains even above the nominal byte budget"
        );
        assert_eq!(transaction.collect_revision_garbage(&[]).unwrap(), 1);
        let target = transaction.next_revision().unwrap();
        fs::write(&target.path, b"leased after branch").unwrap();
        assert_eq!(
            transaction.next_revision().unwrap().number,
            target.number + 1
        );
        transaction.revision_number = u32::MAX;
        assert!(transaction.next_revision().is_err());
        transaction.close(true).unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn recovery_refuses_unknown_structure_truncated_numbers_and_unwritable_start() {
        let root = tempdir();
        let directory = root.join("session-validation");
        fs::create_dir(&directory).unwrap();
        let request = test_request(&root, &directory);
        let transaction = DocumentTransaction::start(request.clone()).unwrap();
        let original = transaction.recovery_value();
        for case in [
            "unknown",
            "page-overflow",
            "selection-type",
            "revision-overflow",
        ] {
            let mut value = original.clone();
            match case {
                "unknown" => value["session"]["futureState"] = serde_json::json!({"preserve":true}),
                "page-overflow" => value["snapshot"]["currentPage"] = serde_json::json!(u64::MAX),
                "selection-type" => value["snapshot"]["selection"] = serde_json::json!(["0"]),
                _ => {
                    value["session"]["revisionNumber"] = serde_json::json!(u64::MAX);
                    value["snapshot"]["revisionNumber"] = serde_json::json!(u64::MAX);
                }
            }
            let bytes = serde_json::to_vec(&value).unwrap();
            fs::write(&request.recovery_path, &bytes).unwrap();
            let mut restore = request.clone();
            restore.restore = true;
            assert!(DocumentTransaction::start(restore).is_err(), "{case}");
            assert_eq!(fs::read(&request.recovery_path).unwrap(), bytes);
        }
        let mut unwritable = request;
        fs::write(root.join("blocked"), b"not a directory").unwrap();
        unwritable.recovery_path = root.join("blocked/session.json");
        assert!(DocumentTransaction::start(unwritable).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    fn test_request(root: &Path, directory: &Path) -> StartRequest {
        StartRequest {
            original_url: path_file_url(&root.join("original.pdf"), false).unwrap(),
            directory_url: path_file_url(directory, true).unwrap(),
            recovery_path: root.join("session.json"),
            original_records_url: path_file_url(&root.join("annotations.json"), false).unwrap(),
            title: "T".into(),
            page_count: 1,
            original_rotations: vec![0],
            original_signature_json: "{}".into(),
            source_size: 1,
            source_modified: None,
            source_sha256: "source".into(),
            annotations_json: "[]".into(),
            bookmarks_json: "[]".into(),
            slots_json: "[]".into(),
            deletions_json: "[]".into(),
            erased_ink_json: "[]".into(),
            annotation_dirty: false,
            current_page: 1,
            selection: vec![],
            cache_directory_prefix: root.to_string_lossy().into_owned(),
            restore: false,
        }
    }

    #[test]
    fn retired_session_cleanup_cannot_delete_a_new_window_recovery_manifest() {
        let root = tempdir();
        let directory = root.join("session-first");
        fs::create_dir(&directory).unwrap();
        let request = StartRequest {
            original_url: path_file_url(&root.join("original.pdf"), false).unwrap(),
            directory_url: path_file_url(&directory, true).unwrap(),
            recovery_path: root.join("session.json"),
            original_records_url: path_file_url(&root.join("annotations.json"), false).unwrap(),
            title: "T".into(),
            page_count: 1,
            original_rotations: vec![0],
            original_signature_json: "{}".into(),
            source_size: 1,
            source_modified: None,
            source_sha256: "source".into(),
            annotations_json: "[]".into(),
            bookmarks_json: "[]".into(),
            slots_json: "[]".into(),
            deletions_json: "[]".into(),
            erased_ink_json: "[]".into(),
            annotation_dirty: false,
            current_page: 1,
            selection: vec![],
            cache_directory_prefix: root.to_string_lossy().into_owned(),
            restore: false,
        };
        let mut first = DocumentTransaction::start(request.clone()).unwrap();
        first.retire_recovery().unwrap();
        assert!(!request.recovery_path.exists());
        assert!(directory.join("retired-session.json").exists());
        let next_directory = root.join("session-next");
        fs::create_dir(&next_directory).unwrap();
        let mut next_request = request.clone();
        next_request.directory_url = path_file_url(&next_directory, true).unwrap();
        let mut next = DocumentTransaction::start(next_request).unwrap();
        let bytes = fs::read(&request.recovery_path).unwrap();
        first.close(true).unwrap();
        assert!(!directory.exists());
        assert_eq!(fs::read(&request.recovery_path).unwrap(), bytes);
        next.close(true).unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    fn tempdir() -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "lyra-edit-transaction-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }
}

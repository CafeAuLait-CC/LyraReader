//! Native-shell file adapter for a resolved application quit. No draft is retired here.
//! Per-document receipts become effective only at one batch commit point. A failed
//! preparation or process exit before that point leaves normal recovery intact.
use crate::{
    document::DesktopDocument, document_cache, draft_store, marks::Marks, pages::PageEdits,
};
use lyra_reader_core::sync::lock;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
};

pub(super) const MAX_DOCUMENTS: usize = 256;
const MAX_RECEIPT_BYTES: u64 = 16 * 1024;
const MAX_BATCH_BYTES: u64 = 128 * 1024;
const VERSION: u32 = 1;
static WRITER: Mutex<()> = Mutex::new(());
// A live process must finish its UI epoch check before another open can consume
// its new decision. After an actual process exit the durable batch is authoritative.
static PENDING: Mutex<BTreeMap<String, String>> = Mutex::new(BTreeMap::new());

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct DraftDigest {
    records: Option<String>,
    pending: Option<String>,
}
impl From<draft_store::Pair> for DraftDigest {
    fn from(pair: draft_store::Pair) -> Self {
        Self {
            records: pair.records.as_deref().map(hash),
            pending: pair.pending.as_deref().map(hash),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct SessionFingerprint {
    directory: PathBuf,
    work: String,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct Fingerprint {
    document: PathBuf,
    cache: PathBuf,
    source: Option<String>,
    original: DraftDigest,
    active: DraftDigest,
    // Shared typed transaction state, excluding only the current reading position.
    // A no-op position flush may rewrite the manifest without changing the work.
    session: Option<SessionFingerprint>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Marker {
    version: u32,
    batch: String,
    fingerprint: Fingerprint,
    manifest_digest: Option<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Batch {
    version: u32,
    resolution: Resolution,
    members: BTreeMap<String, String>,
}
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Resolution {
    Save,
    Discard,
}

/// The caller may cancel only this exact committed decision if its UI epoch changes.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Receipt {
    root: PathBuf,
    batch: String,
    digest: String,
    pub warning: Option<String>,
}

fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
fn digest_file(path: &Path) -> Result<Option<String>, String> {
    Ok(document_cache::read_optional(path)?.as_deref().map(hash))
}
fn marker_name(document: &Path) -> String {
    format!("{}.linux-quit.json", document_cache::legacy_key(document))
}
fn valid_marker_name(name: &str) -> bool {
    name.strip_suffix(".linux-quit.json")
        .is_some_and(|key| key.len() == 64 && key.bytes().all(|b| b.is_ascii_hexdigit()))
}
fn valid_batch_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, b)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn batch_path(root: &Path, id: &str) -> Result<PathBuf, String> {
    if !valid_batch_id(id) {
        return Err("The quit receipt has an invalid batch identity; drafts were kept".into());
    }
    Ok(root.join(format!("linux-quit-{id}.json")))
}

fn fingerprint(marks: &Marks, edits: &PageEdits) -> Result<Fingerprint, String> {
    let active = marks.check_quit_draft()?.into();
    let original_marks = edits.original.as_ref().unwrap_or(marks);
    let original = original_marks.check_quit_draft()?.into();
    let cache = original_marks.cache_location()?;
    let session = edits.quit_state()?.map(|state| {
        // These are engine DTO fields, not a second parser of the recovery manifest.
        let directory = lyra_reader_edit::transaction::file_url_path(&state.directory_url)
            .ok_or("Invalid quit session directory")?;
        let directory = owned_session_directory(&cache.directory, &directory)?;
        let work = serde_json::json!({
            "original": state.original_url, "directory": state.directory_url,
            "records": state.annotation_records_url, "original_records": state.original_records_url,
            "revision": state.revision_url, "number": state.revision_number,
            "map": state.current_to_original, "operations": state.operations,
            "annotations": state.annotations_json, "bookmarks": state.bookmarks_json,
            "slots": state.slots_json, "deletions": state.deletions_json,
            "erased_ink": state.erased_ink_json, "dirty": state.annotation_dirty,
            "source_size": state.source_size, "source_sha256": state.source_sha256
        });
        serde_json::to_vec(&work).map(|bytes| SessionFingerprint {directory, work: hash(&bytes)}).map_err(|e| e.to_string())
    }).transpose()?;
    Ok(Fingerprint {
        document: cache.document.clone(),
        cache: cache.directory.clone(),
        source: digest_file(&cache.directory.join("source.json"))?,
        original,
        active,
        session,
    })
}

pub(super) fn resolve(documents: &[&DesktopDocument], resolution: u32) -> Result<Receipt, String> {
    let resolution = match resolution {
        0 => Resolution::Save,
        1 => Resolution::Discard,
        _ => return Err("Invalid quit resolution".into()),
    };
    if documents.is_empty() || documents.len() > MAX_DOCUMENTS {
        return Err("The quit decision must contain between 1 and 256 documents".into());
    }
    let _writer = lock(&WRITER).map_err(|e| e.to_string())?;
    // Lock order matches page mutations: edits, then marks. Sorting also makes two
    // concurrent batch callers agree; no operation takes locks in another document.
    let mut ordered = documents.to_vec();
    let mut seen = std::collections::HashSet::new();
    ordered.retain(|document| seen.insert(std::ptr::from_ref(*document)));
    ordered.sort_by_key(|document| document.original_path.clone());
    let edits = ordered
        .iter()
        .map(|document| lock(&document.edits).map_err(|e| e.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    let marks = ordered
        .iter()
        .map(|document| lock(&document.marks).map_err(|e| e.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    let root = marks[0].cache_location()?.root.clone();
    let id = crate::marks::uuid()?;
    let mut entries = BTreeMap::new();
    for (marks, edits) in marks.iter().zip(&edits) {
        if marks.cache_location()?.root != root {
            return Err("A quit batch cannot mix document cache locations".into());
        }
        let value = fingerprint(marks, edits)?;
        let name = marker_name(&value.document);
        if let Some(previous) = entries.get(&name) {
            if previous != &value {
                return Err(
                    "The same document has different drafts in two readers. All drafts were kept"
                        .into(),
                );
            }
        } else {
            entries.insert(name, value);
        }
    }
    let mut members = BTreeMap::new();
    for (name, value) in &entries {
        let bytes = serde_json::to_vec(&Marker {
            version: VERSION,
            batch: id.clone(),
            fingerprint: value.clone(),
            manifest_digest: digest_file(&value.cache.join("session.json"))?,
        })
        .map_err(|e| e.to_string())?;
        if bytes.len() as u64 > MAX_RECEIPT_BYTES {
            return Err("The quit receipt exceeds its size limit; drafts were kept".into());
        }
        document_cache::atomic_write(&root.join(name), &bytes)?;
        members.insert(name.clone(), hash(&bytes));
    }
    // Catch external changes during receipt preparation as well. Partial receipts
    // are inert: without the committed batch none can resolve a draft on next open.
    for (marks, edits) in marks.iter().zip(&edits) {
        let current = fingerprint(marks, edits)?;
        if entries.get(&marker_name(&current.document)) != Some(&current) {
            return Err("The drafts changed while recording the quit. All drafts were kept".into());
        }
    }
    let bytes = serde_json::to_vec(&Batch {
        version: VERSION,
        resolution,
        members,
    })
    .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_BATCH_BYTES {
        return Err("The quit batch exceeds its size limit; drafts were kept".into());
    }
    let destination = batch_path(&root, &id)?;
    let staged = root.join(format!(".linux-quit-{id}.prepared"));
    document_cache::atomic_write(&staged, &bytes)?;
    {
        let mut pending = lock(&PENDING).map_err(|e| e.to_string())?;
        if pending.len() >= MAX_DOCUMENTS {
            return Err("Too many unresolved quit decisions; all drafts were kept".into());
        }
        pending.insert(id.clone(), hash(&bytes));
    }
    // Rename is the one commit point and the last operation allowed to return an
    // uncommitted error. A later directory-sync failure is a committed warning.
    if let Err(error) = fs::rename(&staged, &destination) {
        // Only this attempt's random preparation is disposable; receipts stay inert.
        let _ = fs::remove_file(&staged);
        if let Ok(mut pending) = lock(&PENDING) {
            pending.remove(&id);
        }
        return Err(error.to_string());
    }
    #[cfg(unix)]
    let warning = fs::File::open(&root)
        .and_then(|file| file.sync_all())
        .err()
        .map(|e| {
            format!("The quit decision was committed, but its directory could not be synced: {e}")
        });
    #[cfg(not(unix))]
    let warning = None;
    Ok(Receipt {
        root,
        batch: id,
        digest: hash(&bytes),
        warning,
    })
}

// Bounded in-memory acknowledgement only: no filesystem, PDFium or long writer lock.
pub(super) fn activate(receipt: &[u8]) -> Result<(), String> {
    if receipt.len() as u64 > MAX_RECEIPT_BYTES {
        return Err("Invalid quit receipt size".into());
    }
    let receipt: Receipt = serde_json::from_slice(receipt).map_err(|e| e.to_string())?;
    let mut pending = lock(&PENDING).map_err(|e| e.to_string())?;
    if pending.get(&receipt.batch) != Some(&receipt.digest) {
        return Err("The pending quit decision changed; keep the reader windows open".into());
    }
    pending.remove(&receipt.batch);
    Ok(())
}

pub(super) fn cancel(document: &DesktopDocument, receipt: &[u8]) -> Result<(), String> {
    if receipt.len() as u64 > MAX_RECEIPT_BYTES {
        return Err("Invalid quit receipt size".into());
    }
    let receipt: Receipt = serde_json::from_slice(receipt).map_err(|e| e.to_string())?;
    let _writer = lock(&WRITER).map_err(|e| e.to_string())?;
    let marks = lock(&document.marks).map_err(|e| e.to_string())?;
    if marks.cache_location()?.root != receipt.root {
        return Err("The quit receipt belongs to another cache".into());
    }
    let path = batch_path(&receipt.root, &receipt.batch)?;
    if let Some(bytes) = document_cache::read_optional_bounded(&path, MAX_BATCH_BYTES)? {
        if hash(&bytes) != receipt.digest {
            return Err("The quit decision changed externally; its bytes were kept".into());
        }
        fs::remove_file(&path).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        fs::File::open(&receipt.root)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())?;
    }
    lock(&PENDING)
        .map_err(|e| e.to_string())?
        .remove(&receipt.batch);
    Ok(())
}

/// Called after the shared transaction has validated/restored its internal state,
/// before any reader is published to Qt. Retirement uses the existing atomic discard.
pub(super) fn consume(document: &DesktopDocument) -> Result<(), String> {
    let _writer = lock(&WRITER).map_err(|e| e.to_string())?;
    let (root, name) = {
        let marks = lock(&document.marks).map_err(|e| e.to_string())?;
        let cache = marks.cache_location()?;
        (cache.root.clone(), marker_name(&cache.document))
    };
    let path = root.join(&name);
    let Some(bytes) = document_cache::read_optional_bounded(&path, MAX_RECEIPT_BYTES)? else {
        return Ok(());
    };
    let marker: Marker = serde_json::from_slice(&bytes).map_err(|e| {
        format!("The quit receipt could not be read; recovery files were kept: {e}")
    })?;
    if marker.version != VERSION {
        return Ok(());
    }
    let Some(commit) =
        document_cache::read_optional_bounded(&batch_path(&root, &marker.batch)?, MAX_BATCH_BYTES)?
    else {
        return Ok(());
    };
    let batch: Batch = serde_json::from_slice(&commit).map_err(|e| {
        format!("The quit decision could not be read; recovery files were kept: {e}")
    })?;
    if batch.version != VERSION
        || batch.members.is_empty()
        || batch.members.len() > MAX_DOCUMENTS
        || batch.members.keys().any(|name| !valid_marker_name(name))
        || batch.members.get(&name) != Some(&hash(&bytes))
    {
        return Ok(());
    }
    if lock(&PENDING)
        .map_err(|e| e.to_string())?
        .contains_key(&marker.batch)
    {
        return Ok(());
    }
    let (matches, same_source) = {
        let edits = lock(&document.edits).map_err(|e| e.to_string())?;
        let marks = lock(&document.marks).map_err(|e| e.to_string())?;
        let actual = fingerprint(&marks, &edits)?;
        let expected = &marker.fingerprint;
        let same_source = actual.document == expected.document
            && actual.cache == expected.cache
            && actual.source == expected.source;
        // A resolved cleanup retires its session before changing the original
        // records. A crash at that boundary must not revive the old root draft.
        // No other changed session or cache component is accepted as this state.
        let retired = same_source
            && actual.session.is_none()
            && expected.session.is_some()
            && actual.original == expected.original
            && !actual.cache.join("session.json").exists();
        (actual == *expected || retired, same_source)
    };
    if !matches && !same_source {
        return Ok(());
    }
    if matches {
        #[cfg(test)]
        CLEANING.store(true, std::sync::atomic::Ordering::Release);
        document.page_command("quit_discard", &serde_json::json!({}))?;
    }
    // New work with the same source remains recoverable. Only the previously
    // retired, fingerprinted directory is eligible for file-lease-aware cleanup.
    if let Err(error) = cleanup_retired_session(&marker) {
        eprintln!("lyra-reader-quit: recovery bytes were kept after retirement: {error}");
    }
    // Remove the final batch commit before its last receipt. A crash may leave
    // one inert per-document receipt, never an unreachable growing batch journal.
    collect_consumed_batch(&root, &marker.batch, &commit, &batch, &name)?;
    // The successful discard already retired known work and preserved opaque slots.
    // A failure to remove the now-stale receipt cannot undo that completed operation.
    if document_cache::read_optional_bounded(&path, MAX_RECEIPT_BYTES)?.as_ref() == Some(&bytes)
        && let Err(error) = fs::remove_file(&path)
    {
        eprintln!("lyra-reader-quit: resolved draft retired; receipt cleanup failed: {error}");
    }
    #[cfg(test)]
    test_checkpoint("receipt");
    Ok(())
}

fn collect_consumed_batch(
    root: &Path,
    id: &str,
    bytes: &[u8],
    batch: &Batch,
    resolved: &str,
) -> Result<(), String> {
    for (name, digest) in &batch.members {
        if name == resolved {
            continue;
        }

        // The caller validated every member name before constructing any path.
        if document_cache::read_optional_bounded(&root.join(name), MAX_RECEIPT_BYTES)?
            .as_deref()
            .is_some_and(|current| hash(current) == *digest)
        {
            return Ok(());
        }
    }
    let path = batch_path(root, id)?;
    if document_cache::read_optional_bounded(&path, MAX_BATCH_BYTES)?.as_deref() == Some(bytes) {
        fs::remove_file(&path).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        fs::File::open(root)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn owned_session_directory(cache: &Path, directory: &Path) -> Result<PathBuf, String> {
    let name = directory
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or("Invalid quit session directory name")?;
    if !name
        .strip_prefix("session-")
        .is_some_and(|id| lyra_reader_edit::records::normalize_uuid(id).is_some())
    {
        return Err("The quit session directory is not owned by this document".into());
    }
    let cache = cache.canonicalize().map_err(|e| e.to_string())?;
    let parent = directory
        .parent()
        .ok_or("Missing quit session parent")?
        .canonicalize()
        .map_err(|e| e.to_string())?;
    if parent != cache {
        return Err(
            "The quit session directory escapes its document cache; files were kept".into(),
        );
    }
    let expected = cache.join(name);
    match directory.canonicalize() {
        Ok(actual) if actual == expected => Ok(actual),
        Ok(_) => Err("The quit session directory is a redirected path; files were kept".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(expected),
        Err(e) => Err(e.to_string()),
    }
}
fn cleanup_retired_session(marker: &Marker) -> Result<(), String> {
    let Some(session) = &marker.fingerprint.session else {
        return Ok(());
    };
    let public = marker.fingerprint.cache.join("session.json");
    let _owner = crate::session::SessionOwner::acquire(&public)?;
    if crate::session::read_recovery(&public)?.is_some() {
        return Ok(());
    }
    let directory = owned_session_directory(&marker.fingerprint.cache, &session.directory)?;
    let Some(retired) = crate::session::read_recovery(&directory.join("retired-session.json"))?
    else {
        return Ok(());
    };
    if Some(hash(&retired)) != marker.manifest_digest {
        return Err("The retired session changed after the quit; its files were kept".into());
    }
    crate::session::SessionDirectory::retire_detached(&directory)
}
#[cfg(test)]
static CLEANING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[cfg(test)]
pub(super) fn test_checkpoint(stage: &str) {
    if CLEANING.load(std::sync::atomic::Ordering::Acquire)
        && std::env::var("LYRA_READER_TEST_QUIT_CHECKPOINT").as_deref() == Ok(stage)
    {
        std::process::exit(9);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    struct Fixture {
        directory: PathBuf,
        root: PathBuf,
        paths: Vec<PathBuf>,
    }
    impl Fixture {
        fn new(count: usize) -> Self {
            let directory = std::env::temp_dir().join(format!(
                "lyra-reader-quit-check-{}",
                crate::marks::uuid().unwrap()
            ));
            fs::create_dir(&directory).unwrap();
            let root = directory.join("cache");
            let paths = (0..count)
                .map(|i| {
                    let path = directory.join(format!("synthetic-{i}.pdf"));
                    fs::copy(
                        Path::new(env!("CARGO_MANIFEST_DIR"))
                            .join("../../tests/fixtures/multipage.pdf"),
                        &path,
                    )
                    .unwrap();
                    path
                })
                .collect();
            Self {
                directory,
                root,
                paths,
            }
        }
        fn open(&self, index: usize) -> DesktopDocument {
            DesktopDocument::open_with_cache_root(&self.paths[index], None, Some(&self.root))
                .unwrap()
        }
        fn cache(&self, index: usize) -> document_cache::DocumentCache {
            document_cache::DocumentCache::open(&self.paths[index], &self.root).unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            // This uniquely named directory contains only this test's synthetic files.
            let _ = fs::remove_dir_all(&self.directory);
        }
    }
    fn accepted(documents: &[&DesktopDocument], resolution: u32) -> Result<Receipt, String> {
        let receipt = super::resolve(documents, resolution)?;
        super::activate(&serde_json::to_vec(&receipt).map_err(|e| e.to_string())?)?;
        Ok(receipt)
    }
    fn bookmark(document: &DesktopDocument) {
        document
            .command(
                json!({"op":"bookmark_create","page":0,"title":"Synthetic quit draft","yPt":20}),
            )
            .unwrap();
    }
    fn dirty(document: &DesktopDocument) -> bool {
        let state = document.command(json!({"op":"marks"})).unwrap();
        state["pdf_dirty"] == true || state["page_pending"] == true
    }

    #[test]
    fn discard_batch_keeps_bytes_until_open_and_retires_root_and_revision_together() {
        let fixture = Fixture::new(2);
        let originals: Vec<_> = fixture
            .paths
            .iter()
            .map(|path| fs::read(path).unwrap())
            .collect();
        let first = fixture.open(0);
        let second = fixture.open(1);
        bookmark(&first);
        bookmark(&second);
        first
            .command(
                json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}}),
            )
            .unwrap();
        let manifest = fixture.cache(0).directory.join("session.json");
        let before_manifest = fs::read(&manifest).unwrap();
        let first_pair = draft_store::read(&fixture.cache(0).annotations()).unwrap();
        let second_pair = draft_store::read(&fixture.cache(1).annotations()).unwrap();
        let receipt = accepted(&[&first, &second], 1).unwrap();
        assert!(batch_path(&fixture.root, &receipt.batch).unwrap().is_file());
        assert_eq!(fs::read(&manifest).unwrap(), before_manifest);
        assert_eq!(
            draft_store::read(&fixture.cache(0).annotations()).unwrap(),
            first_pair
        );
        assert_eq!(
            draft_store::read(&fixture.cache(1).annotations()).unwrap(),
            second_pair
        );
        assert!(dirty(&first) && dirty(&second));
        drop(first);
        drop(second);
        let first = fixture.open(0);
        let second = fixture.open(1);
        assert!(!dirty(&first) && !dirty(&second));
        assert!(!manifest.exists());
        assert_eq!(
            first.command(json!({"op":"marks"})).unwrap()["bookmarks"],
            json!([])
        );
        for (path, bytes) in fixture.paths.iter().zip(&originals) {
            assert_eq!(fs::read(path).unwrap(), *bytes);
        }
    }

    #[test]
    fn receipt_failure_cannot_activate_an_earlier_prepared_marker() {
        let fixture = Fixture::new(2);
        let first = fixture.open(0);
        let second = fixture.open(1);
        bookmark(&first);
        bookmark(&second);
        let names: BTreeMap<_, _> = fixture
            .paths
            .iter()
            .map(|path| (marker_name(&path.canonicalize().unwrap()), path))
            .collect();
        let blocked = fixture.root.join(names.last_key_value().unwrap().0);
        fs::create_dir(&blocked).unwrap();
        assert!(accepted(&[&first, &second], 1).is_err());
        assert!(
            fixture
                .root
                .join(names.first_key_value().unwrap().0)
                .is_file()
        );
        fs::remove_dir(blocked).unwrap();
        drop(first);
        drop(second);
        assert!(dirty(&fixture.open(0)) && dirty(&fixture.open(1)));
    }

    #[test]
    fn cancel_committed_batch_keeps_all_drafts_recoverable() {
        let fixture = Fixture::new(2);
        let first = fixture.open(0);
        let second = fixture.open(1);
        bookmark(&first);
        bookmark(&second);
        let receipt = accepted(&[&first, &second], 1).unwrap();
        cancel(&first, &serde_json::to_vec(&receipt).unwrap()).unwrap();
        assert!(!batch_path(&fixture.root, &receipt.batch).unwrap().exists());
        drop(first);
        drop(second);
        assert!(dirty(&fixture.open(0)) && dirty(&fixture.open(1)));
    }

    #[test]
    fn later_annotation_work_invalidates_the_resolved_decision() {
        let fixture = Fixture::new(1);
        let document = fixture.open(0);
        bookmark(&document);
        accepted(&[&document], 1).unwrap();
        bookmark(&document);
        drop(document);
        let reopened = fixture.open(0);
        assert!(dirty(&reopened));
        assert_eq!(
            reopened.command(json!({"op":"marks"})).unwrap()["bookmarks"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }

    #[test]
    fn later_page_work_cannot_be_mistaken_for_an_interrupted_retirement() {
        let fixture = Fixture::new(1);
        let document = fixture.open(0);
        let rotate =
            json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}});
        document.command(rotate.clone()).unwrap();
        accepted(&[&document], 1).unwrap();
        document.command(rotate).unwrap();
        let latest = document.active().unwrap().path();
        drop(document);
        let reopened = fixture.open(0);
        assert!(dirty(&reopened));
        assert_eq!(reopened.active().unwrap().path(), latest);
        assert!(reopened.command(json!({"op":"marks"})).unwrap()["error"].is_null());
    }

    #[test]
    fn changed_recovery_manifest_blocks_quit_without_modifying_the_draft() {
        let fixture = Fixture::new(1);
        let document = fixture.open(0);
        bookmark(&document);
        document
            .command(
                json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}}),
            )
            .unwrap();
        let path = fixture.cache(0).directory.join("session.json");
        let mut bytes = fs::read(&path).unwrap();
        bytes.push(b' ');
        fs::write(&path, &bytes).unwrap();
        assert!(accepted(&[&document], 1).is_err());
        assert_eq!(fs::read(path).unwrap(), bytes);
        assert!(dirty(&document));
    }

    #[test]
    fn position_only_termination_flush_does_not_invalidate_the_resolved_work() {
        let fixture = Fixture::new(1);
        let document = fixture.open(0);
        bookmark(&document);
        document
            .command(
                json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}}),
            )
            .unwrap();
        accepted(&[&document], 1).unwrap();
        {
            let edits = lock(&document.edits).unwrap();
            let marks = lock(&document.marks).unwrap();
            let before = fingerprint(&marks, &edits).unwrap();
            let control = edits.control().unwrap();
            let state = control.handle.snapshot().unwrap();
            // Preserve the exact shared work snapshot: repopulating PDF-derived
            // bookmarks from the canvas would be an additional metadata edit.
            let input = lyra_reader_ffi::DocumentTransactionInputRecord {
                annotations_json: state.annotations_json.clone(),
                bookmarks_json: state.bookmarks_json.clone(),
                slots_json: state.slots_json.clone(),
                deletions_json: state.deletions_json.clone(),
                erased_ink_json: state.erased_ink_json.clone(),
                annotation_dirty: state.annotation_dirty,
                current_page: 3,
                selection: vec![1],
            };
            control
                .mutate(|handle| {
                    handle.persist(
                        input,
                        state.revision_url,
                        state.revision_number,
                        control.recovery_path.to_string_lossy().into_owned(),
                    )
                })
                .unwrap();
            assert_eq!(fingerprint(&marks, &edits).unwrap(), before);
        }
        drop(document);
        assert!(!dirty(&fixture.open(0)));
    }

    #[test]
    fn immutable_revision_lease_outlives_editor_without_blocking_resolved_cleanup() {
        let fixture = Fixture::new(1);
        let document = fixture.open(0);
        bookmark(&document);
        document
            .command(
                json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}}),
            )
            .unwrap();
        let frozen = crate::render_source::RenderSource::new(&document, false).unwrap();
        let before = frozen.query(json!({"op":"info"})).unwrap();
        let directory = lock(&document.edits)
            .unwrap()
            .directory
            .as_ref()
            .unwrap()
            .path
            .clone();
        accepted(&[&document], 1).unwrap();
        drop(document);
        let reopened = fixture.open(0);
        assert!(!dirty(&reopened));
        assert_eq!(frozen.query(json!({"op":"info"})).unwrap(), before);
        assert!(directory.is_dir());
        drop(frozen);
        assert!(!directory.exists());
    }

    #[test]
    fn restored_editor_garbage_collection_protects_an_older_frozen_revision() {
        let fixture = Fixture::new(1);
        let document = fixture.open(0);
        let rotate =
            json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}});
        document.command(rotate.clone()).unwrap();
        let old_path = PathBuf::from(document.active().unwrap().path());
        let frozen = crate::render_source::RenderSource::new(&document, false).unwrap();
        drop(document);
        let reopened = fixture.open(0);
        reopened.command(rotate.clone()).unwrap();
        reopened.command(rotate).unwrap();
        {
            let edits = lock(&reopened.edits).unwrap();
            edits
                .control()
                .unwrap()
                .mutate(|handle| handle.limit_history(1, 1))
                .unwrap();
            edits.directory.as_ref().unwrap().collect_garbage().unwrap();
        }
        assert!(old_path.is_file());
        reopened.command(json!({"op":"document_discard"})).unwrap();
        assert!(old_path.is_file());
        assert!(
            !frozen
                .query(json!({"op":"text","page":0}))
                .unwrap()
                .is_null()
        );
        drop(frozen);
        assert!(!old_path.exists());
    }

    #[test]
    fn failed_cleanup_keeps_receipt_and_original_readable_then_retries() {
        let fixture = Fixture::new(1);
        let document = fixture.open(0);
        bookmark(&document);
        accepted(&[&document], 1).unwrap();
        drop(document);
        let cache = fixture.cache(0);
        let pending = cache.directory.join("changes.json");
        let backup = cache.directory.join("test-before-image.json");
        let records = fs::read(cache.annotations()).unwrap();
        fs::rename(&pending, &backup).unwrap();
        fs::create_dir(&pending).unwrap();
        let reopened = fixture.open(0);
        assert!(
            reopened.info().unwrap()["recovery"]["resolved_quit_cleanup_pending"]
                .as_bool()
                .unwrap()
        );
        assert_eq!(
            reopened.command(json!({"op":"marks"})).unwrap()["bookmarks"],
            json!([])
        );
        assert_eq!(fs::read(cache.annotations()).unwrap(), records);
        assert!(
            fixture
                .root
                .join(marker_name(&fixture.paths[0].canonicalize().unwrap()))
                .is_file()
        );
        drop(reopened);
        fs::remove_dir(&pending).unwrap();
        fs::rename(backup, pending).unwrap();
        let reopened = fixture.open(0);
        assert!(!dirty(&reopened));
        assert!(reopened.command(json!({"op":"marks"})).unwrap()["error"].is_null());
    }

    #[test]
    fn resolved_cleanup_preserves_opaque_record_bytes() {
        let fixture = Fixture::new(1);
        let path = fixture.cache(0).annotations();
        let foreign = r#"{ "kind":"future", "id":"9CD73B7D-7A3A-4FB0-814A-AF0211B7DDEF", "page":0, "raw":1.0000000000000001 }"#;
        fs::write(&path, format!("[{foreign}]\n")).unwrap();
        let document = fixture.open(0);
        bookmark(&document);
        accepted(&[&document], 1).unwrap();
        drop(document);
        let reopened = fixture.open(0);
        assert!(!dirty(&reopened));
        assert!(
            String::from_utf8(fs::read(path).unwrap())
                .unwrap()
                .contains(foreign)
        );
        assert_eq!(
            reopened.command(json!({"op":"marks"})).unwrap()["preserved"],
            1
        );
    }

    #[test]
    fn corrupt_committed_receipt_keeps_recovery_and_shows_original_read_only() {
        let fixture = Fixture::new(1);
        let document = fixture.open(0);
        bookmark(&document);
        let receipt = accepted(&[&document], 1).unwrap();
        drop(document);
        fs::write(
            batch_path(&fixture.root, &receipt.batch).unwrap(),
            b"{broken",
        )
        .unwrap();
        let reopened = fixture.open(0);
        let state = reopened.command(json!({"op":"marks"})).unwrap();
        assert!(state["error"].as_str().unwrap().contains("resolved quit"));
        assert_eq!(state["bookmarks"], json!([]));
        assert!(
            reopened
                .command(
                    json!({"op":"bookmark_create","page":0,"title":"must not overwrite","yPt":20})
                )
                .is_err()
        );
        assert!(
            !draft_store::read(&fixture.cache(0).annotations())
                .unwrap()
                .records
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn invalid_and_oversized_batches_and_receipt_paths_are_rejected() {
        assert!(!valid_batch_id("../../outside"));
        assert!(!valid_batch_id("00000000-0000-0000-0000-00000000000/"));
        let fixture = Fixture::new(1);
        let document = fixture.open(0);
        assert!(accepted(&[], 1).is_err());
        assert!(accepted(&[&document], 9).is_err());
        assert!(accepted(&vec![&document; MAX_DOCUMENTS + 1], 1).is_err());
        assert!(cancel(&document, &vec![b' '; MAX_RECEIPT_BYTES as usize + 1]).is_err());
    }

    #[test]
    fn repeated_handles_among_equal_path_readers_are_locked_only_once() {
        let fixture = Fixture::new(1);
        let first = fixture.open(0);
        bookmark(&first);
        let second = fixture.open(0);
        let receipt = accepted(&[&first, &second, &first], 1).unwrap();
        cancel(&first, &serde_json::to_vec(&receipt).unwrap()).unwrap();
        assert!(dirty(&first) && dirty(&second));
    }

    #[test]
    fn pending_ui_acknowledgement_cannot_retire_another_reader_open() {
        let fixture = Fixture::new(1);
        let document = fixture.open(0);
        bookmark(&document);
        let receipt = super::resolve(&[&document], 1).unwrap();
        let before_ack = fixture.open(0);
        assert!(dirty(&before_ack));
        drop(before_ack);
        super::activate(&serde_json::to_vec(&receipt).unwrap()).unwrap();
        drop(document);
        assert!(!dirty(&fixture.open(0)));
    }

    #[test]
    fn interrupted_cleanup_retires_work_at_each_real_process_boundary() {
        for stage in ["retired", "pending", "records", "receipt"] {
            let fixture = Fixture::new(1);
            let original = fs::read(&fixture.paths[0]).unwrap();
            let document = fixture.open(0);
            bookmark(&document);
            document.command(json!({"op":"page_stage","operation":{"Rotate":{"pages":[0],"quarter_turns":1}}})).unwrap();
            accepted(&[&document], 1).unwrap();
            drop(document);
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "quit::tests::cleanup_crash_child",
                    "--ignored",
                    "--nocapture",
                ])
                .env("LYRA_READER_TEST_QUIT_CHECKPOINT", stage)
                .env("LYRA_READER_TEST_QUIT_PATH", &fixture.paths[0])
                .env("LYRA_READER_TEST_QUIT_CACHE", &fixture.root)
                .output()
                .unwrap();
            assert_eq!(
                status.status.code(),
                Some(9),
                "{stage}: {}",
                String::from_utf8_lossy(&status.stderr)
            );
            let reopened = fixture.open(0);
            let state = reopened.command(json!({"op":"marks"})).unwrap();
            assert!(!dirty(&reopened), "{stage}: {state}");
            assert!(state["error"].is_null(), "{stage}: {state}");
            assert_eq!(state["bookmarks"], json!([]), "{stage}");
            assert_eq!(fs::read(&fixture.paths[0]).unwrap(), original, "{stage}");
            assert!(
                !fixture.cache(0).directory.join("session.json").exists(),
                "{stage}"
            );
        }
    }

    #[test]
    #[ignore = "subprocess fixture; the parent test executes each crash boundary"]
    fn cleanup_crash_child() {
        let path = PathBuf::from(
            std::env::var_os("LYRA_READER_TEST_QUIT_PATH").expect("parent-owned synthetic PDF"),
        );
        let cache = PathBuf::from(
            std::env::var_os("LYRA_READER_TEST_QUIT_CACHE").expect("parent-owned synthetic cache"),
        );
        assert!(
            path.parent()
                .unwrap()
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("lyra-reader-quit-check-")
        );
        assert_eq!(cache, path.parent().unwrap().join("cache"));
        let _document = DesktopDocument::open_with_cache_root(&path, None, Some(&cache)).unwrap();
        panic!("The requested cleanup checkpoint was not reached");
    }
}

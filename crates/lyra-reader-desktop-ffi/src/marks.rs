//! Native-shell persistence adapter for the shared annotation codec and rules.
use lyra_reader_edit::draft::{CleanSnapshot, Deletion, PendingState};
use lyra_reader_edit::{kind::AnnotationKind, records, rules};
use lyra_reader_ffi::api::*;
use lyra_reader_ffi::{DocumentTransactionInputRecord, DocumentTransactionStateRecord};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
#[path = "ink_erase.rs"]
mod ink_erase;
const MAX_SIDECAR_BYTES: usize = 16 * 1024 * 1024;
const MAX_HISTORY_BYTES: usize = 32 * 1024 * 1024;
static WRITES: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[derive(Clone)]
enum Entry {
    Known(Value),
    Opaque(String),
}
#[derive(Clone)]
struct Snapshot {
    transient_ink: HashSet<String>,
    hidden_ink: HashSet<String>,
    embedded_bookmarks: HashSet<String>,
    bytes: usize,
    entries: Vec<Entry>,
    deletions: Vec<AnnotationDeleteRecord>,
    dirty: bool,
}
#[derive(Clone)]
pub struct Marks {
    // PDF-owned cut pieces stay staged with their deletion. Persisting them alone
    // would duplicate the original after a crash or an explicit discard-and-close.
    transient_ink: HashSet<String>,
    hidden_ink: HashSet<String>,
    erase: Option<ink_erase::Gesture>,
    embedded_bookmarks: HashSet<String>,
    path: PathBuf,
    cache: Option<crate::document_cache::DocumentCache>,
    source_error: Option<String>,
    session: Option<crate::session::SessionContext>,
    owns_recovery: bool,
    baseline: Option<Vec<u8>>,
    pending_baseline: Option<Vec<u8>>,
    pending: PendingState,
    entries: Vec<Entry>,
    deletions: Vec<AnnotationDeleteRecord>,
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,
    pub error: Option<String>,
    page_count: u32,
}
pub struct Payload {
    pub annotations: Vec<WriteAnnotationRecord>,
    pub bookmarks: Vec<WriteBookmarkRecord>,
    pub updates: Vec<AnnotationUpdateRecord>,
    pub deletions: Vec<AnnotationDeleteRecord>,
    pub ids: HashSet<String>,
    pub has_bookmark_subtree: bool,
}
impl Payload {
    pub fn is_empty(&self) -> bool {
        self.annotations.is_empty()
            && self.bookmarks.is_empty()
            && self.updates.is_empty()
            && self.deletions.is_empty()
            && !self.has_bookmark_subtree
    }
}

fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
        - 978_307_200.0
}
pub(super) fn uuid() -> Result<String, String> {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).map_err(|e| e.to_string())?;
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    Ok(format!(
        "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        b[0],
        b[1],
        b[2],
        b[3],
        b[4],
        b[5],
        b[6],
        b[7],
        b[8],
        b[9],
        b[10],
        b[11],
        b[12],
        b[13],
        b[14],
        b[15]
    ))
}
fn valid_uuid(s: &str) -> bool {
    records::normalize_uuid(s).is_some()
}
fn number(v: &Value, k: &str) -> Result<f64, String> {
    v[k].as_f64()
        .filter(|x| x.is_finite())
        .ok_or_else(|| format!("Invalid {k}"))
}
fn string(v: &Value, k: &str) -> Result<String, String> {
    v[k].as_str()
        .map(str::to_string)
        .ok_or_else(|| format!("Missing {k}"))
}
fn color(v: &Value) -> Option<String> {
    if let Some(text) = v["color"].as_str() {
        return records::PaletteColor::from_hex(text).map(|c| c.hex());
    }
    v["colorIndex"].as_u64().and_then(|index| {
        usize::try_from(index).ok().and_then(|index| {
            records::legacy_highlight_palette()
                .get(index)
                .map(|c| c.hex())
        })
    })
}
fn kind(v: &Value) -> &str {
    v["kind"].as_str().unwrap_or("highlight")
}
fn decode_records(bytes: &[u8], pages: u32) -> Result<records::Contents, String> {
    records::decode(bytes, pages as usize, &records::legacy_highlight_palette())
        .map_err(|e| format!("Invalid annotation records: {e}"))
}

fn decode_entries(bytes: &[u8], pages: u32) -> Result<Vec<Entry>, String> {
    let contents = decode_records(bytes, pages)?;
    // Normalize known entries through the production codec. Opaque slots retain their
    // original source bytes, including numeric spellings and escaped characters.
    let normalized = records::encode(
        &contents.annotations,
        &contents.bookmarks,
        &contents.slots,
        &records::legacy_highlight_palette(),
    )
    .map_err(|e| e.to_string())?;
    let values: Vec<Value> = serde_json::from_slice(&normalized).map_err(|e| e.to_string())?;
    if values.len() != contents.slots.len() {
        return Err("The annotation codec returned an inconsistent entry order".into());
    }
    Ok(values
        .into_iter()
        .zip(contents.slots)
        .map(|(value, slot)| match slot {
            records::Slot::Opaque(raw) => Entry::Opaque(raw),
            _ => Entry::Known(value),
        })
        .collect())
}

fn encode_entries(
    entries: &[Entry],
    pages: u32,
    transient: &HashSet<String>,
) -> Result<Vec<u8>, String> {
    let elements = entries
        .iter()
        .filter(|e| {
            !matches!(e, Entry::Known(v)
        if v["id"].as_str().is_some_and(|id| transient.contains(id)))
        })
        .map(|e| match e {
            Entry::Known(value) => serde_json::to_string(value).map_err(|e| e.to_string()),
            Entry::Opaque(raw) => Ok(raw.clone()),
        })
        .collect::<Result<Vec<_>, _>>()?;
    let input = format!("[{}]", elements.join(","));
    let contents = decode_records(input.as_bytes(), pages)?;
    records::encode(
        &contents.annotations,
        &contents.bookmarks,
        &contents.slots,
        &records::legacy_highlight_palette(),
    )
    .map_err(|e| e.to_string())
}

fn validate(v: &Value, pages: u32) -> Result<bool, String> {
    let bytes = serde_json::to_vec(&vec![v]).map_err(|e| e.to_string())?;
    let contents = decode_records(&bytes, pages)?;
    if contents.preserved_count() != 0 {
        return Ok(false);
    }
    for annotation in &contents.annotations {
        rules::validate_annotation(annotation, pages as usize, &[]).map_err(|e| e.to_string())?;
        if annotation.kind == AnnotationKind::Signature {
            crate::artwork::dimensions(&string(v, "image")?)?;
        }
    }
    for bookmark in &contents.bookmarks {
        rules::validate_bookmark(bookmark, pages as usize, &[]).map_err(|e| e.to_string())?;
    }
    Ok(true)
}

impl Marks {
    fn clean_snapshot(&self) -> CleanSnapshot {
        let mut annotations = Vec::new();
        let mut bookmarks = Vec::new();
        for entry in &self.entries {
            if let Entry::Known(value) = entry {
                if kind(value) == "bookmark" {
                    bookmarks.push(value.clone());
                } else {
                    annotations.push(value.clone());
                }
            }
        }
        CleanSnapshot::new(annotations, bookmarks)
    }
    fn refresh_pending(&mut self) {
        self.pending.deletions = self
            .deletions
            .iter()
            .map(|d| Deletion {
                identity: d.target.clone(),
                page: d.page,
            })
            .collect();
        self.pending.erased_ink = self.hidden_ink.iter().cloned().collect();
        self.pending.erased_ink.sort();
        self.pending.refresh(&self.clean_snapshot());
    }
    fn cache_pair(&self) -> crate::draft_store::Pair {
        crate::draft_store::Pair {
            records: self.baseline.clone(),
            pending: self.pending_baseline.clone(),
        }
    }
    pub fn discard_known(&self, document: &LyraReaderDocument) -> Result<Self, String> {
        if self.session.is_some() {
            return Err("Discard the page transaction through its original cache".into());
        }
        let mut next = self.clone();
        next.entries
            .retain(|entry| matches!(entry, Entry::Opaque(_)));
        next.deletions.clear();
        next.hidden_ink.clear();
        next.transient_ink.clear();
        next.embedded_bookmarks.clear();
        next.erase = None;
        next.pending.mark_clean(next.clean_snapshot());
        next.persist()?;
        next.undo.clear();
        next.redo.clear();
        next.seed_bookmarks(document)?;
        Ok(next)
    }
    pub fn rollback_discard(&self, before: &Self) -> Result<(), String> {
        let _guard = WRITES
            .lock()
            .map_err(|_| "Annotation cache writer is unavailable")?;
        crate::draft_store::rollback(&self.path, &before.cache_pair(), &self.cache_pair()).map_err(
            |error| match crate::draft_store::backup(&self.path, &before.cache_pair()) {
                Ok(path) => format!(
                    "{error}. The previous draft is backed up at {}",
                    path.display()
                ),
                Err(backup) => format!("{error}. {backup}"),
            },
        )
    }
    pub fn validate_source(&self) -> Result<(), String> {
        let cache = self
            .cache
            .as_ref()
            .ok_or("The document cache is unavailable")?;
        if self.owns_recovery {
            cache.validate_pdf_source()
        } else {
            cache.validate_source()
        }
    }
    pub fn cache_root(&self) -> Option<&Path> {
        self.cache.as_ref().map(|c| c.root.as_path())
    }
    pub fn after_save(&mut self) -> Result<(), String> {
        let cache = self
            .cache
            .as_ref()
            .ok_or("The document cache is unavailable")?
            .after_save()?;
        self.path = cache.annotations();
        self.baseline = if self.path.exists() {
            Some(fs::read(&self.path).map_err(|e| e.to_string())?)
        } else {
            None
        };
        self.source_error = None;
        self.cache = Some(cache);
        Ok(())
    }
    pub fn can_stage(&self, _operation: &PageOperationRecord) -> Result<(), String> {
        self.validate_source()?;
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        if self.entries.iter().any(|e| matches!(e, Entry::Opaque(_))) {
            return Err("The annotation cache contains entries from another version whose pages cannot be remapped safely. Page editing is disabled.".into());
        }
        Ok(())
    }
    pub fn cache_location(&self) -> Result<&crate::document_cache::DocumentCache, String> {
        self.cache
            .as_ref()
            .ok_or_else(|| "The document cache is unavailable".into())
    }
    pub fn owns_session(&mut self) {
        self.owns_recovery = true;
        self.source_error = None;
    }
    pub fn recovery_notice(&mut self, error: String) {
        self.source_error = Some(error);
    }
    pub fn needs_materialization(&self, operation: &PageOperationRecord) -> bool {
        let pages = match operation {
            PageOperationRecord::Rotate { pages, .. }
            | PageOperationRecord::SetRotation { pages, .. } => pages,
            _ => return false,
        };
        self.entries.iter().any(|e| matches!(e, Entry::Known(v)
            if v["page"].as_u64().and_then(|p|u32::try_from(p).ok()).is_some_and(|p|pages.contains(&p))
            && !v["id"].as_str().is_some_and(|id|self.embedded_bookmarks.contains(id))))
    }
    pub fn transaction_input(
        &self,
        page: u32,
        selection: &[u32],
    ) -> Result<DocumentTransactionInputRecord, String> {
        let mut annotations = Vec::new();
        let mut bookmarks = Vec::new();
        let mut slots = Vec::new();
        for entry in &self.entries {
            match entry {
                Entry::Known(value) => {
                    let id = string(value, "id")?;
                    if kind(value) == "bookmark" {
                        bookmarks.push(value.clone());
                        slots.push(json!({"bookmark":{"_0":id}}));
                    } else {
                        annotations.push(value.clone());
                        slots.push(json!({"annotation":{"_0":id}}));
                    }
                }
                Entry::Opaque(raw) => slots.push(json!({"opaque":{"_0":raw}})),
            }
        }
        let deletions: Vec<_> = self
            .deletions
            .iter()
            .map(|d| json!({"identity":d.target,"page":d.page}))
            .collect();
        let mut hidden: Vec<_> = self.hidden_ink.iter().cloned().collect();
        hidden.sort();
        Ok(DocumentTransactionInputRecord {
            annotations_json: serde_json::to_string(&annotations).map_err(|e| e.to_string())?,
            bookmarks_json: serde_json::to_string(&bookmarks).map_err(|e| e.to_string())?,
            slots_json: serde_json::to_string(&slots).map_err(|e| e.to_string())?,
            deletions_json: serde_json::to_string(&deletions).map_err(|e| e.to_string())?,
            erased_ink_json: serde_json::to_string(&hidden).map_err(|e| e.to_string())?,
            annotation_dirty: self.pending.dirty || !deletions.is_empty() || !hidden.is_empty(),
            current_page: page,
            selection: selection.to_vec(),
        })
    }
    pub fn restored_transaction(
        &self,
        state: &DocumentTransactionStateRecord,
        control: std::sync::Arc<crate::session::SessionControl>,
        document: &LyraReaderDocument,
        original: &Marks,
    ) -> Result<Self, String> {
        let annotations: Vec<Value> =
            serde_json::from_str(&state.annotations_json).map_err(|e| e.to_string())?;
        let bookmarks: Vec<Value> =
            serde_json::from_str(&state.bookmarks_json).map_err(|e| e.to_string())?;
        let slots: Vec<Value> =
            serde_json::from_str(&state.slots_json).map_err(|e| e.to_string())?;
        let mut pieces = Vec::new();
        let mut emitted = HashSet::new();
        for slot in slots {
            if let Some(raw) = slot["opaque"]["_0"].as_str() {
                pieces.push(raw.to_string());
                continue;
            }
            for (tag, values) in [("annotation", &annotations), ("bookmark", &bookmarks)] {
                if let Some(id) = slot[tag]["_0"].as_str() {
                    let value = values.iter().find(|v| v["id"].as_str().is_some_and(|s|s.eq_ignore_ascii_case(id)))
                        .ok_or("The cached editing snapshot refers to a missing annotation or bookmark")?;
                    if emitted.insert(format!("{tag}:{id}")) {
                        pieces.push(serde_json::to_string(value).map_err(|e| e.to_string())?);
                    }
                }
            }
        }
        for (tag, values) in [("annotation", annotations), ("bookmark", bookmarks)] {
            for value in values {
                let id = string(&value, "id")?;
                if emitted.insert(format!("{tag}:{id}")) {
                    pieces.push(serde_json::to_string(&value).map_err(|e| e.to_string())?);
                }
            }
        }
        let mut result = self.clone();
        result.entries = decode_entries(
            format!("[{}]", pieces.join(",")).as_bytes(),
            document.page_count(),
        )?;
        let deletions: Vec<Value> =
            serde_json::from_str(&state.deletions_json).map_err(|e| e.to_string())?;
        result.deletions = deletions
            .into_iter()
            .map(|v| {
                Ok(AnnotationDeleteRecord {
                    target: string(&v, "identity")?,
                    page: v["page"]
                        .as_u64()
                        .and_then(|p| u32::try_from(p).ok())
                        .ok_or("Invalid cached deletion page")?,
                })
            })
            .collect::<Result<_, String>>()?;
        result.hidden_ink = serde_json::from_str::<Vec<String>>(&state.erased_ink_json)
            .map_err(|e| e.to_string())?
            .into_iter()
            .collect();
        result.pending = original.pending.clone();
        result.pending.dirty = state.annotation_dirty;
        // The shared manifest now persists pieces and their deletions together. Private
        // session records can keep both; the original document cache is never rewritten.
        result.transient_ink.clear();
        result.embedded_bookmarks.clear();
        result.undo.clear();
        result.redo.clear();
        result.erase = None;
        result.path = lyra_reader_edit::transaction::file_url_path(&state.annotation_records_url)
            .ok_or("Invalid session annotation URL")?;
        result.baseline = None;
        result.error = None;
        result.source_error = state.recovery_error.clone();
        result.owns_recovery = true;
        result.session = Some(crate::session::SessionContext {
            control,
            revision_url: state.revision_url.clone(),
            revision_number: state.revision_number,
            current_page: state.current_page,
            selection: state.selection.clone(),
        });
        result.seed_bookmarks(document)?;
        Ok(result)
    }
    pub fn cleaned_for_save(&self, ids: &HashSet<String>) -> Self {
        let mut result = self.clone();
        result.entries.retain(
            |e| !matches!(e,Entry::Known(v)if v["id"].as_str().is_some_and(|id|ids.contains(id))),
        );
        result.deletions.clear();
        result.hidden_ink.clear();
        result.transient_ink.clear();
        result.undo.clear();
        result.redo.clear();
        result.pending.mark_clean(result.clean_snapshot());
        result
    }
    pub fn validate_export(&self, remapping: bool) -> Result<(), String> {
        self.validate_source()?;
        if let Some(error) = &self.error {
            return Err(format!(
                "The annotation annotation cache cannot be read: {error}"
            ));
        }
        if remapping && self.entries.iter().any(|e| matches!(e, Entry::Opaque(_))) {
            return Err(
                "The annotation cache contains unknown entries whose pages cannot be remapped safely".into(),
            );
        }
        if !self.deletions.is_empty() {
            return Err(
                "Write pending file annotation deletions to a PDF before merging or splitting"
                    .into(),
            );
        }
        Ok(())
    }
    pub fn appended_copy(
        &self,
        path: &Path,
        old: &LyraReaderDocument,
        new: &LyraReaderDocument,
    ) -> Result<Self, String> {
        let map: Vec<_> = (0..old.page_count()).map(Some).collect();
        self.copy_with_map(path, &map, old, new, true)
    }
    pub fn staging_copy(
        &self,
        path: &Path,
        map: &[Option<u32>],
        old: &LyraReaderDocument,
        new: &LyraReaderDocument,
    ) -> Result<Self, String> {
        self.copy_with_map(path, map, old, new, false)
    }
    fn copy_with_map(
        &self,
        path: &Path,
        map: &[Option<u32>],
        old: &LyraReaderDocument,
        new: &LyraReaderDocument,
        allow_opaque: bool,
    ) -> Result<Self, String> {
        let old_file = old.annotations().map_err(|e| e.to_string())?;
        let new_file = new.annotations().map_err(|e| e.to_string())?;
        let identity = |id: &str, page: u32, new_page: u32| -> Result<String, String> {
            if !id.starts_with("fp:") {
                return Ok(id.to_string());
            }
            let list: Vec<_> = old_file.iter().filter(|a| a.page == page).collect();
            let index = list
                .iter()
                .position(|a| a.id == id)
                .ok_or("An adopted annotation is missing from the source")?;
            let new_list: Vec<_> = new_file.iter().filter(|a| a.page == new_page).collect();
            let a = list[index];
            let b = new_list
                .get(index)
                .ok_or("An adopted annotation is missing from the edited page")?;
            if a.kind != b.kind || a.contents != b.contents {
                return Err(
                    "An adopted annotation could not be matched safely after the page edit".into(),
                );
            }
            Ok(b.id.clone())
        };
        let mut result = self.clone();
        result.erase = None;
        let root = self
            .cache
            .as_ref()
            .ok_or("The document cache is unavailable")?
            .root
            .clone();
        let cache = crate::document_cache::DocumentCache::open(path, &root)?;
        result.path = cache.annotations();
        result.source_error = cache.validate_source().err();
        result.cache = Some(cache);
        result.baseline = None;
        result.pending_baseline = None;
        result.session = None;
        result.owns_recovery = false;
        result.page_count = new.page_count();
        result.undo.clear();
        result.redo.clear();
        let mut entries = vec![];
        for entry in &self.entries {
            let Entry::Known(v) = entry else {
                if allow_opaque {
                    entries.push(entry.clone());
                    continue;
                }
                return Err("Unsupported annotation cache entry".into());
            };
            if v["id"]
                .as_str()
                .is_some_and(|id| self.embedded_bookmarks.contains(id))
            {
                continue; // Reload embedded destinations from the transformed outline below.
            }
            let mut v = v.clone();
            let page = v["page"].as_u64().unwrap() as u32;
            if let Some(Some(next)) = map.get(page as usize) {
                v["page"] = json!(next);
                if let Some(id) = v["fileIdentity"].as_str() {
                    v["fileIdentity"] = json!(identity(id, page, *next)?);
                }
                entries.push(Entry::Known(v));
            }
        }
        result.entries = entries;
        result.embedded_bookmarks.clear();
        result.seed_bookmarks(new)?;
        result.deletions = self
            .deletions
            .iter()
            .filter_map(|d| {
                map.get(d.page as usize)
                    .copied()
                    .flatten()
                    .map(|page| (d, page))
            })
            .map(|(d, page)| {
                Ok(AnnotationDeleteRecord {
                    target: identity(&d.target, d.page, page)?,
                    page,
                })
            })
            .collect::<Result<_, String>>()?;
        // These outputs were materialised through the verified PDF writer. Their
        // projected cache is clean and must never retain the source session handle.
        result.entries.retain(|e|!matches!(e,Entry::Known(v) if v["id"].as_str().is_some_and(|id|self.hidden_ink.contains(id))));
        result.hidden_ink.clear();
        result.transient_ink.clear();
        result.pending.mark_clean(result.clean_snapshot());
        result.persist()?;
        Ok(result)
    }
    pub fn publish_page_revision<T>(
        &self,
        original: &Self,
        publish: impl FnOnce() -> Result<T, String>,
    ) -> Result<(T, Self, Option<PathBuf>), String> {
        original.validate_source()?;
        if let Some(error) = &original.error {
            return Err(format!("Annotation cache writes are blocked: {error}"));
        }
        let mut prepared = self.clone();
        prepared.session = None;
        prepared.path = original
            .path
            .with_extension(format!("json.prepared-{}", uuid()?));
        prepared.baseline = None;
        prepared.persist()?;
        let _write_guard = WRITES
            .lock()
            .map_err(|_| "Annotation cache writer is unavailable")?;
        let pair = crate::draft_store::read(&original.path)?;
        let current = pair.records.clone();
        if pair != original.cache_pair() {
            let _ = fs::remove_file(&prepared.path);
            return Err("The original annotation cache changed during page editing. The original PDF was not replaced.".into());
        }
        let backup = if let Some(bytes) = current {
            let path = original
                .path
                .with_extension(format!("json.page-backup-{}", uuid()?));
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&path).map_err(|e| e.to_string())?;
            file.set_permissions(
                fs::metadata(&original.path)
                    .map_err(|e| e.to_string())?
                    .permissions(),
            )
            .map_err(|e| e.to_string())?;
            file.write_all(&bytes)
                .and_then(|_| file.sync_all())
                .map_err(|e| e.to_string())?;
            if fs::read(&path).map_err(|e| e.to_string())? != bytes {
                return Err("Annotation cache backup verification failed".into());
            }
            Some(path)
        } else {
            None
        };
        let report = match publish() {
            Ok(report) => report,
            Err(error) => {
                let _ = fs::remove_file(&prepared.path);
                return Err(error);
            }
        };
        let mut result = self.clone();
        result.cache = original.cache.clone();
        result.session = None;
        result.owns_recovery = false;
        result.path = original.path.clone();
        result.baseline = original.baseline.clone();
        result.pending_baseline = original.pending_baseline.clone();
        result.undo.clear();
        result.redo.clear();
        let published = crate::draft_store::write(
            &original.path,
            &pair,
            prepared
                .baseline
                .clone()
                .ok_or("Missing prepared annotation records")?,
            &result.pending,
        );
        if let Err(error) = &published {
            result.error = Some(format!(
                "The PDF was saved, but the remapped annotation cache could not be published: {error}. Recovery data: {}",
                prepared.path.display()
            ));
        } else if let Ok((pair, mut pending)) = published {
            result.baseline = pair.records;
            result.pending_baseline = pair.pending;
            pending.commit = None;
            result.pending = pending;
            // A private prepared mirror is redundant after the recoverable pair is published.
            let _ = fs::remove_file(&prepared.path);
            if let Err(error) = result.after_save() {
                result.error = Some(format!(
                    "The PDF was saved, but its document cache needs recovery: {error}"
                ));
            }
        }
        Ok((report, result, backup))
    }
    pub fn payload(&self, document: &LyraReaderDocument) -> Result<Payload, String> {
        self.validate_source()?;
        if let Some(session) = &self.session {
            session.control.check()?;
        } else if crate::draft_store::is_root(&self.path) {
            let _guard = WRITES
                .lock()
                .map_err(|_| "Annotation cache writer is unavailable")?;
            if crate::draft_store::read(&self.path)? != self.cache_pair() {
                return Err("The annotation cache or pending state changed outside this window. Reopen before saving the PDF.".into());
            }
        }
        if let Some(error) = &self.error {
            return Err(format!("Annotation cache writes are blocked: {error}"));
        }
        let file = document.annotations().map_err(|e| e.to_string())?;
        let mut result = Payload {
            annotations: vec![],
            bookmarks: vec![],
            updates: vec![],
            deletions: self.deletions.clone(),
            ids: HashSet::new(),
            has_bookmark_subtree: document
                .outline()
                .map_err(|e| e.to_string())?
                .iter()
                .any(|e| e.is_bookmark_subtree),
        };
        for entry in &self.entries {
            let Entry::Known(v) = entry else { continue };
            let id = string(v, "id")?;
            result.ids.insert(id.clone());
            if self.hidden_ink.contains(&id) {
                continue;
            }
            if kind(v) == "bookmark" {
                result.bookmarks.push(WriteBookmarkRecord {
                    id,
                    page: v["page"].as_u64().unwrap() as u32,
                    title: string(v, "title")?,
                    y_pt: number(v, "yPt")?,
                });
                continue;
            }
            let quads = Self::quads(v, document)?;
            let read_point = |value: &Value| -> Result<AnnotationPoint, String> {
                Ok(AnnotationPoint {
                    x_pt: number(value, "x")?,
                    y_pt: number(value, "y")?,
                })
            };
            let paths: Vec<Vec<AnnotationPoint>> = if let Some(paths) = v["paths"].as_array() {
                paths
                    .iter()
                    .map(|path| {
                        path.as_array()
                            .ok_or("Invalid path".to_string())?
                            .iter()
                            .map(read_point)
                            .collect()
                    })
                    .collect::<Result<_, String>>()?
            } else {
                vec![]
            };
            let line_start = v.get("lineStart").map(read_point).transpose()?;
            let line_end = v.get("lineEnd").map(read_point).transpose()?;
            let mut bounds = if let Some(r) = v.get("rect") {
                AnnotationQuad {
                    x_pt: number(r, "x")?,
                    y_pt: number(r, "y")?,
                    width_pt: number(r, "width")?,
                    height_pt: number(r, "height")?,
                }
            } else if let Some(q) = quads.first() {
                *q
            } else {
                let points: Vec<_> = paths
                    .iter()
                    .flatten()
                    .chain(line_start.iter())
                    .chain(line_end.iter())
                    .collect();
                if points.is_empty() {
                    return Err("Annotation has no geometry".into());
                }
                let left = points.iter().map(|p| p.x_pt).fold(f64::INFINITY, f64::min);
                let top = points.iter().map(|p| p.y_pt).fold(f64::INFINITY, f64::min);
                let right = points
                    .iter()
                    .map(|p| p.x_pt)
                    .fold(f64::NEG_INFINITY, f64::max);
                let bottom = points
                    .iter()
                    .map(|p| p.y_pt)
                    .fold(f64::NEG_INFINITY, f64::max);
                AnnotationQuad {
                    x_pt: left,
                    y_pt: top,
                    width_pt: (right - left).max(0.1),
                    height_pt: (bottom - top).max(0.1),
                }
            };
            for q in &quads {
                let right = (bounds.x_pt + bounds.width_pt).max(q.x_pt + q.width_pt);
                let bottom = (bounds.y_pt + bounds.height_pt).max(q.y_pt + q.height_pt);
                bounds.x_pt = bounds.x_pt.min(q.x_pt);
                bounds.y_pt = bounds.y_pt.min(q.y_pt);
                bounds.width_pt = right - bounds.x_pt;
                bounds.height_pt = bottom - bounds.y_pt;
            }
            let c = color(v).ok_or("Invalid annotation colour")?;
            let component =
                |offset| u8::from_str_radix(&c[offset..offset + 2], 16).map_err(|e| e.to_string());
            let write_kind = match kind(v) {
                "highlight" => AnnotationWriteKind::Highlight,
                "underline" => AnnotationWriteKind::Underline,
                "strikeout" => AnnotationWriteKind::StrikeOut,
                "stickyNote" => AnnotationWriteKind::Note,
                "textBox" => AnnotationWriteKind::FreeText,
                "ink" => AnnotationWriteKind::Ink,
                "square" => AnnotationWriteKind::Square,
                "circle" => AnnotationWriteKind::Circle,
                "stamp" => AnnotationWriteKind::Stamp,
                "signature" => AnnotationWriteKind::Signature,
                _ => AnnotationWriteKind::Line,
            };
            let (signature_width, signature_height, signature_rgba) = if kind(v) == "signature" {
                crate::artwork::pixels(&string(v, "image")?)?
            } else {
                (0, 0, Vec::new())
            };
            let annotation = WriteAnnotationRecord {
                id: id.clone(),
                page: v["page"].as_u64().unwrap() as u32,
                kind: write_kind,
                rect: bounds,
                quads,
                ink_paths: paths,
                line_start,
                line_end,
                line_arrow: kind(v) == "arrow",
                border_width_pt: v["strokeWidth"].as_f64().unwrap_or(1.0),
                color: AnnotationColorRecord {
                    red: component(1)?,
                    green: component(3)?,
                    blue: component(5)?,
                },
                opacity: f64::from(component(7)?) / 255.0,
                contents: string(v, "note")?,
                author: String::new(),
                modified: chrono::Utc::now().format("D:%Y%m%d%H%M%SZ").to_string(),
                font_size_pt: v["fontSize"].as_f64().unwrap_or(14.0),
                text_alignment: v["textAlignment"].as_str().unwrap_or("left").to_string(),
                stamp_style: v["stampStyle"].as_str().unwrap_or("custom").into(),
                signature_width,
                signature_height,
                signature_rgba,
            };
            let target = v["fileIdentity"].as_str().map(str::to_string).or_else(|| {
                file.iter()
                    .find(|a| a.id == format!("nm:{id}"))
                    .map(|a| a.id.clone())
            });
            if let Some(target) = target {
                let assign_name = target.starts_with("fp:").then(|| id.clone());
                result.updates.push(AnnotationUpdateRecord {
                    target,
                    annotation,
                    assign_name,
                });
            } else {
                result.annotations.push(annotation);
            }
        }
        Ok(result)
    }
    pub fn clear_saved(&mut self, ids: &HashSet<String>) -> Result<(), String> {
        let old = self.snapshot();
        let old_pending = self.pending.clone();
        self.entries.retain(
            |e| !matches!(e,Entry::Known(v)if v["id"].as_str().is_some_and(|id|ids.contains(id))),
        );
        self.deletions.clear();
        self.transient_ink.clear();
        self.hidden_ink.clear();
        self.pending.mark_clean(self.clean_snapshot());
        if let Err(error) = self.persist() {
            self.restore(old);
            self.pending = old_pending;
            return Err(error);
        }
        self.undo.clear();
        self.redo.clear();
        Ok(())
    }
    pub fn seed_bookmarks(&mut self, document: &LyraReaderDocument) -> Result<(), String> {
        if self.error.is_some() {
            return Ok(());
        }
        let mut identities = HashSet::new();
        for entry in &self.entries {
            let value = match entry {
                Entry::Known(v) => v.clone(),
                Entry::Opaque(raw) => serde_json::from_str(raw).map_err(|e| e.to_string())?,
            };
            if let Some(id) = value["id"].as_str() {
                identities.insert(id.to_uppercase());
            }
        }
        let removed: HashSet<_> = if self.pending.dirty {
            self.pending
                .clean
                .as_ref()
                .map(|c| {
                    c.bookmarks
                        .iter()
                        .filter_map(|b| b["id"].as_str().map(str::to_uppercase))
                        .filter(|id| !identities.contains(id))
                        .collect()
                })
                .unwrap_or_default()
        } else {
            HashSet::new()
        };
        for outline in document.outline().map_err(|e| e.to_string())? {
            if let (Some(id), Some(page)) = (outline.bookmark_id, outline.page)
                && valid_uuid(&id)
                && !removed.contains(&id.to_uppercase())
            {
                let y = outline.y_pt.unwrap_or(0.0);
                if identities.insert(id.to_uppercase()) {
                    self.entries.push(Entry::Known(json!({"id":id,"kind":"bookmark","page":page,"title":outline.title,"yPt":y,"createdAt":now()})));
                    self.embedded_bookmarks.insert(id);
                } else if let Some(Entry::Known(v)) = self.entries.iter().find(|e|
                    matches!(e,Entry::Known(v) if v["id"].as_str().is_some_and(|s| s.eq_ignore_ascii_case(&id))))
                    && kind(v) == "bookmark" && v["page"] == page && v["title"] == outline.title
                    && v["yPt"].as_f64().is_some_and(|old| (old-y).abs() < 0.01)
                {
                    self.embedded_bookmarks.insert(v["id"].as_str().unwrap().to_string());
                }
            }
        }
        if !self.pending.dirty {
            self.pending.set_clean_baseline(self.clean_snapshot());
        }
        Ok(())
    }
    pub fn load_opened(document: &LyraReaderDocument, root: Option<&Path>) -> Self {
        Self::load_internal(
            Path::new(&document.path()),
            document.page_count(),
            root,
            Some(document.document_identity()),
        )
    }
    pub fn load_with_root(document: &Path, page_count: u32, root: Option<&Path>) -> Self {
        Self::load_internal(document, page_count, root, None)
    }
    fn load_internal(
        document: &Path,
        page_count: u32,
        root: Option<&Path>,
        identity: Option<DocumentIdentityRecord>,
    ) -> Self {
        let location = root
            .map(|p| Ok(p.to_path_buf()))
            .unwrap_or_else(crate::document_cache::default_root)
            .and_then(|root| {
                crate::document_cache::DocumentCache::open_with_identity(document, &root, identity)
            });
        let (cache, path, initial_error) = match location {
            Ok(cache) => {
                let path = cache.annotations();
                (Some(cache), path, None)
            }
            // Keep the PDF readable; an unavailable location explicitly blocks annotation writes.
            Err(error) => (None, PathBuf::new(), Some(error)),
        };
        let mut result = Self {
            transient_ink: HashSet::new(),
            hidden_ink: HashSet::new(),
            erase: None,
            embedded_bookmarks: HashSet::new(),
            path,
            source_error: cache.as_ref().and_then(|c| c.opened_source_status().err()),
            cache,
            session: None,
            owns_recovery: false,
            baseline: None,
            pending_baseline: None,
            pending: PendingState::new(false, None),
            entries: vec![],
            deletions: vec![],
            undo: vec![],
            redo: vec![],
            error: initial_error,
            page_count,
        };
        let parsed = (|| -> Result<(), String> {
            if let Some(error) = &result.error {
                return Err(error.clone());
            }
            let _guard = WRITES
                .lock()
                .map_err(|_| "Annotation cache writer is unavailable")?;
            let mut pair = crate::draft_store::read(&result.path)?;
            result.baseline = pair.records.clone();
            result.pending_baseline = pair.pending.clone();
            if let Some(bytes) = &pair.records {
                result.entries = decode_entries(bytes, page_count)?;
            }
            let pending = crate::draft_store::recover(&result.path, &mut pair, page_count)?;
            if let Some(bytes) = &pair.records {
                result.entries = decode_entries(bytes, page_count)?;
            }
            result.baseline = pair.records;
            result.pending_baseline = pair.pending;
            result.pending = pending.unwrap_or_else(|| {
                PendingState::new(
                    result.entries.iter().any(|e| matches!(e, Entry::Known(_))),
                    None,
                )
            });
            result.deletions = result
                .pending
                .deletions
                .iter()
                .map(|d| AnnotationDeleteRecord {
                    target: d.identity.clone(),
                    page: d.page,
                })
                .collect();
            result.hidden_ink = result.pending.erased_ink.iter().cloned().collect();
            result.pending.commit = None;
            Ok(())
        })();
        if let Err(error) = parsed {
            result.pending.dirty = result
                .entries
                .iter()
                .any(|entry| matches!(entry, Entry::Known(_)));
            result.error = Some(error)
        }
        result
    }
    pub fn page_snapshot(&self) -> Self {
        let mut result = self.clone();
        result.erase = None;
        result.undo.clear();
        result.redo.clear();
        result
    }
    pub fn storage_bytes(&self) -> usize {
        self.entries
            .iter()
            .map(|e| match e {
                Entry::Known(v) => serde_json::to_vec(v).map_or(0, |b| b.len()),
                Entry::Opaque(v) => v.len(),
            })
            .sum::<usize>()
            + self
                .deletions
                .iter()
                .map(|d| d.target.len() + 32)
                .sum::<usize>()
    }
    fn trim_history(history: &mut Vec<Snapshot>) {
        let mut bytes = history.iter().map(|s| s.bytes).sum::<usize>();
        while history.len() > 1 && (history.len() > 200 || bytes > MAX_HISTORY_BYTES) {
            bytes = bytes.saturating_sub(history.remove(0).bytes);
        }
    }
    fn snapshot(&self) -> Snapshot {
        Snapshot {
            transient_ink: self.transient_ink.clone(),
            hidden_ink: self.hidden_ink.clone(),
            embedded_bookmarks: self.embedded_bookmarks.clone(),
            bytes: self.storage_bytes(),
            entries: self.entries.clone(),
            deletions: self.deletions.clone(),
            dirty: self.pending.dirty,
        }
    }
    fn restore(&mut self, s: Snapshot) {
        self.erase = None;
        self.transient_ink = s.transient_ink;
        self.hidden_ink = s.hidden_ink;
        self.embedded_bookmarks = s.embedded_bookmarks;
        self.entries = s.entries;
        self.deletions = s.deletions;
        self.pending.dirty = s.dirty;
    }
    fn persist(&mut self) -> Result<(), String> {
        self.refresh_pending();
        if let Some(context) = self.session.clone() {
            let input = self.transaction_input(context.current_page, &context.selection)?;
            let state = context.control.mutate(|handle| {
                handle.persist(
                    input,
                    context.revision_url,
                    context.revision_number,
                    context.control.recovery_path.to_string_lossy().into_owned(),
                )
            })?;
            return match state.recovery_error {
                Some(error) => Err(error),
                None => Ok(()),
            };
        }

        let _write_guard = WRITES
            .lock()
            .map_err(|_| "Annotation cache writer is unavailable")?;
        if let Some(error) = &self.error {
            return Err(format!("Annotation cache writes are blocked: {error}"));
        }
        if crate::draft_store::is_root(&self.path) {
            // The state commit couples PDF-owned ink fragments with their deletion and hidden
            // originals, so every record can now survive a crash without duplicating ink.
            let bytes = encode_entries(&self.entries, self.page_count, &HashSet::new())?;
            let (pair, mut pending) =
                crate::draft_store::write(&self.path, &self.cache_pair(), bytes, &self.pending)?;
            self.baseline = pair.records;
            self.pending_baseline = pair.pending;
            pending.commit = None;
            self.pending = pending;
            return Ok(());
        }
        let current = if self.path.exists() {
            Some(fs::read(&self.path).map_err(|e| e.to_string())?)
        } else {
            None
        };
        if current != self.baseline {
            return Err(
                "The annotation cache changed outside this window. Reopen the document before saving."
                    .into(),
            );
        }
        let bytes = encode_entries(&self.entries, self.page_count, &self.transient_ink)?;
        if bytes.len() > MAX_SIDECAR_BYTES {
            return Err(
                "Annotation cache exceeds the 16 MiB limit; this change was not saved".into(),
            );
        }
        if self.baseline.as_ref() == Some(&bytes) {
            return Ok(());
        }
        let temporary = self.path.with_extension(format!("json.{}.tmp", uuid()?));
        let result = (|| -> Result<(), String> {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(&temporary).map_err(|e| e.to_string())?;
            if let Ok(metadata) = fs::metadata(&self.path) {
                file.set_permissions(metadata.permissions())
                    .map_err(|e| e.to_string())?
            }
            file.write_all(&bytes)
                .and_then(|_| file.sync_all())
                .map_err(|e| e.to_string())?;
            fs::rename(&temporary, &self.path).map_err(|e| e.to_string())?;
            if let Some(parent) = self.path.parent()
                && let Ok(directory) = fs::File::open(parent)
            {
                let _ = directory.sync_all();
            }
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result?;
        self.baseline = Some(bytes);
        Ok(())
    }
    fn change(&mut self, task: impl FnOnce(&mut Self) -> Result<(), String>) -> Result<(), String> {
        if !self.owns_recovery
            && let Some(cache) = &self.cache
        {
            cache.validate_recovery()?;
        }
        self.erase = None;
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        let old = self.snapshot();
        if let Err(error) = task(self).and_then(|_| self.persist()) {
            self.restore(old);
            if self.session.is_some()
                && let Err(rollback) = self.persist()
            {
                self.error = Some(format!("The editing session needs recovery: {rollback}"));
            }
            return Err(error);
        }
        self.undo.push(old);
        self.redo.clear();
        Self::trim_history(&mut self.undo);
        Ok(())
    }
    pub fn state(&self, document: &LyraReaderDocument) -> Result<Value, String> {
        let file = document.annotations().map_err(|e| e.to_string())?;
        let mut own = vec![];
        let mut bookmarks = vec![];
        for entry in &self.entries {
            if let Entry::Known(v) = entry {
                if v["id"]
                    .as_str()
                    .is_some_and(|id| self.hidden_ink.contains(id))
                {
                    continue;
                }
                if kind(v) == "bookmark" {
                    bookmarks.push(v.clone())
                } else {
                    own.push(self.display(v, document)?);
                }
            }
        }
        let mut adopted: HashSet<String> = own
            .iter()
            .filter_map(|v| v["fileIdentity"].as_str().map(str::to_string))
            .chain(
                own.iter()
                    .filter_map(|v| v["id"].as_str().map(str::to_string)),
            )
            .collect();
        for v in &own {
            if let Some(id) = v["id"].as_str() {
                adopted.insert(format!("nm:{id}"));
            }
        }
        // The writer removes a deleted parent's entire /IRT descendant chain.
        // Mirror that closure in the staged UI, including replies to replies.
        let mut children = std::collections::HashMap::<&str, Vec<&str>>::new();
        for a in &file {
            if a.is_reply
                && let Some(parent) = a.parent_id.as_deref()
            {
                children.entry(parent).or_default().push(a.id.as_str());
            }
        }
        let mut deleted: HashSet<&str> = self.deletions.iter().map(|d| d.target.as_str()).collect();
        let mut pending: Vec<&str> = deleted.iter().copied().collect();
        while let Some(parent) = pending.pop() {
            if let Some(replies) = children.get(parent) {
                for &reply in replies {
                    if deleted.insert(reply) {
                        pending.push(reply);
                    }
                }
            }
        }
        let removed: HashSet<String> = deleted.into_iter().map(str::to_owned).collect();
        let file: Vec<_> = file
            .into_iter()
            .filter(|a| !adopted.contains(&a.id) && !removed.contains(&a.id))
            .collect();
        let file = crate::artwork::annotations(file)?;
        Ok(
            json!({"annotations":own,"file_annotations":file,"bookmarks":bookmarks,"can_undo":!self.undo.is_empty(),"can_redo":!self.redo.is_empty(),"preserved":self.entries.iter().filter(|e|matches!(e,Entry::Opaque(_))).count(),"error":self.error.as_ref().or(self.source_error.as_ref()),"path":self.path,"pdf_dirty":self.pending.dirty || !self.deletions.is_empty() || !self.hidden_ink.is_empty(),"pending_deletions":self.deletions.len()}),
        )
    }
    fn display(&self, v: &Value, document: &LyraReaderDocument) -> Result<Value, String> {
        let mut value = v.clone();
        let c = color(v).ok_or("Invalid annotation colour")?;
        value["color"] = Value::String(c);
        value["quads"] =
            serde_json::to_value(Self::quads(v, document)?).map_err(|e| e.to_string())?;
        Ok(value)
    }
    fn quads(v: &Value, document: &LyraReaderDocument) -> Result<Vec<AnnotationQuad>, String> {
        if let Some(quads) = v["quads"].as_array() {
            return quads
                .iter()
                .map(|r| {
                    Ok(AnnotationQuad {
                        x_pt: number(r, "x")?,
                        y_pt: number(r, "y")?,
                        width_pt: number(r, "width")?,
                        height_pt: number(r, "height")?,
                    })
                })
                .collect();
        }
        if !["highlight", "underline", "strikeout"].contains(&kind(v)) {
            return Ok(vec![]);
        }
        let page = document
            .text_page(v["page"].as_u64().unwrap() as u32)
            .map_err(|e| e.to_string())?;
        let start = v["start"].as_u64().unwrap() as usize;
        let end = v["end"].as_u64().unwrap() as usize;
        if end >= page.chars.len() {
            return Err("Annotation text range is outside the page. Writes are blocked.".into());
        }
        Ok(page.chars[start..=end]
            .iter()
            .filter(|c| c.width_pt > 0.0 && c.height_pt > 0.0)
            .map(|c| AnnotationQuad {
                x_pt: c.x_pt,
                y_pt: c.y_pt,
                width_pt: c.width_pt,
                height_pt: c.height_pt,
            })
            .collect())
    }
    pub fn command(
        &mut self,
        op: &str,
        r: &Value,
        document: &LyraReaderDocument,
    ) -> Result<Value, String> {
        if op.starts_with("ink_erase_") {
            return self.erase_command(op, r, document);
        }
        let mut selected_id = None;
        match op {
            "marks" => {}
            "mark_create" => {
                let mut entry = r["entry"].clone();
                entry["id"] = json!(uuid()?);
                selected_id = entry["id"].as_str().map(str::to_string);
                entry["createdAt"] = json!(now());
                if !validate(&entry, self.page_count)? {
                    return Err("Unsupported annotation schema".into());
                }
                Self::quads(&entry, document)?;
                self.change(|s| {
                    s.entries.push(Entry::Known(entry));
                    Ok(())
                })?;
            }
            "bookmark_create" => {
                let entry = json!({"id":uuid()?,"kind":"bookmark","page":r["page"],"title":r["title"],"yPt":r.get("yPt").cloned().unwrap_or(json!(0)),"createdAt":now()});
                validate(&entry, self.page_count)?;
                self.change(|s| {
                    s.entries.push(Entry::Known(entry));
                    Ok(())
                })?;
            }
            "mark_update" | "bookmark_update" => {
                let id = string(r, "id")?;
                let patch = r["patch"]
                    .as_object()
                    .ok_or("Missing annotation changes")?
                    .clone();
                self.change(|s| {
                    s.embedded_bookmarks.remove(&id);
                    let v = s
                        .entries
                        .iter_mut()
                        .find_map(|e| match e {
                            Entry::Known(v) if v["id"] == id => Some(v),
                            _ => None,
                        })
                        .ok_or("Annotation not found")?;
                    for (k, value) in patch {
                        if k == "id" || k == "createdAt" {
                            return Err("Annotation identity is immutable".into());
                        }
                        v[k] = value;
                    }
                    if !validate(v, s.page_count)? {
                        return Err("Unsupported annotation changes".into());
                    }
                    Self::quads(v, document)?;
                    Ok(())
                })?;
            }
            "mark_delete" | "bookmark_delete" => {
                let id = string(r, "id")?;
                let file = document.annotations().map_err(|e| e.to_string())?;
                self.change(|s| {
                    let target = s.entries.iter().find_map(|e| match e {
                        Entry::Known(v) if v["id"] == id => v["fileIdentity"]
                            .as_str()
                            .map(str::to_string)
                            .or_else(|| {
                                file.iter()
                                    .find(|a| a.id == format!("nm:{id}"))
                                    .map(|a| a.id.clone())
                            })
                            .map(|target| AnnotationDeleteRecord {
                                target,
                                page: v["page"].as_u64().unwrap_or(0) as u32,
                            }),
                        _ => None,
                    });
                    if let Some(deletion) = target {
                        s.deletions.push(deletion);
                    }
                    let before = s.entries.len();
                    s.entries
                        .retain(|e| !matches!(e,Entry::Known(v)if v["id"]==id));
                    if s.entries.len() == before {
                        return Err("Annotation not found".into());
                    }
                    Ok(())
                })?;
            }
            "bookmark_move" => {
                let id = string(r, "id")?;
                let delta = r["delta"].as_i64().ok_or("Invalid bookmark move")?;
                self.change(|s| {
                    let positions: Vec<_> = s
                        .entries
                        .iter()
                        .enumerate()
                        .filter_map(|(i, e)| {
                            if matches!(e,Entry::Known(v)if kind(v)=="bookmark") {
                                Some(i)
                            } else {
                                None
                            }
                        })
                        .collect();
                    let index = positions
                        .iter()
                        .position(|i| matches!(&s.entries[*i],Entry::Known(v)if v["id"]==id))
                        .ok_or("Bookmark not found")?;
                    let next = (index as i64 + delta).clamp(0, positions.len() as i64 - 1) as usize;
                    s.entries.swap(positions[index], positions[next]);
                    Ok(())
                })?;
            }
            "marks_undo" | "marks_redo" => {
                self.erase = None;
                let previous = if op == "marks_undo" {
                    self.undo.pop()
                } else {
                    self.redo.pop()
                }
                .ok_or("No change to undo")?;
                let current = self.snapshot();
                self.restore(previous.clone());
                if let Err(e) = self.persist() {
                    self.restore(current);
                    if op == "marks_undo" {
                        self.undo.push(previous)
                    } else {
                        self.redo.push(previous)
                    }
                    return Err(e);
                }
                if op == "marks_undo" {
                    self.redo.push(current)
                } else {
                    self.undo.push(current)
                }
                Self::trim_history(&mut self.undo);
                Self::trim_history(&mut self.redo);
            }
            "file_delete" => {
                let id = string(r, "id")?;
                let records = document.annotations().map_err(|e| e.to_string())?;
                let record = records
                    .iter()
                    .find(|a| a.id == id)
                    .ok_or("File annotation not found")?;
                if record.is_reply {
                    return Err(
                        "Edit or delete the annotation at the top of this reply thread".into(),
                    );
                }
                let deletion = AnnotationDeleteRecord {
                    target: id,
                    page: record.page,
                };
                self.change(|s| {
                    if !s.deletions.iter().any(|d| d.target == deletion.target) {
                        s.deletions.push(deletion)
                    }
                    Ok(())
                })?;
            }
            "marks_erase" => {
                let ids: Vec<String> =
                    serde_json::from_value(r["ids"].clone()).map_err(|e| e.to_string())?;
                let file = document.annotations().map_err(|e| e.to_string())?;
                self.change(|s| {
                    for id in ids {
                        let own = s.entries.iter().position(
                            |e| matches!(e,Entry::Known(v)if v["id"]==id && kind(v)=="ink"),
                        );
                        if let Some(index) = own {
                            if let Entry::Known(v) = &s.entries[index]
                                && let Some(target) = v["fileIdentity"].as_str()
                            {
                                s.deletions.push(AnnotationDeleteRecord {
                                    target: target.to_string(),
                                    page: v["page"].as_u64().unwrap() as u32,
                                });
                            }
                            s.entries.remove(index);
                        } else if let Some(a) = file
                            .iter()
                            .find(|a| a.id == id && a.kind == "ink" && !a.is_reply && a.visible)
                        {
                            if !s.deletions.iter().any(|d| d.target == id) {
                                s.deletions.push(AnnotationDeleteRecord {
                                    target: id,
                                    page: a.page,
                                });
                            }
                        } else {
                            return Err("Only whole ink strokes can be erased".into());
                        }
                    }
                    Ok(())
                })?;
            }
            "file_adopt" => {
                let id = string(r, "id")?;
                let records = document.annotations().map_err(|e| e.to_string())?;
                let a = records
                    .iter()
                    .find(|a| a.id == id)
                    .ok_or("File annotation not found")?;
                if a.is_reply {
                    return Err(
                        "Replies stay attached to their thread and cannot be adopted separately"
                            .into(),
                    );
                }
                if !a.visible || a.drawing == "skipped" {
                    return Err("This file annotation is hidden or not drawn".into());
                }
                let k = match a.kind.as_str() {
                    "stamp"
                        if a.stamp.as_ref().is_some_and(|s| {
                            s.text.as_deref().is_some_and(|t| !t.trim().is_empty())
                        }) =>
                    {
                        "stamp"
                    }
                    "stamp" if a.stamp.as_ref().is_some_and(|s| !s.image.is_empty()) => "signature",
                    "line" if a.line_arrow => "arrow",
                    "text" => "stickyNote",
                    "freeText" => "textBox",
                    kind if AnnotationKind::from_record_kind(kind).is_some() => kind,
                    _ => {
                        return Err(
                            "This annotation kind can be deleted but cannot be edited".into()
                        );
                    }
                };
                let existing = self.entries.iter().find_map(|e| match e {
                    Entry::Known(v) if v["fileIdentity"] == id => {
                        v["id"].as_str().map(str::to_string)
                    }
                    _ => None,
                });
                let selected = if let Some(existing) = existing {
                    existing
                } else {
                    let identity = uuid()?;
                    let c = a.color.unwrap_or(AnnotationColorRecord {
                        red: 232,
                        green: 188,
                        blue: 85,
                    });
                    let mut entry = json!({"id":identity,"kind":k,"page":a.page,"note":a.contents.clone().unwrap_or_default(),"createdAt":now(),"color":format!("#{:02X}{:02X}{:02X}{:02X}",c.red,c.green,c.blue,(a.opacity.unwrap_or(1.0).clamp(0.0,1.0)*255.0).round()as u8),"fileIdentity":id});
                    let p = |v: &AnnotationPoint| json!({"x":v.x_pt,"y":v.y_pt});
                    match k {
                        "highlight" | "underline" | "strikeout" => {
                            entry["start"] = json!(0);
                            entry["end"] = json!(0);
                            let quads = if a.quads.is_empty() {
                                vec![AnnotationQuad {
                                    x_pt: a.x_pt,
                                    y_pt: a.y_pt,
                                    width_pt: a.width_pt,
                                    height_pt: a.height_pt,
                                }]
                            } else {
                                a.quads.clone()
                            };
                            entry["quads"]=json!(quads.iter().map(|q|json!({"x":q.x_pt,"y":q.y_pt,"width":q.width_pt,"height":q.height_pt})).collect::<Vec<_>>());
                        }
                        "ink" => {
                            entry["version"] = json!(1);
                            entry["paths"] = json!(
                                a.ink_paths
                                    .iter()
                                    .map(|path| path.iter().map(p).collect::<Vec<_>>())
                                    .collect::<Vec<_>>()
                            );
                            entry["strokeWidth"] = json!(a.border_width_pt.unwrap_or(2.0).max(0.1));
                        }
                        "line" | "arrow" => {
                            entry["version"] = json!(1);
                            entry["lineStart"] =
                                a.line_start.as_ref().map(p).ok_or("Missing line start")?;
                            entry["lineEnd"] =
                                a.line_end.as_ref().map(p).ok_or("Missing line end")?;
                            entry["strokeWidth"] = json!(a.border_width_pt.unwrap_or(2.0).max(0.1));
                        }
                        _ => {
                            entry["version"] = json!(1);
                            entry["rect"] = json!({"x":a.x_pt,"y":a.y_pt,"width":a.width_pt.max(1.0),"height":a.height_pt.max(1.0)});
                            if k == "stickyNote" || k == "textBox" {
                                entry["fontSize"] = json!(a.font_size_pt.unwrap_or(14.0));
                                entry["textAlignment"] = json!(a.alignment);
                            } else if k == "stamp" {
                                let stamp = a.stamp.as_ref().ok_or("Missing stamp artwork")?;
                                entry["note"] = json!(stamp.text.clone().unwrap_or_default());
                                entry["stampStyle"] = json!(match stamp.style.as_str() {
                                    "approved" | "reviewed" | "draft" | "confidential" | "date" =>
                                        stamp.style.as_str(),
                                    _ => "custom",
                                });
                            } else if k == "signature" {
                                let stamp = a.stamp.as_ref().ok_or("Missing signature artwork")?;
                                entry["note"] = json!("");
                                entry["stampStyle"] = json!("signature");
                                entry["image"] = json!(crate::artwork::encode(&stamp.image));
                            } else {
                                entry["strokeWidth"] =
                                    json!(a.border_width_pt.unwrap_or(2.0).max(0.1));
                            }
                        }
                    }
                    if !validate(&entry, self.page_count)? {
                        return Err("Unsupported file annotation geometry".into());
                    }
                    self.change(|s| {
                        s.entries.push(Entry::Known(entry));
                        Ok(())
                    })?;
                    identity
                };
                let mut state = self.state(document)?;
                state["selected_id"] = json!(selected);
                return Ok(state);
            }
            "marks_recover" => {
                if let Some(cache) = &self.cache {
                    cache.validate_recovery()?;
                }
                let previous = self.clone();
                let (pair, backup) = {
                    let _guard = WRITES
                        .lock()
                        .map_err(|_| "Annotation cache writer is unavailable")?;
                    let pair = crate::draft_store::read(&self.path)?;
                    let backup = crate::draft_store::backup(&self.path, &pair)?;
                    (pair, backup)
                };
                self.error = None;
                self.baseline = pair.records;
                self.pending_baseline = pair.pending;
                self.entries.clear();
                self.deletions.clear();
                self.transient_ink.clear();
                self.hidden_ink.clear();
                self.erase = None;
                self.embedded_bookmarks.clear();
                self.undo.clear();
                self.redo.clear();
                self.pending = PendingState::new(false, Some(self.clean_snapshot()));
                if let Err(error) = self.persist() {
                    *self = previous;
                    return Err(format!(
                        "{error}. Recovery data is backed up at {}",
                        backup.display()
                    ));
                }
                self.seed_bookmarks(document)?;
            }
            _ => return Err("Unknown mark operation".into()),
        }
        let mut state = self.state(document)?;
        if let Some(id) = selected_id {
            state["selected_id"] = json!(id);
        }
        Ok(state)
    }
}

#[cfg(test)]
mod codec_checks {
    use super::*;

    #[test]
    fn desktop_codec_round_trips_the_shared_foundation_goldens_byte_for_byte() {
        for name in [
            "empty.json",
            "plain-highlights.json",
            "every-kind.json",
            "notes-newlines.json",
            "bookmarks-unicode.json",
            "old-version-record.json",
            "unknown-extra-fields.json",
            "interleaved-order.json",
            "ui-add-highlight.json",
        ] {
            let path = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/annotation-codec")
                .join(name);
            let bytes = fs::read(path).expect("required shared annotation golden");
            let entries = decode_entries(&bytes, 1000).expect(name);
            assert_eq!(
                encode_entries(&entries, 1000, &HashSet::new()).expect(name),
                bytes,
                "{name}"
            );
        }
    }

    #[test]
    fn imported_opaque_numbers_and_escaped_strings_keep_their_original_bytes() {
        let foreign = r#"{ "kind":"future", "number":1.0000e+00, "text":"a\/b" }"#;
        let entries = decode_entries(format!("[{foreign}]").as_bytes(), 1).expect("foreign entry");
        let output = encode_entries(&entries, 1, &HashSet::new()).expect("encode");
        assert!(String::from_utf8(output).expect("UTF-8").contains(foreign));
    }

    #[test]
    fn new_annotations_use_the_shared_writer_limits_before_persistence() {
        let value = json!({"id":"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", "kind":"highlight",
            "page":0,"start":0,"end":1,"note":"x".repeat(16*1024*1024),
            "createdAt":0,"color":"#E8BC5552"});
        let decoded = decode_records(&serde_json::to_vec(&vec![&value]).unwrap(), 1).unwrap();
        let expected = rules::validate_annotation(&decoded.annotations[0], 1, &[]).unwrap_err();
        assert_eq!(validate(&value, 1).unwrap_err(), expected.to_string());
    }
}

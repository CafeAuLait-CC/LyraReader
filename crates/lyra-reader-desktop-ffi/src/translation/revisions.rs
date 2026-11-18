//! Cache snapshots follow the shared transaction's immutable PDF revisions, not a mutable URL.
use super::*;
use crate::session::SessionDirectory;
use lyra_reader_ffi::DocumentTransactionStateRecord;
use std::{fs, path::Path};

fn revision_path(document: &LyraReaderDocument, directory: &Path) -> Result<PathBuf, String> {
    let document_path = document.path();
    let path = Path::new(&document_path);
    let stem = path
        .file_stem()
        .and_then(|v| v.to_str())
        .filter(|v| {
            !v.is_empty()
                && v.len() <= 96
                && v.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_'))
        })
        .ok_or("The translation revision has an invalid generated filename.")?;
    let sha = document.document_identity().sha256;
    if sha.len() != 64 || !sha.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err("The translation revision has an invalid source identity.".into());
    }
    Ok(directory.join(format!("lyra-translations-{stem}-{sha}.json")))
}

pub(crate) struct RevisionChange<'a> {
    pub(crate) previous: &'a LyraReaderDocument,
    pub(crate) next: &'a Arc<LyraReaderDocument>,
    pub(crate) location: &'a DocumentCache,
    pub(crate) session: Option<Arc<SessionDirectory>>,
    pub(crate) state: Option<&'a DocumentTransactionStateRecord>,
    pub(crate) report: &'a Value,
    pub(crate) operation: &'a str,
    pub(crate) original_path: &'a Path,
}

impl Translations {
    pub(super) fn capture_base(&mut self, location: &DocumentCache) -> Result<(), String> {
        let path = location.directory.join(FILE);
        if self.base_path.as_ref() != Some(&path) {
            self.base_baseline = read_optional_bounded(&path, MAX_BYTES as u64)?;
            self.base_path = Some(path);
        }
        Ok(())
    }
    pub(crate) fn save_snapshot(
        &mut self,
        location: &DocumentCache,
    ) -> Result<Option<Vec<u8>>, String> {
        self.capture_base(location)?;
        self.store.load(location)?;
        if let Some(error) = self.store.warning() {
            return Err(error);
        }
        Ok(self
            .store
            .baseline
            .as_ref()
            .map(|_| self.store.cache.encode().to_vec()))
    }
    pub(crate) fn publish_snapshot(
        &mut self,
        location: &DocumentCache,
        snapshot: Option<&[u8]>,
    ) -> Result<(), String> {
        let Some(bytes) = snapshot else {
            return Ok(());
        };
        location.validate_pdf_source()?;
        let _lease = crate::document_cache::lock_translation_cache(&location.directory)?;
        let path = location.directory.join(FILE);
        let existing = read_optional_bounded(&path, MAX_BYTES as u64)?;
        if existing.as_deref() == Some(bytes) {
            return Ok(());
        }
        let same_baseline_path = self.base_path.as_ref() == Some(&path);
        if existing != self.base_baseline && (existing.is_some() || same_baseline_path) {
            let recovery = location.directory.join(format!(
                "translations.recovery-{}.json",
                crate::marks::uuid()?
            ));
            atomic_write(&recovery, bytes)?;
            return Err(format!(
                "The PDF was saved, but destination translations changed. Both cache versions were kept; the working translations are recoverable at {}",
                recovery.display()
            ));
        }
        if let Some(previous) = existing {
            atomic_write(
                &location.directory.join("translations.previous.json"),
                &previous,
            )?;
        }
        atomic_write(&path, bytes)?;
        Ok(())
    }
    pub(crate) fn adopt_revision(&mut self, change: RevisionChange<'_>) -> Result<(), String> {
        let RevisionChange {
            previous,
            next,
            location,
            session,
            state,
            report,
            operation,
            original_path,
        } = change;
        self.stop();
        self.notice = None;
        self.rows.clear();
        self.running = false;
        self.token.clear();
        self.source = Weak::new();
        let override_path = if Path::new(&next.path()) != original_path {
            Some(revision_path(
                next,
                &session
                    .as_ref()
                    .ok_or("The translation revision has no session lease.")?
                    .path,
            )?)
        } else {
            None
        };
        let destination = override_path
            .clone()
            .unwrap_or_else(|| location.directory.join(FILE));
        self.capture_base(location)?;
        let existing = read_optional_bounded(&destination, MAX_BYTES as u64)?;
        if existing.is_some() || override_path.is_none() {
            self.store = Store {
                override_path,
                ..Default::default()
            };
            self.store.load(location)?;
            self.session_lease = session;
            return Ok(());
        }
        let from_base = matches!(operation, "page_restore" | "page_undo" | "page_redo");
        let (cache, map, old_rotations) = if from_base {
            let state = state.ok_or("The restored translation revision has no shared page map.")?;
            let mut map = vec![None; state.original_rotations.len()];
            for (current, original) in state.current_to_original.iter().enumerate() {
                if let Ok(original) = usize::try_from(*original) {
                    let slot = map
                        .get_mut(original)
                        .ok_or("The restored translation page map is invalid.")?;
                    *slot = Some(
                        u32::try_from(current)
                            .map_err(|_| "Too many restored translation pages.")?,
                    );
                }
            }
            let cache = match self.base_baseline.as_deref() {
                Some(bytes) => Cache::decode(bytes)?,
                None => Cache::default(),
            };
            (cache, map, state.original_rotations.clone())
        } else {
            self.store.load(location)?;
            if let Some(error) = self.store.error.as_ref().or(self.store.protection.as_ref()) {
                return Err(error.clone());
            }
            let map = if let Some(map) = report.get("page_map").filter(|v| !v.is_null()) {
                serde_json::from_value::<Vec<Option<u32>>>(map.clone())
                    .map_err(|e| e.to_string())?
            } else {
                (0..previous.page_count()).map(Some).collect()
            };
            (
                self.store.cache.clone(),
                map,
                previous.page_rotations().map_err(|e| e.to_string())?,
            )
        };
        let rotations = next.page_rotations().map_err(|e| e.to_string())?;
        let mut rotated = Vec::new();
        for (old, new) in map.iter().enumerate() {
            if let Some(new) = new
                && old_rotations.get(old) != rotations.get(*new as usize)
            {
                rotated.push(u32::try_from(old).map_err(|_| "Too many translation pages.")?);
            }
        }
        let projected = cache.projected(&map, &rotated, next.page_count())?;
        let removed = cache
            .entries()
            .count()
            .saturating_sub(projected.entries().count());
        if removed > 0 {
            self.notice = Some(format!(
                "{removed} saved translations were invalidated by page rotation or deletion. Other pages keep their translations; nothing was requested."
            ));
        }
        let warning = projected.warning.clone();
        if warning.is_none()
            && (projected.entries().next().is_some() || self.store.baseline.is_some())
        {
            let _lease = crate::document_cache::lock_translation_cache(
                destination
                    .parent()
                    .ok_or("The translation revision has no directory.")?,
            )?;
            if read_optional_bounded(&destination, MAX_BYTES as u64)?.is_some() {
                return Err("The translation revision cache appeared during projection; both versions were kept.".into());
            }
            atomic_write(&destination, projected.encode())?;
        }
        self.store = Store {
            override_path,
            path: Some(destination.clone()),
            baseline: read_optional_bounded(&destination, MAX_BYTES as u64)?,
            cache: projected,
            ..Default::default()
        };
        self.session_lease = session;
        self.collect_revision_caches()?;
        Ok(())
    }
    pub(crate) fn block_revision(&mut self, error: String) {
        self.store.protection = Some(error);
    }
    fn collect_revision_caches(&self) -> Result<(), String> {
        let Some(lease) = &self.session_lease else {
            return Ok(());
        };
        for entry in fs::read_dir(&lease.path).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            if !entry.file_type().map_err(|e| e.to_string())?.is_file() {
                continue;
            }
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                continue;
            };
            let Some(tail) = name.strip_prefix("lyra-translations-") else {
                continue;
            };
            let Some(tail) = tail
                .strip_suffix(".previous.json")
                .or_else(|| tail.strip_suffix(".json"))
            else {
                continue;
            };
            let Some((stem, sha)) = tail.rsplit_once('-') else {
                continue;
            };
            if stem.is_empty()
                || stem.len() > 96
                || !stem
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_'))
                || sha.len() != 64
                || !sha.bytes().all(|c| c.is_ascii_hexdigit())
            {
                continue;
            }
            // The shared transaction has already collected unreferenced generated PDFs while
            // respecting undo/redo and raster/print leases. Remove only our paired snapshots.
            if !lease.path.join(format!("{stem}.pdf")).exists() {
                fs::remove_file(entry.path()).map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }
}

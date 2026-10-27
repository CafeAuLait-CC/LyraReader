//! File adapter for a recoverable records/state pair. Callers hold the annotation writer lock.
use crate::document_cache::{atomic_write, read_optional};
use lyra_reader_edit::draft::{PendingState, RecordsCommit};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
};

const MAX_RECORDS: usize = 16 * 1024 * 1024;
const MAX_STATE: usize = 64 * 1024 * 1024;

#[derive(Clone, Debug, Default, PartialEq)]
pub(super) struct Pair {
    pub records: Option<Vec<u8>>,
    pub pending: Option<Vec<u8>>,
}

pub(super) fn is_root(path: &Path) -> bool {
    path.file_name().is_some_and(|n| n == "annotations.json")
}
fn pending_path(path: &Path) -> Result<PathBuf, String> {
    Ok(path
        .parent()
        .ok_or("No annotation cache directory")?
        .join("changes.json"))
}
pub(super) fn read(path: &Path) -> Result<Pair, String> {
    let records = read_optional(path)?;
    if records.as_ref().is_some_and(|v| v.len() > MAX_RECORDS) {
        return Err("Annotation cache exceeds the 16 MiB limit".into());
    }
    Ok(Pair {
        records,
        pending: read_optional(&pending_path(path)?)?,
    })
}
fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The pending file is the commit point. A crash before the compatibility mirror is
/// replaced is completed only when its exact previous bytes still match the commit.
pub(super) fn recover(
    path: &Path,
    pair: &mut Pair,
    pages: u32,
) -> Result<Option<PendingState>, String> {
    let Some(bytes) = &pair.pending else {
        return Ok(None);
    };
    let state = PendingState::decode(bytes, pages)?;
    if let Some(commit) = &state.commit {
        let bytes = commit.records.as_bytes();
        if bytes.len() > MAX_RECORDS || hash(bytes) != commit.sha256 {
            return Err(
                "The committed annotation records are damaged; recovery data was kept".into(),
            );
        }
        lyra_reader_edit::records::decode(
            bytes,
            pages as usize,
            &lyra_reader_edit::records::legacy_highlight_palette(),
        )
        .map_err(|e| e.to_string())?;
        let actual = pair.records.as_deref().map(hash);
        if actual.as_deref() != Some(commit.sha256.as_str()) {
            if actual != commit.previous_sha256 {
                return Err("The annotation cache changed outside the pending transaction; both versions were kept".into());
            }
            atomic_write(path, bytes)?;
            pair.records = Some(bytes.to_vec());
        }
    }
    Ok(Some(state))
}

pub(super) fn write(
    path: &Path,
    expected: &Pair,
    records: Vec<u8>,
    state: &PendingState,
) -> Result<(Pair, PendingState), String> {
    if read(path)? != *expected {
        return Err("The annotation cache or pending state changed outside this window. Reopen the PDF before saving.".into());
    }
    if records.len() > MAX_RECORDS {
        return Err("Annotation cache exceeds the 16 MiB limit".into());
    }
    let mut state = state.clone();
    state.commit = Some(RecordsCommit {
        records: String::from_utf8(records.clone()).map_err(|e| e.to_string())?,
        sha256: hash(&records),
        previous_sha256: expected.records.as_deref().map(hash),
    });
    let pending = state.encode()?;
    if pending.len() > MAX_STATE {
        return Err(
            "Pending annotation state exceeds the 64 MiB limit; the old cache was kept".into(),
        );
    }
    let next = Pair {
        records: Some(records),
        pending: Some(pending),
    };
    let changed = (|| {
        if next.pending != expected.pending {
            atomic_write(
                &pending_path(path)?,
                next.pending.as_deref().ok_or("Missing pending state")?,
            )?;
        }
        if next.records != expected.records {
            atomic_write(
                path,
                next.records
                    .as_deref()
                    .ok_or("Missing annotation records")?,
            )?;
        }
        Ok::<_, String>(())
    })();
    if let Err(error) = changed {
        // A failed fsync may follow a successful rename. Restore both exact before-images;
        // do not overwrite a third-party edit made while the write was failing.
        if let Err(rollback) = rollback_partial(path, expected, &next) {
            return Err(format!(
                "{error}. The pending commit was kept for recovery: {rollback}"
            ));
        }
        return Err(error);
    }
    Ok((next, state))
}

fn restore_file(path: &Path, bytes: Option<&[u8]>) -> Result<(), String> {
    if let Some(bytes) = bytes {
        return atomic_write(path, bytes);
    }
    match fs::remove_file(path) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.to_string()),
    }
    #[cfg(unix)]
    if let Some(parent) = path.parent() {
        fs::File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
fn rollback_partial(path: &Path, before: &Pair, next: &Pair) -> Result<(), String> {
    let current = read(path)?;
    if (current.records != before.records && current.records != next.records)
        || (current.pending != before.pending && current.pending != next.pending)
    {
        return Err(
            "The cache changed externally during rollback; no foreign bytes were overwritten"
                .into(),
        );
    }
    restore_file(path, before.records.as_deref())?;
    restore_file(&pending_path(path)?, before.pending.as_deref())?;
    if read(path)? != *before {
        return Err("Annotation cache rollback verification failed".into());
    }
    Ok(())
}
pub(super) fn rollback(path: &Path, before: &Pair, committed: &Pair) -> Result<(), String> {
    if read(path)? != *committed {
        return Err("The cache changed externally before discard could be rolled back; recovery data was kept".into());
    }
    rollback_partial(path, before, committed)
}

pub(super) fn backup(path: &Path, pair: &Pair) -> Result<PathBuf, String> {
    let directory = path
        .parent()
        .ok_or("No annotation cache directory")?
        .join(format!("discard-recovery-{}", crate::marks::uuid()?));
    let mut options = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        options.mode(0o700);
    }
    options.create(&directory).map_err(|e| e.to_string())?;
    let write = (|| {
        if let Some(bytes) = &pair.records {
            atomic_write(&directory.join("annotations.json"), bytes)?;
        }
        if let Some(bytes) = &pair.pending {
            atomic_write(&directory.join("changes.json"), bytes)?;
        }
        Ok::<_, String>(())
    })();
    write.map_err(|e| {
        format!(
            "The draft backup is incomplete at {}: {e}",
            directory.display()
        )
    })?;
    Ok(directory)
}

#[cfg(test)]
mod tests {
    use super::*;
    use lyra_reader_edit::draft::CleanSnapshot;
    fn temp() -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("lyra-draft-pair-{}", crate::marks::uuid().unwrap()));
        fs::create_dir(&path).unwrap();
        path
    }
    #[test]
    fn interrupted_mirror_publication_replays_but_foreign_edits_are_preserved() {
        let directory = temp();
        let path = directory.join("annotations.json");
        let old = b"[]\n".to_vec();
        fs::write(&path, &old).unwrap();
        let mut state = PendingState::new(false, Some(CleanSnapshot::new(vec![], vec![])));
        let records = "[ ]".to_string();
        state.commit = Some(RecordsCommit {
            sha256: hash(records.as_bytes()),
            records: records.clone(),
            previous_sha256: Some(hash(&old)),
        });
        fs::write(pending_path(&path).unwrap(), state.encode().unwrap()).unwrap();
        let mut pair = read(&path).unwrap();
        recover(&path, &mut pair, 1).unwrap();
        assert_eq!(fs::read(&path).unwrap(), records.as_bytes());
        fs::write(&path, b"  []").unwrap();
        let pending = fs::read(pending_path(&path).unwrap()).unwrap();
        let mut pair = read(&path).unwrap();
        assert!(recover(&path, &mut pair, 1).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"  []");
        assert_eq!(fs::read(pending_path(&path).unwrap()).unwrap(), pending);
        fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn committed_pair_can_be_rolled_back_and_external_metadata_blocks_a_write() {
        let directory = temp();
        let path = directory.join("annotations.json");
        let before = read(&path).unwrap();
        let state = PendingState::new(false, Some(CleanSnapshot::new(vec![], vec![])));
        let (after, _) = write(&path, &before, b"[]".to_vec(), &state).unwrap();
        rollback(&path, &before, &after).unwrap();
        assert_eq!(read(&path).unwrap(), before);
        fs::write(pending_path(&path).unwrap(), b"foreign").unwrap();
        assert!(write(&path, &before, b"[]".to_vec(), &state).is_err());
        assert_eq!(fs::read(pending_path(&path).unwrap()).unwrap(), b"foreign");
        fs::remove_dir_all(directory).unwrap();
    }
}

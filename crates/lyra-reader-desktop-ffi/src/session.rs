//! Ownership and file lifetime for the shared Rust document transaction.
use lyra_reader_core::sync::lock;
use lyra_reader_ffi::{LyraReaderDocumentTransaction, LyraReaderFfiError};
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc, LazyLock, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

static OWNERS: LazyLock<Mutex<HashSet<PathBuf>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

pub(super) struct SessionOwner(PathBuf);
impl SessionOwner {
    pub fn acquire(path: &Path) -> Result<Self, String> {
        let mut owners = lock(&OWNERS).map_err(|e| e.to_string())?;
        if !owners.insert(path.to_path_buf()) {
            return Err("This PDF is being edited in another window. Save or close that editing session first.".into());
        }
        Ok(Self(path.to_path_buf()))
    }
}
impl Drop for SessionOwner {
    fn drop(&mut self) {
        match lock(&OWNERS) {
            Ok(mut owners) => {
                owners.remove(&self.0);
            }
            // A poisoned ownership registry must remain fail-closed, including in cleanup.
            Err(e) => eprintln!("lyra-reader-session: ownership cleanup failed: {e}"),
        }
    }
}

pub(super) fn read_recovery(path: &Path) -> Result<Option<Vec<u8>>, String> {
    use std::io::Read;
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.to_string()),
    };
    const LIMIT: u64 = lyra_reader_edit::transaction::MAX_RECOVERY_BYTES;
    if file.metadata().map_err(|e| e.to_string())?.len() > LIMIT {
        return Err(
            "The cached editing session exceeds the 64 MiB read limit; its data was kept.".into(),
        );
    }
    let mut bytes = Vec::new();
    file.take(LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > LIMIT {
        return Err(
            "The cached editing session exceeds the 64 MiB read limit; its data was kept.".into(),
        );
    }
    Ok(Some(bytes))
}

pub(super) struct SessionControl {
    pub handle: Arc<LyraReaderDocumentTransaction>,
    pub recovery_path: PathBuf,
    baseline: Mutex<Option<Vec<u8>>>,
}
impl SessionControl {
    pub fn new(
        handle: Arc<LyraReaderDocumentTransaction>,
        path: PathBuf,
    ) -> Result<Arc<Self>, String> {
        let baseline = read_recovery(&path)?;
        if baseline.is_none() {
            return Err("The editing session could not be cached. No PDF change was made.".into());
        }
        Ok(Arc::new(Self {
            handle,
            recovery_path: path,
            baseline: Mutex::new(baseline),
        }))
    }

    pub fn check(&self) -> Result<(), String> {
        self.mutate(|_| Ok(()))
    }
    pub fn mutate<T>(
        &self,
        operation: impl FnOnce(&LyraReaderDocumentTransaction) -> Result<T, LyraReaderFfiError>,
    ) -> Result<T, String> {
        let mut expected = lock(&self.baseline).map_err(|e| e.to_string())?;
        if read_recovery(&self.recovery_path)? != *expected {
            return Err("The cached editing session changed outside this window. Its files were kept; reopen the original PDF before editing.".into());
        }
        let outcome = operation(&self.handle).map_err(|e| e.to_string());
        *expected = read_recovery(&self.recovery_path)?;
        outcome
    }
}

pub(super) struct SessionDirectory {
    pub path: PathBuf,
    control: Option<Arc<SessionControl>>,
    owner: Mutex<Option<SessionOwner>>,
    cleanup: AtomicBool,
    revisions: Mutex<HashMap<PathBuf, usize>>,
}
impl SessionDirectory {
    pub fn temporary(path: PathBuf) -> Self {
        Self {
            path,
            control: None,
            owner: Mutex::new(None),
            cleanup: AtomicBool::new(true),
            revisions: Mutex::new(HashMap::new()),
        }
    }
    pub fn recoverable(path: PathBuf, control: Arc<SessionControl>, owner: SessionOwner) -> Self {
        Self {
            path,
            control: Some(control),
            owner: Mutex::new(Some(owner)),
            cleanup: AtomicBool::new(false),
            revisions: Mutex::new(HashMap::new()),
        }
    }
    pub fn lease(self: &Arc<Self>, path: &Path) -> Result<RevisionLease, String> {
        let mut revisions = lock(&self.revisions).map_err(|e| e.to_string())?;
        let count = revisions.entry(path.to_path_buf()).or_insert(0);
        *count = count
            .checked_add(1)
            .ok_or("Revision lease count overflowed")?;
        Ok(RevisionLease {
            directory: Arc::clone(self),
            path: path.to_path_buf(),
        })
    }
    pub fn collect_garbage(&self) -> Result<(), String> {
        if let Some(control) = &self.control {
            let protected = lock(&self.revisions)
                .map_err(|e| e.to_string())?
                .keys()
                .map(|p| {
                    lyra_reader_edit::transaction::path_file_url(p, false)
                        .map_err(|e| e.to_string())
                })
                .collect::<Result<Vec<_>, _>>()?;
            control.mutate(|h| h.collect_revision_garbage(protected))?;
        }
        Ok(())
    }
    pub fn retire(&self) -> Result<(), String> {
        if let Some(control) = &self.control {
            control.mutate(|handle| handle.retire_recovery())?;
        }
        self.cleanup.store(true, Ordering::Release);
        // The public manifest is retired. A new session may start while immutable
        // render snapshots keep this directory and its retired transaction alive.
        lock(&self.owner).map_err(|e| e.to_string())?.take();
        Ok(())
    }
}
impl Drop for SessionDirectory {
    fn drop(&mut self) {
        if !self.cleanup.load(Ordering::Acquire) {
            return;
        }
        if let Some(control) = &self.control {
            if let Err(e) = control.handle.close(true) {
                eprintln!("lyra-reader-session: retired cleanup failed; files were kept: {e}");
            }
        } else {
            // Only a temporary directory created by this shell is disposable here.
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

pub(super) struct RevisionLease {
    directory: Arc<SessionDirectory>,
    path: PathBuf,
}
impl Drop for RevisionLease {
    fn drop(&mut self) {
        match lock(&self.directory.revisions) {
            Ok(mut revisions) => {
                if let Some(count) = revisions.get_mut(&self.path) {
                    *count -= 1;
                    if *count == 0 {
                        revisions.remove(&self.path);
                    }
                }
            }
            // A poisoned lease table must keep all files rather than guess at ownership.
            Err(e) => eprintln!("lyra-reader-session: revision lease cleanup failed: {e}"),
        }
    }
}

#[derive(Clone)]
pub(super) struct SessionContext {
    pub control: Arc<SessionControl>,
    pub revision_url: String,
    pub revision_number: u32,
    pub current_page: u32,
    pub selection: Vec<u32>,
}

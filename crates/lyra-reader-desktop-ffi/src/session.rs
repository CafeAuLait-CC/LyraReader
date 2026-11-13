//! Ownership and file lifetime for the shared Rust document transaction.
use lyra_reader_core::sync::lock;
use lyra_reader_ffi::{LyraReaderDocumentTransaction, LyraReaderFfiError};
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc, LazyLock, Mutex, Weak,
        atomic::{AtomicBool, Ordering},
    },
};

static OWNERS: LazyLock<Mutex<HashSet<PathBuf>>> = LazyLock::new(|| Mutex::new(HashSet::new()));

pub(super) struct SessionOwner(PathBuf);
impl SessionOwner {
    pub fn acquire(path: &Path) -> Result<Self, String> {
        let path = path
            .parent()
            .ok_or("Missing session owner directory")?
            .canonicalize()
            .map_err(|e| e.to_string())?
            .join(path.file_name().ok_or("Missing session owner filename")?);
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

// File leases belong to the directory, independently of the editable transaction.
// Reopening recovery in this process must see leases retained by an older preview.
static FILES: LazyLock<Mutex<HashMap<PathBuf, Weak<SessionFiles>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
struct SessionFiles {
    path: PathBuf,
    cleanup: AtomicBool,
    retirement: Mutex<Option<Arc<SessionControl>>>,
    revisions: Mutex<HashMap<PathBuf, usize>>,
}
impl SessionFiles {
    fn new(path: PathBuf, temporary: bool) -> Self {
        Self {
            path,
            cleanup: AtomicBool::new(temporary),
            retirement: Mutex::new(None),
            revisions: Mutex::new(HashMap::new()),
        }
    }
    fn recoverable(path: &Path) -> Result<Arc<Self>, String> {
        let path = path.canonicalize().map_err(|e| e.to_string())?;
        let mut files = lock(&FILES).map_err(|e| e.to_string())?;
        files.retain(|_, value| value.strong_count() > 0);
        if let Some(existing) = files.get(&path).and_then(Weak::upgrade) {
            return Ok(existing);
        }
        let state = Arc::new(Self::new(path.to_path_buf(), false));
        files.insert(path.to_path_buf(), Arc::downgrade(&state));
        Ok(state)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn directory_aliases_share_the_file_lease_registry() {
        let root = std::env::temp_dir().join(format!(
            "lyra-reader-lease-alias-{}",
            crate::marks::uuid().unwrap()
        ));
        fs::create_dir(&root).unwrap();
        let real = root.join("session-test");
        fs::create_dir(&real).unwrap();
        let alias = root.join("alias");
        std::os::unix::fs::symlink(&real, &alias).unwrap();
        let first = SessionFiles::recoverable(&real).unwrap();
        let second = SessionFiles::recoverable(&alias).unwrap();
        assert!(Arc::ptr_eq(&first, &second));
        drop(first);
        drop(second);
        // Only this test's unique synthetic directory is disposable.
        fs::remove_dir_all(root).unwrap();
    }
}
impl Drop for SessionFiles {
    fn drop(&mut self) {
        if !self.cleanup.load(Ordering::Acquire) {
            return;
        }
        // A poisoned lease table must keep every file rather than guess at ownership.
        if self.revisions.is_poisoned() {
            eprintln!("lyra-reader-session: poisoned file leases; files were kept");
            return;
        }
        match self.retirement.get_mut() {
            Ok(Some(control)) => {
                if let Err(e) = control.handle.close(true) {
                    eprintln!("lyra-reader-session: retired cleanup failed; files were kept: {e}");
                }
            }
            Ok(None) => {
                // Only a native-owned temporary or validated retired directory is disposable here.
                let _ = fs::remove_dir_all(&self.path);
            }
            Err(e) => {
                eprintln!("lyra-reader-session: retirement state unavailable; files were kept: {e}")
            }
        }
    }
}
pub(super) struct SessionDirectory {
    pub path: PathBuf,
    control: Option<Arc<SessionControl>>,
    owner: Mutex<Option<SessionOwner>>,
    files: Arc<SessionFiles>,
}
impl SessionDirectory {
    // Caller proved this is a retired session-* child of the document cache and
    // holds its editor registration. Existing immutable leases still delay removal.
    pub(super) fn retire_detached(path: &Path) -> Result<(), String> {
        let files = SessionFiles::recoverable(path)?;
        files.cleanup.store(true, Ordering::Release);
        Ok(())
    }
    pub fn temporary(path: PathBuf) -> Self {
        let files = Arc::new(SessionFiles::new(path.clone(), true));
        Self {
            path,
            control: None,
            owner: Mutex::new(None),
            files,
        }
    }
    pub fn recoverable(
        path: PathBuf,
        control: Arc<SessionControl>,
        owner: SessionOwner,
    ) -> Result<Self, String> {
        let files = SessionFiles::recoverable(&path)?;
        Ok(Self {
            path,
            control: Some(control),
            owner: Mutex::new(Some(owner)),
            files,
        })
    }
    pub fn lease(self: &Arc<Self>, path: &Path) -> Result<RevisionLease, String> {
        let mut revisions = lock(&self.files.revisions).map_err(|e| e.to_string())?;
        let count = revisions.entry(path.to_path_buf()).or_insert(0);
        *count = count
            .checked_add(1)
            .ok_or("Revision lease count overflowed")?;
        Ok(RevisionLease {
            files: Arc::clone(&self.files),
            path: path.to_path_buf(),
        })
    }
    pub fn collect_garbage(&self) -> Result<(), String> {
        if let Some(control) = &self.control {
            let protected = lock(&self.files.revisions)
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
        let mut owner = lock(&self.owner).map_err(|e| e.to_string())?;
        if let Some(control) = &self.control {
            // Acquire the fallible registry lock before retiring the public manifest.
            let mut retirement = lock(&self.files.retirement).map_err(|e| e.to_string())?;
            control.mutate(|handle| handle.retire_recovery())?;
            *retirement = Some(Arc::clone(control));
        }
        self.files.cleanup.store(true, Ordering::Release);
        // No preview owns this editor registration. Its independent file lease only
        // postpones cleanup, including across a restored editor of this same session.
        owner.take();
        Ok(())
    }
}
pub(super) struct RevisionLease {
    files: Arc<SessionFiles>,
    path: PathBuf,
}
impl Drop for RevisionLease {
    fn drop(&mut self) {
        match lock(&self.files.revisions) {
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

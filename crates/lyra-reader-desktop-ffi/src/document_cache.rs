//! Platform file I/O for recoverable reader state; identity comes from the shared engine.
use lyra_reader_ffi::api::{DocumentIdentityRecord, document_identity_for_path};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

const CARRIED_FILES: &[&str] = &[
    "annotations.json",
    "changes.json",
    "source.json",
    "translations.json",
    "summaries.json",
    "document-knowledge-v1.json",
    "region-conversations-v1.json",
];

#[derive(Clone)]
pub(super) struct DocumentCache {
    pub root: PathBuf,
    pub document: PathBuf,
    pub directory: PathBuf,
    identity: Option<DocumentIdentityRecord>,
    recovery_error: Option<String>,
}

// Compatible with DocumentEditCache.SourceStamp. Modification dates are intentionally
// ignored: touching unchanged bytes does not invalidate an editing session.
#[derive(Serialize, Deserialize)]
struct SourceStamp {
    size: u64,
    sha256: String,
}

pub(super) fn default_root() -> Result<PathBuf, String> {
    if let Some(value) =
        std::env::var_os("LYRA_READER_DOCUMENT_CACHE_DIR").filter(|s| !s.is_empty())
    {
        let root = PathBuf::from(value);
        return root
            .is_absolute()
            .then_some(root)
            .ok_or_else(|| "The document cache override must be an absolute path".into());
    }
    #[cfg(target_os = "windows")]
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    #[cfg(target_os = "macos")]
    let base = std::env::var_os("HOME").map(|p| PathBuf::from(p).join("Library/Caches"));
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".cache")));
    base.filter(|p| p.is_absolute())
        .map(|p| p.join("LyraReader/Documents"))
        .ok_or_else(|| "The platform document cache location is unavailable".into())
}

fn canonical_path(path: &Path) -> Result<PathBuf, String> {
    match path.canonicalize() {
        Ok(path) => Ok(path),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            // Save As may reserve a destination before its PDF exists.
            let parent = path
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or(Path::new("."));
            Ok(parent
                .canonicalize()
                .map_err(|e| e.to_string())?
                .join(path.file_name().ok_or("Missing document filename")?))
        }
        Err(e) => Err(e.to_string()),
    }
}

fn legacy_key(path: &Path) -> String {
    Sha256::digest(path.to_string_lossy().as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn private_directory(path: &Path) -> Result<(), String> {
    let mut options = fs::DirBuilder::new();
    options.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        options.mode(0o700);
    }
    options.create(path).map_err(|e| e.to_string())
}

fn read_optional(path: &Path) -> Result<Option<Vec<u8>>, String> {
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e.to_string()),
    };
    const LIMIT: u64 = 64 * 1024 * 1024;
    let oversized =
        || "A document cache file exceeds the 64 MiB read limit; its data was kept".to_string();
    if file.metadata().map_err(|e| e.to_string())?.len() > LIMIT {
        return Err(oversized());
    }
    // The actual read is bounded too, in case another process grows the file after metadata.
    let mut bytes = Vec::new();
    file.take(LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > LIMIT {
        return Err(oversized());
    }
    Ok(Some(bytes))
}

pub(super) fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or("Cache file has no parent directory")?;
    private_directory(parent)?;
    let temporary = parent.join(format!(".lyra-cache-{}.tmp", crate::marks::uuid()?));
    let result = (|| {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary).map_err(|e| e.to_string())?;
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|e| e.to_string())?;
        if fs::read(&temporary).map_err(|e| e.to_string())? != bytes {
            return Err("Document cache verification failed".to_string());
        }
        fs::rename(&temporary, path).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        fs::File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())?;
        Ok(())
    })();
    if result.is_err() {
        // Only this operation's randomly named temporary file is disposable.
        let _ = fs::remove_file(&temporary);
    }
    result
}

impl DocumentCache {
    pub fn open(document: &Path, root: &Path) -> Result<Self, String> {
        Self::open_with_identity(document, root, None)
    }

    pub fn open_with_identity(
        document: &Path,
        root: &Path,
        identity: Option<DocumentIdentityRecord>,
    ) -> Result<Self, String> {
        let document = canonical_path(document)?;
        let identity = if identity.is_some() {
            identity
        } else {
            match fs::metadata(&document) {
                Ok(_) => Some(
                    document_identity_for_path(document.to_string_lossy().into_owned())
                        .map_err(|e| e.to_string())?,
                ),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
                Err(e) => return Err(e.to_string()),
            }
        };
        let legacy = legacy_key(&document);
        let key = identity
            .as_ref()
            .map(|i| i.document_id.clone())
            .unwrap_or_else(|| legacy.clone());
        let mut result = Self {
            root: root.to_path_buf(),
            document,
            directory: root.join(&key),
            identity,
            recovery_error: None,
        };
        private_directory(&result.directory)?;
        if result.identity.is_some() {
            let pointer = root.join(format!("{legacy}.identity"));
            if let Some(bytes) = read_optional(&pointer)? {
                let previous = std::str::from_utf8(&bytes)
                    .map_err(|e| e.to_string())?
                    .trim();
                if previous.len() != 64 || !previous.bytes().all(|c| c.is_ascii_hexdigit()) {
                    return Err(
                        "The document cache identity pointer is invalid; its data was kept".into(),
                    );
                }
                result.recovery_error = result.copy_missing(&root.join(previous))?;
            }
            let legacy_recovery = result.copy_missing(&root.join(&legacy))?;
            if result.recovery_error.is_none() {
                result.recovery_error = legacy_recovery;
            }
            // Until the shared transaction restores/retargets an older session, retain
            // its pointer so the next launch cannot silently forget that recovery data.
            if result.recovery_error.is_none()
                && read_optional(&pointer)?.as_deref() != Some(key.as_bytes())
            {
                atomic_write(&pointer, key.as_bytes())?;
            }
            if read_optional(&result.directory.join("source.json"))?.is_none() {
                result.record_source()?;
            }
        }
        Ok(result)
    }

    fn copy_missing(&self, previous: &Path) -> Result<Option<String>, String> {
        if previous == self.directory || !previous.exists() {
            return Ok(None);
        }
        for name in CARRIED_FILES {
            let destination = self.directory.join(name);
            if !destination.exists()
                && let Some(bytes) = read_optional(&previous.join(name))?
            {
                atomic_write(&destination, &bytes)?;
            }
        }
        Ok(previous.join("session.json").exists().then(||
            "A previous cached page-editing session needs recovery before PDF writes can continue. Its files and identity pointer were kept.".to_string()))
    }

    pub fn annotations(&self) -> PathBuf {
        self.directory.join("annotations.json")
    }

    pub fn validate_source(&self) -> Result<(), String> {
        self.validate_recovery()?;
        if read_optional(&self.directory.join("source.json"))?.is_none() {
            return Ok(());
        }
        let current = document_identity_for_path(self.document.to_string_lossy().into_owned())
            .map_err(|e| e.to_string())?;
        self.compare_source(&current)
    }

    pub fn opened_source_status(&self) -> Result<(), String> {
        self.validate_recovery()?;
        match &self.identity {
            Some(identity) => self.compare_source(identity),
            None => Ok(()),
        }
    }

    pub(super) fn validate_recovery(&self) -> Result<(), String> {
        if let Some(error) = &self.recovery_error {
            return Err(error.clone());
        }
        if self.directory.join("session.json").exists() {
            return Err("A cached page-editing session needs recovery before PDF writes can continue. Its files were kept.".into());
        }
        Ok(())
    }

    fn compare_source(&self, current: &DocumentIdentityRecord) -> Result<(), String> {
        let Some(bytes) = read_optional(&self.directory.join("source.json"))? else {
            return Ok(());
        };
        let expected: SourceStamp = serde_json::from_slice(&bytes)
            .map_err(|e| format!("The PDF's saved source stamp could not be read: {e}"))?;
        if expected.size != current.size || expected.sha256 != current.sha256 {
            return Err("The PDF changed outside LyraReader. Its cached annotations were kept; restore the recorded PDF or back up recovery data before starting fresh.".into());
        }
        Ok(())
    }

    fn record_source(&self) -> Result<(), String> {
        if let Some(identity) = &self.identity {
            let bytes = serde_json::to_vec(&SourceStamp {
                size: identity.size,
                sha256: identity.sha256.clone(),
            })
            .map_err(|e| e.to_string())?;
            atomic_write(&self.directory.join("source.json"), &bytes)?;
        }
        Ok(())
    }

    /// A successful in-place write changes DocumentId. Carry the cleaned state while
    /// preserving the previous directory, and stamp the verified new PDF last.
    pub fn after_save(&self) -> Result<Self, String> {
        let next = Self::open(&self.document, &self.root)?;
        if next.directory != self.directory {
            for name in CARRIED_FILES.iter().filter(|n| **n != "source.json") {
                if let Some(bytes) = read_optional(&self.directory.join(name))? {
                    atomic_write(&next.directory.join(name), &bytes)?;
                }
            }
        }
        next.record_source()?;
        Ok(next)
    }
}

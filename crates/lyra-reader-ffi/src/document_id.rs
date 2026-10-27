//! The one identity a document has across every cache and every tab.
//!
//! Two paths can name the same bytes (a symlink and its target, `.` and an absolute path), and
//! the same path can name two different files over time (an in-place save, a replaced paper).
//! A cache keyed by only one of those facts gets one of the two wrong:
//!
//! * keyed by the path alone, `link.pdf` and `real.pdf` are two documents and the same file
//!   written through a second alias can silently share another document's cache;
//! * keyed by the content alone, two copies of the same paper share a cache even though their
//!   annotations and reading positions are independent.
//!
//! [`DocumentId`] is therefore **the canonical path plus the SHA-256 of the bytes**. It is
//! computed once when a document is opened (the bytes are hashed for the index cache anyway)
//! and carried on the document record. Every persisted cache derives its key from it:
//!
//! * the annotation/edit cache directory (the shell),
//! * AI region conversations, in-place translations, document knowledge and summaries (all live
//!   in that same directory),
//! * the recent-document cover key,
//! * the persistent index cache.
//!
//! # Stability and migration
//!
//! The key is stable for as long as the path and the bytes are, which is what a cache wants:
//! `touch` does not change it, while one appended byte does (the cached values may describe the
//! old bytes). Callers keep the old path-only keys readable: the shell copies the legacy cache
//! directory into the new one on first use, and [`crate::index_cache`] falls back to the legacy
//! path-hash cache and copies a hit forward. No old file is deleted by the read path.

use crate::api::{ErrorSeverity, LyraReaderFfiError};
use crate::index_cache::ContentIdentity;
use sha2::{Digest, Sha256};
use std::io;
use std::path::{Path, PathBuf};

/// Domain separation for the key hash. Changing the recipe must change this string, so a key
/// can never be mistaken for one produced by a different scheme.
const DOMAIN: &[u8] = b"lyra-reader-document-id/v1\0";

/// The identity of one opened document: where it is, and which bytes are there.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DocumentId {
    /// The file's canonical path, with every symlink resolved; the path the caches are keyed on.
    pub canonical_path: PathBuf,
    /// SHA-256 and byte length of the canonical file, reused by the index cache.
    pub content: ContentIdentity,
    /// The stable cache key derived from the two fields above.
    key: String,
}

impl DocumentId {
    /// Computes the identity. The file is read once, sequentially, in [`ContentIdentity::of`].
    pub(crate) fn of(path: &Path) -> io::Result<Self> {
        let canonical_path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        let content = ContentIdentity::of(&canonical_path)?;
        let key = key_for(&canonical_path, &content);
        Ok(Self {
            canonical_path,
            content,
            key,
        })
    }

    /// The stable cache key: lowercase hex SHA-256 of the domain, canonical path and content
    /// digest. It is used as a directory name and a file stem, so it is intentionally plain hex.
    pub(crate) fn key(&self) -> &str {
        &self.key
    }
}

impl From<io::Error> for LyraReaderFfiError {
    fn from(error: io::Error) -> Self {
        LyraReaderFfiError::Document {
            message: error.to_string(),
            severity: ErrorSeverity::Document,
        }
    }
}

fn key_for(canonical_path: &Path, content: &ContentIdentity) -> String {
    let mut hasher = Sha256::new();
    hasher.update(DOMAIN);
    hasher.update(canonical_path.as_os_str().as_encoded_bytes());
    hasher.update([0u8]);
    hasher.update(content.sha256.as_bytes());
    hasher.update([0u8]);
    hasher.update(content.bytes.to_le_bytes());
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// The document key for a path, for the shell before it has opened the document.
///
/// This is the same computation [`DocumentId::of`] performs; the shell memoises it so a check
/// that seeds a cache before opening the document and the open itself agree on one key.
#[uniffi::export]
pub fn document_id_for_path(path: String) -> Result<String, LyraReaderFfiError> {
    Ok(DocumentId::of(Path::new(&path))?.key)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn scratch(label: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "lyra-document-id-{}-{label}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).expect("scratch");
        directory
    }

    #[test]
    fn symlink_and_target_produce_one_key() {
        let directory = scratch("symlink");
        let real = directory.join("real.pdf");
        fs::write(&real, b"%PDF-1.7 same bytes").expect("write real");
        #[cfg(unix)]
        {
            let link = directory.join("link.pdf");
            std::os::unix::fs::symlink(&real, &link).expect("symlink");
            let real_id = DocumentId::of(&real).expect("real id");
            let link_id = DocumentId::of(&link).expect("link id");
            assert_eq!(real_id.key(), link_id.key());
            assert_eq!(real_id.canonical_path, link_id.canonical_path);
        }
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn a_touch_keeps_the_key_and_one_byte_changes_it() {
        let directory = scratch("bytes");
        let path = directory.join("a.pdf");
        fs::write(&path, b"%PDF-1.7 content").expect("write");
        let first = DocumentId::of(&path).expect("first");
        let same = DocumentId::of(&path).expect("same");
        assert_eq!(first.key(), same.key());
        fs::write(&path, b"%PDF-1.7 contenu").expect("overwrite");
        let changed = DocumentId::of(&path).expect("changed");
        assert_ne!(first.key(), changed.key());
        assert_ne!(first.content.sha256, changed.content.sha256);
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn different_files_on_the_same_path_do_not_share_a_key() {
        let directory = scratch("replaced");
        let path = directory.join("paper.pdf");
        fs::write(&path, b"one").expect("write one");
        let one = DocumentId::of(&path).expect("one");
        fs::write(&path, b"two").expect("write two");
        let two = DocumentId::of(&path).expect("two");
        assert_ne!(one.key(), two.key());
        let _ = fs::remove_dir_all(&directory);
    }
}

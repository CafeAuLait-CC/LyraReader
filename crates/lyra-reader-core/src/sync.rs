//! Failure-aware mutex acquisition.
//!
//! # Policy: lock poisoning is an error, not a shrug
//!
//! A [`std::sync::Mutex`] is poisoned when a thread panics while holding it. The value behind
//! the mutex may then be half-updated, so continuing with [`std::sync::PoisonError::into_inner`]
//! can turn one earlier panic into a silent wrong result. The engine's policy is **fail fast**:
//! every lock that guards mutable state is acquired through [`lock`], and a poisoned lock becomes
//! a normal [`LyraReaderError`] (`CorruptDocument`, "internal state was corrupted by an earlier
//! failure; reopen the document") that the shell already knows how to show. A port of that error
//! through the FFI keeps it a document-level error, never a panic and never a default.
//!
//! Two narrow exceptions are allowed and must be justified where they occur:
//!
//! * a **pure cache** may be discarded on poisoning instead of failing the operation — a cache
//!   miss is a defined outcome, not incorrect data;
//! * a **destructor** cannot return an error and must still release a resource; cleanup may take
//!   the guard with [`std::sync::PoisonError::into_inner`] when the mutex guards no data (for
//!   example the process-wide `PDFIUM_LOCK` is a `Mutex<()>` used only for serialisation).
//!
//! This module is the single spelling of the first rule; call sites use it instead of writing
//! `unwrap_or_else` by hand.

use crate::error::{ErrorCode, LyraReaderError, Result};
use std::sync::{Mutex, MutexGuard, PoisonError};

/// The domain error returned when an earlier panic poisoned a mutex.
///
/// The sentence names the only safe recovery: the in-memory state built by this call chain is
/// not trustworthy, so the document must be reopened (which rebuilds every handle from the file).
pub fn lock_poisoned_error() -> LyraReaderError {
    LyraReaderError::new(
        ErrorCode::CorruptDocument,
        "internal state was corrupted by an earlier failure; reopen the document",
    )
}

/// Acquires `mutex`, mapping poisoning to [`lock_poisoned_error`] instead of continuing.
pub fn lock<T>(mutex: &Mutex<T>) -> Result<MutexGuard<'_, T>> {
    mutex.lock().map_err(|_| lock_poisoned_error())
}

/// Acquires a mutex in a destructor, where no error can be returned.
///
/// This is the cleanup-only spelling and deliberately discards the poison marker: the caller is
/// releasing a resource (a PDFium document or page handle), not reading or trusting the guarded
/// data. Use it only from `Drop`-like code, never from an operation that reports to the user.
pub fn lock_for_cleanup<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn a_poisoned_lock_is_the_document_level_corruption_error() {
        let mutex = Arc::new(Mutex::new(0));
        let clone = Arc::clone(&mutex);
        let panicked = std::panic::catch_unwind(move || {
            let _guard = clone.lock().expect("fresh lock");
            panic!("poison the lock for the test");
        });
        assert!(panicked.is_err(), "the test must leave the mutex poisoned");

        let error = lock(&mutex).expect_err("a poisoned lock must be an error");
        assert_eq!(error.code, ErrorCode::CorruptDocument);
        assert_eq!(error.severity, crate::Severity::Document);
        assert_eq!(
            error.message,
            "internal state was corrupted by an earlier failure; reopen the document"
        );

        // The cleanup-only spelling still hands the guard back, which is what a destructor needs.
        assert_eq!(*lock_for_cleanup(&mutex), 0);
    }
}

//! A panic while holding `PDFIUM_LOCK` must turn the next PDFium call into an explicit error.
//!
//! This runs in its own test binary on purpose: poisoning a `std::sync::Mutex` is permanent for
//! the process, so a unit test inside the crate would break every other PDFium test that happens
//! to run afterwards. The test-only hook panics while holding the same process-wide lock the
//! backend uses, exactly as a panic inside a PDFium call would.

use lyra_reader_core::{ErrorCode, Severity};
use lyra_reader_pdfium::PdfiumBackend;
use std::path::{Path, PathBuf};

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/multipage.pdf")
}

#[test]
fn a_poisoned_pdfium_lock_makes_the_next_call_fail_explicitly() {
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let source = fixture();
    if !source.is_file() {
        eprintln!("skipping: {} is not present", source.display());
        return;
    }

    // A panic normally prints a backtrace line; keep the expected panic out of the test log.
    let previous_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    lyra_reader_pdfium::poison_pdfium_lock_for_test();
    std::panic::set_hook(previous_hook);

    let error = PdfiumBackend::open(&source, None)
        .err()
        .expect("the poisoned lock must fail the next open, not continue with stale state");
    assert_eq!(error.code, ErrorCode::CorruptDocument);
    assert_eq!(error.severity, Severity::Document);
    assert_eq!(
        error.message,
        "internal state was corrupted by an earlier failure; reopen the document"
    );

    // And it stays an error: the lock is not silently un-poisoned by the failed attempt.
    let error = PdfiumBackend::open(&source, None)
        .err()
        .expect("a second call after the poison must still fail");
    assert_eq!(error.code, ErrorCode::CorruptDocument);
}

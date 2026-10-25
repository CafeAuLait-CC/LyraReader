//! Repository-wide greps that are part of the error/lock policy.
//!
//! These are deliberately source checks, not runtime checks: the decision is "this spelling no
//! longer exists outside the one helper", and a compile-time-shaped assertion is the honest way
//! to keep a future call site from reintroducing it. Paths are resolved from this crate, so the
//! test works from any checkout.

use std::path::{Path, PathBuf};

fn workspace_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("workspace root")
}

fn rust_sources() -> Vec<PathBuf> {
    fn walk(directory: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(directory) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                walk(&path, out);
            } else if path.extension().is_some_and(|extension| extension == "rs") {
                out.push(path);
            }
        }
    }
    let mut sources = Vec::new();
    walk(&workspace_root().join("crates"), &mut sources);
    sources
}

/// The one place `unwrap_or(u32::MAX)` may appear: the saturation helper itself.
#[test]
fn saturation_has_one_spelling() {
    let allowed = workspace_root().join("crates/lyra-reader-core/src/validation.rs");
    let mut offenders = Vec::new();
    for path in rust_sources() {
        if path == allowed || path.ends_with("source_contracts.rs") {
            continue;
        }
        let source = std::fs::read_to_string(&path).expect("read source");
        if source.contains("unwrap_or(u32::MAX)") {
            offenders.push(path);
        }
    }
    assert!(
        offenders.is_empty(),
        "use lyra_reader_core::saturating_u32 instead of a local unwrap_or(u32::MAX): {offenders:#?}"
    );
}

/// `localization_key`, `ErrorCode::Cancelled` and `ErrorCode::NotReady` are gone.
#[test]
fn deleted_error_items_stay_deleted() {
    let localization_key = concat!("localization", "_key");
    let cancelled = concat!("ErrorCode", "::Cancelled");
    let not_ready = concat!("ErrorCode", "::NotReady");
    let mut offenders = Vec::new();
    for path in rust_sources() {
        if path.ends_with("source_contracts.rs") {
            continue;
        }
        let source = std::fs::read_to_string(&path).expect("read source");
        for (needle, allow_ai_prefix) in [
            (localization_key, false),
            (cancelled, true),
            (not_ready, true),
        ] {
            for (index, _) in source.match_indices(needle) {
                // `AiErrorCode::Cancelled` is a different enum and stays.
                if allow_ai_prefix && source[..index].ends_with("Ai") {
                    continue;
                }
                offenders.push(format!("{}: {needle}", path.display()));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "deleted error items must not return without a caller: {offenders:#?}"
    );
}

/// `poisoned.into_inner()` may only remain where the guarded data is a pure cache or a queue.
#[test]
fn lock_poisoning_is_only_ignored_for_caches() {
    const ALLOWED: &[&str] = &[
        // Page-text/selection and AI-text caches: immutable entries, a miss is defined.
        "crates/lyra-reader-ffi/src/api.rs",
        // AI request event queue and its "provider rejected stream_options" cache.
        "crates/lyra-reader-ai/src/openai.rs",
    ];
    let mut offenders = Vec::new();
    for path in rust_sources() {
        if path.ends_with("source_contracts.rs") {
            continue;
        }
        let source = std::fs::read_to_string(&path).expect("read source");
        if !source.contains("poisoned.into_inner") {
            continue;
        }
        let relative = path
            .strip_prefix(workspace_root())
            .expect("inside workspace");
        if !ALLOWED.contains(&relative.to_string_lossy().as_ref()) {
            offenders.push(relative.display().to_string());
        }
    }
    assert!(
        offenders.is_empty(),
        "a lock-poisoning site outside the justified caches: {offenders:#?}"
    );
}

//! The cooperative index scans must produce exactly the monolithic results.
//!
//! The shell now reads references, captions and document annotations in bounded steps so
//! visible rasters can run between them. That is only safe if a stepped scan is byte-identical
//! to the one-call scan it replaces: same records, same order, same citation map, same
//! unreadable-annotation report. This test drives both paths over the same fixture copy and
//! compares every field.

#[path = "support/index_cache.rs"]
mod cache_test;

use lyra_reader_ffi::api::{LyraReaderDocument, LyraReaderEngine};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn fixture(name: &str) -> PathBuf {
    if let Some(override_dir) = std::env::var_os("LYRA_READER_TEST_FIXTURES")
        && !override_dir.is_empty()
    {
        let candidate = PathBuf::from(override_dir).join(name);
        if candidate.is_file() {
            return candidate;
        }
    }
    if let Ok(current) = std::env::current_dir() {
        for ancestor in current.ancestors() {
            let candidate = ancestor.join("tests/fixtures").join(name);
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    panic!("test fixture {name:?} was not found from the current directory");
}

fn copy_fixture(label: &str, name: &str) -> PathBuf {
    let directory = std::env::temp_dir().join(format!(
        "lyra-cooperative-scan-{}-{label}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&directory);
    fs::create_dir_all(&directory).expect("create scratch directory");
    let path = directory.join("document.pdf");
    fs::copy(fixture(name), &path).expect("copy fixture");
    path
}

fn open(path: &Path) -> (Arc<LyraReaderEngine>, Arc<LyraReaderDocument>) {
    let engine = LyraReaderEngine::new();
    let document = engine
        .open_document(path.display().to_string(), None)
        .expect("open document");
    (engine, document)
}

fn citations(
    document: &LyraReaderDocument,
) -> BTreeMap<u32, Vec<lyra_reader_ffi::api::CitationRecord>> {
    let mut all = BTreeMap::new();
    for page in 0..document.page_count() {
        all.insert(page, document.citations(page).expect("citations"));
    }
    all
}

#[test]
fn stepped_index_scans_match_the_monolithic_results() {
    if !cache_test::isolated("stepped_index_scans_match_the_monolithic_results") {
        return;
    }
    if !lyra_reader_pdfium::is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }

    // One single-page reference fixture (non-empty reference list and citation spans) and one
    // three-page fixture (a scan that must actually bisect into several steps).
    for name in ["two-column-references.pdf", "multipage.pdf"] {
        let whole_path = copy_fixture("whole", name);
        let stepped_path = copy_fixture("stepped", name);
        let (_whole_engine, whole) = open(&whole_path);
        let (_stepped_engine, stepped) = open(&stepped_path);

        let whole_references = whole.references().expect("monolithic references");
        let whole_figures = whole.figures().expect("monolithic figures");
        let whole_citations = citations(&whole);
        let whole_annotations = whole.annotations().expect("monolithic annotations");

        // Interleave the two stepped scans the way the shell does: one bounded step of each,
        // then check that each one eventually completes and that the final data is identical.
        let mut reference_steps = 0;
        let mut figure_steps = 0;
        let mut references_done = false;
        let mut figures_done = false;
        let mut stepped_references = Vec::new();
        let mut stepped_figures = Vec::new();
        while !(references_done && figures_done) {
            if !references_done {
                let progress = stepped.references_scan_step(1, 2).expect("reference step");
                reference_steps += 1;
                references_done = progress.done;
                if progress.done {
                    stepped_references = progress.records;
                }
            }
            if !figures_done {
                let progress = stepped.figures_scan_step(1).expect("figure step");
                figure_steps += 1;
                figures_done = progress.done;
                if progress.done {
                    stepped_figures = progress.records;
                }
            }
            assert!(
                reference_steps + figure_steps < 10_000,
                "a stepped scan stopped making progress"
            );
        }

        assert!(
            reference_steps > 1,
            "{name}: reference scan did not bisect ({reference_steps} step(s))"
        );
        if stepped.page_count() > 1 {
            assert!(
                figure_steps > 1,
                "{name}: figure scan did not bisect ({figure_steps} steps)"
            );
        }
        assert_eq!(
            stepped_references, whole_references,
            "{name}: reference records"
        );
        assert_eq!(stepped_figures, whole_figures, "{name}: figure records");
        // The annotation scan is deliberately still monolithic: its records are visible marks,
        // and the shell keeps them ready for the first sharp frame. This proves the stepped
        // reference/figure scans did not disturb that path.
        // `AnnotationRecord` has no `PartialEq` (many presentation-only fields); Debug is the
        // exact field-by-field rendering of the same record type.
        assert_eq!(
            format!("{:?}", stepped.annotations().expect("stepped annotations")),
            format!("{whole_annotations:?}"),
            "{name}: annotation records"
        );
        assert_eq!(
            citations(&stepped),
            whole_citations,
            "{name}: citation spans per page"
        );

        // A completed stepped scan must have filled the same caches the monolithic path filled:
        // a second call on either document returns the data without rebuilding.
        assert_eq!(
            stepped.references().expect("cached references"),
            whole_references,
            "{name}: cached reference records"
        );
        assert_eq!(
            stepped.figures().expect("cached figures"),
            whole_figures,
            "{name}: cached figure records"
        );
        assert_eq!(
            format!("{:?}", stepped.annotations().expect("cached annotations")),
            format!("{whole_annotations:?}"),
            "{name}: cached annotation records"
        );

        let _ = fs::remove_dir_all(whole_path.parent().expect("whole parent"));
        let _ = fs::remove_dir_all(stepped_path.parent().expect("stepped parent"));
    }
}

//! Frozen table for the one copy-name rule (audit C10).
//!
//! The expected strings were recorded from the five existing callers before the shared helper
//! existed: `writeback::suggested_copy_path`, `redaction::suggested_redaction_copy_path`,
//! `forms::suggested_filled_copy_path`, `flatten::suggested_flatten_copy_path` and
//! `document_properties::suggested_properties_copy_path`. They must stay byte-identical: the
//! same suggested names must reach the save panels.
//!
//! The rows cover a normal name, no extension, a dotfile, multiple dots, spaces, non-ASCII, a
//! name already in parentheses, another extension, an uppercase extension, a short extension,
//! a directory, an absolute path, a trailing dot, a trailing slash, an empty path and `.`.
//! Redaction is the only caller that forces `.pdf`; every other caller preserves the source
//! extension (falling back to `pdf`).

use lyra_reader_pdfium::{
    suggested_copy_path, suggested_filled_copy_path, suggested_flatten_copy_path,
    suggested_properties_copy_path, suggested_redaction_copy_path,
};
use std::path::{Path, PathBuf};

struct Case {
    source: &'static str,
    annotated: &'static str,
    redacted: &'static str,
    filled: &'static str,
    flattened: &'static str,
    properties: &'static str,
}

const CASES: &[Case] = &[
    Case {
        source: "paper.pdf",
        annotated: "paper (annotated).pdf",
        redacted: "paper (redacted).pdf",
        filled: "paper (filled).pdf",
        flattened: "paper (flattened).pdf",
        properties: "paper (properties).pdf",
    },
    Case {
        source: "paper",
        annotated: "paper (annotated).pdf",
        redacted: "paper (redacted).pdf",
        filled: "paper (filled).pdf",
        flattened: "paper (flattened).pdf",
        properties: "paper (properties).pdf",
    },
    Case {
        source: ".pdf",
        annotated: ".pdf (annotated).pdf",
        redacted: ".pdf (redacted).pdf",
        filled: ".pdf (filled).pdf",
        flattened: ".pdf (flattened).pdf",
        properties: ".pdf (properties).pdf",
    },
    Case {
        source: "paper.v2.pdf",
        annotated: "paper.v2 (annotated).pdf",
        redacted: "paper.v2 (redacted).pdf",
        filled: "paper.v2 (filled).pdf",
        flattened: "paper.v2 (flattened).pdf",
        properties: "paper.v2 (properties).pdf",
    },
    Case {
        source: "my paper.pdf",
        annotated: "my paper (annotated).pdf",
        redacted: "my paper (redacted).pdf",
        filled: "my paper (filled).pdf",
        flattened: "my paper (flattened).pdf",
        properties: "my paper (properties).pdf",
    },
    Case {
        source: "论文.pdf",
        annotated: "论文 (annotated).pdf",
        redacted: "论文 (redacted).pdf",
        filled: "论文 (filled).pdf",
        flattened: "论文 (flattened).pdf",
        properties: "论文 (properties).pdf",
    },
    Case {
        source: "paper (draft).pdf",
        annotated: "paper (draft) (annotated).pdf",
        redacted: "paper (draft) (redacted).pdf",
        filled: "paper (draft) (filled).pdf",
        flattened: "paper (draft) (flattened).pdf",
        properties: "paper (draft) (properties).pdf",
    },
    Case {
        source: "archive.tar.gz",
        annotated: "archive.tar (annotated).gz",
        redacted: "archive.tar (redacted).pdf",
        filled: "archive.tar (filled).gz",
        flattened: "archive.tar (flattened).gz",
        properties: "archive.tar (properties).gz",
    },
    Case {
        source: "paper.PDF",
        annotated: "paper (annotated).PDF",
        redacted: "paper (redacted).pdf",
        filled: "paper (filled).PDF",
        flattened: "paper (flattened).PDF",
        properties: "paper (properties).PDF",
    },
    Case {
        source: "a.b",
        annotated: "a (annotated).b",
        redacted: "a (redacted).pdf",
        filled: "a (filled).b",
        flattened: "a (flattened).b",
        properties: "a (properties).b",
    },
    Case {
        source: "dir/with space/paper.pdf",
        annotated: "dir/with space/paper (annotated).pdf",
        redacted: "dir/with space/paper (redacted).pdf",
        filled: "dir/with space/paper (filled).pdf",
        flattened: "dir/with space/paper (flattened).pdf",
        properties: "dir/with space/paper (properties).pdf",
    },
    Case {
        source: "/tmp/paper.pdf",
        annotated: "/tmp/paper (annotated).pdf",
        redacted: "/tmp/paper (redacted).pdf",
        filled: "/tmp/paper (filled).pdf",
        flattened: "/tmp/paper (flattened).pdf",
        properties: "/tmp/paper (properties).pdf",
    },
    Case {
        source: "paper.",
        annotated: "paper (annotated).",
        redacted: "paper (redacted).pdf",
        filled: "paper (filled).",
        flattened: "paper (flattened).",
        properties: "paper (properties).",
    },
    Case {
        source: "dir/",
        annotated: "dir (annotated).pdf",
        redacted: "dir (redacted).pdf",
        filled: "dir (filled).pdf",
        flattened: "dir (flattened).pdf",
        properties: "dir (properties).pdf",
    },
    Case {
        source: "",
        annotated: "document (annotated).pdf",
        redacted: "document (redacted).pdf",
        filled: "document (filled).pdf",
        flattened: "document (flattened).pdf",
        properties: "document (properties).pdf",
    },
    Case {
        source: ".",
        annotated: "./document (annotated).pdf",
        redacted: "./document (redacted).pdf",
        filled: "./document (filled).pdf",
        flattened: "./document (flattened).pdf",
        properties: "./document (properties).pdf",
    },
];

fn assert_case(case: &Case) {
    let source = Path::new(case.source);
    assert_eq!(
        suggested_copy_path(source),
        PathBuf::from(case.annotated),
        "annotated copy of {:?}",
        case.source
    );
    assert_eq!(
        suggested_redaction_copy_path(source),
        PathBuf::from(case.redacted),
        "redacted copy of {:?}",
        case.source
    );
    assert_eq!(
        suggested_filled_copy_path(source),
        PathBuf::from(case.filled),
        "filled copy of {:?}",
        case.source
    );
    assert_eq!(
        suggested_flatten_copy_path(source),
        PathBuf::from(case.flattened),
        "flattened copy of {:?}",
        case.source
    );
    assert_eq!(
        suggested_properties_copy_path(source),
        PathBuf::from(case.properties),
        "properties copy of {:?}",
        case.source
    );
}

#[test]
fn every_caller_keeps_the_frozen_names() {
    for case in CASES {
        assert_case(case);
    }
}

#[cfg(unix)]
#[test]
fn non_utf8_names_keep_the_lossy_spelling() {
    use std::ffi::OsString;
    use std::os::unix::ffi::{OsStrExt, OsStringExt};

    let source = PathBuf::from(OsString::from_vec(b"bad\xFFname.pdf".to_vec()));
    assert_eq!(
        suggested_copy_path(&source).as_os_str().as_bytes(),
        b"bad\xEF\xBF\xBDname (annotated).pdf"
    );
    assert_eq!(
        suggested_redaction_copy_path(&source)
            .as_os_str()
            .as_bytes(),
        b"bad\xEF\xBF\xBDname (redacted).pdf"
    );
    assert_eq!(
        suggested_filled_copy_path(&source).as_os_str().as_bytes(),
        b"bad\xEF\xBF\xBDname (filled).pdf"
    );
    assert_eq!(
        suggested_flatten_copy_path(&source).as_os_str().as_bytes(),
        b"bad\xEF\xBF\xBDname (flattened).pdf"
    );
    assert_eq!(
        suggested_properties_copy_path(&source)
            .as_os_str()
            .as_bytes(),
        b"bad\xEF\xBF\xBDname (properties).pdf"
    );

    let source = PathBuf::from(OsString::from_vec(b"paper.\xFF".to_vec()));
    assert_eq!(
        suggested_copy_path(&source).as_os_str().as_bytes(),
        b"paper (annotated).\xEF\xBF\xBD"
    );
    assert_eq!(
        suggested_redaction_copy_path(&source)
            .as_os_str()
            .as_bytes(),
        b"paper (redacted).pdf"
    );
    assert_eq!(
        suggested_filled_copy_path(&source).as_os_str().as_bytes(),
        b"paper (filled).\xEF\xBF\xBD"
    );
    assert_eq!(
        suggested_flatten_copy_path(&source).as_os_str().as_bytes(),
        b"paper (flattened).\xEF\xBF\xBD"
    );
    assert_eq!(
        suggested_properties_copy_path(&source)
            .as_os_str()
            .as_bytes(),
        b"paper (properties).\xEF\xBF\xBD"
    );
}

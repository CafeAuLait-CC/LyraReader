//! The one rule for the name a saved copy is offered as.
//!
//! Every writer that offers a copy in a save panel uses
//! [`suggest_copy_path`], so the stem, the suffix spelling, the extension fallback and the
//! treatment of unusual file names cannot drift between annotated, redacted, filled, flattened
//! and properties copies.
//!
//! # The rule
//!
//! The suggested path is `<stem> (<suffix>).<extension>` beside the source:
//!
//! * `<stem>` is the source's file stem, with any inner dots kept (`paper.v2.pdf` becomes
//!   `paper.v2 (annotated).pdf`). A source with no file name uses `document`.
//! * `<suffix>` is inserted verbatim inside one pair of parentheses. A suffix that already
//!   contains parentheses keeps them, so the result is `paper (draft (revised)).pdf`; no caller
//!   passes such a suffix today, but the spelling is part of the frozen contract.
//! * `<extension>` is either the source's extension (preserved) or always `pdf`, chosen by the
//!   caller. A source with no extension gets `pdf`. A hidden name such as `.pdf` is a stem, not
//!   an extension, so it becomes `.pdf (annotated).pdf`.
//! * Non-UTF-8 file names go through `to_string_lossy`, exactly as every caller did before this
//!   helper existed.
//!
//! The redaction writer is the one caller whose rule genuinely differs: it always produces a
//! PDF, so it forces `pdf` instead of preserving the source's extension. That difference is a
//! parameter ([`CopyPathExtension::Pdf`]), not a second helper.

use std::path::{Path, PathBuf};

/// How a suggested copy keeps the source's extension.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CopyPathExtension {
    /// Keep the source's extension; a source with none gets `pdf`.
    Preserve,
    /// Always use `pdf`, even when the source has a different extension.
    Pdf,
}

/// The name to offer for a copy of `source`: `<stem> (<suffix>).<extension>`.
///
/// See the [module docs](self) for the stem, suffix and extension rules. This is the only
/// implementation of them; the `suggested_*_copy_path` functions are thin per-writer wrappers.
pub fn suggest_copy_path(source: &Path, suffix: &str, extension: CopyPathExtension) -> PathBuf {
    let stem = source
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| "document".to_string());
    let extension = match extension {
        CopyPathExtension::Preserve => source
            .extension()
            .map(|extension| extension.to_string_lossy().into_owned())
            .unwrap_or_else(|| "pdf".to_string()),
        CopyPathExtension::Pdf => "pdf".to_string(),
    };
    source.with_file_name(format!("{stem} ({suffix}).{extension}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suffix_parentheses_are_kept_inside_the_one_pair_the_rule_adds() {
        assert_eq!(
            suggest_copy_path(
                Path::new("paper.pdf"),
                "draft (revised)",
                CopyPathExtension::Preserve
            ),
            PathBuf::from("paper (draft (revised)).pdf")
        );
    }

    #[test]
    fn forced_pdf_ignores_the_source_extension() {
        assert_eq!(
            suggest_copy_path(
                Path::new("archive.tar.gz"),
                "redacted",
                CopyPathExtension::Pdf
            ),
            PathBuf::from("archive.tar (redacted).pdf")
        );
        assert_eq!(
            suggest_copy_path(Path::new("paper.PDF"), "redacted", CopyPathExtension::Pdf),
            PathBuf::from("paper (redacted).pdf")
        );
    }
}

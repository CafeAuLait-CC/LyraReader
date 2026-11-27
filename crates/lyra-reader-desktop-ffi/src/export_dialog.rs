//! Save-panel defaults over the existing copy-name rules and the original reader identity.
use serde::Deserialize;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

#[derive(Deserialize)]
#[serde(rename_all = "kebab-case")]
enum Kind {
    Document,
    Annotations,
    Forms,
    Flattened,
    Properties,
    Pages,
    Extract,
    Redactions,
    AnnotationText,
    Markdown,
    Csv,
    Bibtex,
}

#[derive(Deserialize)]
struct Request {
    kind: Kind,
    #[serde(default)]
    bibtex: String,
    page_edits: bool,
    #[serde(default)]
    pages: Vec<u32>,
}

pub(super) fn suggestion(source: &Path, request: &Value) -> Result<Value, String> {
    use lyra_reader_pdfium::{CopyPathExtension, suggest_copy_path};
    let request: Request = serde_json::from_value(request.clone())
        .map_err(|e| format!("Invalid save-panel request: {e}"))?;
    let copy = |suffix: &str| suggest_copy_path(source, suffix, CopyPathExtension::Preserve);
    let text_copy = |extension| copy("annotations").with_extension(extension);
    let path: PathBuf = match request.kind {
        Kind::Document if request.page_edits => copy("page edits"),
        Kind::Document | Kind::Annotations => lyra_reader_pdfium::suggested_copy_path(source),
        Kind::Forms => lyra_reader_pdfium::suggested_filled_copy_path(source),
        Kind::Flattened => lyra_reader_pdfium::suggested_flatten_copy_path(source),
        Kind::Properties => lyra_reader_pdfium::suggested_properties_copy_path(source),
        Kind::Pages => copy("page edits"),
        Kind::Extract => {
            if request.pages.is_empty() || request.pages.contains(&u32::MAX) {
                return Err("Select valid pages before exporting them".into());
            }
            copy(&format!(
                "pages {}",
                lyra_reader_ffi::api::page_list(request.pages)
            ))
            .with_extension("pdf")
        }
        Kind::Redactions => lyra_reader_pdfium::suggested_redaction_copy_path(source),
        Kind::AnnotationText | Kind::Markdown => text_copy("md"),
        Kind::Csv => text_copy("csv"),
        Kind::Bibtex => {
            // Match the macOS save panel's generated-entry key, never a path from its text.
            let key = request.bibtex.lines().next().and_then(|line| {
                let (_, rest) = line.split_once('{')?;
                let (key, _) = rest.split_once(',')?;
                let key = key.trim();
                (!key.is_empty()).then_some(key)
            });
            let safe: String = key
                .unwrap_or("reference")
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
                .collect();
            source.with_file_name(format!("{safe}.bib"))
        }
    };
    Ok(
        json!({"path":path,"folder":source.parent().unwrap_or(Path::new(".")),"markdown":text_copy("md"),"csv":text_copy("csv")}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn save_panel_defaults_keep_the_original_folder_and_shared_copy_spelling() {
        for (kind, suffix) in [
            ("annotations", "annotated"),
            ("forms", "filled"),
            ("flattened", "flattened"),
            ("properties", "properties"),
            ("pages", "page edits"),
        ] {
            let value = suggestion(
                Path::new("folder/论文.v2.PDF"),
                &json!({"kind":kind,"page_edits":false}),
            )
            .unwrap();
            assert_eq!(value["path"], format!("folder/论文.v2 ({suffix}).PDF"));
        }
        assert_eq!(
            suggestion(
                Path::new("folder/paper.PDF"),
                &json!({"kind":"extract","page_edits":true,"pages":[0,1]})
            )
            .unwrap()["path"],
            "folder/paper (pages pages 1–2).pdf"
        );
        assert!(
            suggestion(
                Path::new("paper.pdf"),
                &json!({"kind":"extract","page_edits":false})
            )
            .is_err()
        );
        for (edited, suffix) in [(false, "annotated"), (true, "page edits")] {
            assert_eq!(
                suggestion(
                    Path::new("folder/paper.pdf"),
                    &json!({"kind":"document","page_edits":edited})
                )
                .unwrap()["path"],
                format!("folder/paper ({suffix}).pdf")
            );
        }
    }

    #[test]
    fn text_formats_keep_one_stem_and_bibtex_keys_cannot_escape_the_folder() {
        let source = Path::new("folder/paper.v2.pdf");
        let value = suggestion(
            source,
            &json!({"kind":"annotation-text","page_edits":false}),
        )
        .unwrap();
        assert_eq!(value["path"], "folder/paper.v2 (annotations).md");
        assert_eq!(value["csv"], "folder/paper.v2 (annotations).csv");
        for (text, name) in [
            ("@article{Smith2026Paper,\n title={A}", "Smith2026Paper.bib"),
            ("@misc{ ../../bad:key,", "______bad_key.bib"),
            ("not an entry", "reference.bib"),
            ("@misc{ ,", "reference.bib"),
        ] {
            let value = suggestion(
                source,
                &json!({"kind":"bibtex","page_edits":false,"bibtex":text}),
            )
            .unwrap();
            assert_eq!(
                Path::new(value["path"].as_str().unwrap()),
                source.with_file_name(name)
            );
        }
        assert!(suggestion(source, &json!({"kind":"unknown","page_edits":false})).is_err());
        assert!(suggestion(source, &json!({"kind":"document"})).is_err());
    }
}

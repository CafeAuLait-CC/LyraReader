//! Native export plans and annotation materialization for the shared merge/split writers.
use crate::document::DesktopDocument;
use lyra_reader_ffi::api::*;
use serde_json::{Value, json};
use std::{collections::HashSet, fs, path::Path, sync::Arc};

struct ExportSource {
    // Fields drop in this order: close the PDF before removing its private directory.
    document: Arc<LyraReaderDocument>,
    _directory: Option<Arc<crate::pages::SessionDirectory>>,
}

fn materialize(
    source: &Arc<LyraReaderDocument>,
    marks: &crate::marks::Marks,
) -> Result<ExportSource, String> {
    let payload = marks.payload(source)?;
    if payload.annotations.is_empty()
        && payload.bookmarks.is_empty()
        && payload.updates.is_empty()
        && payload.deletions.is_empty()
    {
        return Ok(ExportSource {
            document: Arc::clone(source),
            _directory: None,
        });
    }
    let path = marks
        .cache_root()
        .ok_or("The document cache is unavailable")?
        .join(format!("export-{}", crate::marks::uuid()?));
    let mut options = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        options.mode(0o700);
    }
    options.create(&path).map_err(|e| e.to_string())?;
    let directory = Arc::new(crate::pages::SessionDirectory(path));
    let destination = directory
        .0
        .join("materialized.pdf")
        .to_string_lossy()
        .into_owned();
    source
        .save_annotation_changes_copy(
            destination.clone(),
            payload.annotations,
            payload.bookmarks,
            payload.updates,
            payload.deletions,
        )
        .map_err(|e| e.to_string())?;
    let document = LyraReaderEngine::new()
        .open_document(destination, None)
        .map_err(|e| e.to_string())?;
    Ok(ExportSource {
        document,
        _directory: Some(directory),
    })
}

fn groups(request: &Value, count: u32) -> Result<Vec<Vec<u32>>, String> {
    if count == 0 {
        return Err("The document has no pages to split".into());
    }
    if request["mode"] == "chunks" {
        let every = request["every"]
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .filter(|n| *n > 0)
            .ok_or("Split every N pages needs a positive whole number")?;
        return Ok((0..count)
            .step_by(every as usize)
            .map(|start| (start..start.saturating_add(every).min(count)).collect())
            .collect());
    }
    let text = request["ranges"]
        .as_str()
        .ok_or("Type page ranges, for example 1-5, 6-10")?
        .replace(['–', '—'], "-");
    let mut result = Vec::new();
    let mut seen = HashSet::new();
    for token in text.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        let parts: Vec<_> = token.split('-').map(str::trim).collect();
        if !(1..=2).contains(&parts.len()) {
            return Err(format!("“{token}” is not a page or range"));
        }
        let page = |text: &str| {
            text.parse::<u32>()
                .ok()
                .filter(|n| *n >= 1 && *n <= count)
                .ok_or_else(|| format!("“{token}” is outside pages 1–{count}"))
        };
        let start = page(parts[0])?;
        let end = page(parts.last().unwrap())?;
        if start > end {
            return Err(format!(
                "“{token}” runs backwards; put the smaller page first"
            ));
        }
        let pages: Vec<_> = ((start - 1)..end).collect();
        for &p in &pages {
            if !seen.insert(p) {
                return Err(format!("Page {} occurs in more than one output", p + 1));
            }
        }
        result.push(pages);
    }
    if result.is_empty() {
        return Err("Type at least one page or range".into());
    }
    result.sort_by_key(|pages| pages[0]);
    Ok(result)
}
fn new_destination(path: &Path) -> Result<(), String> {
    if path.exists() {
        return Err(format!(
            "{} already exists; choose a new destination",
            path.display()
        ));
    }
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    if !parent.is_dir() {
        return Err(format!(
            "{} is not an existing output folder",
            parent.display()
        ));
    }
    Ok(())
}
fn parts(request: &Value) -> Result<Vec<SplitPartRecord>, String> {
    serde_json::from_value(request["parts"].clone()).map_err(|e| e.to_string())
}
impl DesktopDocument {
    pub(super) fn export_command(&self, op: &str, r: &Value) -> Result<Value, String> {
        let _edits = self
            .edits
            .lock()
            .map_err(|_| "Page-edit state is unavailable")?;
        let source = self.active()?;
        if op == "split_plan" {
            let ranges = groups(r, source.page_count())?;
            let directory = r["directory"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(Path::new)
                .unwrap_or_else(|| self.original_path.parent().unwrap_or(Path::new(".")));
            if !directory.is_dir() {
                return Err("Choose an existing output folder".into());
            }
            let stem = self
                .original_path
                .file_stem()
                .ok_or("Missing source filename")?
                .to_string_lossy();
            let mut conflicts = Vec::new();
            let planned: Vec<_> = ranges
                .into_iter()
                .map(|pages| {
                    let label = if pages.len() == 1 {
                        format!("{}", pages[0] + 1)
                    } else {
                        format!("{}-{}", pages[0] + 1, pages.last().unwrap() + 1)
                    };
                    let noun = if pages.len() == 1 { "page" } else { "pages" };
                    let path = directory.join(format!("{stem} ({noun} {label}).pdf"));
                    if path.exists() {
                        conflicts.push(path.to_string_lossy().into_owned());
                    }
                    SplitPartRecord {
                        destination_path: path.to_string_lossy().into_owned(),
                        pages,
                    }
                })
                .collect();
            return Ok(json!({"parts":planned,"conflicts":conflicts}));
        }
        let marks = self
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")?;
        marks.validate_export(op == "save_split")?;
        // Exported marks must travel inside the PDF, including when the recipient has
        // no access to this application's cache. The original remains untouched.
        let materialized = materialize(&source, &marks)?;
        let writer = &materialized.document;
        if op == "save_merge" {
            let destination = r["destination"]
                .as_str()
                .ok_or("Choose a merge destination")?;
            let path = Path::new(destination);
            new_destination(path)?;
            let others: Vec<String> =
                serde_json::from_value(r["others"].clone()).map_err(|e| e.to_string())?;
            let report = writer
                .merge_documents(others, destination.to_string())
                .map_err(|e| e.to_string())?;
            let sidecar = (|| {
                let next = LyraReaderEngine::new()
                    .open_document(destination.to_string(), None)
                    .map_err(|e| e.to_string())?;
                marks.appended_copy(path, &source, &next).map(|_| ())
            })();
            if let Err(error) = sidecar {
                let _ = fs::remove_file(path);
                return Err(format!(
                    "Could not carry the source annotations into the merged file: {error}"
                ));
            }
            return serde_json::to_value(report).map_err(|e| e.to_string());
        }
        let parts = parts(r)?;
        if parts.is_empty() {
            return Err("Choose at least one split output".into());
        }
        let mut pages = HashSet::new();
        let mut paths = HashSet::new();
        for part in &parts {
            new_destination(Path::new(&part.destination_path))?;
            let path = Path::new(&part.destination_path);
            let resolved = fs::canonicalize(path.parent().unwrap_or(Path::new(".")))
                .map_err(|e| e.to_string())?
                .join(path.file_name().ok_or("Missing output filename")?);
            if !paths.insert(resolved) {
                return Err("Two split outputs use the same destination".into());
            }
            if part.pages.is_empty() {
                return Err("A split range is empty".into());
            }
            for &page in &part.pages {
                if page >= source.page_count() || !pages.insert(page) {
                    return Err("Split pages must be in range and disjoint".into());
                }
            }
        }
        let result = if source.signature_status().signed {
            // Finalize each signed derivative through the shared sanitizer before
            // starting the next output, so a later failure cannot leave an earlier
            // file carrying signature material that no longer covers its bytes.
            let mut report = SplitReportRecord {
                parts: vec![],
                source_page_count: source.page_count(),
                cleaned_temporary_files: 0,
            };
            let mut error = None;
            for part in &parts {
                match writer.split_pages(vec![part.clone()]) {
                    Ok(next) => {
                        report.parts.extend(next.parts);
                        report.cleaned_temporary_files += next.cleaned_temporary_files;
                    }
                    Err(failure) => {
                        error = Some(failure);
                        break;
                    }
                }
            }
            error.map_or(Ok(report), Err)
        } else {
            writer.split_pages(parts.clone())
        };
        let mut written = 0;
        let mut sidecar_errors = Vec::new();
        // The shared writer leaves earlier verified outputs complete on a later failure.
        // Carry marks into every completed output, even on that partial-result path.
        for part in &parts {
            let path = Path::new(&part.destination_path);
            if !path.exists() {
                continue;
            }
            written += 1;
            let sidecar = (|| {
                let next = LyraReaderEngine::new()
                    .open_document(part.destination_path.clone(), None)
                    .map_err(|e| e.to_string())?;
                if next.page_count() != part.pages.len() as u32 {
                    return Err("The completed output has an unexpected page count".into());
                }
                let mut map = vec![None; source.page_count() as usize];
                let mut ordered = part.pages.clone();
                ordered.sort_unstable();
                for (new, &old) in ordered.iter().enumerate() {
                    map[old as usize] = Some(new as u32);
                }
                marks.staging_copy(path, &map, &source, &next).map(|_| ())
            })();
            if let Err(error) = sidecar {
                sidecar_errors.push(format!("{}: {error}", part.destination_path));
            }
        }
        if !sidecar_errors.is_empty() {
            return Err(format!(
                "{written} PDF outputs were written, but some annotation sidecars failed: {}",
                sidecar_errors.join("; ")
            ));
        }
        serde_json::to_value(
            result.map_err(|e| format!("Split stopped after {written} completed outputs: {e}"))?,
        )
        .map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn range_plans_are_disjoint_sorted_and_bounded_before_writing() {
        assert_eq!(
            groups(&json!({"ranges":" 7, 1–3, 4—6 "}), 8).unwrap(),
            vec![vec![0, 1, 2], vec![3, 4, 5], vec![6]]
        );
        assert_eq!(
            groups(&json!({"mode":"chunks","every":3}), 7).unwrap(),
            vec![vec![0, 1, 2], vec![3, 4, 5], vec![6]]
        );
        for text in ["", "1-3,3-4", "4-1", "0", "9", "1-2-3", "x"] {
            assert!(groups(&json!({"ranges":text}), 8).is_err(), "{text}");
        }
        assert!(groups(&json!({"mode":"chunks","every":0}), 8).is_err());
    }
}

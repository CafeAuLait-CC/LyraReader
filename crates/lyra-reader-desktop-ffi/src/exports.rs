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
    if payload.is_empty() {
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
    let directory = Arc::new(crate::pages::SessionDirectory::temporary(path));
    let destination = directory
        .path
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

// Asset publication must not use the cache writer, which makes its parent private.
// The native save panel owns destination selection; the document command has already
// rejected the original PDF and XFA writes before reaching this adapter.
pub(super) fn save_content_image(
    document: &LyraReaderDocument,
    request: &Value,
) -> Result<Value, String> {
    let page: u32 = serde_json::from_value(request["page"].clone())
        .map_err(|e| format!("Invalid image page: {e}"))?;
    let string = |key: &str| {
        request[key]
            .as_str()
            .ok_or_else(|| format!("Missing image {key}"))
    };
    let destination = Path::new(string("destination")?);
    if !destination
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("png"))
    {
        return Err("Choose a PNG file name for the exported image.".into());
    }
    if destination.exists()
        && fs::canonicalize(destination).map_err(|e| e.to_string())?
            == fs::canonicalize(document.path()).map_err(|e| e.to_string())?
    {
        return Err("An image export cannot overwrite the active PDF revision.".into());
    }
    let png = document
        .content_image_png(page, string("target")?.into(), string("revision")?.into())
        .map_err(|e| e.to_string())?;
    if !png.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err("The image engine did not return a PNG.".into());
    }
    let warning = publish_image_asset(destination, &png)?;
    Ok(json!({"destination_path":destination,"bytes":png.len(),"publication_warning":warning}))
}

fn publish_image_asset(destination: &Path, bytes: &[u8]) -> Result<Option<String>, String> {
    use std::io::{Read, Write};
    let parent = destination
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let temporary = parent.join(format!(".lyra-image-{}.tmp", crate::marks::uuid()?));
    let mut created = false;
    let result = (|| {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary).map_err(|e| e.to_string())?;
        created = true;
        file.write_all(bytes)
            .and_then(|()| file.flush())
            .and_then(|()| file.sync_all())
            .map_err(|e| e.to_string())?;
        drop(file);
        let mut verify = fs::File::open(&temporary).map_err(|e| e.to_string())?;
        let mut block = [0u8; 8192];
        let mut offset = 0usize;
        loop {
            let count = verify.read(&mut block).map_err(|e| e.to_string())?;
            if count == 0 {
                break;
            }
            let end = offset
                .checked_add(count)
                .ok_or("Image verification size overflow")?;
            if bytes.get(offset..end) != Some(&block[..count]) {
                return Err("Image export verification failed".into());
            }
            offset = end;
        }
        if offset != bytes.len() {
            return Err("Image export verification was truncated".into());
        }
        drop(verify);
        fs::rename(&temporary, destination).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            // Publication succeeded. Report a directory durability failure as a warning,
            // rather than claiming the already exported PNG was not written.
            if let Err(error) = fs::File::open(parent).and_then(|f| f.sync_all()) {
                return Ok(Some(format!(
                    "Image saved, but directory synchronization failed: {error}"
                )));
            }
        }
        Ok(None)
    })();
    if let Err(original) = &result
        && created
        && let Err(error) = fs::remove_file(&temporary)
    {
        return Err(format!(
            "{original}; Temporary image cleanup failed: {error}"
        ));
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[cfg(unix)]
    fn image_publication_reports_directory_sync_failure_after_successful_rename() {
        use std::os::unix::fs::PermissionsExt;
        let parent =
            std::env::temp_dir().join(format!("lyra-image-sync-{}", crate::marks::uuid().unwrap()));
        fs::create_dir(&parent).unwrap();
        let destination = parent.join("output.png");
        // Write/search permission permits create/rename, while directory read permission
        // is withheld specifically to fail the post-publication File::open for sync.
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o300)).unwrap();
        let permission_failure = fs::File::open(&parent).is_err();
        let result = publish_image_asset(&destination, b"Synthetic exported bytes");
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o700)).unwrap();
        let written = fs::read(&destination);
        let count = fs::read_dir(&parent).unwrap().count();
        if destination.exists() {
            fs::remove_file(&destination).unwrap();
        }
        fs::remove_dir(&parent).unwrap();
        let warning = result.unwrap();
        assert_eq!(written.unwrap(), b"Synthetic exported bytes");
        assert_eq!(count, 1);
        if permission_failure {
            assert!(
                warning
                    .unwrap()
                    .contains("Image saved, but directory synchronization failed")
            );
            eprintln!(
                "Exercised post-publication directory permission failure; exported bytes remained available"
            );
        } else {
            eprintln!(
                "Notice: privileged filesystem access bypassed the directory permission failure; forced sync-failure assertion was not run"
            );
        }
    }

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

//! Host publication of an offline Markdown/PNG export. Never overwrites existing output.
use lyra_reader_ai::region_export::ExportDocument;
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

fn write_new(path: &Path, bytes: &[u8], owned: &mut Vec<PathBuf>) -> Result<(), String> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path).map_err(|e| e.to_string())?;
    owned.push(path.to_path_buf());
    file.write_all(bytes)
        .and_then(|()| file.flush())
        .and_then(|()| file.sync_all())
        .map_err(|e| e.to_string())?;
    drop(file);
    let mut file = fs::File::open(path).map_err(|e| e.to_string())?;
    let mut offset = 0usize;
    let mut block = [0u8; 8192];
    loop {
        let count = file.read(&mut block).map_err(|e| e.to_string())?;
        if count == 0 {
            break;
        }
        let end = offset
            .checked_add(count)
            .ok_or("Reading-note verification size overflow")?;
        if bytes.get(offset..end) != Some(&block[..count]) {
            return Err("Reading-note export verification failed".into());
        }
        offset = end;
    }
    if offset != bytes.len() {
        return Err("Reading-note export was truncated".into());
    }
    Ok(())
}

fn sync_directory(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        fs::File::open(path)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())?;
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    } // std does not expose a portable directory flush on Windows.
    Ok(())
}

/// Publish pictures first and the verified Markdown last, as one no-clobber hard link.
/// An incomplete export never replaces a prior document. A crash may leave an unreferenced
/// private image folder, but cannot publish Markdown referencing unfinished pictures.
pub(super) fn publish(
    destination: &Path,
    folder: &str,
    document: ExportDocument,
    before_publish: impl FnOnce() -> Result<(), String>,
) -> Result<Option<String>, String> {
    publish_with_sync(
        destination,
        folder,
        document,
        before_publish,
        sync_directory,
    )
}

fn publish_with_sync(
    destination: &Path,
    folder: &str,
    document: ExportDocument,
    before_publish: impl FnOnce() -> Result<(), String>,
    sync: impl Fn(&Path) -> Result<(), String>,
) -> Result<Option<String>, String> {
    if !destination.is_absolute()
        || !destination
            .extension()
            .and_then(|s| s.to_str())
            .is_some_and(|s| s.eq_ignore_ascii_case("md"))
        || folder.is_empty()
        || folder.len() > 80
        || !folder
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
        || matches!(folder, "." | "..")
    {
        return Err("Choose a new local .md file for Reading notes".into());
    }
    match fs::symlink_metadata(destination) {
        Ok(_) => return Err("The Markdown destination already exists. Choose a new filename; existing exports were kept".into()),
        Err(e) if e.kind()==std::io::ErrorKind::NotFound => {},
        Err(e) => return Err(e.to_string()),
    }
    let parent = destination
        .parent()
        .filter(|p| p.is_dir())
        .ok_or("Choose an existing output folder")?;
    let directory = parent.join(folder);
    let temporary = parent.join(format!(".lyra-notes-{}.tmp", crate::marks::uuid()?));
    let mut options = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        options.mode(0o700);
    }
    options.create(&directory).map_err(|e| {
        format!("Could not reserve the image folder. Choose a new export filename: {e}")
    })?;
    let mut owned = Vec::new();
    let mut published = false;
    let result = (|| {
        for image in &document.images {
            // Generated manifests are internal, but the I/O boundary still rejects paths.
            if !image.name.starts_with("region-")
                || !image.name.ends_with(".png")
                || !image
                    .name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-.".contains(&b))
            {
                return Err("Invalid reading-note image filename".into());
            }
            write_new(&directory.join(&image.name), &image.png, &mut owned)?;
        }
        sync(&directory)?;
        write_new(&temporary, document.markdown.as_bytes(), &mut owned)?;
        // Make the image-folder entry durable before the Markdown name can become visible.
        sync(parent)?;
        before_publish()?;
        // Unlike rename, hard_link atomically refuses even a concurrently created symlink/file.
        // Both names are in the chosen folder and therefore on the same filesystem.
        fs::hard_link(&temporary, destination).map_err(|e| {
            format!("Could not publish the new Markdown file without replacing existing data: {e}")
        })?;
        published = true;
        Ok(())
    })();
    let mut cleanup = Vec::new();
    for path in owned
        .iter()
        .rev()
        .filter(|path| !published || **path == temporary)
    {
        if let Err(e) = fs::remove_file(path) {
            cleanup.push(format!("Temporary export cleanup failed: {e}"));
        }
    }
    if !published && let Err(e) = fs::remove_dir(&directory) {
        cleanup.push(format!("Temporary image folder cleanup failed: {e}"));
    }
    if let Err(error) = result {
        return Err(if cleanup.is_empty() {
            error
        } else {
            format!("{error}; {}", cleanup.join("; "))
        });
    }
    if let Err(e) = sync(parent) {
        cleanup.push(format!(
            "Export saved, but output directory synchronization failed: {e}"
        ));
    }
    Ok((!cleanup.is_empty()).then(|| cleanup.join("; ")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use lyra_reader_ai::region_export::ExportImage;
    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "lyra-note-export-{}",
                crate::marks::uuid().unwrap()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn document() -> ExportDocument {
        ExportDocument {
            markdown: "![capture](notes-images/region-01.png)".into(),
            images: vec![ExportImage {
                name: "region-01.png".into(),
                png: b"frozen image bytes".to_vec(),
            }],
            omitted: 0,
        }
    }
    #[test]
    fn publishes_exact_assets_and_refuses_existing_outputs() {
        let dir = Scratch::new();
        let path = dir.0.join("notes.md");
        assert!(
            publish(&path, "notes-images", document(), || Ok(()))
                .unwrap()
                .is_none()
        );
        assert_eq!(fs::read(&path).unwrap(), document().markdown.as_bytes());
        assert_eq!(
            fs::read(dir.0.join("notes-images/region-01.png")).unwrap(),
            b"frozen image bytes"
        );
        assert!(publish(&path, "notes-images", document(), || Ok(())).is_err());
        assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 2);
        assert!(
            publish(
                &dir.0.join("another.md"),
                "notes-images",
                document(),
                || Ok(())
            )
            .is_err()
        );
        assert!(!dir.0.join("another.md").exists());
    }
    #[test]
    fn failures_remove_only_owned_files_and_keep_a_racing_destination() {
        let dir = Scratch::new();
        let path = dir.0.join("notes.md");
        assert!(
            publish(&path, "notes-images", document(), || Err(
                "snapshot changed".into()
            ))
            .is_err()
        );
        assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 0);
        assert!(
            publish(&path, "notes-images", document(), || {
                fs::write(&path, b"concurrent file").unwrap();
                Ok(())
            })
            .is_err()
        );
        assert_eq!(fs::read(&path).unwrap(), b"concurrent file");
        assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 1);
    }
    #[test]
    fn synchronization_failures_distinguish_unpublished_and_published_exports() {
        for failing_call in [2, 3] {
            let dir = Scratch::new();
            let path = dir.0.join("notes.md");
            let calls = std::cell::Cell::new(0);
            let result = publish_with_sync(
                &path,
                "notes-images",
                document(),
                || Ok(()),
                |_| {
                    calls.set(calls.get() + 1);
                    if calls.get() == failing_call {
                        Err("synthetic sync error".into())
                    } else {
                        Ok(())
                    }
                },
            );
            if failing_call == 2 {
                assert!(result.is_err());
                assert_eq!(fs::read_dir(&dir.0).unwrap().count(), 0);
            } else {
                assert!(result.unwrap().unwrap().contains("Export saved"));
                assert_eq!(fs::read(&path).unwrap(), document().markdown.as_bytes());
                assert_eq!(
                    fs::read(dir.0.join("notes-images/region-01.png")).unwrap(),
                    b"frozen image bytes"
                );
            }
        }
    }
    #[cfg(unix)]
    #[test]
    fn dangling_destination_symlinks_are_not_followed_or_replaced() {
        let dir = Scratch::new();
        let path = dir.0.join("notes.md");
        let missing = dir.0.join("missing");
        std::os::unix::fs::symlink(&missing, &path).unwrap();
        assert!(publish(&path, "notes-images", document(), || Ok(())).is_err());
        assert_eq!(fs::read_link(&path).unwrap(), missing);
        assert!(!missing.exists());
        assert!(!dir.0.join("notes-images").exists());
    }
}

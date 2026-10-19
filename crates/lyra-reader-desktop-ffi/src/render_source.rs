use crate::document::DesktopDocument;
use lyra_reader_core::{Rect, Size};
use lyra_reader_ffi::api::*;
use lyra_reader_runtime::{MAX_PAGE_BYTES, bounded_raster_scale};
use std::{fs, path::PathBuf, sync::Arc};

/// An immutable revision, independent of the active tab and its later page edits.
pub struct RenderSource {
    engine: Arc<LyraReaderDocument>,
    _temporary: Option<OwnedDirectory>,
}
struct OwnedDirectory(PathBuf);
impl Drop for OwnedDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
impl RenderSource {
    pub fn new(document: &DesktopDocument, include_edits: bool) -> Result<Self, String> {
        let _edits = document
            .edits
            .lock()
            .map_err(|_| "Page-edit state is unavailable")?;
        let engine = document.active()?;
        if !include_edits {
            return Ok(Self {
                engine,
                _temporary: None,
            });
        }
        let marks = document
            .marks
            .lock()
            .map_err(|_| "Annotation state is unavailable")?;
        let payload = marks.payload(&engine)?;
        if payload.annotations.is_empty()
            && payload.updates.is_empty()
            && payload.deletions.is_empty()
        {
            return Ok(Self {
                engine,
                _temporary: None,
            });
        }
        let directory =
            std::env::temp_dir().join(format!("LyraReaderPrint-{}", crate::marks::uuid()?));
        fs::create_dir(&directory).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
                .map_err(|e| e.to_string())?;
        }
        let path = directory.join("print.pdf");
        let prepared = (|| -> Result<Arc<LyraReaderDocument>, String> {
            engine
                .save_annotation_changes_copy(
                    path.to_string_lossy().into_owned(),
                    payload.annotations,
                    payload.bookmarks,
                    payload.updates,
                    payload.deletions,
                    1.0,
                )
                .map_err(|e| e.to_string())?;
            LyraReaderEngine::new()
                .open_document(
                    path.to_string_lossy().into_owned(),
                    document.password.clone(),
                )
                .map_err(|e| e.to_string())
        })();
        match prepared {
            Ok(engine) => Ok(Self {
                engine,
                _temporary: Some(OwnedDirectory(directory)),
            }),
            Err(error) => {
                let _ = fs::remove_dir_all(directory);
                Err(error)
            }
        }
    }
    pub fn render(
        &self,
        page: u32,
        scale: f64,
        region: Rect,
        annotated: bool,
        transparent: bool,
    ) -> Result<PageBitmap, String> {
        let scale = bounded_raster_scale(Size::new(region.size.width, region.size.height), scale)
            .map_err(|e| e.to_string())?;
        let image = if annotated {
            self.engine.rasterize_region_with_annotations(
                page,
                scale,
                region.origin.x,
                region.origin.y,
                region.size.width,
                region.size.height,
            )
        } else {
            self.engine.rasterize_region(
                page,
                scale,
                region.origin.x,
                region.origin.y,
                region.size.width,
                region.size.height,
                transparent,
            )
        }
        .map_err(|e| e.to_string())?;
        if image.pixels.len() > MAX_PAGE_BYTES {
            return Err("Crop exceeded its byte budget".into());
        }
        Ok(image)
    }
}

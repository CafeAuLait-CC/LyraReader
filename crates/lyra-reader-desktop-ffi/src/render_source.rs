use crate::document::DesktopDocument;
use lyra_reader_core::{Rect, Size};
use lyra_reader_ffi::api::*;
use lyra_reader_runtime::{MAX_PAGE_BYTES, bounded_raster_scale};
use lyra_reader_session::DocumentLayout;
use serde_json::{Value, json};
use std::{fs, path::PathBuf, sync::Arc};

/// An immutable revision, independent of the active tab and its later page edits.
pub struct RenderSource {
    engine: Arc<LyraReaderDocument>,
    layout: DocumentLayout,
    _temporary: Option<OwnedDirectory>,
    _session_directory: Option<crate::session::RevisionLease>,
}
struct OwnedDirectory(PathBuf);
impl Drop for OwnedDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
impl RenderSource {
    pub fn new(document: &DesktopDocument, include_edits: bool) -> Result<Self, String> {
        let edits = document
            .edits
            .lock()
            .map_err(|_| "Page-edit state is unavailable")?;
        let engine = document.active()?;
        let layout = document
            .layout
            .read()
            .map_err(|_| "Layout state is unavailable")?
            .clone();
        let session_directory = edits
            .directory
            .as_ref()
            .map(|d| d.lease(std::path::Path::new(&engine.path())))
            .transpose()?;
        if !include_edits {
            return Ok(Self {
                engine,
                layout,
                _temporary: None,
                _session_directory: session_directory,
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
                layout,
                _temporary: None,
                _session_directory: session_directory,
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
                layout,
                _temporary: Some(OwnedDirectory(directory)),
                _session_directory: session_directory,
            }),
            Err(error) => {
                let _ = fs::remove_dir_all(directory);
                Err(error)
            }
        }
    }
    pub fn query(&self, request: Value) -> Result<Value, String> {
        let page = || {
            request["page"]
                .as_u64()
                .and_then(|p| u32::try_from(p).ok())
                .ok_or("Missing page".to_string())
        };
        fn value<T: serde::Serialize>(
            result: Result<T, LyraReaderFfiError>,
        ) -> Result<Value, String> {
            serde_json::to_value(result.map_err(|e| e.to_string())?).map_err(|e| e.to_string())
        }
        match request["op"].as_str().unwrap_or("") {
            "info" => value(
                (0..self.engine.page_count())
                    .map(|p| self.engine.page_size_pt(p))
                    .collect::<Result<Vec<_>, _>>(),
            ),
            "layout" => crate::document::layout_value(&self.layout, &request),
            "outline" => value(self.engine.outline()),
            "text" => value(self.engine.text_page(page()?)),
            "page_targets" => Ok(
                json!({"links":self.engine.links(page()?).map_err(|e|e.to_string())?,"citations":self.engine.citations(page()?).map_err(|e|e.to_string())?,"mentions":self.engine.caption_mentions(page()?).map_err(|e|e.to_string())?}),
            ),
            "resolve_citations" => value(self.engine.resolve_citations_on(
                page()?,
                serde_json::from_value(request["labels"].clone()).map_err(|e| e.to_string())?,
            )),
            "references" => value(self.engine.references()),
            "figures" => value(self.engine.figures()),
            _ => Err("Unknown render snapshot query".into()),
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

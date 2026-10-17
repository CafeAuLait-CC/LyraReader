//! Ordinary Rust services shared by native shells. No Qt, Swift or generated FFI types.
//!
//! Calls can block on PDFium's process-wide lock: hosts must call `open` and `render_page`
//! on a worker. The backend already protects document operations and destruction.

use aris_reader_core::{
    ArisError, DocumentBackend, ErrorCode, OutlineNode, PageIndex, RasterRequest, RasterTile,
    Result, Size,
};
use aris_reader_pdfium::PdfiumBackend;
use aris_reader_session::{DocumentLayout, Zoom, resolve_zoom};
use std::path::Path;

/// A whole-page preview never exceeds this allocation. Deep-zoom tiles will refine it later.
pub const MAX_PAGE_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_PAGE_EDGE: f64 = 8192.0;
pub const PAGE_GAP_PT: f64 = 12.0;

pub struct Document {
    backend: PdfiumBackend,
    layout: DocumentLayout,
    outline: Vec<OutlineNode>,
}

pub struct PageRaster {
    pub tile: RasterTile,
    /// The real sampling density, which may be lower than requested for a large page.
    pub scale: f64,
}

impl Document {
    pub fn open(path: &Path, password: Option<&str>) -> Result<Self> {
        let backend = PdfiumBackend::open(path, password)?;
        if backend.page_count() == 0 {
            return Err(ArisError::new(
                ErrorCode::CorruptDocument,
                "PDF contains no pages",
            ));
        }
        let sizes = (0..backend.page_count())
            .map(|page| {
                let size = backend.page_info(PageIndex(page))?.geometry.view_size(1.0);
                validate_size(size)?;
                Ok((size.width, size.height))
            })
            .collect::<Result<Vec<_>>>()?;
        let outline = backend.outline()?;
        Ok(Self {
            backend,
            layout: DocumentLayout::new(sizes, PAGE_GAP_PT),
            outline,
        })
    }

    pub fn layout(&self) -> &DocumentLayout {
        &self.layout
    }
    pub fn outline(&self) -> &[OutlineNode] {
        &self.outline
    }

    pub fn render_page(&self, page: u32, scale: f64) -> Result<PageRaster> {
        let placement = self.layout.placement(page).ok_or_else(|| {
            ArisError::new(
                ErrorCode::InvalidArgument,
                "page index is outside the document",
            )
        })?;
        let scale =
            bounded_raster_scale(Size::new(placement.width_pt, placement.height_pt), scale)?;
        let mut request = RasterRequest::full_page(PageIndex(page), scale);
        // The prototype is read-only. Let PDFium draw embedded annotation appearances once;
        // editable overlays and the macOS drawn/skipped policy are a later milestone.
        request.flags.annotations = true;
        let tile = self.backend.rasterize(&request)?;
        if tile.pixels.len() > MAX_PAGE_BYTES {
            return Err(ArisError::new(
                ErrorCode::RenderFailed,
                "page raster exceeded its byte budget",
            ));
        }
        Ok(PageRaster { tile, scale })
    }
}

fn validate_size(size: Size) -> Result<()> {
    if !size.width.is_finite()
        || !size.height.is_finite()
        || size.width <= 0.0
        || size.height <= 0.0
    {
        return Err(ArisError::new(
            ErrorCode::InvalidArgument,
            "page dimensions must be positive and finite",
        ));
    }
    Ok(())
}

/// Account for ceil-to-pixel rounding as well as area/edge caps before asking PDFium to allocate.
pub fn bounded_raster_scale(size: Size, requested: f64) -> Result<f64> {
    validate_size(size)?;
    if !requested.is_finite() || requested <= 0.0 {
        return Err(ArisError::new(
            ErrorCode::InvalidArgument,
            "raster scale must be positive and finite",
        ));
    }
    let mut scale = requested.min(MAX_PAGE_EDGE / size.width.max(size.height));
    scale = scale.min(((MAX_PAGE_BYTES / 4) as f64 / size.width / size.height).sqrt());
    // Integer dimensions can exceed the area cap after rounding. The small reduction is
    // bounded and avoids allocating an enormous bitmap before enforcing the budget.
    while (size.width * scale).ceil() * (size.height * scale).ceil() * 4.0 > MAX_PAGE_BYTES as f64 {
        scale *= 0.999;
    }
    if scale <= 0.0 || !scale.is_finite() {
        return Err(ArisError::new(
            ErrorCode::InvalidArgument,
            "page cannot be rasterized within the budget",
        ));
    }
    Ok(scale)
}

/// Shared fit-width calculation; Qt supplies viewport dimensions, not its own zoom formula.
pub fn fit_width(page_width: f64, viewport_width: f64) -> f64 {
    resolve_zoom(
        Zoom::FitWidth,
        Size::new(page_width, 1.0),
        Size::new(viewport_width, 1.0),
        32.0,
    )
    .clamp(0.1, 4.0)
}

/// Preserve a content point under the input anchor. Scroll clamping remains the host's job.
pub fn zoomed_offset(offset: f64, anchor: f64, old_zoom: f64, new_zoom: f64) -> f64 {
    (offset + anchor) / old_zoom * new_zoom - anchor
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extreme_pages_stay_within_pixel_budget_including_rounding() {
        for size in [
            Size::new(595.0, 842.0),
            Size::new(100_000.0, 10.0),
            Size::new(0.2, 100_000.0),
        ] {
            let scale = bounded_raster_scale(size, 200.0).unwrap();
            let width = (size.width * scale).ceil();
            let height = (size.height * scale).ceil();
            assert!(width * height * 4.0 <= MAX_PAGE_BYTES as f64);
            assert!(width.max(height) <= MAX_PAGE_EDGE);
        }
        assert!(bounded_raster_scale(Size::new(595.0, 842.0), f64::NAN).is_err());
        assert!(bounded_raster_scale(Size::new(0.0, 842.0), 1.0).is_err());
    }

    #[test]
    fn zoom_retains_the_document_point_under_the_anchor() {
        let offset = zoomed_offset(300.0, 180.0, 1.2, 2.4);
        assert!(((offset + 180.0) / 2.4 - (300.0 + 180.0) / 1.2).abs() < 1e-9);
    }
}

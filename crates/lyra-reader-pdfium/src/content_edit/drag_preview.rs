//! Transient object appearances for dragging, rendered from an unsaved document copy.

use super::{failure, fingerprint, inspect_content, pdf_error};
use crate::backend::{PdfiumBackend, lock_pdfium, pdfium_instance};
use lyra_reader_core::{EngineConfig, RasterRequest, RasterTile, Result};
use pdfium_render::prelude::*;
use std::{fs, path::Path};

pub struct ContentDragPreview {
    pub background: RasterTile,
    pub foreground: RasterTile,
}

/// Renders the original paper without the selected object, plus that object's transparent
/// appearance. Neither the open reader document nor any file is changed. Call once per drag,
/// then move the two textures on the canvas instead of invoking PDFium for pointer samples.
pub fn content_drag_preview(
    source: &Path,
    target: &str,
    revision: &str,
    request: &RasterRequest,
) -> Result<ContentDragPreview> {
    let region = request
        .region
        .ok_or_else(|| failure("A drag preview needs a page region."))?;
    let width = (region.size.width * request.scale).ceil();
    let height = (region.size.height * request.scale).ceil();
    if !request.scale.is_finite()
        || request.scale <= 0.0
        || !(request.scale as f32).is_finite()
        || (request.scale as f32) <= 0.0
        || !region.origin.x.is_finite()
        || !region.origin.y.is_finite()
        || !width.is_finite()
        || !height.is_finite()
        || width < 1.0
        || height < 1.0
        || width > 8192.0
        || height > 8192.0
        || width * height > EngineConfig::default().full_page_max_pixels as f64
    {
        return Err(failure(
            "The drag preview exceeds the renderer's supported range.",
        ));
    }
    let snapshot = inspect_content(source, request.page.get())?;
    if snapshot.revision != revision {
        return Err(failure("The object belongs to an older document revision."));
    }
    let item = snapshot
        .items
        .iter()
        .find(|item| item.id == target)
        .ok_or_else(|| failure("The selected object no longer exists."))?;
    if item.paths.is_empty() || item.paths.iter().any(Vec::is_empty) {
        return Err(failure("This object has no drawable page content."));
    }
    let bytes = fs::read(source).map_err(pdf_error)?;
    if fingerprint(&bytes) != revision {
        return Err(failure(
            "The source changed while preparing the drag preview.",
        ));
    }
    let pdfium = pdfium_instance()?;
    let _guard = lock_pdfium()?;
    let doc = pdfium
        .load_pdf_from_byte_slice(&bytes, None)
        .map_err(pdf_error)?;
    let page = doc
        .pages()
        .get(request.page.get().try_into().map_err(pdf_error)?)
        .map_err(pdf_error)?;
    let size = crate::backend::page_geometry(&page).view_size(1.0);
    if region.origin.x < 0.0
        || region.origin.y < 0.0
        || region.origin.x + region.size.width > size.width + 1e-6
        || region.origin.y + region.size.height > size.height + 1e-6
    {
        return Err(failure("The drag preview region is outside the page."));
    }
    // The canvas composites annotations separately; do not bake a second copy into either crop.
    for mut annotation in page.annotations().iter() {
        annotation.set_is_hidden(true).map_err(pdf_error)?;
    }
    let mut active = Vec::with_capacity(item.paths.len());
    for path in &item.paths {
        active.push(set_path_active(&page, path, false)?);
    }
    let background = PdfiumBackend::rasterize_region(&page, request, region)?;
    for (path, active) in item.paths.iter().zip(active) {
        if active {
            set_path_active(&page, path, true)?;
        }
    }
    for (index, object) in page.objects().iter().enumerate() {
        retain_selected(object, &[index], &item.paths)?;
    }
    let mut transparent = *request;
    transparent.background = [0, 0, 0, 0];
    let foreground = PdfiumBackend::rasterize_region(&page, &transparent, region)?;
    Ok(ContentDragPreview {
        background,
        foreground,
    })
}

fn set_path_active(page: &PdfPage<'_>, path: &[usize], active: bool) -> Result<bool> {
    let (first, rest) = path
        .split_first()
        .ok_or_else(|| failure("The object path is empty."))?;
    change_active(page.objects().get(*first).map_err(pdf_error)?, rest, active)
}

fn change_active(mut object: PdfPageObject<'_>, path: &[usize], active: bool) -> Result<bool> {
    if let Some((first, rest)) = path.split_first() {
        let child = object
            .as_x_object_form_object()
            .ok_or_else(|| failure("The object hierarchy changed."))?
            .get(*first)
            .map_err(pdf_error)?;
        return change_active(child, rest, active);
    }
    let previous = object.is_active().map_err(pdf_error)?;
    if active {
        object.set_active().map_err(pdf_error)?;
    } else {
        object.set_inactive().map_err(pdf_error)?;
    }
    Ok(previous)
}

fn retain_selected(
    mut object: PdfPageObject<'_>,
    prefix: &[usize],
    paths: &[Vec<usize>],
) -> Result<()> {
    if paths.iter().any(|path| path == prefix) {
        return Ok(());
    }
    if !paths.iter().any(|path| path.starts_with(prefix)) {
        return object.set_inactive().map_err(pdf_error);
    }
    let form = object
        .as_x_object_form_object()
        .ok_or_else(|| failure("The object hierarchy changed."))?;
    for (index, child) in form.iter().enumerate() {
        let mut child_path = prefix.to_vec();
        child_path.push(index);
        retain_selected(child, &child_path, paths)?;
    }
    Ok(())
}

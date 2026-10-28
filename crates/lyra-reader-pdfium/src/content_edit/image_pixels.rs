//! Checked original image pixels for crop/export, before either PDFium or Rust allocates pixels.
use super::{failure, pdf_error};
use lyra_reader_core::Result;

// Keep the existing PNG editing limit for images already embedded in a PDF as well.
const MAX_PIXELS: usize = 40_000_000;
const MAX_BYTES: usize = MAX_PIXELS * 4;

pub(super) fn rgba_length(width: u32, height: u32) -> Result<usize> {
    let pixels = usize::try_from(width)
        .ok()
        .and_then(|w| usize::try_from(height).ok().and_then(|h| w.checked_mul(h)))
        .filter(|&pixels| width > 0 && height > 0 && pixels <= MAX_PIXELS)
        .ok_or_else(|| failure("The image exceeds the 40 megapixel editing limit."))?;
    pixels
        .checked_mul(4)
        .ok_or_else(|| failure("The image is too large."))
}

fn buffer_length(width: u32, height: u32, stride: i32, channels: usize) -> Result<usize> {
    rgba_length(width, height)?;
    let row = usize::try_from(width)
        .ok()
        .and_then(|w| w.checked_mul(channels))
        .ok_or_else(|| failure("The image row is too large."))?;
    let stride = usize::try_from(stride)
        .ok()
        .filter(|&s| s >= row)
        .ok_or_else(|| failure("The image has an invalid bitmap stride."))?;
    stride
        .checked_mul(usize::try_from(height).map_err(pdf_error)?)
        .filter(|&n| n <= MAX_BYTES)
        .ok_or_else(|| failure("The image bitmap exceeds the editing byte limit."))
}

struct OnDrop<F: FnOnce()>(Option<F>);
impl<F: FnOnce()> Drop for OnDrop<F> {
    fn drop(&mut self) {
        if let Some(close) = self.0.take() {
            close();
        }
    }
}

pub(super) struct Pixels {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

pub(super) fn read(bytes: &[u8], page_index: u32, path: &[usize]) -> Result<Pixels> {
    let (&first, nested) = path
        .split_first()
        .ok_or_else(|| failure("The image path is empty."))?;
    let index = i32::try_from(page_index).map_err(pdf_error)?;
    let first = i32::try_from(first).map_err(pdf_error)?;
    let api = crate::backend::raw_pdfium_bindings()?;
    let _guard = crate::backend::lock_pdfium()?;
    // SAFETY: bytes stays borrowed until the loaded document is closed; the global facade
    // owns this same PDFium library. All calls and RAII cleanup below hold PDFIUM_LOCK.
    let document = unsafe { api.FPDF_LoadMemDocument64(bytes, None) };
    if document.is_null() {
        return Err(failure("The image source could not be opened."));
    }
    // SAFETY: this non-null owned document is closed exactly once, after its page/bitmap.
    let _document = OnDrop(Some(|| unsafe { api.FPDF_CloseDocument(document) }));
    // SAFETY: the document is live and the signed page index is representable.
    let page = unsafe { api.FPDF_LoadPage(document, index) };
    if page.is_null() {
        return Err(failure("The image page is unavailable."));
    }
    // SAFETY: this non-null owned page is closed once before its document.
    let _page = OnDrop(Some(|| unsafe { api.FPDF_ClosePage(page) }));
    // SAFETY: page is live; PDFium returns null for an out-of-range object index.
    let mut object = unsafe { api.FPDFPage_GetObject(page, first) };
    if object.is_null() {
        return Err(failure("The image hierarchy changed."));
    }
    for &index in nested {
        let index = index.try_into().map_err(pdf_error)?;
        // SAFETY: object is a borrowed live page/form child. Type 5 is FPDF_PAGEOBJ_FORM
        // from fpdf_edit.h; only form objects are passed to FPDFFormObj_GetObject.
        if unsafe { api.FPDFPageObj_GetType(object) } != 5 {
            return Err(failure("The image hierarchy changed."));
        }
        // SAFETY: the live form owns its children; an invalid index returns null.
        object = unsafe { api.FPDFFormObj_GetObject(object, index) };
        if object.is_null() {
            return Err(failure("The image hierarchy changed."));
        }
    }
    // SAFETY: object remains owned by the live page. Type 3 is FPDF_PAGEOBJ_IMAGE.
    if unsafe { api.FPDFPageObj_GetType(object) } != 3 {
        return Err(failure("The object is not a bitmap image."));
    }
    let (mut width, mut height) = (0, 0);
    // SAFETY: live image and two aligned writable u32 outputs. This metadata query precedes
    // GetBitmap, which would decode and allocate the file-controlled image dimensions.
    if unsafe { api.FPDFImageObj_GetImagePixelSize(object, &mut width, &mut height) } == 0 {
        return Err(failure("The image dimensions are unavailable."));
    }
    let length = rgba_length(width, height)?;
    // SAFETY: the image is live and its decoded dimensions passed the pixel/byte limit.
    let bitmap = unsafe { api.FPDFImageObj_GetBitmap(object) };
    if bitmap.is_null() {
        return Err(failure("The image bitmap is unavailable."));
    }
    // SAFETY: GetBitmap returns an independently owned bitmap; destroy it before its page.
    let _bitmap = OnDrop(Some(|| unsafe { api.FPDFBitmap_Destroy(bitmap) }));
    // SAFETY: each metadata call reads this live bitmap; it does not copy its buffer.
    let (actual_width, actual_height, format, stride) = unsafe {
        (
            api.FPDFBitmap_GetWidth(bitmap),
            api.FPDFBitmap_GetHeight(bitmap),
            api.FPDFBitmap_GetFormat(bitmap),
            api.FPDFBitmap_GetStride(bitmap),
        )
    };
    if u32::try_from(actual_width).ok() != Some(width)
        || u32::try_from(actual_height).ok() != Some(height)
    {
        return Err(failure(
            "The image bitmap dimensions disagree with its metadata.",
        ));
    }
    // FPDFBitmap_Gray=1, BGR=2, BGRx=3, BGRA=4 (fpdfview.h). Unknown is an error,
    // never a default format. Validate stride/total before borrowing or copying raw bytes.
    let channels = match format {
        1 => 1,
        2 => 3,
        3 | 4 => 4,
        _ => return Err(failure("The image bitmap format is unsupported.")),
    };
    let raw_length = buffer_length(width, height, stride, channels)?;
    // SAFETY: bitmap is live. The API owns at least stride * height bytes until Destroy;
    // checked positive dimensions/stride/total above bound the slice and all row accesses.
    let pointer = unsafe { api.FPDFBitmap_GetBuffer(bitmap) };
    if pointer.is_null() {
        return Err(failure("The image bitmap buffer is unavailable."));
    }
    // SAFETY: non-null, byte-aligned native buffer with validated length, borrowed only while
    // its bitmap and PDFIUM_LOCK remain live. No native call mutates it during conversion.
    let raw = unsafe { std::slice::from_raw_parts(pointer.cast::<u8>(), raw_length) };
    let mut rgba = Vec::new();
    rgba.try_reserve_exact(length)
        .map_err(|_| failure("There is not enough memory to read this image."))?;
    let row_length = usize::try_from(width).map_err(pdf_error)? * channels;
    let stride = usize::try_from(stride).map_err(pdf_error)?;
    for row in raw.chunks_exact(stride) {
        for p in row[..row_length].chunks_exact(channels) {
            match format {
                1 => rgba.extend_from_slice(&[p[0], p[0], p[0], 255]),
                2 | 3 => rgba.extend_from_slice(&[p[2], p[1], p[0], 255]),
                4 => rgba.extend_from_slice(&[p[2], p[1], p[0], p[3]]),
                _ => return Err(failure("The image bitmap format is unsupported.")),
            }
        }
    }
    Ok(Pixels {
        width,
        height,
        rgba,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dimensions_and_native_stride_are_checked_without_pixel_allocation() {
        for (w, h) in [(0, 1), (1, 0), (u32::MAX, 2), (1, u32::MAX), (8192, 8192)] {
            assert!(rgba_length(w, h).is_err());
        }
        assert_eq!(rgba_length(8000, 5000).unwrap(), 160_000_000);
        assert!(buffer_length(4, 2, -16, 4).is_err());
        assert!(buffer_length(4, 2, 15, 4).is_err());
        assert!(buffer_length(4, 2, i32::MAX, 4).is_err());
        assert_eq!(buffer_length(3, 2, 12, 3).unwrap(), 24);
    }
}

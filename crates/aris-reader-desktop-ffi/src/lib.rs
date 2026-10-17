//! A narrow, synchronous C ABI. The Qt host supplies asynchronous execution and never
//! passes QObject pointers into Rust. Header: apps/desktop-qt/src/aris_desktop.h.
#![allow(unsafe_code)]

use aris_reader_runtime::Document;
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    path::Path,
    ptr, slice,
};

#[repr(C)]
pub struct Buffer {
    pub data: *mut u8,
    pub len: usize,
}

impl Buffer {
    fn owned(bytes: Vec<u8>) -> Self {
        let boxed = bytes.into_boxed_slice();
        let len = boxed.len();
        Self {
            data: Box::into_raw(boxed).cast::<u8>(),
            len,
        }
    }
}

#[repr(C)]
pub struct Bitmap {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub scale: f64,
    pub pixels: Buffer,
}

// Every pointer contract is in the header and repeated on the unsafe entry points.
unsafe fn bytes<'a>(data: *const u8, len: usize) -> Result<&'a [u8], String> {
    if len == 0 {
        return Ok(&[]);
    }
    if data.is_null() || len > isize::MAX as usize {
        return Err("invalid UTF-8 buffer".into());
    }
    Ok(unsafe { slice::from_raw_parts(data, len) })
}

unsafe fn run<T>(error: *mut Buffer, task: impl FnOnce() -> Result<T, String>) -> Option<T> {
    match catch_unwind(AssertUnwindSafe(task)) {
        Ok(Ok(value)) => Some(value),
        outcome => {
            let message = match outcome {
                Ok(Err(message)) => message,
                _ => "Rust document service panicked".into(),
            };
            if !error.is_null() {
                unsafe { error.write(Buffer::owned(message.into_bytes())) };
            }
            None
        }
    }
}

/// # Safety
/// Input pointers address `len` readable bytes; error is null or a writable empty Buffer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_desktop_open(
    path: *const u8,
    path_len: usize,
    password: *const u8,
    password_len: usize,
    error: *mut Buffer,
) -> *mut Document {
    unsafe {
        run(error, || {
            let path = std::str::from_utf8(bytes(path, path_len)?).map_err(|e| e.to_string())?;
            let password = if password.is_null() {
                None
            } else {
                Some(
                    std::str::from_utf8(bytes(password, password_len)?)
                        .map_err(|e| e.to_string())?,
                )
            };
            let document = Document::open(Path::new(path), password).map_err(|e| e.to_string())?;
            Ok(Box::into_raw(Box::new(document)))
        })
    }
    .unwrap_or(ptr::null_mut())
}

/// # Safety
/// document is null or an owned handle from open, with no outstanding users or previous close.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_desktop_close(document: *mut Document) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !document.is_null() {
            drop(unsafe { Box::from_raw(document) });
        }
    }));
}

/// # Safety
/// document stays alive throughout the call; output/error are writable empty buffers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_desktop_info(
    document: *const Document,
    output: *mut Buffer,
    error: *mut Buffer,
) -> bool {
    unsafe {
        run(error, || {
            let doc = document.as_ref().ok_or("document handle is null")?;
            if output.is_null() {
                return Err("output buffer is null".into());
            }
            let pages: Vec<_> = doc.layout().placements().iter().map(|p| serde_json::json!({
            "index": p.index, "width": p.width_pt, "height": p.height_pt, "top": p.top_pt,
        })).collect();
            let info = serde_json::json!({
                "pages": pages,
                "width": doc.layout().content_width_pt(),
                "height": doc.layout().content_height_pt(),
                "gap": doc.layout().gap_pt(),
            });
            output.write(Buffer::owned(
                serde_json::to_vec(&info).map_err(|e| e.to_string())?,
            ));
            Ok(())
        })
    }
    .is_some()
}

/// # Safety
/// document stays alive throughout the call; output/error are writable empty structures.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_desktop_render(
    document: *const Document,
    page: u32,
    scale: f64,
    output: *mut Bitmap,
    error: *mut Buffer,
) -> bool {
    unsafe {
        run(error, || {
            let doc = document.as_ref().ok_or("document handle is null")?;
            if output.is_null() {
                return Err("output bitmap is null".into());
            }
            let raster = doc.render_page(page, scale).map_err(|e| e.to_string())?;
            let stride = u32::try_from(raster.tile.stride).map_err(|_| "bitmap stride overflow")?;
            output.write(Bitmap {
                width: raster.tile.size.width as u32,
                height: raster.tile.size.height as u32,
                stride,
                scale: raster.scale,
                pixels: Buffer::owned(raster.tile.pixels),
            });
            Ok(())
        })
    }
    .is_some()
}

/// # Safety
/// buffer is returned by this library and has not been freed; a zeroed buffer is allowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aris_reader_desktop_buffer_free(buffer: Buffer) {
    if !buffer.data.is_null() {
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(buffer.data, buffer.len)) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_desktop_fit_width(page_width: f64, viewport_width: f64) -> f64 {
    if !page_width.is_finite() || !viewport_width.is_finite() {
        return 1.0;
    }
    aris_reader_runtime::fit_width(page_width, viewport_width)
}

#[unsafe(no_mangle)]
pub extern "C" fn aris_reader_desktop_zoom_offset(
    offset: f64,
    anchor: f64,
    old_zoom: f64,
    new_zoom: f64,
) -> f64 {
    if [offset, anchor, old_zoom, new_zoom]
        .iter()
        .any(|n| !n.is_finite())
        || old_zoom <= 0.0
        || new_zoom <= 0.0
    {
        return 0.0;
    }
    aris_reader_runtime::zoomed_offset(offset, anchor, old_zoom, new_zoom)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_handles_report_errors_without_unwinding() {
        let mut error = Buffer {
            data: ptr::null_mut(),
            len: 0,
        };
        let mut output = Buffer {
            data: ptr::null_mut(),
            len: 0,
        };
        assert!(!unsafe { aris_reader_desktop_info(ptr::null(), &mut output, &mut error) });
        assert!(!error.data.is_null());
        unsafe {
            aris_reader_desktop_buffer_free(error);
            aris_reader_desktop_close(ptr::null_mut());
        }
    }
}

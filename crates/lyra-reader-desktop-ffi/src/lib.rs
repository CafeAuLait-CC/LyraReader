//! A narrow, synchronous C ABI. The Qt host supplies asynchronous execution and never
//! passes QObject pointers into Rust. Header: apps/desktop-qt/src/lyra_reader_desktop.h.
#![allow(unsafe_code)]

mod artwork;
mod document;
mod exports;
mod marks;
mod pages;
mod render_source;
use document::DesktopDocument as Document;
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
pub unsafe extern "C" fn lyra_reader_desktop_open(
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
            let document = Document::open(Path::new(path), password)?;
            Ok(Box::into_raw(Box::new(document)))
        })
    }
    .unwrap_or(ptr::null_mut())
}

/// # Safety
/// document is null or an owned handle from open, with no outstanding users or previous close.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_close(document: *mut Document) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !document.is_null() {
            drop(unsafe { Box::from_raw(document) });
        }
    }));
}

/// # Safety
/// document stays alive throughout the call; output/error are writable empty buffers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_info(
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
            let info = doc.info()?;
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
pub unsafe extern "C" fn lyra_reader_desktop_render(
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
            let raster = doc.render(page, scale, false)?;
            output.write(Bitmap {
                width: raster.width_px,
                height: raster.height_px,
                stride: raster.stride,
                scale: raster.scale_used,
                pixels: Buffer::owned(raster.pixels),
            });
            Ok(())
        })
    }
    .is_some()
}

/// # Safety
/// Same handle and empty output/error contract as render. This path burns the PDF's
/// existing appearances into thumbnails; editable canvas annotations are separate GPU nodes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_render_annotated(
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
            let image = doc.render(page, scale, true)?;
            output.write(Bitmap {
                width: image.width_px,
                height: image.height_px,
                stride: image.stride,
                scale: image.scale_used,
                pixels: Buffer::owned(image.pixels),
            });
            Ok(())
        })
    }
    .is_some()
}

/// # Safety
/// Document stays alive during the call; request addresses request_len readable bytes.
/// Output and error are writable, empty buffers and must be freed by buffer_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_command(
    document: *const Document,
    request: *const u8,
    request_len: usize,
    output: *mut Buffer,
    error: *mut Buffer,
) -> bool {
    unsafe {
        run(error, || {
            let doc = document.as_ref().ok_or("document handle is null")?;
            if output.is_null() {
                return Err("output buffer is null".into());
            }
            let request =
                serde_json::from_slice(bytes(request, request_len)?).map_err(|e| e.to_string())?;
            let result = doc.command(request)?;
            let response = serde_json::to_vec(&serde_json::json!({"result":result}))
                .map_err(|e| e.to_string())?;
            output.write(Buffer::owned(response));
            Ok(())
        })
    }
    .is_some()
}

/// # Safety
/// buffer is returned by this library and has not been freed; a zeroed buffer is allowed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_buffer_free(buffer: Buffer) {
    if !buffer.data.is_null() {
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(buffer.data, buffer.len)) });
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn lyra_reader_desktop_zoom_offset(
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
    lyra_reader_runtime::zoomed_offset(offset, anchor, old_zoom, new_zoom)
}

/// # Safety
/// The document remains alive during preparation. The returned snapshot is independent;
/// free it once with render_source_free, after all crop requests finish.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_render_source(
    document: *const Document,
    include_edits: bool,
    error: *mut Buffer,
) -> *mut render_source::RenderSource {
    unsafe {
        run(error, || {
            let document = document.as_ref().ok_or("document handle is null")?;
            Ok(Box::into_raw(Box::new(render_source::RenderSource::new(
                document,
                include_edits,
            )?)))
        })
    }
    .unwrap_or(ptr::null_mut())
}
/// # Safety
/// Source is null or uniquely owned, with no crop calls in progress.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_render_source_free(
    source: *mut render_source::RenderSource,
) {
    if !source.is_null() {
        unsafe {
            drop(Box::from_raw(source));
        }
    }
}
/// # Safety
/// Source remains alive during the call. Output/error are writable empty structures.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lyra_reader_desktop_render_region(
    source: *const render_source::RenderSource,
    page: u32,
    scale: f64,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    annotated: bool,
    transparent: bool,
    output: *mut Bitmap,
    error: *mut Buffer,
) -> bool {
    unsafe {
        run(error, || {
            let source = source.as_ref().ok_or("render source is null")?;
            if output.is_null() {
                return Err("output bitmap is null".into());
            }
            let image = source.render(
                page,
                scale,
                lyra_reader_core::Rect::new(x, y, width, height),
                annotated,
                transparent,
            )?;
            output.write(Bitmap {
                width: image.width_px,
                height: image.height_px,
                stride: image.stride,
                scale: image.scale_used,
                pixels: Buffer::owned(image.pixels),
            });
            Ok(())
        })
    }
    .is_some()
}

/// # Safety
/// Source remains alive throughout the query. Request/output follow the desktop command contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_source_command(
    source: *const render_source::RenderSource,
    request: *const u8,
    len: usize,
    output: *mut Buffer,
    error: *mut Buffer,
) -> bool {
    unsafe {
        run(error, || {
            let source = source.as_ref().ok_or("render source is null")?;
            if output.is_null() {
                return Err("output buffer is null".into());
            }
            let request =
                serde_json::from_slice(bytes(request, len)?).map_err(|e| e.to_string())?;
            let result = source.query(request)?;
            output.write(Buffer::owned(
                serde_json::to_vec(&serde_json::json!({"result":result}))
                    .map_err(|e| e.to_string())?,
            ));
            Ok(())
        })
    }
    .is_some()
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
        assert!(!unsafe { lyra_reader_desktop_info(ptr::null(), &mut output, &mut error) });
        assert!(!error.data.is_null());
        unsafe {
            lyra_reader_desktop_buffer_free(error);
            lyra_reader_desktop_close(ptr::null_mut());
        }
    }
}

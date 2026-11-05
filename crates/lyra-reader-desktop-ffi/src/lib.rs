//! A narrow, synchronous C ABI. The Qt host supplies asynchronous execution and never
//! passes QObject pointers into Rust. Header: apps/desktop-qt/src/lyra_reader_desktop.h.
#![allow(unsafe_code)]

mod artwork;
mod audit;
mod content;
mod document;
mod document_cache;
mod draft_store;
mod exports;
mod marks;
mod navigation;
mod pages;
mod region;
mod region_store;
mod render_source;
mod saving;
mod session;
use document::DesktopDocument as Document;
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    path::Path,
    ptr, slice,
};

/// Version of the hand-written Qt C boundary, including immutable image byte access.
#[unsafe(no_mangle)]
pub extern "C" fn lyra_reader_desktop_abi_version() -> u32 {
    2
}

/// # Safety
/// Error is writable and empty; free its returned buffer once with buffer_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_history_new(
    error: *mut Buffer,
) -> *mut navigation::History {
    // SAFETY: caller provides the documented empty error buffer. The returned owner
    // is opaque and must outlive every history_command borrow before history_free.
    unsafe {
        run(error, || {
            Ok(Box::into_raw(Box::new(navigation::History::new())))
        })
        .unwrap_or(ptr::null_mut())
    }
}
/// # Safety
/// History is null or the unique owner from history_new; no command is in flight.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_history_free(history: *mut navigation::History) {
    // SAFETY: caller retires the one owner after all synchronous borrows finish.
    if !history.is_null() {
        drop(unsafe { Box::from_raw(history) });
    }
}
/// # Safety
/// History is null (rejected) or remains alive; request spans request_len readable bytes. Output/error are
/// writable empty distinct buffers, each freed once with buffer_free after the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_history_command(
    history: *const navigation::History,
    request: *const u8,
    request_len: usize,
    output: *mut Buffer,
    error: *mut Buffer,
) -> bool {
    // SAFETY: all pointers obey the stated ownership, slice and empty-buffer contracts.
    unsafe {
        run(error, || {
            if request_len > 64 * 1024 {
                return Err("Navigation request exceeds its byte limit".into());
            }
            if output.is_null() {
                return Err("Navigation output is null".into());
            }
            let history = history.as_ref().ok_or("Navigation history is closed")?;
            let request =
                serde_json::from_slice(bytes(request, request_len)?).map_err(|e| e.to_string())?;
            output.write(Buffer::owned(
                serde_json::to_vec(&history.query(request)?).map_err(|e| e.to_string())?,
            ));
            Ok(())
        })
        .is_some()
    }
}

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

/// # Safety
/// Source remains alive during the call; target/revision address their stated readable UTF-8
/// byte lengths. Output/error are non-aliased writable empty buffers, freed with buffer_free.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lyra_reader_desktop_source_image_png(
    source: *const render_source::RenderSource,
    page: u32,
    target: *const u8,
    target_len: usize,
    revision: *const u8,
    revision_len: usize,
    output: *mut Buffer,
    error: *mut Buffer,
) -> bool {
    // SAFETY: the caller upholds the handle, slice and writable-buffer contracts above.
    // Length limits are checked before constructing the borrowed slices; no pointer escapes.
    unsafe {
        run(error, || {
            let source = source.as_ref().ok_or("render source is null")?;
            if output.is_null() {
                return Err("output image buffer is null".into());
            }
            if target_len > 4096 || revision_len > 128 {
                return Err("Image identity is too long".into());
            }
            let target =
                std::str::from_utf8(bytes(target, target_len)?).map_err(|e| e.to_string())?;
            let revision =
                std::str::from_utf8(bytes(revision, revision_len)?).map_err(|e| e.to_string())?;
            output.write(Buffer::owned(source.image_png(page, target, revision)?));
            Ok(())
        })
    }
    .is_some()
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
/// For document operations, document stays alive during the call. It may be null for
/// audit_records/audit_clear, which ignore it. Request addresses request_len readable bytes.
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
            if output.is_null() {
                return Err("output buffer is null".into());
            }
            // SAFETY: the caller owns the request slice and writable output as documented;
            // a document handle is inspected only after excluding document-free audit queries.
            let request: serde_json::Value =
                serde_json::from_slice(bytes(request, request_len)?).map_err(|e| e.to_string())?;
            let result = if matches!(
                request["op"].as_str(),
                Some("audit_records" | "audit_clear")
            ) {
                crate::audit::query(&crate::document_cache::default_root()?, &request)?
            } else {
                document
                    .as_ref()
                    .ok_or("document handle is null")?
                    .command(request)?
            };
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

/// Pure shared zoom policy. Zero means no usable fit, outside the 25–400 percent range.
#[unsafe(no_mangle)]
pub extern "C" fn lyra_reader_desktop_fit_percent(
    fit_page: bool,
    page_width: f64,
    page_height: f64,
    viewport_width: f64,
    viewport_height: f64,
    calibration: f64,
) -> u32 {
    lyra_reader_session::resolve_zoom_percent(
        if fit_page {
            lyra_reader_session::ZoomRequest::FitPage
        } else {
            lyra_reader_session::ZoomRequest::FitWidth
        },
        lyra_reader_core::Size::new(page_width, page_height),
        lyra_reader_core::Size::new(viewport_width, viewport_height),
        calibration,
    )
    .unwrap_or(0) // Explicit optional-result sentinel, never a valid percentage.
}

/// Zero means retain the current percentage; the single-page decision lives in session.
#[unsafe(no_mangle)]
pub extern "C" fn lyra_reader_desktop_viewport_fit(
    page_count: u32,
    current_percent: u32,
    page_height: f64,
    viewport_height: f64,
    calibration: f64,
) -> u32 {
    lyra_reader_session::fit_page_on_viewport_change(
        page_count,
        current_percent,
        page_height,
        viewport_height,
        calibration,
    )
    .unwrap_or(0) // A no-change result is not replaced with a new zoom.
}

/// NaN means the shell's transient layout has no usable range; keep its previous offset.
#[unsafe(no_mangle)]
pub extern "C" fn lyra_reader_desktop_clamp_scroll(
    offset: f64,
    content_height: f64,
    viewport_height: f64,
) -> f64 {
    if !offset.is_finite()
        || !content_height.is_finite()
        || !viewport_height.is_finite()
        || content_height < 0.0
        || viewport_height < 0.0
    {
        return f64::NAN;
    }
    lyra_reader_session::clamp_scroll(offset, content_height, viewport_height)
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
    fn navigation_handle_and_packet_boundaries_keep_owned_buffers_balanced() {
        let mut error = Buffer {
            data: ptr::null_mut(),
            len: 0,
        };
        let mut output = Buffer {
            data: ptr::null_mut(),
            len: 0,
        };
        // SAFETY: unique empty buffers, a live opaque owner, and owned readable packets.
        // Every returned buffer/owner is freed once after its synchronous borrow ends.
        unsafe {
            let history = lyra_reader_desktop_history_new(&mut error);
            assert!(!history.is_null());
            assert!(error.data.is_null());
            let request = br#"{"op":"snapshot"}"#;
            assert!(lyra_reader_desktop_history_command(
                history,
                request.as_ptr(),
                request.len(),
                &mut output,
                &mut error
            ));
            let response: serde_json::Value =
                serde_json::from_slice(slice::from_raw_parts(output.data, output.len)).unwrap();
            assert_eq!(
                response["state"]["limit"],
                lyra_reader_session::NAVIGATION_HISTORY_LIMIT
            );
            lyra_reader_desktop_buffer_free(output);
            output = Buffer {
                data: ptr::null_mut(),
                len: 0,
            };
            let oversized = vec![b' '; 64 * 1024 + 1];
            assert!(!lyra_reader_desktop_history_command(
                history,
                oversized.as_ptr(),
                oversized.len(),
                &mut output,
                &mut error
            ));
            assert!(output.data.is_null());
            assert!(!error.data.is_null());
            lyra_reader_desktop_buffer_free(error);
            error = Buffer {
                data: ptr::null_mut(),
                len: 0,
            };
            assert!(!lyra_reader_desktop_history_command(
                ptr::null(),
                request.as_ptr(),
                request.len(),
                &mut output,
                &mut error
            ));
            assert!(output.data.is_null());
            lyra_reader_desktop_buffer_free(error);
            lyra_reader_desktop_history_free(history);
            lyra_reader_desktop_history_free(ptr::null_mut());
        }
    }

    #[test]
    fn native_viewport_boundary_uses_the_shared_fit_and_scroll_contract() {
        assert_eq!(
            lyra_reader_desktop_fit_percent(true, 595.0, 842.0, 900.0, 900.0, 1.0),
            104
        );
        assert_eq!(
            lyra_reader_desktop_viewport_fit(1, 100, 842.0, 900.0, 1.0),
            104
        );
        assert_eq!(
            lyra_reader_desktop_viewport_fit(1, 104, 842.0, 900.0, 1.0),
            0
        );
        assert_eq!(
            lyra_reader_desktop_viewport_fit(2, 25, 842.0, 900.0, 1.0),
            0
        );
        assert_eq!(
            lyra_reader_desktop_viewport_fit(1, 100, 842.0, 582.0, 0.5278),
            127
        );
        assert_eq!(
            lyra_reader_desktop_fit_percent(false, 595.0, 842.0, 611.0, 900.0, 1.0),
            100
        );
        assert_eq!(
            lyra_reader_desktop_fit_percent(true, 595.0, 842.0, 900.0, f64::NAN, 1.0),
            0
        );
        assert_eq!(lyra_reader_desktop_clamp_scroll(-5.0, 1000.0, 300.0), 0.0);
        assert_eq!(
            lyra_reader_desktop_clamp_scroll(9999.0, 1000.0, 300.0),
            700.0
        );
        assert_eq!(lyra_reader_desktop_clamp_scroll(10.0, 200.0, 300.0), 0.0);
        assert!(lyra_reader_desktop_clamp_scroll(f64::INFINITY, 200.0, 300.0).is_nan());
        assert!(lyra_reader_desktop_clamp_scroll(10.0, -1.0, 300.0).is_nan());
    }

    #[test]
    fn image_byte_boundary_rejects_null_handles_and_reports_its_version() {
        assert_eq!(lyra_reader_desktop_abi_version(), 2);
        let mut error = Buffer {
            data: ptr::null_mut(),
            len: 0,
        };
        let mut output = Buffer {
            data: ptr::null_mut(),
            len: 0,
        };
        // SAFETY: null handles are rejected before use; the two output structures are live,
        // empty and distinct. The empty input slices require no readable storage.
        assert!(!unsafe {
            lyra_reader_desktop_source_image_png(
                ptr::null(),
                0,
                ptr::null(),
                0,
                ptr::null(),
                0,
                &mut output,
                &mut error,
            )
        });
        assert!(output.data.is_null());
        assert!(!error.data.is_null());
        // SAFETY: error is the one owned allocation returned by the failed call above.
        unsafe { lyra_reader_desktop_buffer_free(error) };
    }

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

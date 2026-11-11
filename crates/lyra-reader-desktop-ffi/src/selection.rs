//! Cache-only native selection adapters. Recognition and copy normalization live in text.
use crate::{Buffer, bytes, document::DesktopDocument, run};

const MAX_COPY_BYTES: usize = 16 * 1024 * 1024;

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CacheStatus {
    Error = 0,
    NotPrepared = 1,
    Ready = 2,
}

fn output_slot<T>(output: *mut T) -> Result<(), String> {
    if output.is_null() || !(output as usize).is_multiple_of(std::mem::align_of::<T>()) {
        return Err("Selection output is null or misaligned".into());
    }
    Ok(())
}

/// Maximum UTF-8 bytes accepted by the explicit clipboard normalization adapter.
#[unsafe(no_mangle)]
pub extern "C" fn lyra_reader_desktop_selection_copy_limit() -> usize {
    MAX_COPY_BYTES
}

/// # Safety
/// Document is live and aligned throughout the call. Output/error are distinct aligned,
/// writable empty Buffers; free owned buffers once. Null/misaligned output is rejected
/// before access; a miss leaves output untouched. Native drag endpoints may be reversed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_selection_text(
    document: *const DesktopDocument,
    page: u32,
    start: u32,
    end: u32,
    output: *mut Buffer,
    error: *mut Buffer,
) -> CacheStatus {
    // SAFETY: caller owns the documented live handle and distinct slots. The output
    // guard precedes any write; the shared cache lookup never loads a PDFium page.
    unsafe {
        run(error, || {
            output_slot(output)?;
            let current = document
                .as_ref()
                .ok_or("Selection document is null")?
                .active()?;
            if page >= current.page_count() {
                return Err("The selection page is unavailable".into());
            }
            let text = current
                .text_range_string(page, start.min(end), start.max(end))
                .map_err(|e| e.to_string())?;
            match text {
                Some(text) => {
                    output.write(Buffer::owned(text.into_bytes()));
                    Ok(CacheStatus::Ready)
                }
                None => Ok(CacheStatus::NotPrepared),
            }
        })
    }
    .unwrap_or(CacheStatus::Error) // An explicit failed-call status, never an empty success.
}

/// # Safety
/// Text addresses text_len readable UTF-8 bytes for this call; empty input permits null.
/// Output/error are distinct aligned writable empty Buffers, freed once by the caller.
/// Over-limit input is rejected before text is accessed; null/misaligned output is rejected.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lyra_reader_desktop_selection_copy_text(
    text: *const u8,
    text_len: usize,
    output: *mut Buffer,
    error: *mut Buffer,
) -> bool {
    // SAFETY: caller-owned slots and borrowed text. The byte bound precedes both
    // slice construction and allocation; normalization cannot grow the input.
    unsafe {
        run(error, || {
            output_slot(output)?;
            if text_len > MAX_COPY_BYTES {
                return Err("The copied selection exceeds the native clipboard size limit".into());
            }
            let text = std::str::from_utf8(bytes(text, text_len)?)
                .map_err(|e| format!("Invalid copied selection UTF-8: {e}"))?;
            let copied = lyra_reader_ffi::api::selection_copy_text(text.to_owned());
            output.write(Buffer::owned(copied.into_bytes()));
            Ok(())
        })
    }
    .is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, path::Path, ptr};

    fn empty() -> Buffer {
        Buffer {
            data: ptr::null_mut(),
            len: 0,
        }
    }
    unsafe fn take(buffer: Buffer) -> String {
        // SAFETY: test buffers came from this ABI and are consumed/freed once here.
        unsafe {
            let value =
                String::from_utf8(bytes(buffer.data, buffer.len).unwrap().to_vec()).unwrap();
            crate::lyra_reader_desktop_buffer_free(buffer);
            value
        }
    }

    #[test]
    fn native_range_reads_distinguish_misses_errors_and_empty_prepared_ranges() {
        let directory = std::env::temp_dir().join(format!(
            "lyra-selection-{}-{}",
            std::process::id(),
            crate::marks::uuid().unwrap()
        ));
        fs::create_dir(&directory).unwrap();
        let source = directory.join("selection.pdf");
        fs::copy(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../tests/fixtures/two-column-line-numbers.pdf"),
            &source,
        )
        .unwrap();
        let original = fs::read(&source).unwrap();
        let doc =
            DesktopDocument::open_with_cache_root(&source, None, Some(&directory.join("cache")))
                .unwrap();
        let current = doc.active().unwrap();
        let mut out = empty();
        let mut error = empty();
        // SAFETY: the document and distinct empty slots stay live throughout. The final
        // deliberately null output follows the documented rejection path before access.
        unsafe {
            assert_eq!(
                lyra_reader_desktop_selection_text(&doc, 0, 0, u32::MAX, &mut out, &mut error),
                CacheStatus::NotPrepared
            );
            assert!(out.data.is_null() && out.len == 0 && error.data.is_null());
            assert_eq!(current.text_page_cache_stats().loads, 0);
            let page = current.text_page(0).unwrap();
            assert_eq!(page.selection_excluded_indices.len(), 60);
            assert!(page.text.contains("001") && page.text.contains("020"));
            for (start, end) in [(0, u32::MAX), (u32::MAX, 0)] {
                assert_eq!(
                    lyra_reader_desktop_selection_text(&doc, 0, start, end, &mut out, &mut error),
                    CacheStatus::Ready
                );
                let text = take(out);
                out = empty();
                assert!(!text.contains("001") && !text.contains("020"));
                assert!(text.contains("42") && text.contains("[12]"));
                assert_eq!(
                    text,
                    current.text_range_string(0, 0, u32::MAX).unwrap().unwrap()
                );
            }
            assert_eq!(
                lyra_reader_desktop_selection_text(
                    &doc,
                    0,
                    u32::MAX,
                    u32::MAX,
                    &mut out,
                    &mut error
                ),
                CacheStatus::Ready
            );
            assert_eq!(take(out), "");
            out = empty();
            assert_eq!(
                lyra_reader_desktop_selection_text(&doc, 999, 0, 1, &mut out, &mut error),
                CacheStatus::Error
            );
            assert!(out.data.is_null() && out.len == 0);
            assert!(take(error).contains("unavailable"));
            error = empty();
            assert_eq!(
                lyra_reader_desktop_selection_text(&doc, 0, 0, 1, ptr::null_mut(), &mut error),
                CacheStatus::Error
            );
            assert!(take(error).contains("output"));
        }
        assert_eq!(current.text_page_cache_stats().loads, 1);
        assert_eq!(fs::read(&source).unwrap(), original);
        drop(current);
        drop(doc);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn native_clipboard_normalization_is_explicit_bounded_and_does_not_mutate_raw_text() {
        let raw = "con\u{2}\r\n   ditioning ordi\u{ad}\n nary\n\nfine-grained Time-Aware αβ\0";
        let before = raw.to_owned();
        let mut out = empty();
        let mut error = empty();
        // SAFETY: each input slice and the distinct output/error slots remain valid;
        // the deliberately oversized pointer is rejected by length before it is borrowed.
        unsafe {
            assert!(lyra_reader_desktop_selection_copy_text(
                raw.as_ptr(),
                raw.len(),
                &mut out,
                &mut error
            ));
            assert_eq!(
                take(out),
                "conditioning ordinary\n\nfine-grained Time-Aware αβ\0"
            );
            out = empty();
            assert_eq!(raw, before);
            assert!(!lyra_reader_desktop_selection_copy_text(
                [0xff].as_ptr(),
                1,
                &mut out,
                &mut error
            ));
            assert!(out.data.is_null() && out.len == 0);
            assert!(take(error).contains("UTF-8"));
            error = empty();
            assert!(!lyra_reader_desktop_selection_copy_text(
                ptr::without_provenance(1),
                MAX_COPY_BYTES + 1,
                &mut out,
                &mut error
            ));
            assert!(out.data.is_null() && out.len == 0);
            assert!(take(error).contains("size limit"));
            error = empty();
            assert!(lyra_reader_desktop_selection_copy_text(
                ptr::null(),
                0,
                &mut out,
                &mut error
            ));
            assert_eq!(take(out), "");
            assert!(error.data.is_null());
        }
    }
}

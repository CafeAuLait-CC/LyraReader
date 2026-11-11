//! Bounded control/data bridge for the shared, detached object-drag renderer.
use crate::{Bitmap, Buffer, bytes, render_source::RenderSource, run};
use lyra_reader_ffi::api::{ContentBoxRecord, PageBitmap};
const PAIR_BYTES: usize = 16 * 1024 * 1024;
#[unsafe(no_mangle)]
pub extern "C" fn lyra_reader_desktop_drag_pair_limit() -> usize {
    PAIR_BYTES
}
fn geometry(width: f64, height: f64, scale: f64) -> Result<(), String> {
    let w = (width * scale).ceil();
    let h = (height * scale).ceil();
    if !width.is_finite()
        || !height.is_finite()
        || !scale.is_finite()
        || width <= 0.0
        || height <= 0.0
        || scale <= 0.0
        || !w.is_finite()
        || !h.is_finite()
        || w < 1.0
        || h < 1.0
        || w > 8192.0
        || h > 8192.0
    {
        return Err("Invalid object preview dimensions".into());
    }
    let n = (w as usize)
        .checked_mul(h as usize)
        .and_then(|n| n.checked_mul(8))
        .ok_or("Object preview size overflow")?;
    if n > PAIR_BYTES {
        return Err("The object preview exceeds its pixel budget".into());
    }
    Ok(())
}
fn bitmap(image: PageBitmap) -> Result<Bitmap, String> {
    let length = (image.stride as usize)
        .checked_mul(image.height_px as usize)
        .ok_or("Object preview stride overflow")?;
    if image.width_px == 0
        || image.height_px == 0
        || image.width_px > 8192
        || image.height_px > 8192
        || u64::from(image.stride) < u64::from(image.width_px) * 4
        || length > PAIR_BYTES / 2
        || image.pixels.len() != length
        || !image.scale_used.is_finite()
        || image.scale_used <= 0.0
    {
        return Err("Invalid object preview bitmap".into());
    }
    Ok(Bitmap {
        width: image.width_px,
        height: image.height_px,
        stride: image.stride,
        scale: image.scale_used,
        pixels: Buffer::owned(image.pixels),
    })
}
/// # Safety
/// Source is a live aligned render handle for this call. Identity slices are readable
/// UTF-8 for their stated lengths. Output/error slots are distinct aligned writable
/// empty structures. Free each successful pixel buffer exactly once. No borrow escapes.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lyra_reader_desktop_drag_preview(
    source: *const RenderSource,
    page: u32,
    target: *const u8,
    target_len: usize,
    revision: *const u8,
    revision_len: usize,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    scale: f64,
    background: *mut Bitmap,
    foreground: *mut Bitmap,
    error: *mut Buffer,
) -> bool {
    // SAFETY: caller's handle/slices/slots follow the contract. Bounds and alignment
    // precede access/allocation; both images are validated before either is published.
    unsafe {
        run(error, || {
            if background.is_null()
                || foreground.is_null()
                || background == foreground
                || !(background as usize).is_multiple_of(std::mem::align_of::<Bitmap>())
                || !(foreground as usize).is_multiple_of(std::mem::align_of::<Bitmap>())
            {
                return Err("Invalid object preview output slots".into());
            }
            geometry(width, height, scale)?;
            if !x.is_finite()
                || !y.is_finite()
                || x < 0.0
                || y < 0.0
                || !(x + width).is_finite()
                || !(y + height).is_finite()
            {
                return Err("Invalid object preview region".into());
            }
            if target_len == 0 || target_len > 4096 || revision_len == 0 || revision_len > 128 {
                return Err("Invalid object preview identity length".into());
            }
            let target =
                std::str::from_utf8(bytes(target, target_len)?).map_err(|e| e.to_string())?;
            let revision =
                std::str::from_utf8(bytes(revision, revision_len)?).map_err(|e| e.to_string())?;
            let source = source.as_ref().ok_or("The render source is unavailable")?;
            let pair = source.drag_preview(
                page,
                target,
                revision,
                ContentBoxRecord {
                    x,
                    y,
                    width,
                    height,
                },
                scale,
            )?;
            if pair.background.width_px != pair.foreground.width_px
                || pair.background.height_px != pair.foreground.height_px
                || pair.background.stride != pair.foreground.stride
                || pair.background.scale_used != pair.foreground.scale_used
            {
                return Err("Mismatched object preview images".into());
            }
            // Convert the first result only after validation of both, so an error cannot leak
            // an unpublished owned Buffer across this ABI.
            let first = pair.background;
            let second = pair.foreground;
            let check = |v: &PageBitmap| -> Result<(), String> {
                let n = (v.stride as usize)
                    .checked_mul(v.height_px as usize)
                    .ok_or("Object preview stride overflow")?;
                if n > PAIR_BYTES / 2 || n != v.pixels.len() {
                    return Err("Invalid object preview pixel length".into());
                }
                geometry(f64::from(v.width_px), f64::from(v.height_px), 1.0)
            };
            check(&first)?;
            check(&second)?;
            let bg = bitmap(first)?;
            let fg = match bitmap(second) {
                Ok(v) => v,
                Err(e) => {
                    crate::lyra_reader_desktop_buffer_free(bg.pixels);
                    return Err(e);
                }
            };
            background.write(bg);
            foreground.write(fg);
            Ok(())
        })
    }
    .is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pair_allocation_bounds_precede_every_conversion() {
        assert!(geometry(1024.0, 2048.0, 1.0).is_ok());
        for (w, h, s) in [
            (1024.0, 2049.0, 1.0),
            (8193.0, 1.0, 1.0),
            (1.0, 1.0, f64::NAN),
            (f64::INFINITY, 1.0, 1.0),
            (1.0, -1.0, 1.0),
            (1.0, 1.0, 0.0),
        ] {
            assert!(geometry(w, h, s).is_err());
        }
    }
    #[test]
    fn invalid_pair_calls_leave_outputs_empty() {
        let empty = || Bitmap {
            width: 0,
            height: 0,
            stride: 0,
            scale: 0.0,
            pixels: Buffer {
                data: std::ptr::null_mut(),
                len: 0,
            },
        };
        let mut bg = empty();
        let mut fg = empty();
        let mut error = Buffer {
            data: std::ptr::null_mut(),
            len: 0,
        };
        // SAFETY: valid distinct empty output slots. Null handles/over-limit identity
        // lengths and non-finite geometry are explicitly rejected before input access.
        unsafe {
            assert!(!lyra_reader_desktop_drag_preview(
                std::ptr::null(),
                0,
                std::ptr::null(),
                usize::MAX,
                std::ptr::null(),
                0,
                0.0,
                0.0,
                1.0,
                1.0,
                1.0,
                &mut bg,
                &mut fg,
                &mut error
            ));
            crate::lyra_reader_desktop_buffer_free(error);
            error = Buffer {
                data: std::ptr::null_mut(),
                len: 0,
            };
            assert!(!lyra_reader_desktop_drag_preview(
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                0.0,
                0.0,
                1.0,
                1.0,
                f64::NAN,
                &mut bg,
                &mut fg,
                &mut error
            ));
            crate::lyra_reader_desktop_buffer_free(error);
        }
        assert!(bg.pixels.data.is_null() && fg.pixels.data.is_null());
        assert_eq!(bg.width, 0);
        assert_eq!(fg.height, 0);
    }
}

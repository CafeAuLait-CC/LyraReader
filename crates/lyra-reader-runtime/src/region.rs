//! Exact, bounded region captures for native reading assistants. Unlike page backdrops,
//! an attachment refuses an oversized request instead of silently reducing its density.
use lyra_reader_core::{ErrorCode, LyraReaderError, Rect, Result};

pub const MINIMUM_SCALE: f64 = 2.0;
pub const MAXIMUM_EDGE: u32 = 4096;
pub const MAXIMUM_PIXELS: u32 = 4_000_000;
pub const MAXIMUM_PNG_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, Copy)]
pub struct CaptureSize {
    pub scale: f64,
    pub width: u32,
    pub height: u32,
}

fn invalid(message: &str) -> LyraReaderError {
    LyraReaderError::new(ErrorCode::InvalidArgument, message)
}

/// Validate every floating dimension before converting it or asking a renderer to allocate.
pub fn capture_size(rect: Rect, zoom: f64) -> Result<CaptureSize> {
    if ![
        rect.origin.x,
        rect.origin.y,
        rect.size.width,
        rect.size.height,
        zoom,
    ]
    .iter()
    .all(|v| v.is_finite())
        || rect.origin.x < 0.0
        || rect.origin.y < 0.0
        || rect.size.width < 3.0
        || rect.size.height < 3.0
        || zoom <= 0.0
        || !(rect.origin.x + rect.size.width).is_finite()
        || !(rect.origin.y + rect.size.height).is_finite()
    {
        return Err(invalid(
            "Select a finite region at least 3 points wide and high inside the page.",
        ));
    }
    let scale = zoom.max(MINIMUM_SCALE);
    let width = (rect.size.width * scale).ceil();
    let height = (rect.size.height * scale).ceil();
    if !width.is_finite()
        || !height.is_finite()
        || width < 1.0
        || height < 1.0
        || width > f64::from(MAXIMUM_EDGE)
        || height > f64::from(MAXIMUM_EDGE)
    {
        return Err(invalid(
            "This region exceeds the 4096-pixel edge bound at the selected zoom. Select a smaller area.",
        ));
    }
    // Both values have already been bounded to positive integers within u32.
    let (width, height) = (width as u32, height as u32);
    if width.checked_mul(height).is_none_or(|n| n > MAXIMUM_PIXELS) {
        return Err(invalid(
            "This region exceeds 4 megapixels at the selected zoom. Select a smaller area.",
        ));
    }
    Ok(CaptureSize {
        scale,
        width,
        height,
    })
}

/// Validate row padding and the complete backing slice before inspecting or encoding pixels.
pub fn bitmap_length(width: u32, height: u32, stride: u32) -> Result<usize> {
    let row = width
        .checked_mul(4)
        .ok_or_else(|| invalid("Invalid region row width."))?;
    let length = usize::try_from(stride)
        .ok()
        .and_then(|s| s.checked_mul(height as usize))
        .ok_or_else(|| invalid("Invalid region byte count."))?;
    if width == 0
        || height == 0
        || width > MAXIMUM_EDGE
        || height > MAXIMUM_EDGE
        || width.checked_mul(height).is_none_or(|n| n > MAXIMUM_PIXELS)
        || stride < row
        || length > MAXIMUM_PIXELS as usize * 4
    {
        return Err(invalid(
            "The region bitmap is invalid or exceeds its capture budget.",
        ));
    }
    Ok(length)
}

pub fn validate_bitmap(width: u32, height: u32, stride: u32, bytes: &[u8]) -> Result<usize> {
    let length = bitmap_length(width, height, stride)?;
    if bytes.len() < length {
        return Err(invalid("The region bitmap is truncated."));
    }
    Ok(length)
}

/// Sample original BGRA pixels, accounting for row padding. Blank paper has no attachment
/// when there is also no extracted text; lightly tinted artwork still counts as content.
pub fn is_blank(width: u32, height: u32, stride: u32, bytes: &[u8]) -> Result<bool> {
    validate_bitmap(width, height, stride, bytes)?;
    let count = width as usize * height as usize;
    let step = (count / 24_000).max(1);
    let mut dark = 0;
    let mut samples = 0;
    for i in (0..count).step_by(step) {
        let offset = (i / width as usize) * stride as usize + (i % width as usize) * 4;
        let pixel = &bytes[offset..offset + 4];
        let low = pixel[0].min(pixel[1]).min(pixel[2]);
        let high = pixel[0].max(pixel[1]).max(pixel[2]);
        if pixel[3] > 0 && (low < 232 || high - low > 12) {
            dark += 1;
        }
        samples += 1;
    }
    Ok(dark < (samples / 1000).max(3))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn captures_refuse_overflow_and_oversize_before_integer_conversion() {
        for rect in [
            Rect::new(f64::NAN, 0.0, 10.0, 10.0),
            Rect::new(0.0, 0.0, f64::MAX, 10.0),
            Rect::new(0.0, 0.0, 1000.1, 1000.0),
            Rect::new(0.0, 0.0, 2049.0, 3.0),
            Rect::new(-1.0, 0.0, 10.0, 10.0),
            Rect::new(0.0, 0.0, 2.0, 10.0),
        ] {
            assert!(capture_size(rect, 1.0).is_err());
        }
        for zoom in [f64::NAN, f64::INFINITY, 0.0, -1.0] {
            assert!(capture_size(Rect::new(0.0, 0.0, 10.0, 10.0), zoom).is_err());
        }
        let size = capture_size(Rect::new(0.0, 0.0, 1000.0, 1000.0), 1.0).unwrap();
        assert_eq!((size.width, size.height, size.scale), (2000, 2000, 2.0));
        assert_eq!(
            capture_size(Rect::new(0.0, 0.0, 10.25, 20.0), 3.0)
                .unwrap()
                .width,
            31
        );
    }
    #[test]
    fn pixel_inspection_rejects_truncation_and_counts_padded_rows_correctly() {
        assert!(validate_bitmap(u32::MAX, 2, u32::MAX, &[]).is_err());
        assert!(validate_bitmap(2, 2, 4, &[255; 16]).is_err());
        assert!(is_blank(2, 2, 8, &[255; 15]).is_err());
        let mut bytes = vec![255; 12 * 4];
        assert!(is_blank(2, 4, 12, &bytes).unwrap());
        for y in 0..4 {
            bytes[y * 12..y * 12 + 4].copy_from_slice(&[180, 230, 255, 255]);
        }
        assert!(!is_blank(2, 4, 12, &bytes).unwrap());
    }
}

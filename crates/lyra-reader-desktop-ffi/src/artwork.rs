//! Bounded PNG/JPEG artwork shared by sidecar adoption, PDF writing and native display.
use base64::{Engine as _, engine::general_purpose::STANDARD};
use image::{ImageFormat, ImageReader, Limits, imageops::FilterType};
use lyra_reader_ffi::api::AnnotationRecord;
use serde_json::{Value, json};
use std::io::Cursor;

pub const MAX_ENCODED_BYTES: usize = 8 * 1024 * 1024;
const MAX_SOURCE_PIXELS: u64 = 16 * 1024 * 1024;

pub fn encode(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

pub fn bytes(encoded: &str) -> Result<Vec<u8>, String> {
    if encoded.len() > MAX_ENCODED_BYTES.div_ceil(3) * 4 {
        return Err("Signature image exceeds the 8 MiB encoded-image limit".into());
    }
    let data = STANDARD
        .decode(encoded)
        .map_err(|_| "Invalid base64 signature image")?;
    if data.is_empty() || data.len() > MAX_ENCODED_BYTES {
        return Err("Signature image is empty or exceeds 8 MiB".into());
    }
    Ok(data)
}

/// Straight RGBA, top row first. Like macOS, the saved image is capped at 2048 px.
/// Reject unreasonable source dimensions before an image decoder allocates its bitmap.
fn information(data: &[u8]) -> Result<(ImageFormat, u32, u32), String> {
    let format = image::guess_format(data).map_err(|e| e.to_string())?;
    if !matches!(format, ImageFormat::Png | ImageFormat::Jpeg) {
        return Err("Choose a PNG or JPEG signature image".into());
    }
    let (width, height) = ImageReader::with_format(Cursor::new(data), format)
        .into_dimensions()
        .map_err(|e| e.to_string())?;
    if width == 0
        || height == 0
        || width > 8192
        || height > 8192
        || u64::from(width) * u64::from(height) > MAX_SOURCE_PIXELS
    {
        return Err("Signature image exceeds 8192 px on a side or 16 megapixels".into());
    }
    Ok((format, width, height))
}

pub fn dimensions(encoded: &str) -> Result<(u32, u32), String> {
    let (_, width, height) = information(&bytes(encoded)?)?;
    Ok((width, height))
}

pub fn pixels(encoded: &str) -> Result<(u32, u32, Vec<u8>), String> {
    let data = bytes(encoded)?;
    let (format, width, height) = information(&data)?;
    let mut reader = ImageReader::with_format(Cursor::new(data), format);
    let mut limits = Limits::default();
    limits.max_image_width = Some(8192);
    limits.max_image_height = Some(8192);
    limits.max_alloc = Some(128 * 1024 * 1024);
    reader.limits(limits);
    let decoded = reader.decode().map_err(|e| e.to_string())?;
    let decoded = if width.max(height) > 2048 {
        decoded.resize(2048, 2048, FilterType::Triangle)
    } else {
        decoded
    };
    let rgba = decoded.into_rgba8();
    Ok((rgba.width(), rgba.height(), rgba.into_raw()))
}

/// Images cross the thin JSON boundary as base64, matching the macOS sidecar Data
/// encoding. Never turn megabytes of image bytes into arrays of boxed JSON numbers.
pub fn annotations(records: Vec<AnnotationRecord>) -> Result<Value, String> {
    let mut budget = 32 * 1024 * 1024usize;
    let mut result = Vec::with_capacity(records.len());
    for mut record in records {
        let mut image = Vec::new();
        if let Some(stamp) = &mut record.stamp {
            image = std::mem::take(&mut stamp.image);
            if image.len() > MAX_ENCODED_BYTES || image.len() > budget {
                image.clear();
                stamp.image_error = Some("Stamp image exceeds the native preview budget".into());
                if stamp.text.as_deref().is_none_or(|s| s.trim().is_empty()) {
                    record.drawing = "skipped".into();
                    record.skip_reason = Some("stamp-image-unreadable".into());
                }
            } else {
                budget -= image.len();
            }
        }
        let mut value = serde_json::to_value(record).map_err(|e| e.to_string())?;
        if !value["stamp"].is_null() {
            value["stamp"]["image"] = json!(encode(&image));
        }
        result.push(value);
    }
    Ok(Value::Array(result))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ExtendedColorType, ImageEncoder};

    #[test]
    fn transparent_png_keeps_straight_alpha_and_jpeg_is_accepted() {
        let source = [220, 40, 10, 128, 0, 0, 0, 0];
        let mut png = Vec::new();
        image::codecs::png::PngEncoder::new(&mut png)
            .write_image(&source, 2, 1, ExtendedColorType::Rgba8)
            .unwrap();
        assert_eq!(pixels(&encode(&png)).unwrap(), (2, 1, source.to_vec()));
        let mut jpeg = Vec::new();
        image::codecs::jpeg::JpegEncoder::new(&mut jpeg)
            .encode(&[20, 40, 60], 1, 1, ExtendedColorType::Rgb8)
            .unwrap();
        let (w, h, rgba) = pixels(&encode(&jpeg)).unwrap();
        assert_eq!((w, h, rgba.len(), rgba[3]), (1, 1, 4, 255));
        assert!(pixels("aW52YWxpZA==").is_err());
        assert!(pixels("%%").is_err());
    }

    #[test]
    fn large_input_is_reduced_to_the_same_writer_edge_as_macos() {
        let mut png = Vec::new();
        image::codecs::png::PngEncoder::new(&mut png)
            .write_image(&vec![80; 4096 * 4], 4096, 1, ExtendedColorType::Rgba8)
            .unwrap();
        let (width, height, rgba) = pixels(&encode(&png)).unwrap();
        assert_eq!((width, height, rgba.len()), (2048, 1, 2048 * 4));
    }
}

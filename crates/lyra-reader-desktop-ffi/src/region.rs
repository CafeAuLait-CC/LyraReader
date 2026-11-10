//! The desktop's bounded image transport; text and request planning remain in shared engines.
use base64::{Engine as _, engine::general_purpose::STANDARD};
use image::{ExtendedColorType, ImageEncoder, codecs::png::PngEncoder};
use lyra_reader_core::Rect;
use lyra_reader_ffi::api::{AiPlanRequestRecord, AiRegionTextRecord, LyraReaderDocument};
use lyra_reader_runtime::region::{self, MAXIMUM_PNG_BYTES};
use lyra_reader_session::paper::{MAX_PAPER_GEOMETRY_ITEMS, TearFallback, plan_tear};
use serde_json::{Value, json};
use std::io::{self, Cursor, Write};

struct BoundedPng(Vec<u8>);
impl Write for BoundedPng {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let length = self
            .0
            .len()
            .checked_add(bytes.len())
            .filter(|n| *n <= MAXIMUM_PNG_BYTES)
            .ok_or_else(|| io::Error::other("Region PNG exceeds the 8 MiB attachment bound"))?;
        if length > self.0.capacity() {
            let target = (self.0.capacity().clamp(4096, MAXIMUM_PNG_BYTES / 2) * 2)
                .max(length)
                .min(MAXIMUM_PNG_BYTES);
            self.0
                .try_reserve_exact(target - self.0.len())
                .map_err(io::Error::other)?;
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

pub fn capture(
    document: &LyraReaderDocument,
    page: u32,
    page_height: Option<f64>,
    rect: Rect,
    zoom: f64,
    indexed_regions: &[Rect],
    glyphs: Option<&[Rect]>,
) -> Result<Value, String> {
    let spec = region::capture_size(rect, zoom).map_err(|e| e.to_string())?;
    let bitmap = document
        .rasterize_region(
            page,
            spec.scale,
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height,
            false,
        )
        .map_err(|e| e.to_string())?;
    region::validate_bitmap(
        bitmap.width_px,
        bitmap.height_px,
        bitmap.stride,
        &bitmap.pixels,
    )
    .map_err(|e| e.to_string())?;
    if bitmap.scale_used != spec.scale {
        return Err(
            "The region could not be captured at the requested density. Select a smaller area."
                .into(),
        );
    }
    let (text, text_warning) = match document.region_text(
        page,
        rect.origin.x,
        rect.origin.y,
        rect.size.width,
        rect.size.height,
    ) {
        Ok(text) => (text, None),
        Err(error) => (
            AiRegionTextRecord {
                text: String::new(),
                truncated: false,
            },
            Some(format!(
                "Region text could not be read. Only the image is available: {error}"
            )),
        ),
    };
    if text.text.is_empty()
        && region::is_blank(
            bitmap.width_px,
            bitmap.height_px,
            bitmap.stride,
            &bitmap.pixels,
        )
        .map_err(|e| e.to_string())?
    {
        return Err("That area is blank: it contains no text, picture or rule. Select a region with content.".into());
    }
    let length = bitmap.width_px as usize * bitmap.height_px as usize * 4;
    let mut rgba = Vec::new();
    rgba.try_reserve_exact(length)
        .map_err(|_| "Not enough memory to encode this region")?;
    for row in bitmap
        .pixels
        .chunks_exact(bitmap.stride as usize)
        .take(bitmap.height_px as usize)
    {
        for p in row[..bitmap.width_px as usize * 4].as_chunks::<4>().0 {
            rgba.extend_from_slice(&[p[2], p[1], p[0], p[3]]);
        }
    }
    let mut png = BoundedPng(Vec::new());
    PngEncoder::new(&mut png)
        .write_image(
            &rgba,
            bitmap.width_px,
            bitmap.height_px,
            ExtendedColorType::Rgba8,
        )
        .map_err(|e| e.to_string())?;
    let paper_plan = placement(
        page_height,
        rect,
        indexed_regions,
        glyphs,
        !text.text.trim().is_empty(),
    );
    Ok(
        json!({"page":page,"x_pt":rect.origin.x,"y_pt":rect.origin.y,"width_pt":rect.size.width,"height_pt":rect.size.height,
        "source_sha256":document.document_identity().sha256,"text":text.text,"text_truncated":text.truncated,"text_warning":text_warning,"image_png":STANDARD.encode(&png.0),
        "image_width_px":bitmap.width_px,"image_height_px":bitmap.height_px,"capture_scale":spec.scale,"paper_plan":paper_plan}),
    )
}

/// Placement consumes only the caller's current page snapshot. Missing glyph geometry is
/// an explicit row-foot fallback, never a reason to extract text again or finish an index.
fn placement(
    page_height: Option<f64>,
    selection: Rect,
    indexed_regions: &[Rect],
    glyphs: Option<&[Rect]>,
    selection_has_text: bool,
) -> Value {
    let Some(glyphs) = glyphs else {
        return json!({"split_pt":null,"fallback":"unavailable_page_text","warning":null});
    };
    match page_height {
        Some(height) => {
            let plan = plan_tear(
                height,
                selection,
                glyphs,
                indexed_regions,
                selection_has_text,
            );
            let fallback = plan.fallback.map(|reason| match reason {
                TearFallback::UnknownPageGeometry => "unknown_page_geometry",
                TearFallback::InvalidSelection => "invalid_selection",
                TearFallback::InvalidContentGeometry => "invalid_content_geometry",
                TearFallback::GeometryLimit => "geometry_limit",
                TearFallback::UnindexedArtwork => "unindexed_artwork",
            });
            json!({"split_pt":plan.split_pt,"fallback":fallback,"warning":null})
        }
        None => json!({"split_pt":null,"fallback":"unknown_page_geometry","warning":null}),
    }
}

pub struct PaperGeometry {
    pub indexed_regions: Vec<Rect>,
    pub glyphs: Option<Vec<Rect>>,
}

pub fn paper_geometry(request: &Value) -> Result<PaperGeometry, String> {
    let count = |key: &str| -> Result<usize, String> {
        match request.get(key) {
            None => Ok(0),
            Some(value) => value
                .as_array()
                .map(Vec::len)
                .ok_or_else(|| format!("Invalid {key} geometry array")),
        }
    };
    if count("glyphs")?
        .checked_add(count("indexed_regions")?)
        .is_none_or(|count| count > MAX_PAPER_GEOMETRY_ITEMS)
    {
        return Err("The paper geometry limit was exceeded".into());
    }
    Ok(PaperGeometry {
        indexed_regions: indexed_regions(request)?,
        glyphs: glyphs(request)?,
    })
}

fn indexed_regions(request: &Value) -> Result<Vec<Rect>, String> {
    let Some(value) = request.get("indexed_regions") else {
        return Ok(Vec::new());
    };
    geometry_array(value)
}

fn glyphs(request: &Value) -> Result<Option<Vec<Rect>>, String> {
    request.get("glyphs").map(geometry_array).transpose()
}

fn geometry_array(value: &Value) -> Result<Vec<Rect>, String> {
    let regions = value.as_array().ok_or("Paper geometry must be an array")?;
    if regions.len() > MAX_PAPER_GEOMETRY_ITEMS {
        return Err("The paper geometry limit was exceeded".into());
    }
    let mut result = Vec::new();
    result
        .try_reserve_exact(regions.len())
        .map_err(|_| "Paper geometry could not be allocated")?;
    for region in regions {
        let number = |key: &str| {
            region[key]
                .as_f64()
                .ok_or_else(|| format!("Invalid paper region {key}"))
        };
        let rect = Rect::new(
            number("x_pt")?,
            number("y_pt")?,
            number("width_pt")?,
            number("height_pt")?,
        );
        if ![
            rect.min_x(),
            rect.min_y(),
            rect.size.width,
            rect.size.height,
            rect.max_x(),
            rect.max_y(),
        ]
        .iter()
        .all(|value| value.is_finite())
            || rect.size.width < 0.0
            || rect.size.height < 0.0
        {
            return Err("Invalid paper region geometry".into());
        }
        result.push(rect);
    }
    Ok(result)
}

/// Decode bytes once, without materializing millions of JSON numeric values.
pub fn request(mut value: Value) -> Result<AiPlanRequestRecord, String> {
    let encoded = value
        .get_mut("region")
        .and_then(|r| r.get_mut("image_png"))
        .map(Value::take);
    let mut request: AiPlanRequestRecord =
        serde_json::from_value(value).map_err(|e| format!("Invalid request: {e}"))?;
    if let Some(encoded) = encoded.filter(|v| !v.is_null()) {
        let text = encoded
            .as_str()
            .ok_or("The region picture must use bounded base64 transport")?;
        if text.len() > MAXIMUM_PNG_BYTES.div_ceil(3) * 4 {
            return Err("The region picture exceeds 8 MiB".into());
        }
        let bytes = STANDARD
            .decode(text)
            .map_err(|_| "Invalid region picture encoding")?;
        if bytes.is_empty() || bytes.len() > MAXIMUM_PNG_BYTES {
            return Err("The region picture is empty or exceeds 8 MiB".into());
        }
        let mut reader =
            image::ImageReader::with_format(Cursor::new(&bytes), image::ImageFormat::Png);
        let mut limits = image::Limits::default();
        limits.max_image_width = Some(region::MAXIMUM_EDGE);
        limits.max_image_height = Some(region::MAXIMUM_EDGE);
        limits.max_alloc = Some(u64::from(region::MAXIMUM_PIXELS) * 4);
        reader.limits(limits);
        let (width, height) = reader
            .into_dimensions()
            .map_err(|_| "The region picture is not a readable PNG")?;
        region::bitmap_length(
            width,
            height,
            width.checked_mul(4).ok_or("Invalid region picture width")?,
        )
        .map_err(|e| e.to_string())?;
        let region = request.region.as_mut().ok_or("Missing region attachment")?;
        if region.image_width_px != Some(width) || region.image_height_px != Some(height) {
            return Err("The region picture dimensions do not match its preview".into());
        }
        region.image_png = Some(bytes);
    }
    Ok(request)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn indexed_geometry_is_bounded_and_rejects_malformed_values_before_capture() {
        assert!(indexed_regions(&json!({})).unwrap().is_empty());
        let valid = json!({"indexed_regions":[{"x_pt":1,"y_pt":2,"width_pt":3,"height_pt":4}]});
        assert_eq!(
            indexed_regions(&valid).unwrap(),
            [Rect::new(1.0, 2.0, 3.0, 4.0)]
        );
        for invalid in [
            json!({"indexed_regions":null}),
            json!({"indexed_regions":[{}]}),
            json!({"indexed_regions":[{"x_pt":1e308,"y_pt":0,"width_pt":1e308,"height_pt":4}]}),
            json!({"indexed_regions":[{"x_pt":1,"y_pt":2,"width_pt":-3,"height_pt":4}]}),
        ] {
            assert!(indexed_regions(&invalid).is_err());
        }
        let oversized = json!({"indexed_regions":vec![Value::Null;MAX_PAPER_GEOMETRY_ITEMS+1]});
        assert!(indexed_regions(&oversized).unwrap_err().contains("limit"));
        // Invalid elements intentionally prove that total-count rejection precedes decoding.
        let combined =
            json!({"glyphs":vec![Value::Null;MAX_PAPER_GEOMETRY_ITEMS],"indexed_regions":[null]});
        assert!(paper_geometry(&combined).err().unwrap().contains("limit"));
        assert!(paper_geometry(&json!({})).unwrap().glyphs.is_none());
        assert_eq!(
            paper_geometry(&json!({"glyphs":[]})).unwrap().glyphs,
            Some(Vec::new())
        );
    }
    #[test]
    fn encoded_output_stops_at_the_bound_without_growing_the_buffer() {
        let mut sink = BoundedPng(vec![0; MAXIMUM_PNG_BYTES - 1]);
        assert!(sink.write_all(&[1, 2]).is_err());
        assert_eq!(sink.0.len(), MAXIMUM_PNG_BYTES - 1);
        let mut sink = BoundedPng(Vec::new());
        for _ in 0..4096 {
            sink.write_all(&[0; 1024]).unwrap();
        }
        assert!(sink.0.capacity() <= MAXIMUM_PNG_BYTES);
    }
    #[test]
    fn request_images_decode_once_and_match_the_declared_pixel_size() {
        let mut png = Vec::new();
        PngEncoder::new(&mut png)
            .write_image(&[180; 6 * 6 * 4], 6, 6, ExtendedColorType::Rgba8)
            .unwrap();
        let input = json!({"action":"RegionQuestion","document_knowledge":false,"document_knowledge_text":null,"document_knowledge_pages":[],
            "current_page":0,"selection":null,"question":"A synthetic question","language":null,"history":[],
            "base_url":"http://localhost:11434/v1","model":"fixture","temperature":null,"max_tokens":null,"reasoning_mode":"default","reasoning_encoding":"none",
            "region":{"page":0,"x_pt":0,"y_pt":0,"width_pt":3,"height_pt":3,"text":"","image_png":STANDARD.encode(&png),"image_width_px":6,"image_height_px":6,"send_image":true,"include_document_context":false}});
        assert_eq!(
            request(input.clone())
                .unwrap()
                .region
                .unwrap()
                .image_png
                .unwrap(),
            png
        );
        let mut wrong = input.clone();
        wrong["region"]["image_width_px"] = json!(7);
        assert!(request(wrong).is_err());
        let mut wrong = input.clone();
        wrong["region"]["image_png"] = json!([1, 2, 3]);
        assert!(request(wrong).is_err());
        let mut wrong = input.clone();
        wrong["region"]["image_png"] = json!("not PNG");
        assert!(request(wrong).is_err());
        let mut wrong = input;
        wrong["region"]["image_png"] = json!("a".repeat(MAXIMUM_PNG_BYTES.div_ceil(3) * 4 + 1));
        assert!(request(wrong).is_err());
    }
}

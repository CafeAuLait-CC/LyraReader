//! The `/AP /N` stream written for a text-markup annotation.
//!
//! A text mark used to be written with `/QuadPoints`, `/C` and `/CA` but no appearance stream, so
//! every viewer synthesised its own. The writer now paints the same mark this reader's canvas
//! paints. These tests are the save boundary, not the generator: they reopen the saved file with
//! PDFium and compare the pixels PDFium derives from `/AP` against an independent rasterisation
//! of the canvas model, then check the dictionary a reader sees and that flattening still bakes
//! the mark.

use lopdf::{Dictionary, Document, Stream};
use lyra_reader_core::{
    AnnotationAlignment, AnnotationBlend, DocumentBackend, PageIndex, RasterRequest, RasterTile,
    RawAnnotationKind, Rect,
};
use lyra_reader_pdfium::{
    AnnotationChanges, AnnotationReader, PdfiumBackend, SaveMode, WriteAnnotation,
    WriteAnnotationKind, flatten_to_copy, is_available, save_annotated_pdf,
    save_annotation_changes,
};
use std::path::{Path, PathBuf};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures")
        .join(name)
}

struct Scratch(PathBuf);

impl Scratch {
    fn new(label: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "lyra-markup-appearance-{label}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        std::fs::create_dir_all(&path).expect("scratch directory");
        Self(path)
    }

    fn join(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn markup(
    id: &str,
    kind: WriteAnnotationKind,
    quads: Vec<Rect>,
    color: [u8; 3],
    opacity: f64,
) -> WriteAnnotation {
    let mut rect = quads[0];
    for quad in &quads[1..] {
        rect = rect.union(*quad);
    }
    WriteAnnotation {
        id: id.to_string(),
        page: PageIndex(0),
        kind,
        rect,
        quads,
        ink_paths: Vec::new(),
        line: None,
        line_arrow: false,
        stamp_style: None,
        stamp_image: None,
        border_width: 0.0,
        font_size: 0.0,
        alignment: AnnotationAlignment::Left,
        color,
        opacity,
        contents: Some(format!("{id} comment")),
        author: Some("Markup appearance test".to_string()),
        modified: Some("D:20261024200000Z".to_string()),
    }
}

fn kinds() -> Vec<WriteAnnotation> {
    vec![
        markup(
            "highlight",
            WriteAnnotationKind::Highlight,
            vec![
                Rect::new(72.0, 686.0, 388.0, 15.0),
                Rect::new(72.0, 671.0, 300.0, 15.0),
            ],
            [255, 216, 64],
            0.4,
        ),
        markup(
            "underline",
            WriteAnnotationKind::Underline,
            vec![Rect::new(72.0, 641.0, 388.0, 15.0)],
            [220, 40, 40],
            0.85,
        ),
        markup(
            "strikeout",
            WriteAnnotationKind::StrikeOut,
            vec![Rect::new(72.0, 596.0, 388.0, 15.0)],
            [30, 90, 200],
            0.8,
        ),
        markup(
            "squiggly",
            WriteAnnotationKind::Squiggly,
            vec![Rect::new(72.0, 551.0, 388.0, 15.0)],
            [80, 180, 60],
            0.75,
        ),
    ]
}

fn raw_kind(kind: WriteAnnotationKind) -> RawAnnotationKind {
    match kind {
        WriteAnnotationKind::Highlight => RawAnnotationKind::Highlight,
        WriteAnnotationKind::Underline => RawAnnotationKind::Underline,
        WriteAnnotationKind::StrikeOut => RawAnnotationKind::Strikeout,
        WriteAnnotationKind::Squiggly => RawAnnotationKind::Squiggly,
        _ => unreachable!("only markup kinds are compared here"),
    }
}

fn expected_blend(kind: WriteAnnotationKind) -> AnnotationBlend {
    match kind {
        WriteAnnotationKind::Highlight
        | WriteAnnotationKind::Underline
        | WriteAnnotationKind::StrikeOut => AnnotationBlend::Multiply,
        WriteAnnotationKind::Squiggly => AnnotationBlend::Normal,
        _ => unreachable!("only markup kinds are compared here"),
    }
}

fn annotation_dictionary<'a>(document: &'a Document, name: &str) -> &'a Dictionary {
    for (_, page_id) in document.get_pages() {
        let page = document.get_dictionary(page_id).expect("page dictionary");
        let Some(annots) = page.get(b"Annots").ok().and_then(|object| {
            document
                .dereference(object)
                .ok()
                .and_then(|(_, object)| object.as_array().ok())
        }) else {
            continue;
        };
        for object in annots {
            let Some(dictionary) = document
                .dereference(object)
                .ok()
                .and_then(|(_, object)| object.as_dict().ok())
            else {
                continue;
            };
            if dictionary
                .get(b"NM")
                .ok()
                .and_then(|object| document.dereference(object).ok())
                .and_then(|(_, object)| object.as_str().ok())
                .is_some_and(|bytes| bytes == name.as_bytes())
            {
                return dictionary;
            }
        }
    }
    panic!("annotation {name:?} is missing");
}

fn appearance<'a>(document: &'a Document, dictionary: &'a Dictionary) -> &'a Stream {
    let appearance = dictionary
        .get(b"AP")
        .ok()
        .and_then(|object| document.dereference(object).ok())
        .and_then(|(_, object)| object.as_dict().ok())
        .and_then(|ap| ap.get(b"N").ok())
        .and_then(|object| document.dereference(object).ok())
        .and_then(|(_, object)| object.as_stream().ok())
        .expect("a written markup annotation has /AP /N");
    assert!(!appearance.content.is_empty());
    appearance
}

fn state<'a>(document: &'a Document, stream: &'a Stream) -> &'a Dictionary {
    stream
        .dict
        .get(b"Resources")
        .ok()
        .and_then(|object| document.dereference(object).ok())
        .and_then(|(_, object)| object.as_dict().ok())
        .and_then(|resources| resources.get(b"ExtGState").ok())
        .and_then(|object| document.dereference(object).ok())
        .and_then(|(_, object)| object.as_dict().ok())
        .and_then(|states| states.get(b"GS0").ok())
        .and_then(|object| document.dereference(object).ok())
        .and_then(|(_, object)| object.as_dict().ok())
        .expect("the appearance paints through /GS0")
}

#[test]
fn a_written_markups_appearance_is_the_canvas_mark() {
    if !is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let scratch = Scratch::new("write");
    let source = fixture("text-page.pdf");
    let destination = scratch.join("marked.pdf");
    let annotations = kinds();
    let report = save_annotated_pdf(
        &source,
        &destination,
        &annotations,
        &[],
        None,
        SaveMode::Copy,
    )
    .expect("save four text marks");
    assert_eq!(report.written_ids.len(), 4);
    assert!(report.source_bytes_preserved);

    // ── The dictionary: geometry, colour and opacity are the request's, and /AP is real. ──
    let document = Document::load(&destination).expect("parse saved document");
    for expected in &annotations {
        let dictionary = annotation_dictionary(&document, &expected.id);
        let stream = appearance(&document, dictionary);
        let bbox: Vec<f64> = stream
            .dict
            .get(b"BBox")
            .expect("BBox")
            .as_array()
            .expect("BBox array")
            .iter()
            .map(|object| object.as_float().expect("BBox number") as f64)
            .collect();
        assert_eq!(
            bbox,
            vec![
                expected.rect.min_x(),
                expected.rect.min_y(),
                expected.rect.max_x(),
                expected.rect.max_y()
            ],
            "{}: the appearance BBox is the annotation's /Rect",
            expected.id
        );
        let quads: Vec<f32> = dictionary
            .get(b"QuadPoints")
            .expect("QuadPoints")
            .as_array()
            .expect("QuadPoints array")
            .iter()
            .map(|object| object.as_float().expect("quad number"))
            .collect();
        assert_eq!(quads.len(), expected.quads.len() * 8);
        for (index, quad) in expected.quads.iter().enumerate() {
            let slice = &quads[index * 8..(index + 1) * 8];
            assert_eq!(
                slice,
                &[
                    quad.min_x() as f32,
                    quad.max_y() as f32,
                    quad.max_x() as f32,
                    quad.max_y() as f32,
                    quad.min_x() as f32,
                    quad.min_y() as f32,
                    quad.max_x() as f32,
                    quad.min_y() as f32,
                ],
                "{}: quad {index} is in the standard order",
                expected.id
            );
        }
        let colour: Vec<f32> = dictionary
            .get(b"C")
            .expect("C")
            .as_array()
            .expect("colour array")
            .iter()
            .map(|object| object.as_float().expect("colour number"))
            .collect();
        for (channel, expected) in colour.iter().zip(expected.color) {
            assert!((channel * 255.0 - f32::from(expected)).abs() <= 0.5);
        }
        let opacity = dictionary
            .get(b"CA")
            .expect("CA")
            .as_float()
            .expect("opacity number");
        assert!((f64::from(opacity) - expected.opacity).abs() <= 1.0 / 255.0);
        let state = state(&document, stream);
        let blend = state
            .get(b"BM")
            .expect("the appearance states its blend")
            .as_name()
            .expect("blend name");
        assert_eq!(
            blend,
            match expected_blend(expected.kind) {
                AnnotationBlend::Multiply => b"Multiply".as_slice(),
                AnnotationBlend::Normal => b"Normal".as_slice(),
                _ => unreachable!(),
            },
            "{}: the appearance blends like the canvas",
            expected.id
        );
        let alpha = state.get(b"ca").expect("ca").as_float().expect("ca number");
        assert!((f64::from(alpha) - expected.opacity).abs() <= 1.0 / 255.0);
        let content = String::from_utf8_lossy(&stream.content);
        assert!(content.contains("/GS0 gs"), "{}: {content}", expected.id);
        assert!(content.contains(" re f"), "{}: {content}", expected.id);
    }

    // ── Reopening: the colour, opacity, blend and geometry a reader sees are unchanged. ──
    let reader = AnnotationReader::open(&destination, None).expect("open saved annotations");
    let records = reader.page(PageIndex(0)).expect("read page");
    assert_eq!(records.len(), 4, "exactly the four written marks");
    for expected in &annotations {
        let record = records
            .iter()
            .find(|record| record.id == format!("nm:{}", expected.id))
            .unwrap_or_else(|| panic!("{} is in the saved file", expected.id));
        assert_eq!(record.kind, raw_kind(expected.kind));
        assert_eq!(record.rect, expected.rect);
        assert_eq!(record.quads, expected.quads);
        let colour = record.color.expect("the file states /C");
        assert_eq!([colour.red, colour.green, colour.blue], expected.color);
        assert!((record.opacity.expect("opacity") - expected.opacity).abs() <= 1.0 / 255.0);
        assert_eq!(record.blend, expected_blend(expected.kind));
    }

    // ── Pixels: PDFium paints the appearance; the reference paints the canvas model. ──
    let backend = PdfiumBackend::open(&destination, None).expect("open saved file");
    let info = backend.page_info(PageIndex(0)).expect("page info");
    let page_height = info.geometry.crop_box.size.height;
    let scale = 2.0;
    let mut plain = RasterRequest::full_page(PageIndex(0), scale);
    plain.flags.annotations = false;
    let baseline = backend
        .rasterize(&plain)
        .expect("render without annotations");
    let mut annotated_request = plain;
    annotated_request.flags.annotations = true;
    let annotated = backend
        .rasterize(&annotated_request)
        .expect("render with annotations");

    for expected in &annotations {
        let report = compare_canvas_model(&baseline, &annotated, page_height, scale, expected);
        assert!(
            report.full_pixels > 200,
            "{}: the mark covers real pixels",
            expected.id
        );
        assert_eq!(
            report.mismatched_full, 0,
            "{}: every fully covered pixel is the canvas model's: {report}",
            expected.id
        );
        assert_eq!(
            report.mismatched_clear, 0,
            "{}: no paint outside the mark: {report}",
            expected.id
        );
    }

    // ── Flattening: the now-present appearance is what a flattened copy bakes. ──
    let flattened = scratch.join("flattened.pdf");
    flatten_to_copy(&destination, &flattened, None).expect("flatten the copy");
    let flat = PdfiumBackend::open(&flattened, None).expect("open flattened copy");
    let mut flat_request = RasterRequest::full_page(PageIndex(0), scale);
    flat_request.flags.annotations = true;
    let flattened_pixels = flat
        .rasterize(&flat_request)
        .expect("render flattened page");
    assert!(
        flat.annotations(PageIndex(0))
            .expect("flattened annotations")
            .is_empty(),
        "flattening removes the annotation objects"
    );
    for expected in &annotations {
        let mut compared = 0usize;
        for (x, y) in region_pixels(page_height, scale, expected) {
            let before = pixel(&baseline, x, y);
            let marked = pixel(&annotated, x, y);
            if before == marked {
                continue;
            }
            let flat_pixel = pixel(&flattened_pixels, x, y);
            let distance = channel_delta(marked, flat_pixel);
            assert!(
                distance <= 2,
                "{}: flattened pixel ({x},{y}) is {flat_pixel:?}, appearance {marked:?}",
                expected.id
            );
            compared += 1;
        }
        assert!(
            compared > 100,
            "{}: the flattened copy bakes the mark ({compared} pixels)",
            expected.id
        );
    }
}

/// How many pixels the reference and PDFium disagree on.
#[derive(Debug, Default)]
struct PixelReport {
    full_pixels: usize,
    clear_pixels: usize,
    mismatched_full: usize,
    mismatched_clear: usize,
    max_delta: i32,
}

impl std::fmt::Display for PixelReport {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "full={} clear={} mismatch_full={} mismatch_clear={} max_delta={}",
            self.full_pixels,
            self.clear_pixels,
            self.mismatched_full,
            self.mismatched_clear,
            self.max_delta
        )
    }
}

/// Anti-aliasing tolerance: pixels whose coverage is fractional are the edge, not the model.
const EDGE_LOW: f64 = 0.03;
const EDGE_HIGH: f64 = 0.97;
/// Channel tolerance for fully covered and fully clear pixels.
const CHANNEL_TOLERANCE: i32 = 4;

fn compare_canvas_model(
    baseline: &RasterTile,
    annotated: &RasterTile,
    page_height: f64,
    scale: f64,
    annotation: &WriteAnnotation,
) -> PixelReport {
    let mut report = PixelReport::default();
    for (x, y) in region_pixels(page_height, scale, annotation) {
        let coverage = coverage_at(annotation, page_height, scale, x, y);
        let background = pixel(baseline, x, y);
        let painted = pixel(annotated, x, y);
        if coverage >= EDGE_HIGH {
            let expected = expected_pixel(background, annotation, 1.0);
            let delta = channel_delta(expected, painted);
            report.full_pixels += 1;
            report.max_delta = report.max_delta.max(delta);
            if delta > CHANNEL_TOLERANCE {
                report.mismatched_full += 1;
            }
        } else if coverage <= EDGE_LOW {
            // The mark does not reach this pixel. The annotation pass must leave it alone.
            report.clear_pixels += 1;
            if painted != background {
                report.mismatched_clear += 1;
            }
        }
    }
    report
}

fn expected_pixel(background: [u8; 4], annotation: &WriteAnnotation, coverage: f64) -> [u8; 4] {
    let alpha = annotation.opacity.clamp(0.0, 1.0) * coverage;
    let blend = expected_blend(annotation.kind);
    let mut out = [0u8; 4];
    // Raster pixels are BGRA; the annotation colour is RGB.
    let colour = [
        annotation.color[2],
        annotation.color[1],
        annotation.color[0],
    ];
    for (channel, (back, colour)) in background.iter().zip(colour).take(3).enumerate() {
        let back = f64::from(*back);
        let colour = f64::from(colour) / 255.0;
        let value = match blend {
            AnnotationBlend::Multiply => back * (1.0 - alpha + alpha * colour),
            _ => back * (1.0 - alpha) + 255.0 * colour * alpha,
        };
        out[channel] = value.round().clamp(0.0, 255.0) as u8;
    }
    out[3] = 255;
    out
}

fn channel_delta(left: [u8; 4], right: [u8; 4]) -> i32 {
    left.iter()
        .take(3)
        .zip(right)
        .map(|(a, b)| (i32::from(*a) - i32::from(b)).abs())
        .max()
        .unwrap_or(0)
}

/// Every device pixel whose centre could be inside one of the annotation's boxes, plus a margin.
fn region_pixels(
    page_height: f64,
    scale: f64,
    annotation: &WriteAnnotation,
) -> Vec<(usize, usize)> {
    let mut pixels = Vec::new();
    for quad in &annotation.quads {
        let view_top = page_height - (quad.origin.y + quad.size.height);
        let x0 = ((quad.origin.x - 1.0) * scale).floor().max(0.0) as usize;
        let x1 = (((quad.origin.x + quad.size.width) * scale).ceil() + 1.0).max(0.0) as usize;
        let y0 = ((view_top - 1.0) * scale).floor().max(0.0) as usize;
        let y1 = (((view_top + quad.size.height) * scale).ceil() + 1.0).max(0.0) as usize;
        for y in y0..y1 {
            for x in x0..x1 {
                pixels.push((x, y));
            }
        }
    }
    pixels
}

/// Supersampled coverage of the mark at one device pixel: 4×4 samples.
fn coverage_at(
    annotation: &WriteAnnotation,
    page_height: f64,
    scale: f64,
    x: usize,
    y: usize,
) -> f64 {
    const SAMPLES: usize = 4;
    let mut inside = 0;
    for sample_y in 0..SAMPLES {
        for sample_x in 0..SAMPLES {
            let view_x = (x as f64 + (sample_x as f64 + 0.5) / SAMPLES as f64) / scale;
            let view_y = (y as f64 + (sample_y as f64 + 0.5) / SAMPLES as f64) / scale;
            let page_y = page_height - view_y;
            if annotation
                .quads
                .iter()
                .any(|quad| inside_quad(annotation.kind, *quad, view_x, page_y))
            {
                inside += 1;
            }
        }
    }
    inside as f64 / (SAMPLES * SAMPLES) as f64
}

fn inside_quad(kind: WriteAnnotationKind, quad: Rect, x: f64, y: f64) -> bool {
    if x < quad.min_x() || x > quad.max_x() {
        return false;
    }
    if kind == WriteAnnotationKind::Highlight {
        return y >= quad.min_y() && y <= quad.max_y();
    }
    let height = quad.size.height;
    let (scale, offset) = match kind {
        WriteAnnotationKind::Underline => (0.10, 0.90),
        WriteAnnotationKind::StrikeOut => (0.12, 0.45),
        WriteAnnotationKind::Squiggly => (0.12, 0.85),
        _ => (1.0, 0.0),
    };
    let band_top = quad.max_y() - height * offset;
    let band_bottom = band_top - (height * scale).max(1.0);
    y >= band_bottom && y <= band_top
}

fn pixel(tile: &RasterTile, x: usize, y: usize) -> [u8; 4] {
    let offset = y * tile.stride + x * 4;
    [
        tile.pixels[offset],
        tile.pixels[offset + 1],
        tile.pixels[offset + 2],
        tile.pixels[offset + 3],
    ]
}

fn ap_reference(document: &Document, dictionary: &Dictionary) -> lopdf::ObjectId {
    dictionary
        .get(b"AP")
        .ok()
        .and_then(|object| document.dereference(object).ok())
        .and_then(|(_, object)| object.as_dict().ok())
        .and_then(|ap| ap.get(b"N").ok())
        .and_then(|object| object.as_reference().ok())
        .expect("/AP /N is an indirect stream")
}

fn ap_stream(document: &Document, reference: lopdf::ObjectId) -> &Stream {
    document
        .get_object(reference)
        .expect("appearance object")
        .as_stream()
        .expect("appearance stream")
}

fn update_from(
    record: &lyra_reader_core::RawAnnotation,
    contents: &str,
    color: [u8; 3],
    opacity: f64,
) -> lyra_reader_pdfium::AnnotationUpdate {
    let kind = match record.kind {
        RawAnnotationKind::Highlight => WriteAnnotationKind::Highlight,
        RawAnnotationKind::Underline => WriteAnnotationKind::Underline,
        RawAnnotationKind::Strikeout => WriteAnnotationKind::StrikeOut,
        RawAnnotationKind::Squiggly => WriteAnnotationKind::Squiggly,
        ref other => panic!("no update model for {other:?}"),
    };
    lyra_reader_pdfium::AnnotationUpdate {
        target: record.id.clone(),
        assign_name: None,
        values: WriteAnnotation {
            id: format!("edit-{}", record.id),
            page: record.page,
            kind,
            rect: record.rect,
            quads: record.quads.clone(),
            ink_paths: Vec::new(),
            line: None,
            line_arrow: false,
            stamp_style: None,
            stamp_image: None,
            border_width: 0.0,
            font_size: 0.0,
            alignment: AnnotationAlignment::Left,
            color,
            opacity,
            contents: Some(contents.to_string()),
            author: record.author.clone(),
            modified: record.modified.clone(),
        },
    }
}

#[test]
fn a_foreign_appearance_is_kept_until_a_visual_edit_must_replace_it() {
    if !is_available() {
        eprintln!("skipping: PDFium unavailable");
        return;
    }
    let scratch = Scratch::new("foreign");
    let source = scratch.join("foreign.pdf");
    std::fs::copy(fixture("annotated-appearance.pdf"), &source).expect("copy fixture");
    // Give the two marks the reader would edit a stable name, and a producer key this writer
    // does not model. Everything an edit does not own must survive.
    let mut injected = Document::load(&source).expect("load fixture");
    for (name, flag) in [("foreign-highlight", 17), ("foreign-squiggly", 23)] {
        let id = {
            let mut found = None;
            for (_, page_id) in injected.get_pages() {
                let page = injected.get_dictionary(page_id).expect("page");
                let Some(annots) = page
                    .get(b"Annots")
                    .ok()
                    .and_then(|object| injected.dereference(object).ok())
                    .and_then(|(_, object)| object.as_array().ok())
                else {
                    continue;
                };
                for object in annots {
                    let Some((Some(id), dictionary)) = injected
                        .dereference(object)
                        .ok()
                        .and_then(|(id, object)| object.as_dict().ok().map(|dict| (id, dict)))
                    else {
                        continue;
                    };
                    let label = dictionary
                        .get(b"Contents")
                        .ok()
                        .and_then(|object| injected.dereference(object).ok())
                        .and_then(|(_, object)| object.as_str().ok())
                        .map(String::from_utf8_lossy)
                        .unwrap_or_default();
                    if (name == "foreign-highlight" && label.starts_with("Preview's highlight"))
                        || (name == "foreign-squiggly" && label.starts_with("Squiggly with"))
                    {
                        found = Some(id);
                    }
                }
            }
            found.expect("annotation to name")
        };
        let dictionary = injected
            .get_object_mut(id)
            .expect("annotation object")
            .as_dict_mut()
            .expect("annotation dictionary");
        dictionary.set("NM", lopdf::Object::string_literal(name));
        dictionary.set("VendorFlag", lopdf::Object::Integer(flag));
    }
    injected.save(&source).expect("save named fixture");

    let before = Document::load(&source).expect("parse named fixture");
    let underline_id = {
        // The underline has no name; it is the second annotation on page one.
        let page_id = before.get_pages()[&1];
        let page = before.get_dictionary(page_id).expect("page");
        let annots = page
            .get(b"Annots")
            .expect("Annots")
            .as_array()
            .expect("Annots array");
        annots[1].as_reference().expect("indirect annotation")
    };
    let highlight_ap = ap_reference(&before, annotation_dictionary(&before, "foreign-highlight"));
    let squiggly_ap = ap_reference(&before, annotation_dictionary(&before, "foreign-squiggly"));
    let underline_ap = ap_reference(
        &before,
        before
            .get_object(underline_id)
            .expect("underline")
            .as_dict()
            .expect("underline dictionary"),
    );
    let highlight_stream = ap_stream(&before, highlight_ap).content.clone();
    let underline_stream = ap_stream(&before, underline_ap).content.clone();

    let reader = AnnotationReader::open(&source, None).expect("read foreign annotations");
    let records = reader.page(PageIndex(0)).expect("page");
    let highlight = records
        .iter()
        .find(|record| record.id == "nm:foreign-highlight")
        .expect("named highlight");
    let squiggly = records
        .iter()
        .find(|record| record.id == "nm:foreign-squiggly")
        .expect("named squiggly");
    let highlight_quads = highlight.quads.clone();
    let squiggly_quads = squiggly.quads.clone();

    // ── A comment-only edit keeps the producer's stream byte for byte. ──
    let comment_only = scratch.join("comment-only.pdf");
    save_annotation_changes(
        &source,
        &comment_only,
        &AnnotationChanges {
            additions: Vec::new(),
            updates: vec![update_from(
                highlight,
                "A rewritten comment on the same mark.",
                [255, 255, 0],
                highlight.opacity.expect("source opacity"),
            )],
            deletions: Vec::new(),
        },
        &[],
        None,
        SaveMode::Copy,
    )
    .expect("save a comment-only edit");
    let after = Document::load(&comment_only).expect("parse comment-only save");
    let after_highlight = annotation_dictionary(&after, "foreign-highlight");
    assert_eq!(
        ap_reference(&after, after_highlight),
        highlight_ap,
        "a comment-only edit does not replace a foreign appearance"
    );
    assert_eq!(
        ap_stream(&after, highlight_ap).content,
        highlight_stream,
        "the producer's stream is untouched"
    );
    assert_eq!(
        after_highlight
            .get(b"VendorFlag")
            .expect("VendorFlag")
            .as_i64()
            .expect("integer"),
        17,
        "a key this writer does not model survives the edit"
    );
    let untouched = after
        .get_object(underline_id)
        .expect("underline")
        .as_dict()
        .expect("underline dictionary");
    assert_eq!(
        ap_reference(&after, untouched),
        underline_ap,
        "an annotation the edit did not name keeps its appearance"
    );
    assert_eq!(ap_stream(&after, underline_ap).content, underline_stream);

    // ── A visual edit replaces /AP /N, but only /AP /N: geometry, producer keys and other
    //    annotations are untouched, and the new stream states the new colour/opacity/blend. ──
    let visual = scratch.join("visual.pdf");
    save_annotation_changes(
        &source,
        &visual,
        &AnnotationChanges {
            additions: Vec::new(),
            updates: vec![update_from(
                highlight,
                "A recoloured mark.",
                [200, 30, 30],
                0.6,
            )],
            deletions: Vec::new(),
        },
        &[],
        None,
        SaveMode::Copy,
    )
    .expect("save a recoloured mark");
    let after = Document::load(&visual).expect("parse visual save");
    let after_highlight = annotation_dictionary(&after, "foreign-highlight");
    let new_ap = ap_reference(&after, after_highlight);
    assert_ne!(
        new_ap, highlight_ap,
        "a colour change writes a fresh appearance stream"
    );
    let new_stream = ap_stream(&after, new_ap);
    let graphics_state = state(&after, new_stream);
    assert_eq!(
        graphics_state
            .get(b"BM")
            .expect("BM")
            .as_name()
            .expect("name"),
        b"Multiply"
    );
    assert!(
        (graphics_state
            .get(b"ca")
            .expect("ca")
            .as_float()
            .expect("ca")
            - 0.6)
            .abs()
            < 1.0 / 255.0
    );
    let content = String::from_utf8_lossy(&new_stream.content);
    let colour: Vec<f64> = content
        .split_whitespace()
        .filter_map(|token| token.parse::<f64>().ok())
        .take(3)
        .collect();
    assert_eq!(colour.len(), 3, "{content}");
    for (value, expected) in colour.iter().zip([200.0, 30.0, 30.0]) {
        assert!((value * 255.0 - expected).abs() <= 1.0);
    }
    assert_eq!(
        after_highlight
            .get(b"VendorFlag")
            .expect("VendorFlag")
            .as_i64()
            .expect("integer"),
        17
    );
    assert_eq!(
        ap_reference(&after, annotation_dictionary(&after, "foreign-squiggly")),
        squiggly_ap,
        "an edit to the highlight does not touch the squiggly's appearance"
    );
    let reopened = AnnotationReader::open(&visual, None).expect("reopen the recoloured save");
    let record = reopened
        .page(PageIndex(0))
        .expect("page")
        .into_iter()
        .find(|record| record.id == "nm:foreign-highlight")
        .expect("recoloured highlight");
    assert_eq!(
        record
            .color
            .map(|colour| [colour.red, colour.green, colour.blue]),
        Some([200, 30, 30])
    );
    assert!((record.opacity.expect("opacity") - 0.6).abs() <= 1.0 / 255.0);
    assert_eq!(record.blend, AnnotationBlend::Multiply);
    assert_eq!(record.quads, highlight_quads, "the file's geometry is kept");
    assert!(
        !ap_stream(
            &after,
            ap_reference(&after, annotation_dictionary(&after, "foreign-highlight"))
        )
        .content
        .is_empty()
    );

    // ── A squiggly edit uses its own blend (alpha-over) and keeps its geometry. ──
    let squiggly_save = scratch.join("squiggly.pdf");
    save_annotation_changes(
        &source,
        &squiggly_save,
        &AnnotationChanges {
            additions: Vec::new(),
            updates: vec![update_from(
                squiggly,
                "A recoloured squiggly.",
                [10, 200, 120],
                1.0,
            )],
            deletions: Vec::new(),
        },
        &[],
        None,
        SaveMode::Copy,
    )
    .expect("save a recoloured squiggly");
    let after = Document::load(&squiggly_save).expect("parse squiggly save");
    let after_squiggly = annotation_dictionary(&after, "foreign-squiggly");
    let new_ap = ap_reference(&after, after_squiggly);
    let graphics_state = state(&after, ap_stream(&after, new_ap));
    assert_eq!(
        graphics_state
            .get(b"BM")
            .expect("BM")
            .as_name()
            .expect("name"),
        b"Normal",
        "a squiggly is painted alpha-over"
    );
    assert!(
        (graphics_state
            .get(b"ca")
            .expect("ca")
            .as_float()
            .expect("ca")
            - 1.0)
            .abs()
            < 1e-6
    );
    let reopened = AnnotationReader::open(&squiggly_save, None).expect("reopen squiggly save");
    let record = reopened
        .page(PageIndex(0))
        .expect("page")
        .into_iter()
        .find(|record| record.id == "nm:foreign-squiggly")
        .expect("recoloured squiggly");
    assert_eq!(record.kind, RawAnnotationKind::Squiggly);
    assert_eq!(record.blend, AnnotationBlend::Normal);
    assert_eq!(record.quads, squiggly_quads, "the file's geometry is kept");
    assert!(
        !ap_stream(&after, ap_reference(&after, after_squiggly))
            .content
            .is_empty()
    );
    assert_eq!(
        after_squiggly
            .get(b"VendorFlag")
            .expect("VendorFlag")
            .as_i64()
            .expect("integer"),
        23
    );
}

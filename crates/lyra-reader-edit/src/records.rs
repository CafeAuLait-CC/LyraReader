//! The durable annotation cache (`annotations.json`): decoding, classification and encoding.
//!
//! This is the Rust half of `AnnotationRecords.swift`, ported without changing a byte of the
//! file it writes. The Swift shell keeps the file I/O, the cache directory, the source stamp and
//! the corruption/backup policy; this module owns the format:
//!
//! * **The shape.** A pretty-printed JSON array, two-space indentation, keys in sorted order,
//!   `"key" : value` separators, Foundation's `Date` encoding (seconds since 2001-01-01 as a
//!   number) and `UUID` encoding (upper-case, hyphenated). [`encode`] reproduces that exactly,
//!   including the way a foreign entry's original text is spliced back in.
//! * **Forward compatibility.** An entry this version cannot interpret — an unknown kind, an
//!   unknown field, a colour outside the palette, a schema version from a newer build — keeps its
//!   **exact source text** and is written back untouched. [`decode`] classifies entries with the
//!   same order of decisions the Swift implementation used: the bookmark tag first, then the
//!   unknown-field set, the kind, the colour shape and the version.
//! * **Fail closed, precisely.** Structural damage (not JSON, not an array, an entry without
//!   `id`/`page`/`start`, a page outside the document, a duplicate identity, incomplete geometry)
//!   is an error. The caller blocks writes rather than replacing a file it cannot understand.
//!
//! The scanner at the bottom is a port of `JSONArrayElements`: a `serde_json` round trip would
//! not be byte-faithful (`\/` escaping, number formatting, key order), so a foreign entry can
//! only be preserved by slicing the original text.

use std::collections::{BTreeMap, HashSet};
use std::fmt;

use serde_json::{Map, Value};

use crate::kind::AnnotationKind;

/// Keys this version knows how to interpret on an annotation entry. An entry carrying anything
/// else is preserved rather than parsed: guessing at a newer schema risks writing back a
/// half-understood entry.
pub const KNOWN_ANNOTATION_KEYS: &[&str] = &[
    "id",
    "kind",
    "page",
    "start",
    "end",
    "color",
    "colorIndex",
    "note",
    "createdAt",
    // Geometry entries (`ink`, `square`, `circle`, `line`, `arrow`) carry a schema version and
    // page-space geometry.
    "version",
    "paths",
    "rect",
    "lineStart",
    "lineEnd",
    "strokeWidth",
    // Placed text (`stickyNote`, `textBox`) carries its box and its font size.
    "fontSize",
    // An entry that edits an annotation already in the PDF: its file identity, the fixed quads
    // of a foreign text mark, and a free text box's `/Q`.
    "fileIdentity",
    "quads",
    "textAlignment",
    // A stamp's style and an image signature's picture.
    "stampStyle",
    "image",
];

/// The same rule for bookmark entries. `kind` is the discriminator and is written by the
/// encoder; a newer build's additional key makes this build preserve the whole entry.
pub const KNOWN_BOOKMARK_KEYS: &[&str] = &["id", "kind", "page", "title", "yPt", "createdAt"];

/// The discriminator a bookmark is written with. It is also why an annotation-only build
/// preserves the entry instead of misreading it as a broken highlight.
pub const BOOKMARK_KIND: &str = "bookmark";

/// The eight palette colours the shell offers when creating a markup annotation, in order.
///
/// These are the **legacy** colours an older cache stored as `colorIndex`; the values must not
/// move or every existing cached highlight changes colour. The shell passes its palette in, so
/// this function exists for tests and for a caller that has no shell palette (the CLI).
pub fn legacy_highlight_palette() -> Vec<PaletteColor> {
    vec![
        PaletteColor::new(0xFF, 0xD8, 0x40, 0x66),
        PaletteColor::new(0x70, 0xD0, 0x60, 0x66),
        PaletteColor::new(0x60, 0xA0, 0xF0, 0x66),
        PaletteColor::new(0xE0, 0x70, 0xB0, 0x66),
        PaletteColor::new(0xFF, 0xA0, 0x40, 0x66),
        PaletteColor::new(0xA0, 0x80, 0xF0, 0x66),
        PaletteColor::new(0x40, 0xC0, 0xC0, 0x66),
        PaletteColor::new(0x90, 0x98, 0xA0, 0x66),
    ]
}

/// An RGBA colour as the annotation cache stores it (`#RRGGBBAA`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PaletteColor {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
    pub alpha: u8,
}

impl PaletteColor {
    pub const fn new(red: u8, green: u8, blue: u8, alpha: u8) -> Self {
        Self {
            red,
            green,
            blue,
            alpha,
        }
    }

    /// Parses `#RRGGBBAA` (or `#RRGGBB`, taken as opaque). Anything else is rejected rather
    /// than guessed at: an annotation cache is a file the reader must be able to trust.
    pub fn from_hex(text: &str) -> Option<Self> {
        let digits = text.strip_prefix('#')?;
        if digits.len() != 6 && digits.len() != 8 {
            return None;
        }
        if !digits.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return None;
        }
        let value = u32::from_str_radix(digits, 16).ok()?;
        // `from_str_radix` on eight hex digits can overflow a `u32` only above `0xFFFF_FFFF`,
        // which eight digits cannot express; six digits fit trivially.
        if digits.len() == 6 {
            Some(Self::new(
                ((value >> 16) & 0xFF) as u8,
                ((value >> 8) & 0xFF) as u8,
                (value & 0xFF) as u8,
                255,
            ))
        } else {
            Some(Self::new(
                ((value >> 24) & 0xFF) as u8,
                ((value >> 16) & 0xFF) as u8,
                ((value >> 8) & 0xFF) as u8,
                (value & 0xFF) as u8,
            ))
        }
    }

    /// `#RRGGBBAA`, upper case, the shape an older cache and the PDF writer both know.
    pub fn hex(self) -> String {
        format!(
            "#{:02X}{:02X}{:02X}{:02X}",
            self.red, self.green, self.blue, self.alpha
        )
    }
}

/// One point of a stored ink stroke or line, as the cache writes it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StoredPoint {
    pub x: f64,
    pub y: f64,
}

impl StoredPoint {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

/// One rectangle in page space.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StoredRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl StoredRect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }
}

/// One annotation as the cache stores it.
///
/// `created_at` is seconds since 2001-01-01 (Foundation's `Date` time interval), because that is
/// the number the Swift encoder writes and a conversion here would be another place for a
/// rounding difference to enter the file.
#[derive(Clone, Debug, PartialEq)]
pub struct RecordAnnotation {
    pub id: String,
    pub kind: AnnotationKind,
    pub page: i64,
    pub start: i64,
    pub end: i64,
    pub color: PaletteColor,
    pub note: String,
    pub created_at: f64,
    pub ink_paths: Vec<Vec<StoredPoint>>,
    pub shape_rect: Option<StoredRect>,
    pub line_start: Option<StoredPoint>,
    pub line_end: Option<StoredPoint>,
    pub stroke_width: f64,
    pub font_size: f64,
    pub file_identity: Option<String>,
    pub file_quads: Option<Vec<StoredRect>>,
    pub text_alignment: Option<String>,
    pub stamp_style: Option<String>,
    pub image_data: Option<Vec<u8>>,
}

impl RecordAnnotation {
    /// Whether the annotation's geometry is complete and finite.
    ///
    /// The record encoder and the write-back path both rely on this: a mark that cannot be drawn
    /// or written must be refused before it reaches a file, not turned into an empty annotation
    /// on the page. The shell's Swift property delegates here through the FFI, so this is the only
    /// copy of the thresholds.
    pub fn has_valid_geometry(&self) -> bool {
        if !self.stroke_width.is_finite() || !(0.0..=200.0).contains(&self.stroke_width) {
            return false;
        }
        match self.kind {
            AnnotationKind::Ink => {
                !self.ink_paths.is_empty()
                    && self.ink_paths.iter().all(|path| {
                        path.len() >= 2
                            && path
                                .iter()
                                .all(|point| point.x.is_finite() && point.y.is_finite())
                    })
            }
            AnnotationKind::Square | AnnotationKind::Circle => self
                .shape_rect
                .is_some_and(|rect| rect_finite(rect) && rect.width > 0.0 && rect.height > 0.0),
            AnnotationKind::Line | AnnotationKind::Arrow => {
                match (self.line_start, self.line_end) {
                    (Some(start), Some(end)) => {
                        start.x.is_finite()
                            && start.y.is_finite()
                            && end.x.is_finite()
                            && end.y.is_finite()
                            && (end.x - start.x).hypot(end.y - start.y) > 0.01
                    }
                    _ => false,
                }
            }
            AnnotationKind::StickyNote => self
                .shape_rect
                .is_some_and(|rect| rect_finite(rect) && rect.width >= 1.0 && rect.height >= 1.0),
            AnnotationKind::Stamp => self.shape_rect.is_some_and(|rect| {
                rect_finite(rect)
                    && rect.width >= 12.0
                    && rect.height >= 8.0
                    && !self.note.trim().is_empty()
            }),
            AnnotationKind::Signature => self.shape_rect.is_some_and(|rect| {
                rect_finite(rect)
                    && rect.width >= 6.0
                    && rect.height >= 6.0
                    && !self.image_data.as_ref().is_none_or(Vec::is_empty)
            }),
            AnnotationKind::TextBox => self.shape_rect.is_some_and(|rect| {
                rect_finite(rect)
                    && rect.width >= 24.0
                    && rect.height >= 24.0
                    && self.font_size.is_finite()
                    && (1.0..=400.0).contains(&self.font_size)
            }),
            AnnotationKind::Highlight
            | AnnotationKind::Underline
            | AnnotationKind::Strikeout
            | AnnotationKind::Squiggly
            | AnnotationKind::Other(_) => false,
        }
    }
}

fn rect_finite(rect: StoredRect) -> bool {
    rect.x.is_finite() && rect.y.is_finite() && rect.width.is_finite() && rect.height.is_finite()
}

/// One user bookmark as the cache stores it.
#[derive(Clone, Debug, PartialEq)]
pub struct RecordBookmark {
    /// UUID text, upper case.
    pub id: String,
    pub page: i64,
    pub title: String,
    /// Page-local Y in points, 0 at the top of the page.
    pub y_pt: f64,
    /// Seconds since 2001-01-01.
    pub created_at: f64,
}

/// Where an entry in the file came from, so the file can be reproduced in its original order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Slot {
    /// An entry this version understands; looking it up by id keeps edits and reordering intact.
    Annotation(String),
    /// A bookmark this version understands.
    Bookmark(String),
    /// The verbatim JSON text of an entry this version does not understand.
    Opaque(String),
}

/// The whole decoded cache.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Contents {
    pub annotations: Vec<RecordAnnotation>,
    pub bookmarks: Vec<RecordBookmark>,
    pub slots: Vec<Slot>,
}

impl Contents {
    /// How many entries this version preserved verbatim.
    pub fn preserved_count(&self) -> usize {
        self.slots
            .iter()
            .filter(|slot| matches!(slot, Slot::Opaque(_)))
            .count()
    }
}

/// A decoding/encoding failure, with the detail the shell shows after
/// `"Invalid annotation records: "`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecordError {
    pub detail: String,
}

impl RecordError {
    pub fn new(detail: impl Into<String>) -> Self {
        Self {
            detail: detail.into(),
        }
    }
}

impl fmt::Display for RecordError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.detail)
    }
}

impl std::error::Error for RecordError {}

fn failure<T>(detail: impl Into<String>) -> Result<T, RecordError> {
    Err(RecordError::new(detail))
}

// ── Loading ─────────────────────────────────────────────────────────────────

/// Decodes an `annotations.json` file.
///
/// `page_count` is the open document's page count; `palette` is the shell's legacy palette, in
/// order, used to turn an older entry's `colorIndex` into a colour. The palette count, not a
/// hard-coded four, is the validity bound, exactly as the Swift implementation used
/// `highlightPalette.count`.
pub fn decode(
    data: &[u8],
    page_count: usize,
    palette: &[PaletteColor],
) -> Result<Contents, RecordError> {
    let elements = parse_array_elements(data)?;

    let mut annotations: Vec<RecordAnnotation> = Vec::new();
    let mut bookmarks: Vec<RecordBookmark> = Vec::new();
    let mut slots: Vec<Slot> = Vec::new();
    let mut seen_ids: HashSet<String> = HashSet::new();
    let mut seen_bookmark_ids: HashSet<String> = HashSet::new();

    for (offset, element) in elements.iter().enumerate() {
        let entry = offset + 1;
        let value: Value = serde_json::from_str(element)
            .map_err(|_| RecordError::new(format!("entry {entry} is not a JSON object")))?;
        let Some(object) = value.as_object() else {
            return failure(format!("entry {entry} is not a JSON object"));
        };

        let kind_text = object.get("kind").and_then(Value::as_str);

        // A bookmark is classified before the annotation rules are applied. The `kind` tag is
        // what an annotation-only build sees first too, and it preserves the entry because
        // "bookmark" is a kind it cannot draw.
        if kind_text == Some(BOOKMARK_KIND) {
            let unknown_keys = has_unknown_keys(object, KNOWN_BOOKMARK_KEYS);
            if unknown_keys {
                slots.push(Slot::Opaque(element.clone()));
                continue;
            }
            let bookmark = decode_bookmark(object)
                .map_err(|error| RecordError::new(format!("entry {entry}: {error}")))?;
            if bookmark.page < 0 || bookmark.page as usize >= page_count {
                return failure(format!(
                    "entry {entry}: field 'page' is {}, outside the document's {page_count} page(s)",
                    bookmark.page.saturating_add(1)
                ));
            }
            if !bookmark.y_pt.is_finite() || bookmark.y_pt < 0.0 {
                return failure(format!(
                    "entry {entry}: field 'yPt' is {}, which is not a finite page position",
                    swift_description(bookmark.y_pt)
                ));
            }
            if !seen_bookmark_ids.insert(bookmark.id.clone()) {
                return failure(format!(
                    "entry {entry}: duplicate bookmark identity {}",
                    bookmark.id
                ));
            }
            bookmarks.push(bookmark.clone());
            slots.push(Slot::Bookmark(bookmark.id));
            continue;
        }

        // Decide whether this version can interpret the entry at all. Anything it cannot
        // interpret is kept verbatim and skipped while rendering — never dropped, and never a
        // reason to reject the whole file.
        let unknown_keys = has_unknown_keys(object, KNOWN_ANNOTATION_KEYS);
        let kind = kind_text.and_then(AnnotationKind::from_record_kind);
        let kind_understood = kind_text.is_none() || kind.is_some();
        // Either colour shape counts as understood: this version's `color`, or the older
        // `colorIndex` when it names a palette entry. An entry with neither, or with an index
        // outside the palette, is preserved rather than guessed at.
        let color_understood = match object.get("color") {
            Some(Value::String(text)) => PaletteColor::from_hex(text).is_some(),
            _ => classification_int(object.get("colorIndex"))
                .is_some_and(|index| index >= 0 && (index as usize) < palette.len()),
        };
        // A geometry entry is versioned. Text entries are the shape every older build knows and
        // carry no version; if one appears, a newer build wrote it and this one must preserve it
        // rather than interpret fields it does not know.
        let version_understood = match kind
            .as_ref()
            .map(AnnotationKind::flags)
            .and_then(|flags| flags.schema_version)
        {
            Some(expected) => {
                classification_int(object.get("version")) == Some(i64::from(expected))
            }
            None => object.get("version").is_none(),
        };

        if unknown_keys || !kind_understood || !color_understood || !version_understood {
            slots.push(Slot::Opaque(element.clone()));
            continue;
        }

        // From here on the entry claims to be one this version understands, so it has to hold
        // together: a structurally broken entry still fails the load (and therefore blocks
        // writes) instead of being silently reinterpreted.
        let annotation =
            decode_annotation(object, kind.unwrap_or(AnnotationKind::Highlight), palette)
                .map_err(|error| RecordError::new(format!("entry {entry}: {error}")))?;
        if annotation.page < 0 || annotation.page as usize >= page_count {
            return failure(format!(
                "entry {entry}: field 'page' is {}, outside the document's {page_count} page(s)",
                annotation.page.saturating_add(1)
            ));
        }
        if annotation.kind.flags().is_placement {
            if !annotation.has_valid_geometry() {
                return failure(format!(
                    "entry {entry}: {} has incomplete or non-finite geometry (fields 'paths'/'rect'/'lineStart'/'lineEnd'/'strokeWidth')",
                    annotation.kind.record_name().unwrap_or("annotation")
                ));
            }
        } else if annotation.start < 0 || annotation.end < annotation.start {
            return failure(format!(
                "entry {entry}: fields 'start' ({}) and 'end' ({}) are not a valid character range",
                annotation.start, annotation.end
            ));
        }
        if !seen_ids.insert(annotation.id.clone()) {
            return failure(format!(
                "entry {entry}: duplicate annotation identity {}",
                annotation.id
            ));
        }

        annotations.push(annotation.clone());
        slots.push(Slot::Annotation(annotation.id));
    }

    Ok(Contents {
        annotations,
        bookmarks,
        slots,
    })
}

fn has_unknown_keys(object: &Map<String, Value>, known: &[&str]) -> bool {
    object.keys().any(|key| !known.contains(&key.as_str()))
}

fn decode_bookmark(object: &Map<String, Value>) -> Result<RecordBookmark, RecordError> {
    Ok(RecordBookmark {
        id: required_uuid(object, "id")?,
        page: required_int(object, "page")?,
        title: required_string(object, "title")?,
        y_pt: required_double(object, "yPt")?,
        created_at: required_double(object, "createdAt")?,
        // `kind` is checked before this decoder runs; reading it as an optional string keeps the
        // model decodable on its own (tests, future formats). A wrong type is still an error.
    })
}

fn decode_annotation(
    object: &Map<String, Value>,
    kind: AnnotationKind,
    palette: &[PaletteColor],
) -> Result<RecordAnnotation, RecordError> {
    let id = required_uuid(object, "id")?;
    let file_identity = optional_string(object, "fileIdentity")?;
    let file_quads = optional_rects(object, "quads")?;
    let text_alignment = optional_string(object, "textAlignment")?;
    let page = required_int(object, "page")?;

    let flags = kind.flags();
    let expected_version = flags.schema_version;
    let mut start = 0;
    let mut end = 0;
    let note;
    let mut stroke_width = 0.0;
    let mut font_size = 0.0;
    let mut ink_paths = Vec::new();
    let mut shape_rect = None;
    let mut line_start = None;
    let mut line_end = None;
    let mut stamp_style = None;
    let mut image_data = None;

    if let Some(expected) = expected_version {
        let version = optional_int(object, "version")?;
        if version != Some(i64::from(expected)) {
            return failure(format!(
                "field 'version' is invalid: geometry annotation schema {} is not supported",
                version.map_or_else(|| "missing".to_string(), |value| value.to_string())
            ));
        }
    }

    if flags.is_geometry {
        start = optional_int(object, "start")?.unwrap_or(0);
        end = optional_int(object, "end")?.unwrap_or(0);
        note = optional_string(object, "note")?.unwrap_or_default();
        stroke_width = required_double(object, "strokeWidth")?;
        ink_paths = optional_points(object, "paths")?.unwrap_or_default();
        shape_rect = optional_rect(object, "rect")?;
        line_start = optional_point(object, "lineStart")?;
        line_end = optional_point(object, "lineEnd")?;
    } else if flags.is_placed_text {
        note = optional_string(object, "note")?.unwrap_or_default();
        font_size = optional_double(object, "fontSize")?.unwrap_or(0.0);
        shape_rect = optional_rect(object, "rect")?;
    } else if flags.is_stamp_artwork {
        note = optional_string(object, "note")?.unwrap_or_default();
        stamp_style = optional_string(object, "stampStyle")?;
        image_data = optional_data(object, "image")?;
        shape_rect = optional_rect(object, "rect")?;
    } else {
        start = required_int(object, "start")?;
        end = required_int(object, "end")?;
        note = required_string(object, "note")?;
    }

    let color = decode_color(object, palette)?;
    let created_at = required_double(object, "createdAt")?;

    let annotation = RecordAnnotation {
        id,
        kind,
        page,
        start,
        end,
        color,
        note,
        created_at,
        ink_paths,
        shape_rect,
        line_start,
        line_end,
        stroke_width,
        font_size,
        file_identity,
        file_quads,
        text_alignment,
        stamp_style,
        image_data,
    };
    if annotation.kind.flags().is_placement && !annotation.has_valid_geometry() {
        return failure(format!(
            "field 'kind' is invalid: {} annotation has incomplete or non-finite geometry",
            annotation.kind.record_name().unwrap_or("annotation")
        ));
    }
    Ok(annotation)
}

fn decode_color(
    object: &Map<String, Value>,
    palette: &[PaletteColor],
) -> Result<PaletteColor, RecordError> {
    match object.get("color") {
        Some(Value::Null) | None => {
            let index = required_int(object, "colorIndex")?;
            if index < 0 || index as usize >= palette.len() {
                return failure(format!(
                    "field 'colorIndex' is invalid: colour index {index} is outside the {}-colour palette",
                    palette.len()
                ));
            }
            Ok(palette[index as usize])
        }
        Some(Value::String(text)) => PaletteColor::from_hex(text).ok_or_else(|| {
            RecordError::new(format!(
                "field 'color' is invalid: expected #RRGGBB or #RRGGBBAA, got {text}"
            ))
        }),
        Some(_) => failure("field 'color' has the wrong type (expected String)"),
    }
}

// ── Field helpers ───────────────────────────────────────────────────────────

fn wrong_type<T>(key: &str, expected: &str) -> Result<T, RecordError> {
    failure(format!(
        "field '{key}' has the wrong type (expected {expected})"
    ))
}

fn no_value<T>(key: &str, expected: &str) -> Result<T, RecordError> {
    failure(format!("field '{key}' has no value (expected {expected})"))
}

fn required_string(object: &Map<String, Value>, key: &str) -> Result<String, RecordError> {
    match object.get(key) {
        None => failure(format!("field '{key}' is missing")),
        Some(Value::Null) => no_value(key, "String"),
        Some(Value::String(text)) => Ok(text.clone()),
        Some(_) => wrong_type(key, "String"),
    }
}

fn optional_string(object: &Map<String, Value>, key: &str) -> Result<Option<String>, RecordError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => wrong_type(key, "String"),
    }
}

fn required_int(object: &Map<String, Value>, key: &str) -> Result<i64, RecordError> {
    match object.get(key) {
        None => failure(format!("field '{key}' is missing")),
        Some(Value::Null) => no_value(key, "Int"),
        Some(value) => json_int(Some(value)).ok_or_else(|| {
            RecordError::new(format!("field '{key}' has the wrong type (expected Int)"))
        }),
    }
}

fn optional_int(object: &Map<String, Value>, key: &str) -> Result<Option<i64>, RecordError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => json_int(Some(value)).map(Some).ok_or_else(|| {
            RecordError::new(format!("field '{key}' has the wrong type (expected Int)"))
        }),
    }
}

/// The integer a Foundation `NSNumber` bridges to for `as? Int`: an integral number of either
/// representation, **and a boolean** (which the Objective-C bridge reads as 1 or 0). This is the
/// classification cast the Swift decoder used before it decoded the fields.
fn classification_int(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Bool(flag) => Some(i64::from(*flag)),
        Value::Number(number) => json_int_value(number),
        _ => None,
    }
}

/// `JSONDecoder`'s `Int`: an integral number, but not a boolean (a boolean is not an `Int` to
/// `JSONDecoder`, even though the Objective-C bridge would cast it). Keeping the two separate is
/// what makes a malformed `"page": true` fail the same way it did before.
fn json_int(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(number) => json_int_value(number),
        _ => None,
    }
}

fn json_int_value(number: &serde_json::Number) -> Option<i64> {
    if let Some(integer) = number.as_i64() {
        Some(integer)
    } else if let Some(integer) = number.as_u64() {
        i64::try_from(integer).ok()
    } else {
        let value = number.as_f64()?;
        (value.is_finite() && value.fract() == 0.0).then_some(value as i64)
    }
}

fn required_double(object: &Map<String, Value>, key: &str) -> Result<f64, RecordError> {
    match object.get(key) {
        None => failure(format!("field '{key}' is missing")),
        Some(Value::Null) => no_value(key, "Double"),
        Some(Value::Number(number)) => number
            .as_f64()
            .ok_or_else(|| RecordError::new(format!("field '{key}' is invalid: {number}"))),
        Some(_) => wrong_type(key, "Double"),
    }
}

fn optional_double(object: &Map<String, Value>, key: &str) -> Result<Option<f64>, RecordError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => number
            .as_f64()
            .map(Some)
            .ok_or_else(|| RecordError::new(format!("field '{key}' is invalid: {number}"))),
        Some(_) => wrong_type(key, "Double"),
    }
}

fn optional_data(object: &Map<String, Value>, key: &str) -> Result<Option<Vec<u8>>, RecordError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => base64_decode(text)
            .map(Some)
            .ok_or_else(|| RecordError::new(format!("field '{key}' is invalid: not base64"))),
        Some(_) => wrong_type(key, "base64 Data"),
    }
}

fn optional_point(
    object: &Map<String, Value>,
    key: &str,
) -> Result<Option<StoredPoint>, RecordError> {
    let Some(value) = object.get(key) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    let Some(inner) = value.as_object() else {
        return wrong_type(key, "Object");
    };
    Ok(Some(StoredPoint::new(
        required_double(inner, "x")?,
        required_double(inner, "y")?,
    )))
}

fn optional_rect(
    object: &Map<String, Value>,
    key: &str,
) -> Result<Option<StoredRect>, RecordError> {
    let Some(value) = object.get(key) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    let Some(inner) = value.as_object() else {
        return wrong_type(key, "Object");
    };
    Ok(Some(StoredRect::new(
        required_double(inner, "x")?,
        required_double(inner, "y")?,
        required_double(inner, "width")?,
        required_double(inner, "height")?,
    )))
}

fn optional_rects(
    object: &Map<String, Value>,
    key: &str,
) -> Result<Option<Vec<StoredRect>>, RecordError> {
    let Some(value) = object.get(key) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    let Some(items) = value.as_array() else {
        return wrong_type(key, "Array");
    };
    let mut rects = Vec::with_capacity(items.len());
    for item in items {
        let Some(inner) = item.as_object() else {
            return wrong_type(key, "Array of Object");
        };
        rects.push(StoredRect::new(
            required_double(inner, "x")?,
            required_double(inner, "y")?,
            required_double(inner, "width")?,
            required_double(inner, "height")?,
        ));
    }
    Ok(Some(rects))
}

fn optional_points(
    object: &Map<String, Value>,
    key: &str,
) -> Result<Option<Vec<Vec<StoredPoint>>>, RecordError> {
    let Some(value) = object.get(key) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    let Some(paths) = value.as_array() else {
        return wrong_type(key, "Array");
    };
    let mut result = Vec::with_capacity(paths.len());
    for path in paths {
        let Some(points) = path.as_array() else {
            return wrong_type(key, "Array of Array");
        };
        let mut stroke = Vec::with_capacity(points.len());
        for point in points {
            let Some(inner) = point.as_object() else {
                return wrong_type(key, "Array of Array of Object");
            };
            stroke.push(StoredPoint::new(
                required_double(inner, "x")?,
                required_double(inner, "y")?,
            ));
        }
        result.push(stroke);
    }
    Ok(Some(result))
}

fn required_uuid(object: &Map<String, Value>, key: &str) -> Result<String, RecordError> {
    let text = required_string(object, key)?;
    normalize_uuid(&text).ok_or_else(|| {
        RecordError::new(format!("field '{key}' is invalid: expected a UUID string"))
    })
}

/// Upper-cases and validates the hyphenated UUID shape Foundation writes.
pub fn normalize_uuid(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    if bytes.len() != 36 {
        return None;
    }
    let mut normalized = String::with_capacity(36);
    for (index, byte) in bytes.iter().enumerate() {
        match index {
            8 | 13 | 18 | 23 => {
                if *byte != b'-' {
                    return None;
                }
                normalized.push('-');
            }
            _ => {
                let character = char::from(*byte);
                if !character.is_ascii_hexdigit() {
                    return None;
                }
                normalized.push(character.to_ascii_uppercase());
            }
        }
    }
    Some(normalized)
}

// ── Saving ──────────────────────────────────────────────────────────────────

/// The bytes to write for `annotations` and `bookmarks`, in the cache's original entry order,
/// with preserved entries reproduced verbatim.
///
/// Entries this version understands are rendered exactly as Foundation's `JSONEncoder` with
/// `.prettyPrinted, .sortedKeys` rendered them; foreign entries are spliced in as the exact text
/// they had in the file they came from.
pub fn encode(
    annotations: &[RecordAnnotation],
    bookmarks: &[RecordBookmark],
    slots: &[Slot],
    palette: &[PaletteColor],
) -> Result<Vec<u8>, RecordError> {
    enum Piece {
        Annotations(Vec<RecordAnnotation>),
        Bookmarks(Vec<RecordBookmark>),
        Foreign(String),
    }

    let mut pieces: Vec<Piece> = Vec::new();
    let mut pending_annotations: Vec<RecordAnnotation> = Vec::new();
    let mut pending_bookmarks: Vec<RecordBookmark> = Vec::new();
    let mut emitted_annotations: HashSet<String> = HashSet::new();
    let mut emitted_bookmarks: HashSet<String> = HashSet::new();

    fn close_pending_runs(
        pieces: &mut Vec<Piece>,
        pending_annotations: &mut Vec<RecordAnnotation>,
        pending_bookmarks: &mut Vec<RecordBookmark>,
    ) {
        if !pending_annotations.is_empty() {
            pieces.push(Piece::Annotations(std::mem::take(pending_annotations)));
        }
        if !pending_bookmarks.is_empty() {
            pieces.push(Piece::Bookmarks(std::mem::take(pending_bookmarks)));
        }
    }

    for slot in slots {
        match slot {
            Slot::Opaque(raw) => {
                close_pending_runs(
                    &mut pieces,
                    &mut pending_annotations,
                    &mut pending_bookmarks,
                );
                pieces.push(Piece::Foreign(raw.clone()));
            }
            Slot::Annotation(id) => {
                // Leaving a bookmark run flushes it, so an interleaved file keeps its order.
                if !pending_bookmarks.is_empty() {
                    close_pending_runs(
                        &mut pieces,
                        &mut pending_annotations,
                        &mut pending_bookmarks,
                    );
                }
                // Absent means the entry was deleted; a second slot for the same id (only
                // possible in a hand-edited file) is ignored.
                let Some(annotation) = annotations
                    .iter()
                    .find(|annotation| same_identity(&annotation.id, id))
                else {
                    continue;
                };
                if !emitted_annotations.insert(annotation.id.clone()) {
                    continue;
                }
                pending_annotations.push(annotation.clone());
            }
            Slot::Bookmark(id) => {
                if !pending_annotations.is_empty() {
                    close_pending_runs(
                        &mut pieces,
                        &mut pending_annotations,
                        &mut pending_bookmarks,
                    );
                }
                let Some(bookmark) = bookmarks
                    .iter()
                    .find(|bookmark| same_identity(&bookmark.id, id))
                else {
                    continue;
                };
                if !emitted_bookmarks.insert(bookmark.id.clone()) {
                    continue;
                }
                pending_bookmarks.push(bookmark.clone());
            }
        }
    }
    for annotation in annotations {
        if emitted_annotations.contains(&annotation.id) {
            continue;
        }
        if !pending_bookmarks.is_empty() {
            close_pending_runs(
                &mut pieces,
                &mut pending_annotations,
                &mut pending_bookmarks,
            );
        }
        pending_annotations.push(annotation.clone());
    }
    close_pending_runs(
        &mut pieces,
        &mut pending_annotations,
        &mut pending_bookmarks,
    );
    for bookmark in bookmarks {
        if emitted_bookmarks.contains(&bookmark.id) {
            continue;
        }
        pending_bookmarks.push(bookmark.clone());
    }
    close_pending_runs(
        &mut pieces,
        &mut pending_annotations,
        &mut pending_bookmarks,
    );

    if pieces.is_empty() {
        // `JSONEncoder().encode([AppState.Annotation]())` — the empty-array golden.
        return Ok(b"[\n\n]".to_vec());
    }

    let mut lines: Vec<String> = Vec::with_capacity(pieces.len());
    for piece in pieces {
        match piece {
            Piece::Foreign(raw) => {
                // `raw` starts at the entry's first byte; the two spaces put it back at the
                // array's indentation level. Its own interior text is untouched.
                lines.push(format!("  {raw}"));
            }
            Piece::Annotations(run) => {
                lines.push(render_annotation_run(&run, palette)?);
            }
            Piece::Bookmarks(run) => {
                lines.push(render_bookmark_run(&run)?);
            }
        }
    }
    let file = format!("[\n{}\n]", lines.join(",\n"));
    Ok(file.into_bytes())
}

fn same_identity(left: &str, right: &str) -> bool {
    if left == right {
        return true;
    }
    match (normalize_uuid(left), normalize_uuid(right)) {
        (Some(left), Some(right)) => left == right,
        _ => false,
    }
}

fn render_annotation_run(
    annotations: &[RecordAnnotation],
    palette: &[PaletteColor],
) -> Result<String, RecordError> {
    let mut entries = Vec::with_capacity(annotations.len());
    for annotation in annotations {
        // The array is rendered at indent 0; each entry the Swift encoder produced starts with
        // the array's two-space indentation, which is what the assembled file expects.
        entries.push(format!("  {}", render_annotation(annotation, palette)?));
    }
    Ok(entries.join(",\n"))
}

fn render_bookmark_run(bookmarks: &[RecordBookmark]) -> Result<String, RecordError> {
    let mut entries = Vec::with_capacity(bookmarks.len());
    for bookmark in bookmarks {
        entries.push(format!("  {}", render_bookmark(bookmark)?));
    }
    Ok(entries.join(",\n"))
}

fn render_annotation(
    annotation: &RecordAnnotation,
    palette: &[PaletteColor],
) -> Result<String, RecordError> {
    let Some(record_name) = annotation.kind.record_name() else {
        return failure(format!(
            "cannot write {:?} into the annotation cache",
            annotation.kind
        ));
    };
    let id = normalize_uuid(&annotation.id).ok_or_else(|| {
        RecordError::new(format!("annotation id {:?} is not a UUID", annotation.id))
    })?;

    let mut object: BTreeMap<String, Json> = BTreeMap::new();
    object.insert("id".into(), Json::Text(id));
    object.insert("kind".into(), Json::Text(record_name.into()));
    object.insert("page".into(), Json::Int(annotation.page));

    let flags = annotation.kind.flags();
    if let Some(version) = flags.schema_version {
        object.insert("version".into(), Json::Int(i64::from(version)));
    }
    if flags.is_geometry {
        object.insert("strokeWidth".into(), Json::Number(annotation.stroke_width));
        match annotation.kind {
            AnnotationKind::Ink => {
                object.insert("paths".into(), Json::points(&annotation.ink_paths));
            }
            AnnotationKind::Square | AnnotationKind::Circle => {
                if let Some(rect) = annotation.shape_rect {
                    object.insert("rect".into(), Json::rect(rect));
                }
            }
            AnnotationKind::Line | AnnotationKind::Arrow => {
                if let Some(start) = annotation.line_start {
                    object.insert("lineStart".into(), Json::point(start));
                }
                if let Some(end) = annotation.line_end {
                    object.insert("lineEnd".into(), Json::point(end));
                }
            }
            _ => {}
        }
    } else if flags.is_placed_text {
        if let Some(rect) = annotation.shape_rect {
            object.insert("rect".into(), Json::rect(rect));
        }
        object.insert("fontSize".into(), Json::Number(annotation.font_size));
    } else if flags.is_stamp_artwork {
        if let Some(rect) = annotation.shape_rect {
            object.insert("rect".into(), Json::rect(rect));
        }
        if let Some(style) = &annotation.stamp_style {
            object.insert("stampStyle".into(), Json::Text(style.clone()));
        }
        if let Some(image) = &annotation.image_data {
            object.insert("image".into(), Json::Text(base64_encode(image)));
        }
    } else {
        object.insert("start".into(), Json::Int(annotation.start));
        object.insert("end".into(), Json::Int(annotation.end));
    }

    if let Some(index) = palette.iter().position(|color| *color == annotation.color) {
        object.insert("colorIndex".into(), Json::Int(index as i64));
    } else {
        object.insert("color".into(), Json::Text(annotation.color.hex()));
    }
    object.insert("note".into(), Json::Text(annotation.note.clone()));
    object.insert("createdAt".into(), Json::Number(annotation.created_at));
    if let Some(identity) = &annotation.file_identity {
        object.insert("fileIdentity".into(), Json::Text(identity.clone()));
    }
    if let Some(quads) = &annotation.file_quads {
        object.insert(
            "quads".into(),
            Json::Array(quads.iter().copied().map(Json::rect).collect()),
        );
    }
    if let Some(alignment) = &annotation.text_alignment {
        object.insert("textAlignment".into(), Json::Text(alignment.clone()));
    }

    Ok(render(&Json::Object(object), 2))
}

fn render_bookmark(bookmark: &RecordBookmark) -> Result<String, RecordError> {
    let id = normalize_uuid(&bookmark.id)
        .ok_or_else(|| RecordError::new(format!("bookmark id {:?} is not a UUID", bookmark.id)))?;
    let mut object: BTreeMap<String, Json> = BTreeMap::new();
    object.insert("id".into(), Json::Text(id));
    object.insert("kind".into(), Json::Text(BOOKMARK_KIND.into()));
    object.insert("page".into(), Json::Int(bookmark.page));
    object.insert("title".into(), Json::Text(bookmark.title.clone()));
    object.insert("yPt".into(), Json::Number(bookmark.y_pt));
    object.insert("createdAt".into(), Json::Number(bookmark.created_at));
    Ok(render(&Json::Object(object), 2))
}

// ── A small Swift-compatible JSON writer ────────────────────────────────────

#[derive(Clone, Debug, PartialEq)]
enum Json {
    Int(i64),
    Number(f64),
    Text(String),
    Array(Vec<Json>),
    Object(BTreeMap<String, Json>),
}

impl Json {
    fn point(point: StoredPoint) -> Self {
        let mut object = BTreeMap::new();
        object.insert("x".into(), Self::Number(point.x));
        object.insert("y".into(), Self::Number(point.y));
        Self::Object(object)
    }

    fn rect(rect: StoredRect) -> Self {
        let mut object = BTreeMap::new();
        object.insert("x".into(), Self::Number(rect.x));
        object.insert("y".into(), Self::Number(rect.y));
        object.insert("width".into(), Self::Number(rect.width));
        object.insert("height".into(), Self::Number(rect.height));
        Self::Object(object)
    }

    fn points(paths: &[Vec<StoredPoint>]) -> Self {
        Self::Array(
            paths
                .iter()
                .map(|path| Self::Array(path.iter().copied().map(Self::point).collect()))
                .collect(),
        )
    }
}

fn render(value: &Json, indent: usize) -> String {
    match value {
        Json::Int(integer) => integer.to_string(),
        Json::Number(number) => swift_number(*number),
        Json::Text(text) => render_string(text),
        Json::Array(items) => {
            if items.is_empty() {
                return format!("[\n\n{}]", " ".repeat(indent));
            }
            let inner = items
                .iter()
                .map(|item| format!("{}{}", " ".repeat(indent + 2), render(item, indent + 2)))
                .collect::<Vec<_>>()
                .join(",\n");
            format!("[\n{inner}\n{}]", " ".repeat(indent))
        }
        Json::Object(object) => {
            if object.is_empty() {
                return format!("{{\n\n{}}}", " ".repeat(indent));
            }
            let inner = object
                .iter()
                .map(|(key, value)| {
                    format!(
                        "{}{} : {}",
                        " ".repeat(indent + 2),
                        render_string(key),
                        render(value, indent + 2)
                    )
                })
                .collect::<Vec<_>>()
                .join(",\n");
            format!("{{\n{inner}\n{}}}", " ".repeat(indent))
        }
    }
}

fn render_string(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len() + 2);
    escaped.push('"');
    for character in text.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '/' => escaped.push_str("\\/"),
            '\u{8}' => escaped.push_str("\\b"),
            '\u{c}' => escaped.push_str("\\f"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            character if (character as u32) < 0x20 => {
                escaped.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => escaped.push(character),
        }
    }
    escaped.push('"');
    escaped
}

/// Formats a `Double` exactly as Foundation's `JSONEncoder` does.
///
/// Foundation writes Swift's shortest round-trip description with three JSON-specific rules:
///
/// * an integral value in fixed notation drops the `.0` (`14.0` → `14`, `-0.0` → `-0`);
/// * an exponent carries an explicit sign and at least two digits (`1e-7` → `1e-07`,
///   `1e16` → `1e+16`);
/// * the fixed/scientific threshold is the one Swift uses: fixed for decimal exponents in
///   `[-4, 15]`, scientific outside it.
///
/// The digit string itself has to match too, including which of two same-length candidates is
/// chosen when the exact binary value sits halfway between them (Swift rounds half to even;
/// Rust's own `Debug` formatter rounds half away from zero, so two in 4,000 random doubles were
/// measured to differ). `serde_json`'s number formatter produces the same correctly rounded
/// digits as Swift; its *layout* differs (`1e-5` is written `0.00001`, `14.0` as `14.0`), so this
/// function takes its digits and applies Foundation's layout.
pub fn swift_number(value: f64) -> String {
    if value.is_nan() {
        // JSON has no NaN. The cache never writes one (validation refuses non-finite geometry and
        // dates), but a message that names the value is more useful than a panic.
        return "nan".to_string();
    }
    if value.is_infinite() {
        return if value > 0.0 { "inf" } else { "-inf" }.to_string();
    }
    let Some(number) = serde_json::Number::from_f64(value) else {
        return "nan".to_string();
    };
    let text = number.to_string();
    format_swift_number(&text)
}

/// The digits `serde_json` chose, as `(negative, digits, exponent of the first digit)`.
///
/// `14.0` → `(false, "14", 1)`; `0.00001` → `(false, "1", -5)`; `1.234e+18` → `(false, "1234", 18)`.
fn canonical_decimal(text: &str) -> (bool, String, i32) {
    let (negative, unsigned) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text),
    };
    let (mantissa, exponent, scientific) = match unsigned.split_once(['e', 'E']) {
        Some((mantissa, exponent)) => (mantissa, exponent.parse::<i32>().unwrap_or_default(), true),
        None => (unsigned, 0, false),
    };
    let mut digits = String::with_capacity(mantissa.len());
    let mut point = 0usize;
    let mut saw_point = false;
    for character in mantissa.chars() {
        if character == '.' {
            saw_point = true;
            point = digits.len();
        } else if character.is_ascii_digit() {
            digits.push(character);
        }
    }
    if !saw_point {
        point = digits.len();
    }
    let first = digits.find(|character| character != '0');
    let Some(first) = first else {
        return (negative, "0".to_string(), 0);
    };
    let exponent = if scientific {
        exponent
    } else {
        point as i32 - first as i32 - 1
    };
    let mut significant = digits[first..].to_string();
    while significant.ends_with('0') && significant.len() > 1 {
        significant.pop();
    }
    (negative, significant, exponent)
}

fn format_swift_number(text: &str) -> String {
    let (negative, digits, exponent) = canonical_decimal(text);
    if digits == "0" {
        return if negative {
            "-0".to_string()
        } else {
            "0".to_string()
        };
    }
    let mut rendered = String::new();
    if negative {
        rendered.push('-');
    }
    if !(-4..16).contains(&exponent) {
        rendered.push(digits.as_bytes()[0] as char);
        if digits.len() > 1 {
            rendered.push('.');
            rendered.push_str(&digits[1..]);
        }
        rendered.push('e');
        if exponent < 0 {
            rendered.push('-');
        } else {
            rendered.push('+');
        }
        let magnitude = exponent.unsigned_abs();
        if magnitude < 10 {
            rendered.push('0');
        }
        rendered.push_str(&magnitude.to_string());
    } else if exponent >= 0 {
        let whole = exponent as usize + 1;
        if digits.len() <= whole {
            rendered.push_str(&digits);
            rendered.extend(std::iter::repeat_n('0', whole - digits.len()));
        } else {
            rendered.push_str(&digits[..whole]);
            rendered.push('.');
            rendered.push_str(&digits[whole..]);
        }
    } else {
        rendered.push_str("0.");
        rendered.extend(std::iter::repeat_n('0', (-exponent - 1) as usize));
        rendered.push_str(&digits);
    }
    rendered
}

/// Swift's interpolation of a `Double` for a human-readable message.
fn swift_description(value: f64) -> String {
    format!("{value:?}")
}

// ── Base64 (Foundation's `.base64`, standard alphabet, padded) ──────────────

const BASE64_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64_encode(bytes: &[u8]) -> String {
    let mut encoded = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let first = chunk[0] as u32;
        let second = chunk.get(1).copied().unwrap_or(0) as u32;
        let third = chunk.get(2).copied().unwrap_or(0) as u32;
        let value = (first << 16) | (second << 8) | third;
        encoded.push(BASE64_ALPHABET[((value >> 18) & 0x3F) as usize] as char);
        encoded.push(BASE64_ALPHABET[((value >> 12) & 0x3F) as usize] as char);
        encoded.push(if chunk.len() > 1 {
            BASE64_ALPHABET[((value >> 6) & 0x3F) as usize] as char
        } else {
            '='
        });
        encoded.push(if chunk.len() > 2 {
            BASE64_ALPHABET[(value & 0x3F) as usize] as char
        } else {
            '='
        });
    }
    encoded
}

pub fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut decoded = Vec::with_capacity(bytes.len() / 4 * 3);
    for (index, chunk) in bytes.chunks(4).enumerate() {
        let last = index + 1 == bytes.len() / 4;
        let mut values = [0u32; 4];
        let mut padding = 0;
        for (position, byte) in chunk.iter().enumerate() {
            values[position] = if *byte == b'=' {
                // Padding is only legal in the last chunk's last one or two positions.
                if !last || position < 2 {
                    return None;
                }
                padding += 1;
                0
            } else {
                base64_value(*byte)? as u32
            };
        }
        if padding > 2 || (padding > 0 && chunk[4 - padding..].iter().any(|byte| *byte != b'=')) {
            return None;
        }
        let value = (values[0] << 18) | (values[1] << 12) | (values[2] << 6) | values[3];
        decoded.push(((value >> 16) & 0xFF) as u8);
        if padding < 2 {
            decoded.push(((value >> 8) & 0xFF) as u8);
        }
        if padding == 0 {
            decoded.push((value & 0xFF) as u8);
        }
    }
    Some(decoded)
}

fn base64_value(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

// ── The top-level array scanner ─────────────────────────────────────────────

/// Finds the verbatim text of every top-level array element.
///
/// `serde_json` cannot hand back the bytes of an element a newer version wrote, and a round trip
/// is not byte-faithful (`\/` escaping, number and date formatting, key order), so the only way
/// to preserve a foreign entry exactly is to slice the original text. This scanner finds those
/// slices; full JSON validation is left to `serde_json`, which every retained entry goes through.
pub fn parse_array_elements(data: &[u8]) -> Result<Vec<String>, RecordError> {
    let count = data.len();
    let mut index = 0;

    fn is_whitespace(byte: u8) -> bool {
        matches!(byte, 0x20 | 0x09 | 0x0A | 0x0D)
    }

    fn skip_string(bytes: &[u8], index: &mut usize, count: usize) -> Result<(), RecordError> {
        *index += 1; // opening quote
        while *index < count {
            match bytes[*index] {
                b'\\' => *index += 2, // an escape can never end the string
                b'"' => {
                    *index += 1;
                    return Ok(());
                }
                _ => *index += 1,
            }
        }
        failure(format!("byte {index}: unterminated string"))
    }

    fn skip_composite(bytes: &[u8], index: &mut usize, count: usize) -> Result<(), RecordError> {
        let mut depth = 0i64;
        while *index < count {
            match bytes[*index] {
                b'"' => {
                    skip_string(bytes, index, count)?;
                    continue;
                }
                b'{' | b'[' => depth += 1,
                b'}' | b']' => {
                    depth -= 1;
                    if depth == 0 {
                        *index += 1;
                        return Ok(());
                    }
                }
                _ => {}
            }
            *index += 1;
        }
        failure(format!("byte {index}: unterminated entry"))
    }

    fn skip_value(bytes: &[u8], index: &mut usize, count: usize) -> Result<(), RecordError> {
        match bytes[*index] {
            b'{' | b'[' => skip_composite(bytes, index, count),
            b'"' => skip_string(bytes, index, count),
            _ => {
                let start = *index;
                while *index < count
                    && !is_whitespace(bytes[*index])
                    && bytes[*index] != b','
                    && bytes[*index] != b']'
                    && bytes[*index] != b'}'
                {
                    *index += 1;
                }
                if *index == start {
                    return failure(format!("byte {index}: unexpected character"));
                }
                Ok(())
            }
        }
    }

    while index < count && is_whitespace(data[index]) {
        index += 1;
    }
    if index >= count || data[index] != b'[' {
        return failure(format!(
            "byte {index}: the annotation records must be a JSON array"
        ));
    }
    index += 1;

    let mut elements: Vec<String> = Vec::new();
    while index < count && is_whitespace(data[index]) {
        index += 1;
    }
    if index < count && data[index] == b']' {
        index += 1;
    } else {
        loop {
            while index < count && is_whitespace(data[index]) {
                index += 1;
            }
            if index >= count {
                return failure(format!("byte {index}: unexpected end of file"));
            }
            if data[index] == b',' || data[index] == b']' {
                return failure(format!("byte {index}: empty array element"));
            }
            let start = index;
            skip_value(data, &mut index, count)?;
            elements.push(String::from_utf8_lossy(&data[start..index]).into_owned());
            while index < count && is_whitespace(data[index]) {
                index += 1;
            }
            if index >= count {
                return failure(format!("byte {index}: unexpected end of file"));
            }
            if data[index] == b',' {
                index += 1;
                continue;
            }
            if data[index] != b']' {
                return failure(format!("byte {index}: unexpected character after an entry"));
            }
            index += 1;
            break;
        }
    }

    while index < count && is_whitespace(data[index]) {
        index += 1;
    }
    if index != count {
        return failure(format!("byte {index}: unexpected trailing content"));
    }
    let _ = count;
    Ok(elements)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn golden(name: &str) -> Vec<u8> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/annotation-codec")
            .join(name);
        std::fs::read(&path)
            .unwrap_or_else(|error| panic!("read golden {}: {error}", path.display()))
    }

    #[test]
    fn swift_number_matches_foundation() {
        // Captured from the Swift encoder on 2026-10-25.
        let cases: &[(f64, &str)] = &[
            (0.0, "0"),
            (-0.0, "-0"),
            (1.0, "1"),
            (14.0, "14"),
            (2.5, "2.5"),
            (0.1, "0.1"),
            (0.5, "0.5"),
            (1.0 / 3.0, "0.3333333333333333"),
            (1e-7, "1e-07"),
            (1e-6, "1e-06"),
            (1e-5, "1e-05"),
            (0.0001, "0.0001"),
            (0.001, "0.001"),
            (0.01, "0.01"),
            (1e15, "1000000000000000"),
            (1e16, "1e+16"),
            (1e17, "1e+17"),
            (1e20, "1e+20"),
            (1e21, "1e+21"),
            (1e-20, "1e-20"),
            (5e-324, "5e-324"),
            (1.7976931348623157e308, "1.7976931348623157e+308"),
            (123456789012345.6, "123456789012345.6"),
            (804000000.123456, "804000000.123456"),
            (1729876543.123456, "1729876543.123456"),
            (-42.75, "-42.75"),
            (9007199254740992.0, "9007199254740992"),
            (0.30000000000000004, "0.30000000000000004"),
            (0.028, "0.028"),
            (0.000244140625, "0.000244140625"),
            (1.2345678901234567, "1.2345678901234567"),
            (2e-7, "2e-07"),
            (std::f64::consts::PI, "3.141592653589793"),
            (1e-30, "1e-30"),
            (1e30, "1e+30"),
            (1.2345678901234568e18, "1.2345678901234568e+18"),
            // Two values where the exact binary value sits halfway between the two shortest
            // decimal candidates: Swift rounds the final digit to even, Rust's `Debug` does not.
            (f64::from_bits(0xC302_B6A9_4538_EDE2), "-658423463484860.2"),
            (f64::from_bits(0x4314_E9E9_97C3_F879), "1471672254266910.2"),
        ];
        for (value, expected) in cases {
            assert_eq!(swift_number(*value), *expected, "{value:?}");
        }
    }

    #[test]
    fn escapes_match_foundation() {
        let text = "\u{0}\u{1}\u{7}\u{8}\t\n\u{b}\u{c}\r\u{1f}\u{7f}\u{2028}\u{2029}é中😀/\\\"";
        assert_eq!(
            render_string(text),
            "\"\\u0000\\u0001\\u0007\\b\\t\\n\\u000b\\f\\r\\u001f\u{7f}\u{2028}\u{2029}é中😀\\/\\\\\\\"\""
        );
    }

    #[test]
    fn empty_array_matches_foundation() {
        assert_eq!(encode(&[], &[], &[], &[]).unwrap(), b"[\n\n]".to_vec());
    }

    #[test]
    fn scanner_reports_bytes_like_the_swift_scanner() {
        let error = parse_array_elements(br#"[{"id":"#).unwrap_err();
        assert!(error.detail.contains("byte"), "{error}");
        let error = parse_array_elements(br#"{}"#).unwrap_err();
        assert_eq!(
            error.detail,
            "byte 0: the annotation records must be a JSON array"
        );
        let error = parse_array_elements(b"").unwrap_err();
        assert_eq!(
            error.detail,
            "byte 0: the annotation records must be a JSON array"
        );
        let error = parse_array_elements(b"[1,]").unwrap_err();
        assert_eq!(error.detail, "byte 3: empty array element");
    }

    #[test]
    fn base64_round_trips_like_foundation() {
        assert_eq!(base64_encode(&[0, 1, 2, 254, 255]), "AAEC/v8=");
        assert_eq!(base64_decode("AAEC/v8="), Some(vec![0, 1, 2, 254, 255]));
        assert_eq!(base64_decode("AQI="), Some(vec![1, 2]));
        assert_eq!(base64_decode("AQI"), None);
        assert_eq!(base64_decode("AQ ID"), None);
        assert_eq!(base64_decode("-_8="), None);
        assert_eq!(base64_decode("===="), None);
    }

    #[test]
    fn goldens_decode_and_encode_byte_identically() {
        let palette = legacy_highlight_palette();
        for name in [
            "empty.json",
            "plain-highlights.json",
            "every-kind.json",
            "notes-newlines.json",
            "bookmarks-unicode.json",
            "old-version-record.json",
            "unknown-extra-fields.json",
            "interleaved-order.json",
            "ui-add-highlight.json",
        ] {
            let bytes = golden(name);
            let contents = decode(&bytes, 1_000, &palette)
                .unwrap_or_else(|error| panic!("{name}: decode: {error}"));
            let encoded = encode(
                &contents.annotations,
                &contents.bookmarks,
                &contents.slots,
                &palette,
            )
            .unwrap_or_else(|error| panic!("{name}: encode: {error}"));
            assert_eq!(encoded, bytes, "{name}: decode+encode changed the bytes");
        }
    }

    #[test]
    fn an_empty_file_is_still_a_structure_error() {
        let error = decode(b"", 1, &legacy_highlight_palette()).unwrap_err();
        assert_eq!(
            error.detail,
            "byte 0: the annotation records must be a JSON array"
        );
    }

    #[test]
    fn foreign_entries_are_preserved_verbatim() {
        let palette = legacy_highlight_palette();
        let bytes = golden("unknown-extra-fields.json");
        let contents = decode(&bytes, 1_000, &palette).unwrap();
        assert!(contents.preserved_count() > 0);
        let text = String::from_utf8(
            encode(
                &contents.annotations,
                &contents.bookmarks,
                &contents.slots,
                &palette,
            )
            .unwrap(),
        )
        .unwrap();
        assert!(text.contains("\"futureMark\""));
        assert!(text.contains("\"extraLayer\""));
    }
}

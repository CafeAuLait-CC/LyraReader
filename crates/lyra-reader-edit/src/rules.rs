//! The one rule set for annotation and bookmark limits.
//!
//! These numbers and messages used to be spread across the shell, the FFI's write conversion,
//! PDFium's annotation write-back and PDFium's outline writer. They had already drifted: the
//! outline writer refused a page by its zero-based index while the FFI refused it by its
//! one-based page number, and the shell created marks the writer would later refuse.
//!
//! Everything lives here now:
//!
//! * [`validate_bookmark`] / [`validate_bookmarks`] — the outline writer, the FFI save path and
//!   the shell's bookmark entry point all call one of these.
//! * [`bookmark_insertion_index`], [`moved_bookmark_index`] and [`reorder_bookmark_slots`] —
//!   the reader's durable bookmark order, which the shell used to restate when adding, moving
//!   and persisting bookmarks.
//! * [`validate_annotation`] — the shell's annotation entry points, with the same messages the
//!   write path produces.
//! * the per-field helpers ([`validate_page`], [`validate_border_width`],
//!   [`validate_font_size`], [`validate_text`], …) — called by the FFI's write conversion so the
//!   save-time refusal and the creation-time refusal cannot say different things.
//! * the clamps ([`clamp_opacity`], [`clamp_border_width`], [`clamp_font_size`]) — used where the
//!   shell used to clamp by hand.
//!
//! The rules are deliberately conservative about *rejecting*: a limit is enforced where it was
//! enforced before. Decoding a cache does **not** apply the writer's text-length limits, so a
//! cache with a long note that an older build accepted still loads; it is only a new save that
//! is refused, exactly as before this module existed.

use std::fmt;

use crate::kind::AnnotationKind;
use crate::records::{RecordAnnotation, RecordBookmark, Slot};

/// Hard limits, with the values the write path already enforced.
pub const MAX_ANNOTATIONS: usize = 20_000;
pub const MAX_BOOKMARKS: usize = 5_000;
/// One annotation or bookmark identity: the shell writes a UUID string (36 bytes).
pub const MAX_ID_BYTES: usize = 128;
pub const MAX_BOOKMARK_TITLE_BYTES: usize = 4_096;
/// `/Contents` of one annotation, as UTF-8 bytes.
pub const MAX_NOTE_BYTES: usize = 100_000;
pub const MAX_AUTHOR_BYTES: usize = 1_024;
/// A stamp's words are drawn into a fixed badge; PDFium's writer refuses more than this.
pub const MAX_STAMP_TEXT_BYTES: usize = 512;
pub const MAX_QUADS: usize = 1_000;
pub const MAX_INK_PATHS: usize = 256;
pub const MAX_INK_POINTS: usize = 100_000;
pub const MAX_STAMP_IMAGE_SIDE: u32 = 8_192;

/// `/BS /W`: a centred stroke wider than this is not a mark, it is a filled shape.
pub const MAX_BORDER_WIDTH_PT: f64 = 200.0;
/// `/DA` font size, in points. Below 1 pt is unreadable; above 400 pt is page-sized noise.
pub const MIN_FONT_SIZE_PT: f64 = 1.0;
pub const MAX_FONT_SIZE_PT: f64 = 400.0;
/// `/CA`.
pub const MIN_OPACITY: f64 = 0.0;
pub const MAX_OPACITY: f64 = 1.0;

/// A refused rule, with the sentence the shell shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuleError {
    pub message: String,
}

impl RuleError {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for RuleError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for RuleError {}

fn refuse<T>(message: impl Into<String>) -> Result<T, RuleError> {
    Err(RuleError::new(message))
}

// ── Identity ────────────────────────────────────────────────────────────────

/// `1…128` printable ASCII characters. Both a bookmark id and an annotation id are the shell's
/// UUID text today; the wider accepted shape is the writer's existing rule, kept so an imported
/// file with a non-UUID `/NM`-style identity is not silently refused.
pub fn identity_is_valid(id: &str) -> bool {
    !id.is_empty() && id.len() <= MAX_ID_BYTES && id.bytes().all(|byte| byte.is_ascii_graphic())
}

pub fn validate_annotation_identity(id: &str) -> Result<(), RuleError> {
    if identity_is_valid(id) {
        Ok(())
    } else {
        refuse("an annotation identity must be 1–128 printable ASCII characters")
    }
}

pub fn validate_bookmark_identity(id: &str) -> Result<(), RuleError> {
    if identity_is_valid(id) {
        Ok(())
    } else {
        refuse("a bookmark identity must be 1–128 printable ASCII characters")
    }
}

pub fn validate_unique_annotation_ids(ids: &[String]) -> Result<(), RuleError> {
    let mut seen = std::collections::HashSet::new();
    for id in ids {
        if !seen.insert(id) {
            return refuse(format!(
                "two annotations in one save share the identity {:?}",
                id
            ));
        }
    }
    Ok(())
}

pub fn validate_unique_bookmark_ids(ids: &[String]) -> Result<(), RuleError> {
    let mut seen = std::collections::HashSet::new();
    for id in ids {
        if !seen.insert(id) {
            return refuse(format!(
                "two bookmarks in one save share the identity {:?}",
                id
            ));
        }
    }
    Ok(())
}

// ── Page and position ───────────────────────────────────────────────────────

/// One annotation's page is inside the document. The message names the page as a person counts
/// pages (1-based), which is what the FFI save path already showed; the outline writer's
/// zero-based wording was the drift this function removes.
pub fn validate_page(id: &str, page: i64, page_count: usize) -> Result<(), RuleError> {
    if page >= 0 && (page as usize) < page_count {
        Ok(())
    } else {
        refuse(format!(
            "annotation {:?} names page {}, but the document has {page_count} page(s)",
            id,
            page.saturating_add(1)
        ))
    }
}

pub fn validate_bookmark_page(id: &str, page: i64, page_count: usize) -> Result<(), RuleError> {
    if page >= 0 && (page as usize) < page_count {
        Ok(())
    } else {
        refuse(format!(
            "bookmark {:?} names page {}, but the document has {page_count} page(s)",
            id,
            page.saturating_add(1)
        ))
    }
}

/// A bookmark's page-local `yPt`: finite and not above the page's top edge.
pub fn validate_bookmark_y(id: &str, y_pt: f64) -> Result<(), RuleError> {
    if y_pt.is_finite() && y_pt >= 0.0 {
        Ok(())
    } else {
        refuse(format!(
            "bookmark {:?} has a Y that is not finite and non-negative",
            id
        ))
    }
}

// ── Text ────────────────────────────────────────────────────────────────────

pub fn validate_note(id: &str, note: &str) -> Result<(), RuleError> {
    if note.len() > MAX_NOTE_BYTES {
        return refuse(format!(
            "annotation {:?} has more than {MAX_NOTE_BYTES} bytes of text",
            id
        ));
    }
    if note.contains('\0') {
        return refuse(format!("annotation {:?} has a NUL in its contents", id));
    }
    Ok(())
}

pub fn validate_author(id: &str, author: &str) -> Result<(), RuleError> {
    if author.len() > MAX_AUTHOR_BYTES {
        return refuse(format!(
            "annotation {:?} has an author longer than {MAX_AUTHOR_BYTES} bytes",
            id
        ));
    }
    if author.contains('\0') {
        return refuse(format!("annotation {:?} has a NUL in its author", id));
    }
    Ok(())
}

pub fn validate_bookmark_title(id: &str, title: &str) -> Result<(), RuleError> {
    if title.len() > MAX_BOOKMARK_TITLE_BYTES {
        return refuse(format!(
            "bookmark {:?} has a title longer than {MAX_BOOKMARK_TITLE_BYTES} bytes",
            id
        ));
    }
    if title.contains('\0') {
        return refuse(format!("bookmark {:?} has a NUL in its title", id));
    }
    Ok(())
}

pub fn validate_stamp_text(id: &str, text: &str) -> Result<(), RuleError> {
    if text.trim().is_empty() {
        return refuse(format!("stamp annotation {:?} has no text", id));
    }
    if text.len() > MAX_STAMP_TEXT_BYTES {
        return refuse(format!(
            "stamp annotation {:?} has more than {MAX_STAMP_TEXT_BYTES} bytes of text",
            id
        ));
    }
    Ok(())
}

/// A PDF date string (`D:YYYYMMDDHHmmSS±HH'mm'`). The shell builds it; the writer only accepts
/// the shape it documents.
pub fn validate_pdf_date(id: &str, modified: &str) -> Result<(), RuleError> {
    if modified.starts_with("D:")
        && modified.is_ascii()
        && modified.len() <= 64
        && !modified.contains('\0')
    {
        Ok(())
    } else {
        refuse(format!("annotation {:?} has a malformed PDF date", id))
    }
}

// ── Style and geometry limits ───────────────────────────────────────────────

pub fn validate_opacity(id: &str, opacity: f64) -> Result<(), RuleError> {
    if opacity.is_finite() && (MIN_OPACITY..=MAX_OPACITY).contains(&opacity) {
        Ok(())
    } else {
        refuse(format!("annotation {:?} has an opacity outside 0…1", id))
    }
}

pub fn validate_border_width(id: &str, width: f64) -> Result<(), RuleError> {
    if width.is_finite() && width > 0.0 && width <= MAX_BORDER_WIDTH_PT {
        Ok(())
    } else {
        refuse(format!(
            "annotation {:?} has a border width outside 0…{MAX_BORDER_WIDTH_PT} pt",
            id
        ))
    }
}

pub fn validate_font_size(id: &str, size: f64) -> Result<(), RuleError> {
    if size.is_finite() && (MIN_FONT_SIZE_PT..=MAX_FONT_SIZE_PT).contains(&size) {
        Ok(())
    } else {
        refuse(format!(
            "annotation {:?} has a font size outside {MIN_FONT_SIZE_PT}…{MAX_FONT_SIZE_PT} pt",
            id
        ))
    }
}

pub fn validate_alignment(id: &str, alignment: &str) -> Result<(), RuleError> {
    if matches!(alignment, "left" | "center" | "right") {
        Ok(())
    } else {
        refuse(format!(
            "annotation {:?} has an alignment {alignment:?}; expected left, center or right",
            id
        ))
    }
}

pub fn validate_stamp_style(id: &str, style: &str) -> Result<(), RuleError> {
    if matches!(
        style,
        "approved" | "reviewed" | "draft" | "confidential" | "date" | "custom"
    ) {
        Ok(())
    } else {
        refuse(format!(
            "stamp annotation {:?} has an unknown style {:?}",
            id, style
        ))
    }
}

pub fn validate_signature_dimensions(
    id: &str,
    width: u32,
    height: u32,
    rgba_len: usize,
) -> Result<(), RuleError> {
    if width == 0 || height == 0 || width > MAX_STAMP_IMAGE_SIDE || height > MAX_STAMP_IMAGE_SIDE {
        return refuse(format!(
            "signature annotation {:?} has dimensions {}×{}; the limit is {MAX_STAMP_IMAGE_SIDE} on a side",
            id, width, height
        ));
    }
    let expected = width as usize * height as usize * 4;
    if rgba_len != expected {
        return refuse(format!(
            "signature annotation {:?} has {} RGBA byte(s); {}×{} needs {expected}",
            id, rgba_len, width, height
        ));
    }
    Ok(())
}

pub fn validate_quads(id: &str, count: usize) -> Result<(), RuleError> {
    if count > MAX_QUADS {
        return refuse(format!(
            "annotation {:?} has more than {MAX_QUADS} quads",
            id
        ));
    }
    Ok(())
}

// ── Bookmarks ───────────────────────────────────────────────────────────────

/// The bookmark facts the outline writer, the FFI save path and the shell share.
#[derive(Clone, Copy, Debug)]
pub struct BookmarkSpec<'a> {
    pub id: &'a str,
    pub page: i64,
    pub title: &'a str,
    pub y_pt: f64,
}

/// The whole list, in the order the outline writer sees it.
pub fn validate_bookmarks(
    bookmarks: &[BookmarkSpec<'_>],
    page_count: usize,
) -> Result<(), RuleError> {
    if bookmarks.len() > MAX_BOOKMARKS {
        return refuse(format!(
            "{MAX_BOOKMARKS} bookmarks is the most one save can write"
        ));
    }
    let ids: Vec<String> = bookmarks
        .iter()
        .map(|bookmark| bookmark.id.to_string())
        .collect();
    validate_unique_bookmark_ids(&ids)?;
    for bookmark in bookmarks {
        validate_bookmark_identity(bookmark.id)?;
        validate_bookmark_page(bookmark.id, bookmark.page, page_count)?;
        validate_bookmark_y(bookmark.id, bookmark.y_pt)?;
        validate_bookmark_title(bookmark.id, bookmark.title)?;
    }
    Ok(())
}

pub fn validate_bookmark(
    bookmark: &RecordBookmark,
    page_count: usize,
    existing_ids: &[String],
) -> Result<(), RuleError> {
    let mut all: Vec<String> = existing_ids.to_vec();
    all.push(bookmark.id.clone());
    validate_unique_bookmark_ids(&all)?;
    if all.len() > MAX_BOOKMARKS {
        return refuse(format!(
            "{MAX_BOOKMARKS} bookmarks is the most one save can write"
        ));
    }
    validate_bookmark_identity(&bookmark.id)?;
    validate_bookmark_page(&bookmark.id, bookmark.page, page_count)?;
    validate_bookmark_y(&bookmark.id, bookmark.y_pt)?;
    validate_bookmark_title(&bookmark.id, &bookmark.title)?;
    Ok(())
}

// ── Bookmark order ──────────────────────────────────────────────────────────

/// Where a new bookmark lands in the reader's persisted order.
///
/// The order is the reader's manual order. The sidebar shows the list as it is, Move Up/Down
/// changes it, `annotations.json` stores it under the interleaved entry slots, and the outline
/// writer writes it. A new mark is therefore **appended**, even when another mark already sits
/// on the same page: `page` and `y_pt` decide where inside a page a bookmark jumps, never where
/// it sits in the list. Sorting the list by them would silently reorder marks the reader placed.
///
/// The page and position are still part of the rule's input so the shell asks one function
/// instead of deciding an index itself, and a future positional rule can change this one place.
pub fn bookmark_insertion_index(existing: &[BookmarkSpec<'_>], page: i64, y_pt: f64) -> usize {
    // Both are stored facts about the new mark, not sort keys; see the doc comment.
    let _ = (page, y_pt);
    existing.len()
}

/// The index a Move Up/Down request lands on.
///
/// A move past either end stays at that end instead of wrapping; the caller compares the result
/// with the current index and skips the write when they match. `count` is the list length the
/// index refers to, so the shell computes the target before it removes the bookmark.
pub fn moved_bookmark_index(index: usize, offset: i64, count: usize) -> usize {
    if count == 0 {
        return 0;
    }
    let current = index.min(count - 1);
    let target = (current as i64).saturating_add(offset);
    target.clamp(0, count as i64 - 1) as usize
}

/// The entry order `annotations.json` stores after the bookmark list has been reordered.
///
/// Bookmark slots keep their places around every annotation and every preserved foreign entry;
/// the bookmark in position `n` of `ordered_ids` fills the `n`th bookmark slot. A slot left over
/// from a deleted bookmark disappears, and bookmarks added after the file was loaded (adopted
/// from the outline, for example) get a new slot at the end. This is the rule the shell used to
/// apply by hand; it is what keeps a move from shuffling annotations or foreign entries.
///
/// Adding a bookmark is deliberately *not* expressed through this function: it appends a new
/// slot, which keeps a deleted bookmark's slot from being reused before an opaque entry and
/// moving the new mark ahead of it.
pub fn reorder_bookmark_slots(slots: &[Slot], ordered_ids: &[String]) -> Vec<Slot> {
    let mut remaining = ordered_ids.iter();
    let mut reordered = Vec::with_capacity(slots.len());
    for slot in slots {
        if matches!(slot, Slot::Bookmark(_)) {
            if let Some(id) = remaining.next() {
                reordered.push(Slot::Bookmark(id.clone()));
            }
        } else {
            reordered.push(slot.clone());
        }
    }
    for id in remaining {
        reordered.push(Slot::Bookmark(id.clone()));
    }
    reordered
}

// ── Annotations ─────────────────────────────────────────────────────────────

/// A new cached annotation against the document and the annotations already there.
///
/// This is the creation-time twin of the save-time rules. It checks the limits that used to be
/// discovered only when the reader saved into the PDF (page bounds, note length, border width,
/// font size, stamp text/style, identity uniqueness), plus the geometry rules the record codec
/// already applies. It does not re-encode anything.
pub fn validate_annotation(
    annotation: &RecordAnnotation,
    page_count: usize,
    existing_ids: &[String],
) -> Result<(), RuleError> {
    let mut all: Vec<String> = existing_ids.to_vec();
    all.push(annotation.id.clone());
    validate_unique_annotation_ids(&all)?;
    if all.len() > MAX_ANNOTATIONS {
        return refuse(format!(
            "{MAX_ANNOTATIONS} annotations is the most one save can write"
        ));
    }
    validate_annotation_identity(&annotation.id)?;
    validate_page(&annotation.id, annotation.page, page_count)?;
    validate_note(&annotation.id, &annotation.note)?;

    match annotation.kind {
        AnnotationKind::Ink => {
            validate_border_width(&annotation.id, annotation.stroke_width)?;
            if annotation.ink_paths.is_empty() {
                return refuse(format!(
                    "ink annotation {:?} has no /InkList",
                    annotation.id
                ));
            }
            if annotation.ink_paths.len() > MAX_INK_PATHS {
                return refuse(format!(
                    "ink annotation {:?} has more than {MAX_INK_PATHS} strokes",
                    annotation.id
                ));
            }
            let points: usize = annotation.ink_paths.iter().map(Vec::len).sum();
            if points > MAX_INK_POINTS {
                return refuse(format!(
                    "ink annotation {:?} has more than {MAX_INK_POINTS} points",
                    annotation.id
                ));
            }
            if let Some(path) = annotation.ink_paths.iter().find(|path| path.len() < 2) {
                let _ = path;
                return refuse(format!(
                    "ink annotation {:?} has a stroke with fewer than two points",
                    annotation.id
                ));
            }
        }
        AnnotationKind::Square
        | AnnotationKind::Circle
        | AnnotationKind::Line
        | AnnotationKind::Arrow => {
            validate_border_width(&annotation.id, annotation.stroke_width)?;
        }
        AnnotationKind::TextBox => {
            validate_font_size(&annotation.id, annotation.font_size)?;
            if let Some(alignment) = &annotation.text_alignment {
                validate_alignment(&annotation.id, alignment)?;
            }
        }
        AnnotationKind::Stamp => {
            validate_stamp_text(&annotation.id, &annotation.note)?;
            if let Some(style) = &annotation.stamp_style {
                validate_stamp_style(&annotation.id, style)?;
            }
        }
        AnnotationKind::Signature => {
            if !annotation.note.is_empty() {
                return refuse(format!(
                    "signature annotation {:?} must not carry text",
                    annotation.id
                ));
            }
            if annotation.image_data.as_ref().is_none_or(Vec::is_empty) {
                return refuse(format!(
                    "signature annotation {:?} has no image",
                    annotation.id
                ));
            }
        }
        // Text markup has no geometry/border/font of its own; a sticky note's box is checked by
        // `has_valid_geometry` below.
        AnnotationKind::Highlight
        | AnnotationKind::Underline
        | AnnotationKind::Strikeout
        | AnnotationKind::Squiggly
        | AnnotationKind::StickyNote
        | AnnotationKind::Other(_) => {}
    }

    if annotation.kind.flags().is_placement && !annotation.has_valid_geometry() {
        return refuse(format!(
            "annotation {:?} has incomplete or non-finite geometry",
            annotation.id
        ));
    }
    Ok(())
}

// ── Clamps ──────────────────────────────────────────────────────────────────

/// `/CA` as the reader draws it: a malformed opacity is the nearest legal one, never a trap.
pub fn clamp_opacity(opacity: f64) -> f64 {
    if opacity.is_finite() {
        opacity.clamp(MIN_OPACITY, MAX_OPACITY)
    } else {
        MAX_OPACITY
    }
}

pub fn clamp_border_width(width: f64) -> f64 {
    if width.is_finite() {
        width.clamp(0.0, MAX_BORDER_WIDTH_PT)
    } else {
        0.0
    }
}

pub fn clamp_font_size(size: f64) -> f64 {
    if size.is_finite() {
        size.clamp(MIN_FONT_SIZE_PT, MAX_FONT_SIZE_PT)
    } else {
        MIN_FONT_SIZE_PT
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::records::{PaletteColor, RecordAnnotation, RecordBookmark};

    fn annotation(kind: AnnotationKind, page: i64) -> RecordAnnotation {
        RecordAnnotation {
            id: "0F7A2B4C-1111-4222-8333-444455556666".into(),
            kind,
            page,
            start: 0,
            end: 3,
            color: PaletteColor::new(0xFF, 0xD8, 0x40, 0x66),
            note: String::new(),
            created_at: 804_000_000.5,
            ink_paths: vec![vec![
                crate::records::StoredPoint::new(1.0, 2.0),
                crate::records::StoredPoint::new(3.0, 4.0),
            ]],
            shape_rect: Some(crate::records::StoredRect::new(1.0, 2.0, 30.0, 40.0)),
            line_start: Some(crate::records::StoredPoint::new(1.0, 2.0)),
            line_end: Some(crate::records::StoredPoint::new(30.0, 40.0)),
            stroke_width: 2.0,
            font_size: 14.0,
            file_identity: None,
            file_quads: None,
            text_alignment: Some("left".into()),
            stamp_style: Some("approved".into()),
            image_data: Some(vec![1, 2, 3]),
        }
    }

    fn bookmark(id: &str, page: i64, title: &str, y_pt: f64) -> RecordBookmark {
        RecordBookmark {
            id: id.into(),
            page,
            title: title.into(),
            y_pt,
            created_at: 804_000_000.0,
        }
    }

    #[test]
    fn page_bounds_use_one_based_pages() {
        let id = "0F7A2B4C-1111-4222-8333-444455556666";
        assert_eq!(
            validate_page(id, 5, 5).unwrap_err().message,
            format!("annotation {id:?} names page 6, but the document has 5 page(s)")
        );
        assert!(validate_page(id, 4, 5).is_ok());
        assert!(validate_page(id, 0, 1).is_ok());
        assert_eq!(
            validate_bookmark_page("id", 5, 5).unwrap_err().message,
            "bookmark \"id\" names page 6, but the document has 5 page(s)"
        );
    }

    #[test]
    fn bookmark_limits_match_the_outline_writer() {
        let ok = bookmark("id", 0, "title", 12.0);
        assert!(validate_bookmark(&ok, 1, &[]).is_ok());
        assert_eq!(
            validate_bookmark(&bookmark("", 0, "t", 0.0), 1, &[])
                .unwrap_err()
                .message,
            "a bookmark identity must be 1–128 printable ASCII characters"
        );
        assert_eq!(
            validate_bookmark(&bookmark("id", 1, "t", 0.0), 1, &[])
                .unwrap_err()
                .message,
            "bookmark \"id\" names page 2, but the document has 1 page(s)"
        );
        assert_eq!(
            validate_bookmark(&bookmark("id", 0, "t", -1.0), 1, &[])
                .unwrap_err()
                .message,
            "bookmark \"id\" has a Y that is not finite and non-negative"
        );
        assert_eq!(
            validate_bookmark(&bookmark("id", 0, "t", f64::NAN), 1, &[])
                .unwrap_err()
                .message,
            "bookmark \"id\" has a Y that is not finite and non-negative"
        );
        let long = "x".repeat(MAX_BOOKMARK_TITLE_BYTES + 1);
        assert_eq!(
            validate_bookmark(&bookmark("id", 0, &long, 0.0), 1, &[])
                .unwrap_err()
                .message,
            "bookmark \"id\" has a title longer than 4096 bytes"
        );
        assert_eq!(
            validate_bookmark(&bookmark("id", 0, "a\0b", 0.0), 1, &[])
                .unwrap_err()
                .message,
            "bookmark \"id\" has a NUL in its title"
        );
        assert_eq!(
            validate_bookmark(&bookmark("id", 0, "t", 0.0), 5, &["id".into()])
                .unwrap_err()
                .message,
            "two bookmarks in one save share the identity \"id\""
        );
        // The creation-time check enforces the list limit the writer already enforced, so the
        // shell cannot append a 5,001st bookmark that only fails when the PDF is saved.
        let existing: Vec<String> = (0..MAX_BOOKMARKS)
            .map(|index| format!("existing-{index}"))
            .collect();
        assert_eq!(
            validate_bookmark(&bookmark("new", 0, "t", 0.0), 1, &existing)
                .unwrap_err()
                .message,
            "5000 bookmarks is the most one save can write"
        );
        assert!(
            validate_bookmark(
                &bookmark("new", 0, "t", 0.0),
                1,
                &existing[..MAX_BOOKMARKS - 1]
            )
            .is_ok()
        );
        let many: Vec<RecordBookmark> = (0..=MAX_BOOKMARKS)
            .map(|index| bookmark(&format!("id-{index}"), 0, "t", 0.0))
            .collect();
        let specs: Vec<BookmarkSpec<'_>> = many
            .iter()
            .map(|bookmark| BookmarkSpec {
                id: &bookmark.id,
                page: bookmark.page,
                title: &bookmark.title,
                y_pt: bookmark.y_pt,
            })
            .collect();
        assert_eq!(
            validate_bookmarks(&specs, 1).unwrap_err().message,
            "5000 bookmarks is the most one save can write"
        );
    }

    #[test]
    fn bookmark_order_is_manual_and_moves_clamp_at_the_ends() {
        let one = bookmark("one", 0, "one", 10.0);
        let two = bookmark("two", 0, "two", 20.0);
        let three = bookmark("three", 1, "three", 0.0);
        let specs: Vec<BookmarkSpec<'_>> = [&one, &two, &three]
            .into_iter()
            .map(|bookmark| BookmarkSpec {
                id: &bookmark.id,
                page: bookmark.page,
                title: &bookmark.title,
                y_pt: bookmark.y_pt,
            })
            .collect();
        // A new mark on the same page — above or below the others — still goes last.
        assert_eq!(bookmark_insertion_index(&specs, 0, 0.0), 3);
        assert_eq!(bookmark_insertion_index(&specs, 0, 999.0), 3);
        assert_eq!(bookmark_insertion_index(&specs, 1, 0.0), 3);
        assert_eq!(bookmark_insertion_index(&[], 0, 0.0), 0);

        // Moving by one at either end is a no-op; a large offset clamps to the end.
        assert_eq!(moved_bookmark_index(0, -1, 3), 0);
        assert_eq!(moved_bookmark_index(2, 1, 3), 2);
        assert_eq!(moved_bookmark_index(1, 1, 3), 2);
        assert_eq!(moved_bookmark_index(1, -1, 3), 0);
        assert_eq!(moved_bookmark_index(0, 100, 3), 2);
        assert_eq!(moved_bookmark_index(2, -100, 3), 0);
        assert_eq!(moved_bookmark_index(0, 0, 0), 0);
        // A stale index cannot leave the list.
        assert_eq!(moved_bookmark_index(9, 0, 3), 2);
    }

    #[test]
    fn reordering_bookmarks_keeps_other_entries_in_place() {
        let slots = vec![
            Slot::Annotation("a1".into()),
            Slot::Bookmark("b1".into()),
            Slot::Opaque("{\"kind\":\"future\"}".into()),
            Slot::Bookmark("b2".into()),
            Slot::Bookmark("deleted".into()),
            Slot::Annotation("a2".into()),
        ];
        // b2 and b1 swap; the deleted bookmark's slot disappears; annotations and the foreign
        // entry keep their positions.
        assert_eq!(
            reorder_bookmark_slots(&slots, &["b2".into(), "b1".into()]),
            vec![
                Slot::Annotation("a1".into()),
                Slot::Bookmark("b2".into()),
                Slot::Opaque("{\"kind\":\"future\"}".into()),
                Slot::Bookmark("b1".into()),
                Slot::Annotation("a2".into()),
            ]
        );
        // A bookmark adopted after load has no slot yet and is appended when every slot is used.
        let without_deleted = vec![
            Slot::Annotation("a1".into()),
            Slot::Bookmark("b1".into()),
            Slot::Opaque("{\"kind\":\"future\"}".into()),
            Slot::Bookmark("b2".into()),
            Slot::Annotation("a2".into()),
        ];
        assert_eq!(
            reorder_bookmark_slots(
                &without_deleted,
                &["b1".into(), "b2".into(), "adopted".into()]
            ),
            vec![
                Slot::Annotation("a1".into()),
                Slot::Bookmark("b1".into()),
                Slot::Opaque("{\"kind\":\"future\"}".into()),
                Slot::Bookmark("b2".into()),
                Slot::Annotation("a2".into()),
                Slot::Bookmark("adopted".into()),
            ]
        );
        assert_eq!(reorder_bookmark_slots(&[], &[]), Vec::<Slot>::new());
    }

    #[test]
    fn annotation_limits_reject_what_the_writer_rejects() {
        let id = "0F7A2B4C-1111-4222-8333-444455556666";
        let mut highlight = annotation(AnnotationKind::Highlight, 0);
        highlight.note = "x".repeat(MAX_NOTE_BYTES + 1);
        assert_eq!(
            validate_annotation(&highlight, 1, &[]).unwrap_err().message,
            format!("annotation {id:?} has more than 100000 bytes of text")
        );
        let mut highlight = annotation(AnnotationKind::Highlight, 1);
        assert_eq!(
            validate_annotation(&highlight, 1, &[]).unwrap_err().message,
            format!("annotation {id:?} names page 2, but the document has 1 page(s)")
        );
        highlight.page = 0;
        highlight.note = "a\0b".into();
        assert_eq!(
            validate_annotation(&highlight, 1, &[]).unwrap_err().message,
            format!("annotation {id:?} has a NUL in its contents")
        );
        let mut square = annotation(AnnotationKind::Square, 0);
        square.stroke_width = 201.0;
        assert_eq!(
            validate_annotation(&square, 1, &[]).unwrap_err().message,
            format!("annotation {id:?} has a border width outside 0…200 pt")
        );
        let mut text_box = annotation(AnnotationKind::TextBox, 0);
        text_box.font_size = 0.0;
        assert_eq!(
            validate_annotation(&text_box, 1, &[]).unwrap_err().message,
            format!("annotation {id:?} has a font size outside 1…400 pt")
        );
        text_box.font_size = 401.0;
        assert!(validate_annotation(&text_box, 1, &[]).is_err());
        let mut stamp = annotation(AnnotationKind::Stamp, 0);
        stamp.note = "  ".into();
        assert_eq!(
            validate_annotation(&stamp, 1, &[]).unwrap_err().message,
            format!("stamp annotation {id:?} has no text")
        );
        stamp.note = "words".into();
        stamp.stamp_style = Some("nope".into());
        assert_eq!(
            validate_annotation(&stamp, 1, &[]).unwrap_err().message,
            format!("stamp annotation {id:?} has an unknown style \"nope\"")
        );
        assert_eq!(
            validate_annotation(&annotation(AnnotationKind::Square, 0), 1, &[id.into()])
                .unwrap_err()
                .message,
            format!("two annotations in one save share the identity {id:?}")
        );
        assert!(validate_annotation(&annotation(AnnotationKind::Square, 0), 1, &[]).is_ok());
        assert!(validate_annotation(&annotation(AnnotationKind::Highlight, 0), 1, &[]).is_ok());
        assert!(validate_annotation(&annotation(AnnotationKind::Ink, 0), 1, &[]).is_ok());
        assert!(validate_annotation(&annotation(AnnotationKind::Line, 0), 1, &[]).is_ok());
        assert!(validate_annotation(&annotation(AnnotationKind::TextBox, 0), 1, &[]).is_ok());
        let mut stamp_ok = annotation(AnnotationKind::Stamp, 0);
        stamp_ok.note = "words".into();
        assert!(validate_annotation(&stamp_ok, 1, &[]).is_ok());
    }

    #[test]
    fn clamps_are_the_documented_ranges() {
        assert_eq!(clamp_opacity(-1.0), 0.0);
        assert_eq!(clamp_opacity(2.0), 1.0);
        assert_eq!(clamp_opacity(f64::NAN), 1.0);
        assert_eq!(clamp_border_width(-1.0), 0.0);
        assert_eq!(clamp_border_width(500.0), 200.0);
        assert_eq!(clamp_font_size(0.0), 1.0);
        assert_eq!(clamp_font_size(500.0), 400.0);
    }
}

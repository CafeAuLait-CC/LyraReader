//! Swift-parity text selection.
//!
//! The shell's interactive hit-testing and box→range logic lives in
//! `apps/macos/Sources/LyraReaderKit/Engine.swift` (`TextPage.characterIndex`,
//! `SelectionLine.build`, `TextPage.characterRange`). This module is a line-by-line port of
//! those rules, not a new algorithm: PDF glyph boxes describe ink, so an "exact containment"
//! hit-test answers a different question from the one the pointer path asks. The benchmark in
//! `docs/23-audit-todo.md` C1 measured the gap: on 2,500 frozen points the old containment scan
//! disagreed with Swift on 44.4% of closest indices, 31.4% of box ranges and 85.7% of
//! box→character sets. The port keeps Swift's answers, including the places where Swift is
//! arguably wrong:
//!
//! * a box that overlaps two columns selects the **whole span** between them (Swift's
//!   `first...last` range has no line/column awareness), and
//! * a loose line-number gutter box participates in the column and vertical-overlap rules.
//!
//! Those are deliberately reproduced for parity and recorded as future work rather than
//! "fixed", because changing them would change pointer and annotation behaviour.
//!
//! # Coordinate space
//!
//! Character boxes are **view space** (points, top-left origin, y grows downward), exactly the
//! values `LyraReaderDocument::text_page` returns. No transform is applied here.
//!
//! # What is line-aware
//!
//! [`SelectionTextPage::char_index_at`] is the line-aware path (Swift `TextPage.characterIndex`).
//! [`crate::TextPage::char_index_at`] remains the legacy exact-containment scan used by older
//! callers; it is deliberately **not** the interactive path.

use unicode_segmentation::UnicodeSegmentation;

use crate::{CharBox, CharIndex, TextPage};
use lyra_reader_core::{Point, Rect};

/// One hit-test stop inside a [`SelectionLine`].
///
/// A stop is normally one PDF glyph box. It can also be an **interpolated space** between two
/// glyphs: PDFium often gives whitespace a zero-size or unrelated box, and Swift invents a box
/// inside the gap so a drag through an inter-word space still resolves to the space character.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SelectionStop {
    /// Index into the page's character array.
    pub index: u32,
    /// The box used for distance and intersection tests (view space).
    pub rect: Rect,
}

/// One visual line, with the stops that belong to it.
///
/// The line box is the union of its glyph boxes; interpolated spaces use the line's stable
/// height, matching Swift's `SelectionLine.bounds`.
#[derive(Clone, Debug, PartialEq)]
pub struct SelectionLine {
    pub bounds: Rect,
    pub stops: Vec<SelectionStop>,
}

/// The line decomposition Swift builds once per page (`SelectionLine.build`).
///
/// Building is intentionally separate from a page so the engine can build it once, keep it in
/// its byte-bounded cache, and answer every pointer event without repeating the scan.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SelectionLayout {
    lines: Vec<SelectionLine>,
}

impl SelectionLayout {
    /// Port of `SelectionLine.build(_:)` (`Engine.swift:381-417`).
    ///
    /// Order matters and is preserved exactly:
    /// 1. `\n`/`\r` end the current line and are not stops;
    /// 2. Swift's `CharacterSet.whitespaces` characters are not stops (a space with real ink
    ///    still joins the line, it is simply not a selectable stop);
    /// 3. non-positive boxes are skipped;
    /// 4. a glyph joins the current line when the vertical overlap is at least 35% of the
    ///    smaller of the two heights;
    /// 5. missing space boxes between the previous stop and this glyph are interpolated across
    ///    the horizontal gap before the line box is widened.
    pub fn build(chars: &[CharBox]) -> Self {
        let mut lines: Vec<SelectionLine> = Vec::new();
        let mut current: Option<SelectionLine> = None;

        for (index, character) in chars.iter().enumerate() {
            if character.unicode == 10 || character.unicode == 13 {
                if let Some(line) = current.take() {
                    lines.push(line);
                }
                continue;
            }
            // PDFium may give whitespace a zero box or an unrelated y coordinate.
            if is_swift_whitespace(character.unicode) {
                continue;
            }
            let rect = character.rect;
            if !(rect.size.width > 0.0 && rect.size.height > 0.0) {
                continue;
            }
            if let Some(mut line) = current.take() {
                let overlap =
                    line.bounds.max_y().min(rect.max_y()) - line.bounds.min_y().max(rect.min_y());
                if overlap >= line.bounds.size.height.min(rect.size.height) * 0.35 {
                    // Interpolate missing space boxes between neighbouring ink boxes.
                    if let Some(previous) = line.stops.last().copied() {
                        let previous_index = previous.index as usize;
                        if previous_index + 1 < index {
                            let gaps = &chars[previous_index + 1..index];
                            let width =
                                (rect.min_x() - previous.rect.max_x()).max(0.0) / gaps.len() as f64;
                            for (offset, gap) in gaps.iter().enumerate() {
                                if is_swift_whitespace(gap.unicode) {
                                    line.stops.push(SelectionStop {
                                        index: (previous_index + 1 + offset) as u32,
                                        rect: Rect::new(
                                            previous.rect.max_x() + offset as f64 * width,
                                            line.bounds.min_y(),
                                            width,
                                            line.bounds.size.height,
                                        ),
                                    });
                                }
                            }
                        }
                    }
                    line.bounds = line.bounds.union(rect);
                    line.stops.push(SelectionStop {
                        index: index as u32,
                        rect,
                    });
                    current = Some(line);
                    continue;
                }
                lines.push(line);
            }
            current = Some(SelectionLine {
                bounds: rect,
                stops: vec![SelectionStop {
                    index: index as u32,
                    rect,
                }],
            });
        }
        if let Some(line) = current {
            lines.push(line);
        }

        for line in &mut lines {
            line.stops.shrink_to_fit();
        }
        lines.shrink_to_fit();
        Self { lines }
    }

    pub fn lines(&self) -> &[SelectionLine] {
        &self.lines
    }

    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }

    /// Approximate heap size of this layout, used by the engine's byte-bounded cache.
    pub fn estimated_bytes(&self) -> usize {
        self.lines.capacity() * std::mem::size_of::<SelectionLine>()
            + self
                .lines
                .iter()
                .map(|line| line.stops.capacity() * std::mem::size_of::<SelectionStop>())
                .sum::<usize>()
    }

    /// Port of `TextPage.characterIndex(at:extendingSelection:)` (`Engine.swift:316-374`).
    ///
    /// Returns `nil` in every case Swift returns `nil`:
    /// * there are no selection lines at all;
    /// * the chosen line is more than `max(1.5 × line height, 14 pt)` away vertically;
    /// * a drag (`extendingSelection`) outside the line has no usable upper/lower neighbour.
    ///
    /// `extendingSelection` also enables Swift's visual-neighbour rule: a drag into the gap
    /// between two lines resolves to the last stop of the upper line (or one before the first
    /// stop of the lower line) instead of failing.
    pub fn char_index_at(&self, point: Point, extending_selection: bool) -> Option<u32> {
        fn distance(value: f64, low: f64, high: f64) -> f64 {
            (low - value).max(value - high).max(0.0)
        }
        fn squared_distance(point: Point, rect: Rect) -> f64 {
            let dx = distance(point.x, rect.min_x(), rect.max_x());
            let dy = distance(point.y, rect.min_y(), rect.max_y());
            dx * dx + dy * dy
        }

        // Find the horizontal text column first. A loose box in a distant line-number gutter
        // may extend into the body's interline gap; its exact y hit must not beat the body only
        // a fraction of a point away.
        let mut column: Option<&SelectionLine> = None;
        for line in &self.lines {
            let better = match column {
                None => true,
                Some(current) => {
                    squared_distance(point, line.bounds) < squared_distance(point, current.bounds)
                }
            };
            if better {
                column = Some(line);
            }
        }
        let column = column?;

        // Lines that overlap the chosen column horizontally (strict overlap, as Swift's
        // `min(maxX) > max(minX)`).
        let column_lines: Vec<&SelectionLine> = self
            .lines
            .iter()
            .filter(|line| {
                line.bounds.max_x().min(column.bounds.max_x())
                    > line.bounds.min_x().max(column.bounds.min_x())
            })
            .collect();

        let mut line: Option<&SelectionLine> = None;
        for candidate in &column_lines {
            let better = match line {
                None => true,
                Some(current) => {
                    let ay = distance(point.y, candidate.bounds.min_y(), candidate.bounds.max_y());
                    let by = distance(point.y, current.bounds.min_y(), current.bounds.max_y());
                    if ay != by {
                        ay < by
                    } else {
                        let ax =
                            distance(point.x, candidate.bounds.min_x(), candidate.bounds.max_x());
                        let bx = distance(point.x, current.bounds.min_x(), current.bounds.max_x());
                        if ax != bx {
                            ax < bx
                        } else {
                            (candidate.bounds.center().y - point.y).abs()
                                < (current.bounds.center().y - point.y).abs()
                        }
                    }
                }
            };
            if better {
                line = Some(candidate);
            }
        }
        let line = line?;

        if extending_selection && (point.y < line.bounds.min_y() || point.y > line.bounds.max_y()) {
            // Use visual neighbors within the column, independent of the order in which the
            // PDF producer emitted its text objects. Ties keep the earlier line, like Swift's
            // `max(by:)`/`min(by:)` on an array.
            let mut upper: Option<&SelectionLine> = None;
            for candidate in &column_lines {
                if candidate.bounds.max_y() < point.y
                    && upper.is_none_or(|current| candidate.bounds.max_y() > current.bounds.max_y())
                {
                    upper = Some(candidate);
                }
            }
            let mut lower: Option<&SelectionLine> = None;
            for candidate in &column_lines {
                if candidate.bounds.min_y() > point.y
                    && lower.is_none_or(|current| candidate.bounds.min_y() < current.bounds.min_y())
                {
                    lower = Some(candidate);
                }
            }
            if let (Some(upper), Some(lower)) = (upper, lower) {
                let horizontal_overlap = upper.bounds.max_x().min(lower.bounds.max_x())
                    > upper.bounds.min_x().max(lower.bounds.min_x());
                if horizontal_overlap
                    && let (Some(last), Some(first)) = (upper.stops.last(), lower.stops.first())
                    && last.index < first.index
                {
                    return Some(last.index.max(first.index - 1));
                }
            }
        }

        if (line.bounds.center().y - point.y).abs() >= (line.bounds.size.height * 1.5).max(14.0) {
            return None;
        }

        // Nearest stop in x; ties keep the earlier stop and then the closer centre, exactly as
        // Swift's `min(by:)` comparator does.
        let mut best: Option<&SelectionStop> = None;
        for stop in &line.stops {
            let stop_distance = distance(point.x, stop.rect.min_x(), stop.rect.max_x());
            let better = match best {
                None => true,
                Some(current) => {
                    let current_distance =
                        distance(point.x, current.rect.min_x(), current.rect.max_x());
                    if stop_distance != current_distance {
                        stop_distance < current_distance
                    } else {
                        (stop.rect.center().x - point.x).abs()
                            < (current.rect.center().x - point.x).abs()
                    }
                }
            };
            if better {
                best = Some(stop);
            }
        }
        best.map(|stop| stop.index)
    }

    /// Port of `TextPage.characterRange(in:)` (`Engine.swift:4307-4325`).
    ///
    /// A stop counts when `CGRect.intersects` is true. The returned range is the **span from
    /// the first to the last matching stop**, not the set of matching characters: a box that
    /// overlaps two columns therefore returns everything between them, as Swift does. Callers
    /// that need the set can iterate the span (that is what the shell's highlight drawing does).
    pub fn character_range(&self, rect: Rect) -> Option<(u32, u32)> {
        let mut first: Option<u32> = None;
        let mut last: Option<u32> = None;
        for line in &self.lines {
            for stop in &line.stops {
                if intersects(stop.rect, rect) {
                    first.get_or_insert(stop.index);
                    last = Some(stop.index);
                }
            }
        }
        match (first, last) {
            (Some(first), Some(last)) if first <= last => Some((first, last)),
            _ => None,
        }
    }
}

/// One page's text plus the line decomposition the Swift shell builds when it loads the page.
///
/// The engine caches this value per document; callers that only need the old per-character
/// containment API can keep using [`TextPage`]. It deliberately does **not** retain the source
/// [`TextPage`]: every selectable box already lives in the layout stops, and range→string needs
/// only the Unicode scalar per index. Keeping the 64-byte `CharBox` vector as well would limit
/// the engine cache to two large pages instead of five (see the C1 byte budget).
#[derive(Clone, Debug, PartialEq)]
pub struct SelectionTextPage {
    page: lyra_reader_core::PageIndex,
    /// Unicode scalar per character index, including whitespace and characters that are not
    /// layout stops. Invalid scalars are preserved so `string_in_range` can drop them exactly
    /// like Swift's `compactMap`.
    chars: Vec<u32>,
    layout: SelectionLayout,
}

impl SelectionTextPage {
    pub fn new(page: TextPage) -> Self {
        let layout = SelectionLayout::build(&page.chars);
        Self {
            page: page.page,
            chars: page
                .chars
                .iter()
                .map(|character| character.unicode)
                .collect(),
            layout,
        }
    }

    pub fn page(&self) -> lyra_reader_core::PageIndex {
        self.page
    }

    /// Character scalars (including whitespace) by index.
    pub fn chars(&self) -> &[u32] {
        &self.chars
    }

    pub fn layout(&self) -> &SelectionLayout {
        &self.layout
    }

    /// The line-aware hit test; see [`SelectionLayout::char_index_at`].
    pub fn char_index_at(&self, point: Point, extending_selection: bool) -> Option<CharIndex> {
        self.layout
            .char_index_at(point, extending_selection)
            .map(CharIndex)
    }

    /// The line-aware box→range; see [`SelectionLayout::character_range`].
    pub fn character_range(&self, rect: Rect) -> Option<(CharIndex, CharIndex)> {
        self.layout
            .character_range(rect)
            .map(|(first, last)| (CharIndex(first), CharIndex(last)))
    }

    /// Port of `TextPage.string(in:)` (`Engine.swift:4284-4312`).
    ///
    /// Clamps to the page's character range and drops Unicode scalars Swift's
    /// `Unicode.Scalar(_:)` rejects (surrogates and values above `U+10FFFF`). Swift traps when
    /// a range lies entirely beyond the page, a case no production caller reaches because they
    /// validate first; this returns an empty string there.
    pub fn string_in_range(&self, start: u32, end: u32) -> String {
        let chars = &self.chars;
        if chars.is_empty() {
            return String::new();
        }
        let upper = chars.len() - 1;
        let low = start as usize;
        let high = (end as usize).min(upper);
        if low > high || low > upper {
            return String::new();
        }
        chars[low..=high]
            .iter()
            .filter_map(|character| char::from_u32(*character))
            .collect()
    }

    /// Approximate heap size used by the engine's cache budget.
    pub fn estimated_bytes(&self) -> usize {
        std::mem::size_of::<Self>()
            + self.chars.capacity() * std::mem::size_of::<u32>()
            + self.layout.estimated_bytes()
    }
}

/// Port of `Unicode.Scalar(c).map(CharacterSet.whitespaces.contains) == true`.
///
/// On macOS 26.3 `CharacterSet.whitespaces` is exactly these ranges (enumerated with a
/// throwaway probe): tab, the `Zs` separators, and `U+200B`. It deliberately excludes
/// `\n`, `\r`, vertical tab and form feed. The set is spelled out instead of using
/// `char::is_whitespace`, which is broader and would change line grouping.
pub fn is_swift_whitespace(unicode: u32) -> bool {
    matches!(
        unicode,
        0x0009 | 0x0020 | 0x00A0 | 0x1680 | 0x2000..=0x200B | 0x202F | 0x205F | 0x3000
    )
}

/// `CGRect.intersects`: strict overlap on both axes, but a zero-width or zero-height rectangle
/// still intersects when it lies *inside* the other one (verified against CoreGraphics; see
/// `SelectionLayout::character_range`).
pub(crate) fn intersects(a: Rect, b: Rect) -> bool {
    a.min_x() < b.max_x() && b.min_x() < a.max_x() && a.min_y() < b.max_y() && b.min_y() < a.max_y()
}

/// The cap the shell applies to one marquee-selected region, measured in extended grapheme
/// clusters (Swift `Character`s), the unit of the removed `String.prefix(limit)`.
///
/// The same number bounds the AI planner's `MAX_REGION_TEXT_CHARS`; extraction stops at it and
/// reports that it did, never silently sending a longer region.
pub const MAX_REGION_TEXT_CHARS: usize = 12_000;

#[derive(Clone, Copy, Debug, PartialEq)]
struct RegionGlyph {
    x: f64,
    max_x: f64,
    text: char,
    is_space: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
struct RegionLine {
    min_y: f64,
    max_y: f64,
    height: f64,
    glyphs: Vec<RegionGlyph>,
}

/// `CGRect.contains`: a point on the minimum edges is inside, a point on the maximum edges is
/// outside. A zero-area rectangle contains nothing.
fn contains_point(rect: Rect, point: Point) -> bool {
    rect.size.width > 0.0
        && rect.size.height > 0.0
        && point.x >= rect.min_x()
        && point.x < rect.max_x()
        && point.y >= rect.min_y()
        && point.y < rect.max_y()
}

/// `CharacterSet.whitespacesAndNewlines` for one scalar. The set is `whitespaces` plus the line
/// separators Swift also trims at the ends of an extracted region.
pub fn is_swift_whitespace_or_newline(unicode: u32) -> bool {
    is_swift_whitespace(unicode) || matches!(unicode, 0x000A..=0x000D | 0x0085 | 0x2028 | 0x2029)
}

fn trim_region(text: &str) -> &str {
    text.trim_matches(|character: char| is_swift_whitespace(character as u32))
}

fn trim_region_ends(text: &str) -> &str {
    text.trim_matches(|character: char| is_swift_whitespace_or_newline(character as u32))
}

/// Extract the text layer inside a page-local rectangle.
///
/// This is the rectangle-coverage selection mode that used to live in Swift
/// (`AIRegionText.extract`). It is kept in the same module as the pointer selection so the
/// shell's copied text, annotation quotes and region text all resolve against one page model
/// and one whitespace/glyph vocabulary; the acceptance rule differs deliberately:
///
/// * a glyph counts when its centre is inside the rectangle or at least 45% of its area is
///   covered (the pointer path uses hit-testing, not rectangle coverage);
/// * lines are assembled with a vertical-centre tolerance of `max(2.5, height × 0.45)`, in the
///   text layer's emission order (the pointer path builds visual lines once per page);
/// * glyphs in a line are sorted by x, and a space is inserted when the gap exceeds
///   `max(1.2, line height × 0.12)`; real whitespace glyphs collapse to one space.
///
/// The result is exactly the string the shell extracted before this moved to Rust: at most
/// `limit` extended grapheme clusters (Swift `Character`s), joined with a newline per line and
/// trimmed at both ends. `truncated` means the limit cut the assembled text; a cluster is never
/// split.
pub fn region_text(chars: &[CharBox], region: Rect, limit: usize) -> (String, bool) {
    let mut lines: Vec<RegionLine> = Vec::new();
    for character in chars {
        if character.unicode == 10 || character.unicode == 13 {
            continue;
        }
        let rect = character.rect;
        if !(rect.size.width > 0.0 && rect.size.height > 0.0) {
            continue;
        }
        let intersects_region = intersects(rect, region);
        let centre = rect.center();
        let covered = if intersects_region {
            let intersection = Rect::new(
                rect.min_x().max(region.min_x()),
                rect.min_y().max(region.min_y()),
                (rect.max_x().min(region.max_x()) - rect.min_x().max(region.min_x())).max(0.0),
                (rect.max_y().min(region.max_y()) - rect.min_y().max(region.min_y())).max(0.0),
            );
            intersection.size.width * intersection.size.height
                / (rect.size.width * rect.size.height).max(0.001)
        } else {
            0.0
        };
        if !(contains_point(region, centre) || covered >= 0.45) {
            continue;
        }
        let scalar = char::from_u32(character.unicode).unwrap_or('\u{FFFD}');
        let glyph = RegionGlyph {
            x: rect.min_x(),
            max_x: rect.max_x(),
            text: scalar,
            is_space: is_swift_whitespace(character.unicode),
        };
        let tolerance = (rect.size.height * 0.45).max(2.5);
        let existing = lines
            .iter()
            .rposition(|line| ((line.min_y + line.max_y) / 2.0 - centre.y).abs() <= tolerance);
        if let Some(index) = existing {
            let line = &mut lines[index];
            line.min_y = line.min_y.min(rect.min_y());
            line.max_y = line.max_y.max(rect.max_y());
            line.height = line.height.max(rect.size.height);
            line.glyphs.push(glyph);
        } else {
            lines.push(RegionLine {
                min_y: rect.min_y(),
                max_y: rect.max_y(),
                height: rect.size.height,
                glyphs: vec![glyph],
            });
        }
    }

    let mut result = String::new();
    let mut truncated = false;
    for line in &mut lines {
        line.glyphs
            .sort_by(|a, b| a.x.partial_cmp(&b.x).unwrap_or(std::cmp::Ordering::Equal));
        let mut line_text = String::new();
        let mut previous_max_x: Option<f64> = None;
        for glyph in &line.glyphs {
            if glyph.is_space {
                if !line_text.is_empty() && !line_text.ends_with(' ') {
                    line_text.push(' ');
                }
                previous_max_x =
                    Some(previous_max_x.map_or(glyph.max_x, |previous| previous.max(glyph.max_x)));
                continue;
            }
            if let Some(previous) = previous_max_x {
                let gap = glyph.x - previous;
                if gap > (line.height * 0.12).max(1.2)
                    && !line_text.is_empty()
                    && !line_text.ends_with(' ')
                {
                    line_text.push(' ');
                }
            }
            line_text.push(glyph.text);
            previous_max_x =
                Some(previous_max_x.map_or(glyph.max_x, |previous| previous.max(glyph.max_x)));
        }
        let trimmed = trim_region(&line_text);
        if trimmed.is_empty() {
            continue;
        }
        if !result.is_empty() {
            result.push('\n');
        }
        result.push_str(trimmed);
        // Swift checked `result.count` and took `prefix(limit)`: both count extended grapheme
        // clusters. Counting scalars would cut a decomposed accent or a ZWJ sequence here.
        if result.graphemes(true).count() > limit {
            result = result.graphemes(true).take(limit).collect();
            truncated = true;
            break;
        }
    }
    (trim_region_ends(&result).to_string(), truncated)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn character(unicode: u32, x: f64, y: f64, width: f64, height: f64) -> CharBox {
        CharBox {
            rect: Rect::new(x, y, width, height),
            origin: Point::new(x, y + height),
            unicode,
            font_size: height,
            logical_order: 0,
        }
    }

    fn word(text: &str, x: f64, y: f64, size: f64) -> Vec<CharBox> {
        let mut chars = Vec::new();
        let mut cursor = x;
        for scalar in text.chars() {
            let width = if scalar == ' ' { 0.0 } else { size * 0.45 };
            let height = if scalar == ' ' { 0.0 } else { size };
            chars.push(character(scalar as u32, cursor, y, width, height));
            cursor += if scalar == ' ' { size * 0.25 } else { width };
        }
        chars
    }

    #[test]
    fn region_text_truncates_at_a_grapheme_boundary() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
        // Six thousand decomposed accents are 12,000 scalars; the family and tail follow.
        let nfd = "e\u{301}".repeat(6_000);
        let text = format!("{nfd}{family}tail");
        let chars = word(&text, 0.0, 0.0, 10.0);
        let region = Rect::new(-1.0, -1.0, 400_000.0, 20.0);

        let (capped, truncated) = region_text(&chars, region, 6_000);
        assert!(truncated);
        assert_eq!(capped, nfd, "the scalar cut used to return 3,000 accents");
        assert_eq!(capped.graphemes(true).count(), 6_000);

        let (with_family, truncated) = region_text(&chars, region, 6_001);
        assert!(truncated);
        assert_eq!(with_family, format!("{nfd}{family}"));
        assert!(with_family.ends_with(family), "a ZWJ run is never split");
    }

    #[test]
    fn whitespace_set_matches_swift() {
        for (value, expected) in [
            (0x09, true),
            (0x0A, false),
            (0x0B, false),
            (0x0C, false),
            (0x0D, false),
            (0x20, true),
            (0x85, false),
            (0xA0, true),
            (0x1680, true),
            (0x180E, false),
            (0x2000, true),
            (0x200B, true),
            (0x2028, false),
            (0x2029, false),
            (0x202F, true),
            (0x205F, true),
            (0x3000, true),
            (0xFEFF, false),
        ] {
            assert_eq!(is_swift_whitespace(value), expected, "U+{value:04X}");
        }
    }

    #[test]
    fn newlines_split_lines_and_whitespace_is_not_a_stop() {
        let mut chars = word("ab", 10.0, 10.0, 10.0);
        chars.push(character('\n' as u32, 0.0, 0.0, 0.0, 0.0));
        chars.extend(word("cd", 10.0, 30.0, 10.0));
        let layout = SelectionLayout::build(&chars);
        assert_eq!(layout.lines().len(), 2);
        assert_eq!(layout.lines()[0].stops.len(), 2);
        assert_eq!(layout.lines()[1].stops.len(), 2);
    }

    #[test]
    fn spaces_between_glyphs_are_interpolated() {
        let chars = word("a b", 10.0, 10.0, 10.0);
        let layout = SelectionLayout::build(&chars);
        assert_eq!(layout.lines().len(), 1);
        let stops = &layout.lines()[0].stops;
        assert_eq!(stops.len(), 3, "the space gets an interpolated stop");
        assert_eq!(stops[1].index, 1);
        assert!(stops[1].rect.size.width > 0.0);
    }

    #[test]
    fn a_glyph_needs_thirty_five_percent_vertical_overlap_to_join_a_line() {
        let mut chars = vec![character('a' as u32, 10.0, 10.0, 10.0, 10.0)];
        // 3.4 pt overlap = 34%; a new line.
        chars.push(character('b' as u32, 25.0, 16.6, 10.0, 10.0));
        let layout = SelectionLayout::build(&chars);
        assert_eq!(layout.lines().len(), 2);
        // 3.5 pt = 35%; same line.
        let mut chars = vec![character('a' as u32, 10.0, 10.0, 10.0, 10.0)];
        chars.push(character('b' as u32, 25.0, 16.5, 10.0, 10.0));
        assert_eq!(SelectionLayout::build(&chars).lines().len(), 1);
    }

    #[test]
    fn nearest_character_on_the_line_and_vertical_cutoff() {
        let chars = word("abcd", 10.0, 10.0, 10.0);
        let layout = SelectionLayout::build(&chars);
        // Between b and c: the nearer stop wins.
        assert_eq!(layout.char_index_at(Point::new(17.0, 15.0), false), Some(1));
        assert_eq!(layout.char_index_at(Point::new(23.0, 15.0), false), Some(2));
        // Inside the 14 pt cutoff (line mid 15, so 15 ± 14 == 1..29).
        assert_eq!(layout.char_index_at(Point::new(10.0, 1.0), false), Some(0));
        assert_eq!(layout.char_index_at(Point::new(10.0, 29.0), false), Some(0));
        // Outside it: Swift returns nil rather than a distant character.
        assert_eq!(layout.char_index_at(Point::new(10.0, 30.0), false), None);
        assert_eq!(layout.char_index_at(Point::new(10.0, -2.0), false), None);
    }

    #[test]
    fn extending_selection_uses_the_upper_and_lower_neighbours() {
        let mut chars = word("ab", 10.0, 10.0, 10.0);
        chars.extend(word("cd", 10.0, 40.0, 10.0));
        let layout = SelectionLayout::build(&chars);
        // Just below the first line: drag resolves to its last stop.
        assert_eq!(layout.char_index_at(Point::new(14.0, 22.0), true), Some(1));
        // Just above the second line: one before its first stop.
        assert_eq!(layout.char_index_at(Point::new(14.0, 38.0), true), Some(1));
        // A press in the same gap has no closest line within the cutoff.
        assert_eq!(layout.char_index_at(Point::new(14.0, 30.0), false), None);
    }

    #[test]
    fn box_range_is_the_span_between_first_and_last_stop() {
        let mut chars = word("ab", 10.0, 10.0, 10.0);
        chars.extend(word("cd", 200.0, 10.0, 10.0));
        let page = SelectionTextPage::new(TextPage {
            page: lyra_reader_core::PageIndex(0),
            chars,
            blocks: Vec::new(),
            text: "abcd".to_string(),
            is_generated: false,
            has_unicode_map_error: false,
        });
        let (first, last) = page
            .character_range(Rect::new(15.0, 12.0, 190.0, 4.0))
            .expect("a box across both words");
        assert_eq!((first, last), (CharIndex(1), CharIndex(3)));
        assert_eq!(page.string_in_range(first.0, last.0), "bcd");
    }

    #[test]
    fn range_string_matches_swift_scalar_filtering_and_clamping() {
        let mut chars = word("ab", 10.0, 10.0, 10.0);
        chars.push(character(0xD800, 30.0, 10.0, 5.0, 10.0));
        let page = SelectionTextPage::new(TextPage {
            page: lyra_reader_core::PageIndex(0),
            chars,
            blocks: Vec::new(),
            text: String::new(),
            is_generated: false,
            has_unicode_map_error: false,
        });
        assert_eq!(page.string_in_range(0, 1), "ab");
        assert_eq!(
            page.string_in_range(0, 2),
            "ab",
            "invalid scalar is dropped"
        );
        assert_eq!(page.string_in_range(1, 99), "b", "clamped to the page");
        assert_eq!(page.string_in_range(9, 12), "");
    }
}

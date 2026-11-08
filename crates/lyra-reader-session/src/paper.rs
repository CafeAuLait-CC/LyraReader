//! Display-only paper tears, in page-local 100% view points (Y down).
//!
//! The PDF, glyph indices and raster bytes stay unchanged. Shells retain texture ownership
//! and apply these piecewise maps to drawing, hit testing and anchors together. Placement
//! consumes already available glyph/figure boxes; it never starts a document-wide scan.
use lyra_reader_core::{LineSegment, Point, Rect};

/// Bound caller-controlled geometry before allocating or sorting it.
pub const MAX_PAPER_GEOMETRY_ITEMS: usize = 1 << 18;
const CUT_EPSILON: f64 = 0.01;
const LINE_TOLERANCE: f64 = 0.75;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TearFallback {
    UnknownPageGeometry,
    InvalidSelection,
    InvalidContentGeometry,
    GeometryLimit,
    UnindexedArtwork,
}

/// `None` is a page-foot placement, not an arbitrary cut at the bottom of the page.
/// A safe page-foot placement need not have a diagnostic (for example, a foot selection).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TearPlan {
    pub split_pt: Option<f64>,
    pub fallback: Option<TearFallback>,
}

fn foot(fallback: Option<TearFallback>) -> TearPlan {
    TearPlan {
        split_pt: None,
        fallback,
    }
}

fn finite_rect(rect: Rect) -> bool {
    [
        rect.min_x(),
        rect.min_y(),
        rect.size.width,
        rect.size.height,
        rect.max_x(),
        rect.max_y(),
    ]
    .iter()
    .all(|n| n.is_finite())
}

/// Nearest safe whitespace at or below the selection. Gap height deliberately is not an
/// input: inserted conversation space does not have to fit in the remaining paper.
///
/// Ordinary inputs retain the macOS PageTearPlacement contract: 0.75-point line merging,
/// 0.01-point interior tolerance, and no guessed cut through unindexed artwork. Unlike the
/// historical shell, malformed/overflowing boxes fail closed with a diagnostic. Degenerate
/// glyph boxes are allowed (spaces can have zero advance); their positive vertical extent
/// still protects them from a cut, matching the shell's glyph-crossing rule.
pub fn plan_tear(
    page_height_pt: f64,
    selection: Rect,
    glyphs: &[Rect],
    indexed_regions: &[Rect],
    selection_has_text: bool,
) -> TearPlan {
    if !page_height_pt.is_finite() || page_height_pt <= 1.0 {
        return foot(Some(TearFallback::UnknownPageGeometry));
    }
    if !finite_rect(selection) || selection.is_empty() {
        return foot(Some(TearFallback::InvalidSelection));
    }
    if glyphs
        .len()
        .checked_add(indexed_regions.len())
        .is_none_or(|count| count > MAX_PAPER_GEOMETRY_ITEMS)
    {
        return foot(Some(TearFallback::GeometryLimit));
    }
    if glyphs
        .iter()
        .chain(indexed_regions)
        .any(|r| !finite_rect(*r) || r.size.width < 0.0 || r.size.height < 0.0)
    {
        return foot(Some(TearFallback::InvalidContentGeometry));
    }
    let bottom = selection.max_y().clamp(0.0, page_height_pt);
    if bottom <= CUT_EPSILON || page_height_pt - bottom <= CUT_EPSILON {
        return foot(None);
    }
    let indexed = indexed_regions
        .iter()
        .filter(|r| r.size.width > 1.0 && r.size.height > 1.0);
    if !selection_has_text && indexed.clone().next().is_none() {
        return foot(Some(TearFallback::UnindexedArtwork));
    }

    let mut glyph_bands: Vec<_> = glyphs
        .iter()
        .filter(|r| r.size.width > 0.0 && r.size.height > 0.0)
        .map(|r| (r.min_y(), r.max_y()))
        .collect();
    glyph_bands.sort_unstable_by(|a, b| a.0.total_cmp(&b.0));
    let mut lines: Vec<(f64, f64)> = Vec::new();
    for (top, end) in glyph_bands {
        if let Some(last) = lines.last_mut()
            && top - last.1 <= LINE_TOLERANCE
        {
            last.1 = last.1.max(end);
        } else {
            lines.push((top, end));
        }
    }

    // Sweep sorted forbidden interiors once. Testing every candidate against every glyph
    // would be quadratic on dense pages. Open interval edges remain legitimate whitespace.
    let mut forbidden: Vec<_> = glyphs
        .iter()
        .filter(|r| r.size.height > 0.0)
        .chain(indexed)
        .map(|r| (r.min_y() + CUT_EPSILON, r.max_y() - CUT_EPSILON))
        .filter(|(a, b)| a < b)
        .collect();
    forbidden.sort_unstable_by(|a, b| a.0.total_cmp(&b.0));
    let mut interiors = forbidden.into_iter().peekable();
    let mut blocked_until = f64::NEG_INFINITY;
    for y in std::iter::once(bottom).chain(
        lines
            .into_iter()
            .map(|(_, end)| end)
            .filter(|end| *end - bottom > CUT_EPSILON),
    ) {
        if y >= page_height_pt - CUT_EPSILON {
            break;
        }
        while let Some(&(start, end)) = interiors.peek()
            && start < y
        {
            blocked_until = blocked_until.max(end);
            interiors.next();
        }
        if blocked_until <= y {
            return TearPlan {
                split_pt: Some(y),
                fallback: None,
            };
        }
    }
    foot(None)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidPaperGeometry;

impl std::fmt::Display for InvalidPaperGeometry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Invalid paper geometry; close the inserted note and try again")
    }
}
impl std::error::Error for InvalidPaperGeometry {}

/// A paper segment and its display destination, relative to its owning page's display top.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaperSegment {
    pub source_top_pt: f64,
    pub display_top_pt: f64,
    pub height_pt: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaperQuad {
    pub target: Rect,
    /// Original source coordinates, usually normalized UV. No image/lease is duplicated.
    pub source: Rect,
}

/// At most two pieces; per-quad mapping does not allocate on the drawing path.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaperQuads {
    pub first: PaperQuad,
    pub second: Option<PaperQuad>,
}

/// Validated, page-local display geometry. A page-foot note is outside this paper; its
/// row-height contribution belongs to the document layout, not a fabricated inside-page cut.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaperLayout {
    height_pt: f64,
    split_pt: Option<f64>,
    gap_pt: f64,
}

/// Display rectangles for one native control. A single focused editor uses the union;
/// non-interactive drawing can use the individual pieces without covering the gap.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaperRegion {
    pub pieces: [Option<Rect>; 2],
    pub bounds: Option<Rect>,
}

impl PaperLayout {
    fn displayed_split(self) -> Option<f64> {
        self.split_pt.filter(|s| {
            self.gap_pt > CUT_EPSILON && *s > CUT_EPSILON && *s < self.height_pt - CUT_EPSILON
        })
    }
    pub fn new(
        height_pt: f64,
        split_pt: Option<f64>,
        gap_pt: f64,
    ) -> Result<Self, InvalidPaperGeometry> {
        if !height_pt.is_finite()
            || height_pt <= 1.0
            || !gap_pt.is_finite()
            || gap_pt < 0.0
            || !(height_pt + gap_pt).is_finite()
            || split_pt
                .is_some_and(|s| !s.is_finite() || s < CUT_EPSILON || s > height_pt - CUT_EPSILON)
            || split_pt.is_none() && gap_pt != 0.0
        {
            return Err(InvalidPaperGeometry);
        }
        Ok(Self {
            height_pt,
            split_pt,
            gap_pt,
        })
    }

    pub fn segments(self) -> [Option<PaperSegment>; 2] {
        let split = self.split_pt.unwrap_or(self.height_pt);
        [
            Some(PaperSegment {
                source_top_pt: 0.0,
                display_top_pt: 0.0,
                height_pt: split,
            }),
            self.split_pt.map(|s| PaperSegment {
                source_top_pt: s,
                display_top_pt: s + self.gap_pt,
                height_pt: self.height_pt - s,
            }),
        ]
    }

    /// Anchors are not silently clamped to the paper. Crop/rotation/UserUnit have already
    /// been handled by PageGeometry; this map adds only the display gap.
    pub fn display_y(self, paper_y: f64) -> Option<f64> {
        let offset = if self.split_pt.is_some_and(|s| paper_y >= s) {
            self.gap_pt
        } else {
            0.0
        };
        let y = paper_y + offset;
        (paper_y.is_finite() && y.is_finite()).then_some(y)
    }

    /// Inverse anchor map, with no point in the gap. The shell separately checks the owning
    /// page's lower bound for pointer hits; positive extrapolated anchors remain reversible.
    /// The historical 0.001-point tolerance at the upper paper edge is retained.
    pub fn paper_y(self, display_y: f64) -> Option<f64> {
        if !display_y.is_finite() || display_y < -0.001 {
            return None;
        }
        if let Some(split) = self.split_pt {
            if display_y >= split + self.gap_pt {
                return Some(display_y - self.gap_pt);
            }
            if display_y >= split {
                return None;
            }
        }
        Some(display_y)
    }

    /// Union of paper intervals covered by a display viewport, clipped to the original paper.
    /// A viewport wholly in the conversation gap demands no paper rows.
    pub fn paper_band(self, top: f64, bottom: f64) -> Option<(f64, f64)> {
        if !top.is_finite() || !bottom.is_finite() || bottom <= top {
            return None;
        }
        let mut band: Option<(f64, f64)> = None;
        for segment in self.segments().into_iter().flatten() {
            let low = top.max(segment.display_top_pt);
            let high = bottom.min(segment.display_top_pt + segment.height_pt);
            if low < high {
                let a = low - segment.display_top_pt + segment.source_top_pt;
                let b = high - segment.display_top_pt + segment.source_top_pt;
                band = Some(match band {
                    None => (a, b),
                    Some((old_a, old_b)) => (old_a.min(a), old_b.max(b)),
                });
            }
        }
        band
    }

    /// Clip a source region to the original paper before mapping each display segment.
    /// Matches the native CanvasGeometry region contract, including the 0.01-point minimum
    /// intersection. Empty/outside is distinct from malformed geometry and never clamped
    /// into a fabricated visible control. No display height is an authored source height.
    pub fn region(self, width: f64, source: Rect) -> Result<PaperRegion, InvalidPaperGeometry> {
        if !width.is_finite()
            || width <= 0.0
            || !finite_rect(source)
            || source.size.width < 0.0
            || source.size.height < 0.0
        {
            return Err(InvalidPaperGeometry);
        }
        let segments = if self.displayed_split().is_some() {
            self.segments()
        } else {
            [
                Some(PaperSegment {
                    source_top_pt: 0.0,
                    display_top_pt: 0.0,
                    height_pt: self.height_pt,
                }),
                None,
            ]
        };
        let mut mapped = PaperRegion {
            pieces: [None, None],
            bounds: None,
        };
        for (index, segment) in segments.into_iter().flatten().enumerate() {
            let paper = Rect::new(0.0, segment.source_top_pt, width, segment.height_pt);
            let Some(clipped) = source.intersection(paper) else {
                continue;
            };
            if clipped.size.width <= CUT_EPSILON || clipped.size.height <= CUT_EPSILON {
                continue;
            }
            let rect = clipped.translated(0.0, segment.display_top_pt - segment.source_top_pt);
            let bounds = mapped.bounds.map_or(rect, |old| old.union(rect));
            if !finite_rect(rect) || !finite_rect(bounds) {
                return Err(InvalidPaperGeometry);
            }
            mapped.pieces[index] = Some(rect);
            mapped.bounds = Some(bounds);
        }
        Ok(mapped)
    }

    /// A strict pointer hit, unlike extrapolatable reading anchors. Edges are half open as
    /// in the native page rectangles: the cut belongs to the gap and its far edge to the
    /// lower paper. Tiny gaps use the same unsplit geometry as the raster and eraser.
    pub fn pointer_point(
        self,
        width: f64,
        display: lyra_reader_core::Point,
    ) -> Result<Option<lyra_reader_core::Point>, InvalidPaperGeometry> {
        if !width.is_finite() || width <= 0.0 || !display.x.is_finite() || !display.y.is_finite() {
            return Err(InvalidPaperGeometry);
        }
        if display.x < 0.0 || display.x >= width || display.y < 0.0 {
            return Ok(None);
        }
        let y = if let Some(split) = self.displayed_split() {
            if display.y >= split && display.y < split + self.gap_pt {
                return Ok(None);
            }
            if display.y >= split + self.gap_pt {
                display.y - self.gap_pt
            } else {
                display.y
            }
        } else {
            display.y
        };
        Ok((y < self.height_pt).then_some(lyra_reader_core::Point::new(display.x, y)))
    }

    /// Clip the raw display-space pointer sweep to each actual paper segment, then map
    /// endpoints back to the original page. Folding endpoints into one paper-space line
    /// first invents an eraser capsule through the conversation gap. Pieces follow segment
    /// order even for a reverse drag. Zero/tiny gaps follow the raster's unsplit rule.
    pub fn pointer_segments(
        self,
        width_pt: f64,
        from: Point,
        to: Point,
    ) -> Result<[Option<LineSegment>; 2], InvalidPaperGeometry> {
        if !width_pt.is_finite() || width_pt <= 0.0 {
            return Err(InvalidPaperGeometry);
        }
        let segments = if self.displayed_split().is_some() {
            self.segments()
        } else {
            [
                Some(PaperSegment {
                    source_top_pt: 0.0,
                    display_top_pt: 0.0,
                    height_pt: self.height_pt,
                }),
                None,
            ]
        };
        let mut output = [None, None];
        for (index, segment) in segments.into_iter().flatten().enumerate() {
            let rect = Rect::new(0.0, segment.display_top_pt, width_pt, segment.height_pt);
            if let Some(line) = clipped_segment(from, to, rect)? {
                let local = |p: Point| {
                    Point::new(p.x, p.y - segment.display_top_pt + segment.source_top_pt)
                };
                output[index] = Some(LineSegment::new(local(line.from), local(line.to)));
            }
        }
        Ok(output)
    }

    /// Split one already page-owned quad. Later pages and facing partners must be excluded by
    /// identity before calling; never infer ownership from Y alone. Target coordinates are
    /// page-local, before inserting the gap. Original source rect and horizontal extent stay
    /// intact; both results must refer to the caller's same texture/material/generation.
    pub fn quads(self, quad: PaperQuad) -> Result<PaperQuads, InvalidPaperGeometry> {
        if !finite_rect(quad.target)
            || !finite_rect(quad.source)
            || quad.target.is_empty()
            || quad.source.is_empty()
        {
            return Err(InvalidPaperGeometry);
        }
        let unchanged = |first| PaperQuads {
            first,
            second: None,
        };
        let Some(split) = self.displayed_split() else {
            return Ok(unchanged(quad));
        };
        let top = quad.target.min_y();
        let bottom = quad.target.max_y();
        if top >= self.height_pt - 0.001 || bottom <= 0.001 || bottom <= split + 0.001 {
            return Ok(unchanged(quad));
        }
        if top >= split - 0.001 {
            let mut moved = quad;
            moved.target = moved.target.translated(0.0, self.gap_pt);
            return finite_rect(moved.target)
                .then_some(unchanged(moved))
                .ok_or(InvalidPaperGeometry);
        }
        let upper_height = split - top;
        let lower_height = bottom - split;
        if upper_height <= 0.01 || lower_height <= 0.01 {
            return Ok(unchanged(quad));
        }
        let fraction = upper_height / quad.target.size.height;
        let source_height = quad.source.size.height * fraction;
        Ok(PaperQuads {
            first: PaperQuad {
                target: Rect::new(
                    quad.target.min_x(),
                    top,
                    quad.target.size.width,
                    upper_height,
                ),
                source: Rect::new(
                    quad.source.min_x(),
                    quad.source.min_y(),
                    quad.source.size.width,
                    source_height,
                ),
            },
            second: Some(PaperQuad {
                target: Rect::new(
                    quad.target.min_x(),
                    split + self.gap_pt,
                    quad.target.size.width,
                    lower_height,
                ),
                source: Rect::new(
                    quad.source.min_x(),
                    quad.source.min_y() + source_height,
                    quad.source.size.width,
                    quad.source.size.height * (1.0 - fraction),
                ),
            }),
        })
    }
}

/// Liang-Barsky clipping with the macOS pointer tolerance. Endpoint differences must also
/// be finite: two huge finite endpoints can otherwise overflow their delta before clipping.
fn clipped_segment(
    from: Point,
    to: Point,
    rect: Rect,
) -> Result<Option<LineSegment>, InvalidPaperGeometry> {
    let (dx, dy) = (to.x - from.x, to.y - from.y);
    if !finite_rect(rect)
        || rect.is_empty()
        || [from.x, from.y, to.x, to.y, dx, dy]
            .iter()
            .any(|v| !v.is_finite())
    {
        return Err(InvalidPaperGeometry);
    }
    let (mut t0, mut t1) = (0.0_f64, 1.0_f64);
    for (p, q) in [
        (-dx, from.x - rect.min_x()),
        (dx, rect.max_x() - from.x),
        (-dy, from.y - rect.min_y()),
        (dy, rect.max_y() - from.y),
    ] {
        if !q.is_finite() {
            return Err(InvalidPaperGeometry);
        }
        if p.abs() < 1e-12 {
            if q < 0.0 {
                return Ok(None);
            }
            continue;
        }
        let r = q / p;
        if !r.is_finite() {
            return Err(InvalidPaperGeometry);
        }
        if p < 0.0 {
            if r > t1 {
                return Ok(None);
            }
            t0 = t0.max(r);
        } else {
            if r < t0 {
                return Ok(None);
            }
            t1 = t1.min(r);
        }
    }
    Ok(Some(LineSegment::new(
        Point::new(from.x + t0 * dx, from.y + t0 * dy),
        Point::new(from.x + t1 * dx, from.y + t1 * dy),
    )))
}

/// Smoothstep used by paper reveal/close. The shell owns timers, epochs and Reduce Motion.
/// It changes geometry/clip only; this function neither plans tiles nor requests pixels.
pub fn paper_reveal_progress(time: f64) -> Option<f64> {
    if !time.is_finite() {
        return None;
    }
    let t = time.clamp(0.0, 1.0);
    Some(t * t * (3.0 - 2.0 * t))
}

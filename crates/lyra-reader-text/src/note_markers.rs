//! Page-local anchors for comments attached to text markup. The shell uses the
//! returned rectangles unchanged for painting, hit testing and expanded note paper.
use crate::SelectionLayout;
use lyra_reader_core::Rect;

pub const MAX_INLINE_NOTE_MARKERS: usize = 512;
pub const MAX_INLINE_NOTE_BOXES: usize = 8192;

fn usable(rect: Rect) -> bool {
    [rect.min_x(), rect.min_y(), rect.max_x(), rect.max_y()]
        .iter()
        .all(|value| value.is_finite())
        && rect.size.width > 0.0
        && rect.size.height > 0.0
        && rect.max_x() > rect.min_x()
        && rect.max_y() > rect.min_y()
}

/// The maximum-overlap full selection line, including its stable exclusion of
/// manuscript line numbers. No new line decomposition is built for a comment.
pub fn note_line_bounds(layout: &SelectionLayout, region: Rect) -> Option<Rect> {
    if !usable(region) {
        return None;
    }
    let mut best = None;
    let mut area = 0.0;
    for line in layout.lines() {
        if !usable(line.bounds) {
            continue;
        }
        if let Some(overlap) = line.bounds.intersection(region) {
            let candidate = overlap.size.width * overlap.size.height;
            if candidate > area {
                best = Some(line.bounds);
                area = candidate;
            }
        }
    }
    best
}

/// Inputs are ordered file-owned marks first, then local/adopted marks, just as
/// the native reader lays out its two groups. Each optional result retains its input
/// index; malformed/empty boxes have no marker rather than a fabricated text range.
/// A missing prepared layout falls back to the markup's left edge without extracting text.
pub fn inline_note_markers(
    layout: Option<&SelectionLayout>,
    boxes: &[Vec<Rect>],
) -> Result<Vec<Option<Rect>>, &'static str> {
    if boxes.len() > MAX_INLINE_NOTE_MARKERS
        || boxes
            .iter()
            .try_fold(0usize, |count, item| count.checked_add(item.len()))
            .is_none_or(|count| count > MAX_INLINE_NOTE_BOXES)
    {
        return Err("This page has too many inline-note boxes to lay out safely");
    }
    let mut occupied: Vec<Rect> = Vec::with_capacity(boxes.len());
    let mut result = Vec::with_capacity(boxes.len());
    for boxes in boxes {
        let first = boxes
            .iter()
            .copied()
            .filter(|rect| usable(*rect))
            .min_by(|a, b| {
                a.min_y()
                    .total_cmp(&b.min_y())
                    .then(a.min_x().total_cmp(&b.min_x()))
            });
        let Some(first) = first else {
            result.push(None);
            continue;
        };
        let left = layout
            .and_then(|layout| note_line_bounds(layout, first))
            .map(|line| line.min_x())
            .unwrap_or_else(|| {
                boxes
                    .iter()
                    .copied()
                    .filter(|rect| usable(*rect))
                    .map(Rect::min_x)
                    .fold(first.min_x(), f64::min)
            });
        let mut marker = Rect::new(
            (left - 30.0).max(2.0),
            (first.min_y() + first.size.height * 0.5 - 12.0).max(2.0),
            24.0,
            24.0,
        );
        // A finite PDF coordinate may still be too large to represent a 24-point
        // marker. Do not pass a collapsed, unpaintable anchor to a native scene.
        if !usable(marker) {
            result.push(None);
            continue;
        }
        // At most one horizontal or vertical lane per occupied marker is needed.
        // Bounded input makes this finite even for coincident file-controlled boxes.
        let overlaps = |marker| {
            occupied.iter().any(|other| {
                Rect::new(other.min_x() - 1.0, other.min_y() - 1.0, 26.0, 26.0)
                    .intersection(marker)
                    .is_some()
            })
        };
        for _ in 0..occupied.len() {
            if !overlaps(marker) {
                break;
            }
            if marker.min_x() >= 28.0 {
                marker.origin.x -= 28.0;
            } else {
                marker.origin.y += 28.0;
            }
        }
        if overlaps(marker) {
            return Err("Inline-note coordinates cannot form distinct marker lanes");
        }
        occupied.push(marker);
        result.push(Some(marker));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::CharBox;
    use lyra_reader_core::Point;

    fn layout() -> SelectionLayout {
        let chars: Vec<_> = "first word\nsecond line"
            .chars()
            .enumerate()
            .map(|(i, ch)| {
                let row = usize::from(i > 10);
                let column = if row == 0 { i } else { i - 11 };
                CharBox {
                    rect: Rect::new(
                        100.0 + column as f64 * 10.0,
                        50.0 + row as f64 * 20.0,
                        8.0,
                        12.0,
                    ),
                    origin: Point::new(0.0, 0.0),
                    unicode: ch as u32,
                    font_size: 12.0,
                    logical_order: i as u32,
                }
            })
            .collect();
        SelectionLayout::build(&chars)
    }
    #[test]
    fn full_line_anchor_uses_overlap_and_keeps_adopted_fixed_quads() {
        let layout = layout();
        let boxes = vec![vec![Rect::new(160.0, 50.0, 28.0, 12.0)]];
        assert_eq!(
            inline_note_markers(Some(&layout), &boxes).unwrap(),
            vec![Some(Rect::new(70.0, 44.0, 24.0, 24.0))]
        );
        assert_eq!(
            inline_note_markers(None, &boxes).unwrap(),
            vec![Some(Rect::new(130.0, 44.0, 24.0, 24.0))]
        );
        assert_eq!(
            note_line_bounds(&layout, Rect::new(110.0, 57.0, 10.0, 22.0)),
            Some(Rect::new(100.0, 70.0, 108.0, 12.0))
        );
    }
    #[test]
    fn colliding_notes_use_left_lanes_then_move_down_without_overlap() {
        let boxes = vec![vec![Rect::new(100.0, 50.0, 8.0, 12.0)]; 5];
        let result = inline_note_markers(None, &boxes).unwrap();
        assert_eq!(
            result,
            [70.0, 42.0, 14.0, 14.0, 14.0]
                .into_iter()
                .zip([44.0, 44.0, 44.0, 72.0, 100.0])
                .map(|(x, y)| Some(Rect::new(x, y, 24.0, 24.0)))
                .collect::<Vec<_>>()
        );
    }
    #[test]
    fn invalid_boxes_are_skipped_and_batch_limits_precede_layout() {
        assert_eq!(
            inline_note_markers(
                None,
                &[
                    vec![Rect::new(f64::NAN, 0.0, 2.0, 2.0)],
                    vec![],
                    vec![Rect::new(1.0, 1.0, -1.0, 2.0)]
                ]
            )
            .unwrap(),
            vec![None, None, None]
        );
        assert!(inline_note_markers(None, &vec![vec![]; MAX_INLINE_NOTE_MARKERS + 1]).is_err());
        assert!(
            inline_note_markers(
                None,
                &[vec![
                    Rect::new(0.0, 0.0, 1.0, 1.0);
                    MAX_INLINE_NOTE_BOXES + 1
                ]]
            )
            .is_err()
        );
        assert_eq!(
            inline_note_markers(None, &vec![vec![Rect::new(2.0, 1e308, 1.0, 1.0)]; 2]).unwrap(),
            vec![None, None]
        );
        assert_eq!(
            inline_note_markers(None, &[vec![Rect::new(1e100, 1e100, 1e99, 1e99)]]).unwrap(),
            vec![None]
        );
    }
}

//! Translation targets over the same cached lines, stops and scalar indices as selection.
//! No PDFium, source normalization, prompt construction or platform drawing belongs here.
use crate::{SelectionTextPage, is_swift_whitespace_or_newline};
use lyra_reader_core::Rect;
use std::collections::BTreeSet;

pub const MAX_TRANSLATION_TARGETS: usize = 24;
const MAX_LINES: usize = 4096;
const MAX_GLYPHS: usize = 1 << 20;
const MAX_MEMBERSHIP_WORK: usize = 4 << 20;

#[derive(Clone, Debug, PartialEq)]
pub struct TranslationTarget {
    pub page: u32,
    pub start: u32,
    pub end: u32,
    pub rect: Rect,
    pub line_rects: Vec<Rect>,
    pub source_text: String,
    pub source_font_pt: f64,
    pub is_block: bool,
}

fn finite(rect: Rect) -> bool {
    [
        rect.min_x(),
        rect.min_y(),
        rect.max_x(),
        rect.max_y(),
        rect.size.width,
        rect.size.height,
    ]
    .iter()
    .all(|value| value.is_finite())
}

pub fn translation_trimmed_range(
    page: &SelectionTextPage,
    start: u32,
    end: u32,
) -> Option<(u32, u32)> {
    if start > end || end as usize >= page.chars().len() {
        return None;
    }
    let whitespace = |i: u32| {
        char::from_u32(page.chars()[i as usize]).is_none()
            || is_swift_whitespace_or_newline(page.chars()[i as usize])
    };
    let mut lo = start;
    let mut hi = end;
    while lo <= hi && whitespace(lo) {
        lo = lo.checked_add(1)?;
    }
    if lo > hi {
        return None;
    }
    while hi > lo && whitespace(hi) {
        hi -= 1;
    }
    Some((lo, hi))
}

fn rects(page: &SelectionTextPage, start: u32, end: u32) -> Vec<Rect> {
    let mut result = Vec::new();
    for line in page.layout().lines() {
        let mut run: Option<Rect> = None;
        for stop in &line.stops {
            if !(start..=end).contains(&stop.index) {
                continue;
            }
            let next = Rect::new(
                stop.rect.min_x(),
                line.bounds.min_y(),
                stop.rect.size.width,
                line.bounds.size.height,
            );
            if let Some(current) = run {
                let gap = (next.min_x() - current.max_x()).max(current.min_x() - next.max_x());
                if gap <= line.bounds.size.height * 1.5 {
                    run = Some(current.union(next));
                } else {
                    result.push(current);
                    run = Some(next);
                }
            } else {
                run = Some(next);
            }
        }
        if let Some(run) = run {
            result.push(run);
        }
    }
    result
}

fn before(a: Rect, b: Rect) -> bool {
    if (a.min_y() - b.min_y()).abs() > 0.5 {
        a.min_y() < b.min_y()
    } else {
        a.min_x() < b.min_x()
    }
}

/// Paragraphs used by explicit translation and lazy cache validation.
pub fn translation_blocks(page: &SelectionTextPage) -> Result<Vec<TranslationTarget>, String> {
    if page.chars().len() > MAX_GLYPHS || page.layout().lines().len() > MAX_LINES {
        return Err(
            "This page has too much text geometry for a bounded translation preview.".into(),
        );
    }
    for line in page.layout().lines() {
        if !finite(line.bounds) || line.stops.iter().any(|s| !finite(s.rect)) {
            return Err("The translation geometry is not finite; nothing was sent.".into());
        }
    }
    if page.chars().is_empty() {
        return Ok(Vec::new());
    }
    let all_end =
        u32::try_from(page.chars().len() - 1).map_err(|_| "Too many translation characters")?;
    if page
        .chars()
        .len()
        .checked_mul(page.layout().lines().len())
        .is_none_or(|work| work > 8 << 20)
    {
        return Err("This page exceeds the bounded translation geometry work budget.".into());
    }
    let mut lines = rects(page, 0, all_end)
        .into_iter()
        .filter(|r| r.size.width > 0.5 && r.size.height > 0.5)
        .filter_map(|r| {
            page.character_range(r)
                .filter(|(s, e)| s <= e)
                .map(|range| (r, range.0.0, range.1.0))
        })
        .collect::<Vec<_>>();
    if lines.len() > MAX_LINES {
        return Err("This page has too many translation lines.".into());
    }
    // A half-point tolerance is not a transitive total comparator. A bounded stable
    // insertion order preserves the reference rule without passing it to slice::sort.
    for i in 1..lines.len() {
        let mut j = i;
        while j > 0 && before(lines[j].0, lines[j - 1].0) {
            lines.swap(j, j - 1);
            j -= 1;
        }
    }
    let mut heights = lines.iter().map(|l| l.0.size.height).collect::<Vec<_>>();
    heights.sort_by(f64::total_cmp);
    let median = heights.get(heights.len() / 2).copied().unwrap_or(10.0); // An empty page has no targets.
    let mut groups: Vec<(Rect, Vec<Rect>, u32, u32)> = Vec::new();
    for (r, lo, hi) in lines {
        let found = groups.iter().position(|(_, rows, _, _)| {
            rows.last().is_some_and(|previous| {
                let gap = r.min_y() - previous.max_y();
                (-0.5..=median * 0.8).contains(&gap)
                    && r.min_x() < previous.max_x()
                    && previous.min_x() < r.max_x()
                    && (previous.min_x() / 20.0).round() == (r.min_x() / 20.0).round()
            })
        });
        if let Some(i) = found {
            let group = &mut groups[i];
            group.0 = group.0.union(r);
            group.1.push(r);
            group.2 = group.2.min(lo);
            group.3 = group.3.max(hi);
        } else {
            groups.push((r, vec![r], lo, hi));
        }
    }
    let mut blocks = Vec::with_capacity(groups.len());
    for (rect, line_rects, lo, hi) in groups {
        let Some((start, end)) = translation_trimmed_range(page, lo, hi) else {
            continue;
        };
        let source_text = page.string_in_range(start, end);
        if source_text.trim().is_empty() {
            continue;
        }
        blocks.push(TranslationTarget {
            page: page.page().0,
            start,
            end,
            rect,
            line_rects,
            source_text,
            source_font_pt: median.clamp(7.0, 18.0),
            is_block: true,
        });
    }
    Ok(blocks)
}

pub fn translation_targets(
    page: &SelectionTextPage,
    start: u32,
    end: u32,
) -> Result<Vec<TranslationTarget>, String> {
    if start > end || end as usize >= page.chars().len() {
        return Err("The translation range is outside the current page.".into());
    }
    let Some((start, end)) = translation_trimmed_range(page, start, end) else {
        return Ok(Vec::new());
    };
    let blocks = translation_blocks(page)?;
    let mut content = page
        .layout()
        .lines()
        .iter()
        .flat_map(|l| &l.stops)
        .filter(|s| {
            s.rect.size.width > 0.0
                && s.rect.size.height > 0.0
                && char::from_u32(page.chars()[s.index as usize]).is_some()
                && !is_swift_whitespace_or_newline(page.chars()[s.index as usize])
        })
        .map(|s| s.index)
        .collect::<BTreeSet<_>>();
    // Preserve the native resolver's coverage classification: it counted positive-geometry
    // gutter glyphs even though string extraction omits them. A whole-page range containing
    // gutter text outside all paragraph spans remains one free selection. Do not silently
    // turn this historical whole-span behaviour into a different request batch.
    content.extend(
        page.layout()
            .excluded_indices()
            .iter()
            .copied()
            .filter(|i| {
                char::from_u32(page.chars()[*i as usize]).is_some()
                    && !is_swift_whitespace_or_newline(page.chars()[*i as usize])
            }),
    );
    let selected = content.range(start..=end).copied().collect::<BTreeSet<_>>();
    let mut covered = BTreeSet::new();
    let mut whole = Vec::new();
    let mut work = 0usize;
    for block in blocks {
        if block.start < start || block.end > end {
            continue;
        }
        work = work
            .checked_add((block.end - block.start) as usize + 1)
            .filter(|n| *n <= MAX_MEMBERSHIP_WORK)
            .ok_or("Overlapping translation paragraphs exceed the geometry work budget.")?;
        let indices = content
            .range(block.start..=block.end)
            .copied()
            .collect::<BTreeSet<_>>();
        if indices.is_empty() || !indices.is_subset(&selected) {
            continue;
        }
        covered.extend(indices);
        whole.push(block);
    }
    if !whole.is_empty() && covered == selected {
        if whole.len() > MAX_TRANSLATION_TARGETS {
            return Err("Select at most 24 paragraphs for one translation preview.".into());
        }
        for i in 1..whole.len() {
            let mut j = i;
            while j > 0 && before(whole[j].rect, whole[j - 1].rect) {
                whole.swap(j, j - 1);
                j -= 1;
            }
        }
        return Ok(whole);
    }
    let line_rects = rects(page, start, end);
    let Some(first) = line_rects.first().copied() else {
        return Ok(Vec::new());
    };
    let rect = line_rects
        .iter()
        .skip(1)
        .fold(first, |union, r| union.union(*r));
    if rect.size.width <= 0.5 || rect.size.height <= 0.5 {
        return Ok(Vec::new());
    }
    let mut heights = line_rects
        .iter()
        .map(|r| r.size.height)
        .filter(|h| *h > 0.0)
        .collect::<Vec<_>>();
    heights.sort_by(f64::total_cmp);
    let font = heights
        .get(heights.len() / 2)
        .copied()
        .unwrap_or(10.0)
        .clamp(7.0, 18.0);
    Ok(vec![TranslationTarget {
        page: page.page().0,
        start,
        end,
        rect,
        line_rects,
        source_text: page.string_in_range(start, end),
        source_font_pt: font,
        is_block: false,
    }])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CharBox, TextPage};
    use lyra_reader_core::{PageIndex, Point};
    fn page(rows: &[(f64, f64, &str)]) -> SelectionTextPage {
        let mut chars = Vec::new();
        for (x, y, text) in rows {
            for (i, c) in text.chars().enumerate() {
                chars.push(CharBox {
                    rect: Rect::new(x + i as f64 * 5.0, *y, 5.0, 10.0),
                    origin: Point::new(*x, *y),
                    unicode: c as u32,
                    font_size: 10.0,
                    logical_order: 0,
                });
            }
            chars.push(CharBox {
                rect: Rect::default(),
                origin: Point::default(),
                unicode: 10,
                font_size: 10.0,
                logical_order: 0,
            });
        }
        SelectionTextPage::new(TextPage {
            page: PageIndex(2),
            chars,
            ..Default::default()
        })
    }
    #[test]
    fn gutter_characters_keep_legacy_coverage_without_entering_the_sent_text() {
        let mut chars = Vec::new();
        for row in 0..10 {
            let y = 30.0 + f64::from(row) * 15.0;
            for (text, x, size) in [
                (format!("{:03}", row + 1), 10.0, 7.0),
                ("Body text for translation".into(), 60.0, 10.0),
            ] {
                for (i, c) in text.chars().enumerate() {
                    chars.push(CharBox {
                        rect: Rect::new(x + i as f64 * size * 0.45, y, size * 0.45, size),
                        origin: Point::new(x, y),
                        unicode: c as u32,
                        font_size: size,
                        logical_order: 0,
                    });
                }
            }
            chars.push(CharBox {
                rect: Rect::default(),
                origin: Point::default(),
                unicode: 10,
                font_size: 0.0,
                logical_order: 0,
            });
        }
        let page = SelectionTextPage::new(TextPage {
            page: PageIndex(0),
            chars,
            ..Default::default()
        });
        assert!(!page.layout().excluded_indices().is_empty());
        let end = page.chars().len() as u32 - 1;
        let targets = translation_targets(&page, 0, end).unwrap();
        assert_eq!(targets.len(), 1);
        assert!(!targets[0].is_block);
        assert!(!targets[0].source_text.contains("001"));
        assert_eq!(
            targets[0].source_text,
            page.string_in_range(targets[0].start, targets[0].end)
        );
        let block = translation_blocks(&page).unwrap().remove(0);
        assert!(translation_targets(&page, block.start, block.end).unwrap()[0].is_block);
    }

    #[test]
    fn a_large_selection_is_rejected_instead_of_silently_omitting_paragraphs() {
        let rows = (0..25)
            .map(|i| (10.0, 10.0 + f64::from(i) * 40.0, "paragraph"))
            .collect::<Vec<_>>();
        let p = page(&rows);
        let blocks = translation_blocks(&p).unwrap();
        assert_eq!(blocks.len(), 25);
        assert!(
            translation_targets(&p, 0, p.chars().len() as u32 - 1)
                .unwrap_err()
                .contains("24")
        );
    }
    #[test]
    fn paragraph_inspection_and_selected_target_share_one_geometry() {
        let p = page(&[
            (10.0, 10.0, "paragraph one"),
            (10.0, 22.0, "second line"),
            (10.0, 60.0, "paragraph two"),
        ]);
        let blocks = translation_blocks(&p).unwrap();
        assert_eq!(blocks.len(), 2);
        assert_eq!(
            blocks,
            translation_targets(&p, 0, p.chars().len() as u32 - 1).unwrap()
        );
        for block in blocks {
            assert_eq!(
                translation_targets(&p, block.start, block.end).unwrap(),
                vec![block]
            );
        }
    }

    #[test]
    fn whole_paragraphs_split_but_a_partial_range_stays_one_request() {
        let p = page(&[
            (10.0, 10.0, "first line"),
            (10.0, 22.0, "second line"),
            (10.0, 60.0, "next paragraph"),
        ]);
        let targets = translation_targets(&p, 0, p.chars().len() as u32 - 1).unwrap();
        assert_eq!(targets.len(), 2);
        assert!(targets.iter().all(|t| t.is_block));
        assert_eq!(targets[0].source_text, "first line\nsecond line");
        assert_eq!(targets[0].rect, Rect::new(10.0, 10.0, 55.0, 22.0));
        let free = translation_targets(&p, 2, 16).unwrap();
        assert_eq!(free.len(), 1);
        assert!(!free[0].is_block);
        assert_eq!(free[0].source_text, p.string_in_range(2, 16));
    }
    #[test]
    fn source_keeps_interior_unicode_and_line_breaks() {
        let p = page(&[(10.0, 10.0, "  α  β\r\nγ\u{202f}δ  ")]);
        let end = p.chars().len() as u32 - 1;
        let (s, e) = translation_trimmed_range(&p, 0, end).unwrap();
        assert_eq!(p.string_in_range(s, e), "α  β\r\nγ\u{202f}δ");
        assert!(
            translation_targets(&p, 0, end)
                .unwrap()
                .iter()
                .all(|t| !t.source_text.ends_with(' '))
        );
    }
    #[test]
    fn invalid_ranges_and_non_finite_geometry_do_not_become_empty_successes() {
        let p = page(&[(10.0, 10.0, "text")]);
        assert!(translation_targets(&p, 5, 2).is_err());
        assert!(translation_targets(&p, 0, 999).is_err());
        let p = page(&[(f64::NAN, 10.0, "text")]);
        assert!(translation_targets(&p, 0, 3).is_err());
    }
    #[test]
    fn columns_do_not_join_across_a_gutter() {
        let p = page(&[
            (10.0, 10.0, "left"),
            (200.0, 10.0, "right"),
            (10.0, 22.0, "left two"),
            (200.0, 22.0, "right two"),
        ]);
        let t = translation_targets(&p, 0, p.chars().len() as u32 - 1).unwrap();
        assert_eq!(t.len(), 2);
        assert!(t[0].rect.max_x() < t[1].rect.min_x());
    }
}

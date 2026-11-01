//! Numbered display equations and their local preview rectangles.

use crate::{Caption, union_boxes};
use lyra_reader_core::{RawTextPage, Rect};

/// The printed right-margin number anchors a display equation. Prose and adjacent equation
/// numbers bound its vertical band, so a preview cannot adopt the entire surrounding derivation.
pub fn find_numbered_equations(page: &RawTextPage, bounds: Rect) -> Vec<Caption> {
    let chars: Vec<char> = page
        .chars
        .iter()
        .map(|c| char::from_u32(c.unicode).unwrap_or(char::REPLACEMENT_CHARACTER))
        .collect();
    let mut anchors = Vec::new();
    for start in 0..chars.len() {
        if chars[start] != '(' {
            continue;
        }
        let Some(length) = crate::numbered::label_len(&chars[start + 1..]) else {
            continue;
        };
        let end = start + length + 2;
        if chars.get(end - 1) != Some(&')') {
            continue;
        }
        let number = union_boxes(&page.chars[start..end]);
        if number.origin.x < bounds.origin.x + bounds.size.width * 0.65 {
            continue;
        }
        let center = number.origin.y + number.size.height / 2.0;
        let height = number.size.height.max(8.0);
        let row: Vec<_> = page
            .chars
            .iter()
            .filter(|c| {
                let y = c.rect.origin.y + c.rect.size.height / 2.0;
                (y - center).abs() < height * 1.5
                    && c.rect.max_x() < number.origin.x
                    && char::from_u32(c.unicode).is_some_and(|c| !c.is_whitespace())
            })
            .collect();
        let right = row.iter().map(|c| c.rect.max_x()).max_by(f64::total_cmp);
        let math = row.iter().any(|c| {
            crate::superscript::is_math_font(&c.font_name)
                || char::from_u32(c.unicode).is_some_and(|c| "=≤≥∑∫±".contains(c))
        });
        if !math
            || row.len() < 2
            || right.is_none_or(|right| number.origin.x - right < height * 1.5)
        {
            continue;
        }
        anchors.push((start, end, number, center));
    }
    let lines = crate::caption_lines(page, &chars);
    anchors
        .iter()
        .filter_map(|&(start, end, number, center)| {
            let mut bottom = (center - 64.0).max(bounds.origin.y);
            let mut top = (center + 64.0).min(bounds.max_y());
            for &(_, _, _, other) in &anchors {
                if other > center {
                    top = top.min((other + center) / 2.0);
                }
                if other < center {
                    bottom = bottom.max((other + center) / 2.0);
                }
            }
            for line in &lines {
                let prose_letters = page.chars[line.start..line.end]
                    .iter()
                    .filter(|c| {
                        !crate::superscript::is_math_font(&c.font_name)
                            && char::from_u32(c.unicode).is_some_and(char::is_alphabetic)
                    })
                    .count();
                let prose_words = line
                    .raw
                    .split_whitespace()
                    .filter(|word| word.chars().filter(|c| c.is_alphabetic()).count() >= 3)
                    .count();
                if prose_letters < 14 || prose_words < 3 {
                    continue;
                }
                if line.rect.origin.y > number.max_y() {
                    top = top.min(line.rect.origin.y - 2.0);
                }
                if line.rect.max_y() < number.origin.y {
                    bottom = bottom.max(line.rect.max_y() + 2.0);
                }
            }
            let glyphs: Vec<_> = page
                .chars
                .iter()
                .filter(|c| {
                    let y = c.rect.origin.y + c.rect.size.height / 2.0;
                    y >= bottom
                        && y <= top
                        && c.rect.origin.x >= bounds.origin.x
                        && c.rect.max_x() <= number.max_x() + 1.0
                        && char::from_u32(c.unicode).is_some_and(|c| !c.is_whitespace())
                })
                .cloned()
                .collect();
            let rect = union_boxes(&glyphs);
            let margin = 4.0;
            let rect = Rect::new(
                rect.origin.x - margin,
                rect.origin.y - margin,
                rect.size.width + margin * 2.0,
                rect.size.height + margin * 2.0,
            )
            .intersection(bounds)?;
            Some(Caption {
                kind: "Equation".into(),
                label: chars[start + 1..end - 1].iter().collect(),
                text: chars[start..end].iter().collect(),
                start,
                end,
                rect,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use lyra_reader_core::{Point, RawCharBox};

    fn page() -> RawTextPage {
        let mut raw = RawTextPage::default();
        for (x, y, text) in [
            (
                72.0,
                710.0,
                "Assuming a linear transformation, we obtain:\n",
            ),
            (170.0, 660.0, "x = alpha a + (1 - alpha) b\n"),
            (170.0, 642.0, "  = alpha x + (1 - alpha) y,\n"),
            (510.0, 642.0, "(A.38)\n"),
            (180.0, 600.0, "y = x + z,\n"),
            (510.0, 600.0, "(A.39)\n"),
            (
                72.0,
                555.0,
                "Since x = y, this explanation stays outside the crop.\n",
            ),
        ] {
            raw.text.push_str(text);
            raw.chars
                .extend(text.chars().enumerate().map(|(i, c)| RawCharBox {
                    rect: Rect::new(x + i as f64 * 5.0, y, 5.0, 10.0),
                    origin: Point::new(x + i as f64 * 5.0, y),
                    unicode: c as u32,
                    font_size: 10.0,
                    angle: 0.0,
                    font_name: "Body".into(),
                }));
        }
        raw
    }

    #[test]
    fn a_two_line_equation_excludes_prose_and_the_next_equation() {
        let found = find_numbered_equations(&page(), Rect::new(0.0, 0.0, 595.0, 842.0));
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].label, "A.38");
        assert!(found[0].rect.origin.y > 630.0);
        assert!(found[0].rect.max_y() >= 670.0 && found[0].rect.max_y() < 680.0);
        assert!(found[0].rect.origin.x > 160.0);
        assert!(found[1].rect.origin.y > 590.0 && found[1].rect.max_y() < 620.0);
    }

    #[test]
    fn an_inline_equation_reference_is_not_a_display_equation() {
        let mut raw = page();
        let mut reference = crate::test_page("We use x = y in Equation (A.38).\n");
        for c in &mut reference.chars {
            c.rect.origin.x += 400.0;
            c.origin.x += 400.0;
        }
        raw.chars.extend(reference.chars);
        assert_eq!(
            find_numbered_equations(&raw, Rect::new(0.0, 0.0, 700.0, 842.0)).len(),
            2
        );
    }
}

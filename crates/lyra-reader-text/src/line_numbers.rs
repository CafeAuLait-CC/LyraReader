//! Conservative selection-only recognition of manuscript line-number gutters. Character
//! arrays and PDF indices stay intact; repeated small numbers outside prose are not stops.
use crate::CharBox;
use lyra_reader_core::Rect;

struct Candidate {
    indices: std::ops::Range<usize>,
    rect: Rect,
    value: u32,
    side: u8,
    anchor: f64,
}

fn usable(character: &CharBox) -> bool {
    let r = character.rect;
    r.size.width > 0.0
        && r.size.height > 0.0
        && [
            r.min_x(),
            r.min_y(),
            r.max_x(),
            r.max_y(),
            r.size.width,
            r.size.height,
        ]
        .iter()
        .all(|v| v.is_finite())
}

pub(crate) fn selection_exclusions(chars: &[CharBox]) -> Vec<u32> {
    let mut letters: Vec<_> = chars
        .iter()
        .filter(|c| usable(c) && char::from_u32(c.unicode).is_some_and(char::is_alphabetic))
        .collect();
    letters.sort_by(|a, b| a.rect.center().y.total_cmp(&b.rect.center().y));
    let mut candidates = Vec::new();
    let mut index = 0;
    while index < chars.len() {
        let first = index;
        if !(48..=57).contains(&chars[index].unicode) || !usable(&chars[index]) {
            index += 1;
            continue;
        }
        let mut rect = chars[index].rect;
        let mut value = 0_u32;
        while index < chars.len() && (48..=57).contains(&chars[index].unicode) {
            if !usable(&chars[index]) {
                break;
            }
            let next = chars[index].rect;
            if index > first
                && ((next.min_x() - rect.max_x()).abs() > rect.size.height * 0.5
                    || (next.center().y - rect.center().y).abs() > rect.size.height * 0.4)
            {
                break;
            }
            if index - first < 4 {
                value = value * 10 + chars[index].unicode - 48;
            }
            rect = rect.union(next);
            index += 1;
        }
        if index - first > 4 || rect.size.height <= 0.0 || rect.size.width <= 0.0 {
            continue;
        }
        // Equation labels and numbered lists retain their punctuation and remain selectable.
        let punctuated = first
            .checked_sub(1)
            .into_iter()
            .chain((index < chars.len()).then_some(index))
            .any(|i| {
                let c = &chars[i];
                matches!(c.unicode, 40 | 41 | 46 | 58 | 91 | 93)
                    && (c.rect.center().y - rect.center().y).abs() < rect.size.height * 0.5
                    && (c.rect.min_x() - rect.max_x())
                        .max(rect.min_x() - c.rect.max_x())
                        .max(0.0)
                        < rect.size.height * 0.5
            });
        if punctuated {
            continue;
        }
        let low = letters
            .partition_point(|c| c.rect.center().y < rect.center().y - rect.size.height * 0.6);
        let high = letters
            .partition_point(|c| c.rect.center().y <= rect.center().y + rect.size.height * 0.6);
        let row = &letters[low..high];
        if row.len() < 8 {
            continue;
        }
        let mut heights: Vec<_> = row.iter().map(|c| c.rect.size.height).collect();
        heights.sort_by(f64::total_cmp);
        // Same-size numeric table cells and list counters are not manuscript margin labels.
        if rect.size.height >= heights[heights.len() / 2] * 0.92 {
            continue;
        }
        let left = row
            .iter()
            .map(|c| c.rect.min_x())
            .fold(f64::INFINITY, f64::min);
        let right = row
            .iter()
            .map(|c| c.rect.max_x())
            .fold(f64::NEG_INFINITY, f64::max);
        let gap = rect.size.height * 0.75;
        // A paragraph's short last line can end far from its margin counter. Alignment and
        // the consecutive sequence, rather than proximity to that one line, establish a gutter.
        let (side, anchor) = if rect.max_x() + gap < left {
            (0, rect.max_x())
        } else if rect.min_x() - gap > right {
            (1, rect.min_x())
        } else {
            continue;
        };
        candidates.push(Candidate {
            indices: first..index,
            rect,
            value,
            side,
            anchor,
        });
    }
    candidates.sort_by(|a, b| a.side.cmp(&b.side).then(a.anchor.total_cmp(&b.anchor)));
    let mut excluded = Vec::new();
    let mut remaining = candidates.as_mut_slice();
    while !remaining.is_empty() {
        let first = &remaining[0];
        let count = remaining
            .iter()
            .take_while(|c| {
                c.side == first.side
                    && (c.anchor - first.anchor).abs() < first.rect.size.height * 0.4
            })
            .count();
        let (group, rest) = remaining.split_at_mut(count);
        remaining = rest;
        if group.len() < 6 {
            continue;
        }
        group.sort_by(|a, b| a.rect.center().y.total_cmp(&b.rect.center().y));
        let mut connected = vec![false; group.len()];
        for (index, pair) in group.windows(2).enumerate() {
            let step = pair[1].rect.center().y - pair[0].rect.center().y;
            let height = pair[0].rect.size.height.max(pair[1].rect.size.height);
            if pair[0].value.checked_add(1) == Some(pair[1].value)
                && step > height * 0.8
                && step < height * 4.0
            {
                connected[index] = true;
                connected[index + 1] = true;
            }
        }
        let support = connected.iter().filter(|v| **v).count();
        if support < 6 || support < group.len() - group.len() / 5 {
            continue;
        }
        for (candidate, connected) in group.iter().zip(connected) {
            if connected {
                excluded.extend(
                    candidate
                        .indices
                        .clone()
                        .filter_map(|i| u32::try_from(i).ok()),
                );
            }
        }
    }
    excluded.sort_unstable();
    excluded
}

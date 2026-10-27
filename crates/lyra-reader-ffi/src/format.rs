//! Reader-facing page labels and PDF date parsing.
//!
//! The shell had several formatters that were *nearly* the same: AI previews wrote
//! `Page 3` / `Pages 1-3` / `Pages 1, 3, 5`, the layered summary wrote `1-12 and 109-120`,
//! the print title wrote `1-3, 5, 8-9`, and the page-operation menus wrote
//! `pages 1–3`. They are all display strings with different grammars, so this module owns one
//! function per grammar and the shell calls it instead of re-spelling the rules.
//!
//! The PDF date parser is the other half. `/M` (and `/CreationDate`) is
//! `D:YYYYMMDDHHmmSSOHH'mm'`; the offset is optional, and a date with no offset is read as
//! UTC. Two consumers exist and they deliberately differ:
//!
//! * the **sidebar** (and annotation passages) shows the clock digits as written, i.e. reads a
//!   zoned date as if it were UTC. That is the string users have always seen, so
//!   [`pdf_date_display`] keeps it: single-sourcing must not change the visible date.
//! * the **annotation export** needs an instant for ordering, so [`pdf_date_millis`] applies
//!   the offset (`+02'00'` means UTC+2, so the instant is two hours earlier than the same
//!   digits read as UTC).
//!
//! The divergence is intentional and tested; see the module tests at the bottom.

/// `Page 3`, `Pages 1-3`, `Pages 1, 3, 5` for 1-based pages.
///
/// This is the AI preview grammar. Pages are sorted and de-duplicated; a fully contiguous run
/// collapses to a single range, while a gap is listed comma-separated (no "and").
pub fn page_label(pages: &[u32]) -> String {
    let mut pages = pages.to_vec();
    pages.sort_unstable();
    pages.dedup();
    let Some(first) = pages.first().copied() else {
        return "No pages".to_string();
    };
    if pages.len() == 1 {
        return format!("Page {first}");
    }
    let last = pages[pages.len() - 1];
    let contiguous = pages.windows(2).all(|pair| pair[0] + 1 == pair[1]);
    if contiguous {
        return format!("Pages {first}-{last}");
    }
    format!(
        "Pages {}",
        pages
            .iter()
            .map(u32::to_string)
            .collect::<Vec<_>>()
            .join(", ")
    )
}

/// `1-12 and 109-120` for 1-based pages, sorted into inclusive runs.
///
/// This is the layered-summary coverage grammar; an empty list is the empty string (callers
/// only ask once they have at least one page).
pub fn page_ranges_label(pages: &[u32]) -> String {
    page_runs(pages)
        .into_iter()
        .map(|(start, end)| {
            if start == end {
                start.to_string()
            } else {
                format!("{start}-{end}")
            }
        })
        .collect::<Vec<_>>()
        .join(" and ")
}

/// `1-3, 5, 8-9` for 1-based pages, sorted and de-duplicated.
///
/// This is the print-job title grammar: a plain comma-separated list of ranges.
pub fn compact_page_ranges(pages: &[u32]) -> String {
    page_runs(pages)
        .into_iter()
        .map(|(start, end)| {
            if start == end {
                start.to_string()
            } else {
                format!("{start}-{end}")
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// `page 1`, `pages 1–3`, `pages 1, 3, 5` for **0-based** pages.
///
/// This is the page-operation menu grammar (lowercase, en dash for a run). `no pages` matches
/// the menus' empty-selection case.
pub fn page_list(pages: &[u32]) -> String {
    let Some(first) = pages.first().copied() else {
        return "no pages".to_string();
    };
    let last = pages[pages.len() - 1];
    if pages.len() == 1 {
        return format!("page {}", first + 1);
    }
    if last.wrapping_sub(first).saturating_add(1) as usize == pages.len() {
        return format!("pages {}–{}", first + 1, last + 1);
    }
    format!(
        "pages {}",
        pages
            .iter()
            .map(|page| (page + 1).to_string())
            .collect::<Vec<_>>()
            .join(", ")
    )
}

/// The layered-summary row's span label.
///
/// `kind` is the layer's raw value (`abstract`, `sections`, `pages`). The exact grammar is the
/// shipping one: the abstract may sample both ends of a long document, and a section whose
/// text budget cut it says `Pages 4-7 of 4-12`.
#[allow(clippy::too_many_arguments)]
pub fn page_span_label(
    kind: &str,
    pages: &[u32],
    page_start: u32,
    page_end: u32,
    covered_page_end: u32,
    truncated: bool,
    page_count: u32,
) -> String {
    if kind == "abstract" {
        if !pages.is_empty() {
            if pages.len() == page_count as usize
                && pages.first() == Some(&1)
                && pages.last() == Some(&page_count)
            {
                return format!("All {page_count} pages");
            }
            return format!("Pages {} of {page_count}", page_ranges_label(pages));
        }
        let end = if covered_page_end > 0 {
            covered_page_end
        } else {
            page_end.min(page_count)
        };
        return if end >= page_count {
            format!("All {page_count} pages")
        } else {
            format!("Pages 1-{end} of {page_count}")
        };
    }
    if page_start == page_end {
        return format!("Page {page_start} of {page_count}");
    }
    let end = if covered_page_end > 0 {
        covered_page_end.min(page_end)
    } else {
        page_end
    };
    if truncated && end < page_end {
        format!("Pages {page_start}-{end} of {page_start}-{page_end}")
    } else {
        format!("Pages {page_start}-{page_end} of {page_count}")
    }
}

/// Inclusive runs of sorted, de-duplicated 1-based pages.
fn page_runs(pages: &[u32]) -> Vec<(u32, u32)> {
    let mut sorted = pages.to_vec();
    sorted.sort_unstable();
    sorted.dedup();
    let mut runs: Vec<(u32, u32)> = Vec::new();
    for page in sorted {
        match runs.last_mut() {
            Some((_, end)) if page == *end + 1 => *end = page,
            _ => runs.push((page, page)),
        }
    }
    runs
}

/// The sidebar/passages date string for a PDF `/M` value: `YYYY-MM-DD HH:mm` in the clock
/// **as written**, or the original string when it is not the `D:…` shape.
///
/// The offset is deliberately ignored here. See the module note: this is the historical
/// display, and changing it would change what readers see.
pub fn pdf_date_display(value: &str) -> Option<String> {
    if value.is_empty() {
        return None;
    }
    let text = value.strip_prefix("D:").unwrap_or(value);
    let Some((year, month, day, hour, minute, _second)) = parse_stamp(text) else {
        return Some(value.to_string());
    };
    Some(format!(
        "{year:04}-{month:02}-{day:02} {hour:02}:{minute:02}"
    ))
}

/// The instant a PDF date names, in milliseconds since the Unix epoch (UTC).
///
/// Applies the offset when the value carries one. Returns `None` for a value that is not the
/// PDF date shape; the caller treats that as "no date" rather than inventing one.
pub fn pdf_date_millis(value: &str) -> Option<i64> {
    let text = value.strip_prefix("D:").unwrap_or(value);
    let (year, month, day, hour, minute, second) = parse_stamp(text)?;
    let base = days_from_civil(i64::from(year), month, day) * 86_400
        + i64::from(hour) * 3_600
        + i64::from(minute) * 60
        + i64::from(second);
    let remainder: String = text.chars().skip(14).collect();
    let mut chars = remainder.chars();
    let sign = match chars.next() {
        Some('+') => '+',
        Some('-') => '-',
        _ => return Some(base * 1_000),
    };
    let digits: String = chars
        .filter(|character| character.is_ascii_digit())
        .collect();
    if digits.len() < 2 {
        return Some(base * 1_000);
    }
    let hours: i64 = digits[0..2].parse().unwrap_or(0);
    let minutes: i64 = if digits.len() >= 4 {
        digits[2..4].parse().unwrap_or(0)
    } else {
        0
    };
    let offset = hours * 3_600 + minutes * 60;
    // `+02'00'` means the clock reads UTC+2: the instant is two hours earlier than the digits
    // read as UTC. A negative offset is the other way round.
    let adjusted = if sign == '+' {
        base - offset
    } else {
        base + offset
    };
    Some(adjusted * 1_000)
}

/// The date/time fields of `YYYYMMDDHHmmSS`, validated as a real Gregorian date.
fn parse_stamp(text: &str) -> Option<(i32, u32, u32, u32, u32, u32)> {
    let stamp: String = text.chars().take(14).collect();
    if stamp.chars().count() != 14 || !stamp.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let number = |range: std::ops::Range<usize>| stamp[range].parse::<u32>().ok();
    let year = stamp[0..4].parse::<i32>().ok()?;
    let month = number(4..6)?;
    let day = number(6..8)?;
    let hour = number(8..10)?;
    let minute = number(10..12)?;
    let second = number(12..14)?;
    if year < 1
        || !(1..=12).contains(&month)
        || day < 1
        || day > days_in_month(year, month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    Some((year, month, day, hour, minute, second))
}

fn is_leap_year(year: i32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

fn days_in_month(year: i32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if is_leap_year(year) => 29,
        2 => 28,
        _ => 0,
    }
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(year: i64, month: u32, day: u32) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month_index = if month > 2 {
        i64::from(month) - 3
    } else {
        i64::from(month) + 9
    };
    let day_of_year = (153 * month_index + 2) / 5 + i64::from(day) - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_labels_match_the_preview_grammar() {
        assert_eq!(page_label(&[]), "No pages");
        assert_eq!(page_label(&[3]), "Page 3");
        assert_eq!(page_label(&[1, 2, 3]), "Pages 1-3");
        assert_eq!(page_label(&[3, 1, 2, 2]), "Pages 1-3");
        assert_eq!(page_label(&[1, 3, 5]), "Pages 1, 3, 5");
        assert_eq!(page_label(&[1, 2, 4, 5]), "Pages 1, 2, 4, 5");
    }

    #[test]
    fn summary_ranges_join_with_and() {
        assert_eq!(
            page_ranges_label(&[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
            "1-12"
        );
        assert_eq!(
            page_ranges_label(&[109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120]),
            "109-120"
        );
        assert_eq!(page_ranges_label(&[1, 2, 3, 5, 6, 7]), "1-3 and 5-7");
        assert_eq!(page_ranges_label(&[4]), "4");
        assert_eq!(page_ranges_label(&[]), "");
    }

    #[test]
    fn compact_ranges_are_comma_separated() {
        assert_eq!(compact_page_ranges(&[1, 2, 3, 5, 8, 9]), "1-3, 5, 8-9");
        assert_eq!(compact_page_ranges(&[2]), "2");
        assert_eq!(compact_page_ranges(&[]), "");
    }

    #[test]
    fn page_lists_are_lowercase_and_use_an_en_dash() {
        assert_eq!(page_list(&[]), "no pages");
        assert_eq!(page_list(&[0]), "page 1");
        assert_eq!(page_list(&[0, 1, 2]), "pages 1–3");
        assert_eq!(page_list(&[0, 2, 4]), "pages 1, 3, 5");
        assert_eq!(page_list(&[4]), "page 5");
    }

    #[test]
    fn summary_span_labels_keep_their_exact_wording() {
        assert_eq!(
            page_span_label("abstract", &[1, 2, 3, 4, 5], 1, 5, 0, false, 5),
            "All 5 pages"
        );
        assert_eq!(
            page_span_label(
                "abstract",
                &[1, 2, 109, 110, 119, 120],
                1,
                120,
                0,
                false,
                120
            ),
            "Pages 1-2 and 109-110 and 119-120 of 120"
        );
        assert_eq!(
            page_span_label("sections", &[], 4, 12, 7, true, 120),
            "Pages 4-7 of 4-12"
        );
        assert_eq!(
            page_span_label("pages", &[], 4, 4, 0, false, 120),
            "Page 4 of 120"
        );
        assert_eq!(
            page_span_label("pages", &[], 4, 12, 0, false, 120),
            "Pages 4-12 of 120"
        );
    }

    #[test]
    fn a_zoned_date_keeps_the_sidebar_string_but_the_export_instant_applies_the_offset() {
        let zoned = "D:20261017174000-07'00'";
        // Historical sidebar/passages display: the clock digits, no zone conversion.
        assert_eq!(pdf_date_display(zoned).as_deref(), Some("2026-10-17 17:40"));
        // The instant is 2026-10-18T00:40Z: UTC-7 means the clock is seven hours behind UTC.
        let utc_base = pdf_date_millis("D:20261017174000Z").expect("utc");
        let zoned_instant = pdf_date_millis(zoned).expect("zoned");
        assert_eq!(zoned_instant - utc_base, 7 * 3_600 * 1_000);
        assert_eq!(
            pdf_date_millis("D:20261017174000+02'30'").expect("positive offset"),
            utc_base - (2 * 3_600 + 30 * 60) * 1_000
        );
        assert_eq!(
            pdf_date_millis("D:20261017174000").expect("no offset is UTC"),
            utc_base
        );
    }

    #[test]
    fn malformed_dates_are_not_invented() {
        assert_eq!(pdf_date_display(""), None);
        assert_eq!(pdf_date_display("D:bad"), Some("D:bad".to_string()));
        assert_eq!(
            pdf_date_display("D:20260230120000").as_deref(),
            Some("D:20260230120000")
        );
        assert_eq!(
            pdf_date_display("D:20240229120000").as_deref(),
            Some("2024-02-29 12:00")
        );
        assert_eq!(pdf_date_millis("D:20260230120000"), None);
        assert_eq!(pdf_date_millis("D:2026"), None);
        assert_eq!(
            pdf_date_millis("D:20261017174000Z"),
            Some(utc_stamp() * 1_000)
        );
    }

    fn utc_stamp() -> i64 {
        // 2026-10-17T17:40:00Z
        days_from_civil(2026, 10, 17) * 86_400 + 17 * 3_600 + 40 * 60
    }
}

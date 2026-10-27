//! Small numeric/range helpers shared by the engine crates.
//!
//! Two copies of a conversion or a range check are enough for the copies to drift; these are the
//! single spellings the engine uses. They are intentionally tiny and dependency-free.

/// Clamps a `usize` count to `u32` instead of wrapping.
///
/// Every current caller converts a count of objects the process already holds (pages, annotation
/// slots, outline entries, cleaned temporary files, a report's elapsed microseconds). Those counts
/// are bounded far below `u32::MAX` by the formats and limits they come from: PDFium reports a
/// page count as a positive `i32`, and every collection is built behind an explicit byte/count
/// limit. Should such a count ever exceed `u32::MAX` anyway, showing `4294967295` is the honest
/// representation of "more than the protocol can name"; `as u32` would instead wrap to a small
/// number and silently misreport the value. Clamping is therefore the documented last resort,
/// not a substitute for validating a file-controlled length (those go through
/// [`crate::Result`]-returning `checked_*` helpers).
pub fn saturating_u32(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

/// The user-facing sentence for a page index outside the document.
///
/// `page` is the engine's **0-based** page index; `page_count` is the number of pages. The
/// sentence is 1-based because every page number the reader sees is, and it is the one sentence
/// for this class of error across every engine entry point (render, annotations, AI context).
/// Operations whose page number means something different (for example an annotation's recorded
/// target page) keep their own sentence.
pub fn page_out_of_range_message(page: u32, page_count: u32) -> String {
    format!(
        "page {} is outside the document (it has {} page(s))",
        page as u64 + 1,
        page_count
    )
}

/// Validates a **0-based** page index against the document's page count.
///
/// Returns the index unchanged when it is in range, otherwise calls `out_of_range` with the
/// 0-based index so the caller can build its own error type (core, FFI, AI) at the boundary.
/// Keeping the error construction in the caller is what lets the same range rule serve three
/// error models without duplicating the comparison.
pub fn checked_page_index<E>(
    page: u32,
    page_count: u32,
    out_of_range: impl FnOnce(u32) -> E,
) -> std::result::Result<u32, E> {
    if page < page_count {
        Ok(page)
    } else {
        Err(out_of_range(page))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saturating_u32_clamps_instead_of_wrapping() {
        assert_eq!(saturating_u32(0), 0);
        assert_eq!(saturating_u32(40), 40);
        assert_eq!(saturating_u32(u32::MAX as usize), u32::MAX);
        assert_eq!(saturating_u32(u32::MAX as usize + 1), u32::MAX);
        assert_eq!(saturating_u32(usize::MAX), u32::MAX);
    }

    #[test]
    fn checked_page_index_keeps_in_range_pages_and_reports_the_0_based_index() {
        assert_eq!(checked_page_index(0, 3, |page| page), Ok(0));
        assert_eq!(checked_page_index(2, 3, |page| page), Ok(2));
        assert_eq!(checked_page_index(3, 3, |page| page), Err(3));
        assert_eq!(checked_page_index(0, 0, |page| page), Err(0));
        assert_eq!(checked_page_index(u32::MAX, 1, |page| page), Err(u32::MAX));
    }

    #[test]
    fn the_page_range_sentence_is_one_based_and_keeps_both_numbers() {
        assert_eq!(
            page_out_of_range_message(0, 3),
            "page 1 is outside the document (it has 3 page(s))"
        );
        assert_eq!(
            page_out_of_range_message(2, 3),
            "page 3 is outside the document (it has 3 page(s))"
        );
        assert_eq!(
            page_out_of_range_message(99, 3),
            "page 100 is outside the document (it has 3 page(s))"
        );
        // u32::MAX + 1 must not wrap the displayed number.
        assert_eq!(
            page_out_of_range_message(u32::MAX, 0),
            format!(
                "page {} is outside the document (it has 0 page(s))",
                u64::from(u32::MAX) + 1
            )
        );
    }
}

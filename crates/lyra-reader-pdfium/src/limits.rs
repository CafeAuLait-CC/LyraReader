//! Conversions for values crossing PDFium's C ABI.
//!
//! Two places in this crate turned an out-of-range C integer into a plausible value: a document
//! length larger than `c_int::MAX` wrapped negative, and a page count of `-1` became "zero
//! pages". Both are PDFium failures, not empty documents, so the conversions return an error
//! that names the value instead.

use lyra_reader_core::{ErrorCode, LyraReaderError, Result};
use std::ffi::c_int;

/// A document length as `FPDF_LoadMemDocument` takes it.
///
/// `bytes.len() as c_int` truncates above 2 GiB (and wraps negative on some platforms), which
/// hands PDFium a length that does not describe the buffer. Refuse instead.
pub(crate) fn document_len(len: usize) -> Result<c_int> {
    c_int::try_from(len).map_err(|_| {
        LyraReaderError::new(
            ErrorCode::InvalidArgument,
            format!(
                "the document is {len} bytes, larger than PDFium's {}-byte C API limit",
                c_int::MAX
            ),
        )
    })
}

/// A page count reported by PDFium.
///
/// `FPDF_GetPageCount` returns `-1` on failure. Clamping that to zero would report a valid
/// document as empty, so the failure stays an error.
pub(crate) fn page_count(value: c_int) -> Result<u32> {
    u32::try_from(value).map_err(|_| {
        LyraReaderError::new(
            ErrorCode::CorruptDocument,
            format!("PDFium reported a page count of {value} instead of a non-negative count"),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_document_over_two_gibibytes_is_refused_before_the_cast() {
        let too_large = c_int::MAX as usize + 1;
        let error = document_len(too_large).expect_err("more than c_int::MAX bytes must fail");
        assert_eq!(error.code, ErrorCode::InvalidArgument);
        assert!(
            error.message.contains(&too_large.to_string()),
            "the error must name the size that was refused: {error}"
        );
        assert_eq!(document_len(1024).expect("an ordinary document"), 1024);
    }

    #[test]
    fn a_negative_page_count_is_an_error_not_an_empty_document() {
        let error = page_count(-1).expect_err("PDFium's failure sentinel must not be zero pages");
        assert_eq!(error.code, ErrorCode::CorruptDocument);
        assert!(
            error.message.contains("-1"),
            "the error must name the count PDFium returned: {error}"
        );
        assert_eq!(page_count(0).expect("an empty document is valid"), 0);
        assert_eq!(page_count(7).expect("a page count"), 7);
    }
}

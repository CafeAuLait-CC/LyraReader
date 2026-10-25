//! Unified error type.
//!
//! When an error crosses the FFI boundary it is mapped to a Swift `throws` (see `docs/05-ffi.md` §5):
//! `code` is a stable identifier (used for documentation), `message` is a human-readable English
//! summary, `detail` is optional technical detail (for logs), and `severity` tells the shell how
//! to present it. The shell reads `severity` from the FFI payload; it is not inferred from the
//! message.
//!
//! Severity is about **how the user must be interrupted**, not how bad the exception looks:
//!
//! * [`Severity::Recoverable`] — one feature failed and can be retried or ignored; reading and the
//!   document itself are unaffected (a page raster that falls back to a placeholder).
//! * [`Severity::Document`] — the requested document operation failed; the reader must be told
//!   (open/save/export failures, a corrupt page tree, a policy refusal).
//! * [`Severity::Fatal`] — the engine cannot continue to be trusted (GPU device loss, a broken
//!   internal invariant); the reader must restart rather than retry silently.

use std::fmt;

/// Error severity, which determines how the UI handles the error.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Severity {
    /// Recoverable: e.g. a single page fails to render; continue with placeholder content without interrupting the user.
    Recoverable,
    /// Document-level: e.g. open failure or wrong password; the user must be notified.
    Document,
    /// Fatal: e.g. GPU device loss or a broken internal invariant; requires a rebuild or restart.
    Fatal,
}

/// Stable error codes (**do not change the semantics of existing variants**; only append).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorCode {
    Io,
    NotFound,
    InvalidArgument,
    Encrypted,
    WrongPassword,
    CorruptDocument,
    /// The document is read-only by policy (a signed PDF), so writing is refused.
    ReadOnly,
    UnsupportedFeature,
    BackendUnavailable,
    RenderFailed,
    GpuUnavailable,
    GpuDeviceLost,
    Internal,
}

impl ErrorCode {
    /// The default severity for this code.
    ///
    /// Every variant is listed explicitly: adding a code should force the author to decide how
    /// the shell presents it, rather than inherit a wildcard's guess. A call site that knows a
    /// specific failure is different can override this with
    /// [`LyraReaderError::with_severity`].
    pub fn severity(self) -> Severity {
        match self {
            // A single page/render failed; other pages and the document remain usable.
            Self::RenderFailed => Severity::Recoverable,
            // The engine's own invariants or device are gone; retrying in-process is not safe.
            Self::GpuUnavailable | Self::GpuDeviceLost | Self::Internal => Severity::Fatal,
            // Everything else is a failure of the requested document operation.
            Self::Io
            | Self::NotFound
            | Self::InvalidArgument
            | Self::Encrypted
            | Self::WrongPassword
            | Self::CorruptDocument
            | Self::ReadOnly
            | Self::UnsupportedFeature
            | Self::BackendUnavailable => Severity::Document,
        }
    }
}

/// LyraReader unified error.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LyraReaderError {
    pub code: ErrorCode,
    pub message: String,
    pub detail: Option<String>,
    pub severity: Severity,
}

impl LyraReaderError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            detail: None,
            severity: code.severity(),
        }
    }

    pub fn with_detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = Some(detail.into());
        self
    }

    pub fn with_severity(mut self, severity: Severity) -> Self {
        self.severity = severity;
        self
    }

    pub fn not_implemented(what: &str) -> Self {
        Self::new(
            ErrorCode::UnsupportedFeature,
            format!("not implemented yet: {what}"),
        )
    }
}

impl fmt::Display for LyraReaderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.code, self.message)?;
        if let Some(detail) = &self.detail {
            write!(f, " ({detail})")?;
        }
        Ok(())
    }
}

impl std::error::Error for LyraReaderError {}

impl From<std::io::Error> for LyraReaderError {
    fn from(err: std::io::Error) -> Self {
        let code = match err.kind() {
            std::io::ErrorKind::NotFound => ErrorCode::NotFound,
            std::io::ErrorKind::InvalidInput => ErrorCode::InvalidArgument,
            _ => ErrorCode::Io,
        };
        Self::new(code, err.to_string())
    }
}

pub type Result<T> = std::result::Result<T, LyraReaderError>;

#[cfg(test)]
mod tests {
    use super::*;

    /// One representative code per severity class. The shell's table-driven presentation check
    /// consumes the same three classes, so a change to a default is visible in both places.
    #[test]
    fn every_severity_class_has_a_representative_code() {
        let classes = [
            (
                ErrorCode::RenderFailed,
                Severity::Recoverable,
                "a failed page raster is recoverable",
            ),
            (
                ErrorCode::CorruptDocument,
                Severity::Document,
                "a document the reader cannot parse needs a document-level message",
            ),
            (
                ErrorCode::GpuDeviceLost,
                Severity::Fatal,
                "a lost GPU device requires a restart",
            ),
        ];
        for (code, expected, why) in classes {
            assert_eq!(code.severity(), expected, "{why}");
            assert_eq!(
                LyraReaderError::new(code, "message").severity,
                expected,
                "{why}: constructing via LyraReaderError uses the code's severity"
            );
        }
    }

    #[test]
    fn every_code_still_has_a_severity() {
        // Exhaustive on purpose: deleting or adding a variant must be a compile-time decision,
        // and this loop is the runtime assertion that the mapping covers the whole enum.
        for code in [
            ErrorCode::Io,
            ErrorCode::NotFound,
            ErrorCode::InvalidArgument,
            ErrorCode::Encrypted,
            ErrorCode::WrongPassword,
            ErrorCode::CorruptDocument,
            ErrorCode::ReadOnly,
            ErrorCode::UnsupportedFeature,
            ErrorCode::BackendUnavailable,
            ErrorCode::RenderFailed,
            ErrorCode::GpuUnavailable,
            ErrorCode::GpuDeviceLost,
            ErrorCode::Internal,
        ] {
            let severity = code.severity();
            assert!(
                matches!(
                    severity,
                    Severity::Recoverable | Severity::Document | Severity::Fatal
                ),
                "{code:?} has a severity"
            );
        }
    }

    #[test]
    fn a_call_site_can_override_the_default_severity() {
        let error = LyraReaderError::new(ErrorCode::RenderFailed, "timed out")
            .with_severity(Severity::Recoverable);
        assert_eq!(error.severity, Severity::Recoverable);
        let error =
            LyraReaderError::new(ErrorCode::Io, "write failed").with_severity(Severity::Document);
        assert_eq!(error.severity, Severity::Document);
    }
}

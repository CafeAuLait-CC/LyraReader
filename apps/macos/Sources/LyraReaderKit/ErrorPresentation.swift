import LyraReaderBindings

/// The surface on which the shell shows an error.
///
/// One table maps an engine [`ErrorSeverity`] to one surface; call sites never choose between
/// alert/banner/status themselves. `alert` is the blocking `NSAlert` in `ReaderWindow`; `banner`
/// is the dismissible inline strip above the page; `status` is the window's status sentence.
public enum ErrorPresentation: String, CaseIterable, Sendable {
    /// A blocking alert: the reader must acknowledge the failure.
    case alert
    /// An inline, dismissible banner above the page.
    case banner
    /// The window's status line; no interruption.
    case status
}

public extension ErrorSeverity {
    /// The shell's single presentation decision for this severity.
    ///
    /// * `Fatal` — the engine cannot be trusted until restart: alert.
    /// * `Document` — the requested document operation failed: alert. This preserves the
    ///   presentation every engine error had before the severity payload existed (`docs/02`:
    ///   "Document (open failure → alert)").
    /// * `Recoverable` — one feature failed while reading continues: inline banner. The banner is
    ///   mirrored to the status line by `AppState.present(message:severity:)`.
    var presentation: ErrorPresentation {
        switch self {
        case .fatal: return .alert
        case .document: return .alert
        case .recoverable: return .banner
        }
    }
}

public extension LyraReaderFfiError {
    /// The severity carried in the error payload.
    ///
    /// Every variant carries one, so this is a structural read, not a guess from the message.
    var severity: ErrorSeverity {
        switch self {
        case .Document(_, let severity),
             .Backend(_, let severity),
             .InvalidArgument(_, let severity),
             .Ai(_, _, let severity):
            return severity
        }
    }
}

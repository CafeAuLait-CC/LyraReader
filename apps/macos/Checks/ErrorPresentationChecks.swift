import LyraReaderBindings
import LyraReaderKit
import Foundation

extension ReaderChecks {
    // MARK: - Error severity → presentation (A11)

    /// The shell has one severity → surface table, and every existing error path keeps the
    /// presentation it had before the severity payload existed.
    ///
    /// The "existing paths" table is the captured map: every `LyraReaderFfiError` thrown by the
    /// engine used to be assigned to `lastError`, which `ReaderWindow` presents as the blocking
    /// alert. The table below names one representative per payload variant (plus a non-FFI
    /// Cocoa-style error) and asserts that all of them still present as `.alert`.
    @MainActor static func errorPresentationChecks() async throws {
        // 1. The single table. Fatal and Document interrupt; Recoverable does not.
        let severityTable: [(severity: ErrorSeverity, expected: ErrorPresentation, why: String)] = [
            (.fatal, .alert, "a fatal engine failure still blocks with an alert"),
            (.document, .alert, "a failed document operation still blocks with an alert"),
            (.recoverable, .banner, "a recoverable failure is shown inline, not as an alert"),
        ]
        for row in severityTable {
            require(row.severity.presentation == row.expected, row.why)
        }

        // 2. Each severity renders its surface. A separate state per row keeps one row's alert
        //    from masking the next row's banner.
        do {
            let state = AppState(engine: try RustEngine())
            let before = state.statusMessage
            let message = "The document could not be opened"
            state.present(message: message, severity: .document)
            require(state.isErrorAlertPresented && state.lastError == message,
                    "document severity renders the alert")
            require(!state.isRecoverableErrorBannerPresented,
                    "document severity does not add an inline banner")
            require(state.statusMessage == before,
                    "document severity does not silently rewrite the status line")
        }
        do {
            let state = AppState(engine: try RustEngine())
            let message = "The GPU device was lost"
            state.present(message: message, severity: .fatal)
            require(state.isErrorAlertPresented && state.lastError == message,
                    "fatal severity renders the alert")
            require(!state.isRecoverableErrorBannerPresented,
                    "fatal severity does not add an inline banner")
        }
        do {
            let state = AppState(engine: try RustEngine())
            let message = "page 4 is outside the document (it has 3 page(s))"
            state.present(message: message, severity: .recoverable)
            require(state.isRecoverableErrorBannerPresented
                        && state.recoverableErrorBanner == message,
                    "recoverable severity renders the inline banner")
            require(!state.isErrorAlertPresented,
                    "recoverable severity does not interrupt with an alert")
            require(state.statusMessage == message,
                    "recoverable severity mirrors the sentence to the status line")
        }

        // 3. Existing paths keep their captured presentation. Every engine error today reaches
        //    `lastError` through a catch block; that is the alert surface. The payload severity
        //    is read, not guessed from the message or the variant.
        let documentMessage = "The document is password protected"
        let existingPaths: [(name: String, error: LyraReaderFfiError, severity: ErrorSeverity)] = [
            ("open-failure",
             .Document(message: documentMessage, severity: .document), .document),
            ("backend-failure",
             .Backend(message: "could not load PDFium", severity: .fatal), .fatal),
            ("invalid-argument",
             .InvalidArgument(message: "page 9 is outside the document (it has 3 page(s))",
                              severity: .document), .document),
            ("ai-config-refusal",
             .Ai(message: "No API key is configured. Add one in Settings > AI; nothing was sent.",
                 code: .invalidSettings, severity: .document), .document),
        ]
        for row in existingPaths {
            require(row.error.severity == row.severity,
                    "\(row.name) reads its severity from the payload")
            require(row.severity.presentation == .alert,
                    "\(row.name) still presents as the alert it presented before this change")
            let state = AppState(engine: try RustEngine())
            state.present(row.error)
            require(state.isErrorAlertPresented && state.lastError != nil,
                    "\(row.name) reaches the alert surface")
            require(!state.isRecoverableErrorBannerPresented,
                    "\(row.name) does not move to the inline banner")
        }

        // 4. A non-FFI error (Cocoa, NSError, a local guard) has always been put in `lastError`
        //    directly; the presenter gives it document severity and therefore the same alert.
        do {
            let state = AppState(engine: try RustEngine())
            let error = NSError(domain: "LyraReaderChecks", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "The file is not a PDF."])
            state.present(error)
            require(state.isErrorAlertPresented && state.lastError == "The file is not a PDF.",
                    "a non-FFI error keeps its alert presentation")
        }

        // 5. The banner is dismissible and the status line keeps the sentence, so the failure is
        //    still visible after acknowledgement.
        do {
            let state = AppState(engine: try RustEngine())
            state.present(message: "one page could not be rendered", severity: .recoverable)
            state.dismissRecoverableError()
            require(!state.isRecoverableErrorBannerPresented,
                    "dismissing the recoverable banner removes it")
            require(state.statusMessage == "one page could not be rendered",
                    "the status line keeps the recoverable sentence after dismissal")
        }
    }
}

import AppKit
import Foundation
import UniformTypeIdentifiers

/// One document the quit prompt is about.
///
/// The list is built from the same `tabHasUnsavedChanges` predicate as the tab dot, the tab-close
/// prompt and the tab-transfer refusal, so all four surfaces agree on what "unsaved" means.
public struct QuitUnsavedDocument: Identifiable, Equatable, Sendable {
    /// The tab identity, not the document URL: the same file may legitimately be open twice, and
    /// the coordinator needs to be able to bring each copy on screen.
    public let id: UUID
    /// Index into the coordinator's `windows` array (the app's registry order).
    public let windowIndex: Int
    public let title: String
    /// The original file the drafts belong to (never a cached working revision).
    public let documentURL: URL
    public let isReadOnly: Bool
    /// Reader-facing description of the pending kinds, e.g. "page edits, annotations".
    public let changeSummary: String

    public init(
        id: UUID,
        windowIndex: Int,
        title: String,
        documentURL: URL,
        isReadOnly: Bool,
        changeSummary: String
    ) {
        self.id = id
        self.windowIndex = windowIndex
        self.title = title
        self.documentURL = documentURL
        self.isReadOnly = isReadOnly
        self.changeSummary = changeSummary
    }
}

/// What the reader answered on the quit prompt.
public enum QuitUnsavedDecision: Equatable {
    case saveAll
    case discardAll
    case cancel
}

/// How one document would be saved for a Save All decision.
public enum QuitSavePlan: Equatable {
    /// The existing in-place Save path (`saveDocumentToOriginal`, or the form writer for a
    /// form-only draft).
    case inPlace
    /// The document is read-only in place (a signed original); the existing Save As writers write
    /// the changes to `suggestion`. XFA forms are `.blocked`: they cannot be copied either.
    case copy(suggestion: URL)
    /// No existing path can save this document as it stands; the reason is shown to the reader.
    case blocked(String)
}

/// The result of saving one document during quit resolution.
public enum QuitSaveOutcome: Equatable {
    case saved
    case needsCopy(URL)
    case failed(String)
}

/// The wording shared by the tab-close prompt and the quit prompt.
///
/// Both surfaces ask the same question with the same vocabulary (Save / Discard Changes /
/// Cancel); only their scope differs, so a reader never has to learn two mental models for the
/// same decision.
public enum UnsavedChangesPrompt {
    public static let save = "Save"
    public static let saveCopy = "Save a Copy…"
    public static let discard = "Discard Changes"
    public static let cancel = "Cancel"
    public static let review = "Review Changes"
    public static let saveAll = "Save All"
    public static let discardAll = "Discard All Changes"

    public static func closeTitle(documentTitle: String?) -> String {
        guard let documentTitle, !documentTitle.isEmpty else {
            return "Save changes before closing?"
        }
        return "Save changes to “\(documentTitle)” before closing?"
    }

    public static func quitTitle(count: Int) -> String {
        count == 1
            ? "Save changes to 1 document before quitting?"
            : "Save changes to \(count) documents before quitting?"
    }

    public static func quitMessage(documents: [QuitUnsavedDocument]) -> String {
        let shown = documents.prefix(6).map { document in
            "• “\(document.title)” — \(document.changeSummary)"
        }
        var lines = shown
        if documents.count > shown.count {
            lines.append("…and \(documents.count - shown.count) more.")
        }
        var message = lines.joined(separator: "\n")
        if documents.contains(where: \.isReadOnly) {
            message += "\n\nRead-only documents are written to a copy; their originals stay unchanged."
        }
        message += "\n\nIf you don't save, these changes are lost and will not be restored the "
            + "next time the document is opened."
        return message
    }
}

/// Resolves a quit that has unsaved documents.
///
/// The decision model is deliberately separate from AppKit: the delegate supplies the modal
/// alert, this type supplies the deterministic Save All / Discard All / Cancel behaviour, and the
/// native checks drive it with injected closures. No save path is reimplemented here — Save All
/// activates each dirty tab and calls the same ``AppState/saveDocumentForQuit()`` and
/// ``AppState/saveDocumentCopyForQuit(to:)`` methods the menus use.
@MainActor
public final class QuitUnsavedCoordinator {
    public typealias Prompt = @MainActor ([QuitUnsavedDocument]) -> QuitUnsavedDecision
    public typealias SaveDestination = @MainActor (QuitUnsavedDocument, URL) -> URL?
    public typealias Reporter = @MainActor (String) -> Void

    private let windows: [AppState]
    private let prompt: Prompt
    private let saveDestination: SaveDestination
    private let reporter: Reporter
    /// Where each window was looking before Save All started switching tabs, so an aborted
    /// attempt can put the window back.
    private let originalActiveTabs: [(state: AppState, tabID: UUID?)]

    public init(
        windows: [AppState],
        prompt: Prompt? = nil,
        saveDestination: SaveDestination? = nil,
        reporter: Reporter? = nil
    ) {
        self.windows = windows
        self.prompt = prompt ?? Self.presentQuitPrompt
        self.saveDestination = saveDestination ?? Self.presentSaveCopyPanel
        self.reporter = reporter ?? Self.presentAbortAlert
        self.originalActiveTabs = windows.map { ($0, $0.activeTabID) }
    }

    /// Every unsaved document across every window, in registry/tab order.
    public func documents() -> [QuitUnsavedDocument] {
        var seenStates = Set<ObjectIdentifier>()
        var documents: [QuitUnsavedDocument] = []
        for (index, state) in windows.enumerated() {
            guard seenStates.insert(ObjectIdentifier(state)).inserted else { continue }
            documents.append(contentsOf: state.unsavedQuitDocuments(windowIndex: index))
        }
        return documents
    }

    /// Asks the reader. Exposed so a check can assert what the prompt is shown.
    public func decision(for documents: [QuitUnsavedDocument]) -> QuitUnsavedDecision {
        guard !documents.isEmpty else { return .cancel }
        return prompt(documents)
    }

    /// Applies one answer. Returns true when the app may terminate now.
    ///
    /// - Cancel: nothing is touched.
    /// - Discard All: one clean-exit marker per document, then quit. The drafts are not deleted
    ///   here; the next open retires them. A marker write failure aborts the quit with the
    ///   content untouched.
    /// - Save All: every document is saved first, in prompt order, each through its existing save
    ///   path. Any blocked document, cancelled Save As panel or failed save aborts the quit; a
    ///   document saved earlier in the pass stays saved (the PDF was written successfully), and
    ///   the marker is written only after every document succeeded.
    public func resolve(
        _ decision: QuitUnsavedDecision,
        documents: [QuitUnsavedDocument]? = nil
    ) async -> Bool {
        let documents = documents ?? self.documents()
        guard !documents.isEmpty else { return true }
        switch decision {
        case .cancel:
            return false
        case .discardAll:
            return resolveDiscard(documents)
        case .saveAll:
            return await resolveSaveAll(documents)
        }
    }

    // MARK: - Discard All

    private func resolveDiscard(_ documents: [QuitUnsavedDocument]) -> Bool {
        flushWindows()
        guard recordCleanExitMarkers(documents, resolution: .discard) else {
            reporter(
                "LyraReader could not record that the unsaved changes were discarded, so "
                + "the quit was cancelled. Nothing was changed.")
            return false
        }
        return true
    }

    // MARK: - Save All

    private func resolveSaveAll(_ documents: [QuitUnsavedDocument]) async -> Bool {
        // Two tabs of the same file cannot both be saved in place: the second write would be
        // based on bytes the first one replaced. Refuse that ambiguous case before saving
        // anything instead of choosing an order silently.
        var byURL: [String: QuitUnsavedDocument] = [:]
        for document in documents {
            let key = Self.canonicalKey(document.documentURL)
            if let first = byURL[key] {
                reporter(
                    "“\(first.title)” is open with unsaved changes in more than one tab or "
                    + "window. Save or discard one copy first, then quit. The quit was cancelled "
                    + "and nothing was saved.")
                return false
            }
            byURL[key] = document
        }

        flushWindows()

        // Preflight every document before writing anything, so a blocked form draft or an XFA
        // document cannot leave the earlier documents half-saved.
        var plans: [UUID: (document: QuitUnsavedDocument, state: AppState, plan: QuitSavePlan)] = [:]
        for document in documents {
            guard document.windowIndex >= 0, document.windowIndex < windows.count else {
                reporter("The window that owns “\(document.title)” is gone. The quit was cancelled.")
                return false
            }
            let state = windows[document.windowIndex]
            guard state.activateTabForQuit(id: document.id) else {
                reporter(
                    "“\(document.title)” could not be brought back on screen to save. The quit "
                    + "was cancelled and nothing was saved.")
                restoreActiveTabs()
                return false
            }
            let plan = state.quitSavePlan
            if case .blocked(let reason) = plan {
                reporter(reason + " The quit was cancelled and nothing was saved.")
                restoreActiveTabs()
                return false
            }
            plans[document.id] = (document, state, plan)
        }

        // Ask for every copy destination before saving anything. Cancelling a Save As panel
        // therefore aborts the whole decision with no document written and no draft discarded.
        var destinations: [UUID: URL] = [:]
        for document in documents {
            guard let entry = plans[document.id], case .copy(let suggestion) = entry.plan else {
                continue
            }
            guard let destination = saveDestination(document, suggestion) else {
                restoreActiveTabs()
                return false
            }
            guard !Self.resolvesToSameFile(destination, document.documentURL) else {
                reporter(
                    "The copy for “\(document.title)” would replace the original. The quit was "
                    + "cancelled and nothing was saved.")
                restoreActiveTabs()
                return false
            }
            destinations[document.id] = destination
        }

        // Save in prompt order. The order is the reader-visible tab order, so a failure names the
        // document they were looking at and the outcome is reproducible.
        for document in documents {
            guard let entry = plans[document.id] else { continue }
            // Activate again here: a previous save reopened its document and may have left a
            // different tab on screen, and the one save path always acts on the active document.
            guard entry.state.activateTabForQuit(id: document.id) else {
                reporter(
                    "“\(document.title)” could not be brought back on screen to save. The quit "
                    + "was cancelled; documents saved earlier in this pass stay saved.")
                restoreActiveTabs()
                return false
            }
            let outcome: QuitSaveOutcome
            switch entry.plan {
            case .inPlace:
                outcome = await entry.state.saveDocumentForQuit()
            case .copy:
                guard let destination = destinations[document.id] else {
                    reporter("No copy destination was chosen for “\(document.title)”. The quit was cancelled.")
                    restoreActiveTabs()
                    return false
                }
                outcome = await entry.state.saveDocumentCopyForQuit(to: destination)
            case .blocked(let reason):
                outcome = .failed(reason)
            }
            switch outcome {
            case .saved:
                continue
            case .needsCopy(let suggestion):
                let destination: URL
                if let prepared = destinations[document.id] {
                    destination = prepared
                } else if let chosen = saveDestination(document, suggestion) {
                    destination = chosen
                } else {
                    restoreActiveTabs()
                    return false
                }
                let copyOutcome = await entry.state.saveDocumentCopyForQuit(to: destination)
                if case .failed(let reason) = copyOutcome {
                    reporter(reason + " The quit was cancelled; documents saved earlier in this "
                        + "window stay saved.")
                    restoreActiveTabs()
                    return false
                }
            case .failed(let reason):
                reporter(reason + " The quit was cancelled; documents saved earlier in this "
                    + "window stay saved.")
                restoreActiveTabs()
                return false
            }
        }

        // Only now, with every document saved, record the handshake that keeps the next launch
        // from restoring the drafts that were just resolved.
        guard recordCleanExitMarkers(documents, resolution: .save) else {
            reporter(
                "The changes were saved, but LyraReader could not record the clean exit. "
                + "The quit was cancelled so the next launch cannot restore the old drafts; "
                + "quit again after the cache becomes writable.")
            restoreActiveTabs()
            return false
        }
        return true
    }

    // MARK: - Helpers

    /// Writes one marker per original document, all-or-nothing.
    ///
    /// If a later marker cannot be written, the ones already written are removed again: the quit
    /// is about to be cancelled, and a leftover marker would resolve drafts the reader is still
    /// allowed to keep editing. The removal is best effort; a marker that cannot be removed is
    /// still invalidated by the changes.json digest as soon as the reader edits the document.
    private func recordCleanExitMarkers(
        _ documents: [QuitUnsavedDocument],
        resolution: DocumentEditCache.CleanExitResolution
    ) -> Bool {
        var written: [QuitUnsavedDocument] = []
        for document in uniqueDocuments(documents) {
            guard DocumentEditCache.recordCleanExit(
                for: document.documentURL, resolution: resolution
            ) else {
                for previous in written {
                    DocumentEditCache.clearCleanExit(for: previous.documentURL)
                }
                return false
            }
            written.append(document)
        }
        return true
    }

    private func flushWindows() {
        var seenStates = Set<ObjectIdentifier>()
        for state in windows where seenStates.insert(ObjectIdentifier(state)).inserted {
            state.flushPendingWrites()
        }
    }

    private func restoreActiveTabs() {
        for entry in originalActiveTabs {
            guard let tabID = entry.tabID else { continue }
            _ = entry.state.activateTabForQuit(id: tabID)
        }
    }

    private func uniqueDocuments(_ documents: [QuitUnsavedDocument]) -> [QuitUnsavedDocument] {
        var seen = Set<String>()
        return documents.filter { seen.insert(Self.canonicalKey($0.documentURL)).inserted }
    }

    private static func canonicalKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func resolvesToSameFile(_ first: URL, _ second: URL) -> Bool {
        canonicalKey(first) == canonicalKey(second)
    }

    // MARK: - AppKit presentation (not used by the checks)

    public static func presentQuitPrompt(_ documents: [QuitUnsavedDocument]) -> QuitUnsavedDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = UnsavedChangesPrompt.quitTitle(count: documents.count)
        alert.informativeText = UnsavedChangesPrompt.quitMessage(documents: documents)
        alert.addButton(withTitle: UnsavedChangesPrompt.saveAll)
        alert.addButton(withTitle: UnsavedChangesPrompt.discardAll)
        alert.addButton(withTitle: UnsavedChangesPrompt.cancel)
        // Escape is Cancel: the safe answer never loses the reader's work.
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .saveAll
        case .alertSecondButtonReturn:
            return .discardAll
        default:
            return .cancel
        }
    }

    public static func presentSaveCopyPanel(
        _ document: QuitUnsavedDocument,
        _ suggestion: URL
    ) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save Changes to a Copy"
        panel.message =
            "“\(document.title)” is read-only in place. The changes are written to a copy; "
            + "the original file is not modified."
        panel.nameFieldStringValue = suggestion.lastPathComponent
        panel.directoryURL = suggestion.deletingLastPathComponent()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    public static func presentAbortAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "LyraReader did not quit"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

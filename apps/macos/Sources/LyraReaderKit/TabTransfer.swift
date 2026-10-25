import Foundation

/// A tab on its way from one reader window to another.
///
/// It is deliberately a value with only what the destination needs to continue: the file, the
/// tab's identity, its title and its reading position. Everything heavier (tiles, derived data,
/// undo history) belongs to the source window's `AppState`; the destination reopens the document
/// through the normal open path and rebuilds its own. The source gives the tab up only after the
/// destination reports that the document opened, so a failed move keeps the tab on screen.
public struct TabTransfer: Equatable, Sendable {
    /// The `AppState.OpenTab.id` of the tab in the source window. The destination reuses it, so a
    /// completion (or rollback) can find exactly the tab that moved.
    public let tabID: UUID
    public let url: URL
    public let title: String
    /// The tab's saved content offset. Applied while the destination loads the document, before
    /// the first raster is requested.
    public let scrollYPt: CGFloat
    /// The page that was current, when the source still had the document open. `nil` for an
    /// evicted tab; the destination then derives the page from the restored scroll offset.
    public let currentPage: Int?

    public init(
        tabID: UUID,
        url: URL,
        title: String,
        scrollYPt: CGFloat,
        currentPage: Int?
    ) {
        self.tabID = tabID
        self.url = url
        self.title = title
        self.scrollYPt = scrollYPt
        self.currentPage = currentPage
    }
}

/// The one commit path for a tab moved between two windows.
///
/// The order is deliberate: prepare the transfer (validates that the tab is clean), let the
/// destination open the document and insert the tab, then remove the tab from the source. Both
/// failure points are recoverable without losing the reader's document: a refused prepare changes
/// nothing, and a destination that fails to open leaves the source tab where it was. If the
/// source removal fails *after* the destination opened the document (it became dirty between the
/// two calls), the destination's new tab is closed again so the document is never open in two
/// windows.
@MainActor
public enum TabMove {
    @discardableResult
    public static func move(
        from source: AppState,
        tabAtIndex sourceIndex: Int,
        to target: AppState,
        insertionIndex: Int
    ) -> Bool {
        guard let transfer = source.prepareTabTransfer(at: sourceIndex) else { return false }
        return commit(transfer, from: source, to: target, insertionIndex: insertionIndex)
    }

    /// Completes a transfer whose `TabTransfer` was prepared earlier (a tear-off may wait for
    /// SwiftUI to make the destination window).
    @discardableResult
    public static func commit(
        _ transfer: TabTransfer,
        from source: AppState,
        to target: AppState,
        insertionIndex: Int
    ) -> Bool {
        guard target.acceptTabTransfer(transfer, atInsertionIndex: insertionIndex) else {
            source.reportTabTransferFailure(
                "Couldn’t move “\(transfer.title)” to the other window. \(source.lastError ?? "")")
            return false
        }
        // A tab that vanished with its source window is already gone; that is a completed move,
        // not a failure. A tab still present is the duplicate this method exists to prevent.
        if source.containsTab(id: transfer.tabID), !source.removeTransferredTab(id: transfer.tabID) {
            target.removeTransferredTab(id: transfer.tabID)
            source.reportTabTransferFailure(
                "“\(transfer.title)” was moved, but the old window kept it (it has unsaved changes). "
                + "The move was rolled back; save or discard the changes and try again.")
            return false
        }
        return true
    }
}

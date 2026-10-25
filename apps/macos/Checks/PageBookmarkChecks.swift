import AppKit
import Foundation
import LyraReaderKit

extension ReaderChecks {
    @MainActor static func pageBookmarkChecks(root: URL) async throws {
        _ = NSApplication.shared
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-page-bookmarks-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("pages.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"),
                                        to: fixture)
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 1000, height: 700))
        state.newTab(url: fixture)
        try await eventually("the page-bookmark fixture opens", { state.document != nil })
        require(state.document!.pageCount > 1, "the test has a page outside the current viewport")
        let originalPage = state.currentPage
        let originalScroll = state.scrollYPt
        require(state.addBookmark(onPage: 1, name: "  Experiment  "),
                "a corner action can bookmark an explicit page")
        let bookmark = state.bookmarks.last!
        require(bookmark.page == 1 && bookmark.yPt == 0 && bookmark.title == "Experiment",
                "the edge bookmark stores the clicked page top and normalized name")
        require(state.currentPage == originalPage && state.scrollYPt == originalScroll,
                "adding an edge bookmark does not move the reader")
        require(!state.addBookmark(onPage: -1) && !state.addBookmark(onPage: 100_000),
                "stale or invalid page corners cannot add out-of-range bookmarks")
        state.renameBookmark(bookmark.id, to: "Updated experiment")
        let reopened = AppState(engine: try RustEngine())
        reopened.open(url: fixture)
        require(reopened.bookmarks.first?.displayTitle == "Updated experiment"
                    && reopened.bookmarks.first?.page == 1,
                "the named page bookmark survives reopening the document")
        state.renameBookmark(bookmark.id, to: "")
        require(state.bookmarks.last?.displayTitle == "Page 2",
                "an empty name still has a readable page title in the sidebar")
        state.removeBookmark(bookmark.id)
        require(state.bookmarks.isEmpty, "removing the page bookmark clears its saved state")

        let a = PagePlacement(index: 0, topPt: 20, leftPt: 10, widthPt: 400, heightPt: 600)
        let b = PagePlacement(index: 1, topPt: 20, leftPt: 430, widthPt: 400, heightPt: 600)
        let continuation = PagePlacement(index: 0, topPt: 800, leftPt: 10,
            widthPt: 400, heightPt: 300, sourceTopPt: 300)
        let viewport = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let positions = PageBookmarkGeometry.frames(pages: [a, b, continuation], width: 1000,
            contentWidth: 850, zoom: 1, scroll: 0, viewport: viewport)
        require(positions.count == 2 && positions[0]?.minX == 423 && positions[1]?.minX == 843,
                "facing pages receive separate flags at their own right edges")
        require(positions[0]?.minY == 14,
                "the bookmark flag overlaps the paper edge by a small fixed amount")
        let zoomed = PageBookmarkGeometry.frames(pages: [a], width: 1000, contentWidth: 850,
            zoom: 2, scroll: 0, viewport: viewport)
        require(zoomed[0]?.minX == 758 && zoomed[0]?.minY == 34
                    && zoomed[0]?.size == positions[0]?.size,
                "zoom moves the page corner while retaining a usable control size")
        let torn = PageBookmarkGeometry.frames(pages: [continuation], width: 1000,
            contentWidth: 850, zoom: 1, scroll: 500, viewport: viewport)
        require(torn.isEmpty, "the lower half of a torn page does not get a duplicate bookmark")

        let flag = PageBookmarkFlagView(frame: CGRect(x: 100, y: 100, width: 60, height: 56))
        // A flag's immediate parent is the y-down overlay, not the y-up Metal canvas.
        let container = PageBookmarkCanvasHost(frame: viewport)
        container.addSubview(flag)
        let iconPoint = CGPoint(x: 140, y: 110)
        require(flag.hitTest(iconPoint) == nil, "an idle unbookmarked corner passes page input through")
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        flag.mouseEntered(with: event)
        require(flag.hitTest(iconPoint) is NSButton, "hover reveals a clickable bookmark flag")
        require(flag.hitTest(CGPoint(x: 110, y: 110)) == nil,
                "the rest of the hover area never blocks PDF selection")
        flag.mouseExited(with: event)
        require(flag.hitTest(iconPoint) == nil, "the uncommitted hover hint disappears on exit")
        flag.bookmarked = true
        require(flag.hitTest(iconPoint) is NSButton, "an existing bookmark remains visible after hover ends")

        let metalCoordinates = NSView(frame: viewport)
        let host = PageBookmarkCanvasHost(frame: viewport)
        metalCoordinates.addSubview(host)
        _ = host.configure(state: state)
        host.sync(size: viewport.size, viewport: viewport, scroll: 0, zoom: 1,
                  contentWidth: 850, pages: [a])
        host.updateHover(at: CGPoint(x: 463, y: 24))
        require(host.hitTest(CGPoint(x: 463, y: 676)) is NSButton,
                "real mouse hit testing converts the y-up canvas into the y-down overlay")
        require(host.hitTest(CGPoint(x: 300, y: 676)) == nil,
                "the transparent overlay passes unrelated canvas clicks through")
        let control = ContinuitySignatureRequestor(controller: FillSignCommandController(state: state))
        require(control.intrinsicContentSize.height == 32,
                "the device signature method matches the other 32-point method buttons")
    }
}

import AppKit
import Foundation
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func contentScrollRecoveryChecks(root: URL) async throws {
        let engine = ContentScrollEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 800, height: 600))
        require(state.open(url: root.appendingPathComponent("tests/fixtures/text-page.pdf")),
                "content scroll fixture opens")
        state.contentEditEnabled = true
        let first = Task { @MainActor in await state.reloadContentObjects() }
        try await eventually("first inspection is in flight", { engine.waiting[0] != nil })
        state.gotoPage(1)
        engine.complete(0)
        await first.value
        require(!state.contentEditLoading && state.contentEditPage == nil,
                "a result made stale by scrolling releases its busy flag")

        let second = Task { @MainActor in await state.reloadContentObjects() }
        try await eventually("second inspection starts", { engine.waiting[1] != nil })
        state.gotoPage(2)
        let third = Task { @MainActor in await state.reloadContentObjects() }
        try await eventually("latest page can load while an older request remains", { engine.waiting[2] != nil })
        engine.complete(1)
        await second.value
        require(state.contentEditLoading, "an old completion cannot clear a newer request's busy flag")
        engine.complete(2)
        await third.value
        require(!state.contentEditLoading && state.contentEditPage?.page == 2,
                "editing recovers on the latest page without reopening")

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = ContentEditorView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.state = state
        window.contentView = view
        defer { window.contentView = nil; window.orderOut(nil) }
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 3, y: 3),
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        state.contentEditSelection = nil
        view.mouseMoved(with: event)
        require(view.hoveredContentID == nil && !view.showsMoveCursor,
                "empty space with no selection never becomes a move hand")
        view.mouseExited(with: event)
        require(!view.showsMoveCursor, "leaving the paper clears move hover")
        try await contentDragCancellationChecks(root: root)

    }
}

extension ReaderChecks {
    @MainActor private static func contentDragCancellationChecks(root: URL) async throws {
        for cancelByPage in [false, true] {
            let engine = ContentScrollEngine()
            let state = AppState(engine: engine)
            state.setViewportSize(CGSize(width: 800, height: 600))
            state.newTab(url: root.appendingPathComponent("tests/fixtures/text-page.pdf"))
            state.contentEditEnabled = true
            let item = PDFContentItem(id: "moving-text", kind: "text",
                bounds: PDFContentBox(CGRect(x: 100, y: 100, width: 200, height: 30)),
                text: "Moving text", font: "Helvetica", size: 12, colour: [0, 0, 0, 255],
                can_edit_text: true, reason: nil, paths: [[0]], link_page: nil, link_uri: nil)
            let load = Task { @MainActor in await state.reloadContentObjects() }
            try await eventually("the controlled drag page begins loading", { engine.waiting[0] != nil })
            engine.complete(0, items: [item])
            await load.value
            let view = ContentEditorView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.state = state
            defer { window.contentView = nil; window.orderOut(nil) }
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            }
            let source = state.viewRect(local: item.bounds.rect, onPage: 0)!
            let point = CGPoint(x: source.midX, y: source.midY)
            state.contentEditSelection = item.id
            view.mouseDown(with: mouse(.leftMouseDown, point))
            view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: point.x + 30, y: point.y + 15)))
            try await eventually("one preview request starts for the held drag", { engine.previewWaiting != nil })
            for step in 1...12 {
                view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: point.x + CGFloat(step * 4), y: point.y + 15)))
            }
            require(engine.previewRequests == 1, "pointer events reuse one preview request")
            if cancelByPage {
                state.gotoPage(1)
                view.synchronizePointer()
            } else {
                view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
            }
            view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: point.x + 48, y: point.y + 15)))
            require(!state.contentTextEditing, "releasing a cancelled drag cannot start a text editor")
            engine.completePreview()
            // Let the resumed main-actor task consume the deliberately late result.
            try await Task.sleep(for: .milliseconds(75))
            require(!state.canvasPages.contains { $0.placement.index == PlacementIndex.contentDragForeground },
                    "a late preview cannot resurrect a drag after \(cancelByPage ? "page navigation" : "Escape")")
            require(state.pageEditPendingOperations.isEmpty, "cancelling a preview stages no PDF edit")
        }
    }
}

/// Controlled responses model non-cancellable work already executing on the engine queue.
@MainActor private final class ContentScrollEngine: PDFEngine {
    let version = "content scroll regression"
    var waiting: [Int: CheckedContinuation<PDFContentPage, Error>] = [:]
    var previewWaiting: CheckedContinuation<ContentDragPreview, Error>?
    var previewBounds = CGRect.zero
    var previewRequests = 0
    func contentDragPreview(page: Int, target: String, revision: String,
                            bounds: CGRect, scale: CGFloat) async throws -> ContentDragPreview {
        previewRequests += 1
        previewBounds = bounds
        return try await withCheckedThrowingContinuation { previewWaiting = $0 }
    }
    func completePreview() {
        let image = PageImage(pixelWidth: 1, pixelHeight: 1, pointSize: previewBounds.size,
                              bgra: Data([0, 0, 0, 255]), generation: 1)
        previewWaiting?.resume(returning: ContentDragPreview(bounds: previewBounds, background: image, foreground: image))
        previewWaiting = nil
    }
    func contentObjects(page: Int) async throws -> PDFContentPage {
        try await withCheckedThrowingContinuation { waiting[page] = $0 }
    }
    func complete(_ page: Int, items: [PDFContentItem] = []) {
        waiting.removeValue(forKey: page)?.resume(returning:
            PDFContentPage(revision: "revision", page: page, items: items))
    }
    func openDocument(at url: URL) throws -> LoadedDocument {
        LoadedDocument(title: "Scroll", pageCount: 3, url: url,
                       firstPageSize: CGSize(width: 600, height: 1000))
    }
    func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage { throw CancellationError() }
    func rasterizeRegion(page: Int, scale: CGFloat, xPt: CGFloat, yPt: CGFloat,
                         widthPt: CGFloat, heightPt: CGFloat, transparentBackground: Bool) async throws -> PageImage {
        throw CancellationError()
    }
    func rasterizeTile(page: Int, lod: UInt8, tileX: Int, tileY: Int, tileSize: Int) async throws -> TileImage { throw CancellationError() }
    func textPage(_ page: Int) async throws -> TextPage { throw CancellationError() }
    func links(_ page: Int) async throws -> [DocumentLink] { [] }
    func citations(_ page: Int) async throws -> [Citation] { [] }
    func captionMentions(page: Int) async throws -> [CaptionMention] { [] }
    func annotations() async throws -> [DocumentAnnotation] { [] }
    func figures() async throws -> [Figure] { [] }
    func references() async throws -> [Reference] { [] }
    func resolveCitations(labels: [String], page: Int) async throws -> [Reference] { [] }
    func outline() async throws -> [OutlineEntry] { [] }
    func metadata() async throws -> DocumentMetadata { .empty }
    func generateBibtex(_ draft: MetadataDraft) -> String { draft.bibtex }
    func search(_ pattern: String, limit: Int) async throws -> [SearchHit] { [] }
    func contentHeightPt(gapPt: CGFloat) -> CGFloat { 3036 }
    func contentWidthPt(gapPt: CGFloat) -> CGFloat { 600 }
    func visiblePages(scrollYPt: CGFloat, viewportHeightPt: CGFloat, gapPt: CGFloat, marginPt: CGFloat) -> [PagePlacement] {
        (0..<3).map { PagePlacement(index: $0, topPt: CGFloat($0) * (1000 + gapPt),
                                  leftPt: 0, widthPt: 600, heightPt: 1000) }
    }
    func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat) -> Int {
        min(2, max(0, Int(scrollYPt / (1000 + gapPt))))
    }
    func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat { CGFloat(index) * (1000 + gapPt) }
}

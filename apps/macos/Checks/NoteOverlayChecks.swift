import AppKit
import LyraReaderKit
import SwiftUI

extension ReaderChecks {
    @MainActor static func noteOverlayChecks(url: URL) async throws {
        _ = NSApplication.shared
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.sidebarVisible = false
        let host = NSHostingView(rootView: ReaderWindow(
            state: state, opener: DocumentOpenCoordinator(state: state),
            previewPanels: ReferencePreviewPanelController()))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func firstCanvas(in view: NSView) -> MetalCanvasView? {
            if let canvas = view as? MetalCanvasView { return canvas }
            return view.subviews.lazy.compactMap { firstCanvas(in: $0) }.first
        }
        try await eventually("the note reader canvas attaches",
                             { firstCanvas(in: host)?.hasAttachedSurface == true })
        try await eventually("the note canvas viewport reaches the reader",
                             { state.canvasViewportWidthPt > 0 })
        // Pin the CI runner's 38 ppi virtual-display geometry (factor 0.5278) after the canvas
        // reported its real screen. A developer display is 1.5× and would otherwise never open
        // the note on the fit path this check must keep independent of the PDF position.
        state.setDisplayCalibration(DisplayCalibration(factor: 0.5278))
        state.open(url: url)
        try await eventually("note fixture is loaded in the reader", { !state.documentNotes.isEmpty })
        // At this calibration the page is smaller than the canvas, so the reader's fit path is
        // the one that runs on CI. Fit explicitly so the scenario is the same on every display:
        // a fitted first page must keep `scrollYPt` non-negative, and scrolling the note paper
        // must not move that PDF offset at all.
        state.zoomFitPage()
        require(state.zoomPercent > 100,
                "the low-density note fixture takes the Fit Page path (\(state.zoomPercent)%)")
        require(state.scrollYPt >= 0,
                "Fit Page keeps the offset non-negative on the note page")
        guard let note = state.documentNotes.first, let box = note.boxes.first,
              let placement = state.canvasPageFrames.first(where: { $0.index == note.page })
                ?? engine.visiblePages(scrollYPt: state.scrollYPt, viewportHeightPt: 700,
                                       gapPt: state.pageGapPt, marginPt: 0)
                    .first(where: { $0.index == note.page })
        else { fatalError("FAIL: the note has a visible placement") }
        let point = CGPoint(x: placement.leftPt + box.xPt + box.widthPt / 2,
                            y: placement.topPt + box.yPt + box.heightPt / 2)
        state.endPointerInteraction(at: point, wasClick: true)
        require(state.openDocumentNote?.id == note.id && !state.sidebarVisible,
                "clicking the glyph opens its paper without shifting the canvas")
        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.string == note.contents { return text }
            return view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        try await eventually("the complete note is in a native scrollable text view", {
            host.layoutSubtreeIfNeeded()
            return textView(in: host) != nil
        })
        guard let text = textView(in: host), let scroll = text.enclosingScrollView else {
            fatalError("FAIL: the paper has a scroll view")
        }
        require(scroll.hasVerticalScroller && !scroll.autohidesScrollers,
                "the paper provides a visible vertical scrollbar")
        let paperSize = scroll.frame.size
        text.string = String(repeating: "A long note wraps and scrolls.\n", count: 200)
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        text.sizeToFit()
        require(text.frame.height > scroll.contentSize.height && scroll.frame.size == paperSize,
                "long text overflows inside the fixed paper")
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 150))
        scroll.reflectScrolledClipView(scroll.contentView)
        require(scroll.contentView.bounds.minY > 0 && state.scrollYPt == 0,
                "scrolling the note changes its text position without moving the PDF")
        let viewport = CGSize(width: 1000, height: 700)
        for anchor in [CGRect(x: 40, y: 80, width: 24, height: 24),
                       CGRect(x: 970, y: 680, width: 24, height: 24)] {
            let frame = DocumentNoteLayout.frame(anchor: anchor, viewport: viewport)
            require(frame.size == DocumentNoteLayout.size
                    && CGRect(origin: .zero, size: viewport).contains(frame),
                    "the paper keeps its size and stays within the canvas")
        }
        state.endPointerInteraction(at: CGPoint(x: -20, y: -20), wasClick: true)
        require(state.openDocumentNote == nil, "clicking away dismisses the paper")
        state.openDocumentNote(at: point)
        state.open(url: url)
        require(state.openDocumentNote == nil, "a document switch dismisses the paper")
    }
}

import AppKit
import SwiftUI
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func annotationThreadInteractionChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-review-threads-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("threads.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/adopted-note-thread.pdf"), to: file)
        let original = try Data(contentsOf: file)
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 800, height: 500))
        require(state.open(url: file), "the adopted-note thread fixture opens")
        try await eventually("the thread annotations load", { state.documentAnnotations.count == 3 })
        let parentID = "nm:thread-note", replyID = "nm:thread-status"
        func verifyThread(_ state: AppState, adopted: Bool) {
            let page = state.annotationSidebarPages.first { $0.id == 1 }!
            require(page.rows.count == 1 && page.annotationCount == 3,
                    "the parent and its two replies form one sidebar item on the parent's page")
            guard case .thread(let parent, let replies) = page.rows[0] else {
                fatalError("FAIL: the sidebar contains an actual nested thread")
            }
            require(replies.map(\.depth) == [1, 2] && replies.allSatisfy { $0.orphanReason == nil },
                    "status and cross-page replies retain their nesting without a missing-parent warning")
            if adopted {
                guard case .own(let own) = parent else { fatalError("FAIL: the editable parent remains the thread root") }
                require(own.fileIdentity == parentID && page.rows[0].contains(.own(own.id)),
                        "the edited parent keeps its original PDF thread identity")
            } else {
                require(parent.contains(.document(parentID)), "the original PDF parent owns its replies")
            }
        }
        verifyThread(state, adopted: false)
        state.activateDocumentAnnotationRow(parentID)
        let own = state.annotations.first { $0.fileIdentity == parentID }!
        require(state.annotationSidebarSelected(.own(own.id)), "the selected editable parent is highlighted in the sidebar")
        verifyThread(state, adopted: true)
        require(state.commitTextEditing(), "the adopted note editor closes cleanly")
        state.undo()
        verifyThread(state, adopted: false)
        state.redo()
        verifyThread(state, adopted: true)
        state.gotoPage(2)
        state.activateDocumentAnnotationRow(replyID)
        require(state.annotationSidebarSelected(.document(replyID)) && !state.annotationSidebarSelected(.own(own.id)),
                "clicking a reply highlights the reply rather than a stale parent selection")
        require(state.markSelectionRefusalNotice == nil && state.selectedAnnotationID == nil && state.editingAnnotationID == nil,
                "reading a reply shows no edit-refusal banner and does not arm its parent for editing")
        let box = own.shapeRect!
        let anchor = state.anchorViewRect(page: own.page, region: box)!
        require(anchor.midY >= 0 && anchor.midY < 500,
                "the reply reveals the parent's exact page position instead of its placeholder box")
        let reopened = AppState(engine: try RustEngine())
        reopened.setViewportSize(CGSize(width: 800, height: 500))
        require(reopened.open(url: file), "the adopted thread reopens from its existing recovery data")
        try await eventually("the reopened thread loads", { reopened.documentAnnotations.count == 2 })
        verifyThread(reopened, adopted: true)

        let markupFile = scratch.appendingPathComponent("markup.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/annotated-replies.pdf"), to: markupFile)
        let markup = AppState(engine: try RustEngine())
        markup.setViewportSize(CGSize(width: 800, height: 500))
        require(markup.open(url: markupFile), "the text-markup reply fixture opens")
        try await eventually("the markup thread loads", { markup.documentAnnotations.count == 11 })
        require(markup.adoptDocumentAnnotation("nm:parent-highlight") != nil, "a highlighted parent enters the editable model")
        markup.gotoPage(1)
        markup.activateDocumentAnnotationRow("nm:reply-cross-page")
        let marked = markup.annotations.first { $0.fileIdentity == "nm:parent-highlight" }!.fileQuads![0]
        let markAnchor = markup.anchorViewRect(page: 0, region: CGRect(x: marked.x, y: marked.y, width: marked.width, height: marked.height))!
        require(markAnchor.midY >= 0 && markAnchor.midY < 500 && markup.markSelectionRefusalNotice == nil,
                "an adopted text-markup parent is located by its PDF quads rather than a synthetic character range")

        // Real canvas events cover both the read-only paper and the adopted sticky-note editor.
        let reader = AppState(engine: try RustEngine())
        let second = scratch.appendingPathComponent("clicks.pdf")
        try FileManager.default.copyItem(at: file, to: second)
        require(reader.open(url: second), "the click-toggle fixture opens")
        reader.sidebarVisible = false; reader.rightPanelVisible = false
        let host = NSHostingView(rootView: ReaderWindow(state: reader, opener: DocumentOpenCoordinator(state: reader)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 750),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        func findCanvas(_ view: NSView) -> MetalCanvasView? {
            if let canvas = view as? MetalCanvasView { return canvas }
            return view.subviews.lazy.compactMap { findCanvas($0) }.first
        }
        try await eventually("the reader hosts its canvas and note", {
            host.layoutSubtreeIfNeeded()
            return findCanvas(host) != nil && reader.documentAnnotations.count == 3
        })
        reader.jump(toDocumentAnnotation: reader.documentAnnotations.first { $0.id == parentID }!)
        let canvas = findCanvas(host)!
        func clickNote() async throws {
            try await eventually("the note's click geometry is current", {
                host.layoutSubtreeIfNeeded()
                return abs(canvas.scrollYPt - reader.scrollYPt) < 0.01 && abs(canvas.zoom - reader.zoomFactor) < 0.001
                    && canvas.annotationMarks.map(\.id) == reader.canvasAnnotationMarks.map(\.id)
            })
            let anchor = reader.anchorViewRect(page: 1, region: box)!
            let local = CGPoint(x: anchor.midX, y: canvas.bounds.height - anchor.midY)
            require(canvas.bounds.contains(local), "the note is visible inside the actual canvas viewport")
            let location = canvas.convert(local, to: nil)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
            }
        }
        try await clickNote()
        require(reader.openDocumentNoteID == parentID, "one click opens the PDF note")
        let fraction = reader.scrollFraction
        reader.jump(to: AppState.Annotation(id: UUID(), page: 1, start: 0, end: 2,
            color: AppState.highlightPalette[0].color, note: "", createdAt: Date()))
        reader.scroll(toFraction: fraction)
        try await clickNote()
        require(reader.openDocumentNoteID == nil && reader.selection == nil,
                "a second click closes the same PDF note and clears stale PDF selection")
        reader.activateDocumentAnnotationRow(parentID)
        let edited = reader.annotations.first { $0.fileIdentity == parentID }!
        reader.updateEditingText("Draft preserved by the second click")
        try await clickNote()
        require(reader.editingAnnotationID == nil, "a second click closes an adopted sticky-note editor")
        try await clickNote()
        require(reader.editingAnnotationID == edited.id && reader.editingAnnotation?.note == "Draft preserved by the second click",
                "another click reopens the same sticky note with its draft intact")
        require(reader.commitTextEditing(), "the final note draft commits")
        let final = try Data(contentsOf: file)
        require(final == original, "thread presentation and navigation leave the source PDF unchanged")

        if let path = ProcessInfo.processInfo.environment["LYRA_READER_THREAD_SAMPLE"] {
            let sample = scratch.appendingPathComponent("private-review.pdf")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: sample)
            let sampleState = AppState(engine: try RustEngine())
            sampleState.setViewportSize(CGSize(width: 1000, height: 600))
            require(sampleState.open(url: sample), "the private review copy opens")
            try await eventually("the private review annotations load", { !sampleState.documentAnnotations.isEmpty })
            let reply = sampleState.documentAnnotations.first { $0.page == 4 && $0.isReply }!
            let parent = sampleState.documentAnnotations.first { $0.id == reply.parentID }!
            sampleState.activateDocumentAnnotationRow(parent.id)
            let adopted = sampleState.annotations.first { $0.fileIdentity == parent.id }!
            require(sampleState.annotationSidebarSelected(.own(adopted.id)), "the private review parent row highlights after adoption")
            let page = sampleState.annotationSidebarPages.first { $0.id == 4 }!
            require(page.rows.count == 1 && page.rows[0].contains(.document(reply.id)), "the private review status reply is nested with its note")
            sampleState.gotoPage(0)
            sampleState.activateDocumentAnnotationRow(reply.id)
            let note = sampleState.anchorViewRect(page: 4, region: adopted.shapeRect!)!
            require(note.midY >= 0 && note.midY < 600 && sampleState.markSelectionRefusalNotice == nil,
                    "the private reply navigates to its note without a warning banner")
        }
    }
}

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
        let writesBeforeReading = state.annotationWriteCount
        state.activateDocumentAnnotationRow(parentID)
        require(state.openDocumentNoteID == parentID && state.editingAnnotationID == nil
                && state.annotations.isEmpty && !state.hasUnsavedDocumentChanges
                && state.annotationWriteCount == writesBeforeReading,
                "sidebar note reading neither adopts nor dirties the PDF")
        state.editOpenNote()
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
        require(reader.openDocumentNoteID == parentID && reader.editingAnnotationID == nil,
                "sidebar and canvas both open file notes for reading")
        reader.editOpenNote()
        let edited = reader.annotations.first { $0.fileIdentity == parentID }!
        reader.updateEditingText("Draft preserved by the second click")
        try await clickNote()
        require(reader.editingAnnotationID == nil, "a second click closes an adopted sticky-note editor")
        try await clickNote()
        require(reader.openOwnNoteID == edited.id && reader.editingAnnotationID == nil
                && reader.openOwnNote?.note == "Draft preserved by the second click",
                "another icon click reopens the adopted note for reading with its draft intact")
        require(reader.commitTextEditing(), "the final note draft commits")
        require(reader.placeStickyNote(page: 1, at: CGPoint(x: 200, y: 250)), "a second note is placed")
        let secondID = reader.editingAnnotationID!
        let secondText = "Second note — different location and contents.\n"
            + (1...24).map { "Line \($0): 独立的便签内容与滚动区域。" }.joined(separator: "\n")
        reader.updateEditingText(secondText)
        require(reader.commitTextEditing(), "the second note draft commits")
        func textView(in view: NSView, matching text: String, editable: Bool) -> NSTextView? {
            if let body = view as? NSTextView, body.isEditable == editable, body.string == text { return body }
            return view.subviews.lazy.compactMap { textView(in: $0, matching: text, editable: editable) }.first
        }
        let firstText = "Draft preserved by the second click"
        let savedNotes = reader.annotations
        let writes = reader.annotationWriteCount
        for id in [edited.id, secondID, edited.id, secondID] {
            reader.openPassageNote(.own(id))
            let expected = id == edited.id ? firstText : secondText
            try await eventually("switching sidebar notes replaces the live paper text", {
                host.layoutSubtreeIfNeeded()
                return reader.openOwnNoteID == id && reader.editingAnnotationID == nil
                    && textView(in: host, matching: expected, editable: false) != nil
            })
        }
        require(reader.annotations == savedNotes && reader.annotationWriteCount == writes,
                "repeated reading and switching never mutates or writes note contents")
        let body = textView(in: host, matching: secondText, editable: false)!
        let scroller = body.enclosingScrollView?.verticalScroller as? LyraReaderSidebarScroller
        require(scroller?.trackColor == LyraReaderTheme.noteBgColor,
                "the note's legacy scrollbar track uses the note paper color")
        if let directory = ProcessInfo.processInfo.environment["LYRA_READER_CHECK_SNAPSHOT_DIR"],
           let scroll = body.enclosingScrollView {
            // Capture after the paper's reveal, rather than a partially masked transition.
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)!
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: folder.appendingPathComponent("note-reading-scrollbar.png"))
        }
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: body.convert(CGPoint(x: 8, y: 8), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        body.mouseDown(with: click)
        try await eventually("a paper body click opens the current note editor", {
            reader.editingAnnotationID == secondID && textView(in: host, matching: secondText, editable: true) != nil
        })
        try await eventually("the editor scrollbar track also uses the note paper color", {
            guard let editor = textView(in: host, matching: secondText, editable: true),
                  let scroller = editor.enclosingScrollView?.verticalScroller as? LyraReaderSidebarScroller
            else { return false }
            return scroller.trackColor == LyraReaderTheme.noteBgColor
        })
        reader.beginEditingAnnotation(edited.id)
        try await eventually("switching directly between editors loads the first note", {
            textView(in: host, matching: firstText, editable: true) != nil
        })
        reader.beginEditingAnnotation(secondID)
        try await eventually("switching directly back loads the second note", {
            textView(in: host, matching: secondText, editable: true) != nil
        })
        require(reader.annotations == savedNotes && reader.annotationWriteCount == writes,
                "editor initialization cannot copy an earlier note into a later note")
        require(reader.commitTextEditing(), "the unmodified note editor closes")
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
            require(sampleState.openDocumentNoteID == parent.id && !sampleState.hasUnsavedDocumentChanges,
                    "the private review note first opens for reading")
            sampleState.editOpenNote()
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

import AppKit
import LyraReaderKit
import SwiftUI
import Foundation
import PDFKit

extension ReaderChecks {
    /// The multiline half of the form feature: an AcroForm text field with `/Ff` bit 13 is
    /// edited as a multi-line surface (Enter is a newline, Command-Return commits, the widget
    /// scrolls inside its fixed rectangle), its `/V` keeps the line break, and the generated
    /// appearance paints two lines that PDFKit also renders as two rows.
    ///
    /// The single-line half is checked in the same session: Return still commits and moves on,
    /// and neither the draft nor `/V` can acquire a newline.
    @MainActor
    static func multilineFormChecks(root: URL) async throws {
        let fixture = root.appendingPathComponent("tests/fixtures/form-fields.pdf")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-multiline-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("multiline-source.pdf")
        try FileManager.default.copyItem(at: fixture, to: source)

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 1000, height: 900))
        state.newTab(url: source)
        try await eventually("the multiline fixture's form loads", {
            state.formLoadCompleted && !state.formLoading
        })
        let fields = state.formInfo.fields
        guard let notes = fields.first(where: { $0.name == "notes" }),
              let fullName = fields.first(where: { $0.name == "fullName" }),
              let email = fields.first(where: { $0.name == "email" }) else {
            require(false, "the form fixture carries the notes, fullName and email fields")
            return
        }
        require(notes.multiline, "the notes field is the multiline field")

        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1000, height: 860),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        let host = NSHostingView(rootView: ReaderWindow(
            state: state,
            opener: DocumentOpenCoordinator(state: state),
            previewPanels: ReferencePreviewPanelController()))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        // The focus assertions below need this process to be the active application: AppKit
        // only makes a window's field editor first responder while the app is active, and a
        // full-suite run may leave another app frontmost. Activation is what every other
        // window-hosting check does (e.g. canvas-commit, frame-scheduling); without it the
        // editor check depends on which window happened to be key before.
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKey()
        state.gotoPage(notes.page + 1)

        // ── The multiline editor: scrolls, wraps, Enter is a newline, ⌘Return commits ───────
        state.focusFormField(notes.id)
        try await eventually("the multiline field uses the native scrolled editor", {
            host.layoutSubtreeIfNeeded()
            return textView(in: host, label: notes.displayName) != nil
        })
        guard let editor = textView(in: host, label: notes.displayName) else {
            require(false, "the multiline editor is a text view labelled for its field")
            return
        }
        guard let scrollView = editor.enclosingScrollView else {
            require(false, "the multiline editor is bounded by a scroll view inside the widget")
            return
        }
        require(scrollView.hasVerticalScroller && scrollView.autohidesScrollers,
                "a value taller than the widget scrolls vertically instead of growing the widget")
        require(editor.isVerticallyResizable && !editor.isHorizontallyResizable,
                "the editor grows in height and wraps at the widget width")
        require(editor.textContainer?.widthTracksTextView == true,
                "the text container tracks the widget width")
        try await eventually("the multiline editor takes keyboard focus", {
            window.firstResponder === editor
        })

        editor.insertText("First line",
                          replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        let returnEvent = keyEvent(36, "\r", windowNumber: window.windowNumber)
        editor.keyDown(with: returnEvent)
        editor.insertText("Second line", replacementRange: editor.selectedRange())
        try await eventually("Enter inserts a newline in a multiline field", {
            state.formCurrentText(notes) == "First line\nSecond line"
                && state.formFocusedFieldID == notes.id
        })

        // Overflow: the widget rectangle does not move, the text view scrolls inside it.
        let overflowText = Array(repeating: "overflow line", count: 24).joined(separator: "\n")
        state.updateFormText(notes.id, text: overflowText)
        try await eventually("a long multiline value becomes taller than its widget", {
            host.layoutSubtreeIfNeeded()
            guard let current = textView(in: host, label: notes.displayName),
                  let currentScroll = current.enclosingScrollView else { return false }
            return current.frame.height > currentScroll.contentSize.height + 20
        })
        state.updateFormText(notes.id, text: "First line\nSecond line")
        try await eventually("the two-line value comes back", {
            state.formCurrentText(notes) == "First line\nSecond line"
        })

        let cmdReturn = keyEvent(36, "\r", modifiers: .command,
                                 windowNumber: window.windowNumber)
        editor.keyDown(with: cmdReturn)
        try await eventually("Command-Return commits the multiline field", {
            state.formFocusedFieldID == nil
        })
        require(state.formCurrentText(notes) == "First line\nSecond line",
                "committing keeps the typed lines in the reader's draft")

        // A click outside the widget ends editing; the draft is already the committed value.
        state.focusFormField(notes.id)
        try await eventually("the multiline editor comes back for the click-away check", {
            host.layoutSubtreeIfNeeded()
            guard let current = textView(in: host, label: notes.displayName) else { return false }
            return window.firstResponder === current
        })
        state.beginSelection(at: CGPoint(x: 8, y: 8))
        require(state.formFocusedFieldID == nil,
                "a click on the page outside the field commits the multiline edit")
        require(state.formCurrentText(notes) == "First line\nSecond line",
                "the click-away keeps the committed draft")

        // ── The single-line editor: Return commits and can never carry a newline ───────────
        // Re-activate here: the multiline part above ends with a click that can move key status
        // in a headless full-suite run, and the field editor below needs our app active.
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        state.gotoPage(fullName.page + 1)
        state.focusFormField(fullName.id)
        try await eventually("the single-line field uses the single-line editor", {
            host.layoutSubtreeIfNeeded()
            return textField(in: host, label: fullName.displayName) != nil
        })
        guard let nameField = textField(in: host, label: fullName.displayName) else {
            require(false, "the single-line field has an editor")
            return
        }
        try await eventually("the single-line editor takes keyboard focus", {
            nameField.currentEditor() != nil
                && window.firstResponder === nameField.currentEditor()
        })
        guard let fieldEditor = nameField.currentEditor() as? NSTextView else {
            require(false, "the single-line field has a field editor")
            return
        }
        fieldEditor.insertText("Single line",
                               replacementRange: NSRange(location: 0,
                                                         length: (fieldEditor.string as NSString).length))
        try await eventually("typing updates the single-line draft", {
            state.formCurrentText(fullName) == "Single line"
        })
        fieldEditor.keyDown(with: returnEvent)
        try await eventually("Return commits a single-line field and moves to the next field", {
            state.formFocusedFieldID == email.id
        })
        require(!state.formCurrentText(fullName).contains("\n"),
                "the single-line draft never holds a newline")
        // Even a paste the platform normally prevents is normalised at the model boundary.
        state.updateFormText(fullName.id, text: "Single line\ncontinued")
        require(state.formCurrentText(fullName) == "Single line continued"
                    && !state.formCurrentText(fullName).contains("\n"),
                "a newline reaching a single-line draft becomes a space")

        // ── Save: /V keeps the newline, the appearance and PDFKit render two rows ─────────
        let filled = scratch.appendingPathComponent("multiline-filled.pdf")
        let saved = await state.saveFilledForm(to: filled)
        require(saved, "the two-line draft saves into a filled copy")
        let sourceBytes = try Data(contentsOf: source)
        let savedBytes = try Data(contentsOf: filled)
        require(savedBytes.starts(with: sourceBytes),
                "the two-line save keeps the source bytes as the output's prefix")
        require(savedBytes.range(of: Data("(First line\nSecond line)".utf8)) != nil,
                "the raw /V text string carries an LF between the two lines")
        let appearanceLines = appearanceTextLineCount(url: filled)
        require(appearanceLines == 2,
                "the generated appearance stream shows two text lines (\(appearanceLines) Tj)")

        let reopenedEngine = try RustEngine()
        _ = try reopenedEngine.openDocument(at: filled)
        let after = try await reopenedEngine.formInfo()
        guard let savedNotes = after.fields.first(where: { $0.name == "notes" }),
              let savedName = after.fields.first(where: { $0.name == "fullName" }) else {
            require(false, "the saved copy still reports the notes and fullName fields")
            return
        }
        require(savedNotes.value == "First line\nSecond line",
                "the saved /V reads back as two lines joined by a newline")
        require((savedName.value ?? "").contains("\n") == false
                    && savedName.value == "Single line continued",
                "the saved single-line /V carries no newline")

        // Reopening in the reader shows both lines, not one line with the second hidden.
        let reopenedState = AppState(engine: try RustEngine())
        reopenedState.setViewportSize(CGSize(width: 1000, height: 900))
        reopenedState.newTab(url: filled)
        try await eventually("the saved two-line value reopens in the reader", {
            reopenedState.formLoadCompleted && !reopenedState.formLoading
        })
        if let reopenedNotes = reopenedState.formField(id: savedNotes.id) {
            require(reopenedState.formCurrentText(reopenedNotes) == "First line\nSecond line",
                    "reopening the saved copy shows both lines")
        } else {
            require(false, "the reopened copy has the notes field")
        }

        let pdfKit = try pdfKitTextValues(url: filled, pageIndex: notes.page)
        require(pdfKit.count == 1, "PDFKit sees one text widget on the notes page")
        if let value = pdfKit.first?.value {
            require(value.contains("First line") && value.contains("Second line"),
                    "PDFKit reads both lines from the saved widget")
            require(value.contains("\n") || value.contains("\r"),
                    "PDFKit reads the two lines as a line break, not a single run")
        } else {
            require(false, "PDFKit reads a value for the saved notes widget")
        }

        let scale: CGFloat = 2
        let notesBox = CGRect(x: savedNotes.xPt + 5, y: savedNotes.yPt + 3,
                              width: savedNotes.widthPt - 10, height: savedNotes.heightPt - 6)
        let notesBands = try inkRowBands(url: filled, pageIndex: notes.page,
                                         viewSpaceRect: notesBox, scale: scale)
        require(notesBands.count == 2,
                "PDFKit's render has two text rows inside the widget (\(notesBands.count) rows)")
        require(notesBands.allSatisfy { band in
            CGFloat(band.lowerBound) / scale >= notesBox.minY - 1
                && CGFloat(band.upperBound) / scale <= notesBox.maxY + 1
        }, "both rendered rows sit inside the widget rectangle")
        let nameBox = CGRect(x: savedName.xPt + 5, y: savedName.yPt + 3,
                             width: savedName.widthPt - 10, height: savedName.heightPt - 6)
        let nameBands = try inkRowBands(url: filled, pageIndex: savedName.page,
                                        viewSpaceRect: nameBox, scale: scale)
        require(nameBands.count == 1,
                "PDFKit's render has one row in the single-line field (\(nameBands.count) rows)")

        state.undo()
        require(state.formCurrentText(notes) == "First line\nSecond line",
                "form drafts are not an undoable page edit and the save keeps them")
    }

    // MARK: - Hosted-view helpers

    @MainActor
    private static func textView(in view: NSView, label: String) -> NSTextView? {
        if let text = view as? NSTextView, text.accessibilityLabel() == label {
            return text
        }
        for subview in view.subviews {
            if let found = textView(in: subview, label: label) { return found }
        }
        return nil
    }

    @MainActor
    private static func textField(in view: NSView, label: String) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityLabel() == label {
            return field
        }
        for subview in view.subviews {
            if let found = textField(in: subview, label: label) { return found }
        }
        return nil
    }

    @MainActor
    private static func keyEvent(
        _ keyCode: UInt16,
        _ characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        windowNumber: Int
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else {
            fatalError("could not build a key event")
        }
        return event
    }

    /// The number of `Tj` operations in the last generated text appearance stream.
    ///
    /// The form writer appends uncompressed appearance streams to the original file; the last
    /// one is the multiline field (the changed fields are written in page order). The inner
    /// `re W n` clip followed directly by `BT` identifies a text appearance this writer made.
    private static func appearanceTextLineCount(url: URL) -> Int {
        let data = try? Data(contentsOf: url)
        guard let data else { return 0 }
        let text = String(decoding: data, as: UTF8.self)
        guard let clip = text.range(of: "re W n\nBT\n", options: .backwards),
              let end = text[clip.upperBound...].range(of: "\nET\n") else { return 0 }
        let body = text[clip.upperBound..<end.lowerBound]
        return body.components(separatedBy: " Tj").count - 1
    }

    // MARK: - PDFKit reading and raster rows

    /// The widget values PDFKit reads from one page, in page order.
    @MainActor
    private static func pdfKitTextValues(
        url: URL,
        pageIndex: Int
    ) throws -> [(subtype: String, value: String?, state: Int)] {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex) else {
            throw NSError(domain: "LyraReader", code: 70, userInfo: [
                NSLocalizedDescriptionKey: "PDFKit could not open the saved form page",
            ])
        }
        return page.annotations.compactMap { annotation in
            guard annotation.type == "Widget" else { return nil }
            return (subtype: annotation.widgetFieldType.rawValue,
                    value: annotation.widgetStringValue,
                    state: annotation.buttonWidgetState.rawValue)
        }
    }

    /// The rows of dark text ink inside `viewSpaceRect`, grouped so one text line is one band.
    ///
    /// This is the independent renderer: it asks PDFKit to draw the page and counts pixel rows
    /// rather than trusting the appearance stream's own operator list.
    @MainActor
    private static func inkRowBands(
        url: URL,
        pageIndex: Int,
        viewSpaceRect: CGRect,
        scale: CGFloat
    ) throws -> [ClosedRange<Int>] {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex) else {
            throw NSError(domain: "LyraReader", code: 71, userInfo: [
                NSLocalizedDescriptionKey: "PDFKit could not open the rendered form page",
            ])
        }
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(ceil(bounds.width * scale))
        let height = Int(ceil(bounds.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "LyraReader", code: 72, userInfo: [
                NSLocalizedDescriptionKey: "could not create a PDFKit bitmap",
            ])
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let data = context.data else { return [] }
        let rowBytes = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        let minX = max(Int(viewSpaceRect.minX * scale), 0)
        let maxX = min(Int(viewSpaceRect.maxX * scale), width - 1)
        let minY = max(Int(viewSpaceRect.minY * scale), 0)
        let maxY = min(Int(viewSpaceRect.maxY * scale), height - 1)
        guard minX < maxX, minY < maxY else { return [] }
        var occupied = [Bool](repeating: false, count: height)
        for y in minY...maxY {
            for x in minX...maxX {
                let offset = y * rowBytes + x * 4
                if pixels[offset] < 90 && pixels[offset + 1] < 90 && pixels[offset + 2] < 90 {
                    occupied[y] = true
                    break
                }
            }
        }
        // A glyph's rows touch; allow a two-pixel gap so antialiasing does not split one line
        // into several bands, while the leading between two lines is much larger.
        var bands: [ClosedRange<Int>] = []
        var start: Int?
        var last = minY
        for y in minY...maxY {
            if occupied[y] {
                if start == nil { start = y }
                last = y
            } else if let bandStart = start, y - last > 2 {
                bands.append(bandStart...last)
                start = nil
            }
        }
        if let bandStart = start { bands.append(bandStart...last) }
        return bands
    }
}


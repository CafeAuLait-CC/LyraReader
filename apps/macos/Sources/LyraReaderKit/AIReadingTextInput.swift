import AppKit
import SwiftUI

/// One TextKit layout owns the text, insertion point and placeholder. Return handling lives
/// at the native input boundary so marked text can finish composition before a chat sends.
struct AIReadingTextInput: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let placeholder: String
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = AIReadingInputScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = NSScroller.preferredScrollerStyle; scroll.borderType = .noBorder
        let input = AIReadingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 96))
        input.isRichText = false; input.drawsBackground = false
        input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.textContainerInset = NSSize(width: 10, height: 10)
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.widthTracksTextView = true
        input.textContainer?.containerSize.height = .greatestFiniteMagnitude
        input.font = .systemFont(ofSize: 13)
        input.allowsUndo = true
        input.delegate = context.coordinator
        scroll.documentView = input
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = scroll.documentView as? AIReadingTextView else { return }
        let appearance: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if scroll.appearance?.name != appearance { scroll.appearance = NSAppearance(named: appearance) }
        if input.string != text && !input.hasMarkedText() { input.string = text }
        input.placeholder = placeholder; input.onSubmit = onSubmit
        input.isEditable = enabled; input.isSelectable = enabled
        if input.textColor != LyraReaderTheme.textPrimaryColor { input.textColor = LyraReaderTheme.textPrimaryColor }
        input.insertionPointColor = LyraReaderTheme.accentColor
        input.selectedTextAttributes = [.backgroundColor: NSColor(LyraReaderTheme.selectedBg),
                                        .foregroundColor: NSColor(LyraReaderTheme.selectedFg)]
        input.setAccessibilityLabel(placeholder)
        if onSubmit != nil { input.setAccessibilityHelp(aiReadingLabel("Return to send · Shift+Return for a new line")) }
        input.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIReadingTextInput
        init(_ parent: AIReadingTextInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let input = notification.object as? AIReadingTextView else { return }
            parent.text = input.string; input.needsDisplay = true
        }
    }
}

@MainActor private final class AIReadingInputScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let input = documentView as? AIReadingTextView, contentSize.width > 0, contentSize.height > 0 else { return }
        if input.minSize.height != contentSize.height { input.minSize = NSSize(width: 0, height: contentSize.height) }
        if input.frame.width != contentSize.width || input.frame.height < contentSize.height {
            input.setFrameSize(NSSize(width: contentSize.width, height: max(input.frame.height, contentSize.height)))
        }
    }
}

@MainActor final class AIReadingTextView: NSTextView {
    var placeholder = ""
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), let onSubmit, !hasMarkedText() {
            if event.isARepeat { return }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.shift) { insertNewline(nil); return }
            if !modifiers.contains(.option) && !modifiers.contains(.control) { onSubmit(); return }
        }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let textContainer else { return }
        let storage = NSTextStorage(string: placeholder, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(LyraReaderTheme.textPlaceholder)
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: textContainer.containerSize)
        container.lineFragmentPadding = textContainer.lineFragmentPadding
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: textContainerOrigin)
    }
}

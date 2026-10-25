import AppKit
import SwiftUI

/// A transparent native text surface on the PDF, without a note card or a separate dialog.
///
/// The text view lives in a flipped container that pins it to the container's full bounds. That
/// is what puts the insertion point at the **top-left** of the box from the first frame: an
/// `NSTextView` given the text box's size directly can shrink to its one-line content and settle
/// at the bottom of the SwiftUI frame (the reported bottom-left caret). The container owns the
/// geometry; the text view only lays out glyphs from its own top-left.
///
/// `scrollsVertically` is for an editor whose box the reader does not own — an AcroForm widget's
/// rectangle is fixed by the PDF. In that mode the text view becomes a vertically scrolling
/// document inside an `NSScrollView`, so a value taller than the widget stays editable instead of
/// being cut off. The default (text boxes, notes) keeps the growth behaviour: the box grows with
/// the text and the editor fills it.
struct InlineTextBoxEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let color: NSColor
    let onCommit: () -> Void
    let onCancel: () -> Void
    var onTab: ((Bool) -> Void)? = nil
    var accessibilityName = "Text box content"
    var useAppearanceFont = true
    /// Keep the editor's box fixed and scroll the text inside it. Used by form widgets, whose
    /// rectangle is part of the document rather than something the text may resize.
    var scrollsVertically = false
    /// Start with the whole text selected. A new Date box uses this so the first keystroke
    /// replaces the date; an ordinary empty box is unaffected.
    var selectAllOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> EditorContainer {
        let container = EditorContainer(scrollsVertically: scrollsVertically)
        let view = container.editor
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isHorizontallyResizable = false
        // The editor is as tall as the box, not as tall as its text: the caret and the first
        // line sit at the top and the box itself is what grows when lines are added.
        view.isVerticallyResizable = false
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.widthTracksTextView = true
        if scrollsVertically {
            view.isVerticallyResizable = true
            view.autoresizingMask = [.width]
            view.minSize = NSSize(width: 0, height: 0)
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        }
        view.delegate = context.coordinator
        view.string = text
        view.setAccessibilityLabel(accessibilityName)
        context.coordinator.pendingSelectAll = selectAllOnAppear
        updateNSView(container, context: context)
        let wantsSelectAll = selectAllOnAppear
        DispatchQueue.main.async { [weak container, weak coordinator = context.coordinator] in
            guard let container, let window = container.window else { return }
            window.makeFirstResponder(container.editor)
            let length = (container.editor.string as NSString).length
            if wantsSelectAll {
                if length > 0 {
                    container.editor.setSelectedRange(NSRange(location: 0, length: length))
                    coordinator?.pendingSelectAll = false
                }
            } else {
                container.editor.setSelectedRange(NSRange(location: length, length: 0))
            }
            container.editor.scrollRangeToVisible(container.editor.selectedRange())
        }
        return container
    }
    func updateNSView(_ container: EditorContainer, context: Context) {
        context.coordinator.parent = self
        let view = container.editor
        view.font = useAppearanceFont ? AnnotationTextFont.font(size: max(1, fontSize)) : .systemFont(ofSize: max(1, fontSize))
        if useAppearanceFont {
            view.typingAttributes[.kern] = 0
            view.textStorage?.addAttribute(.kern, value: 0, range: NSRange(location: 0, length: (view.string as NSString).length))
        }
        view.textColor = color
        view.insertionPointColor = color
        view.onCommit = onCommit
        view.onCancel = onCancel
        view.onTab = onTab
        if view.string != text { view.string = text }
        // The Date box's text arrives after the view is made. Once it is here, select it once so
        // typing replaces it; later keystrokes must not re-select what the reader is writing.
        if context.coordinator.pendingSelectAll, !text.isEmpty {
            view.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
            context.coordinator.pendingSelectAll = false
        }
        // SwiftUI can hand the container a new size without asking the text view to lay out
        // again; doing it here keeps the insertion point at the top-left on the very first pass.
        container.needsLayout = true
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineTextBoxEditor
        var pendingSelectAll = false
        init(_ parent: InlineTextBoxEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            // A scrollable form editor must keep the insertion point visible as the value grows.
            if let scroll = view.enclosingScrollView {
                view.layoutManager?.ensureLayout(for: view.textContainer!)
                let used = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 0
                view.setFrameSize(NSSize(
                    width: view.frame.width,
                    height: max(scroll.contentSize.height, ceil(used + 2))
                ))
                view.scrollRangeToVisible(view.selectedRange())
            }
        }
    }
    /// A flipped host that gives the text view the whole box. `NSViewRepresentable` proposes the
    /// overlay's size to this view; the text view never influences its own height.
    ///
    /// When `scrollsVertically` is set, the host owns a scroll view instead: the text view is its
    /// document and grows in height, while the host's frame (the widget's rectangle) does not.
    final class EditorContainer: NSView {
        let editor = Editor(frame: .zero)
        private let scrollView: NSScrollView?
        override var isFlipped: Bool { true }

        init(scrollsVertically: Bool) {
            if scrollsVertically {
                let scroll = NSScrollView()
                scroll.drawsBackground = false
                scroll.borderType = .noBorder
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = true
                scroll.scrollerStyle = .overlay
                scroll.verticalScrollElasticity = .allowed
                scrollView = scroll
            } else {
                scrollView = nil
            }
            super.init(frame: .zero)
            if let scrollView {
                scrollView.documentView = editor
                addSubview(scrollView)
            } else {
                editor.autoresizingMask = [.width, .height]
                addSubview(editor)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("InlineTextBoxEditor is programmatic") }

        override func layout() {
            super.layout()
            guard let scrollView else {
                editor.frame = bounds
                return
            }
            scrollView.frame = bounds
            scrollView.tile()
            let content = scrollView.contentSize
            editor.minSize = NSSize(width: content.width, height: content.height)
            if editor.textContainer?.containerSize.width != content.width {
                editor.textContainer?.containerSize = NSSize(
                    width: content.width,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
            var height = max(editor.frame.height, content.height)
            if let manager = editor.layoutManager, let container = editor.textContainer {
                manager.ensureLayout(for: container)
                height = max(height, ceil(manager.usedRect(for: container).height + 2))
            }
            if editor.frame.width != content.width || editor.frame.height != height {
                editor.frame = NSRect(x: 0, y: 0, width: content.width, height: height)
            }
        }
    }
    final class Editor: NSTextView {
        var onCommit: (() -> Void)?
        var onCancel: (() -> Void)?
        var onTab: ((Bool) -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 48, let onTab { onTab(event.modifierFlags.contains(.shift)); return }
            if event.keyCode == 53 { onCancel?(); return }
            if (event.keyCode == 36 || event.keyCode == 76),
               event.modifierFlags.contains(.command) {
                onCommit?()
                return
            }
            super.keyDown(with: event)
        }
    }
}

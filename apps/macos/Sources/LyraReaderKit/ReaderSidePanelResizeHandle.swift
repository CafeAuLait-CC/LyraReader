import AppKit
import SwiftUI

/// Native pointer tracking keeps the origin in window space while the handle itself moves.
struct ReaderSidePanelResizeHandle: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    let width: CGFloat
    let label: String
    let interactive: Bool
    let began: () -> Void
    let resize: (CGFloat) -> Void
    let ended: () -> Void

    func makeNSView(context: Context) -> ReaderSidePanelResizeView { ReaderSidePanelResizeView(frame: .zero) }
    func updateNSView(_ view: ReaderSidePanelResizeView, context: Context) {
        view.contentWidth = width
        view.began = began; view.resize = resize; view.ended = ended
        view.inputEnabled = enabled && interactive
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue("\(Int(width.rounded())) points")
        view.setAccessibilityEnabled(view.inputEnabled)
        if !view.inputEnabled { view.finishResize() }
    }
    static func dismantleNSView(_ view: ReaderSidePanelResizeView, coordinator: ()) { view.finishResize() }
}

@MainActor final class ReaderSidePanelResizeView: NSView {
    var contentWidth: CGFloat = ReaderSidePanelMetrics.defaultContentWidthPt
    var inputEnabled = true
    var began: () -> Void = {}
    var resize: (CGFloat) -> Void = { _ in }
    var ended: () -> Void = {}
    private var drag: (windowX: CGFloat, width: CGFloat)?
    private var hovered = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.splitter)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true); setAccessibilityRole(.splitter)
    }
    override var acceptsFirstResponder: Bool { inputEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { inputEnabled }
    override func resetCursorRects() { if inputEnabled { addCursorRect(bounds, cursor: .resizeLeftRight) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if inputEnabled && (hovered || drag != nil) {
            LyraReaderTheme.accentColor.withAlphaComponent(0.55).setFill()
            bounds.fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard inputEnabled else { return }
        drag = (event.locationInWindow.x, contentWidth)
        began(); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard inputEnabled, let drag else { return }
        resize(ReaderSidePanelMetrics.contentWidth(base: drag.width,
            dragTranslationX: event.locationInWindow.x - drag.windowX))
    }
    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        mouseDragged(with: event); finishResize()
    }
    override func cancelOperation(_ sender: Any?) { finishResize() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishResize() }
        super.viewWillMove(toWindow: newWindow)
    }
    func finishResize() {
        guard drag != nil else { return }
        drag = nil; needsDisplay = true; ended()
    }
    override func accessibilityPerformIncrement() -> Bool { adjust(16) }
    override func accessibilityPerformDecrement() -> Bool { adjust(-16) }
    private func adjust(_ delta: CGFloat) -> Bool {
        guard inputEnabled else { return false }
        began(); resize(ReaderSidePanelMetrics.clampedContentWidth(contentWidth + delta)); ended()
        return true
    }
}

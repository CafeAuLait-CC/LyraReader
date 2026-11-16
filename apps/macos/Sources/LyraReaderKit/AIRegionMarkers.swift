import AppKit
import SwiftUI

/// Map the original captured rectangle through the same display segments as the PDF.
/// A selection crossing a tear produces two outlines; the gap itself is never tinted.
package enum AIRegionMarkerGeometry {
    package static func rectangles(attachment: AIRegionAttachment, frames: [PagePlacement],
                                   width: CGFloat, contentWidth: CGFloat,
                                   scroll: CGFloat, zoom: CGFloat) -> [CGRect] {
        guard zoom.isFinite, zoom > 0 else { return [] }
        let offset = max(0, (width - contentWidth * zoom) / 2)
        return frames.filter { $0.index == attachment.page }.compactMap { frame in
            let source = CGRect(x: 0, y: frame.sourceTopPt, width: frame.widthPt, height: frame.heightPt)
            let clipped = attachment.rect.intersection(source)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            return CGRect(x: offset + (frame.leftPt + clipped.minX) * zoom,
                y: (frame.topPt + clipped.minY - frame.sourceTopPt - scroll) * zoom,
                width: clipped.width * zoom, height: clipped.height * zoom)
        }
    }
}

@MainActor
final class AIRegionMarkerButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    var regionID: UUID?
    var activate: (() -> Void)?
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded; isBordered = false
        font = .systemFont(ofSize: 11, weight: .semibold)
        target = self; action = #selector(openConversation)
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        NSColor(LyraReaderTheme.accentSoft).setFill(); shape.fill()
        if hovered || isHighlighted {
            LyraReaderTheme.accentColor.withAlphaComponent(isHighlighted ? 0.12 : 0.06).setFill()
            shape.fill()
        }
        NSColor(LyraReaderTheme.accentBorder).withAlphaComponent(hovered ? 0.85 : 0.6).setStroke()
        shape.lineWidth = 1; shape.stroke()
        super.draw(dirtyRect)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hovered = false; needsDisplay = true }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func openConversation() { activate?(); window?.makeFirstResponder(self) }
}

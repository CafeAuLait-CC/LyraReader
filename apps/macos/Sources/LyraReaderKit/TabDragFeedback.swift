import AppKit
import QuartzCore
import SwiftUI

/// A noninteractive preview can follow the pointer beyond the source window's clipping bounds.
@MainActor
final class TabDragFeedback {
    private let panel: NSPanel
    private let title: String
    let sourceFrame: CGRect
    private let grab: CGPoint
    private var hint = ""
    var frame: CGRect { panel.frame }
    var isVisible: Bool { panel.isVisible }

    init(title: String, sourceFrame: CGRect, pressPoint: CGPoint, appearance: NSAppearance) {
        self.title = title
        self.sourceFrame = sourceFrame
        grab = CGPoint(x: pressPoint.x - sourceFrame.minX, y: sourceFrame.maxY - pressPoint.y)
        let frame = CGRect(x: sourceFrame.minX, y: sourceFrame.maxY - 64,
                           width: sourceFrame.width, height: 64)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.appearance = appearance; panel.animationBehavior = .none
        panel.setAccessibilityElement(false)
    }

    func update(at point: CGPoint, hint: String) {
        if self.hint != hint {
            self.hint = hint
            panel.contentView = NSHostingView(rootView: TabDragPreview(title: title, hint: hint))
        }
        panel.setFrameOrigin(CGPoint(x: point.x - grab.x, y: point.y + grab.y - 64))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func settle(at destination: CGRect?) {
        guard !ReaderMotion.reduceMotionEnabled else { panel.orderOut(nil); return }
        let panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ReaderMotion.secondaryRowDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if let destination {
                panel.animator().setFrame(CGRect(x: destination.minX, y: destination.maxY - 64,
                    width: destination.width, height: 64), display: true)
            }
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    func dismiss() { panel.orderOut(nil) }
}

private struct TabDragPreview: View {
    let title: String
    let hint: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text").foregroundStyle(LyraReaderTheme.accent)
                Text(title).lineLimit(1).truncationMode(.middle)
            }.font(.system(size: 12, weight: .medium))
            Text(hint).font(.system(size: 10)).foregroundStyle(LyraReaderTheme.textSecondary)
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(LyraReaderTheme.textPrimary)
        .background(RoundedRectangle(cornerRadius: 9).fill(LyraReaderTheme.raisedBg))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(LyraReaderTheme.accent.opacity(0.65), lineWidth: 1))
        .padding(2)
        .accessibilityHidden(true)
    }
}

import AppKit
import QuartzCore

/// The eraser's cursor: a thin circle drawn **over the page** whose radius is the distance the
/// eraser actually reaches, in view points.
///
/// It is not the system cursor (the system's eraser cursor says nothing about reach and cannot
/// scale with the tool). It is a transparent, click-through overlay: `hitTest` returns nil, so
/// every press still reaches the canvas and erases exactly as it did before this view existed.
///
/// The radius comes from `AnnotationGeometry.eraserCursorRadiusViewPt`: the fixed 8 view-point
/// tolerance plus half the ink stroke's on-screen width. The canvas supplies the reader's
/// current ink width and the live zoom, so the ring is 9 pt for the default 2 pt pen at 100%
/// and grows with the stroke as the page is zoomed in.
package final class EraserCursorRingView: NSView {
    /// The ring is hollow: this is the "transparent fill" the cursor draws over the page.
    package static let fillColor = NSColor.clear
    /// One point, so the circle reads as an indicator rather than a second mark on the page.
    package static let lineWidth: CGFloat = 1
    /// The alpha of the theme's secondary text colour. Low enough to stay subtle on paper,
    /// high enough to remain visible over the dark canvas and over ink.
    package static let strokeAlpha: CGFloat = 0.85

    private let ringLayer = CAShapeLayer()
    /// The circle's centre in this view's top-left coordinate space.
    package private(set) var ringCenterViewPt: CGPoint = .zero
    /// The circle's radius in view points; equal to the eraser's reach at the current zoom.
    package private(set) var ringRadiusViewPt: CGFloat = 0

    /// Top-left origin, so the canvas can hand over the pointer position directly.
    package override var isFlipped: Bool { true }

    /// Click-through by construction: the cursor is never a hit target, so it cannot intercept
    /// an eraser press, a draw, or any other canvas gesture.
    package override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The ring is visible exactly while the eraser holds the pointer.
    package var isRingVisible: Bool { !isHidden }

    package override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = false
        ringLayer.fillColor = Self.fillColor.cgColor
        ringLayer.lineWidth = Self.lineWidth
        ringLayer.contentsScale = 2
        layer?.addSublayer(ringLayer)
        isHidden = true
    }

    @available(*, unavailable) package required init?(coder: NSCoder) {
        fatalError("EraserCursorRingView is programmatic")
    }

    /// Places the ring under the pointer and shows it. A non-finite or empty radius hides it:
    /// a zero-radius circle would be a dot in the middle of the page, not a reach indicator.
    package func show(at center: CGPoint, radius: CGFloat) {
        guard center.x.isFinite, center.y.isFinite, radius.isFinite, radius > 0 else {
            hideRing()
            return
        }
        ringCenterViewPt = center
        ringRadiusViewPt = radius
        isHidden = false
        redraw()
    }

    /// Reuses the last pointer position with a new reach (zoom or ink-width change).
    package func updateRadius(_ radius: CGFloat) {
        guard radius.isFinite, radius > 0 else { return }
        ringRadiusViewPt = radius
        if !isHidden { redraw() }
    }

    package func hideRing() {
        isHidden = true
    }

    /// The stroke this view draws, resolved under `appearance`. The canvas calls it with its
    /// effective appearance; checks use it to prove the light and dark themes differ.
    package func strokeColor(for appearance: NSAppearance) -> NSColor {
        var color = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            let base = LyraReaderTheme.textSecondaryColor.usingColorSpace(.sRGB) ?? .clear
            color = base.withAlphaComponent(Self.strokeAlpha)
        }
        return color
    }

    package override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.frame = bounds
        CATransaction.commit()
        if !isHidden { redraw() }
    }

    package override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !isHidden { redraw() }
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hideRing() }
        if !isHidden { redraw() }
    }

    private func redraw() {
        let stroke = strokeColor(for: effectiveAppearance)
        let radius = ringRadiusViewPt
        let circle = CGRect(x: ringCenterViewPt.x - radius, y: ringCenterViewPt.y - radius,
                            width: radius * 2, height: radius * 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringLayer.frame = bounds
        ringLayer.path = CGPath(ellipseIn: circle, transform: nil)
        ringLayer.fillColor = Self.fillColor.cgColor
        ringLayer.strokeColor = stroke.cgColor
        ringLayer.lineWidth = Self.lineWidth
        ringLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}

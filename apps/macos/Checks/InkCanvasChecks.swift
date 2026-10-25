import AppKit
import QuartzCore
@testable import LyraReaderKit

extension ReaderChecks {
    /// Exercise the actual pointer → page path → composited overlay, rather than only the
    /// model's geometry. Correct stored points alone cannot catch a mirrored drawing layer.
    @MainActor static func inkCanvasChecks() async throws {
        _ = NSApplication.shared
        let page = PagePlacement(index: 0, topPt: 20, leftPt: 0, widthPt: 600, heightPt: 500)
        let upper = PagePlacement(index: 0, topPt: 20, leftPt: 0, widthPt: 600, heightPt: 200)
        let lower = PagePlacement(index: 0, topPt: 360, leftPt: 0, widthPt: 600,
                                  heightPt: 300, sourceTopPt: 200)
        let top = [CGPoint(x: 80, y: 80), CGPoint(x: 180, y: 140)]
        let scenarios: [(String, [PagePlacement], CGFloat, CGFloat, CGFloat, [CGPoint])] = [
            ("top-down", [page], 600, 1, 0, top),
            ("bottom-up", [page], 600, 1, 0,
             [CGPoint(x: 80, y: 430), CGPoint(x: 180, y: 350)]),
            ("zoom-scroll", [page], 600, 3, 70, top),
            ("later-page", [PagePlacement(index: 2, topPt: 700, leftPt: 0,
                                           widthPt: 600, heightPt: 500)], 600, 1, 650, top),
            ("facing-page", [PagePlacement(index: 2, topPt: 20, leftPt: 0, widthPt: 300, heightPt: 500),
                             PagePlacement(index: 3, topPt: 20, leftPt: 310, widthPt: 300, heightPt: 500)],
             610, 1, 0, top),
            ("across-tear", [upper, lower], 600, 1, 0,
             [CGPoint(x: 80, y: 160), CGPoint(x: 180, y: 260)]),
        ]
        for (name, frames, width, zoom, scroll, points) in scenarios {
            try await inkCanvasGesture(name: name, frames: frames, contentWidth: width,
                                       zoom: zoom, scroll: scroll, points: points, tool: .pen)
        }
        for tool in [AnnotationTool.line, .arrow, .rectangle, .ellipse] {
            try await inkCanvasGesture(name: tool.rawValue, frames: [page], contentWidth: 600,
                                       zoom: 1, scroll: 0, points: top, tool: tool)
        }
    }

    @MainActor private static func inkCanvasGesture(
        name: String, frames: [PagePlacement], contentWidth: CGFloat,
        zoom: CGFloat, scroll: CGFloat, points: [CGPoint], tool: AnnotationTool
    ) async throws {
        let size = CGSize(width: 800, height: 700)
        let canvas = MetalCanvasView(frame: CGRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        canvas.contentWidthPt = contentWidth
        canvas.annotationPageFrames = frames
        canvas.zoom = zoom
        canvas.scrollYPt = scroll
        let red = AnnotationColor(red: 220, green: 20, blue: 30, alpha: 255)
        canvas.annotationColor = red
        canvas.annotationStrokeWidth = 4
        canvas.annotationTool = tool
        canvas.layoutSubtreeIfNeeded()
        try await eventually("\(name): the canvas submits its view transform", { canvas.frameAttemptCount > 0 })
        let overlay = canvas.subviews.compactMap { $0 as? AnnotationOverlayView }.first!
        let page = frames.last!.index
        func contentPoint(_ point: CGPoint) -> CGPoint {
            let segment = frames.first { $0.index == page && $0.sourceRangePt.contains(point.y) }!
            return CGPoint(x: segment.leftPt + point.x,
                           y: segment.topPt + point.y - segment.sourceTopPt)
        }
        func viewPoint(_ point: CGPoint) -> CGPoint {
            let content = contentPoint(point)
            return CGPoint(x: max(0, (size.width - contentWidth * zoom) / 2) + content.x * zoom,
                           y: (content.y - scroll) * zoom)
        }

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            let local = CGPoint(x: point.x, y: size.height - point.y)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(local, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        var draft: AnnotationDraft?
        canvas.onAnnotationDraft = { draft = $0 }
        let start = viewPoint(points[0]), end = viewPoint(points[1])
        canvas.mouseDown(with: event(.leftMouseDown, at: start))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: end))

        func capture(_ phase: String) throws -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 700,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            CATransaction.flush()
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
            // Bitmap rows are top-down; Quartz's default drawing context is bottom-up.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            overlay.layer!.render(in: context)
            if let directory = ProcessInfo.processInfo.environment["LYRA_INK_EVIDENCE"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])!.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(phase).png"))
            }
            return bitmap
        }
        func redPixels(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Int {
            var count = 0
            for y in max(0, Int(rect.minY))..<min(700, Int(ceil(rect.maxY))) {
                for x in max(0, Int(rect.minX))..<min(800, Int(ceil(rect.maxX))) {
                    let c = bitmap.colorAt(x: x, y: y)!
                    if c.alphaComponent > 0.5 && c.redComponent > 0.6 && c.greenComponent < 0.3 {
                        count += 1
                    }
                }
            }
            return count
        }
        let probes = tool == .ellipse ? [CGPoint(x: (start.x + end.x) / 2, y: start.y),
                                         CGPoint(x: end.x, y: (start.y + end.y) / 2)] : [start, end]
        func verifyPixels(_ bitmap: NSBitmapImageRep, phase: String) {
            for (index, probe) in probes.enumerated() {
                require(redPixels(bitmap, in: CGRect(x: probe.x - 3, y: probe.y - 3,
                                                       width: 6, height: 6)) > 3,
                        "\(name) \(phase): rendered stroke matches pointer probe \(index + 1) at \(probe)")
            }
            if tool == .pen {
                let wrongSlope = CGPoint(x: start.x, y: end.y)
                require(redPixels(bitmap, in: CGRect(x: wrongSlope.x - 3, y: wrongSlope.y - 3,
                                                       width: 6, height: 6)) == 0,
                        "\(name) \(phase): the stroke is not mirrored in the opposite drag direction")
            }
            if name == "across-tear" {
                require(redPixels(bitmap, in: CGRect(x: 100, y: 230, width: 400, height: 120)) == 0,
                        "\(phase): ink is clipped out of the torn page's conversation gap")
            }
        }
        verifyPixels(try capture("live"), phase: "live")
        canvas.mouseUp(with: event(.leftMouseUp, at: end))
        guard let draft else { require(false, "\(name): the gesture produces a draft"); return }
        require(draft.page == page && draft.kind == tool.kind,
                "\(name): mouse-up commits the correct page and tool")
        if tool == .pen {
            require(draft.inkPaths == [points], "\(name): pointer samples retain exact top-left page coordinates")
        }
        let cleared = try capture("released")
        require(redPixels(cleared, in: CGRect(origin: .zero, size: size)) == 0,
                "\(name): mouse-up removes the live preview")
        canvas.annotationMarks = [CanvasAnnotationMark(id: name, page: page, kind: draft.kind,
            inkPaths: draft.inkPaths, shapeRect: draft.shapeRect,
            lineStart: draft.lineStart, lineEnd: draft.lineEnd,
            color: red, strokeWidth: 4, isSelected: true, isEditable: true)]
        verifyPixels(try capture("committed"), phase: "committed")
        let hitPoint = tool == .ellipse
            ? CGPoint(x: (points[0].x + points[1].x) / 2, y: points[0].y) : points[0]
        require(overlay.hitTestMark(atContentPoint: contentPoint(hitPoint), toleranceViewPt: 4)?.id == name,
                "\(name): hit testing finds the mark at its displayed position")
    }
}

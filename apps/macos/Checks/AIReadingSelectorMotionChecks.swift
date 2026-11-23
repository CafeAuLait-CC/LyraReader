import AppKit
import SwiftUI
import LyraReaderBindings
@testable import LyraReaderKit

@MainActor private final class ReadingSelectorAppearance: ObservableObject {
    @Published var reduced = false
}

private struct ReadingSelectorHost: View {
    @ObservedObject var state: AppState
    @ObservedObject var reading: AIReadingModel
    @ObservedObject var navigation: AIAssistantModel
    @ObservedObject var appearance: ReadingSelectorAppearance
    var body: some View {
        // Include the real drawer's transaction boundary, not just an isolated control.
        ReaderSidePanel(isVisible: true, contentWidth: 414, onResize: { _ in }) {
            AIReadingSidebar(state: state, navigation: navigation, reading: reading, isActive: false)
        }.id(appearance.reduced).preferredColorScheme(.light)
    }
}

extension ReaderChecks {
    @MainActor static func aiReadingSelectorMotionChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-selector-motion-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("synthetic.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: source)
        let domain = "lyra-selector-motion-\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AISettingsStore(defaults: defaults, keyStore: InMemoryAPIKeyStore(key: nil))
        settings.prereadingPolicy = "never"
        let state = AppState(engine: try RustEngine())
        require(state.open(url: source), "the selector motion fixture opens")
        let reading = AIReadingModel(settings: settings, audit: AIAuditTrail.shared)
        await reading.bind(state)
        let summary = AiReadingRecord.make(kind: "summary", title: "Whole document",
            content: "## Overview\n\n" + String(repeating: "A synthetic paragraph makes only the whole-document result scroll.\n\n", count: 24),
            sourceID: aiReadingScopeKey(selection: nil), pages: [1])
        reading.store.put(summary)
        reading.store.put(.make(kind: "translation", title: "Whole document",
            content: "<!--lyra:0-->A synthetic translation.", sourceID: aiReadingScopeKey(selection: nil), pages: [1]))
        let notes = (0..<16).map { AiReadingRecord.make(kind: "note", title: "Synthetic note \($0)",
            content: "A local note with enough content to make the list scroll.", sourceID: "synthetic:\($0)", pages: [1]) }
        let navigation = AIAssistantModel(settings: settings)
        let appearance = ReadingSelectorAppearance()
        let savedMotion = ReaderMotion.reduceMotionOverride
        ReaderMotion.reduceMotionOverride = false
        defer { ReaderMotion.reduceMotionOverride = savedMotion }
        let host = NSHostingView(rootView: ReadingSelectorHost(state: state, reading: reading, navigation: navigation, appearance: appearance))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 421, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil; reading.cancelPresentation() }
        func markers(_ view: NSView) -> [AITranslationControlMarker] {
            (view as? AITranslationControlMarker).map { [$0] } ?? view.subviews.flatMap(markers)
        }
        func rect(_ id: String) -> CGRect {
            host.layoutSubtreeIfNeeded()
            guard let marker = markers(host).first(where: { $0.id == id }) else { fail("FAIL: missing selector control \(id)") }
            return host.convert(marker.bounds, from: marker)
        }
        func click(_ id: String) {
            let target = host.convert(rect(id), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: CGPoint(x: target.midX, y: target.midY),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
            }
        }
        // Read actual gold pixels. A target-value probe or an endpoint screenshot cannot
        // distinguish a continuous slide from a jump or two backgrounds cross-fading.
        func captureSelector(_ area: CGRect) -> NSBitmapImageRep {
            let bitmap: NSBitmapImageRep
            if CommandLine.arguments.contains("--selector-one-times-pixels") {
                guard let unscaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(area.width)),
                    pixelsHigh: Int(ceil(area.height)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                    fail("FAIL: selector single-scale bitmap exists")
                }
                unscaled.size = area.size; bitmap = unscaled
            } else {
                guard let native = host.bitmapImageRepForCachingDisplay(in: area) else { fail("FAIL: selector bitmap exists") }
                bitmap = native
            }
            host.cacheDisplay(in: area, to: bitmap)
            return bitmap
        }
        func paintedHighlight(_ area: CGRect, bitmap supplied: NSBitmapImageRep? = nil) -> (center: CGFloat, width: CGFloat, labels: [CGRect]) {
            let bitmap = supplied ?? captureSelector(area)
            guard let image = bitmap.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("FAIL: selector pixels are readable") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            guard let data = context.data else { fail("FAIL: selector pixels exist") }
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            let scale = CGFloat(bitmap.pixelsWide) / area.width
            var columns: [Int] = []
            var inkMinX = [Int.max, Int.max], inkMinY = [Int.max, Int.max]
            var inkMaxX = [-1, -1], inkMaxY = [-1, -1]
            for x in 0..<bitmap.pixelsWide {
                var gold = 0
                for y in 0..<bitmap.pixelsHigh {
                    let offset = y * context.bytesPerRow + x * 4
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    if r > 217, g > 178, b < 212, r - b > 30, g - b > 17 { gold += 1 }
                    if r < 150, g < 150, b < 150, pixels[offset + 3] > 250,
                       y > Int(3 * scale), y < bitmap.pixelsHigh - Int(3 * scale),
                       x > Int(3 * scale), x < bitmap.pixelsWide - Int(3 * scale),
                       abs(x - bitmap.pixelsWide / 2) > Int(3 * scale) {
                        let half = x < bitmap.pixelsWide / 2 ? 0 : 1
                        inkMinX[half] = min(inkMinX[half], x); inkMinY[half] = min(inkMinY[half], y)
                        inkMaxX[half] = max(inkMaxX[half], x); inkMaxY[half] = max(inkMaxY[half], y)
                    }
                }
                if gold > bitmap.pixelsHigh / 3 { columns.append(x) }
            }
            guard let first = columns.first, let last = columns.last else { fail("FAIL: selector paints its gold background") }
            let labels = (0..<2).map { index -> CGRect in
                guard inkMaxX[index] >= inkMinX[index] else { fail("FAIL: selector paints its icon and text") }
                return CGRect(x: CGFloat(inkMinX[index]) / scale, y: CGFloat(inkMinY[index]) / scale,
                    width: CGFloat(inkMaxX[index] - inkMinX[index] + 1) / scale, height: CGFloat(inkMaxY[index] - inkMinY[index] + 1) / scale)
            }
            return (CGFloat(first + last) / (2 * scale), CGFloat(last - first + 1) / scale, labels)
        }
        func scrollers(_ view: NSView, style: NSScroller.Style) {
            if let scroll = view as? NSScrollView { scroll.scrollerStyle = style; scroll.tile() }
            view.subviews.forEach { scrollers($0, style: style) }
        }
        var sharedSelectorWidth: CGFloat?
        for (name, tab, first, second) in [
            ("summary", AIAssistantTab.summary, "Whole document", "Selection"),
            ("translation", .translation, "Whole document", "Selection"),
            ("notes", .regions, "Page order", "Recent")
        ] {
            navigation.selectedTab = tab; reading.selectedNoteID = nil
            try await Task.sleep(for: .milliseconds(220))
            // Force the space-consuming system scroller used in the user's recording.
            scrollers(host, style: .legacy)
            try await Task.sleep(for: .milliseconds(100))
            let left = "segment-\(first)", right = "segment-\(second)"
            click(left); try await Task.sleep(for: .milliseconds(250))
            let originalLeft = rect(left), originalRight = rect(right)
            let area = originalLeft.union(originalRight)
            // AppKit can snap the two equal SwiftUI cells to different pixel widths.
            // Their mean preserves the actual half-point width without choosing one edge's bias.
            let cellWidth = (originalLeft.width + originalRight.width) / 2
            print("INFO: \(name) native cells left=\(originalLeft), right=\(originalRight), mean width=\(cellWidth)")
            // The probes cover the two cells, inside the selector's 3 pt border inset.
            let expectedWidth = 414 - 2 * AIReadingScrollMetrics.horizontalInset - AIReadingScrollMetrics.gutterWidth - 6
            require(abs(area.width - expectedWidth) < 0.5,
                    "\(name) reserves a complete scrollbar gutter even for empty or short content (\(area.width), expected \(expectedWidth))")
            if let sharedSelectorWidth {
                require(abs(area.width - sharedSelectorWidth) < 0.5, "all three AI panels use the same selector width")
            } else { sharedSelectorWidth = area.width }
            let start = paintedHighlight(area)
            // Each rasterized edge can round independently. Compare every frame with
            // the actual cell width, not with a first bitmap that has its own rounding bias.
            require(abs(start.width - cellWidth) < 2,
                    "\(name) initially paints a full cell-width highlight")
            if name == "notes" {
                reading.store.putAll(notes)
                try await Task.sleep(for: .milliseconds(150))
                require(abs(rect(left).width - originalLeft.width) < 0.5 && abs(rect(right).midX - originalRight.midX) < 0.5
                        && abs(rect(left).minY - originalLeft.minY) < 0.5,
                        "a long notes list does not change its sort selector's geometry")
            }
            for (direction, target) in [(1, right), (-1, left)] {
                let began = ProcessInfo.processInfo.systemUptime
                click(target)
                let deadline = ProcessInfo.processInfo.systemUptime + 0.3
                var samples: [(CGFloat, CGFloat)] = []
                var geometryError: CGFloat = 0, labelError: CGFloat = 0
                var frames: [(TimeInterval, NSBitmapImageRep)] = []
                var captureCosts: [TimeInterval] = []
                while ProcessInfo.processInfo.systemUptime < deadline {
                    let l = rect(left), r = rect(right)
                    geometryError = max(geometryError, abs(l.width - originalLeft.width), abs(r.midX - originalRight.midX))
                    let captureBegan = ProcessInfo.processInfo.systemUptime
                    frames.append((captureBegan - began, captureSelector(area)))
                    captureCosts.append(ProcessInfo.processInfo.systemUptime - captureBegan)
                    // Raster capture already consumes part of a display interval. Yield to
                    // SwiftUI without adding another fixed 8 ms to each observed frame.
                    try await Task.sleep(for: .milliseconds(1))
                }
                // Decode after the motion. Per-pixel sRGB/ink analysis on the main actor
                // would otherwise delay the very SwiftUI frames this check is observing.
                for frame in frames {
                    let painted = paintedHighlight(area, bitmap: frame.1)
                    samples.append((painted.center, painted.width))
                    for (initial, current) in zip(start.labels, painted.labels) {
                        labelError = max(labelError, abs(initial.minX - current.minX), abs(initial.maxX - current.maxX),
                                         abs(initial.minY - current.minY), abs(initial.maxY - current.maxY))
                    }
                }
                let end = samples.last!.0
                let previous = direction == 1 ? start.center : originalRight.midX - area.minX
                let low = min(previous, end) + 8, high = max(previous, end) - 8
                let intermediate = Set(samples.filter { $0.0 > low && $0.0 < high }.map { Int($0.0.rounded()) })
                print("INFO: \(name) direction \(direction) captured \(frames.count) frames before pixel analysis")
                print("INFO: \(name) highlight widths start=\(start.width) samples=\(samples.map(\.1))")
                let trace = zip(frames, zip(captureCosts, samples)).map { frame, measurement in
                    String(format: "%.1f/%.1f/%.1f", frame.0 * 1000, measurement.0 * 1000, measurement.1.0)
                }
                print("INFO: \(name) time_ms/capture_ms/center_pt=\(trace.joined(separator: ","))")
                require(geometryError < 0.5, "\(name) labels keep their positions when content gains or loses a scrollbar (error \(geometryError) pt)")
                require(labelError <= 1, "\(name) keeps painted icon/text bounds fixed throughout the slide (error \(labelError) pt)")
                require(intermediate.count >= 3, "\(name) paints multiple intermediate highlight positions in direction \(direction) (\(intermediate.count))")
                require(samples.allSatisfy { abs($0.1 - cellWidth) < 2 },
                        "\(name) moves one cell-width gold block without cross-fading (expected \(cellWidth) pt)")
                if let folder = ProcessInfo.processInfo.environment["LYRA_AI_EVIDENCE"] {
                    let directory = URL(fileURLWithPath: folder).appendingPathComponent("selector-\(name)-\(direction)")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for (index, frame) in frames.enumerated() {
                        guard let png = frame.1.representation(using: .png, properties: [:]) else { fail("FAIL: selector frame is encodable") }
                        try png.write(to: directory.appendingPathComponent(String(format: "%03d.png", index)))
                    }
                    try JSONSerialization.data(withJSONObject: frames.map(\.0)).write(to: directory.appendingPathComponent("times.json"))
                }
                try captureReadingInteraction(host, name: "selector-\(name)-\(direction)")
            }
            ReaderMotion.reduceMotionOverride = true; appearance.reduced = true
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded(); scrollers(host, style: .legacy)
            try await Task.sleep(for: .milliseconds(80))
            click(right)
            try await Task.sleep(for: .milliseconds(40))
            require(abs(paintedHighlight(area).center - (originalRight.midX - area.minX)) < 2,
                    "\(name) switches immediately with Reduce Motion")
            ReaderMotion.reduceMotionOverride = false; appearance.reduced = false
            try await Task.sleep(for: .milliseconds(100))
            scrollers(host, style: .overlay)
            try await Task.sleep(for: .milliseconds(150))
            require(abs(rect(left).width - originalLeft.width) < 0.5 && abs(rect(right).midX - originalRight.midX) < 0.5,
                    "\(name) reserves the same width when the system uses overlay scrollbars")
            click(left); try await Task.sleep(for: .milliseconds(250))
            require(abs(rect(left).width - originalLeft.width) < 0.5 && abs(rect(right).midX - originalRight.midX) < 0.5,
                    "\(name) keeps the reserved overlay gutter when switching between empty and populated results")
        }
    }
}

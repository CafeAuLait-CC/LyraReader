import AppKit
import Combine
import LyraReaderKit
import SwiftUI

@MainActor private final class SidePanelInteractionState: ObservableObject {
    @Published var visible = true
    @Published var width: CGFloat = 414
    var begins = 0
    var ends = 0
}

private final class SidePanelBodyMarker: NSView {}
private struct SidePanelBodyProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> SidePanelBodyMarker { SidePanelBodyMarker() }
    func updateNSView(_ view: SidePanelBodyMarker, context: Context) {}
}

private struct SidePanelInteractionView: View {
    @ObservedObject var model: SidePanelInteractionState
    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear
            ReaderSidePanel(isVisible: model.visible, contentWidth: model.width,
                onResizeBegan: { model.begins += 1 },
                onResize: { if abs(model.width - $0) > 0.01 { model.width = $0 } },
                onResizeEnded: { model.ends += 1 }) {
                    HStack(spacing: 0) {
                        Color(red: 0, green: 1, blue: 0).frame(width: 12)
                        ScrollView { Text("Panel content").padding(16).frame(maxWidth: .infinity) }
                    }.background(Color.gray)
                        .background(SidePanelBodyProbe())
                }
        }.animation(.linear(duration: 0.6), value: model.visible)
    }
}

extension ReaderChecks {
    @MainActor static func sidePanelInteractionChecks() async throws {
        func verify(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "SidePanelInteractionChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
            print("PASS: \(message)")
        }
        let model = SidePanelInteractionState()
        let host = NSHostingView(rootView: SidePanelInteractionView(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let value = view as? T { return value }
            return view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        try await eventually("the interaction fixture lays out its side panel", {
            host.layoutSubtreeIfNeeded()
            return find(ReaderSidePanelMarkerView.self, in: host)?.bounds.width ?? 0 > 400
        })
        let panel = find(ReaderSidePanelMarkerView.self, in: host)!
        let body = find(SidePanelBodyMarker.self, in: host)!
        let base = model.width
        let panelRect = host.convert(panel.bounds, from: panel)
        try await Task.sleep(for: .milliseconds(200))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let colors = (0..<bitmap.pixelsWide).compactMap { bitmap.colorAt(x: $0, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) }
            try verify(colors.contains { $0.greenComponent > 0.8 && $0.greenComponent - $0.redComponent > 0.3 && $0.greenComponent - $0.blueComponent > 0.4 }, "the settled fixture draws its content stripe")
        } else {
            try verify(false, "the fixture can capture rendered content")
        }
        let start = CGPoint(x: panelRect.minX + 3, y: panelRect.midY)
        var eventNumber = 1
        func mouse(_ type: NSEvent.EventType, delta: CGFloat) {
            let location = host.convert(CGPoint(x: start.x + delta, y: start.y), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            eventNumber += 1
            window.sendEvent(event)
        }
        mouse(.leftMouseDown, delta: 0)
        try await Task.sleep(for: .milliseconds(100))
        mouse(.leftMouseDragged, delta: 0)
        try await Task.sleep(for: .milliseconds(50))
        try verify(model.begins == 1, "window events engage the panel resize handle")
        for delta in [-8.0, -16, -24, -32, -40, -48, -40, -24, -8, 0] {
            mouse(.leftMouseDragged, delta: delta)
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            try verify(abs(model.width - (base - delta)) < 1,
                    "a moving resize handle uses stable window coordinates (delta \(delta), width \(model.width), expected \(base - delta))")
        }
        mouse(.leftMouseUp, delta: 0)
        try await Task.sleep(for: .milliseconds(50))
        try verify(model.begins == 1 && model.ends == 1,
                "real pointer events begin and end exactly one resize gesture")

        // Sample the actual animation, not just the deterministic progress override. A fixed
        // content origin behind an expanding clip would pass width-only checks.
        model.visible = false
        try await eventually("the interaction panel closes", { panel.bounds.width < 0.5 })
        model.visible = true
        var partialFrames = 0
        var maximumFrameError: CGFloat = 0
        var maximumDrawingError: CGFloat = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(12))
            host.layoutSubtreeIfNeeded()
            let frame = host.convert(panel.bounds, from: panel)
            let content = host.convert(body.bounds, from: body)
            let total = ReaderSidePanelMetrics.totalWidth(contentWidth: model.width)
            if frame.width > 20 && frame.width < total - 20 {
                partialFrames += 1
                maximumFrameError = max(maximumFrameError, abs(content.minX - frame.minX - 7))
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let row = bitmap.pixelsHigh / 2
                    let green = (0..<bitmap.pixelsWide).first { x in
                        guard let color = bitmap.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) else { return false }
                        return color.greenComponent > 0.8 && color.greenComponent - color.redComponent > 0.3 && color.greenComponent - color.blueComponent > 0.4
                    }
                    try verify(green != nil, "the intermediate frame draws its content stripe (panel \(frame), content \(content))")
                    let drawnX = CGFloat(green!) * host.bounds.width / CGFloat(bitmap.pixelsWide)
                    maximumDrawingError = max(maximumDrawingError, abs(drawnX - frame.minX - 7))
                } else {
                    try verify(false, "the intermediate frame can capture rendered content")
                }
            }
        }
        try verify(partialFrames > 2, "the opening check observes intermediate content positions")
        try verify(maximumFrameError < 1, "native content moves with the panel edge (maximum error \(maximumFrameError))")
        try verify(maximumDrawingError < 2, "rendered content moves with the panel edge (maximum error \(maximumDrawingError))")
    }
}

import AppKit
import SwiftUI
@testable import LyraReaderKit

@MainActor private final class ToolbarMotionModel: ObservableObject {
    @Published var width: CGFloat = 1100
    var markers: [String: NSView] = [:]
}

private struct ToolbarMotionMarker: NSViewRepresentable {
    let id: String
    let model: ToolbarMotionModel
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        model.markers[id] = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { model.markers[id] = view }
}

private struct ToolbarMotionRow: View {
    @ObservedObject var model: ToolbarMotionModel
    var body: some View {
        ReaderSecondaryRow {
            HStack(spacing: ReaderSecondaryRowMetrics.itemSpacing) {
                Button {} label: {
                    Label("Active tool", systemImage: "signature")
                        .background(ToolbarMotionMarker(id: "active", model: model))
                        // Pressed/selected Button updates can replace the label transaction.
                        // Reproduce that isolation instead of merely calling the tool action.
                        .transaction { $0.animation = nil }
                }.lyraToolStyle(selected: model.width < 1100)
                Button {} label: {
                    Label("Neighbor", systemImage: "calendar")
                        .background(ToolbarMotionMarker(id: "neighbor", model: model))
                }.lyraToolStyle()
            }
        }
        .frame(width: model.width)
        .animation(ReaderMotion.panelAnimation, value: model.width)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ReaderChecks {
    @MainActor static func toolbarMotionChecks(root: URL) async throws {
        _ = NSApplication.shared
        let savedMotion = ReaderMotion.reduceMotionOverride
        ReaderMotion.reduceMotionOverride = false
        defer { ReaderMotion.reduceMotionOverride = savedMotion }
        let model = ToolbarMotionModel()
        let host = NSHostingView(rootView: ToolbarMotionRow(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await eventually("both toolbar motion markers are mounted", {
            host.layoutSubtreeIfNeeded()
            return model.markers.count == 2
        })
        try await Task.sleep(for: .milliseconds(300))
        func positions() -> (CGFloat, CGFloat) {
            host.layoutSubtreeIfNeeded()
            let active = model.markers["active"]!
            let neighbor = model.markers["neighbor"]!
            return (host.convert(active.bounds, from: active).minX,
                    host.convert(neighbor.bounds, from: neighbor).minX)
        }
        let initial = positions()
        let gap = initial.1 - initial.0
        for target: CGFloat in [800, 1100] {
            model.width = target
            let deadline = ProcessInfo.processInfo.systemUptime + 0.38
            var intermediate: Set<Int> = []
            var maximumGapError: CGFloat = 0
            while ProcessInfo.processInfo.systemUptime < deadline {
                let (active, neighbor) = positions()
                maximumGapError = max(maximumGapError, abs(neighbor - active - gap))
                intermediate.insert(Int((active * 2).rounded()))
                try await Task.sleep(for: .milliseconds(8))
            }
            require(maximumGapError < 0.75,
                    "the isolated active label follows its neighbor throughout the slide (error \(maximumGapError) pt)")
            require(intermediate.count >= 4,
                    "the toolbar moves through intermediate positions in both directions")
        }
        ReaderMotion.reduceMotionOverride = true
        model.width = 800
        try await Task.sleep(for: .milliseconds(60))
        let reduced = positions()
        require(abs(reduced.0 - (initial.0 - 150)) < 0.75,
                "Reduce Motion places the entire tool group at its destination immediately")
    }
}

import AppKit
import Foundation
import LyraReaderKit
import QuartzCore
import SwiftUI

extension ReaderChecks {
    /// Keep a closed native host and its callback alive deliberately: AppKit may do the same.
    /// Its lifetime must not give it ownership of a later preview's viewport.
    @MainActor static func previewLifecycleChecks(root: URL) async throws {
        _ = NSApplication.shared
        let state = AppState(engine: try RustEngine())
        let panels = ReferencePreviewPanelController()
        let host = NSHostingView(rootView: ReaderWindow(
            state: state, opener: DocumentOpenCoordinator(state: state), previewPanels: panels))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1100, height: 750),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { state.closeReferencePreview(); panels.close(); window.orderOut(nil) }
        require(state.open(url: root.appendingPathComponent("tests/fixtures/cross-references.pdf")),
                "preview lifecycle fixture opens")
        let readerOffset = state.scrollYPt
        func canvas(_ view: NSView?) -> MetalCanvasView? {
            guard let view else { return nil }
            if let found = view as? MetalCanvasView { return found }
            return view.subviews.lazy.compactMap { canvas($0) }.first
        }
        let region = CGRect(x: 72, y: 100, width: 430, height: 200)
        func open(_ title: String, kind: AppState.ReferencePreviewKind = .figure,
                  entries: [AppState.CitationEntry] = []) {
            state.openReferencePreview(page: 0, title: title, from: "page 1", kind: kind,
                                       region: region, entries: entries)
        }
        func ready() async throws -> MetalCanvasView {
            try await eventually("current native preview fits its actual viewport", {
                host.layoutSubtreeIfNeeded()
                panels.panel?.contentView?.layoutSubtreeIfNeeded()
                guard let panel = panels.panel, panel.isVisible, panel.parent === window,
                      let view = canvas(panel.contentView), view.bounds.width > 0,
                      let image = state.referencePreviewPages.first?.image,
                      !state.referencePreviewLoading else { return false }
                return abs(state.referencePreviewZoom * image.pointSize.width - view.bounds.width) < 0.001
                    && abs(view.zoom - state.referencePreviewZoom) < 0.001
                    && view.hasAttachedSurface
            })
            return canvas(panels.panel?.contentView)!
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for iteration in 0..<3 {
                open("Single", kind: .reference, entries: [.init(label: "1", text: "A short work.")])
                try await eventually("short citation mounts in a native panel", {
                    panels.panel?.isVisible == true && panels.panel!.frame.height < 160
                })
                open("Group", kind: .reference, entries: (1...3).map {
                    .init(label: "\($0)", text: "Author. A synthetic reference title. 2026.")
                })
                try await eventually("group replaces single", { panels.model.entries.count == 3 })
                let oldPanel = panels.panel!
                oldPanel.applyUserFrame(CGRect(x: 150, y: 180, width: 600, height: 360))
                oldPanel.applyUserFrame(oldPanel.frame.offsetBy(dx: 40, dy: 30))
                let oldContent = oldPanel.contentView!
                let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: oldPanel.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53)!
                oldPanel.keyDown(with: escape)
                require(!oldPanel.isVisible && oldPanel.parent == nil && oldPanel.contentView == nil,
                        "closing unmounts the old observer even when AppKit retains its panel")
                open("Figure \(iteration)")
                let view = try await ready()
                oldContent.layoutSubtreeIfNeeded()
                require(canvas(oldContent) == nil,
                        "a closed citation host cannot create a competing figure canvas")
                let staleViewport = view.onViewportSize!
                let oldZoom = state.referencePreviewZoom
                open("Replacement \(iteration)")
                let replacement = try await ready()
                staleViewport(CGSize(width: 913, height: 300))
                require(!state.referencePreviewLoading && !state.referencePreviewPages.isEmpty
                            && abs(state.referencePreviewZoom - oldZoom) < 0.001,
                        "a replaced body cannot overwrite the current preview viewport")
                let closedViewport = replacement.onViewportSize!
                state.closeReferencePreview()
                try await eventually("state close unmounts its panel", { panels.panel == nil })
                // Equal content reopened in a new panel still has a different owner.
                open("Replacement \(iteration)")
                let reopened = try await ready()
                closedViewport(CGSize(width: 997, height: 300))
                require(!state.referencePreviewLoading && !state.referencePreviewPages.isEmpty,
                        "a closed panel cannot claim an equal-content preview in a new panel")
                for width: CGFloat in [620, 480, 600] {
                    panels.panel!.applyUserFrame(CGRect(x: 150, y: 180, width: width, height: 360))
                }
                let resized = try await ready()
                require((resized.layer as? CAMetalLayer)?.colorspace?.name == CGColorSpace.sRGB,
                        "resizing the crop surface preserves its explicit sRGB declaration")
                let expected = resized.bounds.width / region.width
                require(abs(state.referencePreviewZoom - expected) < 0.001,
                        "rapid resize fits the final live bounds without right-edge clipping")
                require(reopened.window === resized.window && state.scrollYPt == readerOffset,
                        "preview close, replace and resize preserve the reader's location")
                state.closeReferencePreview()
                try await eventually("repeat ends with no preview", { panels.panel == nil })
            }
        }
    }

    /// Verify native profile selection and unchanged transparent source bytes. Actual dark ink
    /// coverage and colour are also checked by the GPU offscreen regression and native captures.
    @MainActor static func previewPaperChecks(root: URL) async throws {
        let state = AppState(engine: try RustEngine())
        require(state.open(url: root.appendingPathComponent("tests/fixtures/alpha-crop.pdf")),
                "preview paper fixture opens")
        let panels = ReferencePreviewPanelController()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ReaderWindow(
            state: state, opener: DocumentOpenCoordinator(state: state), previewPanels: panels))
        window.contentView = host
        window.orderFrontRegardless()
        let appearance = ReadingAppearanceStore.shared
        let saved = appearance.mode
        defer { state.closeReferencePreview(); panels.close(); window.orderOut(nil); appearance.mode = saved }
        func canvas(_ view: NSView?) -> MetalCanvasView? {
            guard let view else { return nil }
            if let found = view as? MetalCanvasView { return found }
            return view.subviews.lazy.compactMap { canvas($0) }.first
        }
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: theme)
            for mode in PaperAppearance.allCases {
                appearance.mode = mode
                state.openReferencePreview(page: 0, title: "Original scientific tones", from: "page 1",
                    kind: .figure, region: CGRect(x: 0, y: 0, width: 595, height: 400))
                try await eventually("transparent raster reaches the real figure canvas", {
                    host.layoutSubtreeIfNeeded()
                    panels.panel?.contentView?.layoutSubtreeIfNeeded()
                    guard let view = canvas(panels.panel?.contentView) else { return false }
                    return view.hasAttachedSurface && !state.referencePreviewLoading
                        && !state.referencePreviewPages.isEmpty
                })
                let view = canvas(panels.panel?.contentView)!
                require(view.paperAppearance == .original,
                        "scientific colours remain original under \(theme) / \(mode)")
                let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                require(view.adaptsFigureInkToAppearance && view.renderingAppearanceCode == (dark ? 3 : 4),
                        "scientific crops select dark ink or light edge compositing")
                require((view.layer as? CAMetalLayer)?.colorspace?.name == CGColorSpace.sRGB,
                        "the native crop layer declares its source sRGB colour space")
                var background = NSColor.black
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    background = view.canvasClearColor!.usingColorSpace(.sRGB)!
                }
                let image = state.referencePreviewPages[0].image
                let scale = CGFloat(image.pixelWidth) / image.pointSize.width
                func sample(_ x: CGFloat, _ y: CGFloat) -> [CGFloat] {
                    let offset = (Int(y * scale) * image.pixelWidth + Int(x * scale)) * 4
                    return image.bgra.withUnsafeBytes { raw in
                        let b = raw.bindMemory(to: UInt8.self)
                        let alpha = CGFloat(b[offset + 3]) / 255
                        let red = CGFloat(b[offset + 2]) / 255 * alpha + background.redComponent * (1 - alpha)
                        let green = CGFloat(b[offset + 1]) / 255 * alpha + background.greenComponent * (1 - alpha)
                        let blue = CGFloat(b[offset]) / 255 * alpha + background.blueComponent * (1 - alpha)
                        return [red, green, blue]
                    }
                }
                let expectedBackground: [CGFloat] = dark
                    ? [52.0 / 255, 48.0 / 255, 41.0 / 255]
                    : [1, 253.0 / 255, 250.0 / 255]
                require(zip(sample(560, 100), expectedBackground).allSatisfy { abs($0.0 - $0.1) < 0.001 },
                        "transparent paper blends into the original light or dark card")
                let samples: [(CGFloat, CGFloat, CGFloat)] = [
                    (132, 112, 242.0 / 255), (132, 212, 204.0 / 255),
                    (300, 212, 128.0 / 255), (468, 212, 0)
                ]
                for (x, y, expected) in samples {
                    require(sample(x, y).allSatisfy { abs($0 - expected) < 0.02 },
                            "the real figure raster retains source tone \(expected)")
                }
                state.closeReferencePreview()
                try await eventually("paper check unmounts the figure", { panels.panel == nil })
            }
        }
        appearance.mode = .original
        state.openReferencePreview(page: 0, title: "Live theme switch", from: "page 1",
            kind: .figure, region: CGRect(x: 0, y: 0, width: 595, height: 400))
        try await eventually("theme-switch crop is ready", {
            !state.referencePreviewLoading && !state.referencePreviewPages.isEmpty
                && canvas(panels.panel?.contentView) != nil
        })
        let source = state.referencePreviewPages[0].image
        for theme in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
            window.appearance = NSAppearance(named: theme)
            panels.sync(state: state, parentWindow: window)
            try await eventually("theme switch updates the existing figure surface", {
                panels.panel?.contentView?.layoutSubtreeIfNeeded()
                guard let view = canvas(panels.panel?.contentView) else { return false }
                return view.renderingAppearanceCode == (theme == .darkAqua ? 3 : 4)
            })
            require(state.referencePreviewPages[0].image.generation == source.generation
                        && state.referencePreviewPages[0].image.bgra == source.bgra,
                    "theme switching reuses untouched source pixels")
        }
    }
}

import AppKit
import SwiftUI
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func aiTranslationDisclosureChecks() async throws {
        let original = String(repeating: "A synthetic original passage retains its opening while keeping the complete source available. ", count: 16)
        let content = "<!--lyra:0-->\n$$\nc_k = W_c u_k + e_{\\tau}(\\tau_k). \\tag{3}\n$$\n\n"
            + String(repeating: "合成译文用于检查长段落折叠、独立展开和下方重试按钮的可点击性。", count: 24)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 414, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        for dark in [false, true] {
            for width in [414, 320] {
                var retries: [String] = [], collapses = 0
                let host = NSHostingView(rootView: ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        AITranslationBlocks(originals: [original], pages: [1], content: content,
                            showOriginal: true, verifiedPages: [1], pageCount: 1, onLocate: { _, _ in }, onJump: { _ in },
                            recordID: "long", onCollapse: { collapses += 1 }, onRetry: { retries.append("long") })
                        Divider()
                        AITranslationBlocks(originals: ["Short original"], pages: [1], content: "<!--lyra:0-->简短译文。",
                            showOriginal: true, verifiedPages: [1], pageCount: 1, onLocate: { _, _ in }, onJump: { _ in },
                            recordID: "short", onRetry: { retries.append("short") })
                    }.padding(18)
                }.environment(\.readingStableTextLayout, true)
                    .foregroundStyle(LyraReaderTheme.textPrimary).background(LyraReaderTheme.panelBg)
                    .preferredColorScheme(dark ? .dark : .light))
                window.contentView = host; window.setContentSize(NSSize(width: width, height: 850))
                window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
                func markers(_ view: NSView) -> [AITranslationControlMarker] {
                    (view as? AITranslationControlMarker).map { [$0] } ?? view.subviews.flatMap(markers)
                }
                func marker(_ id: String) -> AITranslationControlMarker {
                    host.layoutSubtreeIfNeeded()
                    guard let result = markers(host).first(where: { $0.id == id }) else { fail("FAIL: missing translation disclosure control \(id)") }
                    return result
                }
                func click(_ id: String) async throws {
                    let target = marker(id)
                    if let scroll = target.enclosingScrollView, let document = scroll.documentView {
                        let area = target.convert(target.bounds, to: document)
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, area.midY - scroll.contentView.bounds.height / 2)))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    try await Task.sleep(for: .milliseconds(40))
                    let rect = target.convert(target.bounds, to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        window.sendEvent(NSEvent.mouseEvent(with: type, location: CGPoint(x: rect.midX, y: rect.midY),
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
                print("INFO: translation disclosure controls \(markers(host).map { "\($0.id):\($0.bounds.height)" }.sorted())")
                try captureReadingInteraction(host, name: "translation-disclosure-initial-\(width)-\(dark ? "dark" : "light")")
                try await eventually("long originals and translations expose independent disclosure controls", {
                    host.layoutSubtreeIfNeeded()
                    let ids = Set(markers(host).map(\.id))
                    return ids.contains("original-more-long-0") && ids.contains("result-more-long")
                })
                func textViews(_ view: NSView) -> [NSTextView] {
                    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
                }
                let rendered = textViews(host).first { $0.string.contains("合成译文") }!
                require(abs((rendered.textContainer?.containerSize.width ?? 0) - rendered.bounds.width) < 1
                        && rendered.bounds.width > CGFloat(width) - 70,
                        "the visible translation uses the complete available width in TextKit (view \(rendered.bounds.width), container \(rendered.textContainer?.containerSize.width ?? 0))")
                let sourceHeight = marker("original-preview-long-0").bounds.height
                let resultHeight = marker("translated-preview-long-0").bounds.height
                require(sourceHeight < 100 && resultHeight <= 181, "long originals start at three lines and translations have a compact preview")
                require(!markers(host).contains { ["original-more-short-0", "result-more-short"].contains($0.id) },
                        "short originals and translations need no disclosure buttons")
                try captureReadingInteraction(host, name: "translation-compact-\(width)-\(dark ? "dark" : "light")")
                try await click("original-more-long-0")
                try await eventually("original More expands only the original source", {
                    marker("original-preview-long-0").bounds.height > sourceHeight + 150
                        && abs(marker("translated-preview-long-0").bounds.height - resultHeight) < 1
                })
                try captureReadingInteraction(host, name: "translation-original-expanded-\(width)-\(dark ? "dark" : "light")")
                try await click("original-more-long-0")
                try await eventually("original Less restores its opening lines", { abs(marker("original-preview-long-0").bounds.height - sourceHeight) < 1 })
                try await click("result-more-long")
                try await eventually("translation More leaves the original collapsed", {
                    marker("translated-preview-long-0").bounds.height > resultHeight + 100
                        && abs(marker("original-preview-long-0").bounds.height - sourceHeight) < 1
                })
                try await click("result-more-long")
                try await eventually("translation Less restores the compact preview", { abs(marker("translated-preview-long-0").bounds.height - resultHeight) < 1 })
                require(collapses == 2, "both Less controls notify the parent to keep the result in view")
                try await click("result-retry-long")
                try await click("result-retry-short")
                require(retries == ["long", "short"], "clipped native math and text cannot intercept either result's Retry button")
            }
        }
        print("PASS: independent original/translation disclosure, compact Retry and adjacent native hit testing at both sidebar widths and appearances")
    }
}

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
                var retries: [String] = [], collapses = 0, located: [UInt32] = []
                let host = NSHostingView(rootView: ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        AITranslationBlocks(originals: [original], pages: [1], content: content,
                            showOriginal: true, verifiedPages: [1], pageCount: 1, onLocate: { page, _ in located.append(page) }, onJump: { _ in },
                            recordID: "long", onCollapse: { collapses += 1 }, onRetry: { retries.append("long") })
                        Divider()
                        AITranslationBlocks(originals: ["Short original"], pages: [1], content: "<!--lyra:0-->简短译文。",
                            showOriginal: true, verifiedPages: [1], pageCount: 1, onLocate: { _, _ in }, onJump: { _ in },
                            recordID: "short", onRetry: { retries.append("short") })
                        Divider()
                        AITranslationBlocks(originals: ["Equation source", "Another source"], pages: [1, 1],
                            content: "<!--lyra:0-->\\[x=1\\tag{3}\\]\n<!--lyra:1-->Another paragraph.",
                            showOriginal: true, verifiedPages: [1], pageCount: 1, onLocate: { _, _ in }, onJump: { _ in },
                            recordID: "equation", onRetry: { retries.append("equation") })
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
                func frame(_ id: String) -> CGRect {
                    let view = marker(id); return host.convert(view.bounds, from: view)
                }
                let sourceMore = frame("original-more-long-0"), resultMore = frame("result-more-long")
                let retry = frame("result-retry-long"), result = frame("translated-preview-long-0")
                // Native icon and text controls can differ in height. Compare their shared
                // row, allowing one backing pixel for AppKit frame rounding at either scale.
                let pixel = 1 / window.backingScaleFactor
                print("INFO: inline controls scale=\(window.backingScaleFactor) preview=\(result) more=\(resultMore) retry=\(retry)")
                let originalView = textViews(host).first { $0.string == original }!
                let layout = originalView.layoutManager!, container = originalView.textContainer!
                var originalLines: [CGRect] = []
                layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, used, _, _, stop in
                    originalLines.append(host.convert(used.offsetBy(dx: originalView.textContainerOrigin.x,
                        dy: originalView.textContainerOrigin.y), from: originalView))
                    if originalLines.count == 3 { stop.pointee = true }
                }
                require(originalLines.count == 3 && sourceMore.minY >= originalLines[2].minY - 1
                        && sourceMore.maxY <= originalLines[2].maxY + 1
                        && frame("original-preview-long-0").contains(sourceMore),
                        "original More stays inside its third text line instead of adding another row")
                require(result.insetBy(dx: -pixel, dy: -pixel).contains(resultMore),
                        "translation More stays in its last visible text line")
                let footer = frame("result-source-long-0")
                require(footer.insetBy(dx: -pixel, dy: -pixel).contains(retry)
                        && abs(footer.maxX - retry.maxX) <= pixel && retry.minY > result.maxY,
                        "long translations keep right-aligned Retry on the page row, separate from More")
                require(frame("result-source-short-0").insetBy(dx: -pixel, dy: -pixel).contains(frame("result-retry-short")),
                        "a short translation keeps Retry on its source row without a separate action row")
                require(frame("result-source-equation-0").insetBy(dx: -pixel, dy: -pixel).contains(frame("result-more-equation"))
                        && frame("result-source-equation-0").insetBy(dx: -pixel, dy: -pixel).contains(frame("result-retry-equation")),
                        "an equation-only ending keeps its complete formula and shares the source row for actions")
                require(originalView.string == original && container.containerSize.width == originalView.bounds.width,
                        "inline truncation retains the complete selectable original and its real layout width")
                require(!markers(host).contains { ["original-more-short-0", "result-more-short"].contains($0.id) },
                        "short originals and translations need no disclosure buttons")
                try captureReadingInteraction(host, name: "translation-compact-\(width)-\(dark ? "dark" : "light")")
                try await click("original-more-long-0")
                try await eventually("original More expands only the original source", {
                    markers(host).contains { $0.id == "original-more-long-0" }
                        && marker("original-preview-long-0").bounds.height > sourceHeight + 150
                        && abs(marker("translated-preview-long-0").bounds.height - resultHeight) < 1
                })
                let sourceLess = frame("original-more-long-0")
                require(originalView.string.replacingOccurrences(of: "\u{00a0}" + aiReadingLabel("Less"), with: "") == original,
                        "expanded source retains every original character before its trailing disclosure")
                requireInlineTail(originalView, marker: marker("original-more-long-0"), host: host)
                require(frame("original-preview-long-0").insetBy(dx: -pixel, dy: -pixel).contains(sourceLess),
                        "source Less belongs to the expanded text rather than a separate row")
                try captureReadingInteraction(host, name: "translation-original-expanded-\(width)-\(dark ? "dark" : "light")")
                try await click("original-more-long-0")
                try await eventually("original Less restores its opening lines", { abs(marker("original-preview-long-0").bounds.height - sourceHeight) < 1 })
                try await click("result-more-long")
                try await eventually("translation More leaves the original collapsed", {
                    markers(host).contains { $0.id == "result-more-long" }
                        && marker("translated-preview-long-0").bounds.height > resultHeight + 100
                        && abs(marker("original-preview-long-0").bounds.height - sourceHeight) < 1
                })
                requireInlineTail(rendered, marker: marker("result-more-long"), host: host)
                require(frame("result-source-long-0").insetBy(dx: -pixel, dy: -pixel).contains(frame("result-retry-long")),
                        "expanded translations also keep Retry on the page row")
                try captureReadingInteraction(host, name: "translation-result-expanded-\(width)-\(dark ? "dark" : "light")")
                try await click("result-more-long")
                try await eventually("translation Less restores the compact preview", { abs(marker("translated-preview-long-0").bounds.height - resultHeight) < 1 })
                require(collapses == 2, "both Less controls notify the parent to keep the result in view")
                try await click("result-page-long-0")
                require(located == [1], "the page-only source link remains clickable")
                try await click("result-retry-long")
                try await click("result-retry-short")
                try await click("result-retry-equation")
                require(retries == ["long", "short", "equation"], "clipped native math and text cannot intercept any result's Retry button")
            }
        }
        print("PASS: independent original/translation disclosure, inline Less, page-row Retry and adjacent native hit testing at both sidebar widths and appearances")
    }
    @MainActor private static func requireInlineTail(_ text: NSTextView, marker: NSView, host: NSView) {
        let layout = text.layoutManager!, container = text.textContainer!
        layout.ensureLayout(for: container)
        let suffix = (text.string as NSString).range(of: "\u{00a0}" + aiReadingLabel("Less"), options: .backwards)
        require(suffix.location != NSNotFound && suffix.location > 0, "expanded text retains a trailing disclosure after its source")
        let glyph = layout.glyphIndexForCharacter(at: suffix.location + 1)
        let preceding = layout.glyphIndexForCharacter(at: suffix.location - 1)
        require(layout.lineFragmentRect(forGlyphAt: preceding, effectiveRange: nil).minY
                == layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY,
                "Less shares the final source word's line instead of wrapping onto its own row")
        let lastLine = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        let line = host.convert(lastLine, from: text), action = host.convert(marker.bounds, from: marker)
        require(action.minY >= line.minY - 1 && action.maxY <= line.maxY + 1
                && action.maxX <= line.maxX + 1 && action.minX >= line.minX - 1,
                "expanded Less is an inline button at the end of the complete final text line")
        require(action.width > 1 && action.height > 1,
                "the trailing disclosure has its own native button hit region")
    }
}

import AppKit
import SwiftUI

/// Native line geometry keeps disclosure controls on the actual text baseline, including
/// paragraphs containing formula attachments. The original selectable text stays intact.
struct TranslationInlinePreview<Content: View>: View {
    let collapsed: Bool
    var limit: CGFloat = 180
    var maximumLines: Int? = nil
    var additionalContent = false
    let moreID: String
    var reportsOverflow = true
    var onOverflowChange: ((Bool) -> Void)? = nil
    let onExpand: () -> Void
    var onCollapse: (() -> Void)? = nil
    let content: Content
    @State private var naturalHeight: CGFloat = 0
    @State private var lines = TranslationTailMetrics()
    private var hasMore: Bool {
        additionalContent || (maximumLines == nil ? naturalHeight > limit + 0.5 : lines.hiddenLines)
    }
    private var needsFooter: Bool {
        guard lines.measured else { return false }
        if !collapsed { return onCollapse != nil && lines.actionRect == nil }
        guard hasMore, maximumLines == nil else { return false }
        // An ending image/equation has no text baseline for a suffix. Keep it intact
        // and share its existing source row rather than covering the formula with controls.
        guard let line = lines.tail else { return true }
        return naturalHeight <= limit + 0.5 && naturalHeight > line.bottom + 8
    }
    private var visibleHeight: CGFloat {
        guard collapsed else { return naturalHeight }
        if let line = lines.tail, maximumLines != nil { return line.bottom }
        if let line = lines.tail, hasMore && !needsFooter { return min(limit, line.bottom) }
        return limit
    }
    var body: some View {
        TranslationPreviewLayout(limit: collapsed ? visibleHeight : nil) {
            content.environment(\.readerMarkdownTrailingAction, !collapsed && onCollapse != nil ?
                ReaderMarkdownTrailingAction(id: moreID, title: aiReadingLabel("Less")) : nil).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
        }.clipped().contentShape(Rectangle())
            .background {
                TranslationLineProbe(actionID: moreID, maximumLines: collapsed ? maximumLines : nil,
                    limit: collapsed ? limit : .greatestFiniteMagnitude) { lines = $0 }
            }
            .overlay(alignment: .topLeading) {
                if !collapsed, let rect = lines.actionRect, let onCollapse {
                    Button(action: onCollapse) { Color.clear.contentShape(Rectangle()) }
                        .buttonStyle(.plain).frame(width: rect.width, height: rect.height)
                        .accessibilityLabel(aiReadingLabel("Less")).accessibilityValue(aiReadingLabel("Expanded"))
                        .overlay(AITranslationControlProbe(id: moreID, clickable: true))
                        .modifier(TranslationPointingHand())
                        .offset(x: rect.minX, y: rect.minY)
                }
                if collapsed && hasMore && lines.measured && !needsFooter {
                    TranslationInlineActions(line: lines.tail, fallbackHeight: visibleHeight) {
                        LyraReaderTheme.panelBg.allowsHitTesting(false).accessibilityHidden(true)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("…").foregroundStyle(LyraReaderTheme.textSecondary)
                            Button(aiReadingLabel("More"), action: onExpand)
                                .accessibilityValue(aiReadingLabel("Collapsed"))
                                .accessibilityIdentifier(moreID == "excerpt-more" ? "translation-excerpt-more" : moreID)
                                .overlay(AITranslationControlProbe(id: moreID, clickable: true))
                                .modifier(TranslationPointingHand())
                        }.fixedSize()
                    }.font(.system(size: 11)).foregroundStyle(LyraReaderTheme.accent).buttonStyle(.plain)
                }
            }
            .onChange(of: hasMore) { _, value in onOverflowChange?(value) }
            .preference(key: TranslationPreviewOverflow.self, value: reportsOverflow && hasMore)
            .preference(key: TranslationPreviewFooter.self, value: reportsOverflow && needsFooter)
    }
}

private struct TranslationTailLine: Equatable {
    let top: CGFloat
    let bottom: CGFloat
    let baseline: CGFloat
    let end: CGFloat
    let glyphEnds: [CGFloat]
}
private struct TranslationTailMetrics: Equatable {
    var tail: TranslationTailLine?
    var measured = false
    var hiddenLines = false
    var actionRect: CGRect?
}
struct TranslationPreviewOverflow: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
struct TranslationPreviewFooter: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The opaque suffix replaces only complete trailing glyphs on the last visible line.
/// Controls keep their own native hit regions and keyboard/accessibility semantics.
private struct TranslationInlineActions: Layout {
    let line: TranslationTailLine?
    let fallbackHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? fallbackHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let leading = subviews[1].dimensions(in: .unspecified)
        let capacity = max(0, bounds.width - leading.width)
        let end = line?.end ?? capacity
        let prefix = line?.glyphEnds.filter { $0 + 3 <= capacity }.max() ?? 0
        let x = end + 3 <= capacity ? end + 3 : min(capacity, prefix)
        let baseline = line?.baseline ?? max(0, bounds.height - 3)
        let top = line?.top ?? max(0, baseline - leading[.firstTextBaseline])
        subviews[0].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + top), anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width - x, height: max(0, bounds.height - top)))
        subviews[1].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + baseline - leading[.firstTextBaseline]),
            anchor: .topLeading, proposal: ProposedViewSize(width: leading.width, height: leading.height))
    }
}

/// Query only the owning native scroll document. Earlier clipped paragraphs can extend
/// behind a later row; their origins lie outside this viewport and are deliberately excluded.
private struct TranslationLineProbe: NSViewRepresentable {
    let actionID: String
    let maximumLines: Int?
    let limit: CGFloat
    let onChange: (TranslationTailMetrics) -> Void
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {
        view.actionID = actionID; view.maximumLines = maximumLines; view.limit = limit; view.onChange = onChange; view.schedule()
    }
    final class Marker: NSView {
        var actionID = ""
        var maximumLines: Int?
        var limit: CGFloat = 180
        var onChange: ((TranslationTailMetrics) -> Void)?
        private var pending = false
        private var previous = TranslationTailMetrics()
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func layout() { super.layout(); schedule() }
        func schedule() {
            guard !pending else { return }
            pending = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.pending = false; self.measure()
            }
        }
        private func measure() {
            guard window != nil, bounds.width > 1, bounds.height > 0,
                  let root = enclosingScrollView?.documentView ?? window?.contentView else { return }
            func textViews(_ view: NSView) -> [NSTextView] {
                (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
            }
            var candidates: [(NSTextView, NSRange, CGRect, CGFloat)] = []
            var hidden = false
            var actionRect: CGRect?
            for view in textViews(root) where !view.isHiddenOrHasHiddenAncestor {
                let rect = convert(view.bounds, from: view)
                guard rect.minY >= -0.5, rect.minY < bounds.height + 0.5,
                      rect.minX >= -0.5, rect.minX < bounds.width,
                      let layout = view.layoutManager, let container = view.textContainer else { continue }
                layout.ensureLayout(for: container)
                if let action = view.subviews.first(where: { $0 is ReaderMarkdownActionMarker && $0.identifier?.rawValue == actionID }) {
                    actionRect = convert(action.bounds, from: action)
                }
                var count = 0
                layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) {
                    fragment, used, _, glyphs, stop in
                    let local = self.convert(used.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view)
                    count += 1
                    if let maximumLines = self.maximumLines, count > maximumLines {
                        hidden = true; stop.pointee = true; return
                    }
                    guard self.maximumLines != nil || local.maxY <= self.limit + 0.5 else { stop.pointee = true; return }
                    let location = layout.location(forGlyphAt: glyphs.location)
                    let baseline = self.convert(CGPoint(x: 0, y: view.textContainerOrigin.y + fragment.minY + location.y), from: view).y
                    candidates.append((view, glyphs, local, baseline))
                }
            }
            let last = candidates.max { $0.3 == $1.3 ? $0.2.maxX < $1.2.maxX : $0.3 < $1.3 }
            var value = TranslationTailMetrics(measured: true, hiddenLines: hidden, actionRect: actionRect)
            if let (view, glyphs, rect, baseline) = last, let layout = view.layoutManager, let container = view.textContainer {
                let ends = (glyphs.location..<NSMaxRange(glyphs)).map { glyph in
                    let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                    return convert(glyphRect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y), from: view).maxX
                }
                value.tail = TranslationTailLine(top: rect.minY, bottom: rect.maxY, baseline: baseline, end: rect.maxX, glyphEnds: ends)
            }
            if value != previous { previous = value; onChange?(value) }
        }
    }
}

/// Measure and place rich content at the same width; only its visible viewport shrinks.
struct TranslationPreviewLayout: Layout {
    let limit: CGFloat?
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: limit.map { min($0, size.height) } ?? size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

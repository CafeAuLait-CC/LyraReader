import AppKit
import LyraReaderBindings
import SwiftUI

/// Native presentation of the Rust reading workspace and paragraph source map.
struct AITranslationView: View {
    @ObservedObject var state: AppState
    @ObservedObject var reading: AIReadingModel
    let isActive: Bool
    @State private var selectedTerm: String?
    @State private var trailingGutter = AIReadingScrollMetrics.initialAdditionalInset
    @ObservedObject private var knowledge: AIDocumentKnowledge

    init(state: AppState, reading: AIReadingModel, isActive: Bool = false) {
        self.state = state; self.reading = reading; self.isActive = isActive
        _knowledge = ObservedObject(wrappedValue: state.documentKnowledge)
    }
    private var worker: AIAssistantModel { reading.translation }
    private var busy: Bool { worker.isPreparing || worker.isSending || worker.phase == .preview || worker.phase == .mergePreview }
    private var records: [AiReadingRecord] { reading.store.translationHistory(selection: reading.translationSelection) }
    private var scrollKey: String { "\(state.document?.id.uuidString ?? "none"):translation-\(reading.translationSelection ? "selection" : "document")" }
    private var canRun: Bool {
        !busy && !knowledge.isBlocking && reading.store.isAvailable && reading.settings.canUseAI &&
        (!reading.translationSelection || !reading.excerpt("translation").isEmpty)
    }
    private var selectionObservation: TranslationSelectionObservation {
        let enabled = isActive && reading.translationSelection && !reading.store.isLoading
        return TranslationSelectionObservation(document: state.document?.id,
            selection: enabled ? state.selection : nil, enabled: enabled)
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sourceControls
                    HStack(spacing: 12) {
                        Button { reading.translateCurrentSource(state: state) } label: {
                            Label(aiReadingLabel("Translate"), systemImage: "character.bubble")
                        }.buttonStyle(ReaderPanelButtonStyle(prominent: true)).disabled(!canRun)
                            .accessibilityIdentifier("translation-generate")
                            .background(AITranslationControlProbe(id: "generate"))
                        Text(aiReadingLabel("TO")).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                        AITranslationLanguagePicker(language: $reading.translationLanguage).disabled(busy)
                    }
                    Divider().overlay(LyraReaderTheme.separator)
                    HStack {
                        Text(aiReadingLabel("Translations")).foregroundStyle(LyraReaderTheme.textSecondary)
                        Spacer(minLength: 4)
                        Toggle(aiReadingLabel("Show original"), isOn: $reading.showOriginal)
                            .toggleStyle(LyraReadingCheckboxStyle()).fixedSize()
                            .background(AITranslationControlProbe(id: "show-original"))
                    }.font(.callout)
                    if busy { activeTranslation }
                    if records.isEmpty && !busy {
                        Text(aiReadingLabel("A continuous translation with the original source close at hand."))
                            .foregroundStyle(LyraReaderTheme.textSecondary).padding(.vertical, 12)
                    }
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(records, id: \.id) { record in
                            savedTranslation(record, onCollapse: { proxy.scrollTo(record.id, anchor: .top) }).id(record.id)
                                .accessibilityIdentifier("translation-result-\(record.id)")
                                .background(AITranslationControlProbe(id: record.id))
                        }
                    }
                    if let error = worker.errorMessage {
                        Text(error).font(.caption).foregroundStyle(LyraReaderTheme.errorFg).textSelection(.enabled)
                    }
                    if !reading.settings.canUseAI {
                        Text(aiReadingLabel("Connect an AI provider in Settings to continue.")).font(.caption)
                    }
                }.padding(.vertical, 18).padding(.horizontal, AIReadingScrollMetrics.horizontalInset)
                    .padding(.trailing, trailingGutter).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AIReadingScrollMemory(key: scrollKey, reading: reading,
                        onGutterChange: { trailingGutter = $0 }))
            }
        }
        .task(id: selectionObservation) {
            guard selectionObservation.enabled else { return }
            // Coalesce pointer movement; only the visible translation tool observes selection.
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard !Task.isCancelled else { return }
            reading.refreshTranslationSelection(state)
        }
        .onChange(of: state.document?.id) { _, _ in selectedTerm = nil }
        .popover(isPresented: Binding(get: { selectedTerm != nil }, set: { if !$0 { selectedTerm = nil } })) {
            if let selectedTerm {
                AIReadingTermView(state: state, settings: reading.settings, term: selectedTerm, language: reading.translationLanguage)
                    .frame(width: 340, height: 300)
            }
        }
    }
    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            LyraReadingSegmentedPicker(title: "Source", selection: Binding(
                get: { reading.translationSelection }, set: { selection in
                    let key = "\(state.document?.id.uuidString ?? "none"):translation-\(selection ? "selection" : "document")"
                    reading.scrollPositions[key] = .zero
                    reading.changeTranslationSource(selection: selection, state: state)
                }),
                first: "Whole document", second: "Selection", firstIcon: "doc.text", secondIcon: "rectangle.dashed")
                .disabled(busy)
            if reading.translationSelection {
                let page = reading.selectionPage("translation")
                AITranslationExcerpt(text: reading.excerpt("translation"), page: page) {
                    if let page { reading.locate(page: UInt32(page), excerpt: reading.excerpt("translation"), state: state) }
                }.id(reading.excerpt("translation"))
            }
        }
    }
    private var activeTranslation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(aiReadingLabel(worker.isPreparing ? "Preparing source…" : "Translating…")).font(.caption)
                Spacer()
                Button(aiReadingLabel("Stop")) { worker.cancelRegionWork() }
            }
            if let source = reading.runningTranslation, !source.excerpt.isEmpty {
                Text(source.excerpt).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary).lineLimit(2)
            }
            if !worker.answer.isEmpty, let plan = worker.plan {
                blocks(originals: plan.sources.map(\.snippet), pages: plan.sources.map(\.page), content: worker.answer,
                    verifiedPages: worker.sentSourcePages)
            }
        }
    }
    private func savedTranslation(_ record: AiReadingRecord, onCollapse: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(aiReadingLabel(record.sourceId == aiReadingScopeKey(selection: nil) ? "Document translation" : "Selection translation"))
                Text(AITranslationLanguage.display(record.language).code).font(.caption.monospaced())
                Spacer(minLength: 4)
                Text(Date(timeIntervalSince1970: Double(record.modified) / 1000), format: .dateTime.hour().minute()).font(.caption)
            }.font(.callout).foregroundStyle(LyraReaderTheme.textSecondary)
            if record.status == "sourceChanged" {
                Text(aiReadingLabel("The document has changed. This result keeps its original source snapshot.")).font(.caption).foregroundStyle(LyraReaderTheme.warningFg)
            } else if record.status == "partial" {
                Label(aiReadingLabel("Partial result · stopped or interrupted"), systemImage: "pause.circle").font(.caption)
            }
            blocks(originals: record.originals, pages: record.originalPages, content: record.content, verifiedPages: record.pages,
                recordID: record.id, onCollapse: onCollapse, onRetry: { reading.retranslate(record, state: state) })
            Divider().overlay(LyraReaderTheme.separator)
        }
    }
    private func blocks(originals: [String], pages: [UInt32], content: String, verifiedPages: [UInt32],
        recordID: String? = nil, onCollapse: (() -> Void)? = nil, onRetry: (() -> Void)? = nil) -> some View {
        AITranslationBlocks(originals: originals, pages: pages, content: content, showOriginal: reading.showOriginal,
            verifiedPages: Set(verifiedPages), pageCount: state.document?.pageCount ?? 0,
            onLocate: { reading.locate(page: $0, excerpt: $1, state: state) }, onJump: { state.gotoPage($0 - 1) },
            recordID: recordID, retryDisabled: busy || knowledge.isBlocking || !reading.store.isAvailable || !reading.settings.canUseAI,
            onCollapse: onCollapse, onRetry: onRetry)
            .contextMenu {
                ForEach(aiTranslationTerms(originals: originals), id: \.self) { term in
                    Button(String(format: aiReadingLabel("Explain “%@”"), term)) { selectedTerm = term }
                        .disabled(busy || knowledge.isBlocking || !reading.settings.canUseAI)
                }
            }
    }
}
private struct TranslationSelectionObservation: Equatable {
    let document: UUID?
    let selection: AppState.Selection?
    let enabled: Bool
}

struct AITranslationExcerpt: View {
    let text: String
    let page: Int?
    var onLocate: () -> Void
    @State private var expanded = false
    @State private var heights: [Bool: CGFloat] = [:]
    private var canExpand: Bool { (heights[true] ?? 0) > (heights[false] ?? 0) + 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(aiReadingLabel("Selected passage") + (page.map { " · p. \($0)" } ?? ""), systemImage: "rectangle.dashed")
                Spacer()
                Button(aiReadingLabel("Locate"), action: onLocate).buttonStyle(.plain)
                    .foregroundStyle(LyraReaderTheme.accent).disabled(text.isEmpty || page == nil)
            }.font(.callout)
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(LyraReaderTheme.separator).frame(width: 2)
                VStack(alignment: .leading, spacing: 6) {
                    quote.lineLimit(expanded ? nil : 3).textSelection(.enabled)
                        .background {
                            ForEach([false, true], id: \.self) { full in
                                quote.lineLimit(full ? nil : 3).fixedSize(horizontal: false, vertical: true).hidden()
                                    .background(GeometryReader { geometry in
                                        Color.clear.preference(key: TranslationExcerptHeight.self, value: [full: geometry.size.height])
                                    })
                            }.allowsHitTesting(false).accessibilityHidden(true)
                        }
                    if canExpand {
                        Button(aiReadingLabel(expanded ? "Less" : "More")) { expanded.toggle() }
                            .buttonStyle(.plain).foregroundStyle(LyraReaderTheme.accent)
                            .font(.caption).accessibilityIdentifier("translation-excerpt-more")
                            .accessibilityValue(aiReadingLabel(expanded ? "Expanded" : "Collapsed"))
                            .background(AITranslationControlProbe(id: "excerpt-more"))
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LyraReaderTheme.separator))
            .background(AITranslationControlProbe(id: "excerpt-card"))
            .onPreferenceChange(TranslationExcerptHeight.self) { if heights != $0 { heights = $0 } }
    }
    private var quote: some View {
        Text(text.isEmpty ? aiReadingLabel("Select a passage in the document.") : text)
            .font(.callout).foregroundStyle(LyraReaderTheme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct TranslationExcerptHeight: PreferenceKey {
    static let defaultValue: [Bool: CGFloat] = [:]
    static func reduce(value: inout [Bool: CGFloat], nextValue: () -> [Bool: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}

struct AITranslationBlocks: View {
    let originals: [String]
    let pages: [UInt32]
    let content: String
    let showOriginal: Bool
    let verifiedPages: Set<UInt32>
    let pageCount: Int
    var onLocate: (UInt32, String) -> Void
    var onJump: (Int) -> Void
    var recordID: String? = nil
    var retryDisabled = false
    var onCollapse: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
    @State private var expanded = false
    @State private var overflows = false
    private var collapsed: Bool { recordID != nil && !expanded }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let blocks = try? aiTranslationBlocks(originals: originals, pages: pages, response: content), blocks.contains(where: { !$0.translation.isEmpty }) {
                let visible = collapsed ? Array(blocks.prefix(1)) : blocks
                ForEach(Array(visible.enumerated()), id: \.offset) { index, block in
                    VStack(alignment: .leading, spacing: 14) {
                        if showOriginal {
                            if let recordID {
                                AITranslationOriginal(text: block.original, controlID: "\(recordID)-\(index)", onCollapse: onCollapse)
                            } else {
                                Text(block.original).font(.system(size: 13.5)).lineSpacing(5)
                                    .foregroundStyle(LyraReaderTheme.textSecondary).textSelection(.enabled)
                            }
                        }
                        if block.translation.isEmpty {
                            Text(aiReadingLabel("Translation incomplete")).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                        } else {
                            preview(height: 180) {
                                AIAnswerView(text: block.translation, pageCount: pageCount,
                                             verifiedPages: verifiedPages.contains(block.page) ? [Int(block.page)] : [], onJump: onJump)
                                    .environment(\.readerMarkdownTypography, .translation)
                            }
                            .background {
                                if let recordID { AITranslationControlProbe(id: "translated-preview-\(recordID)-\(index)") }
                            }
                        }
                        HStack {
                            Button { onLocate(block.page, block.original) } label: {
                                Label(String(format: aiReadingLabel("Original · p. %d"), block.page), systemImage: "arrow.up.right")
                            }.foregroundStyle(LyraReaderTheme.accent)
                            Spacer()
                            Text("¶ \(index + 1)").foregroundStyle(LyraReaderTheme.textSecondary)
                        }.font(.callout)
                    }.padding(.vertical, 12)
                    if index < visible.count - 1 { Divider().overlay(LyraReaderTheme.separator) }
                }
                footer(hasMore: blocks.count > 1 || overflows)
            } else {
                Text(aiReadingLabel("Paragraph alignment is unavailable for this response. The returned text is preserved below.")).font(.caption).foregroundStyle(LyraReaderTheme.warningFg)
                preview(height: 180) {
                    AIAnswerView(text: content, pageCount: pageCount, verifiedPages: Set(verifiedPages.map(Int.init)), onJump: onJump)
                        .environment(\.readerMarkdownTypography, .translation)
                }
                footer(hasMore: overflows)
            }
        }.onPreferenceChange(TranslationPreviewOverflow.self) { overflows = $0 }
    }
    @ViewBuilder private func preview<Content: View>(height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        if recordID != nil {
            TranslationPreviewClip(collapsed: collapsed, limit: height, content: content())
        } else { content() }
    }
    @ViewBuilder private func footer(hasMore: Bool) -> some View {
        if let recordID {
            HStack(spacing: 12) {
                if expanded || hasMore {
                    Button(aiReadingLabel(expanded ? "Less" : "More")) {
                        expanded.toggle()
                        if !expanded { onCollapse?() }
                    }.accessibilityValue(aiReadingLabel(expanded ? "Expanded" : "Collapsed"))
                        .background(AITranslationControlProbe(id: "result-more-\(recordID)"))
                }
                Spacer(minLength: 0)
                if let onRetry {
                    Button(action: onRetry) { Label(aiReadingLabel("Retry"), systemImage: "arrow.clockwise") }
                        .disabled(retryDisabled)
                        .background(AITranslationControlProbe(id: "result-retry-\(recordID)"))
                }
            }.font(.caption).foregroundStyle(LyraReaderTheme.accent).buttonStyle(.plain)
        }
    }
}
struct AITranslationOriginal: View {
    let text: String
    let controlID: String
    var onCollapse: (() -> Void)? = nil
    @State private var expanded = false
    @State private var heights: [Bool: CGFloat] = [:]
    private var canExpand: Bool { (heights[true] ?? 0) > (heights[false] ?? 0) + 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            original.lineLimit(expanded ? nil : 3).textSelection(.enabled)
                .background {
                    ForEach([false, true], id: \.self) { full in
                        original.lineLimit(full ? nil : 3).fixedSize(horizontal: false, vertical: true).hidden()
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: TranslationExcerptHeight.self, value: [full: geometry.size.height])
                            })
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
            if canExpand {
                Button(aiReadingLabel(expanded ? "Less" : "More")) {
                    expanded.toggle()
                    if !expanded { onCollapse?() }
                }.font(.caption).buttonStyle(.plain).foregroundStyle(LyraReaderTheme.accent)
                    .accessibilityValue(aiReadingLabel(expanded ? "Expanded" : "Collapsed"))
                    .background(AITranslationControlProbe(id: "original-more-\(controlID)"))
            }
        }.background(AITranslationControlProbe(id: "original-preview-\(controlID)"))
            .onPreferenceChange(TranslationExcerptHeight.self) { if heights != $0 { heights = $0 } }
    }
    private var original: some View {
        Text(text).font(.system(size: 13.5)).lineSpacing(5).foregroundStyle(LyraReaderTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct TranslationPreviewOverflow: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
private struct TranslationPreviewClip<Content: View>: View {
    let collapsed: Bool
    let limit: CGFloat
    let content: Content
    @State private var height: CGFloat = 0
    var body: some View {
        TranslationPreviewLayout(limit: collapsed ? limit : nil) {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
            .clipped().contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if collapsed && height > limit + 0.5 {
                    LinearGradient(colors: [.clear, LyraReaderTheme.panelBg], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .preference(key: TranslationPreviewOverflow.self, value: height > limit + 0.5)
    }
}
/// Measure and place the native rich text at the same width, with an unconstrained height.
/// Only the enclosing viewport shrinks; text never reflows into a narrow ideal-size column.
private struct TranslationPreviewLayout: Layout {
    let limit: CGFloat?
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: limit.map { min($0, size.height) } ?? size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
/// Non-intercepting native geometry used by the mouse-driven interaction checks.
final class AITranslationControlMarker: NSView {
    var id = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
struct AITranslationControlProbe: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> AITranslationControlMarker { AITranslationControlMarker() }
    func updateNSView(_ view: AITranslationControlMarker, context: Context) { view.id = id }
}

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
    private var selectionObservation: AIReadingSelectionObservation {
        let enabled = isActive && reading.translationSelection && !reading.store.isLoading
        return AIReadingSelectionObservation(document: state.document?.id,
            selection: enabled ? state.selection : nil, enabled: enabled)
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                    LazyVStack(alignment: .leading, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 6) {
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
struct AIReadingSelectionObservation: Equatable {
    let document: UUID?
    let selection: AppState.Selection?
    let enabled: Bool
}

struct AITranslationExcerpt: View {
    let text: String
    let page: Int?
    var onLocate: () -> Void
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
                TranslationSourceDisclosure(text: text.isEmpty ? aiReadingLabel("Select a passage in the document.") : text,
                    moreID: "excerpt-more", fontSize: 13, lineSpacing: 0)
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LyraReaderTheme.separator))
            .background(AITranslationControlProbe(id: "excerpt-card"))
    }
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
    @State private var footerDisclosure = false
    private var collapsed: Bool { recordID != nil && !expanded }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let blocks = try? aiTranslationBlocks(originals: originals, pages: pages, response: content), blocks.contains(where: { !$0.translation.isEmpty }) {
                let visible = collapsed ? Array(blocks.prefix(1)) : blocks
                let hasMore = blocks.count > 1 || overflows
                ForEach(Array(visible.enumerated()), id: \.offset) { index, block in
                    let last = index == visible.count - 1
                    VStack(alignment: .leading, spacing: 10) {
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
                            preview(inlineControls: last, additionalContent: blocks.count > 1) {
                                AIAnswerView(text: block.translation, pageCount: pageCount,
                                    verifiedPages: verifiedPages.contains(block.page) ? [Int(block.page)] : [], onJump: onJump)
                                    .environment(\.readerMarkdownTypography, .translation)
                            }.background {
                                if let recordID { AITranslationControlProbe(id: "translated-preview-\(recordID)-\(index)") }
                            }
                        }
                        HStack(spacing: 10) {
                            Button { onLocate(block.page, block.original) } label: {
                                Text(String(format: aiReadingLabel("p. %d"), block.page))
                            }.buttonStyle(.plain).foregroundStyle(LyraReaderTheme.accent)
                                .overlay(AITranslationControlProbe(id: "result-page-\(recordID ?? "active")-\(index)", clickable: true))
                                .modifier(TranslationPointingHand())
                            Spacer(minLength: 0)
                            if last {
                                if collapsed && hasMore && (footerDisclosure || block.translation.isEmpty) { footerMore }
                                resultActions(endingWithoutText: block.translation.isEmpty)
                            }
                        }.font(.callout).background {
                            if let recordID { AITranslationControlProbe(id: "result-source-\(recordID)-\(index)") }
                        }
                    }.padding(.vertical, 6)
                    if index < visible.count - 1 { Divider().overlay(LyraReaderTheme.separator) }
                }
            } else {
                Text(aiReadingLabel("Paragraph alignment is unavailable for this response. The returned text is preserved below.")).font(.caption).foregroundStyle(LyraReaderTheme.warningFg)
                preview(inlineControls: true, additionalContent: false) {
                    AIAnswerView(text: content, pageCount: pageCount, verifiedPages: Set(verifiedPages.map(Int.init)), onJump: onJump)
                        .environment(\.readerMarkdownTypography, .translation)
                }
                HStack {
                    if collapsed && footerDisclosure { footerMore }
                    Spacer(minLength: 0); resultActions()
                }
            }
        }.onPreferenceChange(TranslationPreviewOverflow.self) { overflows = $0 }
            .onPreferenceChange(TranslationPreviewFooter.self) { footerDisclosure = $0 }
    }
    @ViewBuilder private var footerMore: some View {
        if let recordID {
            Button(aiReadingLabel("More")) { expanded = true }
                .font(.caption).buttonStyle(.plain).foregroundStyle(LyraReaderTheme.accent)
                .overlay(AITranslationControlProbe(id: "result-more-\(recordID)", clickable: true))
                .modifier(TranslationPointingHand())
        }
    }
    @ViewBuilder private func preview<Content: View>(inlineControls: Bool, additionalContent: Bool,
        @ViewBuilder content: () -> Content) -> some View {
        if let recordID, inlineControls {
            TranslationInlinePreview(collapsed: collapsed, additionalContent: additionalContent,
                moreID: "result-more-\(recordID)", onExpand: { expanded = true },
                onCollapse: { expanded = false; onCollapse?() }, content: content())
        } else { content() }
    }
    @ViewBuilder private func resultActions(endingWithoutText: Bool = false) -> some View {
        if let recordID {
            Group {
                if expanded && (footerDisclosure || endingWithoutText) {
                    Button(aiReadingLabel("Less")) { expanded = false; onCollapse?() }
                        .accessibilityValue(aiReadingLabel("Expanded"))
                        .overlay(AITranslationControlProbe(id: "result-more-\(recordID)", clickable: true))
                        .modifier(TranslationPointingHand())
                }
                if let onRetry {
                    Button(action: onRetry) { Label(aiReadingLabel("Retry"), systemImage: "arrow.clockwise") }
                        .disabled(retryDisabled).overlay(AITranslationControlProbe(id: "result-retry-\(recordID)", clickable: !retryDisabled))
                        .modifier(TranslationPointingHand(enabled: !retryDisabled))
                }
            }.font(.caption).foregroundStyle(LyraReaderTheme.accent).buttonStyle(.plain)
        }
    }
}
struct AITranslationOriginal: View {
    let text: String
    let controlID: String
    var onCollapse: (() -> Void)? = nil
    var body: some View {
        TranslationSourceDisclosure(text: text, moreID: "original-more-\(controlID)", onCollapse: onCollapse)
            .background(AITranslationControlProbe(id: "original-preview-\(controlID)"))
    }
}
private struct TranslationSourceDisclosure: View {
    let text: String
    let moreID: String
    var fontSize: CGFloat = 13.5
    var lineSpacing: CGFloat = 5
    var onCollapse: (() -> Void)? = nil
    @State private var expanded = false
    var body: some View {
        TranslationInlinePreview(collapsed: !expanded,
            limit: 3 * (ceil(NSFont.systemFont(ofSize: fontSize).ascender - NSFont.systemFont(ofSize: fontSize).descender) + lineSpacing),
            maximumLines: 3, moreID: moreID, reportsOverflow: false,
            onExpand: { expanded = true }, onCollapse: { expanded = false; onCollapse?() }, content:
                ReaderMarkdownInlineText(inlines: [.text(text)], pageCount: 0, fontSize: fontSize, onJump: { _ in })
                    .environment(\.readerMarkdownTypography, ReaderMarkdownTypography(bodySize: fontSize,
                        lineSpacing: lineSpacing, themedInk: true, secondaryInk: true))
                    .environment(\.readingStableTextLayout, true))
    }
}
/// Non-intercepting native geometry used by the mouse-driven interaction checks.
final class AITranslationControlMarker: NSView {
    var id = ""
    var clickable = false
    override func resetCursorRects() {
        if clickable { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
/// Track the button itself so the cursor overlay cannot consume its click.
struct TranslationPointingHand: ViewModifier {
    var enabled = true
    @State private var holdsCursor = false
    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            switch phase {
            case .active:
                guard enabled else { return }
                if !holdsCursor { NSCursor.pointingHand.push(); holdsCursor = true }
                NSCursor.pointingHand.set()
            case .ended: releaseCursor()
            }
        }.onChange(of: enabled) { _, value in if !value { releaseCursor() } }
            .onDisappear(perform: releaseCursor)
    }
    private func releaseCursor() {
        if holdsCursor { NSCursor.pop(); holdsCursor = false }
    }
}
struct AITranslationControlProbe: NSViewRepresentable {
    let id: String
    var clickable = false
    func makeNSView(context: Context) -> AITranslationControlMarker { AITranslationControlMarker() }
    func updateNSView(_ view: AITranslationControlMarker, context: Context) {
        view.id = id
        if view.clickable != clickable {
            view.clickable = clickable; view.window?.invalidateCursorRects(for: view)
        }
    }
}

import AppKit
import LyraReaderBindings
import SwiftUI

/// Native presentation of the Rust reading workspace and paragraph source map.
struct AITranslationView: View {
    @ObservedObject var state: AppState
    @ObservedObject var reading: AIReadingModel
    @Binding var showingHistory: Bool
    @State private var selectedTerm: String?
    @ObservedObject private var knowledge: AIDocumentKnowledge

    init(state: AppState, reading: AIReadingModel, showingHistory: Binding<Bool>) {
        self.state = state; self.reading = reading; _showingHistory = showingHistory
        _knowledge = ObservedObject(wrappedValue: state.documentKnowledge)
    }
    private var worker: AIAssistantModel { reading.translation }
    private var busy: Bool { worker.isPreparing || worker.isSending || worker.phase == .preview || worker.phase == .mergePreview }
    private var result: AiReadingRecord? { reading.result("translation") }
    private var records: [AiReadingRecord] { reading.store.taskHistory("translation") }
    private var canRun: Bool {
        !busy && !knowledge.isBlocking && reading.store.isAvailable && reading.settings.canUseAI &&
        (!reading.translationSelection || !reading.excerpt("translation").isEmpty)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if showingHistory { history }
                else { translation }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(AIReadingScrollMemory(key: "\(state.document?.id.uuidString ?? "none"):translation:\(showingHistory):\(reading.translationResultID ?? "draft")", reading: reading))
        }.id(showingHistory)
        .onChange(of: state.document?.id) { _, _ in selectedTerm = nil }
        .popover(isPresented: Binding(get: { selectedTerm != nil }, set: { if !$0 { selectedTerm = nil } })) {
            if let selectedTerm {
                AIReadingTermView(state: state, settings: reading.settings, term: selectedTerm, language: reading.translationLanguage)
                    .padding(16).frame(width: 320, height: 300)
            }
        }
    }
    private var translation: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 4) {
                sourceButton("Whole document", icon: "doc.text", selection: false)
                sourceButton("Selection", icon: "rectangle.dashed", selection: true)
            }.padding(3)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LyraReaderTheme.controlBorder))
                .disabled(busy)
            if reading.translationSelection {
                let page = result?.originalPages.first.map(Int.init) ?? reading.selectionPage("translation")
                AITranslationExcerpt(text: reading.excerpt("translation"), page: page) {
                    if let page { reading.locate(page: UInt32(page), excerpt: reading.excerpt("translation"), state: state) }
                }.id(reading.excerpt("translation"))
                Button {
                    reading.useSelection("translation", state: state)
                } label: { Label(aiReadingLabel("Use new selection"), systemImage: "rectangle.dashed") }
                    .disabled(state.selection == nil || busy).accessibilityIdentifier("translation-use-selection")
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(aiReadingLabel("Document language"))
                    Image(systemName: "arrow.right")
                }.foregroundStyle(LyraReaderTheme.textSecondary)
                Spacer(minLength: 4)
                Text(aiReadingLabel("TO")).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                Menu {
                    ForEach(Array(Set([reading.translationLanguage, "English", "Simplified Chinese", "Traditional Chinese", "Japanese", "Korean", "French", "Spanish", "German"])).sorted(), id: \.self) { language in
                        Button { reading.translationLanguage = language } label: {
                            if reading.translationLanguage == language { Label(aiReadingLabel(language), systemImage: "checkmark") }
                            else { Text(aiReadingLabel(language)) }
                        }
                    }
                } label: {
                    Text(aiReadingLabel(reading.translationLanguage))
                }.menuStyle(.borderlessButton).fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LyraReaderTheme.controlBorder))
                    .disabled(busy)
                    .accessibilityLabel(aiReadingLabel("Translate to"))
            }
            Divider().overlay(LyraReaderTheme.separator)
            HStack {
                Text(aiReadingLabel(reading.translationSelection ? "Selection translation" : "Document translation"))
                    .foregroundStyle(LyraReaderTheme.textSecondary)
                Spacer(minLength: 4)
                Toggle(aiReadingLabel("Show original"), isOn: $reading.showOriginal)
                    .toggleStyle(.checkbox).tint(LyraReaderTheme.accent).controlSize(.small).fixedSize()
            }.font(.callout)
            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(aiReadingLabel(worker.isPreparing ? "Preparing source…" : "Translating…")).font(.caption)
                    Spacer()
                    Button(aiReadingLabel("Stop")) { worker.cancelRegionWork() }
                }
            }
            if busy, !worker.answer.isEmpty, let plan = worker.plan {
                blocks(originals: plan.sources.map(\.snippet), pages: plan.sources.map(\.page), content: worker.answer)
            } else if let result {
                if result.language != reading.translationLanguage {
                    Text(aiReadingLabel("Settings changed. Generate again to update this result.")).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                }
                if result.status == "sourceChanged" {
                    Text(aiReadingLabel("The document has changed. This result keeps its original source snapshot.")).font(.caption).foregroundStyle(LyraReaderTheme.warningFg)
                } else if result.status == "partial" {
                    Label(aiReadingLabel("Partial result · stopped or interrupted"), systemImage: "pause.circle").font(.caption)
                }
                blocks(originals: result.originals, pages: result.originalPages, content: result.content)
            } else if !busy {
                Text(aiReadingLabel("A continuous translation with the original source close at hand."))
                    .foregroundStyle(LyraReaderTheme.textSecondary).padding(.vertical, 12)
            }
            if let error = worker.errorMessage {
                Text(error).font(.caption).foregroundStyle(LyraReaderTheme.errorFg).textSelection(.enabled)
            }
            if !reading.settings.canUseAI { Text(aiReadingLabel("Connect an AI provider in Settings to continue.")).font(.caption) }
            HStack(spacing: 12) {
                if result == nil { generateButton.buttonStyle(ReaderPanelButtonStyle(prominent: true)) }
                else { generateButton.buttonStyle(.plain).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading) }
                if let result {
                    Button { copy(result) } label: { Label(aiReadingLabel("Copy translation"), systemImage: "doc.on.doc") }
                        .buttonStyle(ReaderPanelButtonStyle()).disabled(busy)
                        .contextMenu {
                            Button(aiReadingLabel("Current page")) { copy(result, page: state.currentPage) }
                            Button(aiReadingLabel("All translated text")) { copy(result) }
                        }
                }
            }
            if !records.isEmpty {
                Button { showingHistory = true } label: {
                    HStack {
                        Label(aiReadingLabel("Translation history"), systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Text(String(format: aiReadingLabel("%d saved translations"), records.count)).font(.caption)
                        Image(systemName: "chevron.right").font(.caption)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(LyraReaderTheme.accent).padding(.vertical, 8)
                    .disabled(busy).accessibilityIdentifier("translation-history")
                    .background(AITranslationControlProbe(id: "history"))
            }
        }
    }
    private var generateButton: some View {
        Button { reading.run("translation", state: state, force: result != nil) } label: {
            Label(aiReadingLabel(result == nil ? (reading.translationSelection ? "Translate selection" : "Translate document") : "Retranslate"), systemImage: result == nil ? "sparkles" : "arrow.clockwise")
        }.disabled(!canRun).accessibilityIdentifier("translation-generate")
    }
    private func sourceButton(_ title: String, icon: String, selection: Bool) -> some View {
        Button { reading.changeTranslationSource(selection: selection, state: state) } label: {
            Label(aiReadingLabel(title), systemImage: icon).frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
        }.buttonStyle(TranslationSourceStyle(selected: reading.translationSelection == selection))
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { showingHistory = false } label: { Label(aiReadingLabel("Current task"), systemImage: "chevron.left") }
            Text(aiReadingLabel("Translation history")).font(.headline)
            if records.isEmpty { ContentUnavailableView(aiReadingLabel("No saved task results"), systemImage: "clock") }
            ForEach(records, id: \.id) { record in
                Button {
                    reading.openTranslation(record); showingHistory = false
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Label(aiReadingLabel(record.title), systemImage: record.sourceId == aiReadingScopeKey(selection: nil) ? "doc.text" : "rectangle.dashed")
                            Spacer()
                            if record.id == result?.id { Image(systemName: "checkmark").foregroundStyle(LyraReaderTheme.accent) }
                        }.font(.callout.weight(.medium))
                        Text(record.excerpt).font(.callout).lineLimit(3).foregroundStyle(LyraReaderTheme.textSecondary)
                        HStack {
                            Text(aiReadingLabel(record.language))
                            Spacer()
                            Text(Date(timeIntervalSince1970: Double(record.modified) / 1000), format: .dateTime.month().day().hour().minute())
                        }.font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(TranslationHistoryStyle(selected: record.id == result?.id))
                    .accessibilityIdentifier("translation-history-\(record.id)")
                    .background(AITranslationControlProbe(id: record.id))
            }
        }
    }
    private func blocks(originals: [String], pages: [UInt32], content: String) -> some View {
        AITranslationBlocks(originals: originals, pages: pages, content: content, showOriginal: reading.showOriginal,
            pageCount: state.document?.pageCount ?? 0, onLocate: { reading.locate(page: $0, excerpt: $1, state: state) },
            onJump: { state.gotoPage($0 - 1) })
            .contextMenu {
                ForEach(aiTranslationTerms(originals: originals), id: \.self) { term in
                    Button(String(format: aiReadingLabel("Explain “%@”"), term)) { selectedTerm = term }
                        .disabled(busy || knowledge.isBlocking || !reading.settings.canUseAI)
                }
            }
    }
    private func copy(_ record: AiReadingRecord, page: Int? = nil) {
        let text: String
        do {
            let blocks = try aiTranslationBlocks(originals: record.originals, pages: record.originalPages, response: record.content)
            let translated = blocks.filter { page == nil || Int($0.page) == page }.map(\.translation).filter { !$0.isEmpty }.joined(separator: "\n\n")
            if translated.isEmpty && page != nil { reading.notice = "This page has no aligned translation to copy."; return }
            text = translated.isEmpty ? record.content : translated
        } catch {
            reading.notice = AIReadableError.message(error)
            guard page == nil else { return }
            // A malformed alignment must not prevent copying the raw response shown above.
            text = record.content
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
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
    let pageCount: Int
    var onLocate: (UInt32, String) -> Void
    var onJump: (Int) -> Void
    var body: some View {
        if let blocks = try? aiTranslationBlocks(originals: originals, pages: pages, response: content), blocks.contains(where: { !$0.translation.isEmpty }) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                VStack(alignment: .leading, spacing: 14) {
                    if showOriginal { Text(block.original).font(.callout).foregroundStyle(LyraReaderTheme.textSecondary).textSelection(.enabled) }
                    if block.translation.isEmpty {
                        Text(aiReadingLabel("Translation incomplete")).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                    } else {
                        AIAnswerView(text: block.translation, pageCount: pageCount, verifiedPages: [Int(block.page)], onJump: onJump)
                    }
                    HStack {
                        Button { onLocate(block.page, block.original) } label: {
                            Label(String(format: aiReadingLabel("Original · p. %d"), block.page), systemImage: "arrow.up.right")
                        }.foregroundStyle(LyraReaderTheme.accent)
                        Spacer()
                        Text("¶ \(index + 1)").foregroundStyle(LyraReaderTheme.textSecondary)
                    }.font(.callout)
                }.padding(.vertical, 8)
                Divider().overlay(LyraReaderTheme.separator)
            }
        } else {
            Text(aiReadingLabel("Paragraph alignment is unavailable for this response. The returned text is preserved below.")).font(.caption).foregroundStyle(LyraReaderTheme.warningFg)
            AIAnswerView(text: content, pageCount: pageCount, verifiedPages: Set(pages.map(Int.init)), onJump: onJump)
        }
    }
}
private struct TranslationSourceStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(!enabled ? LyraReaderTheme.textDisabled : selected ? LyraReaderTheme.selectedFg : LyraReaderTheme.textPrimary)
            .background(configuration.isPressed ? LyraReaderTheme.pressedBg : selected ? LyraReaderTheme.selectedBg : hovered && enabled ? LyraReaderTheme.hoverBg : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}
private struct TranslationHistoryStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed && enabled ? LyraReaderTheme.pressedBg : selected ? LyraReaderTheme.selectedBg : hovered && enabled ? LyraReaderTheme.hoverBg : LyraReaderTheme.fieldBg,
                                       in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? LyraReaderTheme.accentBorder : LyraReaderTheme.separator))
            .onHover { hovered = $0 }
    }
}

/// Non-intercepting native geometry used by the mouse-driven interaction checks.
final class AITranslationControlMarker: NSView {
    var id = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private struct AITranslationControlProbe: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> AITranslationControlMarker { AITranslationControlMarker() }
    func updateNSView(_ view: AITranslationControlMarker, context: Context) { view.id = id }
}

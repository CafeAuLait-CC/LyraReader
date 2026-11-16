import LyraReaderBindings
import SwiftUI

/// Collapsing Markdown headings is a presentation operation and never starts another request.
struct AIReadingSummaryContent: View {
    let text: String
    let pageCount: Int
    let pages: [UInt32]
    let onJump: (Int) -> Void
    @State private var expanded: [Int: Bool] = [:]
    private var groups: [(String, [ReaderMarkdownBlock])] {
        let document = ReaderMarkdown.parse(text, pageCount: pageCount, verifiedPages: Set(pages.map(Int.init)))
        var result: [(String, [ReaderMarkdownBlock])] = []
        for block in document.blocks {
            if case .heading = block {
                result.append((ReaderMarkdownDocument(blocks: [block]).plainText, []))
            } else {
                if result.isEmpty { result.append(("", [])) }
                result[result.count - 1].1.append(block)
            }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if group.0.isEmpty {
                    ReaderMarkdownView(document: ReaderMarkdownDocument(blocks: group.1), pageCount: pageCount, onJump: onJump)
                } else if group.1.isEmpty {
                    Text(group.0).font(.system(size: 13, weight: .semibold))
                } else {
                    DisclosureGroup(isExpanded: Binding(get: {
                        expanded[index] ?? (index < 2 || group.0.localizedCaseInsensitiveContains("Key ideas"))
                    }, set: { expanded[index] = $0 })) {
                        ReaderMarkdownView(document: ReaderMarkdownDocument(blocks: group.1), pageCount: pageCount, onJump: onJump)
                            .padding(.top, 8)
                    } label: { Text(group.0).font(.system(size: 13, weight: .semibold)) }
                }
            }
        }
    }
}

struct AIReadingTermView: View {
    @ObservedObject var state: AppState
    @StateObject private var worker: AIAssistantModel
    let term: String
    let language: String
    init(state: AppState, settings: AISettingsStore, term: String, language: String) {
        self.state = state; self.term = term; self.language = language
        _worker = StateObject(wrappedValue: AIAssistantModel(settings: settings))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(term).font(.headline)
            ScrollView {
                if worker.isPreparing || worker.isSending { ProgressView().controlSize(.small) }
                if !worker.answer.isEmpty {
                    AIAnswerView(text: worker.answer, pageCount: state.document?.pageCount ?? 0,
                                 verifiedPages: Set(worker.sentSourcePages.map(Int.init)), onJump: { state.gotoPage($0 - 1) })
                }
                if let error = worker.errorMessage { Text(error).font(.caption).foregroundStyle(LyraReaderTheme.errorFg) }
                if let note = worker.statusNote, worker.answer.isEmpty { Text(note).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary) }
            }
        }.padding(16).frame(maxWidth: .infinity).frame(height: 250).background(LyraReaderTheme.panelBg)
        .task(id: term) {
            guard let live = state.aiReaderContext else { return }
            let context = AIReaderContext(documentKey: live.documentKey, documentTitle: live.documentTitle,
                pageCount: live.pageCount, currentPage: live.currentPage, selection: nil)
            worker.attach(service: state.aiChatService, context: context)
            worker.question = term
            await worker.prepare(action: .summarizeDocument, context: context,
                                 reading: AiReadingOptionsRecord(kind: "term", detail: "Standard"), outputLanguage: language)
            guard worker.phase == .preview, let plan = worker.plan else { return }
            if worker.settings.reviewBeforeSending {
                guard await AIReadingReviewWindow.review(plan), worker.phase == .preview else { return }
            }
            worker.send()
        }.onDisappear { worker.cancelRegionWork() }
    }
}

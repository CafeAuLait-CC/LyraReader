import AppKit
import LyraReaderBindings
import SwiftUI

/// Collapsing Markdown headings is a presentation operation and never starts another request.
struct AIReadingSummaryContent: View {
    let text: String
    let pageCount: Int
    let pages: [UInt32]
    let onJump: (Int) -> Void
    @State private var expanded: [Int: Bool] = [:]
    @State private var hoveredHeading: Int?
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
                    let open = expanded[index] ?? (index < 2 || group.0.localizedCaseInsensitiveContains("Key ideas"))
                    VStack(alignment: .leading, spacing: 0) {
                        Button { expanded[index] = !open } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                    .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(LyraReaderTheme.textSecondary)
                                Text(group.0).font(.system(size: 13, weight: .semibold))
                                    .underline(hoveredHeading == index, color: LyraReaderTheme.accentBorder)
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(AIReadingHeadingProbe(index: index))
                            .accessibilityValue(Text(aiReadingLabel(open ? "Expanded" : "Collapsed")))
                            .help(aiReadingLabel("Expand or collapse this section"))
                            .onHover { inside in
                                if inside { hoveredHeading = index }
                                else if hoveredHeading == index { hoveredHeading = nil }
                            }
                        if open {
                            ReaderMarkdownView(document: ReaderMarkdownDocument(blocks: group.1), pageCount: pageCount, onJump: onJump)
                                .padding(.top, 8)
                        }
                    }
                }
            }
        }
    }
}

final class AIReadingHeadingMarker: NSView {
    var index = 0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private struct AIReadingHeadingProbe: NSViewRepresentable {
    let index: Int
    func makeNSView(context: Context) -> AIReadingHeadingMarker { AIReadingHeadingMarker() }
    func updateNSView(_ view: AIReadingHeadingMarker, context: Context) { view.index = index }
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

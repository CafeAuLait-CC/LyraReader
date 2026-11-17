import AppKit
import LyraReaderBindings
import SwiftUI

struct AIReadingSidebar: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: AIAssistantModel
    @ObservedObject var reading: AIReadingModel
    @ObservedObject private var knowledge: AIDocumentKnowledge
    @State private var history = false
    @State private var showingTaskHistory = false
    @State private var selectedTaskID: String?
    @State private var search = ""
    @State private var recent = false
    @State private var editing = false
    @State private var selectedTerm: String?
    @State private var noteTitle = ""
    @State private var noteContent = ""
    @State private var noteThoughts = ""
    let isActive: Bool

    init(state: AppState, navigation: AIAssistantModel, reading: AIReadingModel, isActive: Bool) {
        self.state = state; self.navigation = navigation; self.reading = reading; self.isActive = isActive
        _knowledge = ObservedObject(wrappedValue: state.documentKnowledge)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(LyraReaderTheme.separator)
            if state.document == nil { ContentUnavailableView(aiReadingLabel("Open a document"), systemImage: "doc") }
            else if reading.store.isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                if knowledge.isBlocking { readiness }
                if let error = reading.store.error { Text(error).font(.caption).foregroundStyle(LyraReaderTheme.errorFg).padding(12) }
                if navigation.selectedTab == .chat {
                    if history { conversationHistory }
                    AIDocumentChatView(state: state, model: reading.chat,
                        onKeep: { reading.keepChat($0) }, onAsk: { reading.askChat(state: state) },
                        onLocate: { reading.locate(page: UInt32($0.page), excerpt: $0.snippet, state: state) })
                        .disabled(knowledge.isBlocking)
                } else if navigation.selectedTab == .regions { notes }
                else if showingTaskHistory { taskHistory(navigation.selectedTab == .summary ? "summary" : "translation") }
                else { task(navigation.selectedTab == .summary ? "summary" : "translation").background(AIReadingSidebarMarker()) }
                if let notice = reading.notice {
                    HStack { Image(systemName: "info.circle"); Text(aiReadingLabel(notice)); Spacer(); Button { reading.notice = nil } label: { Image(systemName: "xmark") } }
                        .font(.caption).padding(10).background(LyraReaderTheme.noteBg)
                        .task(id: notice) {
                            do { try await Task.sleep(for: .seconds(4)); reading.notice = nil } catch { }
                        }
                }
            }
        }
        .environment(\.readingStableTextLayout, true)
        .environment(\.readingThemedLinks, true)
        .background(LyraReaderTheme.panelBg)
        .foregroundStyle(LyraReaderTheme.textPrimary)
        .buttonStyle(.borderless)
        .textFieldStyle(ReaderPanelFieldStyle())
        .task(id: "\(isActive)-\(state.document?.id.uuidString ?? "none")-\(state.document?.url?.path ?? "none")") {
            if state.document == nil { reading.cancelPresentation(); return }
            guard isActive else { return }
            await reading.bind(state)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lyraReadingNoteChanged)) { notification in
            guard let owner = notification.object as? AppState, owner === state else { return }
            reading.importInterleaf(state)
            reading.notice = "Reading note saved"
        }
        .onChange(of: state.regionHistory) { _, _ in reading.importInterleaf(state) }
        .onDisappear { reading.cancelPresentation() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: navigation.selectedTab.icon).foregroundStyle(LyraReaderTheme.accent)
            Text(aiReadingLabel(navigation.selectedTab.title)).font(.system(size: 14, weight: .semibold))
            Spacer()
            if navigation.selectedTab == .chat {
                Button { history.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }.help(aiReadingLabel("Conversation history"))
                Button { reading.newSession(pageCount: state.document?.pageCount ?? 0); history = false } label: { Image(systemName: "square.and.pencil") }
                    .help(aiReadingLabel("New conversation")).disabled(reading.chat.isSending)
            }
            if navigation.selectedTab == .summary || navigation.selectedTab == .translation {
                Button { showingTaskHistory.toggle(); selectedTaskID = nil } label: { Image(systemName: "clock.arrow.circlepath") }.help(aiReadingLabel("Task history"))
            }
            if navigation.selectedTab == .regions {
                Button { copy(reading.store.notes(query: search, recent: recent).map { "# \($0.title)\n\n\($0.content)\n\n\($0.thoughts)" }.joined(separator: "\n\n---\n\n")) }
                    label: { Image(systemName: "doc.on.doc") }.help(aiReadingLabel("Copy reading notes"))
            }
            SettingsLink { Image(systemName: "gearshape") }.help(aiReadingLabel("Lyra AI settings"))
            Button { state.toggleRightPanel() } label: { Image(systemName: "xmark") }.accessibilityLabel(aiReadingLabel("Close AI assistant"))
        }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: 46).background(LyraReaderTheme.sidebarBg)
    }
    private var readiness: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(aiReadingLabel(knowledge.phase == .reading ? "Prereading document… AI will be ready shortly." : "Preparing document…"))
                .font(.caption)
            Spacer()
            if knowledge.phase == .reading { Button(aiReadingLabel("Stop")) { knowledge.stopReading() } }
        }.padding(12).background(LyraReaderTheme.accentSoft)
    }

    private func task(_ kind: String) -> some View {
        let worker = reading.worker(kind)
        let selected = kind == "summary" ? reading.summarySelection : reading.translationSelection
        let result = reading.result(kind)
        let busy = worker.isPreparing || worker.isSending || worker.phase == .mergePreview || worker.phase == .preview
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker(aiReadingLabel("Source"), selection: Binding(get: { selected }, set: { value in
                    if kind == "summary" { reading.summarySelection = value } else { reading.translationSelection = value }
                    if value && reading.excerpt(kind).isEmpty { reading.useSelection(kind, state: state) }
                })) {
                    Text(aiReadingLabel("Whole document")).tag(false)
                    Text(aiReadingLabel("Selection")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().disabled(busy)
                if selected {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(aiReadingLabel("Selected passage")).font(.caption.weight(.medium))
                            Spacer()
                            Button(aiReadingLabel("Locate")) { reading.locateSelection(kind, state: state) }
                            Button(aiReadingLabel("Use new selection")) { reading.useSelection(kind, state: state) }.disabled(state.selection == nil || busy)
                        }
                        Text(reading.excerpt(kind).isEmpty ? aiReadingLabel("Select a passage in the document.") : reading.excerpt(kind))
                            .font(.caption).lineLimit(5).textSelection(.enabled)
                    }.padding(12).background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Label(String(format: aiReadingLabel("All %d pages"), state.document?.pageCount ?? 0), systemImage: "doc.text").font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                }
                if kind == "summary" {
                    HStack { Text(aiReadingLabel("Detail")).font(.caption); Spacer(); Picker(aiReadingLabel("Detail"), selection: $reading.detail) {
                        ForEach(["Brief", "Standard", "Detailed"], id: \.self) { Text(aiReadingLabel($0)).tag($0) }
                    }.labelsHidden().fixedSize() }
                } else {
                    Picker(aiReadingLabel("Translate to"), selection: $reading.translationLanguage) {
                        ForEach(Array(Set([reading.translationLanguage, "English", "Simplified Chinese", "Traditional Chinese", "Japanese", "Korean", "French", "Spanish", "German"])).sorted(), id: \.self) {
                            Text(aiReadingLabel($0)).tag($0)
                        }
                    }
                    Toggle(aiReadingLabel("Show original"), isOn: $reading.showOriginal).toggleStyle(.switch).controlSize(.small)
                }
                if busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(aiReadingLabel(worker.isPreparing ? "Preparing source…" : (kind == "summary" ? "Summarizing…" : "Translating…"))).font(.caption)
                        Spacer(); Button(aiReadingLabel("Stop")) { worker.cancelRegionWork() }
                    }
                }
                if !busy, let result, (result.detail != reading.detail && kind == "summary" || result.language != (kind == "summary" ? reading.language : reading.translationLanguage)) {
                    Label(aiReadingLabel("Settings changed. Generate again to update this result."), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                }
                if busy && !worker.answer.isEmpty {
                    answer(worker.answer, pages: worker.sentSourcePages)
                } else if let result {
                    Text("\(result.language.isEmpty ? aiReadingLabel("Document language") : result.language) · \(result.model)")
                        .font(.caption2).foregroundStyle(LyraReaderTheme.textSecondary)
                    if !selected { Text(String(format: aiReadingLabel("Text coverage: %d of %d pages"), result.pages.count, state.document?.pageCount ?? 0)).font(.caption2).foregroundStyle(LyraReaderTheme.textSecondary) }
                    if result.status == "sourceChanged" { Text(aiReadingLabel("The document has changed. This result keeps its original source snapshot.")).font(.caption).foregroundStyle(LyraReaderTheme.warningFg) }
                    if result.status == "partial" { Label(aiReadingLabel("Partial result · stopped or interrupted"), systemImage: "pause.circle").font(.caption) }
                    if kind == "translation" { translationResult(result) }
                    else { AIReadingSummaryContent(text: result.content, pageCount: state.document?.pageCount ?? 0, pages: result.pages, onJump: { state.gotoPage($0 - 1) }) }
                    HStack {
                        if kind == "translation" {
                            Menu(aiReadingLabel("Copy translation")) {
                                Button(aiReadingLabel("Current page")) { if let text = translationText(result, page: state.currentPage) { copy(text) } }
                                Button(aiReadingLabel("All translated text")) { if let text = translationText(result, page: nil) { copy(text) } }
                            }
                        } else { Button { copy(result.content) } label: { Label(aiReadingLabel("Copy"), systemImage: "doc.on.doc") } }
                        if kind == "summary" { Button { reading.keep(result) } label: { Label(aiReadingLabel("Keep in notes"), systemImage: "note.text.badge.plus") } }
                    }.controlSize(.small)
                    if storeVersions(result).count > 1 {
                        DisclosureGroup(aiReadingLabel("Previous results")) {
                            ForEach(Array(storeVersions(result).dropFirst().enumerated()), id: \.offset) { _, old in
                                answer(old.content, pages: old.pages).padding(.vertical, 8)
                            }
                        }.font(.caption)
                    }
                } else if !busy {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: kind == "summary" ? "text.alignleft" : "character.bubble").font(.system(size: 28, weight: .light)).foregroundStyle(LyraReaderTheme.accent)
                        Text(aiReadingLabel(kind == "summary" ? "Get the shape of this document" : "Read across languages")).font(.headline)
                        Text(aiReadingLabel(kind == "summary" ? "An overview, key ideas and links back to the source." : "A continuous translation with the original source close at hand."))
                            .font(.callout).foregroundStyle(LyraReaderTheme.textSecondary)
                    }.padding(.vertical, 12)
                }
                if let error = worker.errorMessage {
                    Text(error).font(.caption).foregroundStyle(knowledge.isBlocking ? LyraReaderTheme.textSecondary : LyraReaderTheme.errorFg).textSelection(.enabled)
                }
                if !reading.settings.canUseAI { Text(aiReadingLabel("Connect an AI provider in Settings to continue.")).font(.caption) }
                Button {
                    reading.run(kind, state: state, force: reading.result(kind) != nil)
                } label: {
                    Label(aiReadingLabel(result == nil ? (kind == "summary" ? (selected ? "Summarize selection" : "Summarize document") : (selected ? "Translate selection" : "Translate document")) : (kind == "summary" ? "Regenerate" : "Retranslate")), systemImage: result == nil ? "sparkles" : "arrow.clockwise")
                }.buttonStyle(ReaderPanelButtonStyle(prominent: true))
                    .disabled(busy || knowledge.isBlocking || !reading.store.isAvailable || !reading.settings.canUseAI || selected && reading.excerpt(kind).isEmpty)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(AIReadingScrollMemory(key: "\(state.document?.id.uuidString ?? "none"):\(kind)", reading: reading))
        }.id(kind)
    }
    @ViewBuilder private func translationResult(_ result: AiReadingRecord) -> some View {
        if result.status != "sourceChanged" {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(aiTranslationTerms(originals: result.originals), id: \.self) { term in
                        Button(term) { selectedTerm = term }.font(.caption)
                    }
                }
            }
            if let term = selectedTerm {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Spacer(); Button { selectedTerm = nil } label: { Image(systemName: "xmark") }.accessibilityLabel(aiReadingLabel("Close term explanation")) }
                    AIReadingTermView(state: state, settings: reading.settings, term: term, language: result.language)
                }.padding(10).background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        if let blocks = try? aiTranslationBlocks(originals: result.originals, pages: result.originalPages, response: result.content),
           blocks.contains(where: { !$0.translation.isEmpty }) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                VStack(alignment: .leading, spacing: 10) {
                    if reading.showOriginal { Text(block.original).font(.callout).foregroundStyle(LyraReaderTheme.textSecondary).textSelection(.enabled) }
                    if block.translation.isEmpty { Text(aiReadingLabel("Translation incomplete")).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary) }
                    else { answer(block.translation, pages: [block.page]) }
                    Button("Original · p. \(block.page)") { reading.locate(page: block.page, excerpt: block.original, state: state) }.font(.caption)
                }.padding(.vertical, 10)
                Divider().overlay(LyraReaderTheme.separator)
            }
        } else {
            Text(aiReadingLabel("Paragraph alignment is unavailable for this response. The returned text is preserved below.")).font(.caption).foregroundStyle(LyraReaderTheme.warningFg)
            answer(result.content, pages: result.pages)
        }
    }
    private func taskHistory(_ kind: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button { showingTaskHistory = false; selectedTaskID = nil } label: { Label(aiReadingLabel("Current task"), systemImage: "chevron.left") }
                let records = reading.store.records.filter { $0.kind == kind }.sorted { $0.modified > $1.modified }
                if let selected = records.first(where: { $0.id == selectedTaskID }) {
                    Button(aiReadingLabel("All task results")) { selectedTaskID = nil }
                    Text(selected.title).font(.headline)
                    Text("\(selected.language.isEmpty ? "Document language" : selected.language) · \(selected.detail) · \(selected.model)")
                        .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                    if selected.status == "sourceChanged" { Text(aiReadingLabel("The source document has changed. This result retains its original source snapshot.")).font(.caption) }
                    if kind == "translation" { translationResult(selected) }
                    else {
                        AIReadingSummaryContent(text: selected.content, pageCount: state.document?.pageCount ?? 0, pages: selected.pages, onJump: { state.gotoPage($0 - 1) })
                        Button(aiReadingLabel("Keep in notes")) { reading.keep(selected) }
                    }
                    Button(aiReadingLabel("Copy result")) { copy(selected.content) }
                    DisclosureGroup(aiReadingLabel("Saved source")) { Text(selected.excerpt).font(.caption).lineLimit(12).textSelection(.enabled) }
                } else if records.isEmpty {
                    ContentUnavailableView(aiReadingLabel("No saved task results"), systemImage: "clock")
                } else {
                    ForEach(records, id: \.id) { record in
                        Button { selectedTaskID = record.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.title).font(.headline)
                                Text("\(record.language.isEmpty ? "Document language" : record.language) · \(record.detail)").font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                                Text(record.content).font(.caption).lineLimit(3).foregroundStyle(LyraReaderTheme.textSecondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func translationText(_ record: AiReadingRecord, page: Int?) -> String? {
        do {
            let blocks = try aiTranslationBlocks(originals: record.originals, pages: record.originalPages, response: record.content)
            let text = blocks.filter { page == nil || Int($0.page) == page }.map(\.translation).filter { !$0.isEmpty }.joined(separator: "\n\n")
            if text.isEmpty && page != nil { reading.notice = "This page has no aligned translation to copy."; return nil }
            return text.isEmpty ? record.content : text
        } catch { reading.notice = error.localizedDescription; return page == nil ? record.content : nil }
    }
    private func storeVersions(_ result: AiReadingRecord) -> [AiReadingRecord] {
        reading.store.records.filter { $0.kind == result.kind && $0.sourceId == result.sourceId }.sorted { $0.modified > $1.modified }
    }
    private func answer(_ text: String, pages: [UInt32]) -> some View {
        AIAnswerView(text: text, pageCount: state.document?.pageCount ?? 0,
                     verifiedPages: Set(pages.map(Int.init)), onJump: { state.gotoPage($0 - 1) })
    }
    private var conversationHistory: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(reading.sessions, id: \.id) { session in
                    Button { reading.openSession(session.id, pageCount: state.document?.pageCount ?? 0); history = false } label: {
                        Label(session.title, systemImage: "bubble.left").lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).padding(8)
                }
            }.padding(8)
        }.frame(maxHeight: 180).background(LyraReaderTheme.fieldBg)
    }

    private var notes: some View {
        Group {
            if let id = reading.selectedNoteID, let note = reading.store.records.first(where: { $0.id == id }) {
                noteDetail(note)
            } else {
                VStack(spacing: 12) {
                    TextField(aiReadingLabel("Search reading notes"), text: $search)
                    Picker(aiReadingLabel("Sort"), selection: $recent) { Text(aiReadingLabel("Page order")).tag(false); Text(aiReadingLabel("Recent")).tag(true) }.pickerStyle(.segmented)
                    let notes = reading.store.notes(query: search, recent: recent)
                    if notes.isEmpty {
                        ContentUnavailableView(aiReadingLabel(search.isEmpty ? "Keep the ideas you discover" : "No matching notes"), systemImage: "note.text",
                            description: Text(aiReadingLabel(search.isEmpty ? "Save a summary, a Chat answer, or finish an Interleaf discussion." : "Try another search or clear the search field.")))
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(notes, id: \.id) { note in
                                    Button { reading.selectedNoteID = note.id; editing = false } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(sourceLabel(note)).font(.caption2).foregroundStyle(LyraReaderTheme.textSecondary)
                                            Text(note.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(LyraReaderTheme.textPrimary)
                                            Text(note.content).font(.caption).lineLimit(3).foregroundStyle(LyraReaderTheme.textSecondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                                    }.buttonStyle(.plain)
                                    Divider().overlay(LyraReaderTheme.separator)
                                }
                            }
                        }
                    }
                }.padding(16)
            }
        }
    }
    private func isWholeDocumentNote(_ note: AiReadingRecord) -> Bool {
        reading.store.records.contains { $0.id == note.sourceId && $0.kind == "summary" && $0.sourceId == "document" }
    }
    private func sourceLabel(_ note: AiReadingRecord) -> String {
        if isWholeDocumentNote(note) { return aiReadingLabel("Summary · Whole document") }
        let kind = note.sourceId.hasPrefix("interleaf:") ? "Interleaf" :
            (reading.store.records.first(where: { $0.id == note.sourceId })?.kind == "summary" ? "Summary" : "Chat")
        return kind + " · " + note.pages.map { "p. \($0)" }.joined(separator: ", ")
    }
    private func noteDetail(_ note: AiReadingRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button { reading.selectedNoteID = nil; editing = false } label: { Label(aiReadingLabel("All notes"), systemImage: "chevron.left") }
                    Spacer(); Text(aiReadingLabel("Saved")).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                }
                if editing {
                    TextField(aiReadingLabel("Title"), text: $noteTitle)
                    Text(aiReadingLabel("Key ideas")).font(.headline)
                    TextEditor(text: $noteContent).frame(minHeight: 220).padding(6).background(LyraReaderTheme.fieldBg)
                    Text(aiReadingLabel("My thoughts")).font(.headline)
                    TextEditor(text: $noteThoughts).frame(minHeight: 100).padding(6).background(LyraReaderTheme.noteBg)
                    HStack {
                        Button(aiReadingLabel("Save changes")) {
                            var updated = note; updated.title = noteTitle; updated.content = noteContent; updated.thoughts = noteThoughts
                            updated.modified = UInt64(Date().timeIntervalSince1970 * 1000)
                            reading.store.put(updated); editing = false
                        }.buttonStyle(ReaderPanelButtonStyle(prominent: true))
                        Button(aiReadingLabel("Cancel")) { editing = false }
                    }
                } else {
                    Text(note.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(sourceLabel(note)).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                    Button(aiReadingLabel("Edit note")) {
                        let current = reading.store.records.first(where: { $0.id == note.id }) ?? note
                        noteTitle = current.title; noteContent = current.content; noteThoughts = current.thoughts; editing = true
                    }
                    if let entry = state.currentRegionHistory.first(where: { $0.id.uuidString == note.conversationId }),
                       entry.allTurns.count > Int(note.coveredTurns), reading.store.suggestion(note.id) == nil {
                        if reading.updatingNoteID == note.id {
                            HStack { ProgressView().controlSize(.small); Text(aiReadingLabel("Updating ideas…")); Spacer(); Button(aiReadingLabel("Stop")) { reading.stopNoteUpdate() } }
                        } else {
                            Button(aiReadingLabel("Update from conversation")) { reading.updateNote(note, state: state) }
                                .disabled(reading.updatingNoteID != nil || knowledge.isBlocking)
                        }
                    }
                    if let suggestion = reading.store.suggestion(note.id) {
                        DisclosureGroup(aiReadingLabel("Conversation updated · review new ideas")) {
                            answer(suggestion.content, pages: suggestion.pages)
                            HStack {
                                Button(aiReadingLabel("Apply suggestion")) { reading.store.applySuggestion(note.id, apply: true) }
                                Button(aiReadingLabel("Keep current note")) { reading.store.applySuggestion(note.id, apply: false) }
                            }
                        }.padding(12).background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text(aiReadingLabel("Key ideas")).font(.headline)
                    answer(note.content, pages: note.pages)
                    Text(aiReadingLabel("My thoughts")).font(.headline)
                    AIReadingTextInput(text: Binding(get: {
                        reading.store.records.first(where: { $0.id == note.id })?.thoughts ?? note.thoughts
                    }, set: { text in
                        guard var updated = reading.store.records.first(where: { $0.id == note.id }) else { return }
                        updated.thoughts = text; updated.modified = UInt64(Date().timeIntervalSince1970 * 1000)
                        reading.store.put(updated)
                    }), placeholder: aiReadingLabel("Add your own thoughts…"))
                        .id(note.id).frame(height: 112)
                        .background(LyraReaderTheme.noteBg, in: RoundedRectangle(cornerRadius: 8))
                    if note.status == "sourceChanged" { Text(aiReadingLabel("The source document has changed. The saved knowledge and source snapshot are preserved.")).font(.caption).foregroundStyle(LyraReaderTheme.warningFg) }
                    if isWholeDocumentNote(note) {
                        Button(aiReadingLabel("Locate whole document")) { state.gotoPage(0) }
                    } else {
                        if !note.excerpt.isEmpty { DisclosureGroup(aiReadingLabel("Source")) { Text(note.excerpt).font(.caption).lineLimit(8).textSelection(.enabled) } }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(note.pages, id: \.self) { page in Button("p. \(page)") { reading.locate(page: page, excerpt: note.excerpt, state: state) } }
                            }
                        }
                    }
                    if !note.question.isEmpty {
                        DisclosureGroup(aiReadingLabel("View conversation")) {
                            Text(note.question).font(.callout).textSelection(.enabled)
                            if !note.sourceId.hasPrefix("interleaf:"), let source = reading.store.records.first(where: { $0.id == note.sourceId }) {
                                answer(source.content, pages: source.pages)
                            }
                        }
                    }
                    if let entry = state.currentRegionHistory.first(where: { $0.id.uuidString == note.conversationId }) {
                        Button(aiReadingLabel("Continue at source")) { _ = state.reopenRegionCard(from: entry) }
                    } else if !note.conversationId.isEmpty {
                        Button(aiReadingLabel("Continue conversation")) { reading.openSession(note.conversationId, pageCount: state.document?.pageCount ?? 0); navigation.selectedTab = .chat }
                    }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); reading.notice = "Copied" }
}

private struct AIReadingSidebarMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> AIAssistantPanelMarkerView { AIAssistantPanelMarkerView(frame: .zero) }
    func updateNSView(_ nsView: AIAssistantPanelMarkerView, context: Context) { }
}

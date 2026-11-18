import AppKit
import Combine
import Foundation
import LyraReaderBindings

/// Native task orchestration only. Plans, source selection, note rules and durable records
/// are provided by Rust; each tool has a separate transport handle and presentation state.
@MainActor
final class AIReadingModel: ObservableObject {
    let summary: AIAssistantModel
    let translation: AIAssistantModel
    let chat: AIAssistantModel
    let store = AIReadingStore()
    let settings: AISettingsStore
    /// Deterministic native checks inject a mock transport; production keeps this nil.
    var serviceOverride: (any AIChatServicing)?
    private func service(_ state: AppState) -> (any AIChatServicing)? { serviceOverride ?? state.aiChatService }
    @Published var detail = "Standard"
    @Published var summarySelection = false
    @Published var translationSelection = false
    @Published var language = ""
    @Published var translationLanguage = "English"
    @Published var showOriginal = true
    @Published private(set) var translationResultID: String?
    private var translationDraft = false
    @Published var notice: String?
    @Published var sessionID = UUID().uuidString
    @Published var selectedNoteID: String?
    @Published var updatingNoteID: String?
    private var noteWorker: AIAssistantModel?
    private weak var analysisOwner: AIDocumentKnowledge?
    private var noteGeneration = UUID()
    private var documentKey: String?
    private var documentInstance: UUID?
    private var sourceURL: URL?
    let presentationID = UUID().uuidString
    var scrollPositions: [String: CGPoint] = [:]
    private struct Presentation {
        var summarySelection: Bool; var translationSelection: Bool
        var detail: String; var language: String; var translationLanguage: String; var original: Bool
        var summary: AIReaderContext?; var translation: AIReaderContext?
        var summaryExcerpt: String; var translationExcerpt: String
        var translationResultID: String?; var translationDraft: Bool
    }
    private var presentations: [String: Presentation] = [:]
    private var generation = UUID()
    private var activeResults: [String: AiReadingRecord] = [:]
    private var operations: [String: Task<Void, Never>] = [:]
    private var bindings = Set<AnyCancellable>()
    private var frozenSummary: AIReaderContext?
    private var frozenTranslation: AIReaderContext?
    private var summaryExcerpt = ""
    private var translationExcerpt = ""

    init(settings: AISettingsStore, audit: AIAuditTrail) {
        self.settings = settings
        language = settings.outputLanguage
        translationLanguage = settings.outputLanguage.isEmpty ? (Locale.preferredLanguages.first ?? "English") : settings.outputLanguage
        summary = AIAssistantModel(settings: settings, audit: audit)
        translation = AIAssistantModel(settings: settings, audit: audit)
        chat = AIAssistantModel(settings: settings, audit: audit)
        for worker in [summary, translation, chat] {
            worker.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bindings)
            worker.$phase.dropFirst().sink { [weak self, weak worker] phase in
                Task { @MainActor in
                    guard let self, let worker else { return }
                    if phase == .mergePreview, worker.mergePlan != nil { worker.sendMerge() }
                    if phase.isTerminal && worker.phase == phase { self.saveCompleted(worker) }
                }
            }.store(in: &bindings)
        }
        // A synthesis plan arrives after the phase change, so observe the plan separately.
        summary.$mergePlan.compactMap { $0 }.sink { [weak self] _ in
            Task { @MainActor in
                guard let self, self.summary.phase == .mergePreview else { return }
                self.summary.sendMerge()
            }
        }.store(in: &bindings)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            self?.cancelPresentation(); self?.store.finishPendingWrites()
        }.store(in: &bindings)
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bindings)
        settings.$outputLanguage.dropFirst().sink { [weak self] language in self?.language = language }.store(in: &bindings)
        chat.$chatQuestion.dropFirst().debounce(for: .milliseconds(400), scheduler: RunLoop.main).sink { [weak self] _ in
            self?.saveChat()
        }.store(in: &bindings)
        store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bindings)
    }

    var isBusy: Bool { [summary, translation, chat].contains { $0.isPreparing || $0.isSending } }
    var sessions: [AiReadingRecord] { store.records.filter { $0.kind == "conversation" }.sorted { $0.modified > $1.modified } }
    func result(_ kind: String) -> AiReadingRecord? {
        if kind == "translation" {
            if translationDraft { return nil }
            if let translationResultID { return store.taskHistory(kind).first { $0.id == translationResultID } }
        }
        return store.taskHistory(kind, sourceID: scopeID(kind)).first
    }
    func openTranslation(_ record: AiReadingRecord) {
        guard record.kind == "translation" else { return }
        translationSelection = record.sourceId != aiReadingScopeKey(selection: nil)
        translationLanguage = record.language
        translationExcerpt = record.excerpt
        translationDraft = false
        translationResultID = record.id
    }
    func changeTranslationSource(selection: Bool, state: AppState) {
        translationSelection = selection
        translationResultID = nil; translationDraft = false
        if selection { useSelection("translation", state: state) }
    }
    private func restoreTranslationSource(_ record: AiReadingRecord, live: AIReaderContext) throws {
        let selection = try store.taskSelection(record.id)
        translationSelection = selection != nil
        frozenTranslation = AIReaderContext(documentKey: live.documentKey, documentTitle: live.documentTitle,
            pageCount: live.pageCount, currentPage: live.currentPage, selection: selection.map {
                AIReaderSelection(page: Int($0.page) + 1, start: Int($0.start), end: Int($0.end))
            })
    }
    private func scopeID(_ kind: String) -> String {
        let selected = kind == "summary" ? summarySelection : translationSelection
        guard selected else { return aiReadingScopeKey(selection: nil) }
        let selection = (kind == "summary" ? frozenSummary : frozenTranslation)?.selection
        guard let selection, selection.page > 0,
              let page = UInt32(exactly: selection.page - 1), let start = UInt32(exactly: selection.start),
              let end = UInt32(exactly: selection.end) else { return "selection:missing" }
        return aiReadingScopeKey(selection: AiSelectionRecord(page: page, start: start, end: end))
    }
    func worker(_ kind: String) -> AIAssistantModel { kind == "summary" ? summary : translation }
    func excerpt(_ kind: String) -> String { kind == "summary" ? summaryExcerpt : translationExcerpt }
    func selectionPage(_ kind: String) -> Int? { (kind == "summary" ? frozenSummary : frozenTranslation)?.selection?.page }

    func bind(_ state: AppState) async {
        guard let context = state.aiReaderContext else { return }
        let instance = state.document?.id
        let currentSource = state.document?.url
        guard documentKey != context.documentKey || documentInstance != instance || sourceURL != currentSource else {
            while store.isLoading && documentKey == context.documentKey {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
            guard documentKey == context.documentKey, documentInstance == instance, sourceURL == currentSource else { return }
            for worker in [summary, translation, chat] { worker.attach(service: service(state), context: context) }
            return
        }
        let revisedInPlace = documentKey == context.documentKey && (documentInstance != instance || sourceURL != currentSource)
        cancelPresentation()
        if let documentKey {
            presentations[documentKey] = Presentation(summarySelection: summarySelection, translationSelection: translationSelection,
                detail: detail, language: language, translationLanguage: translationLanguage, original: showOriginal,
                summary: frozenSummary, translation: frozenTranslation, summaryExcerpt: summaryExcerpt, translationExcerpt: translationExcerpt,
                translationResultID: translationResultID, translationDraft: translationDraft)
        }
        noteWorker?.cancelRegionWork(); noteWorker = nil; updatingNoteID = nil
        generation = UUID(); documentKey = context.documentKey; documentInstance = instance; sourceURL = currentSource
        activeResults = [:]; frozenSummary = nil; frozenTranslation = nil
        translationResultID = nil; translationDraft = false
        selectedNoteID = nil; notice = nil
        if let saved = presentations[context.documentKey] {
            summarySelection = saved.summarySelection; translationSelection = saved.translationSelection
            detail = saved.detail; language = saved.language; translationLanguage = saved.translationLanguage; showOriginal = saved.original
            frozenSummary = saved.summary; frozenTranslation = saved.translation
            summaryExcerpt = saved.summaryExcerpt; translationExcerpt = saved.translationExcerpt
            translationResultID = saved.translationResultID; translationDraft = saved.translationDraft
        } else {
            summarySelection = false; translationSelection = false; detail = "Standard"
            summaryExcerpt = ""; translationExcerpt = ""
        }
        if revisedInPlace { frozenSummary = nil; frozenTranslation = nil; summaryExcerpt = ""; translationExcerpt = "" }
        for worker in [summary, translation, chat] { worker.attach(service: service(state), context: context) }
        await store.load(document: state.translationDocumentURL ?? state.document?.url,
            identity: "\(context.documentKey):\(instance?.uuidString ?? "none"):\(currentSource?.path ?? "none")", source: state.document?.url)
        guard documentKey == context.documentKey, documentInstance == instance else { return }
        if let translationResultID, let saved = store.taskHistory("translation").first(where: { $0.id == translationResultID }) {
            translationExcerpt = saved.excerpt
        }
        if presentations[context.documentKey] == nil, let latest = store.taskHistory("translation").first { openTranslation(latest) }
        if let session = sessions.first { openSession(session.id, pageCount: context.pageCount, saveCurrent: false) }
        else { newSession(pageCount: context.pageCount, saveCurrent: false) }
        importInterleaf(state)
    }

    func cancelPresentation() {
        if analysisOwner?.reader === summary { analysisOwner?.cancel() }
        generation = UUID()
        for task in operations.values { task.cancel() }; operations.removeAll()
        for worker in [summary, translation, chat] { worker.cancelRegionWork(); saveCompleted(worker) }
        saveChat()
        noteGeneration = UUID()
        noteWorker?.cancelRegionWork(); noteWorker = nil; updatingNoteID = nil
    }

    func locate(page: UInt32, excerpt: String, state: AppState) {
        guard let engine = state.engine as? RustEngine, let key = state.aiReaderContext?.documentKey, page > 0 else { return }
        Task {
            do {
                let rects = try await engine.locateAIReadingSource(page: page - 1, text: excerpt)
                guard state.aiReaderContext?.documentKey == key else { return }
                if rects.isEmpty { state.gotoPage(Int(page) - 1) }
                else { state.revealAISource(page: Int(page) - 1, rects: rects.map {
                    CGRect(x: $0.xPt, y: $0.yPt, width: $0.widthPt, height: $0.heightPt)
                }) }
            } catch { notice = AIReadableError.message(error) }
        }
    }
    func locateSelection(_ kind: String, state: AppState) {
        guard let selection = (kind == "summary" ? frozenSummary : frozenTranslation)?.selection else { return }
        locate(page: UInt32(selection.page), excerpt: excerpt(kind), state: state)
    }

    func useSelection(_ kind: String, state: AppState) {
        guard let context = state.aiReaderContext, state.selection != nil,
              let excerpt = state.selectedPassageText else { return }
        if kind == "summary" { frozenSummary = context; summaryExcerpt = excerpt }
        else {
            frozenTranslation = context; translationExcerpt = excerpt
            translationResultID = nil; translationDraft = true
        }
    }

    func run(_ kind: String, state: AppState, force: Bool = false) {
        guard let live = state.aiReaderContext, !state.documentKnowledge.isBlocking else { return }
        let worker = worker(kind)
        guard !worker.isPreparing, !worker.isSending else { return }
        if kind == "translation", translationResultID != nil, let record = result(kind) {
            do { try restoreTranslationSource(record, live: live) }
            catch { notice = AIReadableError.message(error); return }
        }
        let usesSelection = kind == "summary" ? summarySelection : translationSelection
        if usesSelection && (kind == "summary" ? frozenSummary : frozenTranslation) == nil { useSelection(kind, state: state) }
        let captured = usesSelection ? (kind == "summary" ? frozenSummary : frozenTranslation) : live
        guard var context = captured else { notice = "Select a passage first."; return }
        if !usesSelection {
            context = AIReaderContext(documentKey: live.documentKey, documentTitle: live.documentTitle,
                                      pageCount: live.pageCount, currentPage: live.currentPage, selection: nil)
        }
        guard !usesSelection || context.selection != nil else { notice = "Select a passage first."; return }
        if kind == "summary" && !usesSelection { analysisOwner = state.documentKnowledge }
        let token = generation
        let id = UUID().uuidString
        let outputLanguage = kind == "summary" ? language : translationLanguage
        let requestedDetail = detail
        let scope = usesSelection ? "Selected passage" : "Whole document"
        activeResults[kind] = .make(id: id, kind: kind, title: scope, sourceID: scopeID(kind),
            excerpt: usesSelection ? excerpt(kind) : "", language: outputLanguage, detail: requestedDetail, status: "preparing")
        if kind == "translation" { translationResultID = nil; translationDraft = true }
        worker.attach(service: service(state), context: context)
        operations[kind]?.cancel()
        operations[kind] = Task {
            let source = kind == "summary" && !usesSelection ? state.document?.url : nil
            let cache = state.translationDocumentURL ?? source
            var sharedLease: UInt64?
            defer { if let sharedLease { state.documentKnowledge.cancelSummary(model: worker, lease: sharedLease) } }
            if let source, let cache {
                do {
                    state.documentKnowledge.settings = settings
                    if !force, let cached = try await state.documentKnowledge.cachedSummary(sourceURL: source,
                        cacheDocumentURL: cache, language: outputLanguage, detail: requestedDetail) {
                        guard generation == token, activeResults[kind]?.id == id, !Task.isCancelled else { return }
                        worker.discard(); store.put(cached); activeResults.removeValue(forKey: kind)
                        return
                    }
                    sharedLease = try await state.documentKnowledge.prepareSummary(model: worker, sourceURL: source,
                        cacheDocumentURL: cache, language: outputLanguage, detail: requestedDetail, resultID: id,
                        retry: { [weak self, weak state] in guard let self, let state else { return }; self.run("summary", state: state, force: true) })
                } catch is CancellationError { return }
                catch { notice = AIReadableError.message(error); return }
            }
            let action: AIAssistantAction = usesSelection ? (kind == "summary" ? .summarizeSelection : .translateSelection) : .summarizeDocument
            await worker.prepare(action: action, context: context,
                                 reading: AiReadingOptionsRecord(kind: kind, detail: requestedDetail), outputLanguage: outputLanguage)
            guard generation == token, activeResults[kind]?.id == id, worker.phase == .preview, let plan = worker.plan else { return }
            if settings.reviewBeforeSending && source == nil {
                let approved = await AIReadingReviewWindow.review(plan)
                guard generation == token, activeResults[kind]?.id == id, worker.phase == .preview else { return }
                guard approved else { worker.cancelRegionWork(); return }
            }
            if let source, let cache, let sharedLease { state.documentKnowledge.sendSummary(model: worker, sourceURL: source, cacheDocumentURL: cache, lease: sharedLease) }
            else { worker.send() }
        }
    }

    func askChat(state: AppState) {
        guard let context = state.aiReaderContext, !state.documentKnowledge.isBlocking else { return }
        chat.attach(service: service(state), context: context)
        let token = generation
        let session = sessionID
        operations["chat"]?.cancel()
        operations["chat"] = Task {
            await chat.prepareDocumentChat(context: context)
            guard generation == token, sessionID == session, chat.phase == .preview, let plan = chat.plan else { return }
            if settings.reviewBeforeSending {
                let approved = await AIReadingReviewWindow.review(plan)
                guard generation == token, sessionID == session, chat.phase == .preview else { return }
                guard approved else { chat.cancelRegionWork(); return }
            }
            chat.send()
        }
    }

    private func saveCompleted(_ worker: AIAssistantModel) {
        guard documentKey == worker.documentKey, worker.phase.isTerminal else { return }
        if worker === chat { saveChat(); return }
        let kind = worker === summary ? "summary" : "translation"
        guard var record = activeResults[kind], !worker.answer.isEmpty, let plan = worker.plan else { return }
        record.content = worker.answer
        record.model = plan.model
        record.pages = worker.sentSourcePages
        record.originals = plan.sources.map(\.snippet)
        record.originalPages = plan.sources.map(\.page)
        if record.excerpt.isEmpty { record.excerpt = plan.sources.map(\.snippet).joined(separator: "\n\n") }
        record.status = worker.phase == .finished && worker.errorMessage == nil && worker.finishReason != "length" && !worker.hasTruncatedSource ? "finished" : "partial"
        record.modified = UInt64(Date().timeIntervalSince1970 * 1000)
        store.put(record)
        if kind == "translation" { translationResultID = record.id; translationDraft = false }
        activeResults.removeValue(forKey: kind)
    }

    func keep(_ record: AiReadingRecord) {
        if store.keep(record) != nil { notice = "Saved to Reading notes" }
    }
    func keepChat(_ turn: AIChatTurn) {
        var source = AiReadingRecord.make(id: turn.id.uuidString, kind: "message", title: turn.question,
            content: turn.answer, conversationID: sessionID, question: turn.question,
            pages: turn.sources.map { UInt32($0.page) }, excerpt: turn.sources.map(\.snippet).joined(separator: "\n\n"))
        source.originals = turn.sources.map(\.snippet); source.originalPages = turn.sources.map { UInt32($0.page) }
        keep(source)
    }
    func saveChat() {
        guard documentKey != nil else { return }
        let title = chat.chatTurns.first?.question ?? "New conversation"
        var records = [AiReadingRecord.make(id: sessionID, kind: "conversation", title: title, question: chat.chatQuestion)]
        for turn in chat.chatTurns {
            var record = AiReadingRecord.make(id: turn.id.uuidString, kind: "message", content: turn.answer,
                conversationID: sessionID, question: turn.question, pages: turn.sources.map { UInt32($0.page) },
                excerpt: turn.sources.map(\.snippet).joined(separator: "\n\n"),
                status: turn.state == .finished ? "finished" : "partial")
            record.originals = turn.sources.map(\.snippet); record.originalPages = turn.sources.map { UInt32($0.page) }
            records.append(record)
        }
        store.putAll(records)
    }

    func newSession(pageCount: Int, saveCurrent: Bool = true) {
        if saveCurrent { saveChat() }
        operations["chat"]?.cancel()
        chat.cancelRegionWork()
        sessionID = UUID().uuidString
        chat.restoreChat([], draft: "")
        saveChat()
    }
    func openSession(_ id: String, pageCount: Int, saveCurrent: Bool = true) {
        if saveCurrent { saveChat() }
        operations["chat"]?.cancel()
        chat.cancelRegionWork()
        sessionID = id
        let records = store.records.filter { $0.kind == "message" && $0.conversationId == id }.sorted { $0.modified < $1.modified }
        let turns = records.map { r in AIChatTurn(id: UUID(uuidString: r.id) ?? UUID(), question: r.question, answer: r.content,
            sources: zip(r.originalPages, r.originals).map { AIChatSource(page: Int($0.0), snippet: $0.1, rects: []) }, pageCount: pageCount,
            state: r.status == "finished" ? .finished : .cancelled) }
        chat.restoreChat(turns, draft: store.records.first { $0.id == id }?.question ?? "")
    }

    func stopNoteUpdate() {
        noteGeneration = UUID()
        operations["note"]?.cancel(); noteWorker?.cancelRegionWork()
        updatingNoteID = nil; noteWorker = nil
        notice = "Note update stopped. Your existing note is preserved."
    }

    func updateNote(_ note: AiReadingRecord, state: AppState) {
        guard updatingNoteID == nil, !state.documentKnowledge.isBlocking,
              let entry = state.currentRegionHistory.first(where: { $0.id.uuidString == note.conversationId }),
              let live = state.aiReaderContext else { return }
        let context = AIReaderContext(documentKey: live.documentKey, documentTitle: live.documentTitle,
            pageCount: live.pageCount, currentPage: entry.attachment.page + 1, selection: nil)
        let worker = AIAssistantModel(settings: settings)
        worker.attach(service: service(state), context: context)
        worker.question = aiReadingNoteInput(turns: entry.allTurns.filter { $0.state == .finished }.map {
            AiConversationTurnRecord(question: $0.question, answer: $0.answer)
        }, previous: note.content)
        noteWorker = worker; updatingNoteID = note.id
        noteGeneration = UUID(); let noteToken = noteGeneration
        let token = generation
        operations["note"] = Task {
            defer { if generation == token && noteGeneration == noteToken { updatingNoteID = nil; noteWorker = nil } }
            await worker.prepare(action: .summarizeDocument, context: context,
                reading: AiReadingOptionsRecord(kind: "note", detail: "Standard"), outputLanguage: settings.outputLanguage)
            guard generation == token && noteGeneration == noteToken else { return }
            guard worker.phase == .preview, let plan = worker.plan else {
                notice = worker.errorMessage ?? worker.statusNote; return
            }
            if settings.reviewBeforeSending {
                guard await AIReadingReviewWindow.review(plan), generation == token && noteGeneration == noteToken, worker.phase == .preview else { return }
            }
            worker.send()
            while !worker.phase.isTerminal {
                guard generation == token && noteGeneration == noteToken else { worker.cancelRegionWork(); return }
                if worker.phase == .mergePreview, worker.mergePlan != nil { worker.sendMerge() }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { worker.cancelRegionWork(); return }
            }
            guard generation == token && noteGeneration == noteToken, worker.phase == .finished, worker.errorMessage == nil, worker.finishReason != "length" else {
                notice = worker.errorMessage ?? "The note update stopped. Your existing note is preserved."; return
            }
            var source = AiReadingRecord.make(id: note.sourceId, kind: "message", title: note.title, content: worker.answer,
                conversationID: note.conversationId, question: worker.question, pages: worker.sentSourcePages,
                excerpt: note.excerpt, language: settings.outputLanguage, detail: note.detail)
            source.coveredTurns = UInt32(entry.allTurns.count)
            store.put(source)
            notice = "New ideas are ready to review"
        }
    }

    func importInterleaf(_ state: AppState) {
        for entry in state.currentRegionHistory where !entry.knowledgeNote.isEmpty {
            var source = AiReadingRecord.make(id: "interleaf:\(entry.id.uuidString)", kind: "message",
                title: "Interleaf · \(entry.attachment.pageLabel)", content: entry.knowledgeNote,
                conversationID: entry.id.uuidString, question: entry.allTurns.map { "Q: \($0.question)\n\n\($0.answer)" }.joined(separator: "\n\n" ),
                pages: [UInt32(entry.attachment.page + 1)], excerpt: entry.attachment.text,
                detail: "Interleaf · \(entry.allTurns.count) rounds")
            source.coveredTurns = UInt32(entry.noteTurnCount ?? 0)
            if let existing = store.records.first(where: { $0.id == source.id }), existing.coveredTurns > source.coveredTurns { continue }
            store.put(source)
            if let saved = store.records.first(where: { $0.id == source.id }) { _ = store.keep(saved) }
        }
    }
}

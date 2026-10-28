import Foundation
import LyraReaderBindings
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func optionalDocumentKnowledgeChecks(root: URL) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-optional-reading-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("reading.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: source)
        let domain = "lyra-optional-reading-\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AISettingsStore(defaults: defaults, keyStore: InMemoryAPIKeyStore(key: "mock"))
        _ = settings.save(baseURL: "http://localhost:11434/v1", model: "mock", temperature: 0.2,
                          maxTokens: 900, apiKey: nil)
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        require(state.open(url: source), "optional reading fixture opens")
        let context = state.aiReaderContext!
        let service = HeldReadingService(engine: engine)
        let skipped = AIDocumentKnowledge(); skipped.settings = settings
        let choice = Task { try await skipped.ensure(service: service, context: context,
            sourceURL: source, cacheDocumentURL: source) }
        try await eventually("optional reading offers a choice before sending", { skipped.phase == .consent })
        skipped.continueWithoutSummary()
        let empty = try await choice.value
        require(empty.isEmpty && !skipped.isPresented && service.handles.isEmpty,
                "continuing without reading sends no whole-document request")
        let request = AIMakePlanRequest(action: .summarizePage, currentPage: 1, selection: nil,
            question: nil, language: nil, settings: try settings.providerSettings())
        let skipService = DocumentKnowledgeService(base: service, knowledge: skipped, context: context,
            sourceURL: source, cacheDocumentURL: source)
        _ = try await skipService.prepare(request)
        require(service.lastRequest?.documentKnowledgeText == nil,
                "AI actions prepare their own source context after skipping the summary")

        let background = AIDocumentKnowledge(); background.settings = settings
        let begin = Task { try await background.ensure(service: service, context: context,
            sourceURL: source, cacheDocumentURL: source) }
        try await eventually("background reading asks before network work", { background.phase == .consent })
        background.proceed()
        let released = try await begin.value
        require(released.isEmpty && !background.isPresented,
                "starting background reading releases the original action before any answer")
        try await eventually("the background request starts", { service.handles.count == 1 })
        let wrapped = DocumentKnowledgeService(base: service, knowledge: background, context: context,
            sourceURL: source, cacheDocumentURL: source)
        var prepared = false
        let another = Task { _ = try await wrapped.prepare(request); prepared = true }
        try await eventually("another AI action prepares while the provider has not answered", { prepared })
        try await another.value
        service.handles[0].fail()
        try await eventually("a slow provider failure becomes nonmodal status", { background.phase == .failed })
        let afterFailure = try await background.ensure(service: service, context: context,
            sourceURL: source, cacheDocumentURL: source)
        require(afterFailure.isEmpty && !background.isPresented && background.statusVisible,
                "an idle timeout cannot lock subsequent AI actions behind a retry sheet")
        background.retry()
        try await eventually("retry asks again without sending automatically", { background.phase == .consent })
        require(service.handles.count == 1, "retry planning sends nothing before consent")
        background.proceed()
        try await eventually("a second background request starts", { service.handles.count == 2 })
        background.stopReading()
        background.retry()
        try await eventually("stopping and immediately retrying cannot be overwritten by the old task", {
            background.phase == .consent
        })
        background.continueWithoutSummary()
        try await eventually("reading remains optional after a stop", { !background.isPresented })
        background.invalidate()
        require(background.record == nil && !background.statusVisible && !background.isPresented,
                "leaving a document clears its background result and status")
    }
}

@MainActor private final class HeldReadingService: AIChatServicing {
    let base: RustAIChatService
    var handles: [HeldReadingHandle] = []
    var lastRequest: AIMakePlanRequest?
    init(engine: RustEngine) { base = RustAIChatService(engine: engine, useMockProvider: true) }
    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        lastRequest = request
        return try await base.prepare(request)
    }
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        let handle = HeldReadingHandle(); handles.append(handle); return handle
    }
}

@MainActor private final class HeldReadingHandle: AIChatHandle {
    var isFinished = false
    private var events: [AIStreamEvent] = []
    func fail() { events = [.error(message: "the idle timeout expired", cancelled: false)] }
    func poll() -> [AIStreamEvent] {
        let pending = events; events = []
        if !pending.isEmpty { isFinished = true }
        return pending
    }
    func cancel() { isFinished = true; events = [] }
}

import AppKit
import Foundation
import LyraReaderBindings
@testable import LyraReaderKit

@MainActor private final class SharedUnderstandingService: AIChatServicing {
    let base: RustAIChatService
    var sent: [AiPlanRecord] = []
    var partCount = 1
    var truncateSources = false
    var holdNextPreparation = false
    var heldPreparation: CheckedContinuation<Void, Never>?
    init(engine: RustEngine) { base = RustAIChatService(engine: engine, useMockProvider: true) }
    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord { try await base.prepare(request) }
    func prepareReading(_ request: AIMakePlanRequest, options: AiReadingOptionsRecord) async throws -> AiPlanRecord {
        if holdNextPreparation {
            holdNextPreparation = false
            await withCheckedContinuation { heldPreparation = $0 }
        }
        var plan = try await base.prepareReading(request, options: options)
        if partCount > 1, let first = plan.parts.first {
            plan.parts = (0..<partCount).map { index in var part = first; part.index = UInt32(index); part.total = UInt32(partCount); return part }
        }
        return plan
    }
    func prepareMerge(_ request: AIMergePlanRequest) async throws -> AiPlanRecord { try await base.prepareMerge(request) }
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        sent.append(plan); return SharedUnderstandingHandle(plan: plan, truncate: truncateSources && plan.parts.count > 1)
    }
}
@MainActor private final class SharedUnderstandingHandle: AIChatHandle {
    var isFinished = false
    let plan: AiPlanRecord
    let truncate: Bool
    init(plan: AiPlanRecord, truncate: Bool) { self.plan = plan; self.truncate = truncate }
    func poll() -> [AIStreamEvent] {
        guard !isFinished else { return [] }; isFinished = true
        var events: [AIStreamEvent] = []
        for part in plan.parts {
            events += [.partStarted(index: Int(part.index), total: Int(part.total), label: "Synthetic document"),
                .delta("# Overview\nA synthetic research purpose [p.1].\n\n## Key ideas\nA synthetic method [p.1].\n\n## Limitations\nOnly the supplied evidence is available.")]
            if truncate && part.index == 0 {
                events.append(.diagnostics(AIStreamDiagnostics(httpStatus: 200, bytes: 100, frames: 2,
                    dataFrames: 2, contentFrames: 1, reasoningFrames: 0, roleOnlyFrames: 0, emptyFrames: 0,
                    usageFrames: 0, contentShape: "synthetic", finishReason: "length", usage: AIUsage())))
            }
        }
        return events + [.usage(AIUsage(promptTokens: 120, completionTokens: 20, totalTokens: 140, cachedTokens: 100)), .done]
    }
    func cancel() { isFinished = true }
}

extension ReaderChecks {
    @MainActor static func sharedDocumentUnderstandingChecks(root: URL) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-shared-reading-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let domain = "lyra-shared-reading-\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AISettingsStore(defaults: defaults, keyStore: InMemoryAPIKeyStore(key: "mock"))
        settings.prereadingPolicy = "ask"
        _ = settings.save(baseURL: "http://localhost:11434/v1", model: "mock", temperature: 0.2, maxTokens: 900, apiKey: nil)
        let source = folder.appendingPathComponent("summary-first.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: source)
        let engine = try RustEngine(); let state = AppState(engine: engine)
        require(state.open(url: source), "the shared analysis fixture opens")
        let service = SharedUnderstandingService(engine: engine)
        let knowledge = state.documentKnowledge; knowledge.settings = settings
        let context = state.aiReaderContext!
        let wrapped = DocumentKnowledgeService(base: service, knowledge: knowledge, context: context, sourceURL: source, cacheDocumentURL: source)
        let reading = AIReadingModel(settings: settings, audit: AIAuditTrail.shared)
        reading.serviceOverride = wrapped
        await reading.bind(state)
        reading.run("summary", state: state)
        try await eventually("Summary itself completes the shared full-document analysis", {
            reading.result("summary")?.status == "finished" && knowledge.phase == .ready
        })
        require(service.sent.count == 1 && !knowledge.isPresented,
                "Summary does not first send a redundant prereading request or ask a second consent question")
        require(knowledge.record?.summary == reading.result("summary")?.content,
                "Summary and prereading publish the same completed understanding")
        reading.chat.chatQuestion = "这篇文章的研究目的是什么？"
        reading.askChat(state: state)
        try await eventually("Chat uses the completed analysis without another preread", {
            reading.chat.phase == .finished && service.sent.count == 2
        })
        let first = service.sent[0].parts[0]; let second = service.sent[1].parts[0]
        let marker = "[End document original sources]\n\n"
        let end = first.userPrompt.range(of: marker)!.upperBound
        require(second.systemPrompt == first.systemPrompt && second.userPrompt.hasPrefix(String(first.userPrompt[..<end])),
                "Summary and Chat retain byte-identical system and original-text prefixes")
        require(!second.userPrompt.contains("[Shared document understanding"),
                "short documents do not send a duplicate generated digest")
        require(reading.chat.usage?.cachedTokens == 100 && reading.chat.usage?.totalTokens == 140,
                "reported cached input remains a subset rather than additional usage")
        let file = DocumentEditCache.directory(for: source).appendingPathComponent("document-understanding-v2.json")
        try await eventually("the Rust analysis is persisted by native I/O", { FileManager.default.fileExists(atPath: file.path) })
        let reopened = AIDocumentKnowledge(); reopened.settings = settings
        let restored = try await reopened.ensure(service: service, context: context, sourceURL: source, cacheDocumentURL: source)
        require(restored == knowledge.record?.summary && service.sent.count == 2,
                "reopening reuses the source-matched analysis without a provider request")

        let other = folder.appendingPathComponent("preread-first.pdf")
        try FileManager.default.copyItem(at: source, to: other)
        let otherEngine = try RustEngine(); let otherState = AppState(engine: otherEngine)
        require(otherState.open(url: other), "the preread-first fixture opens")
        let otherService = SharedUnderstandingService(engine: otherEngine)
        let otherKnowledge = otherState.documentKnowledge; otherKnowledge.settings = settings
        let liveOther = otherState.aiReaderContext!
        let otherContext = AIReaderContext(documentKey: liveOther.documentKey, documentTitle: liveOther.documentTitle,
            pageCount: liveOther.pageCount, currentPage: liveOther.currentPage,
            selection: AIReaderSelection(page: 1, start: 0, end: 3))
        let request = Task { try await otherKnowledge.ensure(service: otherService, context: otherContext, sourceURL: other, cacheDocumentURL: other) }
        try await eventually("prereading still asks before any provider work", { otherKnowledge.phase == .consent })
        let choiceReader = otherKnowledge.reader
        do { _ = try await otherKnowledge.prepareSummary(model: AIAssistantModel(settings: settings), sourceURL: other,
            cacheDocumentURL: other, language: "", detail: "Standard", resultID: UUID().uuidString, retry: {})
            require(false, "another Summary cannot replace an active prereading choice") }
        catch { require(error is AIPreReadingPause && otherKnowledge.phase == .consent && otherKnowledge.reader === choiceReader,
            "Summary preparation preserves the active choice and its original reader") }
        otherKnowledge.proceed()
        do { _ = try await request.value; require(false, "prereading pauses the original action") }
        catch { require(error is AIPreReadingPause, "the approved preread uses the existing recoverable gate") }
        try await eventually("the preread-first analysis completes", { otherKnowledge.phase == .ready })
        let otherReading = AIReadingModel(settings: settings, audit: AIAuditTrail.shared)
        otherReading.serviceOverride = DocumentKnowledgeService(base: otherService, knowledge: otherKnowledge,
            context: otherContext, sourceURL: other, cacheDocumentURL: other)
        await otherReading.bind(otherState)
        otherReading.run("summary", state: otherState)
        try await eventually("Summary displays the completed preread", { otherReading.result("summary") != nil })
        require(otherService.sent.count == 1,
                "prereading followed by matching Summary performs exactly one provider request")
        require(otherService.sent[0].sources.map(\.snippet) == service.sent[0].sources.map(\.snippet),
                "starting prereading from a selection still reads the same complete document originals")
        let changedLanguage = try await otherKnowledge.cachedSummary(sourceURL: other, cacheDocumentURL: other, language: "French", detail: "Standard")
        require(changedLanguage == nil, "a different requested summary language cannot masquerade as a cache hit")
        otherReading.run("summary", state: otherState, force: true)
        try await eventually("explicit Regenerate creates a new analysis", { otherService.sent.count == 2 && otherKnowledge.phase == .ready })
        require(otherReading.store.notes(query: "", recent: false).isEmpty,
                "shared analysis reuse does not create or edit personal notes")
        otherKnowledge.io.suspend()
        var ioSuspended = true
        defer { if ioSuspended { otherKnowledge.io.resume() } }
        otherReading.run("summary", state: otherState, force: true)
        try await eventually("a completed analysis can finish while its disk write is deliberately held", {
            otherService.sent.count == 3 && otherKnowledge.phase == .ready
        })
        otherService.holdNextPreparation = true
        otherReading.run("summary", state: otherState, force: true)
        try await eventually("the next analysis owns its lease before the old disk cleanup", { otherService.heldPreparation != nil })
        otherKnowledge.io.resume(); ioSuspended = false
        try await Task.sleep(for: .milliseconds(100))
        otherService.heldPreparation?.resume(); otherService.heldPreparation = nil
        try await eventually("old disk cleanup cannot cancel a newer prepared analysis", {
            otherService.sent.count == 4 && otherKnowledge.phase == .ready
        })
        otherService.partCount = 2
        otherReading.run("summary", state: otherState, force: true)
        try await eventually("a multi-part shared analysis consolidates once without waiting on its own gate", {
            otherService.sent.count == 6 && otherKnowledge.phase == .ready
        })
        let completeID = try await otherKnowledge.cachedSummary(sourceURL: other, cacheDocumentURL: other, language: "", detail: "Standard")!.id
        otherService.truncateSources = true
        otherReading.run("summary", state: otherState, force: true)
        try await eventually("a truncated source part cannot become a complete understanding after synthesis", { otherKnowledge.phase == .failed })
        require(otherReading.result("summary")?.status == "partial", "the displayed synthesized result retains the source truncation state")
        let stillComplete = try await otherKnowledge.cachedSummary(sourceURL: other, cacheDocumentURL: other, language: "", detail: "Standard")
        require(stillComplete?.id == completeID, "a truncated regeneration preserves the previous complete analysis")
        let otherFile = DocumentEditCache.directory(for: other).appendingPathComponent("document-understanding-v2.json")
        try await Task.sleep(for: .milliseconds(100))
        let malformed = Data("{truncated synthetic cache".utf8)
        try malformed.write(to: otherFile)
        let broken = AIDocumentKnowledge(); broken.settings = settings
        do { _ = try await broken.ensure(service: otherService, context: otherContext, sourceURL: other, cacheDocumentURL: other)
            require(false, "a malformed analysis cannot look like a successful empty cache") }
        catch { require(broken.phase == .failed && broken.failureDetail != nil, "an unreadable analysis exposes a recoverable status") }
        let preserved = try Data(contentsOf: otherFile)
        require(preserved == malformed, "an unreadable analysis file is preserved byte for byte")
        broken.continueWithoutSummary()
        let skipped = try await broken.ensure(service: otherService, context: otherContext, sourceURL: other, cacheDocumentURL: other)
        require(skipped.isEmpty && !broken.isBlocking && otherService.sent.count == 8,
                "explicitly skipping a broken optional cache restores AI access without another request")
        reading.cancelPresentation(); otherReading.cancelPresentation()
    }
}

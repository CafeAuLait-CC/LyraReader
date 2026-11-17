import AppKit
import Foundation
import LyraReaderBindings
import SwiftUI
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
        AIPreReadingWindow.present(skipped)
        let panel = NSApplication.shared.windows.first { $0.title == aiReadingLabel("Document prereading") }!
        require(!panel.styleMask.contains(.titled) && panel.standardWindowButton(.closeButton) == nil,
                "the prereading choice has no system titlebar or traffic lights")
        require(panel.canBecomeKey && panel.contentView!.bounds.height > 150,
                "the borderless choice retains keyboard input and fits its content")
        try captureReadingInteraction(panel.contentView!, name: "prereading-choice")
        panel.cancelOperation(nil)
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

        service.partCount = 3
        let background = AIDocumentKnowledge(); background.settings = settings
        let begin = Task { try await background.ensure(service: service, context: context,
            sourceURL: source, cacheDocumentURL: source) }
        try await eventually("background reading asks before network work", { background.phase == .consent })
        background.proceed()
        do { _ = try await begin.value; require(false, "the original action must pause for prereading") }
        catch { require(error is AIPreReadingPause, "prereading pauses the action without a provider failure") }
        require(!background.isPresented, "starting prereading closes the choice window")
        try await eventually("the background request starts", { service.handles.count == 1 })
        require(background.reader?.plan?.parts.count == 3, "the prereading fixture has three actual plan parts")
        service.handles[0].part(0)
        try await eventually("the first prereading part is reported", { background.reader?.currentRequestNumber == 1 })
        service.handles[0].part(1)
        try await eventually("part progress advances from stream events", { background.reader?.currentRequestNumber == 2 })
        if ProcessInfo.processInfo.environment["LYRA_AI_EVIDENCE"] != nil {
            let status = NSHostingView(rootView: AIDocumentKnowledgeStatus(knowledge: background))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 348, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = status; window.setContentSize(status.fittingSize); window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(100))
            try captureReadingInteraction(status, name: "prereading-progress-2-of-3")
            window.orderOut(nil); window.contentView = nil
        }
        let wrapped = DocumentKnowledgeService(base: service, knowledge: background, context: context,
            sourceURL: source, cacheDocumentURL: source)
        do { _ = try await wrapped.prepare(request); require(false, "another AI action must wait for prereading") }
        catch { require(error is AIPreReadingPause, "all AI requests share the prereading gate") }
        require(service.handles.count == 1, "a blocked action cannot start a second provider request")
        service.handles[0].fail()
        try await eventually("a slow provider failure becomes nonmodal status", { background.phase == .failed })
        do { _ = try await background.ensure(service: service, context: context,
            sourceURL: source, cacheDocumentURL: source); require(false, "a failed preread requires retry or explicit skip") }
        catch { require(error is AIPreReadingPause, "prereading failure retains a recoverable gate") }
        background.continueWithoutSummary()
        let afterFailure = try await background.ensure(service: service, context: context,
            sourceURL: source, cacheDocumentURL: source)
        require(afterFailure.isEmpty && !background.isPresented,
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
    var partCount = 1
    init(engine: RustEngine) { base = RustAIChatService(engine: engine, useMockProvider: true) }
    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        lastRequest = request
        return adjust(try await base.prepare(request))
    }
    func prepareReading(_ request: AIMakePlanRequest, options: AiReadingOptionsRecord) async throws -> AiPlanRecord {
        lastRequest = request
        return adjust(try await base.prepareReading(request, options: options))
    }
    private func adjust(_ source: AiPlanRecord) -> AiPlanRecord {
        var plan = source
        if partCount > 1, let first = plan.parts.first {
            plan.parts = (0..<partCount).map { index in
                var part = first; part.index = UInt32(index); part.total = UInt32(partCount); return part
            }
        }
        return plan
    }
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        let handle = HeldReadingHandle(); handles.append(handle); return handle
    }
}

@MainActor private final class HeldReadingHandle: AIChatHandle {
    var isFinished = false
    private var events: [AIStreamEvent] = []
    func fail() { events = [.error(message: "the idle timeout expired", cancelled: false)] }
    func part(_ index: Int) { events.append(.partStarted(index: index, total: 3, label: "Synthetic source")) }
    func poll() -> [AIStreamEvent] {
        let pending = events; events = []
        if pending.contains(where: { if case .error = $0 { return true }; return false }) { isFinished = true }
        return pending
    }
    func cancel() { isFinished = true; events = [] }
}

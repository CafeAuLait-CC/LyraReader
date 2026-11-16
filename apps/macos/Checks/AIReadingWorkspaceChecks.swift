import AppKit
import Foundation
import LyraReaderBindings
import SwiftUI
@testable import LyraReaderKit

@MainActor
private final class ReadingTaskService: AIChatServicing {
    let base: RustAIChatService
    var starts = 0
    init(engine: RustEngine) { base = RustAIChatService(engine: engine, useMockProvider: true) }
    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord { try await base.prepare(request) }
    func prepareReading(_ request: AIMakePlanRequest, options: AiReadingOptionsRecord) async throws -> AiPlanRecord {
        try await base.prepareReading(request, options: options)
    }
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        starts += 1
        return ReadingTaskHandle(plan: plan)
    }
}

@MainActor
private final class ReadingTaskHandle: AIChatHandle {
    private var events: [AIStreamEvent]
    private(set) var isFinished = false
    init(plan: AiPlanRecord) {
        events = []
        for part in plan.parts {
            events.append(.partStarted(index: Int(part.index), total: Int(part.total), label: part.label))
            if plan.action == .translateSelection {
                for (index, source) in plan.sources.enumerated() where part.userPrompt.contains("[Paragraph \(index);") {
                    events.append(.delta("<!--lyra:\(index)-->Translated synthetic paragraph [p.\(source.page)]\n\n"))
                }
            } else { events.append(.delta("# Synthetic knowledge\n\n## Overview\nA supported idea [p.1].\n\n## Key ideas\n- A reproducible result.")) }
        }
        events.append(.done)
    }
    func poll() -> [AIStreamEvent] { let result = events; events = []; isFinished = true; return result }
    func cancel() { events = []; isFinished = true }
}

extension ReaderChecks {
    @MainActor static func aiReadingWorkspaceChecks(root: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-ai-workspace-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("synthetic.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: source)
        let domain = "lyra-ai-workspace-\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = AISettingsStore(defaults: defaults, keyStore: InMemoryAPIKeyStore(key: "mock"))
        require(!settings.reviewBeforeSending && settings.prereadingPolicy == "ask", "reading workflow defaults to direct tasks and a prereading choice")
        settings.prereadingPolicy = "never"
        _ = settings.save(baseURL: "http://localhost:11434/v1", model: "mock", temperature: 0.2, maxTokens: 512, apiKey: nil)
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        require(state.open(url: source), "the workspace fixture opens")
        let reading = AIReadingModel(settings: settings, audit: AIAuditTrail.shared)
        let service = ReadingTaskService(engine: engine)
        reading.serviceOverride = service
        await reading.bind(state)
        require(reading.store.error == nil, "the Rust workspace loads through native I/O")
        reading.run("summary", state: state)
        try await eventually("one summary action completes and persists", { reading.result("summary") != nil })
        require(service.starts == 1, "one click sends the complete summary task without an inline preview")
        let summary = reading.result("summary")!
        require(summary.pages == [1] && summary.content.contains("supported idea"), "saved results retain actual source coverage")
        let sourceRects = try await engine.locateAIReadingSource(page: 0, text: summary.originals[0])
        require(!sourceRects.isEmpty, "saved source paragraphs resolve back to real PDF text geometry")
        reading.keep(summary); reading.keep(summary)
        require(reading.store.notes(query: "", recent: false).count == 1, "saving the same result twice keeps one note")
        var note = reading.store.notes(query: "", recent: false)[0]
        note.thoughts = "My independent annotation"
        note.content = "My corrected knowledge"
        reading.store.put(note); reading.keep(summary)
        require(reading.store.notes(query: "independent", recent: false).first?.content == "My corrected knowledge", "saving again preserves personal thoughts and hand edits")
        reading.run("translation", state: state)
        try await eventually("document translation completes as one user task", { reading.result("translation") != nil })
        let translated = reading.result("translation")!
        let blocks = try aiTranslationBlocks(originals: translated.originals, pages: translated.originalPages, response: translated.content)
        require(!blocks.isEmpty && blocks.allSatisfy { !$0.translation.isEmpty }, "all translated paragraphs retain their originals and page anchors")
        let sent = service.starts
        reading.showOriginal.toggle()
        require(service.starts == sent, "showing original text sends no request")
        let session = reading.sessionID
        reading.chat.restoreChat((0..<10).map { AIChatTurn(question: "Question \($0)", answer: "Answer \($0)", pageCount: 1, state: .finished) }, draft: "Unsent draft")
        reading.saveChat()
        reading.newSession(pageCount: 1)
        reading.openSession(session, pageCount: 1)
        require(reading.chat.chatTurns.count == 10 && reading.chat.chatQuestion == "Unsent draft", "new sessions retain complete earlier history and drafts")
        await reading.store.flush()
        let restored = AIReadingStore()
        await restored.load(document: source, identity: state.aiReaderContext!.documentKey)
        require(restored.records.filter { $0.kind == "message" }.count == 10, "a new native store restores all persisted chat messages")
        require(restored.notes(query: "independent", recent: true).count == 1, "native relaunch restores edited notes and searchable personal thoughts")
        try await captureReadingWorkspace(state: state, reading: reading)
        settings.reviewBeforeSending = true
        let beforeReview = service.starts
        reading.run("summary", state: state)
        try await eventually("optional review pauses before provider I/O", { reading.summary.phase == .preview })
        reading.cancelPresentation()
        try await Task.sleep(for: .milliseconds(150))
        require(service.starts == beforeReview, "cancelling a review closes its window without sending")
        settings.reviewBeforeSending = false
        let stale = AIAssistantModel(settings: settings)
        stale.attach(service: service, context: state.aiReaderContext)
        await stale.prepare(action: .summarizeDocument, context: state.aiReaderContext!,
            reading: AiReadingOptionsRecord(kind: "summary", detail: "Standard"))
        let beforeChange = service.starts
        _ = settings.save(baseURL: "http://localhost:1234/v1", model: "another-mock", temperature: 0.2, maxTokens: 512, apiKey: "mock-new")
        stale.send()
        require(stale.phase == .failed && service.starts == beforeChange,
                "changing provider settings cannot send an earlier reviewed plan with the new connection")
        print("PASS: reading workspace tasks, source maps, note deduplication, edits, full sessions and disk restoration")
    }

    @MainActor private static func captureReadingWorkspace(state: AppState, reading: AIReadingModel) async throws {
        guard let directory = ProcessInfo.processInfo.environment["LYRA_AI_EVIDENCE"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let navigation = AIAssistantModel(settings: reading.settings)
        for dark in [false, true] {
            let host = NSHostingView(rootView: AIReadingSidebar(state: state, navigation: navigation, reading: reading, isActive: false)
                .preferredColorScheme(dark ? .dark : .light))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 414, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.setContentSize(NSSize(width: 414, height: 900)); window.orderFrontRegardless()
            for (name, tab) in [("summary", AIAssistantTab.summary), ("translation", .translation), ("chat", .chat), ("notes", .regions), ("note-detail", .regions)] {
                navigation.selectedTab = tab
                reading.selectedNoteID = name == "note-detail" ? reading.store.notes(query: "", recent: false).first?.id : nil
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("reading-\(name)-414-\(dark ? "dark" : "light").png"))
                }
            }
            window.orderOut(nil); window.contentView = nil
        }
    }
}

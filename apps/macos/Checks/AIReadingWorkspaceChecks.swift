import AppKit
import Foundation
import LyraReaderBindings
import SwiftUI
@testable import LyraReaderKit

@MainActor
private final class ReadingTaskService: AIChatServicing {
    let base: RustAIChatService
    var starts = 0
    var startedPlans: [AiPlanRecord] = []
    var holdNext = false
    var latestHandle: ReadingTaskHandle?
    init(engine: RustEngine) { base = RustAIChatService(engine: engine, useMockProvider: true) }
    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord { try await base.prepare(request) }
    func prepareReading(_ request: AIMakePlanRequest, options: AiReadingOptionsRecord) async throws -> AiPlanRecord {
        try await base.prepareReading(request, options: options)
    }
    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        starts += 1
        startedPlans.append(plan)
        let handle = ReadingTaskHandle(plan: plan)
        handle.suspended = holdNext; holdNext = false; latestHandle = handle
        return handle
    }
}

@MainActor
private final class ReadingTaskHandle: AIChatHandle {
    private var events: [AIStreamEvent]
    private(set) var isFinished = false
    var suspended = false
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
    func poll() -> [AIStreamEvent] {
        guard !suspended else { return [] }
        let result = events; events = []; isFinished = true; return result
    }
    func cancel() { events = []; isFinished = true }
}

private struct TranslationPanelCheckHost: View {
    @ObservedObject var state: AppState
    @ObservedObject var reading: AIReadingModel
    @ObservedObject var navigation: AIAssistantModel
    var body: some View {
        AIReadingSidebar(state: state, navigation: navigation, reading: reading, isActive: state.rightPanelVisible)
    }
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
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: source), "the workspace fixture opens")
        let reading = AIReadingModel(settings: settings, audit: AIAuditTrail.shared)
        let service = ReadingTaskService(engine: engine)
        reading.serviceOverride = service
        await reading.bind(state)
        require(reading.store.error == nil, "the Rust workspace loads through native I/O")
        reading.run("summary", state: state)
        try await eventually("one summary action completes and persists", { reading.result("summary") != nil })
        try await eventually("completed Summary publishes its shared understanding before other AI tools resume", {
            state.documentKnowledge.phase == .ready
        })
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
        let textPage = try await engine.textPage(0)
        func select(_ range: ClosedRange<Int>, capture: Bool = true) async throws {
            state.clearSelection()
            try await eventually("synthetic page has a canvas placement", { !state.canvasPageFrames.isEmpty })
            let placement = state.canvasPageFrames.first { $0.index == 0 }!
            func point(_ index: Int) -> CGPoint {
                let character = textPage.chars[index]
                return CGPoint(x: placement.leftPt + character.xPt + min(1, character.widthPt / 2),
                               y: placement.topPt + character.yPt + max(1, character.heightPt / 2))
            }
            try await eventually("the canvas accepts the selected source", {
                state.beginSelection(at: point(range.lowerBound))
                return state.selection != nil
            })
            state.extendSelection(to: point(range.upperBound))
            require(state.selectedPassageText?.isEmpty == false, "the selected passage is available through the real canvas")
            if capture { reading.changeTranslationSource(selection: true, state: state) }
        }
        try await select(0...15)
        reading.run("translation", state: state)
        try await eventually("the first selected translation is saved", { reading.result("translation") != nil })
        let firstSelection = reading.result("translation")!
        try await select(80...110)
        require(reading.result("translation") == nil, "a new selection starts a draft without deleting earlier results")
        reading.run("translation", state: state)
        try await eventually("the second selected translation is saved", { reading.result("translation") != nil })
        let secondSelection = reading.result("translation")!
        require(secondSelection.sourceId != firstSelection.sourceId && reading.store.taskHistory("translation").count == 3,
                "whole-document and distinct selected translations remain independently accessible")
        let beforeHistory = service.starts
        reading.openTranslation(firstSelection)
        require(reading.result("translation")?.id == firstSelection.id && reading.excerpt("translation") == firstSelection.excerpt,
                "opening history restores its result and its source snapshot together")
        require(service.starts == beforeHistory, "opening an earlier translation sends no request")
        reading.changeTranslationSource(selection: true, state: state)
        let currentPreview = reading.excerpt("translation")
        reading.translationLanguage = "German"
        reading.retranslate(firstSelection, state: state)
        try await eventually("retranslating a saved passage creates another retained result", {
            reading.result("translation").map { $0.id != firstSelection.id } ?? false
        })
        require(service.startedPlans.last?.sources.map(\.snippet) == firstSelection.originals,
                "retranslation uses the saved first selection even while the canvas still selects the second")
        require(reading.excerpt("translation") == currentPreview && reading.translationLanguage == "German"
                && reading.result("translation")?.language == firstSelection.language,
                "retranslating an inline result keeps its saved language without changing the next translation's preview")
        require(reading.store.taskHistory("translation").count == 4,
                "retranslation preserves every earlier run, including the previous result for this scope")
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
        require(restored.taskHistory("translation").count == 4 && restored.taskHistory("translation").contains { $0.id == firstSelection.id },
                "native disk restoration retains every translation and its original identity")
        require(restored.translationHistory(selection: false).map(\.id) == [translated.id]
                && restored.translationHistory(selection: true).count == 3
                && restored.translationHistory(selection: true).contains { $0.id == secondSelection.id },
                "disk restoration keeps whole-document and all selected-passage timelines separate")
        let relaunched = AIReadingModel(settings: settings, audit: AIAuditTrail.shared)
        relaunched.serviceOverride = service
        await relaunched.bind(state)
        require(relaunched.result("translation")?.id == reading.result("translation")?.id && relaunched.translationSelection,
                "a new presentation opens the latest saved selection translation without requiring a new selection")
        relaunched.cancelPresentation()
        try await translationPresentationChecks(state: state, reading: reading,
            select: { try await select($0, capture: false) }, service: service)
        try await captureReadingWorkspace(state: state, reading: reading)
        settings.reviewBeforeSending = true
        let beforeReview = service.starts
        reading.run("summary", state: state, force: true)
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

    @MainActor private static func translationPresentationChecks(state: AppState, reading: AIReadingModel,
        select: (ClosedRange<Int>) async throws -> Void, service: ReadingTaskService) async throws {
        func find(_ view: NSView) -> [AITranslationControlMarker] {
            (view as? AITranslationControlMarker).map { [$0] } ?? view.subviews.flatMap(find)
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 414, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentView = nil }
        let long = String(repeating: "A synthetic selected passage retains its opening and can expand to show the rest. ", count: 12)
        let excerpt = NSHostingView(rootView: ScrollView {
            AITranslationExcerpt(text: long, page: 1, onLocate: {}).padding(18)
        }.background(LyraReaderTheme.panelBg).foregroundStyle(LyraReaderTheme.textPrimary).preferredColorScheme(.light))
        window.contentView = excerpt; window.setContentSize(NSSize(width: 414, height: 900)); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(150))
        func click(_ id: String, in host: NSView) {
            host.layoutSubtreeIfNeeded()
            guard let marker = find(host).first(where: { $0.id == id }) else { fail("FAIL: missing native translation control \(id)") }
            let rect = marker.convert(marker.bounds, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: CGPoint(x: rect.midX, y: rect.midY),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
            }
        }
        try await eventually("long selected passages expose More", {
            excerpt.layoutSubtreeIfNeeded(); return find(excerpt).contains { $0.id == "excerpt-more" }
        })
        let collapsed = find(excerpt).first { $0.id == "excerpt-card" }!.bounds.height
        try captureReadingInteraction(excerpt, name: "translation-excerpt-collapsed")
        click("excerpt-more", in: excerpt)
        try await eventually("More expands the actual source text", {
            excerpt.layoutSubtreeIfNeeded()
            return find(excerpt).first { $0.id == "excerpt-card" }!.bounds.height > collapsed + 100
        })
        try captureReadingInteraction(excerpt, name: "translation-excerpt-expanded")
        click("excerpt-more", in: excerpt)
        try await eventually("Less restores the compact source card", {
            excerpt.layoutSubtreeIfNeeded()
            return abs(find(excerpt).first { $0.id == "excerpt-card" }!.bounds.height - collapsed) < 2
        })
        let navigation = AIAssistantModel(settings: reading.settings); navigation.selectedTab = .translation
        state.aiToolsVisible = false; state.rightPanelVisible = false
        let host = NSHostingView(rootView: TranslationPanelCheckHost(state: state, reading: reading, navigation: navigation)
            .preferredColorScheme(.light))
        window.contentView = host
        let count = service.starts
        reading.showOriginal = false
        try await eventually("saved translations appear directly in the result feed", {
            host.layoutSubtreeIfNeeded()
            let ids = Set(reading.store.taskHistory("translation").map(\.id))
            return find(host).filter { ids.contains($0.id) }.count >= 2
        })
        require(!find(host).contains { $0.id == "history" }, "translation results need no separate history screen")
        click("show-original", in: host)
        try await eventually("the Lyra checkbox toggles original paragraphs", { reading.showOriginal })
        try captureReadingInteraction(host, name: "translation-inline-history")
        click("language", in: host)
        try await eventually("the destination picker opens the shared Lyra menu panel", {
            NSApplication.shared.windows.contains { $0.isVisible && $0.accessibilityLabel() == "Toolbar commands" }
        })
        let menu = NSApplication.shared.windows.first { $0.isVisible && $0.accessibilityLabel() == "Toolbar commands" }!
        try await Task.sleep(for: .milliseconds(150))
        if let content = menu.contentView { try captureReadingInteraction(content, name: "translation-language-menu") }
        for _ in 0..<3 {
            menu.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: menu.windowNumber, context: nil,
                characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!)
            try await Task.sleep(for: .milliseconds(60))
        }
        menu.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: menu.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        try await eventually("Lyra menu keyboard navigation selects Japanese", { reading.translationLanguage == "Japanese" })
        require(AITranslationLanguage.display(reading.translationLanguage).code == "JP", "the destination field uses its short code")
        require(service.starts == count, "expansion, checkbox and language selection never call a provider")

        let inactiveExcerpt = reading.excerpt("translation")
        try await select(130...155)
        try await Task.sleep(for: .milliseconds(180))
        require(reading.excerpt("translation") == inactiveExcerpt, "a closed translation tool ignores reading selections")
        state.toggleRightPanel()
        try await eventually("opening the translation tool captures the current selection", {
            reading.excerpt("translation") == state.selectedPassageText
        })
        try await select(160...190)
        try await eventually("the active translation preview follows a new selection automatically", {
            reading.excerpt("translation") == state.selectedPassageText
        })
        require(service.starts == count, "automatic selection capture sends no AI request")
        click("segment-Whole document", in: host)
        try await eventually("the shared source picker switches Translate to the whole document", { !reading.translationSelection })
        try await eventually("the document feed hides every selected-passage result", {
            host.layoutSubtreeIfNeeded()
            let ids = Set(find(host).map(\.id))
            return reading.store.translationHistory(selection: false).allSatisfy { ids.contains($0.id) }
                && reading.store.translationHistory(selection: true).allSatisfy { !ids.contains($0.id) }
        })
        click("segment-Selection", in: host)
        try await eventually("the shared source picker returns to the selected passage", { reading.translationSelection })
        try await eventually("the selection feed restores earlier passages without document results", {
            host.layoutSubtreeIfNeeded()
            let ids = Set(find(host).map(\.id))
            return reading.store.translationHistory(selection: true).contains { ids.contains($0.id) }
                && reading.store.translationHistory(selection: false).allSatisfy { !ids.contains($0.id) }
        })
        require(service.starts == count, "switching translation timelines sends no AI requests")
        let captured = reading.excerpt("translation")
        let before = reading.store.taskHistory("translation").count
        service.holdNext = true
        click("generate", in: host)
        try await eventually("Translate explicitly starts one frozen task", { service.starts == count + 1 && reading.translation.isSending })
        let originals = service.startedPlans.last!.sources.map(\.snippet)
        try await select(210...235)
        try await eventually("a new preview can update while an older selection is translating", {
            reading.excerpt("translation") == state.selectedPassageText && reading.excerpt("translation") != captured
        })
        service.latestHandle?.suspended = false
        try await eventually("the frozen task finishes as another inline result", { reading.store.taskHistory("translation").count == before + 1 })
        require(reading.store.taskHistory("translation").first?.originals == originals,
                "changing the preview cannot replace the in-flight task's source")
        require(service.starts == count + 1, "selection changes during translation do not enqueue another request")
        let preview = reading.excerpt("translation")
        navigation.selectedTab = .summary
        try await Task.sleep(for: .milliseconds(100))
        try await eventually("Summary exposes the same Lyra source picker", {
            host.layoutSubtreeIfNeeded(); return find(host).contains { $0.id == "segment-Selection" }
        })
        click("segment-Selection", in: host)
        try await eventually("Summary's shared picker changes its source", { reading.summarySelection })
        click("segment-Whole document", in: host)
        try await eventually("Summary's shared picker returns to whole document", { !reading.summarySelection })
        try await select(245...270)
        try await Task.sleep(for: .milliseconds(180))
        require(reading.excerpt("translation") == preview, "Summary does not keep updating the translation selection")
        navigation.selectedTab = .chat
        try await select(280...305)
        try await Task.sleep(for: .milliseconds(180))
        require(reading.excerpt("translation") == preview, "Chat does not keep updating the translation selection")
        navigation.selectedTab = .regions; reading.selectedNoteID = nil
        try await eventually("reading notes expose the same Lyra sorting picker", {
            host.layoutSubtreeIfNeeded(); return find(host).contains { $0.id == "segment-Recent" }
        })
        click("segment-Recent", in: host)
        try await Task.sleep(for: .milliseconds(70))
        try captureReadingInteraction(host, name: "notes-sort-sliding")
        try await Task.sleep(for: .milliseconds(150))
        try captureReadingInteraction(host, name: "notes-sort-recent")
        require(service.starts == count + 1, "source and note-order controls never request AI")
        navigation.selectedTab = .translation
        try await eventually("returning to Translate refreshes the preview without sending", { reading.excerpt("translation") == state.selectedPassageText })
        state.aiToolsVisible = false
        let closed = reading.excerpt("translation")
        try await select(310...335)
        try await Task.sleep(for: .milliseconds(180))
        require(!state.rightPanelVisible && reading.excerpt("translation") == closed,
                "closing the Lyra row stops automatic translation selection tracking")
        func textViews(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        for (name, content) in [
            ("aligned", "<!--lyra:0-->Supported [p.1].\n<!--lyra:1-->Unsupported [p.2]."),
            ("unaligned", "Supported [p.1]. Unsupported [p.2].")
        ] {
            let sourceCheck = NSHostingView(rootView: ScrollView {
                VStack(alignment: .leading) {
                    AITranslationBlocks(originals: ["First source", "Unsent source"], pages: [1, 2], content: content,
                        showOriginal: false, verifiedPages: [1], pageCount: 2, onLocate: { _, _ in }, onJump: { _ in })
                }.padding(18)
            }.environment(\.readingStableTextLayout, true))
            window.contentView = sourceCheck
            try await eventually("\(name) translation renders its citation fixture", {
                sourceCheck.layoutSubtreeIfNeeded()
                return textViews(sourceCheck).contains { $0.string.contains("Unsupported") }
            })
            var links = Set<String>()
            for view in textViews(sourceCheck) {
                guard let storage = view.textStorage else { continue }
                storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                    if let url = value as? URL { links.insert(url.absoluteString) }
                }
            }
            require(links.contains("lyra-reader-page://1") && !links.contains("lyra-reader-page://2"),
                    "\(name) translation links only actual sent pages, not the complete planned source map")
            let rendered = textViews(sourceCheck).first { $0.string.contains("Supported") }!.attributedString()
            let font = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let paragraph = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            require(font?.pointSize == 14 && paragraph?.lineSpacing == 5,
                    "translated paragraphs use the larger reading font and relaxed line spacing")
        }
    }

    @MainActor private static func captureReadingWorkspace(state: AppState, reading: AIReadingModel) async throws {
        let directory = ProcessInfo.processInfo.environment["LYRA_AI_EVIDENCE"]
        if let directory { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        let originals = ["The synthetic experiment measures repeatability across several independent trials. We report the complete procedure, compare the measurements, and discuss the remaining limitations.",
                         "The second synthetic paragraph describes a control condition and the evidence needed to interpret the result."]
        var translated = AiReadingRecord.make(kind: "translation", title: "Selected passage",
            content: "<!--lyra:0-->合成实验通过多次独立试验衡量可重复性。我们报告完整流程、比较测量结果，并讨论仍然存在的局限。\n\n<!--lyra:1-->第二段合成文本描述对照条件，以及解释结果所需的证据。",
            sourceID: "selection:1:0:15", pages: [1], excerpt: originals.joined(separator: "\n\n"), language: "Simplified Chinese")
        translated.originals = originals; translated.originalPages = [1, 1]
        reading.store.put(translated); reading.openTranslation(translated); reading.showOriginal = true
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
                if let prefix = ["summary": "A supported idea", "translation": "合成实验", "chat": "Answer", "note-detail": "My corrected knowledge"][name] {
                    try await eventually("\(name) renders its semantic-ink fixture in \(dark ? "dark" : "light") mode", {
                        host.layoutSubtreeIfNeeded()
                        return markdownTextViews(host).contains { $0.string.hasPrefix(prefix) }
                    })
                    let output = markdownTextViews(host).first { $0.string.hasPrefix(prefix) }!
                    let color = output.attributedString().attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                    var rgb: [CGFloat] = []
                    output.effectiveAppearance.performAsCurrentDrawingAppearance {
                        if let resolved = color?.usingColorSpace(.sRGB) { rgb = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent] }
                    }
                    let expected = (dark ? [241, 236, 227] : [48, 43, 37]).map { CGFloat($0) / 255 }
                    require(rgb.count == 3 && zip(rgb, expected).allSatisfy { abs($0 - $1) < 0.005 },
                            "\(name) output uses Lyra primary ink in \(dark ? "dark" : "light") mode")
                }
                if let directory, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("reading-\(name)-414-\(dark ? "dark" : "light").png"))
                }
            }
            navigation.selectedTab = .translation
            window.setContentSize(NSSize(width: 320, height: 900))
            try await Task.sleep(for: .milliseconds(150))
            try captureReadingInteraction(host, name: "translation-320-\(dark ? "dark" : "light")")
            window.orderOut(nil); window.contentView = nil
        }
        try mathInkIsolationChecks()
    }

    @MainActor private static func markdownTextViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(markdownTextViews)
    }

    @MainActor private static func mathInkIsolationChecks() throws {
        let expression = "\\frac{x}{2}"
        guard case .success(let original) = ReaderMathRenderer.render(expression, fontSize: 18),
              case .success(let themed) = ReaderMathRenderer.render(expression, fontSize: 18,
                  ink: NSColor(srgbRed: 48 / 255, green: 43 / 255, blue: 37 / 255, alpha: 1)),
              case .success(let repeated) = ReaderMathRenderer.render(expression, fontSize: 18),
              let originalData = original.image.tiffRepresentation,
              let themedData = themed.image.tiffRepresentation,
              let repeatedData = repeated.image.tiffRepresentation,
              let bitmap = themed.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              bitmap.width < 512, bitmap.height < 512,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: bitmap.width, height: bitmap.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("FAIL: mathematics ink fixtures render") }
        require(originalData == repeatedData && originalData != themedData,
                "themed mathematics cannot contaminate the default renderer cache used by Interleaf")
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        guard let data = context.data else { fail("FAIL: mathematics pixels are readable") }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var samples = 0, matches = true
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let offset = y * context.bytesPerRow + x * 4
                if bytes[offset + 3] > 250 {
                    samples += 1
                    matches = matches && zip([48, 43, 37], 0..<3).allSatisfy {
                        abs(Int(bytes[offset + $1]) - $0) <= 1
                    }
                }
            }
        }
        require(samples > 0 && matches, "AI mathematics glyphs and rules use the same warm primary ink as text")
        guard case .failure = ReaderMathRenderer.render(String(repeating: "x", count: 1200), fontSize: 18,
            ink: NSColor(srgbRed: 48 / 255, green: 43 / 255, blue: 37 / 255, alpha: 1)) else {
            fail("FAIL: oversized mathematics is refused before bitmap allocation")
        }
        print("PASS: oversized mathematics is refused before bitmap allocation")
    }
}

import AppKit
import LyraReaderBindings
import LyraReaderKit
import Foundation

/// The transport-neutral plan and the one body rendered for the selected connection.
///
/// These checks are local: the Rust planner reads the fixture's text layer, the mock provider
/// answers a send, and no socket is opened.

@MainActor
private final class PlanWireRecordingService: AIChatServicing {
    let base: RustAIChatService
    private(set) var preparedSources: [AiPlanRecord] = []
    private(set) var started: [AiPlanRecord] = []

    init(engine: RustEngine) {
        self.base = RustAIChatService(engine: engine, useMockProvider: true)
    }

    func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        let source = try await base.prepare(request)
        preparedSources.append(source)
        return source
    }

    func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        started.append(plan)
        return try base.start(plan, apiKey: apiKey)
    }
}

extension ReaderChecks {
    @MainActor static func planWireChecks(root: URL) async throws {
        func payloadCount(_ body: String) -> Int {
            body.components(separatedBy: "base64,").count - 1
        }
        let fixture = root.appendingPathComponent("tests/fixtures/text-page.pdf")
        let engine = try RustEngine()
        let state = AppState(engine: engine)
        require(state.open(url: fixture), "the plan-wire fixture opens")
        let context = AIReaderContext(
            documentKey: "plan-wire-check",
            documentTitle: "Plan wire fixture",
            pageCount: 1,
            currentPage: 1,
            selection: nil
        )

        let suiteName = "lyra-reader-plan-wire-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "sk-plan-wire-not-real"
        let settings = AISettingsStore(defaults: defaults, keyStore: InMemoryAPIKeyStore(key: key))
        require(settings.save(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            apiKey: key,
            reasoningMode: .off,
            reasoningEncoding: .thinking,
            modelAcceptsImages: true
        ), "the plan-wire provider settings save")

        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        let attachment = AIRegionAttachment(
            page: 0,
            rect: CGRect(x: 40, y: 40, width: 120, height: 60),
            text: "Region text for the plan-wire check.",
            png: png,
            pixelWidth: 1,
            pixelHeight: 1,
            captureScale: 2
        )

        let service = PlanWireRecordingService(engine: engine)
        let model = AIAssistantModel(settings: settings)
        model.attach(service: service, context: context)
        await model.prepareRegion(question: "What does this region show?",
                                  attachment: attachment, context: context)
        try await eventually("the plan-wire region preview is built", {
            model.phase == .preview && model.plan != nil
        })
        guard let source = service.preparedSources.last,
              let preview = model.plan, let previewPart = preview.parts.first else {
            fatalError("FAIL: the plan-wire region preview exists: \(model.errorMessage ?? "no error")")
        }

        // 1. The planner carries the capture and the neutral description, not a body.
        require(source.parts.allSatisfy { $0.wireBody.isEmpty },
                "the plan carries no chat-completions body string")
        require(source.parts[0].image?.png == png,
                "the plan carries the exact capture bytes")
        require(source.parts[0].image?.widthPx == 1 && source.parts[0].image?.heightPx == 1,
                "the plan carries the capture dimensions")
        require(source.parts[0].pages == [1] && !source.parts[0].label.isEmpty,
                "the plan carries page labels without a transport body")
        require(source.stream && source.includeStreamOptions,
                "the plan carries the streaming decisions a transport needs")
        require(source.reasoningField == "thinking" && source.reasoningValue == "{\"type\":\"disabled\"}",
                "the plan carries the reasoning field as a parameter, not as a body")

        // 2. Exactly one body is rendered per transport, with exactly one image payload.
        let apiKeyPlan = try AIPlanWire.render(source, connection: .apiKey)
        require(apiKeyPlan.parts[0].wireBody.contains("\"messages\""),
                "the API-key connection renders the chat-completions body")
        require(apiKeyPlan.parts[0].wireBody.contains("\"image_url\""),
                "the API-key body carries an image_url part")
        require(!apiKeyPlan.parts[0].wireBody.contains("input_image"),
                "the API-key body is not a Responses body")
        require(payloadCount(apiKeyPlan.parts[0].wireBody) == 1,
                "the API-key request carries exactly one base64 image payload")

        let planPlan = try AIPlanWire.render(source, connection: .chatGPT)
        require(planPlan.endpoint == ChatGPTResponses.endpoint,
                "the plan connection names the fixed Responses endpoint")
        require(planPlan.parts[0].wireBody.contains("\"input_image\""),
                "the plan connection renders an input_image part")
        require(!planPlan.parts[0].wireBody.contains("\"messages\""),
                "the plan connection contains no chat-completions body")
        require(payloadCount(planPlan.parts[0].wireBody) == 1,
                "the plan request carries exactly one base64 image payload")
        let converted = try ChatGPTResponses.plan(source)
        require(converted.parts[0].wireBody == planPlan.parts[0].wireBody,
                "the shared ChatGPT conversion and the platform renderer agree byte for byte")

        // 3. The preview is the body that is sent, for the API-key connection.
        require(preview.parts[0].wireBody == apiKeyPlan.parts[0].wireBody,
                "the API-key preview is the body rendered for the selected transport")
        model.send()
        try await eventually("the plan-wire region answer finishes", {
            model.phase.isTerminal
        })
        guard let sent = service.started.last else { fatalError("FAIL: the previewed region was sent") }
        require(sent.parts.map(\.wireBody) == preview.parts.map(\.wireBody),
                "the sent request carries the exact previewed bytes")
        require(payloadCount(sent.parts[0].wireBody) == 1,
                "the sent request carries the image payload once, not twice")

        // 4. A two-megabyte capture is still carried once: the raw plan, then one encoded body.
        let large = Data(repeating: 0xAB, count: 2 * 1024 * 1024)
        let largeAttachment = AIRegionAttachment(
            page: 0,
            rect: CGRect(x: 40, y: 40, width: 120, height: 60),
            text: "A large region capture.",
            png: large,
            pixelWidth: 2048,
            pixelHeight: 2048,
            captureScale: 2
        )
        let largeRequest = AIMakePlanRequest(
            action: .regionQuestion,
            currentPage: 1,
            selection: nil,
            question: "Describe the large region.",
            language: nil,
            region: largeAttachment,
            sendRegionImage: true,
            settings: try settings.providerSettings()
        )
        let largeSource = try await service.prepare(largeRequest)
        require(largeSource.parts[0].wireBody.isEmpty,
                "a two-megabyte capture adds no encoded body to the plan")
        require(largeSource.parts[0].image?.png.count == 2 * 1024 * 1024,
                "the large plan carries the capture bytes once")
        do {
            let body = try AIPlanWire.render(largeSource, connection: .apiKey).parts[0].wireBody
            require(payloadCount(body) == 1,
                    "the API-key body materialises one encoded copy of the large capture")
            require(body.utf8.count > 2 * 1024 * 1024,
                    "the encoded body is the materialised copy, not a second capture")
        }
        do {
            let body = try AIPlanWire.render(largeSource, connection: .chatGPT).parts[0].wireBody
            require(payloadCount(body) == 1,
                    "the plan body materialises one encoded copy of the large capture")
        }

        // 5. Both rendered bodies are byte-identical to fixtures captured from the code before
        // the plan went transport-neutral. The fixtures carry the exact prompts, temperature and
        // capture of the documented region request.
        let fixtures = root.appendingPathComponent("crates/lyra-reader-ai/tests/fixtures")
        let chatFixture = try Data(contentsOf: fixtures.appendingPathComponent(
            "region_chat_completions_body.json"))
        let responsesFixture = try Data(contentsOf: fixtures.appendingPathComponent(
            "region_responses_body.json"))
        let chatObject = try JSONSerialization.jsonObject(with: chatFixture) as! [String: Any]
        let messages = chatObject["messages"] as! [[String: Any]]
        let systemPrompt = messages[0]["content"] as! String
        let userContent = messages[1]["content"] as! [[String: Any]]
        let userPrompt = userContent[0]["text"] as! String
        let imageURL = (userContent[1]["image_url"] as! [String: Any])["url"] as! String
        let imagePrefix = "data:image/png;base64,"
        require(imageURL.hasPrefix(imagePrefix), "the fixture image URL is an inline PNG")
        let fixturePNG = Data(base64Encoded: String(imageURL.dropFirst(imagePrefix.count)))!
        let fixturePart = AiPlanPartRecord(
            index: 0, total: 1, label: "Page 2 · 200 × 80 pt", primaryPage: 2, pages: [2],
            pageCharacters: 0, requestCharacters: 0,
            systemPrompt: systemPrompt, userPrompt: userPrompt, wireBody: "", note: nil,
            image: AiPlanImageRecord(png: fixturePNG, widthPx: 400, heightPx: 160))
        let fixturePlan = AiPlanRecord(
            action: .regionQuestion, actionLabel: "Ask about a region",
            documentTitle: "A Paper", pageCount: 3,
            baseUrl: "https://api.openai.com/v1",
            endpoint: "https://api.openai.com/v1/chat/completions",
            host: "api.openai.com", isLocal: false, model: "test-model",
            temperature: chatObject["temperature"] as? Double,
            maxTokens: (chatObject["max_tokens"] as? NSNumber)?.uint32Value,
            stream: true, includeStreamOptions: true,
            reasoningField: "thinking", reasoningValue: "{\"type\":\"disabled\"}",
            parts: [fixturePart], sourcePages: [2], note: nil, sources: [],
            historyTurns: 0, previewHeaders: [], estimatedTokens: 0)
        let fixtureChat = try renderAiPlan(plan: fixturePlan, transport: .chatCompletions)
        require(fixtureChat.parts[0].wireBody == String(decoding: chatFixture, as: UTF8.self),
                "the API-key body is byte-identical to the pre-refactor chat-completions fixture")
        let fixtureResponses = try renderAiPlan(plan: fixturePlan, transport: .responses)
        require(fixtureResponses.parts[0].wireBody == String(decoding: responsesFixture, as: UTF8.self),
                "the plan body is byte-identical to the pre-refactor Responses fixture")

        // 6. The layered summary uses the same transport-neutral path, including #178's
        // two-ended abstract sampling. Build a 120-page abstract, confirm both ranges are in
        // the neutral plan and in the body rendered for each transport.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-plan-wire-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let longURL = scratch.appendingPathComponent("long-abstract.pdf")
        try ReaderChecks.writeLayeredFixture(to: longURL, pageCount: 120)
        let longEngine = try RustEngine()
        let longDocument = try longEngine.openDocument(at: longURL)
        require(longDocument.pageCount == 120, "the plan-wire summary fixture has 120 pages")
        let summaryRequest = AiSummaryRequestRecord(
            layer: .abstract,
            units: [AiSummaryUnitRequestRecord(
                kind: .abstract, index: 0, title: "Abstract", number: nil, depth: 0,
                pageStart: 1, pageEnd: 120)],
            language: nil,
            documentTitle: "Plan wire long document",
            baseUrl: "http://127.0.0.1:11434/v1",
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            reasoningMode: "off",
            reasoningEncoding: "thinking")
        let summaryPreview = try await RustAIChatService(engine: longEngine)
            .prepareSummary(summaryRequest)
        guard let summaryUnit = summaryPreview.units.first,
              let neutralSummary = summaryUnit.plan else {
            fatalError("FAIL: the long abstract has a plan")
        }
        require(summaryUnit.pages == Array(1...12) + Array(109...120),
                "the long summary preview still samples both ends (\(summaryUnit.pages))")
        require(summaryUnit.note == "Summarised from pages 1-12 and 109-120 of 120.",
                "the long summary preview still names both ranges (\(summaryUnit.note ?? "nil"))")
        require(neutralSummary.parts[0].wireBody.isEmpty,
                "the abstract unit carries no transport body after planning")
        require(neutralSummary.parts[0].pages == Array(1...12) + Array(109...120),
                "the abstract plan carries both page windows")

        let summaryChat = try AIPlanWire.render(neutralSummary, connection: .apiKey)
        let summaryChatBody = summaryChat.parts[0].wireBody
        require(summaryChatBody.contains("\"messages\""),
                "the API-key transport renders the summary body")
        for label in ["[Pages 1-12: beginning of the document]",
                      "[Pages 109-120: end of the document]", "[Page 120]", "CONCLUSION"] {
            require(summaryChatBody.contains(label),
                    "the API-key summary body carries \(label)")
        }
        require(!summaryChatBody.contains("[Page 60]"),
                "the API-key summary body does not include the unsent middle")
        require(payloadCount(summaryChatBody) == 0,
                "a text-only summary carries no image payload")

        let summaryPlan = try AIPlanWire.render(neutralSummary, connection: .chatGPT)
        let summaryPlanBody = summaryPlan.parts[0].wireBody
        require(summaryPlan.endpoint == ChatGPTResponses.endpoint,
                "the plan connection renders the summary body against the Responses endpoint")
        require(summaryPlanBody.contains("\"input\"")
                    && summaryPlanBody.contains("input_text")
                    && !summaryPlanBody.contains("\"messages\""),
                "the plan transport renders the summary as a Responses body")
        for label in ["[Pages 1-12: beginning of the document]",
                      "[Pages 109-120: end of the document]", "[Page 120]", "CONCLUSION"] {
            require(summaryPlanBody.contains(label),
                    "the plan summary body carries \(label)")
        }
        require(!summaryPlanBody.contains("[Page 60]"),
                "the plan summary body does not include the unsent middle")
        require(payloadCount(summaryPlanBody) == 0,
                "the Responses summary carries no image payload")

        print("PASS: one transport-neutral plan, one rendered body per selected transport")
    }
}

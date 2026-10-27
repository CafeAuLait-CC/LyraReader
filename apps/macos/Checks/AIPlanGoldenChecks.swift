import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import LyraReaderBindings
import LyraReaderKit

// AI plan goldens: the exact request bodies and accounting for the region question, the
// document-knowledge-enriched question, the 120-page two-window abstract and every outline
// section. The file `tests/fixtures/ai-plan-goldens.json` was captured with the pre-change code;
// the check recomputes the same inputs through today's production paths and requires the whole
// snapshot (body, prompts, character counts, token estimate, coverage and section list) to be
// identical.

extension ReaderChecks {
    @MainActor
    static func captureAIPlanGoldens(root: URL) async throws {
        let snapshot = try await aiPlanGoldenSnapshot(root: root)
        let data = try canonicalGolden(snapshot)
        let output = root.appendingPathComponent("tests/fixtures/ai-plan-goldens.json")
        try data.write(to: output)
        print("PASS: wrote AI plan goldens to \(output.path)")
        printGoldenBodies(snapshot)
    }

    @MainActor
    static func checkAIPlanGoldens(root: URL) async throws {
        let current = try await aiPlanGoldenSnapshot(root: root)
        let fixture = root.appendingPathComponent("tests/fixtures/ai-plan-goldens.json")
        let storedData = try Data(contentsOf: fixture)
        guard let stored = try JSONSerialization.jsonObject(with: storedData) as? [String: Any] else {
            throw goldenError("ai-plan-goldens.json is not a JSON object")
        }
        let currentData = try canonicalGolden(current)
        var expectedBytes = storedData
        if expectedBytes.last == 0x0A { expectedBytes.removeLast() }
        var actualBytes = currentData
        if actualBytes.last == 0x0A { actualBytes.removeLast() }
        guard actualBytes == expectedBytes else {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lyra-ai-plan-goldens-diff", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let expectedFile = directory.appendingPathComponent("expected.json")
            let actualFile = directory.appendingPathComponent("actual.json")
            try expectedBytes.write(to: expectedFile)
            try actualBytes.write(to: actualFile)
            let expectedSections = stored["summary_sections"] as? [[String: Any]] ?? []
            let actualSections = current["summary_sections"] as? [[String: Any]] ?? []
            let sectionNote = expectedSections.map(sectionLine) == actualSections.map(sectionLine)
                ? "section list matches" : "section list differs"
            throw goldenError(
                "AI plan goldens differ (\(sectionNote)); expected \(expectedFile.path), "
                    + "actual \(actualFile.path)")
        }
        print("PASS: AI plan bodies, counts and section list match the frozen pre-change goldens")
        printGoldenBodies(current)
        let sections = current["summary_sections"] as? [[String: Any]] ?? []
        for section in sections {
            print("PASS: section row \(sectionLine(section))")
        }
    }

    @MainActor
    private static func aiPlanGoldenSnapshot(root: URL) async throws -> [String: Any] {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-ai-plan-goldens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let outlined = scratch.appendingPathComponent("outlined.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/outlined.pdf"), to: outlined)
        let long = scratch.appendingPathComponent("long-abstract.pdf")
        try writeLayeredFixture(to: long, pageCount: 120)

        let outlinedEngine = try RustEngine()
        let outlinedDocument = try outlinedEngine.openDocument(at: outlined)
        let longEngine = try RustEngine()
        let longDocument = try longEngine.openDocument(at: long)
        let textEngine = try RustEngine()
        _ = try textEngine.openDocument(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"))
        let textService = RustAIChatService(engine: textEngine, useMockProvider: true)
        let service = RustAIChatService(engine: outlinedEngine, useMockProvider: true)
        let longService = RustAIChatService(engine: longEngine, useMockProvider: true)
        let settings = AIProviderSettings(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            reasoningMode: .off,
            reasoningEncoding: .thinking,
            vision: true
        )

        let textPage = try await textEngine.textPage(0)
        let prefix = Array(textPage.chars.prefix(40))
        let minX = prefix.map { $0.xPt }.min() ?? 0
        let minY = prefix.map { $0.yPt }.min() ?? 0
        let maxX = prefix.map { $0.xPt + $0.widthPt }.max() ?? 1
        let maxY = prefix.map { $0.yPt + $0.heightPt }.max() ?? 1
        let regionRect = CGRect(x: minX - 2, y: minY - 2,
                                width: maxX - minX + 4, height: maxY - minY + 4)
        let regionText = try await textEngine.regionText(
            page: 0, rect: regionRect, limit: AIRegionLimits.maximumTextCharacters)

        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        let attachment = AIRegionAttachment(
            page: 0,
            rect: regionRect,
            text: regionText.text,
            png: png,
            pixelWidth: 1,
            pixelHeight: 1,
            captureScale: 2,
            textTruncated: regionText.truncated
        )
        let regionRequest = AIMakePlanRequest(
            action: .regionQuestion,
            currentPage: 1,
            selection: nil,
            question: "What does this region show?",
            language: nil,
            region: attachment,
            sendRegionImage: true,
            settings: settings
        )
        let regionPlan = try await textService.prepare(regionRequest)
        var regionSnapshot = try planSnapshot("region_question", regionPlan)
        regionSnapshot["region_text"] = regionText.text
        regionSnapshot["region_truncated"] = regionText.truncated
        regionSnapshot["region_rect"] = [Double(regionRect.minX), Double(regionRect.minY),
                                         Double(regionRect.width), Double(regionRect.height)]

        let askRequest = AIMakePlanRequest(
            action: .askSelection,
            currentPage: 1,
            selection: AIReaderSelection(page: 1, start: 0, end: 40),
            question: "What does this passage argue?",
            language: nil,
            includeDocumentContext: true,
            settings: settings
        )
        let knowledge = knowledgeFixture
        let enrichedAsk = try await service.prepare(
            askRequest.withDocumentKnowledge(knowledge, pages: [1, 2, 3]))
        var knowledgeSnapshot = try planSnapshot("knowledge_question", enrichedAsk)
        knowledgeSnapshot["knowledge"] = knowledge

        let abstractUnits = [AiSummaryUnitRequestRecord(
            kind: .abstract, index: 0, title: "Abstract", number: nil, depth: 0,
            pageStart: 1, pageEnd: UInt32(longDocument.pageCount)
        )]
        let abstractRequest = summaryRequest(
            layer: .abstract, units: abstractUnits, documentTitle: longDocument.title)
        let abstractPlan = try await longService.prepareSummary(abstractRequest)
        let abstractSnapshot = try summarySnapshot(
            abstractPlan.units[0], pageCount: longDocument.pageCount)

        let outlinedOutline = try await outlinedEngine.outline()
        let sections = AISummarySections.sections(
            outline: outlinedOutline, pageCount: outlinedDocument.pageCount)
        let sectionUnits = sections.enumerated().map { index, section in
            AiSummaryUnitRequestRecord(
                kind: .section, index: UInt32(index), title: section.title,
                number: section.number.isEmpty ? nil : section.number,
                depth: UInt32(max(0, section.depth)),
                pageStart: UInt32(max(0, section.pageStart)),
                pageEnd: UInt32(max(0, section.pageEnd))
            )
        }
        let sectionRequest = summaryRequest(
            layer: .section, units: sectionUnits, documentTitle: outlinedDocument.title)
        let sectionPlan = try await service.prepareSummary(sectionRequest)
        var sectionSnapshots: [[String: Any]] = []
        for (index, section) in sections.enumerated() {
            let unit = sectionPlan.units[index]
            var snapshot = try summarySnapshot(unit, pageCount: outlinedDocument.pageCount)
            snapshot["section"] = [
                "index": index,
                "title": section.title,
                "number": section.number,
                "depth": section.depth,
                "page_start": section.pageStart,
                "page_end": section.pageEnd,
                "link_page": section.linkPage,
            ]
            sectionSnapshots.append(snapshot)
        }

        return [
            "version": 1,
            "generator": "LyraReaderChecks --capture-ai-plan-goldens",
            "knowledge": knowledge,
            "region_question": regionSnapshot,
            "knowledge_question": knowledgeSnapshot,
            "summary_abstract": abstractSnapshot,
            "summary_sections": sectionSnapshots,
        ]
    }

    @MainActor
    private static func summaryRequest(
        layer: AiSummaryLayerRecord,
        units: [AiSummaryUnitRequestRecord],
        documentTitle: String
    ) -> AiSummaryRequestRecord {
        AiSummaryRequestRecord(
            layer: layer,
            units: units,
            language: nil,
            documentTitle: documentTitle,
            baseUrl: "http://127.0.0.1:11434/v1",
            model: "mock-model",
            temperature: 0.2,
            maxTokens: 900,
            reasoningMode: "off",
            reasoningEncoding: "thinking",
            documentKnowledgeText: nil,
            documentKnowledgePages: []
        )
    }

    @MainActor
    private static func summarySnapshot(
        _ unit: AiSummaryUnitRecord,
        pageCount: Int
    ) throws -> [String: Any] {
        var snapshot: [String: Any] = [
            "index": Int(unit.index),
            "kind": summaryLayerName(unit.kind),
            "title": unit.title,
            "number": unit.number ?? NSNull(),
            "depth": Int(unit.depth),
            "page_start": Int(unit.pageStart),
            "page_end": Int(unit.pageEnd),
            "covered_page_end": Int(unit.coveredPageEnd),
            "pages": unit.pages.map(Int.init),
            "truncated": unit.truncated,
            "text_hash": unit.textHash,
            "characters": unit.characters,
            "note": unit.note ?? NSNull(),
            "page_count": pageCount,
        ]
        if let plan = unit.plan {
            snapshot["plan"] = try planSnapshot("summary", plan)
        }
        return snapshot
    }

    @MainActor
    private static func planSnapshot(
        _ kind: String,
        _ plan: AiPlanRecord
    ) throws -> [String: Any] {
        let rendered = try AIPlanWire.render(plan, connection: .apiKey)
        let part = rendered.parts.first
        let body = part?.wireBody ?? ""
        let digest = SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return [
            "kind": kind,
            "action": actionName(rendered.action),
            "body": body,
            "body_sha256": digest,
            "body_utf8_len": body.utf8.count,
            "system_prompt": part?.systemPrompt ?? "",
            "user_prompt": part?.userPrompt ?? "",
            "page_characters": part?.pageCharacters ?? 0,
            "request_characters": part?.requestCharacters ?? 0,
            "estimated_tokens": rendered.estimatedTokens,
            "parts": rendered.parts.map {
                [
                    "index": Int($0.index), "total": Int($0.total), "label": $0.label,
                    "pages": $0.pages.map(Int.init), "page_characters": $0.pageCharacters,
                    "request_characters": $0.requestCharacters,
                    "note": $0.note ?? NSNull(), "has_image": $0.image != nil,
                ] as [String: Any]
            },
            "source_pages": rendered.sourcePages.map(Int.init),
            "note": rendered.note ?? NSNull(),
        ]
    }

    private static func canonicalGolden(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        data.append(0x0A)
        return data
    }

    private static func printGoldenBodies(_ snapshot: [String: Any]) {
        func printBody(_ label: String, _ plan: [String: Any]) {
            let body = plan["body"] as? String ?? ""
            let hash = plan["body_sha256"] as? String ?? ""
            print("PASS: \(label) body bytes=\(body.utf8.count) sha256=\(hash)")
        }
        if let region = snapshot["region_question"] as? [String: Any] {
            printBody("region question", region)
        }
        if let knowledge = snapshot["knowledge_question"] as? [String: Any] {
            printBody("knowledge question", knowledge)
        }
        if let abstract = snapshot["summary_abstract"] as? [String: Any],
           let plan = abstract["plan"] as? [String: Any] {
            printBody("summary abstract", plan)
        }
        let sections = snapshot["summary_sections"] as? [[String: Any]] ?? []
        for section in sections {
            if let plan = section["plan"] as? [String: Any] {
                printBody("section \(sectionLine(section))", plan)
            }
        }
    }

    private static func sectionLine(_ section: [String: Any]) -> String {
        guard let values = section["section"] as? [String: Any] else { return "?" }
        return "[\(values["index"] ?? -1)] \(values["title"] ?? "") "
            + "\(values["page_start"] ?? 0)-\(values["page_end"] ?? 0)"
    }

    private static func summaryLayerName(_ layer: AiSummaryLayerRecord) -> String {
        switch layer {
        case .abstract: return "abstract"
        case .section: return "section"
        case .page: return "page"
        }
    }

    private static func actionName(_ action: AiActionRecord) -> String {
        switch action {
        case .summarizePage: return "summarizePage"
        case .summarizeSelection: return "summarizeSelection"
        case .summarizeDocument: return "summarizeDocument"
        case .askSelection: return "askSelection"
        case .translateSelection: return "translateSelection"
        case .documentChat: return "documentChat"
        case .regionQuestion: return "regionQuestion"
        case .summarizeAbstract: return "summarizeAbstract"
        case .summarizeSection: return "summarizeSection"
        case .summarizePageLine: return "summarizePageLine"
        }
    }

    private static func goldenError(_ message: String) -> NSError {
        NSError(domain: "AIPlanGoldens", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static let knowledgeFixture = """
    Shared reading: the paper argues that attention is budgeted, not free. It defines a \
    terminology for "reading attention" — café 🎯 — reports an evaluation on three corpora, \
    and concludes that the approach improves comprehension. Unresolved: the ablation lacks a \
    human baseline, so the claim stays provisional.
    """
}

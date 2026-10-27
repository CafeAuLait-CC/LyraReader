import AppKit
import CryptoKit
import Foundation
import LyraReaderBindings
@testable import LyraReaderKit

// Contract-cleanup equivalence checks.
//
// Four of the five audit items changed *where* a value is computed, not what the reader sees.
// These checks keep a frozen copy of the previous Swift behaviour and require the new
// single-sourced Rust result to agree with it over a matrix. That is the evidence for "the
// visible output is unchanged": the reference is the code that shipped, copied here rather than
// imported, so a future change to either side fails loudly.

extension ReaderChecks {
    @MainActor static func contractCleanupChecks(root: URL) async throws {
        try zoomPolicyEquivalence()
        try pageLabelEquivalence()
        try dateParserEquivalence()
        try auditCategoryEquivalence()
        try exportByteEquivalence()
        try await documentIdentityChecks(root: root)
    }

    // MARK: - Item 2: zoom / fit policy

    /// The shipping Swift formula this policy replaced, frozen here as the equivalence oracle.
    private static func legacyFitPercent(_ contentPt: CGFloat, _ viewportPt: CGFloat,
                                         _ calibration: CGFloat) -> Int? {
        let inset: CGFloat = 8
        let available = viewportPt - 2 * inset
        guard contentPt.isFinite, contentPt > 0,
              available.isFinite, available > 0,
              calibration.isFinite, calibration > 0 else { return nil }
        let percent = available / (contentPt * calibration) * 100
        guard percent.isFinite else { return nil }
        return min(400, max(25, Int(percent.rounded(.down))))
    }

    private static func legacyClamp(_ offset: CGFloat, _ content: CGFloat, _ viewport: CGFloat) -> CGFloat {
        min(max(0, offset), max(0, content - viewport))
    }

    private static func policy(
        _ mode: ZoomModeRecord, percent: Int = 100, delta: Int = 0,
        page: CGSize = .zero, viewport: CGSize = .zero, calibration: CGFloat
    ) -> ZoomPolicyRecord {
        ZoomPolicyRecord(
            mode: mode,
            percent: UInt32(clamping: percent),
            delta: Int32(clamping: delta),
            pageWidthPt: Double(page.width),
            pageHeightPt: Double(page.height),
            viewportWidthPt: Double(viewport.width),
            viewportHeightPt: Double(viewport.height),
            calibration: Double(calibration)
        )
    }

    @MainActor
    private static func zoomPolicyEquivalence() throws {
        // Steps, including odd values and both clamps.
        for percent in [25, 26, 37, 99, 100, 123, 395, 400] {
            for delta in [-400, -10, -1, 0, 1, 10, 400] {
                let expected = min(400, max(25, percent + delta))
                let resolved = resolveZoom(policy: policy(
                    .percent, percent: percent, delta: delta, calibration: 1))
                require(resolved == UInt32(expected),
                        "step \(percent)\(delta >= 0 ? "+" : "")\(delta) = \(expected)%")
            }
        }
        require(resolveZoom(policy: policy(
            .percent, percent: 100, delta: 10, calibration: 1)) == 110,
            "the toolbar step is the same integer percent")
        require(resolveZoom(policy: policy(
            .percent, percent: 400, delta: 10, calibration: 1)) == 400,
            "the 400% clamp is unchanged")
        require(resolveZoom(policy: policy(
            .percent, percent: 25, delta: -10, calibration: 1)) == 25,
            "the 25% clamp is unchanged")

        // Fit width / fit page over page sizes, viewports and calibrations (including the
        // degenerate cases where the old formula returned nil).
        let widths: [CGFloat] = [0, 1, 100, 595, 1000, 100_000]
        let heights: [CGFloat] = [0, 1, 200, 842, 1000, 100_000]
        let viewports: [CGFloat] = [-10, 0, 10, 16, 17, 240, 595, 800, 1000, 4000, 100_000]
        let calibrations: [CGFloat] = [0, 0.5, 1, 1.507, 2, .nan]
        for width in widths {
            for viewport in viewports {
                for calibration in calibrations {
                    let expected = legacyFitPercent(width, viewport, calibration)
                    let resolved = resolveZoom(policy: policy(
                        .fitWidth,
                        page: CGSize(width: width, height: 1),
                        viewport: CGSize(width: viewport, height: 1),
                        calibration: calibration))
                    require(resolved.map(Int.init) == expected,
                            "fit width \(width) into \(viewport) @\(calibration): "
                                + "\(String(describing: resolved)) vs \(String(describing: expected))")
                }
            }
        }
        for height in heights {
            for viewport in viewports {
                for calibration in calibrations {
                    let expected = legacyFitPercent(height, viewport, calibration)
                    let resolved = resolveZoom(policy: policy(
                        .fitPage,
                        page: CGSize(width: 1, height: height),
                        viewport: CGSize(width: 1, height: viewport),
                        calibration: calibration))
                    require(resolved.map(Int.init) == expected,
                            "fit page \(height) into \(viewport) @\(calibration): "
                                + "\(String(describing: resolved)) vs \(String(describing: expected))")
                }
            }
        }
        // The exact numbers the shipping presets produced for an A4 page.
        require(resolveZoom(policy: policy(
            .fitWidth, page: CGSize(width: 595, height: 842),
            viewport: CGSize(width: 1000, height: 800), calibration: 1)) == 165,
            "A4 fit width is 165%")
        require(resolveZoom(policy: policy(
            .fitWidth, page: CGSize(width: 595, height: 842),
            viewport: CGSize(width: 1000, height: 800), calibration: 1.507)) == 109,
            "A4 fit width at 1.507 calibration is 109%")
        require(resolveZoom(policy: policy(
            .fitPage, page: CGSize(width: 595, height: 842),
            viewport: CGSize(width: 1000, height: 800), calibration: 1)) == 93,
            "A4 fit page is 93%")

        // Scroll clamp over a matrix, including the end of the document and a short document.
        let offsets: [CGFloat] = [-1000, -0.5, 0, 1, 240, 5000]
        let contents: [CGFloat] = [0, 100, 800, 1000, 2550]
        let heightsViewport: [CGFloat] = [0, 1, 300, 800, 2000]
        for offset in offsets {
            for content in contents {
                for viewport in heightsViewport {
                    let expected = legacyClamp(offset, content, viewport)
                    let resolved = CGFloat(clampScroll(
                        offsetPt: Double(offset),
                        contentHeightPt: Double(content),
                        viewportHeightPt: Double(viewport)))
                    require(abs(resolved - expected) < 0.000_001,
                            "clamp \(offset) in \(content)-\(viewport): \(resolved) vs \(expected)")
                }
            }
        }
        require(zoomMinPercent() == 25 && zoomMaxPercent() == 400,
                "the reader's range is still 25…400%")
        require(abs(zoomPresetInsetPt() - 8) < 0.000_001,
                "the fit inset is still 8 pt per side")
    }

    // MARK: - Item 3: page labels

    private static func legacyPageLabel(_ input: [Int]) -> String {
        let pages = Array(Set(input)).sorted()
        guard let first = pages.first else { return "No pages" }
        if pages.count == 1 { return "Page \(first)" }
        if zip(pages, pages.dropFirst()).allSatisfy({ $0 + 1 == $1 }) {
            return "Pages \(first)-\(pages.last!)"
        }
        return "Pages " + pages.map(String.init).joined(separator: ", ")
    }

    private static func legacyRangesLabel(_ input: [Int]) -> String {
        var ranges: [(Int, Int)] = []
        for page in input.sorted() where ranges.last?.1 != page {
            if let end = ranges.last?.1, page == end + 1 {
                ranges[ranges.count - 1].1 = page
            } else {
                ranges.append((page, page))
            }
        }
        return ranges.map { $0.0 == $0.1 ? "\($0.0)" : "\($0.0)-\($0.1)" }
            .joined(separator: " and ")
    }

    private static func legacyPageList(_ pages: [Int]) -> String {
        guard let first = pages.first, let last = pages.last else { return "no pages" }
        if pages.count == 1 { return "page \(first + 1)" }
        if last - first + 1 == pages.count {
            return first == last ? "page \(first + 1)" : "pages \(first + 1)–\(last + 1)"
        }
        return "pages " + pages.map { String($0 + 1) }.joined(separator: ", ")
    }

    private static func legacyCompactRanges(_ input: [Int]) -> String {
        let sorted = Array(Set(input)).sorted()
        var parts: [String] = []
        var start: Int?
        var previous = Int.min
        func appendRange(_ first: Int, _ last: Int) {
            parts.append(first == last ? "\(first + 1)" : "\(first + 1)-\(last + 1)")
        }
        for page in sorted {
            if let first = start {
                if page == previous + 1 { previous = page; continue }
                appendRange(first, previous)
            }
            start = page
            previous = page
        }
        if let first = start { appendRange(first, previous) }
        return parts.joined(separator: ", ")
    }

    @MainActor
    private static func pageLabelEquivalence() throws {
        let matrices: [[Int]] = [
            [], [1], [3], [1, 2, 3], [3, 2, 1], [1, 2, 2, 3],
            [1, 3, 5], [1, 2, 4, 5], Array(1...12), Array(1...12) + Array(109...120),
        ]
        for pages in matrices {
            let unsigned = pages.map { UInt32(max(0, $0)) }
            require(pageLabel(pages: unsigned) == legacyPageLabel(pages),
                    "page label \(pages): \(pageLabel(pages: unsigned))")
            require(pageRangesLabel(pages: unsigned) == legacyRangesLabel(pages),
                    "range label \(pages): \(pageRangesLabel(pages: unsigned))")
            let compactInput = pages.map { UInt32(max(0, $0) + 1) }
            require(compactPageRanges(pages: compactInput) == legacyCompactRanges(pages),
                    "compact ranges \(pages): \(compactPageRanges(pages: compactInput))")
            let zeroBased = pages.map { UInt32(max(0, $0 - 1)) }
            require(pageList(pages: zeroBased) == legacyPageList(pages.map { $0 - 1 }),
                    "page list \(pages): \(pageList(pages: zeroBased))")
        }
        // The summary span grammar, frozen literals.
        require(pageSpanLabel(kind: "abstract", pages: [1, 2, 3, 4, 5],
                              pageStart: 1, pageEnd: 5, coveredPageEnd: 0,
                              truncated: false, pageCount: 5) == "All 5 pages",
                "a complete abstract says All 5 pages")
        require(pageSpanLabel(kind: "abstract", pages: Array(1...3) + Array(9...12),
                              pageStart: 1, pageEnd: 12, coveredPageEnd: 0,
                              truncated: false, pageCount: 12) == "Pages 1-3 and 9-12 of 12",
                "a two-window abstract keeps its exact wording")
        require(pageSpanLabel(kind: "sections", pages: [],
                              pageStart: 4, pageEnd: 12, coveredPageEnd: 7,
                              truncated: true, pageCount: 120) == "Pages 4-7 of 4-12",
                "a truncated section keeps its exact wording")
    }

    // MARK: - Item 3: PDF dates

    @MainActor
    private static func dateParserEquivalence() throws {
        // Sidebar/passage display keeps the historical clock-as-written string, including for a
        // zoned date: this is the deliberate divergence documented in the report.
        require(pdfDateDisplay(value: "D:20261017174000-07'00'") == "2026-10-17 17:40",
                "the sidebar keeps showing the zoned clock digits as written")
        require(pdfDateDisplay(value: "D:20240229120000") == "2024-02-29 12:00",
                "a valid local date formats as before")
        require(pdfDateDisplay(value: "D:20260230120000") == "D:20260230120000",
                "an invalid date returns the file's string, as before")
        require(pdfDateDisplay(value: "not a pdf date") == "not a pdf date",
                "a non-PDF date string is preserved")
        require(pdfDateDisplay(value: "") == nil, "no /M means no display date")

        // The export parser applies the offset. `-07'00'` is seven hours behind UTC.
        let utc = pdfDateMillis(value: "D:20261017174000Z")
        let zoned = pdfDateMillis(value: "D:20261017174000-07'00'")
        require(utc != nil && zoned != nil, "both date shapes parse")
        require(zoned! - utc! == 7 * 3_600 * 1_000,
                "the export applies the negative offset")
        require(pdfDateMillis(value: "D:20261017174000+02'30'")! - utc! == -(2 * 3_600 + 30 * 60) * 1_000,
                "the export applies the positive offset")
        require(pdfDateMillis(value: "D:20261017174000") == utc,
                "a date with no zone is UTC, as before")
        require(pdfDateMillis(value: "D:2026") == nil,
                "a short date is not invented")

        // The export's Date conversion is byte-for-byte the same instant as the old parser.
        let zonedDate = AnnotationExport.date(fromPDFDate: "D:20261017174000-07'00'")
        require(zonedDate == Date(timeIntervalSince1970: TimeInterval((utc! + 7 * 3_600 * 1_000)) / 1000),
                "the CSV/Markdown date is the same instant")
        require(AnnotationExport.date(fromPDFDate: "D:2026") == nil,
                "an unparseable export date stays nil")
    }

    // MARK: - Item 4: AI audit categories

    /// The pre-cleanup stream classifier, frozen as the oracle for the code mapping.
    private static func legacyStreamCategory(_ message: String,
                                             _ failure: AIRequestFailure) -> AIAuditCode {
        switch failure {
        case .offline: return .offline
        case .localServer: return .localServer
        case .other: break
        }
        let lower = message.lowercased()
        if lower.contains("unauthorized") || lower.contains("401") || lower.contains("api key") {
            return .unauthorized
        }
        if lower.contains("rate limit") || lower.contains("429") { return .rateLimited }
        if lower.contains("timed out") || lower.contains("timeout") { return .timeout }
        if lower.contains("http ") { return .httpError }
        if lower.contains("stream") || lower.contains("protocol") || lower.contains("malformed") {
            return .protocolError
        }
        if lower.contains("unreachable") || lower.contains("connection") { return .unreachable }
        if lower.contains("unsupported") || lower.contains("does not support") {
            return .unsupportedCapability
        }
        return .providerError
    }

    /// The pre-cleanup preparation classifier, frozen as the oracle.
    private static func legacyPreparationCategory(_ message: String, baseURL: String) -> AIAuditCode {
        if message.contains("Nothing in this document is relevant") { return .nothingRelevant }
        if message.contains("Turn on image input") { return .visionUnsupported }
        if message.contains("no text layer") || message.contains("not available")
            || message.contains("too large") || message.contains("too long")
            || message.contains("nothing to send") || message.contains("nothing to ask")
            || message.contains("has no pages") || message.contains("outside this document") {
            return .emptyContext
        }
        if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noEndpoint }
        if message.contains("base URL") || message.contains("endpoint")
            || message.contains("model") || message.contains("Temperature")
            || message.contains("Max tokens") || message.contains("reasoning") {
            return .invalidSettings
        }
        return .other
    }

    /// The pre-cleanup start classifier, frozen as the oracle.
    private static func legacyStartCategory(_ message: String) -> AIAuditCode {
        if message.contains("No API key") { return .noApiKey }
        if message.contains("connection changed") { return .connectionChanged }
        if message.contains("ChatGPT account") || message.contains("Connect ChatGPT") {
            return .signedOut
        }
        if message.contains("engine is not available") { return .notConfigured }
        if message.contains("Keychain") { return .keychainUnavailable }
        return .invalidSettings
    }

    @MainActor
    private static func auditCategoryEquivalence() throws {
        let streamCases: [(String, AIRequestFailure, AiErrorCode)] = [
            ("unauthorized (check API key)", .other, .unauthorized),
            ("HTTP 401 from the provider", .other, .unauthorized),
            ("rate limited; retry later", .other, .rateLimited),
            ("HTTP 429", .other, .rateLimited),
            ("timed out after 60s", .other, .timeout),
            ("provider timeout", .other, .timeout),
            ("HTTP 500 from the provider", .other, .httpStatus),
            ("malformed stream frame", .other, .protocol),
            ("protocol error", .other, .protocol),
            ("provider unreachable: no route", .other, .unreachable),
            ("connection closed", .other, .unreachable),
            ("model lacks capability: image input", .other, .unsupportedCapability),
            ("something else entirely", .other, .other),
            ("AI provider not configured", .other, .notConfigured),
            ("provider unreachable: no network route", .offline, .offline),
            ("provider unreachable: local server is not running", .localServer, .localServer),
        ]
        for (message, failure, code) in streamCases {
            require(AIAuditCode.classifyStreamFailure(code: code)
                        == legacyStreamCategory(message, failure),
                    "stream code \(code) keeps the category for \(message)")
        }

        let preparationCases: [(String, String, AiErrorCode)] = [
            ("Nothing in this document is relevant to the question, so nothing was sent.",
             "https://api.example.com/v1", .nothingRelevant),
            ("Turn on image input in Settings > AI, or select a region with text.",
             "https://api.example.com/v1", .visionUnsupported),
            ("This document has no pages.", "https://api.example.com/v1", .emptyContext),
            ("The selected page is outside this document.", "https://api.example.com/v1", .emptyContext),
            ("The endpoint URL is not valid: bad host", "https://api.example.com/v1", .invalidSettings),
            ("model lacks capability: image input", "https://api.example.com/v1", .unsupportedCapability),
            ("AI provider not configured", "https://api.example.com/v1", .notConfigured),
            ("Select text first; there is no selection to send.", "https://api.example.com/v1", .other),
            ("This document has no pages.", "", .emptyContext),
            ("Nothing in this document is relevant.", "", .nothingRelevant),
            ("The endpoint URL is not valid: bad host", "", .invalidSettings),
            ("AI provider not configured", "", .notConfigured),
        ]
        for (message, baseURL, code) in preparationCases {
            let error = LyraReaderFfiError.Ai(message: message, code: code, severity: .recoverable)
            require(AIAuditCode.classifyPreparationFailure(error, baseURL: baseURL)
                        == legacyPreparationCategory(message, baseURL: baseURL),
                    "preparation code \(code) keeps the category for \(message) (base \(baseURL))")
        }

        let startCases: [(String, AISettingsError, AIAuditCode)] = [
            ("No API key", .refused("No API key is configured.", .noApiKey), .noApiKey),
            ("connection changed", .refused("The AI connection changed.", .connectionChanged),
             .connectionChanged),
            ("ChatGPT account", .refused("The ChatGPT account changed.", .signedOut), .signedOut),
            ("engine is not available", .refused("The Rust engine is not available.", .notConfigured),
             .notConfigured),
            ("anything", .invalid("anything"), .invalidSettings),
        ]
        for (message, error, expected) in startCases {
            require(AIAuditCode.classifyStartFailure(error) == legacyStartCategory(message),
                    "start refusal \(message) keeps the category")
            require(AIAuditCode.classifyStartFailure(error) == expected,
                    "start refusal \(message) is \(expected)")
        }
        require(AIAuditCode.classifyStartFailure(
            NSError(domain: "test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Keychain denied"])) == .other,
                "a non-settings Keychain error is still other, as before")

        // The stable code is the Rust variant's, not the message's: a success-looking message
        // cannot change what an unauthorized failure records.
        require(AiErrorCode.unauthorized != .other,
                "the code enum distinguishes unauthorized from other")
    }

    // MARK: - Item 3: export bytes

    @MainActor
    private static func exportByteEquivalence() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let entries = [
            AnnotationExportEntry(
                id: "nm:note", page: 0, kind: "text", colorHex: "#FFCC33FF",
                author: "Reviewer A", date: Date(timeIntervalSince1970: 1_704_164_645),
                quote: nil, comment: "A sticky note body.", source: .pdf, yPt: 40),
            AnnotationExportEntry(
                id: "cached-highlight", page: 1, kind: "highlight", colorHex: "#FFD84066",
                author: "Alex", date: Date(timeIntervalSince1970: 1_717_236_000),
                quote: "Something underlined.", comment: nil, source: .sidecar, yPt: 200),
        ]
        let document = AnnotationExportDocument(
            fileName: "paper.pdf", pageCount: 3,
            exportedAt: Date(timeIntervalSince1970: 1_792_258_800),
            timeZone: utc, entries: entries)
        let csv = AnnotationExport.csv(document)
        let expectedCSV = "page,type,author,date,colour,quote,comment,reply_to,id,source\r\n"
            + "1,text,Reviewer A,2024-01-02T03:04:05Z,#FFCC33FF,,A sticky note body.,,nm:note,pdf\r\n"
            + "2,highlight,Alex,2024-06-01T10:00:00Z,#FFD84066,Something underlined.,,,cached-highlight,sidecar\r\n"
        require(csv == expectedCSV, "CSV is byte-identical to the captured fixture")
        let markdown = AnnotationExport.markdown(document)
        require(markdown.contains("## Page 1\n") && markdown.contains("## Page 2\n")
                    && !markdown.contains("## Page 3"),
                "Markdown page headings use the same page labels")
        require(markdown.contains("- **Date:** 2024-01-02T03:04:05Z"),
                "Markdown dates are the same instant")
    }

    // MARK: - Item 1: one document identity

    @MainActor
    private static func documentIdentityChecks(root: URL) async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("lyra-docid-\(UUID())")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let source = root.appendingPathComponent("tests/fixtures/text-page.pdf")
        let real = scratch.appendingPathComponent("real.pdf")
        let link = scratch.appendingPathComponent("link.pdf")
        try fm.copyItem(at: source, to: real)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let realID = try RustEngine().openDocument(at: real).documentId
        let linkID = try RustEngine().openDocument(at: link).documentId
        require(!realID.isEmpty && realID == linkID,
                "a symlink and its target have one DocumentId")
        let freeFunctionID = try documentIdForPath(path: real.path)
        require(realID == freeFunctionID,
                "the engine and the free function compute the same key")

        // The old cache was keyed by the canonical path alone. Seed records there and verify
        // that both aliases read them, and that the new key has a copy.
        let canonical = real.standardizedFileURL.resolvingSymlinksInPath().path
        let legacyKey = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let legacyDirectory = DocumentEditCache.root.appendingPathComponent(legacyKey, isDirectory: true)
        try fm.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let mark = AppState.Annotation(
            id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color,
            note: "legacy cache still loads", createdAt: Date())
        let records = try AnnotationRecords.encode(
            annotations: [mark], bookmarks: [], slots: [.annotation(mark.id)])
        try records.write(to: legacyDirectory.appendingPathComponent("annotations.json"))

        let attachment = AIRegionAttachment(
            page: 0, rect: CGRect(x: 10, y: 10, width: 40, height: 30),
            text: "region text", png: Data(), pixelWidth: 1, pixelHeight: 1, captureScale: 2)
        let legacyEntry = AIRegionHistoryEntry(
            documentKey: real.path, attachment: attachment,
            question: "What is this?", answer: "A region.",
            state: .finished, createdAt: Date(timeIntervalSince1970: 10))
        let encodedHistory = try JSONEncoder().encode([legacyEntry])
        try encodedHistory.write(to: legacyDirectory
            .appendingPathComponent("region-conversations-v1.json"))

        func openBoth(_ url: URL) async throws -> AppState {
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(CGSize(width: 1000, height: 800))
            require(state.open(url: url), "the identity fixture opens via \(url.lastPathComponent)")
            try await eventually("the identity fixture loads its legacy annotations", {
                state.annotations.count == 1
            })
            return state
        }

        let byReal = try await openBoth(real)
        require(byReal.annotations.first?.note == "legacy cache still loads",
                "the legacy annotation cache still loads through the new key")
        require(byReal.regionDocumentKey == realID,
                "the region key is the DocumentId, not the path")
        require(byReal.currentRegionHistory.count == 1,
                "the legacy conversation is retargeted to the DocumentId")
        require(DocumentEditCache.documentIdentity(for: link) == realID,
                "the symlink alias resolves to the same cache identity")
        require(DocumentEditCache.directory(for: link) == DocumentEditCache.directory(for: real),
                "both aliases use one annotation cache directory")
        require(fm.fileExists(atPath: DocumentEditCache.directory(for: real)
            .appendingPathComponent("annotations.json").path),
                "the legacy records were migrated into the new directory")
        require(fm.fileExists(atPath: legacyDirectory.appendingPathComponent("annotations.json").path),
                "the old files stay readable")

        let byLink = try await openBoth(link)
        require(byLink.regionDocumentKey == realID,
                "the second alias sees the same conversation key")
        require(byLink.currentRegionHistory.count == 1,
                "the second alias sees the same conversation history")
        require(byLink.annotations.count == 1,
                "the second alias sees the same annotation cache")
        require(RecentDocumentStore.documentKey(for: real) == RecentDocumentStore.documentKey(for: link),
                "the recent-document cover key is one identity too")

        // The sidebar subtitle / annotation-passage line is assembled from the record's own
        // page label and display date. Freeze the exact string for the annotated fixture.
        let annotated = AppState(engine: try RustEngine())
        annotated.setViewportSize(CGSize(width: 1000, height: 800))
        let annotatedURL = root.appendingPathComponent("tests/fixtures/annotated.pdf")
        require(annotated.open(url: annotatedURL), "the annotated fixture opens")
        try await eventually("the annotated fixture's file annotations load", {
            !annotated.documentAnnotations.isEmpty
        })
        guard let highlight = annotated.documentAnnotations.first(where: {
            $0.modified == "D:20240102030405Z"
        }) else {
            fatalError("FAIL: the annotated fixture's dated highlight is present")
        }
        require(highlight.pageLabel == "Page 1",
                "the annotation record's page label is the sidebar's label")
        require(highlight.displayDate == "2024-01-02 03:04",
                "the annotation record's display date keeps the historical UTC-clock string")
        let sidebarLine = "\(highlight.pageLabel) · \(highlight.author ?? "") · \(highlight.displayDate ?? "")"
        require(sidebarLine == "Page 1 · Reviewer A · 2024-01-02 03:04",
                "the sidebar/passages line is byte-identical: \(sidebarLine)")

        // A changed body gets a new identity (so a replaced file cannot inherit caches), while a
        // touch does not.
        var bytes = try Data(contentsOf: real)
        bytes.append(0x20)
        try bytes.write(to: real, options: .atomic)
        let changedID = try RustEngine().openDocument(at: real).documentId
        require(changedID != realID, "one changed byte is a different document identity")
    }
}

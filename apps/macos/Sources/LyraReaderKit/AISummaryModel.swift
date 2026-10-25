import Combine
import Foundation
import LyraReaderBindings

// MARK: - Layers and rows

/// The three navigable levels of a document summary.
public enum AISummaryLayer: String, CaseIterable, Identifiable, Sendable {
    case abstract, sections, pages

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .abstract: return "Abstract"
        case .sections: return "Sections"
        case .pages: return "Pages"
        }
    }

    public var icon: String {
        switch self {
        case .abstract: return "doc.text.magnifyingglass"
        case .sections: return "list.bullet.indent"
        case .pages: return "doc.on.doc"
        }
    }

    /// The row title the Rust builder expects.
    var record: AiSummaryLayerRecord {
        switch self {
        case .abstract: return .abstract
        case .sections: return .section
        case .pages: return .page
        }
    }

    /// Whether the layer is keyed to the outline, page ranges or single pages.
    public var sourceLabel: String {
        switch self {
        case .abstract: return "Bounded sample of the document"
        case .sections: return "Outline sections (page ranges when there is no outline)"
        case .pages: return "One line for every page"
        }
    }
}

/// What one row is doing. Everything except `ready` is visibly distinct in the panel, and a
/// failed or cancelled row keeps its own Retry button.
public enum AISummaryEntryState: Equatable, Sendable {
    case notGenerated
    case generating
    case ready
    /// A cached summary for an older hash of this entry's text. It is shown but labelled.
    case stale
    case failed(String)
    case cancelled

    public var label: String {
        switch self {
        case .notGenerated: return "Not generated"
        case .generating: return "Generating…"
        case .ready: return "Ready"
        case .stale: return "Stale"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    public var isReady: Bool { self == .ready }
    public var isBusy: Bool { self == .generating }
    public var needsRetry: Bool {
        switch self {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .ready, .failed, .cancelled, .stale: return true
        default: return false
        }
    }
}

/// One row of one layer: the unit to summarise, its page span and its current text.
public struct AISummaryEntry: Identifiable, Equatable, Sendable {
    /// Stable within a document and language-independent: "abstract", "section:3", "page:12".
    public let id: String
    public let kind: AISummaryLayer
    public let unitIndex: Int
    public let title: String
    public let number: String?
    public let depth: Int
    /// 1-based, inclusive; what the row asked for.
    public let pageStart: Int
    public let pageEnd: Int
    /// 0-based page clicking this row jumps to.
    public let linkPage: Int
    public var state: AISummaryEntryState = .notGenerated
    public var summary: String = ""
    public var error: String?
    /// The fixed transport category when this row failed. Nil for local refusals and after a
    /// successful retry.
    public var failure: AIRequestFailure?
    /// The honest coverage line from the builder, e.g. "Summarised from pages 1-12 and
    /// 109-120 of 120."
    public var note: String?
    /// The last page actually sent. For an abstract that samples both ends this is the end
    /// window's last page; `pages` lists both windows.
    public var coveredPageEnd: Int = 0
    public var truncated = false
    /// 1-based pages actually sent, in order. A long document's abstract holds the beginning
    /// window followed by the end window.
    public var pages: [Int] = []
    /// SHA-256 of exactly the text this unit sends; part of the cache key.
    public var textHash: String = ""
    public var charactersSent: UInt64 = 0
    /// The model and language that produced `summary`. The language is part of the cache key,
    /// so a ready row may only be kept when these still match the current selection.
    public var summaryModel: String = ""
    public var summaryLanguage: String = ""

    public var isLinkable: Bool { kind != .abstract }

    /// Collapse an ascending page list into inclusive ranges: `[1...12, 109...120]` becomes
    /// "1-12 and 109-120". A two-window abstract has exactly two ranges; a document that fits
    /// the windows has one.
    public static func pageRangesLabel(_ pages: [Int]) -> String {
        LyraReaderBindings.pageRangesLabel(pages: pages.map { UInt32(max(0, $0)) })
    }

    /// "Page 3", "Pages 2-5", "Pages 1-12 and 109-120 of 120".
    public func pageSpanLabel(pageCount: Int) -> String {
        LyraReaderBindings.pageSpanLabel(
            kind: kind.rawValue,
            pages: pages.map { UInt32(max(0, $0)) },
            pageStart: UInt32(max(0, pageStart)),
            pageEnd: UInt32(max(0, pageEnd)),
            coveredPageEnd: UInt32(max(0, coveredPageEnd)),
            truncated: truncated,
            pageCount: UInt32(max(0, pageCount))
        )
    }

    /// How many pages this row covers.
    public func pageCountLabel(documentPageCount: Int) -> String {
        switch kind {
        case .abstract:
            if !pages.isEmpty {
                return "\(pages.count) of \(documentPageCount) pages"
            }
            let end = coveredPageEnd > 0 ? coveredPageEnd : min(pageEnd, documentPageCount)
            return "\(max(0, end)) of \(documentPageCount) pages"
        case .sections, .pages:
            let end = coveredPageEnd > 0 ? min(coveredPageEnd, pageEnd) : pageEnd
            let count = max(0, end - pageStart + 1)
            return count == 1 ? "1 page" : "\(count) pages"
        }
    }
}

// MARK: - Outline → section rows

/// One section row derived from the document outline, or from a page range when the document
/// has no outline. Pages are 1-based and inclusive; `linkPage` is 0-based.
public struct AISummarySection: Equatable, Sendable {
    public let title: String
    public let number: String
    public let depth: Int
    public let pageStart: Int
    public let pageEnd: Int
    public let linkPage: Int

    public init(
        title: String,
        number: String,
        depth: Int,
        pageStart: Int,
        pageEnd: Int,
        linkPage: Int
    ) {
        self.title = title
        self.number = number
        self.depth = depth
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.linkPage = linkPage
    }
}

public enum AISummarySections {
    /// Turn a flattened outline into section page ranges.
    ///
    /// The rules live in Rust (`lyra_reader_ai::sections`) so the summary builder and the panel
    /// cannot disagree about which page range a section request carries. Reader bookmarks are
    /// excluded; a missing destination is filled from a later (then earlier) entry; a section
    /// ends before the next entry that starts later; no usable outline falls back to ten-page
    /// ranges with page labels.
    public static func sections(outline: [OutlineEntry], pageCount: Int) -> [AISummarySection] {
        LyraReaderBindings.aiSummarySections(
            outline: outline.map { entry in
                LyraReaderBindings.OutlineEntry(
                    title: entry.title,
                    page: entry.page.map { UInt32(max(0, $0)) },
                    depth: UInt32(max(0, entry.depth)),
                    bookmarkId: entry.bookmarkID,
                    yPt: entry.yPt,
                    isBookmarkSubtree: entry.isBookmarkSubtree
                )
            },
            pageCount: UInt32(max(0, pageCount))
        ).map { section in
            AISummarySection(
                title: section.title,
                number: section.number,
                depth: Int(section.depth),
                pageStart: Int(section.pageStart),
                pageEnd: Int(section.pageEnd),
                linkPage: Int(section.linkPage)
            )
        }
    }
}

// MARK: - Cache

/// One cached summary. The cache key is the tuple the task names: layer + unit, the model, the
/// target language and the SHA-256 of exactly the covered text. The document directory is the
/// same cache the annotations use (`DocumentEditCache`), never a file beside the PDF.
public struct AISummaryCacheEntry: Codable, Equatable, Sendable {
    public var layer: String
    public var unit: String
    public var model: String
    public var language: String
    public var textHash: String
    public var title: String
    public var pageStart: Int
    public var pageEnd: Int
    public var summary: String
    public var savedAt: Date
}

/// Reads and writes `summaries.json` in the document's annotation-cache directory.
@MainActor
public final class AISummaryCache {
    public static let fileName = "summaries.json"
    /// Older models and languages are kept, but the file cannot grow without a bound.
    public static let maximumEntries = 600

    public let documentURL: URL
    public private(set) var entries: [AISummaryCacheEntry] = []
    public private(set) var lastError: String?

    public init(documentURL: URL) {
        self.documentURL = documentURL
        load()
    }

    public var fileURL: URL {
        DocumentEditCache.directory(for: documentURL).appendingPathComponent(Self.fileName)
    }

    public static func key(
        layer: AISummaryLayer,
        unit: String,
        model: String,
        language: String,
        textHash: String
    ) -> String {
        "\(layer.rawValue)|\(unit)|\(model)|\(language)|\(textHash)"
    }

    public func summary(
        layer: AISummaryLayer,
        unit: String,
        model: String,
        language: String,
        textHash: String
    ) -> String? {
        entries.first {
            $0.layer == layer.rawValue && $0.unit == unit && $0.model == model
                && $0.language == language && $0.textHash == textHash
        }?.summary
    }

    /// Any cached row for this unit/model/language, regardless of hash. A non-nil result whose
    /// hash differs is what the panel shows as `stale`.
    public func staleEntry(
        layer: AISummaryLayer,
        unit: String,
        model: String,
        language: String
    ) -> AISummaryCacheEntry? {
        entries
            .filter {
                $0.layer == layer.rawValue && $0.unit == unit && $0.model == model
                    && $0.language == language
            }
            .max { $0.savedAt < $1.savedAt }
    }

    public func store(
        layer: AISummaryLayer,
        unit: String,
        model: String,
        language: String,
        textHash: String,
        title: String,
        pageStart: Int,
        pageEnd: Int,
        summary: String
    ) {
        let entry = AISummaryCacheEntry(
            layer: layer.rawValue,
            unit: unit,
            model: model,
            language: language,
            textHash: textHash,
            title: title,
            pageStart: pageStart,
            pageEnd: pageEnd,
            summary: summary,
            savedAt: Date()
        )
        entries.removeAll {
            $0.layer == entry.layer && $0.unit == entry.unit && $0.model == entry.model
                && $0.language == entry.language
        }
        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.sort { $0.savedAt < $1.savedAt }
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        save()
    }

    private struct Stored: Codable {
        var entries: [AISummaryCacheEntry]
    }

    private func load() {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            entries = try JSONDecoder().decode(Stored.self, from: data).entries
            lastError = nil
        } catch {
            lastError = "The summary cache could not be read; cached rows are ignored (the PDF is untouched)."
            entries = []
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Stored(entries: entries))
            let directory = DocumentEditCache.directory(for: documentURL)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "The summary was generated but could not be cached: \(error.localizedDescription)"
        }
    }
}

// MARK: - Layered summary model

/// The panel's layered summary state machine.
///
/// One Generate press builds a preview of at most `maxRequestsPerBatch` independent requests,
/// then runs them with at most `maxConcurrentRequests` in flight. Each completed row is cached
/// immediately, so Cancel keeps finished rows and Retry re-sends exactly the failed row's
/// already-previewed request. Nothing reaches a provider until the reader presses Send.
@MainActor
public final class LayeredSummaryModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case refreshing
        case preview
        case generating
        case finished
        case cancelled
        case failed
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var entries: [AISummaryEntry] = []
    @Published public private(set) var preview: AiSummaryPlanRecord?
    @Published public private(set) var previewLayer: AISummaryLayer?
    @Published public private(set) var generationLayer: AISummaryLayer?
    @Published public private(set) var statusNote: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var documentKey: String?
    @Published public private(set) var documentTitle = ""
    @Published public private(set) var pageCount = 0
    @Published public private(set) var language = ""
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var isPreparing = false
    @Published public private(set) var activeRequests = 0
    @Published public private(set) var finishedRequests = 0
    @Published public private(set) var batchRequests = 0
    @Published public private(set) var cacheURL: URL?
    @Published public private(set) var cacheError: String?
    public let bounds: AiSummaryLimitsRecord

    /// The same calm hint the assistant panel shows, derived from the rows' fixed transport
    /// categories. Nil when no row failed with a recognized offline/local-server error.
    public var offlineHint: AIOfflineHint? {
        guard phase == .failed || phase == .finished || phase == .cancelled else {
            return nil
        }
        let failures = entries.compactMap(\.failure)
        if failures.contains(.offline) { return AIOfflineHint(kind: .noNetwork) }
        if failures.contains(.localServer) { return AIOfflineHint(kind: .localServer) }
        return nil
    }

    public let settings: AISettingsStore
    /// The shared local audit trail. Each previewed unit is its own outgoing request, so a
    /// batch writes one record per unit that actually starts.
    public let audit: AIAuditTrail
    private var service: (any AIChatServicing)?
    private var context: AIReaderContext?
    private var documentURL: URL?
    private var outline: [OutlineEntry] = []
    private var outlineSignature = ""
    private var cache: AISummaryCache?
    private var fingerprints: [String: AiSummaryFingerprintRecord] = [:]
    private var preparedPlans: [String: AiPlanRecord] = [:]
    private var handles: [String: any AIChatHandle] = [:]
    private var answers: [String: String] = [:]
    private var queue: [String] = []
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var epoch = 0
    private var concurrency = 1

    public init(settings: AISettingsStore = .shared, audit: AIAuditTrail = .shared) {
        self.settings = settings
        self.audit = audit
        self.bounds = aiSummaryLimits()
    }

    /// Host the current configuration would contact. The audit stores only the host.
    private var auditHost: String {
        if settings.connectionMode == .chatGPT { return "api.openai.com" }
        return settings.endpointInfo?.host ?? ""
    }

    private var auditModel: String {
        if settings.connectionMode == .chatGPT {
            return settings.chatGPT.selected?.model ?? ""
        }
        return settings.model
    }

    private var auditBaseURL: String {
        settings.connectionMode == .chatGPT ? "https://api.openai.com/v1" : settings.baseURL
    }

    /// A lazy-summary refusal never reaches a transport. One zero-count entry records the
    /// Generate attempt; the batch itself is not several requests until Send starts them.
    private func recordRefusal(_ code: AIAuditCode, startedAt: Date) {
        audit.refuse(kind: .summaryLayer, host: auditHost, model: auditModel,
                     code: code, startedAt: startedAt)
    }

    public var isGenerating: Bool { phase == .generating }
    public var isBusy: Bool {
        phase == .generating || phase == .preview || isPreparing || isRefreshing
    }
    public var hasPreview: Bool { preview != nil }

    public var documentLanguageLabel: String { "Document language" }
    public var languageLabel: String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? documentLanguageLabel : trimmed
    }

    /// "8 sections · pages 1-3 of 3", "3 pages", "pages 1 of 20". The layer header states how
    /// many pages the layer covers.
    public func coverageLabel(for layer: AISummaryLayer) -> String {
        let rows = entries(for: layer)
        switch layer {
        case .abstract:
            let pages = rows.first?.pages.count ?? 0
            let bound = pages > 0
                ? pages
                : min(Int(bounds.abstractMaxPages), pageCount)
            return pageCount > 0 ? "\(bound) of \(pageCount) pages" : "No pages"
        case .sections:
            guard let first = rows.first, let last = rows.last else { return "No sections" }
            let pages = "pages \(first.pageStart)-\(last.pageEnd) of \(pageCount)"
            return "\(rows.count) section\(rows.count == 1 ? "" : "s") · \(pages)"
        case .pages:
            return "\(rows.count) page\(rows.count == 1 ? "" : "s") of \(pageCount)"
        }
    }

    public func entries(for layer: AISummaryLayer) -> [AISummaryEntry] {
        entries.filter { $0.kind == layer }
    }

    public func entry(id: String) -> AISummaryEntry? {
        entries.first { $0.id == id }
    }

    /// Attach the window's service, document and outline. Re-attaching the same document is a
    /// no-op until the outline or language changes, so panel toggles do not re-read anything.
    public func attach(
        service: (any AIChatServicing)?,
        context: AIReaderContext?,
        outline: [OutlineEntry]? = nil,
        documentURL: URL? = nil
    ) {
        self.service = service
        let key = context?.documentKey
        let newOutline = outline ?? self.outline
        let signature = Self.outlineSignature(newOutline)
        let sameDocument = documentKey == key
        self.context = context
        if sameDocument {
            let outlineChanged = signature != outlineSignature
            if outlineChanged || entries.isEmpty {
                epoch += 1
                self.outline = newOutline
                outlineSignature = signature
                rebuildEntries()
                scheduleRefresh()
            } else if let url = documentURL, self.documentURL != url {
                epoch += 1
                self.documentURL = url
                cache = AISummaryCache(documentURL: url)
                cacheURL = cache?.fileURL
                scheduleRefresh()
            }
            return
        }
        cancelWork()
        documentKey = key
        pageCount = context?.pageCount ?? 0
        documentTitle = context?.documentTitle ?? ""
        self.outline = newOutline
        outlineSignature = signature
        self.documentURL = documentURL
        epoch += 1
        entries = []
        preview = nil
        previewLayer = nil
        generationLayer = nil
        preparedPlans = [:]
        fingerprints = [:]
        if let key, let url = documentURL {
            cache = AISummaryCache(documentURL: url)
            cacheURL = cache?.fileURL
            cacheError = cache?.lastError
            _ = key
        } else {
            cache = nil
            cacheURL = nil
        }
        rebuildEntries()
        phase = .idle
        statusNote = nil
        errorMessage = nil
        scheduleRefresh()
    }

    /// Commit a new summary language. Deferred until Apply so typing a language does not re-read
    /// the document on every keystroke. The panel then shows cached rows for that language; a
    /// language with no cache is `notGenerated`, never another language's text.
    public func setLanguage(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != language else { return }
        cancelWork()
        language = trimmed
        epoch += 1
        preview = nil
        previewLayer = nil
        preparedPlans = [:]
        phase = .idle
        statusNote = "Language changed to \(languageLabel); cached rows for that language are shown. Nothing is sent until you press Generate and Send."
        scheduleRefresh()
    }

    /// The provider model changed. Cached rows were keyed by the old model, so re-inspect the
    /// coverage and let the cache decide: rows from another model are never shown as current.
    public func settingsDidChange() {
        guard phase != .generating else { return }
        cancelWork()
        epoch += 1
        preview = nil
        previewLayer = nil
        preparedPlans = [:]
        phase = .idle
        statusNote = "The model changed; rows are matched against the new model's cache. Nothing was sent."
        scheduleRefresh()
    }

    /// Inspect every layer locally and fill rows from the cache. No request is started.
    public func refresh() async {
        guard let service, let context, context.documentKey == documentKey else { return }
        guard pageCount > 0 else { return }
        isRefreshing = true
        let currentEpoch = epoch
        let model = currentModel
        let languageKey = cacheLanguage
        var firstError: String?
        for layer in AISummaryLayer.allCases {
            let rows = entries(for: layer)
            guard !rows.isEmpty else { continue }
            do {
                let request = request(layer: layer, entries: rows, model: model)
                let result = try await service.inspectSummary(request)
                guard currentEpoch == epoch else { return }
                apply(fingerprints: result, layer: layer, model: model, language: languageKey)
            } catch {
                guard currentEpoch == epoch else { return }
                if firstError == nil { firstError = AIReadableError.message(error) }
            }
        }
        guard currentEpoch == epoch else { return }
        isRefreshing = false
        cacheError = cache?.lastError
        if let firstError {
            errorMessage = firstError
            statusNote = "The summary coverage could not be read: \(firstError)"
        } else if phase == .idle {
            let ready = entries.filter(\.state.isReady).count
            let stale = entries.filter { $0.state == .stale }.count
            if ready + stale > 0 {
                statusNote = "\(ready) cached summar\(ready == 1 ? "y" : "ies") shown"
                    + (stale > 0 ? "; \(stale) changed since it was cached." : ". Nothing was sent.")
            }
        }
    }

    /// Build the preview for one layer. The request list is bounded; if the layer has more
    /// not-ready rows, only the first batch is previewed and the note says how many remain.
    public func prepare(_ layer: AISummaryLayer) async {
        await prepare(layer: layer, only: nil)
    }

    private func prepare(layer: AISummaryLayer, only ids: Set<String>?) async {
        guard phase != .generating, !isPreparing else { return }
        let auditStart = Date()
        guard let service, let context, context.documentKey == documentKey else {
            recordRefusal(.notConfigured, startedAt: auditStart)
            phase = .failed
            errorMessage = AIAssistantModel.noEngineMessage
            statusNote = errorMessage
            return
        }
        guard pageCount > 0 else {
            recordRefusal(.emptyContext, startedAt: auditStart)
            phase = .failed
            errorMessage = "This document has no pages."
            statusNote = errorMessage
            return
        }
        guard settings.canUseAI else {
            recordRefusal(settings.connectionMode == .chatGPT ? .signedOut : .noApiKey,
                          startedAt: auditStart)
            phase = .failed
            errorMessage = settings.connectionMode == .chatGPT
                ? "Sign in with ChatGPT in Settings > AI first. Nothing was sent."
                : AIAssistantModel.noKeyMessage
            statusNote = errorMessage
            return
        }
        let provider: AIProviderSettings
        do { provider = try settings.providerSettings() }
        catch {
            recordRefusal(AIAuditCode.classifyPreparationFailure(error, baseURL: auditBaseURL),
                          startedAt: auditStart)
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
            return
        }
        let candidates = entries(for: layer).filter { entry in
            if let ids { return ids.contains(entry.id) }
            return !entry.state.isReady
        }
        guard !candidates.isEmpty else {
            statusNote = "Everything in this layer is cached. Nothing was sent."
            return
        }
        let limit = Int(bounds.maxRequestsPerBatch)
        let batch = Array(candidates.prefix(limit))
        let skipped = candidates.count - batch.count
        isPreparing = true
        phase = .refreshing
        errorMessage = nil
        cancelPolling()
        let currentEpoch = epoch
        do {
            let request = request(layer: layer, entries: batch, model: provider.model)
            var plan = try await service.prepareSummary(request)
            guard currentEpoch == epoch else { return }
            // Each unit is materialised once for the selected connection. The layer envelope
            // (units, bounds, note) is unchanged.
            let converted = try plan.units.map { unit -> AiSummaryUnitRecord in
                var copy = unit
                if let source = unit.plan {
                    copy.plan = try AIPlanWire.render(source, connection: settings.connectionMode)
                }
                return copy
            }
            plan = AiSummaryPlanRecord(
                layer: plan.layer,
                pageCount: plan.pageCount,
                units: converted,
                note: plan.note,
                maxRequestsPerBatch: plan.maxRequestsPerBatch,
                maxConcurrentRequests: plan.maxConcurrentRequests
            )
            var note = plan.note
            if skipped > 0 {
                note += " \(skipped) more \(skipped == 1 ? "entry stays" : "entries stay") for the next batch."
            }
            preview = plan
            previewLayer = layer
            preparedPlans = [:]
            batchRequests = 0
            for unit in plan.units {
                let id = entryID(layer: layer, index: Int(unit.index))
                if let unitPlan = unit.plan {
                    preparedPlans[id] = unitPlan
                    batchRequests += 1
                }
                apply(unit: unit, id: id, layer: layer)
            }
            if batchRequests == 0 {
                recordRefusal(.emptyContext, startedAt: auditStart)
                phase = .failed
                errorMessage = "None of these entries has extractable text, so there is nothing to send."
                statusNote = errorMessage
            } else {
                phase = .preview
                statusNote = "Nothing has been sent yet. Review the \(batchRequests) request\(batchRequests == 1 ? "" : "s") below, then press Send."
            }
            if !note.isEmpty { statusNote = (statusNote ?? "") + " " + note }
        } catch {
            guard currentEpoch == epoch else { return }
            recordRefusal(AIAuditCode.classifyPreparationFailure(error, baseURL: auditBaseURL),
                          startedAt: auditStart)
            phase = .failed
            errorMessage = AIReadableError.message(error)
            statusNote = errorMessage
        }
        isPreparing = false
    }

    /// Start the previewed batch. The key (or ChatGPT account) is read here, per request, and
    /// never retained by this model.
    public func send() {
        guard phase == .preview, let preview, let layer = previewLayer else { return }
        let auditStart = Date()
        guard settings.canUseAI else {
            recordRefusal(settings.connectionMode == .chatGPT ? .signedOut : .noApiKey,
                          startedAt: auditStart)
            phase = .failed
            errorMessage = AIAssistantModel.noKeyMessage
            statusNote = errorMessage
            return
        }
        let requestUnits = preview.units.filter { $0.plan != nil }
        guard !requestUnits.isEmpty else { return }
        generationLayer = layer
        phase = .generating
        errorMessage = nil
        answers = [:]
        handles = [:]
        queue = []
        finishedRequests = 0
        activeRequests = 0
        batchRequests = requestUnits.count
        concurrency = max(1, Int(preview.maxConcurrentRequests))
        for unit in preview.units {
            let id = entryID(layer: layer, index: Int(unit.index))
            if unit.plan == nil {
                updateEntry(id) {
                    $0.state = .failed(unit.error ?? "This entry has no extractable text.")
                    $0.error = unit.error ?? "This entry has no extractable text."
                }
            } else {
                queue.append(id)
            }
        }
        statusNote = "Generating \(requestUnits.count) request\(requestUnits.count == 1 ? "" : "s") with at most \(concurrency) in flight."
        startQueued()
        startPumping()
    }

    public func cancel() {
        guard phase == .generating else { return }
        for (id, handle) in handles {
            handle.cancel()
            updateEntry(id) { entry in
                entry.state = .cancelled
                entry.error = "Cancelled. The completed rows are kept."
            }
        }
        handles.removeAll()
        for id in queue {
            updateEntry(id) { $0.state = .notGenerated }
        }
        queue.removeAll()
        pollTask?.cancel()
        pollTask = nil
        activeRequests = 0
        phase = .cancelled
        generationLayer = nil
        statusNote = "Cancelled. \(entries.filter(\.state.isReady).count) completed summar\(entries.filter(\.state.isReady).count == 1 ? "y is" : "ies are") kept and cached."
    }

    /// Retry one failed or cancelled row. Its already-previewed request is re-sent, exactly like
    /// the panel's existing Retry; if no preview survives, a one-row preview is built first.
    public func retry(_ id: String) {
        guard phase != .generating, !isPreparing, !isRefreshing else { return }
        guard let entry = entry(id: id), entry.state.needsRetry else { return }
        if preparedPlans[id] != nil {
            generationLayer = entry.kind
            phase = .generating
            errorMessage = nil
            updateEntry(id) { $0.failure = nil }
            answers[id] = ""
            handles = [:]
            queue = [id]
            finishedRequests = 0
            activeRequests = 0
            batchRequests = 1
            concurrency = max(1, Int(bounds.maxConcurrentRequests))
            statusNote = "Retrying “\(entry.title)”."
            startQueued()
            startPumping()
        } else {
            Task { await prepare(layer: entry.kind, only: [id]) }
        }
    }

    public func discardPreview() {
        guard phase == .preview else { return }
        cancelPolling()
        preview = nil
        previewLayer = nil
        preparedPlans = [:]
        phase = .idle
        statusNote = "Preview discarded. Nothing was sent; cached summaries are kept."
    }

    public func clearError() {
        errorMessage = nil
    }

    // MARK: - Rows

    private static func outlineSignature(_ outline: [OutlineEntry]) -> String {
        outline.map { "\($0.depth)|\($0.page ?? -1)|\($0.title)|\($0.bookmarkID ?? "")" }
            .joined(separator: "\u{1F}")
    }

    private func rebuildEntries() {
        guard pageCount > 0 else {
            entries = []
            return
        }
        var next: [AISummaryEntry] = []
        next.append(AISummaryEntry(
            id: "abstract",
            kind: .abstract,
            unitIndex: 0,
            title: "Abstract",
            number: nil,
            depth: 0,
            pageStart: 1,
            pageEnd: pageCount,
            linkPage: 0
        ))
        for (index, section) in AISummarySections
            .sections(outline: outline, pageCount: pageCount)
            .enumerated()
        {
            next.append(AISummaryEntry(
                id: "section:\(index)",
                kind: .sections,
                unitIndex: index,
                title: section.title,
                number: section.number.isEmpty ? nil : section.number,
                depth: section.depth,
                pageStart: section.pageStart,
                pageEnd: section.pageEnd,
                linkPage: section.linkPage
            ))
        }
        for index in 0..<pageCount {
            next.append(AISummaryEntry(
                id: "page:\(index + 1)",
                kind: .pages,
                unitIndex: index,
                title: LyraReaderBindings.pageLabel(pages: [UInt32(max(0, index + 1))]),
                number: nil,
                depth: 0,
                pageStart: index + 1,
                pageEnd: index + 1,
                linkPage: index
            ))
        }
        entries = next
    }

    private func entryID(layer: AISummaryLayer, index: Int) -> String {
        switch layer {
        case .abstract: return "abstract"
        case .sections: return "section:\(index)"
        case .pages: return "page:\(index + 1)"
        }
    }

    private func updateEntry(_ id: String, _ body: (inout AISummaryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        body(&entries[index])
    }

    // MARK: - Coverage and cache

    private var currentModel: String {
        (try? settings.providerSettings())?.model ?? settings.model
    }

    private var cacheLanguage: String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "document" : trimmed
    }

    private func request(
        layer: AISummaryLayer,
        entries rows: [AISummaryEntry],
        model: String
    ) -> AiSummaryRequestRecord {
        AiSummaryRequestRecord(
            layer: layer.record,
            units: rows.map { entry in
                AiSummaryUnitRequestRecord(
                    kind: layer.record,
                    index: UInt32(max(0, entry.unitIndex)),
                    title: entry.kind == .abstract ? "Abstract" : entry.title,
                    number: entry.number,
                    depth: UInt32(max(0, entry.depth)),
                    pageStart: UInt32(max(0, entry.pageStart)),
                    pageEnd: UInt32(max(0, entry.pageEnd))
                )
            },
            language: language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : language.trimmingCharacters(in: .whitespacesAndNewlines),
            documentTitle: documentTitle,
            baseUrl: settings.baseURL,
            model: model,
            temperature: settings.temperature,
            maxTokens: UInt32(max(0, settings.maxTokens)),
            reasoningMode: settings.reasoningMode.rawValue,
            reasoningEncoding: settings.reasoningEncoding.rawValue,
            documentKnowledgeText: nil,
            documentKnowledgePages: []
        )
    }

    private func apply(
        fingerprints result: [AiSummaryFingerprintRecord],
        layer: AISummaryLayer,
        model: String,
        language languageKey: String
    ) {
        // A refresh that started before Send must not overwrite the batch's live states when
        // it returns: the rows' progress and errors belong to the running generation.
        if phase == .generating || isPreparing { return }
        for fingerprint in result {
            let id = entryID(layer: layer, index: Int(fingerprint.index))
            guard entries.contains(where: { $0.id == id }) else { continue }
            fingerprints[id] = fingerprint
            let hash = fingerprint.textHash
            let coveredEnd = Int(fingerprint.coveredPageEnd)
            let pages = fingerprint.pages.map(Int.init)
            updateEntry(id) { entry in
                entry.coveredPageEnd = coveredEnd
                entry.truncated = fingerprint.truncated
                entry.pages = pages
                entry.charactersSent = fingerprint.characters
                guard !hash.isEmpty, entry.state != .generating else { return }
                // Same text, model and language already on screen: keep it rather than
                // re-reading the cache. A language switch must miss here.
                if entry.textHash == hash, entry.state.isReady, !entry.summary.isEmpty,
                   entry.summaryLanguage == languageKey, entry.summaryModel == model {
                    return
                }
                entry.textHash = hash
                // The builder owns the coverage sentence: speak with one authority for fresh
                // previews and for rows rebuilt from the cache.
                entry.note = fingerprint.note
                if let cached = cache?.summary(
                    layer: layer,
                    unit: id,
                    model: model,
                    language: languageKey,
                    textHash: hash
                ) {
                    entry.summary = cached
                    entry.summaryModel = model
                    entry.summaryLanguage = languageKey
                    entry.state = .ready
                    entry.error = nil
                } else if let stale = cache?.staleEntry(
                    layer: layer,
                    unit: id,
                    model: model,
                    language: languageKey
                ) {
                    entry.summary = stale.summary
                    entry.state = .stale
                    entry.note = "Cached from an older version of this text; regenerate it to update the summary."
                } else {
                    if entry.state == .ready || entry.state == .stale {
                        entry.summary = ""
                    }
                    entry.state = .notGenerated
                }
            }
        }
        cacheError = cache?.lastError
    }

    private func apply(unit: AiSummaryUnitRecord, id: String, layer: AISummaryLayer) {
        fingerprints[id] = AiSummaryFingerprintRecord(
            index: unit.index,
            kind: unit.kind,
            requestedPageStart: unit.pageStart,
            requestedPageEnd: unit.pageEnd,
            coveredPageStart: UInt32(max(0, Int(unit.pageStart))),
            coveredPageEnd: unit.coveredPageEnd,
            pages: unit.pages,
            truncated: unit.truncated,
            textHash: unit.textHash,
            characters: unit.characters,
            note: unit.note
        )
        updateEntry(id) { entry in
            entry.note = unit.note
            entry.coveredPageEnd = Int(unit.coveredPageEnd)
            entry.truncated = unit.truncated
            entry.pages = unit.pages.map(Int.init)
            entry.textHash = unit.textHash
            entry.charactersSent = unit.characters
            if unit.plan == nil {
                entry.state = .failed(unit.error ?? "No request can be sent for this entry.")
                entry.error = unit.error ?? "No request can be sent for this entry."
            }
        }
    }

    private func storeCache(for id: String, plan: AiPlanRecord, summary: String) {
        guard let cache, let entry = entry(id: id) else { return }
        cache.store(
            layer: entry.kind,
            unit: id,
            model: plan.model,
            language: cacheLanguage,
            textHash: entry.textHash,
            title: entry.title,
            pageStart: entry.pageStart,
            pageEnd: entry.pageEnd,
            summary: summary
        )
        cacheError = cache.lastError
    }

    // MARK: - Generation

    private func startQueued() {
        while handles.count < concurrency, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let plan = preparedPlans[id] else {
                updateEntry(id) { $0.state = .failed("The previewed request is missing; retry this row.") }
                continue
            }
            updateEntry(id) { entry in
                entry.state = .generating
                entry.summary = ""
                entry.error = nil
            }
            answers[id] = ""
            do {
                handles[id] = try startUnit(plan)
                activeRequests = handles.count
            } catch {
                updateEntry(id) {
                    $0.state = .failed(AIReadableError.message(error))
                    $0.error = AIReadableError.message(error)
                }
                activeRequests = handles.count
            }
        }
    }

    /// Start one previewed unit. Each unit is one outgoing request, so each gets its own audit
    /// attempt and exactly one record when it starts and ends. A failed start is recorded as a
    /// refusal, not silently dropped from the batch.
    private func startUnit(_ plan: AiPlanRecord) throws -> any AIChatHandle {
        let attempt = audit.begin(plan: plan, kind: .summaryLayer)
        do {
            guard let service else {
                throw AISettingsError.refused(AIAssistantModel.noEngineMessage, .notConfigured)
            }
            let handle: any AIChatHandle
            if settings.connectionMode == .chatGPT {
                guard let account = settings.chatGPT.selected, account.connected else {
                    throw AISettingsError.refused(
                        "Connect ChatGPT in Settings > AI first. Nothing was sent.", .signedOut)
                }
                handle = ChatGPTResponsesHandle(
                    plan: plan,
                    accounts: settings.chatGPT,
                    accountID: account.id
                )
            } else {
                guard let key = try settings.readKey() else {
                    throw AISettingsError.refused(AIAssistantModel.noKeyMessage, .noApiKey)
                }
                handle = try service.start(plan, apiKey: key)
            }
            return AIAuditedChatHandle(base: handle, attempt: attempt)
        } catch {
            attempt.finish(.refused, code: AIAuditCode.classifyStartFailure(error))
            throw error
        }
    }

    private func startPumping() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.phase == .generating {
                self.pollOnce()
                if self.handles.isEmpty && self.queue.isEmpty {
                    self.finishGeneration()
                    return
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    private func pollOnce() {
        let inFlight = Array(handles.keys)
        for id in inFlight {
            guard let handle = handles[id] else { continue }
            var terminal = false
            for event in handle.poll() {
                switch event {
                case .partStarted:
                    break
                case .delta(let text):
                    answers[id, default: ""] += text
                    updateEntry(id) { entry in
                        entry.state = .generating
                        entry.summary = answers[id] ?? ""
                    }
                case .reasoningDelta:
                    break
                case .usage, .diagnostics:
                    break
                case .done:
                    complete(id)
                    terminal = true
                case .error(let message, let cancelled, let failure, _):
                    if cancelled {
                        updateEntry(id) {
                            $0.state = .cancelled
                            $0.error = "Cancelled. The completed rows are kept."
                            $0.failure = nil
                        }
                        finishedRequests += 1
                    } else {
                        updateEntry(id) {
                            $0.state = .failed(message)
                            $0.error = message
                            $0.failure = failure
                        }
                        finishedRequests += 1
                    }
                    terminal = true
                }
                if terminal { break }
            }
            if terminal {
                handles.removeValue(forKey: id)
                activeRequests = handles.count
                continue
            }
            if handle.isFinished {
                let answer = (answers[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if answer.isEmpty {
                    updateEntry(id) {
                        $0.state = .failed("The provider finished without returning text.")
                        $0.error = "The provider finished without returning text."
                    }
                    finishedRequests += 1
                } else {
                    complete(id)
                }
                handles.removeValue(forKey: id)
                activeRequests = handles.count
            }
        }
        startQueued()
        if handles.isEmpty && queue.isEmpty {
            finishGeneration()
        }
    }

    private func complete(_ id: String) {
        let summary = (answers[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            updateEntry(id) {
                $0.state = .failed("The provider returned no text.")
                $0.error = "The provider returned no text."
            }
            finishedRequests += 1
            return
        }
        updateEntry(id) {
            $0.summary = summary
            $0.summaryModel = $0.summaryModel.isEmpty ? self.currentModel : $0.summaryModel
            $0.summaryLanguage = self.cacheLanguage
            $0.state = .ready
            $0.error = nil
            $0.failure = nil
        }
        if let plan = preparedPlans[id] {
            storeCache(for: id, plan: plan, summary: summary)
        }
        finishedRequests += 1
        statusNote = "Generating \(finishedRequests) of \(batchRequests)…"
    }

    private func finishGeneration() {
        guard phase == .generating else { return }
        pollTask?.cancel()
        pollTask = nil
        activeRequests = 0
        let ready = entries.filter { $0.state == .ready }.count
        let failed = entries.filter {
            if case .failed = $0.state { return true }
            return false
        }.count
        let cancelled = entries.filter { $0.state == .cancelled }.count
        phase = failed > 0 && ready == 0 ? .failed : .finished
        generationLayer = nil
        var note = "Batch finished: \(finishedRequests) of \(batchRequests) request\(batchRequests == 1 ? "" : "s") finished."
        note += " \(ready) row\(ready == 1 ? " is" : "s are") ready and cached."
        if failed > 0 { note += " \(failed) failed; retry each row." }
        if cancelled > 0 { note += " \(cancelled) cancelled." }
        let remaining = entries(for: previewLayer ?? .pages).filter { !$0.state.isReady && !$0.state.needsRetry }.count
        if remaining > 0 {
            note += " \(remaining) entr\(remaining == 1 ? "y" : "ies") remain; press Generate for the next batch."
        }
        statusNote = note
        if failed > 0 && ready == 0 {
            errorMessage = "Every request in this batch failed. See each row for the provider's message."
        }
    }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func cancelWork() {
        refreshTask?.cancel()
        refreshTask = nil
        cancelPolling()
        for (_, handle) in handles { handle.cancel() }
        handles.removeAll()
        queue.removeAll()
        activeRequests = 0
        if phase == .generating || phase == .preview {
            phase = .idle
        }
        isPreparing = false
        isRefreshing = false
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let currentEpoch = epoch
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh()
            guard currentEpoch == self.epoch else { return }
        }
    }
}

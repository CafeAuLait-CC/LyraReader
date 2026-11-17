import AppKit
import Foundation
import LyraReaderBindings
import SwiftUI

struct AIPreReadingPause: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One completed reading of the document. Source hashes invalidate it after any PDF change.
public struct AIDocumentKnowledgeRecord: Equatable, Sendable {
    public let version: Int
    public let sourceHash: String
    public let summary: String
    public let pages: [Int]
    public let model: String
    public let readAt: Date
}

/// Optional shared context. Consent decides whether to start a background reading; AI actions
/// wait for this optional reading to finish; ordinary PDF reading remains available.
@MainActor
public final class AIDocumentKnowledge: ObservableObject {
    public enum Phase: String, Equatable { case idle, preparing, consent, reading, ready, failed }
    @Published public private(set) var phase: Phase = .idle
    @Published public var isPresented = false
    @Published public private(set) var record: AIDocumentKnowledgeRecord?
    @Published public private(set) var reader: AIAssistantModel?
    @Published public private(set) var message: String?
    @Published public private(set) var failureDetail: String?
    @Published public private(set) var statusVisible = false
    public var settings: AISettingsStore = .shared
    private let memory = LyraDocumentUnderstanding()
    let io = DispatchQueue(label: "lyra.ai.understanding.disk", qos: .utility)
    private var memorySource: String?
    private var analysisLease: UInt64?
    private var analysisLanguage = ""
    private var analysisDetail = "Standard"
    private var analysisResultID: String?
    private var pending: Task<String, Error>?
    private var background: Task<Void, Never>?
    private var backgroundID: UUID?
    private var backgroundLease: UInt64?
    private var approval: CheckedContinuation<Bool, Error>?
    private var epoch = UUID()
    private var sourceIdentity: String?
    private var allowsWithoutSummary = false
    private var retryAction: (() -> Void)?
    public var isBlocking: Bool { phase == .preparing || phase == .consent || phase == .reading }
    public init() {}

    public func ensure(service: any AIChatServicing, context: AIReaderContext,
                       sourceURL: URL, cacheDocumentURL: URL) async throws -> String {
        let sourceKey = DocumentEditCache.documentIdentity(for: sourceURL) ?? sourceURL.standardizedFileURL.path
        let cacheKey = DocumentEditCache.documentIdentity(for: cacheDocumentURL) ?? cacheDocumentURL.standardizedFileURL.path
        let identity = sourceKey + "|" + cacheKey
        if let sourceIdentity, sourceIdentity != identity { invalidate() }
        sourceIdentity = identity
        let gate = try aiReadingGate(policy: settings.prereadingPolicy,
            state: allowsWithoutSummary && record == nil && background == nil ? "skipped" : phase.rawValue, hasCache: false)
        if gate == "wait" { throw AIPreReadingPause(message: "Document prereading is in progress. Continue when Lyra AI is ready.") }
        if phase == .failed { throw AIPreReadingPause(message: "Prereading paused. Retry or choose Continue Without Reading.") }
        if let pending { return try await pending.value }
        if allowsWithoutSummary && record == nil { phase = .idle; return "" }
        let token = epoch
        retryAction = { [weak self] in
            Task { @MainActor [weak self] in
                do { _ = try await self?.ensure(service: service, context: context, sourceURL: sourceURL, cacheDocumentURL: cacheDocumentURL) }
                catch is AIPreReadingPause { /* The shared status already explains the gate. */ }
                catch is CancellationError { /* Leaving the document cancels the retry. */ }
                catch { self?.failureDetail = AIReadableError.message(error) }
            }
        }
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            self.phase = .preparing
            let (hash, file) = try await self.loadMemory(sourceURL: sourceURL, cacheDocumentURL: cacheDocumentURL)
            try Task.checkCancellation()
            guard self.epoch == token else { throw CancellationError() }
            if let cached = try self.memory.record(source: hash) {
                self.publish(cached); self.phase = .ready
                return cached.content
            }
            if gate == "ready" || self.allowsWithoutSummary { self.phase = .idle; return "" }
            self.record = nil
            let model = AIAssistantModel(settings: self.settings)
            model.attach(service: service, context: context)
            self.reader = model
            self.analysisLanguage = self.settings.outputLanguage; self.analysisDetail = "Standard"
            self.analysisResultID = nil
            await model.prepare(action: .summarizeDocument, context: context, documentKnowledge: true,
                                reading: AiReadingOptionsRecord(kind: "summary", detail: "Standard"), outputLanguage: self.analysisLanguage)
            try Task.checkCancellation()
            guard self.epoch == token else { throw CancellationError() }
            self.phase = .consent
            self.message = model.errorMessage
            self.isPresented = gate == "ask"
            let startReading: Bool
            if gate == "read" { startReading = true }
            else {
                startReading = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Bool, Error>) in self.approval = continuation
                }
            }
            try Task.checkCancellation()
            guard self.epoch == token else { throw CancellationError() }
            self.isPresented = false
            self.allowsWithoutSummary = !startReading
            if startReading, let plan = model.plan, model.phase == .preview {
                self.startBackground(model: model, plan: plan, sourceURL: sourceURL,
                                     file: file, hash: hash, token: token)
                throw AIPreReadingPause(message: "Document prereading has started. Continue when Lyra AI is ready.")
            } else {
                self.phase = .idle
                self.message = nil
            }
            // The action that opened this choice keeps going; it never waits for provider I/O.
            return ""
        }
        pending = task
        defer { if epoch == token { pending = nil } }
        do { return try await task.value }
        catch let pause as AIPreReadingPause { throw pause }
        catch {
            if epoch == token && !(error is CancellationError) {
                phase = .failed; statusVisible = true
                message = "Document reading paused. You can keep using Lyra without it."
                failureDetail = AIReadableError.message(error)
            }
            throw error
        }
    }

    private static func hash(_ url: URL) async throws -> String {
        // Reuse the Rust identity shared by tabs and caches: canonical path plus content hash.
        try await Task.detached(priority: .utility) { try documentIdForPath(path: url.path) }.value
    }

    private func startBackground(model: AIAssistantModel, plan: AiPlanRecord, sourceURL: URL,
                                 file: URL, hash: String, token: UUID) {
        let job = UUID(); backgroundID = job
        backgroundLease = analysisLease
        phase = .reading; message = nil; failureDetail = nil; statusVisible = true
        background = Task { @MainActor [weak self] in
            guard let self else { return }
            var ownedLease = self.analysisLease
            defer {
                if let lease = ownedLease {
                    do { try self.memory.cancel(token: lease) }
                    catch { if self.epoch == token && self.backgroundID == job { self.failureDetail = AIReadableError.message(error) } }
                    if self.analysisLease == lease { self.analysisLease = nil }
                }
                if self.epoch == token && self.backgroundID == job {
                    self.background = nil
                    self.backgroundID = nil
                    self.backgroundLease = nil
                }
            }
            if self.settings.reviewBeforeSending {
                let approved = await AIReadingReviewWindow.review(plan)
                guard self.epoch == token else { return }
                guard approved else {
                    self.phase = .idle; self.message = "Prereading cancelled. Choose whether to preread when you use AI again."
                    return
                }
            }
            guard self.epoch == token, !Task.isCancelled else { return }
            do {
                if self.analysisLease == nil {
                    switch try self.memory.begin(source: hash, language: self.analysisLanguage, detail: self.analysisDetail, force: false) {
                    case let .start(lease): self.analysisLease = lease
                    case .ready:
                        guard let cached = try self.memory.record(source: hash) else { throw AISettingsError.invalid(aiReadingLabel("The document analysis could not start. Please try again.")) }
                        self.publish(cached); self.phase = .ready; return
                    case .waiting: throw AIPreReadingPause(message: aiReadingLabel("Document analysis is already in progress."))
                    }
                }
            } catch { self.phase = .failed; self.failureDetail = AIReadableError.message(error); return }
            ownedLease = self.analysisLease; self.backgroundLease = ownedLease
            model.send()
            do {
                while true {
                    try Task.checkCancellation()
                    guard self.epoch == token else { throw CancellationError() }
                    if model.phase == .mergePreview, model.mergePlan != nil {
                        model.sendMerge()
                    }
                    if model.phase.isTerminal { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard model.phase == .finished, (plan.parts.count <= 1 || model.completedDocumentSynthesis), model.errorMessage == nil, model.finishReason != "length", !model.hasTruncatedSource,
                      !model.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AISettingsError.invalid(model.errorMessage ?? "The document reading did not finish.")
                }
                let completedHash = try await Self.hash(sourceURL)
                try Task.checkCancellation()
                guard self.epoch == token else { throw CancellationError() }
                guard completedHash == hash else {
                    throw AISettingsError.invalid("The PDF changed while it was being read. Start again with the current PDF.")
                }
                var completed = AiReadingRecord.make(id: self.analysisResultID ?? UUID().uuidString, kind: "summary", content: model.answer, sourceID: "document",
                    pages: plan.sourcePages, language: self.analysisLanguage, detail: self.analysisDetail)
                completed.model = plan.model; completed.sourceHash = hash
                completed.originals = plan.sources.map(\.snippet); completed.originalPages = plan.sources.map(\.page)
                guard let lease = self.analysisLease, try self.memory.finish(token: lease, record: completed) else { throw CancellationError() }
                self.analysisLease = nil
                self.publish(completed)
                self.phase = .ready
                self.message = "Lyra AI is ready. You can continue using AI tools."
                Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    guard self?.epoch == token, self?.phase == .ready else { return }
                    self?.statusVisible = false
                }
                do { try await self.persist(to: file) }
                catch {
                    guard self.epoch == token, self.backgroundID == job else { return }
                    self.message = "Document reading is ready, but could not be saved for next time."; self.failureDetail = AIReadableError.message(error)
                }
            } catch is CancellationError {
                guard self.epoch == token else { return }
                self.phase = .idle
                self.message = "Document reading stopped. You can keep using Lyra without it."
            } catch {
                guard self.epoch == token else { return }
                self.phase = .failed
                self.message = "Document reading paused. You can keep using Lyra without it."
                self.failureDetail = AIReadableError.message(error)
            }
        }
    }

    private func publish(_ snapshot: AiReadingRecord) {
        record = AIDocumentKnowledgeRecord(version: 2, sourceHash: snapshot.sourceHash, summary: snapshot.content,
            pages: snapshot.pages.map(Int.init), model: snapshot.model,
            readAt: Date(timeIntervalSince1970: Double(snapshot.modified) / 1000))
        phase = .ready
    }

    private func loadMemory(sourceURL: URL, cacheDocumentURL: URL) async throws -> (String, URL) {
        let sourceKey = DocumentEditCache.documentIdentity(for: sourceURL) ?? sourceURL.standardizedFileURL.path
        let cacheKey = DocumentEditCache.documentIdentity(for: cacheDocumentURL) ?? cacheDocumentURL.standardizedFileURL.path
        let identity = sourceKey + "|" + cacheKey
        if let sourceIdentity, sourceIdentity != identity { invalidate() }
        sourceIdentity = identity
        let token = epoch
        let hash = try await Self.hash(sourceURL)
        try Task.checkCancellation()
        guard epoch == token else { throw CancellationError() }
        let file = DocumentEditCache.directory(for: cacheDocumentURL).appendingPathComponent("document-understanding-v2.json")
        if memorySource != hash {
            record = nil
            let memory = self.memory
            try await Task.detached(priority: .utility) {
                if FileManager.default.fileExists(atPath: file.path) {
                    guard let limit = Int(exactly: aiDocumentUnderstandingCacheLimit()) else {
                        throw AISettingsError.invalid(aiReadingLabel("The document understanding cache limit is unsupported."))
                    }
                    let handle = try FileHandle(forReadingFrom: file)
                    // Closing a read-only cache handle cannot invalidate successfully read data.
                    defer { try? handle.close() }
                    var bytes = Data()
                    while bytes.count <= limit {
                        guard let chunk = try handle.read(upToCount: min(64 * 1024, limit - bytes.count + 1)), !chunk.isEmpty else { break }
                        bytes.append(chunk)
                    }
                    guard bytes.count <= limit else { throw AISettingsError.invalid(aiReadingLabel("The saved document understanding is too large. Its file was kept.")) }
                    _ = try memory.load(bytes: bytes, source: hash)
                }
            }.value
            try Task.checkCancellation()
            guard epoch == token else { throw CancellationError() }
            memorySource = hash
        }
        return (hash, file)
    }

    private func persist(to file: URL) async throws {
        let memory = self.memory
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            io.async {
                do { try Data(memory.encode()).write(to: file, options: .atomic); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    func cachedSummary(sourceURL: URL, cacheDocumentURL: URL, language: String, detail: String) async throws -> AiReadingRecord? {
        let (hash, _) = try await loadMemory(sourceURL: sourceURL, cacheDocumentURL: cacheDocumentURL)
        if let cached = try memory.record(source: hash) { publish(cached) }
        return try memory.reusable(source: hash, language: language, detail: detail)
    }

    func prepareSummary(model: AIAssistantModel, sourceURL: URL, cacheDocumentURL: URL, language: String, detail: String, resultID: String, retry: @escaping () -> Void) async throws -> UInt64 {
        let (hash, _) = try await loadMemory(sourceURL: sourceURL, cacheDocumentURL: cacheDocumentURL)
        try Task.checkCancellation()
        // Another entry can acquire the shared choice while the fingerprint/cache I/O awaits.
        guard !isBlocking else { throw AIPreReadingPause(message: aiReadingLabel("Document analysis is already in progress.")) }
        switch try memory.begin(source: hash, language: language, detail: detail, force: true) {
        case let .start(lease): analysisLease = lease
        case .waiting: throw AIPreReadingPause(message: aiReadingLabel("Document analysis is already in progress."))
        case .ready: throw AISettingsError.invalid(aiReadingLabel("The document analysis could not start. Please try again."))
        }
        reader = model; analysisLanguage = language; analysisDetail = detail
        analysisResultID = resultID
        retryAction = retry
        phase = .preparing; failureDetail = nil
        guard let analysisLease else { throw AISettingsError.invalid(aiReadingLabel("The document analysis could not start. Please try again.")) }
        return analysisLease
    }

    func sendSummary(model: AIAssistantModel, sourceURL: URL, cacheDocumentURL: URL, lease: UInt64) {
        guard reader === model, analysisLease == lease, let plan = model.plan, let hash = memorySource else { return }
        let file = DocumentEditCache.directory(for: cacheDocumentURL).appendingPathComponent("document-understanding-v2.json")
        startBackground(model: model, plan: plan, sourceURL: sourceURL, file: file, hash: hash, token: epoch)
    }

    func cancelSummary(model: AIAssistantModel, lease: UInt64) {
        guard reader === model, analysisLease == lease, backgroundLease != lease else { return }
        releaseLease(); phase = record == nil ? .idle : .ready
    }

    private func releaseLease() {
        if let lease = analysisLease {
            do { try memory.cancel(token: lease) } catch { failureDetail = AIReadableError.message(error) }
            analysisLease = nil
        }
    }

    public func proceed() { approval?.resume(returning: true); approval = nil }
    public func continueWithoutSummary() {
        if let approval { approval.resume(returning: false); self.approval = nil }
        else { allowsWithoutSummary = true; phase = .idle; statusVisible = false; message = nil; failureDetail = nil }
    }
    public func dismissStatus() { statusVisible = false }
    public func retry() {
        guard background == nil else { return }
        phase = .idle
        allowsWithoutSummary = false; message = nil; failureDetail = nil; statusVisible = false
        retryAction?()
    }
    public func stopReading() {
        releaseLease()
        background?.cancel(); reader?.cancelRegionWork()
        pending?.cancel(); pending = nil
        epoch = UUID()
        background = nil; phase = .idle; allowsWithoutSummary = true
        backgroundID = nil
        backgroundLease = nil
        message = "Document reading stopped. You can keep using Lyra without it."
    }
    public func cancel() {
        releaseLease()
        approval?.resume(throwing: CancellationError()); approval = nil
        reader?.cancelRegionWork()
        pending?.cancel(); pending = nil
        background?.cancel(); background = nil
        backgroundID = nil
        backgroundLease = nil
        epoch = UUID(); phase = .idle; isPresented = false; statusVisible = false
        allowsWithoutSummary = false; retryAction = nil; message = nil; failureDetail = nil
    }
    public func invalidate() { cancel(); record = nil; memorySource = nil }
}

@MainActor
package final class DocumentKnowledgeService: AIChatServicing {
    let base: any AIChatServicing
    let knowledge: AIDocumentKnowledge
    let context: AIReaderContext
    let sourceURL: URL
    let cacheDocumentURL: URL
    package init(base: any AIChatServicing, knowledge: AIDocumentKnowledge, context: AIReaderContext,
         sourceURL: URL, cacheDocumentURL: URL) {
        self.base = base; self.knowledge = knowledge; self.context = context
        self.sourceURL = sourceURL; self.cacheDocumentURL = cacheDocumentURL
    }
    private func prior() async throws -> String {
        try await knowledge.ensure(service: base, context: context,
                                   sourceURL: sourceURL, cacheDocumentURL: cacheDocumentURL)
    }
    private func priorWithPages() async throws -> (text: String, pages: [Int]) {
        let summary = try await prior()
        return (aiDocumentUnderstandingContext(text: summary), knowledge.record?.pages ?? [])
    }
    package func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        let kind: String
        switch request.action {
        case .summarizeDocument, .summarizePage, .summarizeSelection: kind = "summary"
        case .translateSelection: kind = "translation"
        default: kind = "question"
        }
        if !aiNeedsDocumentUnderstanding(kind: kind) {
            guard !knowledge.isBlocking else { throw AIPreReadingPause(message: aiReadingLabel("Document analysis is already in progress.")) }
            return try await base.prepare(request)
        }
        let prior = try await priorWithPages()
        if prior.text.isEmpty { return try await base.prepare(request) }
        return try await base.prepare(
            request.withDocumentContext()
                .withDocumentKnowledge(prior.text, pages: prior.pages))
    }
    package func prepareReading(_ request: AIMakePlanRequest, options: AiReadingOptionsRecord) async throws -> AiPlanRecord {
        if !aiNeedsDocumentUnderstanding(kind: options.kind) {
            // The Summary lifecycle owns the active analysis lease. Other independent tasks
            // still respect an analysis already running in another entry point.
            if knowledge.isBlocking && (options.kind != "summary" || request.selection != nil) { throw AIPreReadingPause(message: aiReadingLabel("Document analysis is already in progress.")) }
            return try await base.prepareReading(request, options: options)
        }
        let prior = try await priorWithPages()
        let input = prior.text.isEmpty ? request : request.withDocumentKnowledge(prior.text, pages: prior.pages)
        return try await base.prepareReading(input, options: options)
    }
    package func prepareMerge(_ request: AIMergePlanRequest) async throws -> AiPlanRecord {
        // Consolidation already contains the analysis's source-bound part results. Looking up
        // the same in-flight analysis would wait on itself and duplicate generated context.
        try await base.prepareMerge(request)
    }
    package func inspectSummary(_ request: AiSummaryRequestRecord) async throws -> [AiSummaryFingerprintRecord] {
        try await base.inspectSummary(request)
    }
    package func prepareSummary(_ request: AiSummaryRequestRecord) async throws -> AiSummaryPlanRecord {
        guard !knowledge.isBlocking else { throw AIPreReadingPause(message: aiReadingLabel("Document analysis is already in progress.")) }
        return try await base.prepareSummary(request)
    }
    package func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        try base.start(plan, apiKey: apiKey)
    }
}

struct AIDocumentKnowledgeSheet: View {
    @ObservedObject var knowledge: AIDocumentKnowledge
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                LyraAIIcon(isActive: knowledge.phase == .reading || knowledge.phase == .preparing).frame(width: 32, height: 32)
                    .foregroundStyle(LyraReaderTheme.accent)
                Text(knowledge.phase == .reading ? "Prereading your document…" : "Get to know this document")
                    .font(.system(size: 18, weight: .semibold))
            }
            Text(aiReadingLabel("Lyra can read this document once to connect ideas across your questions, and save that understanding locally. You can keep reading the PDF while it works; AI tools become available when prereading finishes. You can also continue without it."))
                .font(.system(size: 13)).foregroundStyle(LyraReaderTheme.textSecondary)
            if let reader = knowledge.reader { AIDocumentKnowledgeProgress(reader: reader, reading: knowledge.phase == .reading) }
            if let message = knowledge.message {
                Text(message).font(.caption).foregroundStyle(LyraReaderTheme.warningFg).textSelection(.enabled)
            }
            HStack {
                Button("Continue Without Reading") { knowledge.continueWithoutSummary() }
                    .buttonStyle(ReaderPanelButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if knowledge.phase != .reading {
                    Button("Start prereading") { knowledge.proceed() }
                        .buttonStyle(ReaderPanelButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(knowledge.reader?.plan == nil || knowledge.reader?.phase != .preview)
                }
            }
        }.padding(24).frame(width: 460).foregroundStyle(LyraReaderTheme.textPrimary)
            .background(LyraReaderTheme.panelBg).interactiveDismissDisabled()
    }
}

/// A background task is visible without taking the document's pointer or keyboard focus.
struct AIDocumentKnowledgeStatus: View {
    @ObservedObject var knowledge: AIDocumentKnowledge
    var body: some View {
        if knowledge.statusVisible {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(aiReadingLabel(knowledge.phase == .reading ? "Reading your document…" : "Document reading"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if knowledge.phase != .reading { Button { knowledge.dismissStatus() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }.buttonStyle(.plain).help("Hide document reading status")
                        .accessibilityLabel("Hide document reading status")
                    }
                }
                if knowledge.phase == .reading, let reader = knowledge.reader {
                    AIPreReadingActivity(reader: reader)
                    HStack { Spacer(); Button { knowledge.stopReading() } label: {
                        Text(aiReadingLabel("Stop Reading")).padding(.horizontal, 12)
                    }.buttonStyle(ReaderPanelButtonStyle()).fixedSize(horizontal: true, vertical: false) }
                } else {
                    if let message = knowledge.message {
                        Text(message).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                    }
                    if let detail = knowledge.failureDetail {
                        DisclosureGroup("Details") { Text(detail).font(.caption).textSelection(.enabled) }
                            .font(.caption)
                    }
                    if knowledge.record == nil || knowledge.phase == .failed {
                        HStack {
                            Button("Retry prereading") { knowledge.retry() }
                            Button("Continue Without Reading") { knowledge.continueWithoutSummary() }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(14).frame(width: 320, alignment: .leading)
            .foregroundStyle(LyraReaderTheme.textPrimary)
            .background(RoundedRectangle(cornerRadius: 10).fill(LyraReaderTheme.panelBg)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(LyraReaderTheme.border))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 3))
        }
    }
}
struct AIPreReadingActivity: View {
    @ObservedObject var reader: AIAssistantModel
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(aiReadingLabel("Prereading in progress…")).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            Spacer(minLength: 0)
            if let plan = reader.plan, plan.parts.count > 1 {
                Text("\(reader.mergePlan == nil ? min(reader.currentRequestNumber ?? 1, plan.parts.count) : plan.parts.count)/\(plan.parts.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(LyraReaderTheme.textSecondary)
                    .accessibilityLabel(aiReadingLabel("Prereading progress"))
            }
        }
    }
}
private struct AIDocumentKnowledgeProgress: View {
    @ObservedObject var reader: AIAssistantModel
    let reading: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plan = reader.plan {
                Text("\(plan.pageCount) pages · \(plan.model)").font(.caption.weight(.medium))
                Text(plan.isLocal ? "Read using your local AI service." : "The document text will be sent to \(plan.host).")
                    .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                if plan.parts.count > 1 {
                    Text("Reads in \(plan.parts.count) parts, then combines the ideas.")
                        .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                }
                if reading {
                    ProgressView().controlSize(.small)
                    Text(reader.mergePlan != nil ? "Connecting the ideas…" : "Prereading is still in progress…")
                        .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                }
            }
        }
    }
}

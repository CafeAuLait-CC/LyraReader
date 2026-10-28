import AppKit
import CryptoKit
import Foundation
import LyraReaderBindings
import SwiftUI

/// One completed reading of the document. Source hashes invalidate it after any PDF change.
public struct AIDocumentKnowledgeRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let sourceHash: String
    public let summary: String
    public let pages: [Int]
    public let model: String
    public let readAt: Date
}

/// Optional shared context. Consent decides whether to start a background reading; AI actions
/// may proceed immediately with their own source passages while that reading is in progress.
@MainActor
public final class AIDocumentKnowledge: ObservableObject {
    public enum Phase: Equatable { case idle, preparing, consent, reading, ready, failed }
    @Published public private(set) var phase: Phase = .idle
    @Published public var isPresented = false
    @Published public private(set) var record: AIDocumentKnowledgeRecord?
    @Published public private(set) var reader: AIAssistantModel?
    @Published public private(set) var message: String?
    @Published public private(set) var failureDetail: String?
    @Published public private(set) var statusVisible = false
    public var settings: AISettingsStore = .shared
    private var pending: Task<String, Error>?
    private var background: Task<Void, Never>?
    private var approval: CheckedContinuation<Bool, Error>?
    private var epoch = UUID()
    private var sourceIdentity: String?
    private var allowsWithoutSummary = false
    private var retryAction: (() -> Void)?
    public init() {}

    public func ensure(service: any AIChatServicing, context: AIReaderContext,
                       sourceURL: URL, cacheDocumentURL: URL) async throws -> String {
        let sourceKey = DocumentEditCache.documentIdentity(for: sourceURL) ?? sourceURL.standardizedFileURL.path
        let cacheKey = DocumentEditCache.documentIdentity(for: cacheDocumentURL) ?? cacheDocumentURL.standardizedFileURL.path
        let identity = sourceKey + "|" + cacheKey
        if let sourceIdentity, sourceIdentity != identity { invalidate() }
        sourceIdentity = identity
        if let pending { return try await pending.value }
        if background != nil || (allowsWithoutSummary && record == nil) { return "" }
        let token = epoch
        let task = Task { @MainActor [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            self.phase = .preparing
            let hash = try await Self.hash(sourceURL)
            try Task.checkCancellation()
            guard self.epoch == token else { throw CancellationError() }
            if let record = self.record, record.sourceHash == hash {
                self.phase = .ready
                return record.summary
            }
            let file = DocumentEditCache.directory(for: cacheDocumentURL).appendingPathComponent("document-knowledge-v1.json")
            if let data = try? Data(contentsOf: file),
               let cached = try? JSONDecoder().decode(AIDocumentKnowledgeRecord.self, from: data),
               cached.version == 1, cached.sourceHash == hash, !cached.summary.isEmpty {
                self.record = cached; self.phase = .ready
                return cached.summary
            }
            self.record = nil
            let model = AIAssistantModel(settings: self.settings)
            model.attach(service: service, context: context)
            self.reader = model
            await model.prepare(action: .summarizeDocument, context: context, documentKnowledge: true)
            try Task.checkCancellation()
            guard self.epoch == token else { throw CancellationError() }
            self.phase = .consent
            self.message = model.errorMessage
            self.isPresented = true
            self.retryAction = { [weak self] in
                Task { @MainActor [weak self] in
                    _ = try? await self?.ensure(service: service, context: context,
                        sourceURL: sourceURL, cacheDocumentURL: cacheDocumentURL)
                }
            }
            let startReading = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Bool, Error>) in self.approval = continuation
            }
            try Task.checkCancellation()
            guard self.epoch == token else { throw CancellationError() }
            self.isPresented = false
            self.allowsWithoutSummary = true
            if startReading, let plan = model.plan, model.phase == .preview {
                self.startBackground(model: model, plan: plan, sourceURL: sourceURL,
                                     file: file, hash: hash, token: token)
            } else {
                self.phase = .idle
                self.message = nil
            }
            // The action that opened this choice keeps going; it never waits for provider I/O.
            return ""
        }
        pending = task
        defer { if epoch == token { pending = nil } }
        return try await task.value
    }

    private static func hash(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private func startBackground(model: AIAssistantModel, plan: AiPlanRecord, sourceURL: URL,
                                 file: URL, hash: String, token: UUID) {
        phase = .reading; message = nil; failureDetail = nil; statusVisible = true
        background = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.epoch == token { self.background = nil } }
            model.send()
            var consolidated = plan.parts.count <= 1
            do {
                while true {
                    try Task.checkCancellation()
                    guard self.epoch == token else { throw CancellationError() }
                    if model.phase == .mergePreview, model.mergePlan != nil {
                        consolidated = true
                        model.sendMerge()
                    }
                    if model.phase.isTerminal { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard model.phase == .finished, consolidated, model.errorMessage == nil,
                      !model.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AISettingsError.invalid(model.errorMessage ?? "The document reading did not finish.")
                }
                let completedHash = try await Self.hash(sourceURL)
                try Task.checkCancellation()
                guard self.epoch == token else { throw CancellationError() }
                guard completedHash == hash else {
                    throw AISettingsError.invalid("The PDF changed while it was being read. Start again with the current PDF.")
                }
                let record = AIDocumentKnowledgeRecord(version: 1, sourceHash: hash,
                    summary: model.answer, pages: plan.sourcePages.map(Int.init), model: plan.model, readAt: Date())
                self.record = record
                self.phase = .ready
                self.message = "Document reading is ready. New questions can use it."
                do { try JSONEncoder().encode(record).write(to: file, options: .atomic) }
                catch { self.message = "Document reading is ready, but could not be saved for next time." }
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

    public func proceed() { approval?.resume(returning: true); approval = nil }
    public func continueWithoutSummary() { approval?.resume(returning: false); approval = nil }
    public func dismissStatus() { statusVisible = false }
    public func retry() {
        guard background == nil else { return }
        allowsWithoutSummary = false; message = nil; failureDetail = nil; statusVisible = false
        retryAction?()
    }
    public func stopReading() {
        background?.cancel(); reader?.cancelRegionWork()
        pending?.cancel(); pending = nil
        epoch = UUID()
        background = nil; phase = .idle
        message = "Document reading stopped. You can keep using Lyra without it."
    }
    public func cancel() {
        approval?.resume(throwing: CancellationError()); approval = nil
        reader?.cancelRegionWork()
        pending?.cancel(); pending = nil
        background?.cancel(); background = nil
        epoch = UUID(); phase = .idle; isPresented = false; statusVisible = false
        allowsWithoutSummary = false; retryAction = nil; message = nil; failureDetail = nil
    }
    public func invalidate() { cancel(); record = nil }
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
        return (summary, knowledge.record?.pages ?? [])
    }
    package func prepare(_ request: AIMakePlanRequest) async throws -> AiPlanRecord {
        if request.action == .translateSelection { return try await base.prepare(request) }
        let prior = try await priorWithPages()
        if prior.text.isEmpty { return try await base.prepare(request) }
        return try await base.prepare(
            request.withDocumentContext()
                .withDocumentKnowledge(prior.text, pages: prior.pages))
    }
    package func prepareMerge(_ request: AIMergePlanRequest) async throws -> AiPlanRecord {
        let prior = try await priorWithPages()
        if prior.text.isEmpty { return try await base.prepareMerge(request) }
        return try await base.prepareMerge(
            request.withDocumentKnowledge(prior.text, pages: prior.pages))
    }
    package func inspectSummary(_ request: AiSummaryRequestRecord) async throws -> [AiSummaryFingerprintRecord] {
        try await base.inspectSummary(request)
    }
    package func prepareSummary(_ request: AiSummaryRequestRecord) async throws -> AiSummaryPlanRecord {
        let prior = try await priorWithPages()
        if prior.text.isEmpty { return try await base.prepareSummary(request) }
        return try await base.prepareSummary(
            request.withDocumentKnowledge(prior.text, pages: prior.pages))
    }
    package func start(_ plan: AiPlanRecord, apiKey: String) throws -> any AIChatHandle {
        try base.start(plan, apiKey: apiKey)
    }
}

private extension AiSummaryRequestRecord {
    func withDocumentKnowledge(_ text: String, pages: [Int]) -> AiSummaryRequestRecord {
        AiSummaryRequestRecord(
            layer: layer,
            units: units,
            language: language,
            documentTitle: documentTitle,
            baseUrl: baseUrl,
            model: model,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningMode: reasoningMode,
            reasoningEncoding: reasoningEncoding,
            documentKnowledgeText: text,
            documentKnowledgePages: pages.map { UInt32(max(0, $0)) }
        )
    }
}

struct AIDocumentKnowledgeSheet: View {
    @ObservedObject var knowledge: AIDocumentKnowledge
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                LyraAIIcon(isActive: knowledge.phase == .reading || knowledge.phase == .preparing).frame(width: 32, height: 32)
                    .foregroundStyle(LyraReaderTheme.accent)
                Text(knowledge.phase == .reading ? "Getting to know your document…" : "Get to know this document")
                    .font(.system(size: 18, weight: .semibold))
            }
            Text("Lyra can read this document once to connect ideas across your questions, and save that understanding locally. It works in the background while you read. You can also continue without it; answers may have less context about the whole document.")
                .font(.system(size: 13)).foregroundStyle(LyraReaderTheme.textSecondary)
            if let reader = knowledge.reader { AIDocumentKnowledgeProgress(reader: reader, reading: knowledge.phase == .reading) }
            if let message = knowledge.message {
                Text(message).font(.caption).foregroundStyle(LyraReaderTheme.warningFg).textSelection(.enabled)
            }
            HStack {
                Button("Continue Without Reading") { knowledge.continueWithoutSummary() }
                    .buttonStyle(ReaderPanelButtonStyle())
                if knowledge.phase != .reading {
                    Button("Read in Background") { knowledge.proceed() }
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
                    Text(knowledge.phase == .reading ? "Reading your document…" : "Document reading")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { knowledge.dismissStatus() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }.buttonStyle(.plain).help("Hide document reading status")
                        .accessibilityLabel("Hide document reading status")
                }
                if knowledge.phase == .reading, let reader = knowledge.reader {
                    AIDocumentKnowledgeProgress(reader: reader, reading: true)
                    Button("Stop Reading") { knowledge.stopReading() }.buttonStyle(.plain)
                } else {
                    if let message = knowledge.message {
                        Text(message).font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                    }
                    if let detail = knowledge.failureDetail {
                        DisclosureGroup("Details") { Text(detail).font(.caption).textSelection(.enabled) }
                            .font(.caption)
                    }
                    if knowledge.record == nil {
                        Button("Read Document…") { knowledge.retry() }.buttonStyle(.plain)
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
                    ProgressView(value: Double(reader.partAnswers.count), total: Double(max(1, plan.parts.count)))
                        .tint(LyraReaderTheme.accent)
                    Text(reader.mergePlan != nil ? "Connecting the ideas…" : "Reading \(reader.partAnswers.count) of \(plan.parts.count) parts")
                        .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                }
            }
        }
    }
}

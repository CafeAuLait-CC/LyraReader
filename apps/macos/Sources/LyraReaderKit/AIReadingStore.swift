import Combine
import Foundation
import LyraReaderBindings

/// Thin native I/O adapter. Rust owns the records, search, versioning and serialization.
@MainActor
final class AIReadingStore: ObservableObject {
    @Published private(set) var records: [AiReadingRecord] = []
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    var isAvailable: Bool { workspace != nil }
    private var workspace: LyraReadingWorkspace?
    private var file: URL?
    private var identity: String?
    private var generation = UUID()
    private let io = DispatchQueue(label: "lyra.ai.workspace.disk", qos: .utility)

    func load(document: URL?, identity: String, source: URL? = nil) async {
        guard self.identity != identity else { return }
        self.identity = identity
        generation = UUID()
        let token = generation
        records = []; workspace = nil; error = nil; isLoading = true
        // A fast document/session switch must see the writes queued by its departing view.
        await flush()
        guard generation == token else { return }
        guard let document else { isLoading = false; return }
        let file = DocumentEditCache.directory(for: document).appendingPathComponent("ai-reading-workspace.json")
        let fingerprintURL = source ?? document
        self.file = file
        do {
            let loaded = try await Task.detached(priority: .utility) {
                let bytes: Data?
                if FileManager.default.fileExists(atPath: file.path) { bytes = try Data(contentsOf: file) }
                else { bytes = nil }
                let workspace = try LyraReadingWorkspace(bytes: bytes)
                try workspace.bindSource(fingerprint: aiDocumentFingerprint(path: fingerprintURL.path))
                return workspace
            }.value
            guard generation == token else { return }
            workspace = loaded; records = try loaded.records()
        } catch {
            guard generation == token else { return }
            self.error = AIReadableError.message(error)
        }
        if generation == token { isLoading = false }
    }

    func put(_ record: AiReadingRecord) {
        guard let workspace else { return }
        do { _ = try workspace.put(record: record); try refreshAndSave() }
        catch { self.error = AIReadableError.message(error) }
    }
    func putAll(_ records: [AiReadingRecord]) {
        guard let workspace else { return }
        do { try workspace.putAll(records: records); try refreshAndSave() }
        catch { self.error = AIReadableError.message(error) }
    }
    @discardableResult
    func keep(_ source: AiReadingRecord) -> AiReadingRecord? {
        guard let workspace else { return nil }
        do {
            let result = try workspace.keep(source: source, noteId: UUID().uuidString)
            try refreshAndSave()
            return result
        } catch { self.error = AIReadableError.message(error); return nil }
    }
    func notes(query: String, recent: Bool) -> [AiReadingRecord] {
        guard let workspace else { return [] }
        do { return try workspace.notes(query: query, recent: recent) }
        catch { self.error = AIReadableError.message(error); return [] }
    }
    func suggestion(_ id: String) -> AiReadingRecord? {
        guard let workspace else { return nil }
        do { return try workspace.suggestion(noteId: id) }
        catch { self.error = AIReadableError.message(error); return nil }
    }
    func applySuggestion(_ id: String, apply: Bool) {
        guard let workspace else { return }
        do {
            _ = try workspace.applySuggestion(noteId: id, apply: apply, modified: UInt64(Date().timeIntervalSince1970 * 1000))
            try refreshAndSave()
        } catch { self.error = AIReadableError.message(error) }
    }
    func flush() async {
        await withCheckedContinuation { continuation in io.async { continuation.resume() } }
    }
    /// Only used at application termination, after normal interactive work has ended.
    func finishPendingWrites() { io.sync { } }
    private func refreshAndSave() throws {
        guard let workspace, let file else { return }
        records = try workspace.records()
        let token = generation
        io.async { [weak self] in
            do {
                // Rust serializes the durable workspace away from the UI thread.
                let bytes = try workspace.encode()
                try Data(bytes).write(to: file, options: .atomic)
            }
            catch {
                let message = AIReadableError.message(error)
                Task { @MainActor [weak self] in
                    guard self?.generation == token else { return }
                    self?.error = message
                }
            }
        }
    }
}

extension AiReadingRecord {
    static func make(id: String = UUID().uuidString, kind: String, title: String = "", content: String = "",
                     sourceID: String = "", conversationID: String = "", question: String = "", pages: [UInt32] = [],
                     excerpt: String = "", language: String = "", detail: String = "", status: String = "finished") -> Self {
        Self(id: id, kind: kind, sourceId: sourceID, conversationId: conversationID, title: title, content: content,
             thoughts: "", question: question, pages: pages, excerpt: excerpt, language: language, model: "", detail: detail,
             status: status, modified: UInt64(Date().timeIntervalSince1970 * 1000), revision: 0, sourceRevision: 0, originals: [], originalPages: [], sourceHash: "", coveredTurns: 0, versions: [])
    }
}

extension Notification.Name { static let lyraReadingNoteChanged = Notification.Name("LyraReadingNoteChanged") }

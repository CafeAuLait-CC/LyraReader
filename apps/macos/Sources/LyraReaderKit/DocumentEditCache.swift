import CryptoKit
import Foundation

/// Recoverable editor state lives in the application cache, never beside a user's PDF.
@MainActor public enum DocumentEditCache {
    public static var rootOverride: URL?

    public static var root: URL {
        if let rootOverride { return rootOverride }
        if let path = ProcessInfo.processInfo.environment["LYRA_READER_DOCUMENT_CACHE_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyraReader/Documents", isDirectory: true)
    }

    public static func directory(for document: URL) -> URL {
        let path = document.standardizedFileURL.resolvingSymlinksInPath().path
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func annotationsURL(for document: URL) -> URL {
        directory(for: document).appendingPathComponent("annotations.json")
    }

    /// In-place translations live in the document's edit-cache directory, beside the annotations
    /// and revisions. They are never written next to the PDF: a translation is reader state, not
    /// document content, and it must not travel with a shared file.
    public static func translationsURL(for document: URL) -> URL {
        directory(for: document).appendingPathComponent("translations.json")
    }

    struct SourceStamp: Codable, Equatable {
        let size: Int
        let modified: Date?
        let sha256: String
        init(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            size = values.fileSize ?? 0
            modified = values.contentModificationDate
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        static func == (lhs: SourceStamp, rhs: SourceStamp) -> Bool {
            lhs.size == rhs.size && lhs.sha256 == rhs.sha256
        }
    }

    enum CacheError: LocalizedError {
        /// The PDF's identity no longer matches the one recorded with the cache. The message
        /// names the recorded and current `size`/`sha256` so a reader can tell which file moved.
        case sourceChanged(String)
        /// `source.json` exists but cannot be decoded. This is metadata, not annotation
        /// records: it never blocks loading the annotations themselves.
        case sourceMetadata(String)
        case backupVerification
        var errorDescription: String? {
            switch self {
            case .sourceChanged(let detail):
                return detail
            case .sourceMetadata(let detail):
                return "The PDF's saved source stamp could not be read: \(detail)"
            case .backupVerification:
                return "The recovery data could not be verified. The original files were kept."
            }
        }
    }

    /// How today's PDF compares with the `source.json` recorded beside the annotation cache.
    ///
    /// Loading is deliberately separated from this check. A changed PDF means the cache may
    /// describe a different revision of the document, which is a reason to refuse replacing
    /// that PDF (see ``validateSource``), not a reason to call a perfectly readable annotation
    /// cache corrupt. Only a decode failure of `annotations.json`/`changes.json` blocks writes.
    enum SourceStatus: Equatable {
        case missing
        case matches
        case changed(saved: SourceStamp, current: SourceStamp)
        case unreadable(String)
    }

    static func sourceStatus(for document: URL) -> SourceStatus {
        let metadata = directory(for: document).appendingPathComponent("source.json")
        guard FileManager.default.fileExists(atPath: metadata.path),
              FileManager.default.fileExists(atPath: document.path) else { return .missing }
        let expected: SourceStamp
        do {
            expected = try JSONDecoder().decode(SourceStamp.self, from: Data(contentsOf: metadata))
        } catch {
            return .unreadable(AnnotationRecords.describe(error))
        }
        do {
            let current = try SourceStamp(document)
            return current == expected ? .matches : .changed(saved: expected, current: current)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    static func sourceChangeMessage(saved: SourceStamp, current: SourceStamp) -> String {
        "The PDF changed outside LyraReader (recorded size \(saved.size), sha256 \(saved.sha256.prefix(12))…;"
            + " current size \(current.size), sha256 \(current.sha256.prefix(12))…)."
            + " Its saved annotations were kept; restore the recorded file or back up the recovery data"
            + " before starting fresh."
    }

    static func recordSource(for document: URL) throws {
        guard FileManager.default.fileExists(atPath: document.path) else { return }
        try JSONEncoder().encode(SourceStamp(document)).write(
            to: directory(for: document).appendingPathComponent("source.json"), options: .atomic)
    }

    static func validateSource(for document: URL) throws {
        switch sourceStatus(for: document) {
        case .missing, .matches:
            return
        case .changed(let saved, let current):
            throw CacheError.sourceChanged(sourceChangeMessage(saved: saved, current: current))
        case .unreadable(let detail):
            throw CacheError.sourceMetadata(detail)
        }
    }

    static func prepareAnnotations(for document: URL) throws -> URL {
        let cache = annotationsURL(for: document)
        if FileManager.default.fileExists(atPath: cache.path)
            || FileManager.default.fileExists(atPath: pendingStateURL(for: document).path)
            || FileManager.default.fileExists(atPath: recoveryURL(for: document).path) {
            // Reading the cache is not the moment to judge the PDF's identity. `loadAnnotations`
            // decodes the records first and decides separately whether a changed PDF is safe to
            // adopt (nothing cached yet) or needs the explicit recovery choice (cached work).
            // `validateSource` still guards every operation that would replace the PDF itself.
            if !FileManager.default.fileExists(atPath: directory(for: document).appendingPathComponent("source.json").path) {
                try recordSource(for: document)
            }
            return cache
        }
        try recordSource(for: document)
        return cache
    }

    static func recoveryURL(for document: URL) -> URL {
        directory(for: document).appendingPathComponent("session.json")
    }

    static func pendingStateURL(for document: URL) -> URL {
        directory(for: document).appendingPathComponent("changes.json")
    }

    static func newSessionDirectory(for document: URL) throws -> URL {
        let result = directory(for: document).appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
}

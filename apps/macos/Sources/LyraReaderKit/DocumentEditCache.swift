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
        case sourceChanged
        case backupVerification
        var errorDescription: String? {
            switch self {
            case .sourceChanged:
                return "The PDF changed outside LyraReader. Its recovery data was kept; back it up before starting fresh."
            case .backupVerification:
                return "The recovery data could not be verified. The original files were kept."
            }
        }
    }

    static func recordSource(for document: URL) throws {
        guard FileManager.default.fileExists(atPath: document.path) else { return }
        try JSONEncoder().encode(SourceStamp(document)).write(
            to: directory(for: document).appendingPathComponent("source.json"), options: .atomic)
    }

    static func validateSource(for document: URL) throws {
        let metadata = directory(for: document).appendingPathComponent("source.json")
        guard FileManager.default.fileExists(atPath: metadata.path),
              FileManager.default.fileExists(atPath: document.path) else { return }
        let expected = try JSONDecoder().decode(SourceStamp.self, from: Data(contentsOf: metadata))
        guard try SourceStamp(document) == expected else { throw CacheError.sourceChanged }
    }

    static func prepareAnnotations(for document: URL) throws -> URL {
        let cache = annotationsURL(for: document)
        if FileManager.default.fileExists(atPath: cache.path)
            || FileManager.default.fileExists(atPath: pendingStateURL(for: document).path)
            || FileManager.default.fileExists(atPath: recoveryURL(for: document).path) {
            try validateSource(for: document)
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

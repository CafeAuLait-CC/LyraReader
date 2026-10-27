import CryptoKit
import Foundation
import LyraReaderBindings

/// Recoverable editor state lives in the application cache, never beside a user's PDF.
///
/// The directory is keyed by the engine's `DocumentId` — canonical path **and** content hash —
/// so a symlink and its target share one cache, and a replaced file does not inherit the old
/// bytes' records. The engine computes the id once at open (`LoadedDocument.documentId`); the
/// helpers here memoise it by file stamp for the pre-open callers (checks seed a cache before
/// opening the document) and for calls that only have a URL.
///
/// # Lazy migration
///
/// Older builds keyed the directory by SHA-256 of the canonical path alone. On first use the
/// contents of that legacy directory are **copied** into the new one; the old files are left
/// untouched, so a downgrade still finds them and nothing is lost if the copy is interrupted.
///
/// The page-edit recovery manifest (`session.json`) is the one file that cannot be copied as-is:
/// its URLs name the legacy directory, which recovery would reject against the new cache prefix.
/// It is retargeted by the Rust edit crate, written atomically into the new directory, and only
/// then is the legacy manifest renamed to `session.json.migrated` (never deleted) and a
/// completion marker recorded. If retargeting fails, no manifest is imported, the old files stay
/// exactly where they are, and ``migrationFailure(for:)`` reports the reason to the recovery
/// path so it can be shown instead of silently losing the staged edits.
@MainActor public enum DocumentEditCache {
    public static var rootOverride: URL?

    /// The legacy manifest is retired under this name, never deleted. A second migration must
    /// not import it again (the audit's `retiredManifestReimported` case).
    private static let recoveryManifestName = "session.json"
    private static let retiredRecoveryManifestName = "session.json.migrated"

    private struct MigrationMarker: Codable {
        let version: Int
        let legacyDirectory: String
        let documentId: String
        let retiredManifest: String
    }

    /// Why the last legacy-cache migration of `document` could not import its staged page edits.
    private static var migrationFailures: [String: String] = [:]

    private struct IdentityStamp: Equatable {
        let size: UInt64
        let modified: TimeInterval
        let inode: UInt64
    }

    /// Memoised `DocumentId` values, keyed by canonical path and invalidated by a file stamp
    /// change (size, mtime or inode). This keeps a cache-heavy check from hashing the PDF on
    /// every `annotationsURL` call without ever serving a key for bytes that changed.
    private static var identities: [String: (id: String, stamp: IdentityStamp)] = [:]

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func stamp(for url: URL) -> IdentityStamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return IdentityStamp(
            size: size.uint64Value,
            modified: modified.timeIntervalSince1970,
            inode: inode.uint64Value
        )
    }

    /// The one document identity, or `nil` when the file does not exist / cannot be hashed.
    ///
    /// Callers that get `nil` (a recent entry whose file has been deleted, a cache path for a
    /// document that has not been saved yet) fall back to the historical path-only key.
    public static func documentIdentity(for url: URL) -> String? {
        let canonical = canonicalURL(url)
        guard let stamp = stamp(for: canonical) else { return nil }
        let path = canonical.path
        if let cached = identities[path], cached.stamp == stamp { return cached.id }
        guard let id = try? documentIdForPath(path: path), !id.isEmpty else { return nil }
        identities[path] = (id, stamp)
        return id
    }

    /// Adopts the id the engine computed at open, so no second hash is paid for the same bytes.
    public static func adopt(documentId: String, for url: URL) {
        let canonical = canonicalURL(url)
        guard !documentId.isEmpty, let stamp = stamp(for: canonical) else { return }
        identities[canonical.path] = (documentId, stamp)
    }

    /// The historical directory key: SHA-256 of the canonical path, with no content component.
    static func legacyKey(for url: URL) -> String {
        let path = canonicalURL(url).path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func legacyDirectory(for url: URL) -> URL {
        root.appendingPathComponent(legacyKey(for: url), isDirectory: true)
    }

    /// A stable per-path pointer to the most recently used identity directory.
    ///
    /// The identity includes the bytes, so an external edit changes it. The pointer is what
    /// lets the next open find the previous identity's `source.json` and annotations: it can
    /// then report "the PDF changed outside LyraReader" and refuse to overwrite it, exactly as
    /// before the identity existed, instead of silently starting from an empty cache.
    private static func pointerURL(for url: URL) -> URL {
        root.appendingPathComponent(legacyKey(for: url) + ".identity")
    }

    private static func previousIdentityDirectory(for url: URL) -> URL? {
        guard let data = try? Data(contentsOf: pointerURL(for: url)),
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        let directory = root.appendingPathComponent(key, isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    private static func recordIdentityPointer(_ identity: String, for url: URL) {
        let pointer = pointerURL(for: url)
        if let existing = try? Data(contentsOf: pointer),
           String(data: existing, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == identity {
            return
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(identity.utf8).write(to: pointer, options: .atomic)
    }

    /// Copy the persistent reader state from the previous identity directory into this one when
    /// it is not already present. Used on open: if the bytes changed outside the reader, the
    /// old annotations and source stamp must still be found (so the shell can warn and refuse).
    private static func adoptPreviousIdentityState(from previous: URL, to directory: URL) {
        guard previous.path != directory.path else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in carriedFileNames {
            let old = previous.appendingPathComponent(name)
            let new = directory.appendingPathComponent(name)
            guard manager.fileExists(atPath: old.path),
                  !manager.fileExists(atPath: new.path) else { continue }
            try? manager.copyItem(at: old, to: new)
        }
    }

    /// Copy any file the legacy directory holds that the new one does not. Never deletes and
    /// never overwrites: a new-key file is the reader's current state.
    ///
    /// `session.json` is skipped here and handled by ``importLegacyRecoveryManifest``: copying it
    /// verbatim would leave its URLs in the old directory and make the session unrestorable.
    private static func migrateLegacyDirectory(for document: URL, to directory: URL) throws {
        let legacy = legacyDirectory(for: document)
        guard legacy.path != directory.path,
              FileManager.default.fileExists(atPath: legacy.path) else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let names = try? manager.contentsOfDirectory(atPath: legacy.path) else { return }
        for name in names {
            if name == recoveryManifestName || name == retiredRecoveryManifestName { continue }
            let source = legacy.appendingPathComponent(name)
            let destination = directory.appendingPathComponent(name)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            try? manager.copyItem(at: source, to: destination)
        }
        try importLegacyRecoveryManifest(for: document, from: legacy, to: directory)
    }

    /// Moves the legacy `session.json` into the new directory after retargeting its URLs.
    ///
    /// The new manifest is written only after the Rust retargeter accepted every URL. If any
    /// later step fails, the imported copy is removed and the legacy file is left (or moved
    /// back) exactly where it was: a failed migration must not look successful on the next
    /// lookup, and it must not make recovery read a half-imported session.
    private static func importLegacyRecoveryManifest(
        for document: URL,
        from legacy: URL,
        to directory: URL
    ) throws {
        let manager = FileManager.default
        let legacyManifest = legacy.appendingPathComponent(recoveryManifestName)
        let newManifest = directory.appendingPathComponent(recoveryManifestName)
        let marker = migrationMarkerURL(for: document)
        // A completion marker means this manifest was already retired. A manifest already in
        // the new directory is the reader's current state and must win; both cases leave the
        // legacy file alone and import nothing.
        guard manager.fileExists(atPath: legacyManifest.path),
              !manager.fileExists(atPath: marker.path),
              !manager.fileExists(atPath: newManifest.path) else { return }

        let source = try Data(contentsOf: legacyManifest)
        guard let text = String(data: source, encoding: .utf8) else {
            throw LegacyMigrationError(detail: "the legacy manifest is not UTF-8")
        }
        let retargeted: String
        do {
            retargeted = try retargetRecoveryManifest(
                manifestJson: text,
                oldDirectoryUrl: legacy.absoluteString,
                newDirectoryUrl: directory.absoluteString)
        } catch {
            throw LegacyMigrationError(detail: AnnotationRecords.message(error))
        }
        try Data(retargeted.utf8).write(to: newManifest, options: .atomic)

        let retired = retiredRecoveryManifestURL(in: legacy)
        do {
            try manager.moveItem(at: legacyManifest, to: retired)
        } catch {
            // The new copy is not a successful import without the retirement: remove it so the
            // next lookup retries instead of treating a partial migration as complete.
            try? manager.removeItem(at: newManifest)
            throw LegacyMigrationError(
                detail: "the previous manifest could not be retired: \(error.localizedDescription)")
        }
        do {
            let record = MigrationMarker(
                version: 1,
                legacyDirectory: legacy.lastPathComponent,
                documentId: directory.lastPathComponent,
                retiredManifest: retired.lastPathComponent)
            try JSONEncoder().encode(record).write(to: marker, options: .atomic)
        } catch {
            // Completion could not be recorded: undo the import + retirement and report it.
            try? manager.removeItem(at: newManifest)
            try? manager.moveItem(at: retired, to: legacyManifest)
            throw LegacyMigrationError(
                detail: "migration completion could not be recorded: \(error.localizedDescription)")
        }
    }

    /// The name the legacy manifest is retired under. Never reuses an existing file: the first
    /// retirement keeps the expected name and a later one gets a unique suffix.
    private static func retiredRecoveryManifestURL(in legacy: URL) -> URL {
        let preferred = legacy.appendingPathComponent(retiredRecoveryManifestName)
        guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }
        return legacy.appendingPathComponent(
            "\(retiredRecoveryManifestName)-\(UUID().uuidString)")
    }

    /// The durable marker that records a completed legacy-directory migration.
    ///
    /// It names the legacy directory and the destination identity, so a later lookup (or a human
    /// reading the cache) can tell why `session.json` is no longer imported from the old layout.
    static func migrationMarkerURL(for document: URL) -> URL {
        root.appendingPathComponent(legacyKey(for: document) + ".migration")
    }

    /// The reason the last legacy-cache migration of `document` could not import its staged page
    /// edits, or `nil` when there is nothing to report.
    ///
    /// The recovery path turns this into `AppState.lastError`; it is deliberately not consumed
    /// here, so every lookup that retries a failed migration reports the same cause.
    public static func migrationFailure(for document: URL) -> String? {
        migrationFailures[canonicalURL(document).path]
    }

    /// One migration failure. The sentence names the consequence (the staged edits were kept) so
    /// the recovery path can show it without inventing a second explanation.
    private struct LegacyMigrationError: LocalizedError {
        let detail: String
        var errorDescription: String? {
            "The cached page-editing session in the previous cache location could not be moved "
                + "to the current one; its files were left untouched: \(detail)"
        }
    }

    public static var root: URL {
        if let rootOverride { return rootOverride }
        if let path = ProcessInfo.processInfo.environment["LYRA_READER_DOCUMENT_CACHE_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LyraReader/Documents", isDirectory: true)
    }

    public static func directory(for document: URL) -> URL {
        guard let identity = documentIdentity(for: document) else {
            // No bytes to identify (a deleted recent file, a destination not written yet): keep
            // the historical path-only directory so the caller still has a stable location.
            let legacy = legacyDirectory(for: document)
            try? FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            return legacy
        }
        let directory = root.appendingPathComponent(identity, isDirectory: true)
        if let previous = previousIdentityDirectory(for: document) {
            adoptPreviousIdentityState(from: previous, to: directory)
        }
        let path = canonicalURL(document).path
        migrationFailures.removeValue(forKey: path)
        do {
            try migrateLegacyDirectory(for: document, to: directory)
        } catch {
            migrationFailures[path] = error.localizedDescription
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        recordIdentityPointer(identity, for: document)
        return directory
    }

    /// The persistent reader state that must survive an in-place save.
    ///
    /// The document's content hash changes when a command replaces the PDF, so the directory
    /// key changes too. These are the files that are reader state rather than a picture of the
    /// old bytes: annotations and their pending deletions, the source stamp, translations,
    /// summaries, document knowledge, and region conversations. Transient page-edit sessions
    /// (`session-*` directories and `session.json`) are deliberately not carried — the save that
    /// changes the bytes is what retires them.
    private static let carriedFileNames = [
        "annotations.json",
        "changes.json",
        "source.json",
        "translations.json",
        "summaries.json",
        "document-knowledge-v1.json",
        "region-conversations-v1.json",
    ]

    /// Copy the persistent files from the previous identity's directory into the new one.
    ///
    /// Called by the shell immediately after an in-place write changed the bytes. Never
    /// overwrites an existing new-key file and never deletes the old copy.
    public static func carryDocumentState(from source: URL, to destination: URL) {
        guard source.path != destination.path else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in carriedFileNames {
            let old = source.appendingPathComponent(name)
            let new = destination.appendingPathComponent(name)
            guard manager.fileExists(atPath: old.path) else { continue }
            // The new-key `source.json` was written *after* the replacement and describes the
            // new bytes; never overwrite it with the pre-save stamp. Every other file is the
            // cleaned post-save state, which is newer than the provisional copy a directory
            // lookup may have made while the save was in flight.
            if name == "source.json", manager.fileExists(atPath: new.path) { continue }
            try? manager.removeItem(at: new)
            try? manager.copyItem(at: old, to: new)
        }
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

extension String {
    /// This string when it is not empty, for `??` chains that prefer a non-empty cache key.
    var nonEmpty: String? { isEmpty ? nil : self }
}

import AppKit
import Foundation
import LyraReaderBindings
@testable import LyraReaderKit

extension ReaderChecks {
    /// Regression probe for the old path-hash cache layout's page-edit recovery manifest.
    ///
    /// The old cache directory (`<root>/<sha256-of-path>/`) held `session.json` beside a
    /// `session-<uuid>/` directory. When that directory is migrated to the `DocumentId` key the
    /// manifest must be retargeted, not copied verbatim: recovery passes the new directory as its
    /// prefix, so a verbatim copy is rejected by the directory-boundary check and the staged page
    /// edits silently disappear.
    ///
    /// The check stages a **real** inserted-page revision through the production transaction
    /// (`rev-1.pdf` plus the manifest it writes), runs the production `DocumentEditCache.directory`
    /// migration and the real `AppState.open` recovery path, and then exercises the retired
    /// manifest, the completion marker and the failure branch.
    @MainActor static func legacyRecoveryMigrationChecks(root: URL) async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("lyra-legacy-recovery-\(UUID())")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let oldRoot = DocumentEditCache.rootOverride
        DocumentEditCache.rootOverride = scratch.appendingPathComponent("cache", isDirectory: true)
        defer {
            DocumentEditCache.rootOverride = oldRoot
            try? fm.removeItem(at: scratch)
        }

        struct LegacySession {
            let document: URL
            let directory: URL
            let sessionDirectory: URL
            let manifest: URL
            let label: String
        }

        func fixture(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try fm.copyItem(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: url)
            return url
        }

        /// Builds the exact old-layout state a pre-`DocumentId` build left behind: a real page
        /// revision and its manifest, both inside the path-hash directory.
        func stageLegacySession(_ document: URL, label: String) async throws -> LegacySession {
            let legacyKey = DocumentEditCache.legacyKey(for: document)
            let legacy = DocumentEditCache.root.appendingPathComponent(legacyKey, isDirectory: true)
            let sessionDirectory = legacy.appendingPathComponent(
                "session-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            try Data("[]".utf8).write(to: legacy.appendingPathComponent("annotations.json"))
            let stamp = try DocumentEditCache.SourceStamp(document)
            let request = DocumentTransactionStartRecord(
                originalUrl: document.absoluteString,
                directoryUrl: sessionDirectory.absoluteString,
                recoveryPath: legacy.appendingPathComponent("session.json").path,
                originalRecordsUrl: legacy.appendingPathComponent("annotations.json").absoluteString,
                title: document.deletingPathExtension().lastPathComponent,
                pageCount: 3,
                originalRotations: [0, 0, 0],
                originalSignatureJson: #"{"evidence":[],"readOnlyReason":null,"signed":false}"#,
                sourceSize: UInt64(stamp.size),
                sourceModified: stamp.modified?.timeIntervalSinceReferenceDate,
                sourceSha256: stamp.sha256,
                annotationsJson: "[]",
                bookmarksJson: "[]",
                slotsJson: "[]",
                deletionsJson: "[]",
                erasedInkJson: "[]",
                annotationDirty: false,
                currentPage: 1,
                selection: [],
                cacheDirectoryPrefix: legacy.path + "/",
                restore: false,
                xfaReadOnlyReason: nil
            )
            let (transaction, _) = try DocumentTransactionSession.start(request)
            let input = DocumentTransactionInputRecord(
                annotationsJson: "[]",
                bookmarksJson: "[]",
                slotsJson: "[]",
                deletionsJson: "[]",
                erasedInkJson: "[]",
                annotationDirty: false,
                currentPage: 1,
                selection: []
            )
            try transaction.prepare(label: label, input: input)
            let applied = try await transaction.apply(.insertBlank(index: 1))
            require(applied.pageCount == 4 && applied.state.operations == [label],
                    "the legacy-layout fixture stages a real four-page inserted revision")
            transaction.close(deleteFiles: false)
            return LegacySession(
                document: document,
                directory: legacy,
                sessionDirectory: sessionDirectory,
                manifest: legacy.appendingPathComponent("session.json"),
                label: label
            )
        }

        func sessionObject(_ manifest: URL) throws -> [String: Any] {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
            guard let envelope = object as? [String: Any],
                  let session = envelope["session"] as? [String: Any] else {
                throw NSError(domain: "LyraReaderChecks", code: 50, userInfo: [
                    NSLocalizedDescriptionKey: "the recovery manifest has no session object",
                ])
            }
            return session
        }

        func isUnder(_ urlString: String, _ directory: URL) -> Bool {
            guard let url = URL(string: urlString) else { return false }
            return url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
        }

        func sameFile(_ urlString: String, _ url: URL) -> Bool {
            guard let parsed = URL(string: urlString) else { return false }
            return parsed.standardizedFileURL.path == url.standardizedFileURL.path
        }

        // ── A successful old-layout migration restores the staged page edit ──────────────
        let document = try fixture("legacy-recovery.pdf")
        let legacy = try await stageLegacySession(
            document, label: "Insert a blank page before page 2")
        let legacyManifestBytes = try Data(contentsOf: legacy.manifest)
        let identity = DocumentEditCache.documentIdentity(for: document)
        require(identity != nil, "the migration fixture has a DocumentId")
        let newDirectory = DocumentEditCache.directory(for: document)
        require(newDirectory.lastPathComponent == identity,
                "the cache directory is keyed by the document identity")

        let newManifest = newDirectory.appendingPathComponent("session.json")
        require(fm.fileExists(atPath: newManifest.path),
                "the old-layout recovery manifest is imported into the new directory")
        let migrated = try sessionObject(newManifest)
        let migratedDirectory = migrated["directory"] as? String ?? ""
        require(isUnder(migratedDirectory, newDirectory),
                "session.directory is retargeted into the new cache directory")
        require(isUnder(migrated["annotationRecordsURL"] as? String ?? "", newDirectory),
                "annotationRecordsURL is retargeted into the new cache directory")
        let migratedOriginalRecords = migrated["originalRecordsURL"] as? String ?? ""
        require(sameFile(migratedOriginalRecords,
                         newDirectory.appendingPathComponent("annotations.json")),
                "originalRecordsURL is retargeted at the new document cache")
        require(isUnder(migrated["revisionURL"] as? String ?? "", newDirectory),
                "revisionURL is retargeted into the new session directory")
        require(sameFile(migrated["originalURL"] as? String ?? "", document),
                "the original document URL is left unchanged")
        require(URL(string: migratedDirectory)?.standardizedFileURL.path
                    == newDirectory.appendingPathComponent(legacy.sessionDirectory.lastPathComponent)
                        .standardizedFileURL.path,
                "the session directory keeps its name under the new cache")
        for name in ["undo", "redo"] {
            for snapshot in migrated[name] as? [[String: Any]] ?? [] {
                let revision = snapshot["revisionURL"] as? String ?? ""
                require(revision == migrated["originalURL"] as? String
                            || isUnder(revision, newDirectory),
                        "\(name) revision URLs are retargeted or remain the original")
            }
        }

        let retiredManifest = legacy.directory.appendingPathComponent("session.json.migrated")
        require(!fm.fileExists(atPath: legacy.manifest.path),
                "the legacy manifest is retired, not left in place")
        require(fm.fileExists(atPath: retiredManifest.path)
                    && (try? Data(contentsOf: retiredManifest)) == legacyManifestBytes,
                "the retired legacy manifest is preserved byte-for-byte")
        let marker = DocumentEditCache.root.appendingPathComponent(
            DocumentEditCache.legacyKey(for: document) + ".migration")
        require(fm.fileExists(atPath: marker.path),
                "migration completion is recorded durably")
        let markerText = String(decoding: try Data(contentsOf: marker), as: UTF8.self)
        require(markerText.contains(legacy.directory.lastPathComponent)
                    && markerText.contains(identity ?? ""),
                "the completion marker names the legacy directory and the new identity")

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 1000, height: 800))
        require(state.open(url: document), "the migrated document opens")
        require(state.pageEditSessionActive,
                "the migrated page-edit session is restored (pre-fix: the manifest is rejected)")
        require(state.pageEditPendingOperations == [legacy.label],
                "the restored session keeps the staged operation: \(state.lastError ?? "no error")")
        require(state.document?.pageCount == 4,
                "the restored working revision has the inserted page")
        require(state.document?.url.map { isUnder($0.absoluteString, newDirectory) } == true,
                "the restored revision is the one in the new cache directory")

        // The audit's `retiredManifestReimported` repro: deleting the imported manifest must not
        // make the next directory lookup copy the old one in again.
        try fm.removeItem(at: newManifest)
        _ = DocumentEditCache.directory(for: document)
        require(!fm.fileExists(atPath: newManifest.path),
                "a deleted new manifest is not re-imported from the retired legacy one")
        require(fm.fileExists(atPath: retiredManifest.path),
                "the retired legacy manifest stays retired")
        state.discardPageEdits()
        let reopened = AppState(engine: try RustEngine())
        reopened.setViewportSize(CGSize(width: 1000, height: 800))
        require(reopened.open(url: document), "the document reopens after the manifest was deleted")
        require(!reopened.pageEditSessionActive && reopened.pageEditPendingOperations.isEmpty,
                "the retired manifest does not come back as a recovered session")

        // ── A manifest that cannot be retargeted is left alone and reported ─────────────
        let brokenDocument = try fixture("legacy-recovery-broken.pdf")
        let broken = try await stageLegacySession(
            brokenDocument, label: "Insert a blank page before page 2")
        var envelope = try JSONSerialization.jsonObject(
            with: Data(contentsOf: broken.manifest)) as? [String: Any] ?? [:]
        var session = envelope["session"] as? [String: Any] ?? [:]
        let foreignSession = "file:///tmp/lyra-legacy-foreign-\(UUID().uuidString)/"
        session["directory"] = foreignSession
        envelope["session"] = session
        let brokenManifest = try JSONSerialization.data(
            withJSONObject: envelope, options: [.sortedKeys])
        try brokenManifest.write(to: broken.manifest)
        let brokenRevision = broken.sessionDirectory.appendingPathComponent("rev-1.pdf")
        let brokenMarker = DocumentEditCache.root.appendingPathComponent(
            DocumentEditCache.legacyKey(for: brokenDocument) + ".migration")
        let brokenIdentity = DocumentEditCache.documentIdentity(for: brokenDocument)
        require(brokenIdentity != nil, "the broken-migration fixture has a DocumentId")
        let brokenDirectory = DocumentEditCache.root.appendingPathComponent(
            brokenIdentity ?? "")
        let brokenState = AppState(engine: try RustEngine())
        brokenState.setViewportSize(CGSize(width: 1000, height: 800))
        require(brokenState.open(url: brokenDocument),
                "a document whose legacy manifest cannot be retargeted still opens")
        require(!brokenState.pageEditSessionActive,
                "a foreign legacy manifest is not restored")
        require(brokenState.lastError != nil,
                "a failed migration is visible to the caller, not swallowed")
        require(brokenState.lastError?.contains("could not be moved") == true,
                "the visible failure names the failed manifest migration")
        require(!fm.fileExists(atPath: brokenDirectory.appendingPathComponent("session.json").path),
                "a failed migration writes no partial session.json into the new directory")
        require((try? Data(contentsOf: broken.manifest)) == brokenManifest,
                "a failed migration leaves the legacy manifest byte-identical")
        require(!fm.fileExists(atPath: broken.directory.appendingPathComponent("session.json.migrated").path),
                "a failed migration does not retire the legacy manifest")
        require(!fm.fileExists(atPath: brokenMarker.path),
                "a failed migration does not claim completion")
        require(fm.fileExists(atPath: brokenRevision.path),
                "a failed migration leaves the legacy working revision in place")
        _ = DocumentEditCache.directory(for: brokenDocument)
        require(!fm.fileExists(atPath: brokenDirectory.appendingPathComponent("session.json").path),
                "a retried failed migration still writes no partial manifest")

        print("Legacy recovery migration checks passed")
    }
}

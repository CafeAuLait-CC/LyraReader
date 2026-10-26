import AppKit
import CryptoKit
import Foundation
@testable import LyraReaderKit

/// Equivalence evidence for the page-edit transaction (audit C2b/C4).
///
/// The page-edit session used to live in `AppState`: it wrote `rev-N.pdf` files, kept the
/// annotation/bookmark snapshot per revision, remapped the reader's marks after each page
/// operation and wrote `session.json` recovery data. This suite freezes what that state machine
/// produced **before** it moved to `lyra-reader-edit::DocumentTransaction`, and then compares the
/// moved implementation against the same freeze.
///
/// # What is compared, byte for byte
///
/// * every page operation's resulting page map, page count, inserted page and revision number;
/// * the revision file names under the session directory (`rev-N.pdf`, one chain per session);
/// * the recovery JSON (`session.json`) after each step, compared as bytes;
/// * a scripted undo/redo sequence, one manifest entry and one recovery file per step;
/// * a simulated process kill mid-transaction (a complete unreferenced revision left behind);
/// * signed-document and XFA refusal paths;
/// * extract/split/merge reports (these stay immediate-to-a-new-file; the suite still pins them).
///
/// Foundation's `JSONEncoder` writes object keys in a per-process random order (it is backed by
/// a randomly seeded hasher), so no two raw captures of the pre-change writer are byte-identical
/// even when every value is. Both the capture and the check therefore re-encode the recovery
/// object with `JSONSerialization` `[.sortedKeys]` before comparing; that orders keys and leaves
/// every value, number spelling, escape and field exactly as the writer produced it. The raw
/// capture and this canonical form differ only in key order (proved by the checks below).
extension ReaderChecks {
    private static let transactionFixtureDirectory = "tests/fixtures/document-transaction"

    @MainActor
    static func captureDocumentTransactionGoldens(root: URL) async throws {
        let result = try await documentTransactionResults(root: root)
        let directory = root.appendingPathComponent(transactionFixtureDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in result.recoveries.sorted(by: { $0.key < $1.key }) {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        let manifest = try JSONSerialization.data(
            withJSONObject: result.manifest, options: [.prettyPrinted, .sortedKeys])
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        print("Captured \(result.recoveries.count) recovery goldens and the transaction manifest")
    }

    /// Child half of the killed-process check: starts a real page-edit session, stages one
    /// verified revision, then writes the *next* revision through a separate engine and dies
    /// before the session can adopt it — the exact window a crash can land in.
    ///
    /// Launched by the parent check with
    /// `--document-transaction-crash-child <root> <fixture> <cache-root>`.
    @MainActor
    static func documentTransactionCrashChild() async throws {
        guard CommandLine.arguments.count >= 5 else { exit(2) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
        let cache = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
        DocumentEditCache.rootOverride = cache
        let state = AppState(engine: try RustEngine())
        guard state.open(url: fixture) else { exit(3) }
        state.selectPage(0, extending: false, toggling: false)
        let applied = await state.applyPageEditOperation(
            .insertBlank(index: 1), label: "Insert a blank page before page 2")
        guard applied else { exit(4) }
        for _ in 0..<400 {
            if !state.pageEditBusy { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard state.pageEditPendingOperations.count == 1 else { exit(5) }
        // The next revision is written and verified, but the process dies before the session
        // can adopt it (no recovery write, no undo push, no cleanup).
        let recovery = DocumentEditCache.recoveryURL(for: fixture)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: recovery))
        guard let envelope = object as? [String: Any],
              let session = envelope["session"] as? [String: Any],
              let directory = session["directory"] as? String,
              let sessionDirectory = URL(string: directory) else { exit(6) }
        let revision = sessionDirectory.appendingPathComponent("rev-2.pdf")
        let engine = try RustEngine()
        guard let current = state.document?.url, (try? engine.openDocument(at: current)) != nil else { exit(7) }
        _ = try await engine.applyPageOperation(.delete(pages: [0]), to: revision)
        // Hard exit: no `defer`, no session close, no recovery rewrite.
        _exit(9)
    }

    @MainActor
    static func documentTransactionChecks(root: URL) async throws {
        let directory = root.appendingPathComponent(transactionFixtureDirectory)
        let actual = try await documentTransactionResults(root: root)
        let expectedManifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let expectedManifest = try JSONSerialization.jsonObject(with: expectedManifestData)
        let differences = manifestDifferences(expected: expectedManifest, actual: actual.manifest)
        require(differences.isEmpty,
                "the page-edit transaction manifest matches its pre-change freeze"
                + (differences.isEmpty ? "" : ": " + differences.prefix(8).joined(separator: " · ")))
        for (name, data) in actual.recoveries.sorted(by: { $0.key < $1.key }) {
            let golden = try Data(contentsOf: directory.appendingPathComponent(name))
            require(data == golden,
                    "the recovery JSON \(name) is byte-identical to the pre-change capture"
                    + (data == golden ? "" : " (\(data.count) vs \(golden.count) bytes)"))
        }
        try await fractionalTimestampRecoveryCheck(root: root)
        try await materialisedRotationCheck(root: root)
        print("Document-transaction equivalence checks passed")
    }

    /// A rotation on a page with cached marks first materialises those marks into a working
    /// PDF. The new revision must show them from the PDF (the cache is empty) while the undo
    /// snapshot keeps the cache entries, so undo restores one copy rather than two.
    @MainActor
    private static func materialisedRotationCheck(root: URL) async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("lyra-doctx-materialise-\(UUID())")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        DocumentEditCache.rootOverride = scratch.appendingPathComponent("cache")
        defer { DocumentEditCache.rootOverride = nil }

        let source = scratch.appendingPathComponent("materialise.pdf")
        try fm.copyItem(
            at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: source)
        let mark = AppState.Annotation(
            id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
            kind: .highlight, page: 0, start: 0, end: 4,
            color: AppState.highlightPalette[0].color, note: "materialise me",
            createdAt: Date(timeIntervalSinceReferenceDate: 599_627_045))
        let records = try AnnotationRecords.encode(
            annotations: [mark], bookmarks: [], slots: [.annotation(mark.id)])
        try records.write(to: DocumentEditCache.annotationsURL(for: source))
        let state = AppState(engine: try RustEngine())
        require(state.open(url: source), "the materialised-rotation fixture opens")
        state.selectPage(0, extending: false, toggling: false)
        let applied = await state.applyPageEditOperation(
            .rotate(pages: [0], quarterTurns: 1), label: "Rotate page 1 90° clockwise")
        require(applied, "rotation materialises the cached marks and stages the revision")
        require(state.annotations.isEmpty,
                "the rotated revision shows the mark from the PDF, not a duplicate cache entry")
        require(state.pageEditPendingOperations.count == 1,
                "the materialised rotation is one pending page change")
        let recovery = String(
            decoding: try Data(contentsOf: DocumentEditCache.recoveryURL(for: source)),
            as: UTF8.self)
        require(recovery.contains("\"annotations\":[]"),
                "the current recovery snapshot keeps no duplicate mark")
        require(recovery.contains("materialise me"),
                "the undo snapshot keeps the cached mark for undo")
        state.undoPageEdit()
        for _ in 0..<400 {
            if !state.pageEditBusy && state.pageEditPendingOperations.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        require(state.annotations.count == 1 && state.annotations[0].page == 0,
                "undo restores the cached mark on its original page")
        state.discardPageEdits()
    }

    /// Foundation prints a `Date` with its shortest round-tripping spelling. The recovery writer
    /// must not re-spell it (`0.1` as `0.10000000000000001`, which `JSONSerialization` does).
    /// This guards the one number shape the integral-date freezes cannot cover.
    @MainActor
    private static func fractionalTimestampRecoveryCheck(root: URL) async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("lyra-doctx-fractional-\(UUID())")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        DocumentEditCache.rootOverride = scratch.appendingPathComponent("cache")
        defer { DocumentEditCache.rootOverride = nil }

        let source = scratch.appendingPathComponent("fractional.pdf")
        try fm.copyItem(
            at: root.appendingPathComponent("tests/fixtures/multipage.pdf"), to: source)
        let createdAt = Date(timeIntervalSinceReferenceDate: 784_123_456.789_012)
        let annotation = AppState.Annotation(
            id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            kind: .highlight, page: 0, start: 0, end: 4,
            color: AppState.highlightPalette[1].color, note: "fractional timestamp",
            createdAt: createdAt)
        let records = try AnnotationRecords.encode(
            annotations: [annotation], bookmarks: [],
            slots: [.annotation(annotation.id)])
        try records.write(to: DocumentEditCache.annotationsURL(for: source))
        let state = AppState(engine: try RustEngine())
        require(state.open(url: source), "the fractional-timestamp fixture opens")
        let applied = await state.applyPageEditOperation(
            .insertBlank(index: 1), label: "Insert a blank page before page 2")
        require(applied, "the fractional-timestamp edit is staged")
        for _ in 0..<400 {
            if !state.pageEditBusy { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let recovery = DocumentEditCache.recoveryURL(for: source)
        let text = String(decoding: try Data(contentsOf: recovery), as: UTF8.self)
        require(text.contains("\"createdAt\":784123456.789012"),
                "the recovery manifest keeps Foundation's shortest fractional Date spelling")
        require(!text.contains("784123456.78901196"),
                "the recovery manifest does not re-spell a fractional Date")
        state.discardPageEdits()

        let sample = Data(#"{"s":"a\/b","n":0.1,"i":12}"#.utf8)
        let canonical = try canonicalRecoveryBytes(sample) { $0 }
        require(canonical == Data(#"{"i":12,"n":0.1,"s":"a\/b"}"#.utf8),
                "the canonicalizer sorts keys without re-spelling numbers or escapes")
    }

    /// Everything the capture writes. Recoveries are canonical key-sorted `session.json` bytes
    /// with machine-specific paths replaced by `$SCRATCH` / `$SESSION` tokens.
    private struct DocumentTransactionResults {
        var manifest: Any
        var recoveries: [String: Data]
    }

    @MainActor
    private static func documentTransactionResults(root: URL) async throws -> DocumentTransactionResults {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("lyra-doctx-\(UUID())")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        DocumentEditCache.rootOverride = scratch.appendingPathComponent("cache")
        defer { DocumentEditCache.rootOverride = nil }

        let fixedDate = Date(timeIntervalSinceReferenceDate: 599_627_045)
        let fileDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var recoveries: [String: Data] = [:]
        var cases: [String: Any] = [:]

        func copyFixture(_ name: String, to fileName: String) throws -> URL {
            let destination = scratch.appendingPathComponent(fileName)
            try fm.copyItem(at: root.appendingPathComponent("tests/fixtures/\(name)"), to: destination)
            try fm.setAttributes([.modificationDate: fileDate], ofItemAtPath: destination.path)
            return destination
        }

        let annotationOne = AppState.Annotation(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            kind: .highlight, page: 0, start: 0, end: 4,
            color: AppState.highlightPalette[0].color, note: "first page mark",
            createdAt: fixedDate)
        let annotationTwo = AppState.Annotation(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            kind: .underline, page: 1, start: 1, end: 5,
            color: AppState.highlightPalette[2].color, note: "second page mark",
            createdAt: fixedDate)
        let bookmark = Bookmark(
            id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            page: 1, title: "second page bookmark", yPt: 12, createdAt: fixedDate)

        func seedRecords(_ document: URL) throws {
            let data = try AnnotationRecords.encode(
                annotations: [annotationOne, annotationTwo],
                bookmarks: [bookmark],
                slots: [.annotation(annotationOne.id), .annotation(annotationTwo.id),
                        .bookmark(bookmark.id)])
            try data.write(to: DocumentEditCache.annotationsURL(for: document))
        }

        func makeState(_ document: URL, viewport: CGSize = CGSize(width: 1000, height: 800))
            throws -> AppState {
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(viewport)
            require(state.open(url: document), "the transaction fixture \(document.lastPathComponent) opens")
            state.selectPage(0, extending: false, toggling: false)
            return state
        }

        func waitForIdle(_ state: AppState, pending: Int? = nil) async throws {
            for _ in 0..<400 {
                if !state.pageEditBusy && (pending == nil || state.pageEditPendingOperations.count == pending!) {
                    return
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw NSError(domain: "LyraReaderChecks", code: 40, userInfo: [
                NSLocalizedDescriptionKey:
                    "the page-edit session did not become idle (busy \(state.pageEditBusy), "
                    + "pending \(state.pageEditPendingOperations.count))",
            ])
        }

        func token(scratch: URL, sessionDirectories: [URL]) -> (String) -> String {
            { value in
                var text = value
                text = text.replacingOccurrences(of: scratch.path, with: "$SCRATCH")
                // The document-cache directory is the engine's DocumentId: canonical path plus
                // the PDF's content hash. The scratch path changes per run, so the id does too;
                // it is machine state, not transaction state. The source PDF's own sha256 lives
                // in `sourceStamp` and is deliberately not touched.
                text = text.replacingOccurrences(
                    of: #"/cache/[0-9a-f]{64}/"#, with: "/cache/$IDENTITY/",
                    options: .regularExpression)
                // The canonicalizer passes raw string contents (with Foundation's `\/` URL
                // escaping); the same tokens must be recognized in that spelling too.
                let escapedScratch = scratch.path.replacingOccurrences(of: "/", with: "\\/")
                text = text.replacingOccurrences(of: escapedScratch, with: "$SCRATCH")
                text = text.replacingOccurrences(
                    of: #"\\/cache\\/[0-9a-f]{64}\\/"#,
                    with: #"\\/cache\\/$IDENTITY\\/"#,
                    options: .regularExpression)
                for session in sessionDirectories {
                    text = text.replacingOccurrences(
                        of: session.lastPathComponent, with: "session-$SESSION")
                }
                return text
            }
        }

        func sessionDirectory(of state: AppState) throws -> URL? {
            guard let original = state.pageEditOriginalURLForChecks else { return nil }
            let recovery = DocumentEditCache.recoveryURL(for: original)
            guard fm.fileExists(atPath: recovery.path) else { return nil }
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: recovery))
            guard let envelope = object as? [String: Any],
                  let session = envelope["session"] as? [String: Any],
                  let directory = session["directory"] as? String,
                  let url = URL(string: directory) else { return nil }
            return url
        }

        func canonicalRecovery(
            of state: AppState,
            normalize: @escaping (String) -> String
        ) throws -> Data? {
            guard let original = state.pageEditOriginalURLForChecks else { return nil }
            let recovery = DocumentEditCache.recoveryURL(for: original)
            guard fm.fileExists(atPath: recovery.path) else { return nil }
            return try canonicalRecoveryBytes(
                Data(contentsOf: recovery), normalize: normalize)
        }

        func annotationManifest(_ state: AppState) -> [[String: Any]] {
            state.annotations.map { annotation in
                var entry: [String: Any] = [
                    "id": annotation.id.uuidString,
                    "kind": annotation.kind.rawValue,
                    "page": annotation.page,
                    "note": annotation.note,
                    "start": annotation.start,
                    "end": annotation.end,
                ]
                if let identity = annotation.fileIdentity { entry["fileIdentity"] = identity }
                return entry
            }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
        }

        func bookmarkManifest(_ state: AppState) -> [[String: Any]] {
            state.bookmarks.map { bookmark in
                [
                    "id": bookmark.id.uuidString,
                    "page": bookmark.page,
                    "title": bookmark.title,
                    "yPt": Double(bookmark.yPt),
                ]
            }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
        }

        func stateManifest(
            _ state: AppState,
            normalize: (String) -> String,
            recoveryName: String?
        ) -> [String: Any] {
            let revision: String
            if let url = state.document?.url {
                revision = normalize(url.path)
            } else {
                revision = "none"
            }
            var entry: [String: Any] = [
                "revision": revision,
                "revisionNumber": state.pageEditRevisionNumberForChecks,
                "currentToOriginal": state.pageEditCurrentToOriginalForChecks,
                "operations": state.pageEditPendingOperations,
                "pending": state.pageEditPendingOperations.count,
                "canUndo": state.canUndoPageEdit,
                "canRedo": state.canRedoPageEdit,
                "sessionActive": state.pageEditSessionActive,
                "currentPage": state.currentPage,
                "selection": state.pageSelection.sorted(),
                "pageCount": state.document?.pageCount ?? 0,
                "annotations": annotationManifest(state),
                "bookmarks": bookmarkManifest(state),
            ]
            if let last = state.pageEditLastAction { entry["lastAction"] = last }
            if let recoveryName { entry["recovery"] = recoveryName }
            return entry
        }

        func record(
            _ name: String,
            state: AppState,
            normalize: @escaping (String) -> String,
            extra: [String: Any] = [:]
        ) throws -> [String: Any] {
            let recoveryName = "\(name).json"
            if let data = try canonicalRecovery(of: state, normalize: normalize) {
                recoveries[recoveryName] = data
            }
            var entry = stateManifest(state, normalize: normalize, recoveryName: recoveryName)
            for (key, value) in extra { entry[key] = value }
            return entry
        }

        func pageMapManifest(_ report: PageOperationReport) -> [Any] {
            report.pageMap.map { $0.map { $0 as Any } ?? NSNull() }
        }

        // ── One fresh document per page operation ───────────────────────────────────────────
        func runPageOperation(
            name: String,
            operation: PageEditOperation,
            label: String
        ) async throws {
            let document = try copyFixture("multipage.pdf", to: "\(name).pdf")
            try seedRecords(document)
            let state = try makeState(document)
            let normalize = token(scratch: scratch, sessionDirectories: [])
            let before = try record("\(name)-before", state: state, normalize: normalize)
            let applied = await state.applyPageEditOperation(operation, label: label)
            require(applied, "\(name): the page operation is staged")
            try await waitForIdle(state)
            let session = try sessionDirectory(of: state)
            let normalizeWithSession = token(scratch: scratch, sessionDirectories: session.map { [$0] } ?? [])
            let after = try record("\(name)-after", state: state, normalize: normalizeWithSession)
            let revisionNames = try session.map { url in
                try fm.contentsOfDirectory(atPath: url.path)
                    .filter { $0.hasPrefix("rev-") || $0.hasPrefix("marks-") }
                    .sorted()
            } ?? []
            cases[name] = [
                "before": before,
                "after": after,
                "revisionFiles": revisionNames,
            ]
            state.discardPageEdits()
        }

        try await runPageOperation(
            name: "insert-blank",
            operation: .insertBlank(index: 1),
            label: "Insert a blank page before page 2")
        try await runPageOperation(
            name: "delete-page",
            operation: .delete(pages: [1]),
            label: "Delete page 2")
        try await runPageOperation(
            name: "rotate-page",
            operation: .rotate(pages: [2], quarterTurns: 1),
            label: "Rotate page 3 90° clockwise")
        try await runPageOperation(
            name: "move-page",
            operation: .move(pages: [0], destination: 2),
            label: "Move page 1 to position 3")

        // ── Scripted undo/redo sequence ─────────────────────────────────────────────────────
        do {
            let document = try copyFixture("multipage.pdf", to: "sequence.pdf")
            try seedRecords(document)
            let state = try makeState(document)
            var steps: [[String: Any]] = []
            var sessions: [URL] = []
            var normalize = token(scratch: scratch, sessionDirectories: sessions)
            func capture(_ name: String) throws {
                let after = try record(name, state: state, normalize: normalize)
                steps.append(after)
            }
            try capture("sequence-step-0-clean")
            let insert = await state.applyPageEditOperation(
                .insertBlank(index: 1), label: "Insert a blank page before page 2")
            require(insert, "sequence: insert is staged")
            try await waitForIdle(state, pending: 1)
            if let session = try sessionDirectory(of: state), !sessions.contains(session) {
                sessions.append(session)
                normalize = token(scratch: scratch, sessionDirectories: sessions)
            }
            try capture("sequence-step-1-insert")
            let rotate = await state.applyPageEditOperation(
                .rotate(pages: [1], quarterTurns: 1), label: "Rotate page 2 90° clockwise")
            require(rotate, "sequence: rotation of the inserted page is staged")
            try await waitForIdle(state, pending: 2)
            try capture("sequence-step-2-rotate")
            let move = await state.applyPageEditOperation(
                .move(pages: [0], destination: 2), label: "Move page 1 to position 3")
            require(move, "sequence: move is staged")
            try await waitForIdle(state, pending: 3)
            try capture("sequence-step-3-move")
            state.undoPageEdit()
            try await waitForIdle(state, pending: 2)
            try capture("sequence-step-4-undo")
            state.undoPageEdit()
            try await waitForIdle(state, pending: 1)
            try capture("sequence-step-5-undo")
            state.undoPageEdit()
            try await waitForIdle(state, pending: 0)
            try capture("sequence-step-6-undo-all")
            state.redoPageEdit()
            try await waitForIdle(state, pending: 1)
            try capture("sequence-step-7-redo")
            state.redoPageEdit()
            try await waitForIdle(state, pending: 2)
            try capture("sequence-step-8-redo")
            let delete = await state.applyPageEditOperation(
                .delete(pages: [0]), label: "Delete page 1")
            require(delete, "sequence: a new operation after undo is staged")
            try await waitForIdle(state, pending: 3)
            try capture("sequence-step-9-new-after-redo")
            require(!state.canRedoPageEdit, "a new page operation clears the redo stack")
            cases["sequence"] = steps
            state.discardPageEdits()
        }

        // ── A killed process mid-transaction leaves the last complete revision reachable ─────
        do {
            let document = try copyFixture("multipage.pdf", to: "crash.pdf")
            try seedRecords(document)
            let cacheRoot = DocumentEditCache.root
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            child.arguments = [
                "--document-transaction-crash-child",
                root.path,
                document.path,
                cacheRoot.path,
            ]
            try child.run()
            child.waitUntilExit()
            require(child.terminationStatus == 9,
                    "crash: the child process really died mid-transaction (status \(child.terminationStatus))")
            // The state a killed process leaves behind: the first revision and its recovery are
            // complete, a verified second revision exists but was never adopted.
            let session = try sessionDirectoryFromRecovery(DocumentEditCache.recoveryURL(for: document))
            require(session.map { fm.fileExists(atPath: $0.appendingPathComponent("rev-2.pdf").path) } == true,
                    "crash: the unwritten next revision exists on disk")
            let normalize = token(scratch: scratch, sessionDirectories: session.map { [$0] } ?? [])
            let crashedRecovery = try canonicalRecoveryAfterCrash(
                DocumentEditCache.recoveryURL(for: document), normalize: normalize)
            if let crashedRecovery { recoveries["crash-recovery.json"] = crashedRecovery }
            let resumed = try makeState(document)
            try await waitForIdle(resumed, pending: 1)
            var entry = try record("crash-restored", state: resumed, normalize: normalize)
            entry["partialRevisionVisible"] =
                resumed.document?.url?.lastPathComponent == "rev-2.pdf"
            entry["recoveryBeforeRestore"] = crashedRecovery != nil
            cases["crash"] = entry
            resumed.discardPageEdits()
        }

        // ── Signed document: stage and copy are allowed, replacing the original is refused ──
        do {
            let document = try copyFixture("signed-signature.pdf", to: "signed.pdf")
            let originalBytes = try Data(contentsOf: document)
            let state = try makeState(document)
            let before = [
                "signed": state.documentSignature.signed,
                "readOnly": state.isReadOnlyDocument,
                "canPageEdit": state.canPageEdit,
                "canReplace": state.canReplaceOriginalWithPageEdits,
                "readOnlyReason": state.readOnlyReason ?? "nil",
            ] as [String: Any]
            let applied = await state.applyPageEditOperation(
                .insertBlank(index: 1), label: "Insert a blank page before page 2")
            try await waitForIdle(state)
            let staged = [
                "applied": applied,
                "pending": state.pageEditPendingOperations.count,
                "canSaveCopy": state.canSavePageEditsCopy,
                "canReplace": state.canReplaceOriginalWithPageEdits,
            ] as [String: Any]
            let replaced = await state.replaceOriginalWithPageEdits()
            let refusal = [
                "replaced": replaced,
                "error": state.lastError ?? "nil",
                "status": state.statusMessage,
                "originalUnchanged": (try Data(contentsOf: document)) == originalBytes,
            ] as [String: Any]
            cases["signed"] = ["before": before, "staged": staged, "refusal": refusal]
            state.discardPageEdits()
        }

        // ── XFA form: page editing is not offered and the engine refuses it ─────────────────
        do {
            let document = try copyFixture("xfa-refusal.pdf", to: "xfa.pdf")
            let originalBytes = try Data(contentsOf: document)
            let state = try makeState(document)
            let applied = await state.applyPageEditOperation(
                .insertBlank(index: 0), label: "Insert a blank page")
            let entry = [
                "xfa": state.isXfaDocument,
                "canPageEdit": state.canPageEdit,
                "canPageOperations": state.canPageOperations,
                "readOnlyReason": state.readOnlyReason ?? "nil",
                "applied": applied,
                "error": state.lastError ?? "nil",
                "sessionActive": state.pageEditSessionActive,
                "originalUnchanged": (try Data(contentsOf: document)) == originalBytes,
            ] as [String: Any]
            cases["xfa"] = entry
            state.discardPageEdits()
        }

        // ── Extract, split and merge reports stay immediate-to-a-new-file ───────────────────
        do {
            let source = try copyFixture("multipage.pdf", to: "export-source.pdf")
            let extracted = scratch.appendingPathComponent("export-extract.pdf")
            let extractProbe = try RustEngine()
            _ = try extractProbe.openDocument(at: source)
            let extract = try await extractProbe.extractPages([0, 2], to: extracted)
            let first = scratch.appendingPathComponent("export-split-1.pdf")
            let second = scratch.appendingPathComponent("export-split-2.pdf")
            let split = try await extractProbe.splitPages([
                PageSplitPart(pages: [0], destination: first),
                PageSplitPart(pages: [1, 2], destination: second),
            ])
            let other = try copyFixture("annotated.pdf", to: "export-other.pdf")
            let merged = scratch.appendingPathComponent("export-merge.pdf")
            let merge = try await extractProbe.mergeDocuments(others: [other], to: merged)
            cases["exports"] = [
                "extract": [
                    "pageMap": pageMapManifest(extract),
                    "pageCount": extract.pageCount,
                    "rotations": extract.rotations,
                ],
                "split": [
                    "sourcePageCount": split.sourcePageCount,
                    "parts": split.parts.map {
                        [
                            "pageCount": $0.pageCount,
                            "sourcePages": $0.sourcePages,
                            "rotations": $0.rotations,
                        ] as [String: Any]
                    },
                ],
                "merge": [
                    "pageCount": merge.pageCount,
                    "firstPageCount": merge.firstPageCount,
                    "appendedPageCounts": merge.appendedPageCounts,
                    "appendedAnnotationCounts": merge.appendedAnnotationCounts,
                    "rotations": merge.rotations,
                    "firstOutlineEntries": merge.firstOutlineEntries,
                    "appendedOutlineEntries": merge.appendedOutlineEntries,
                    "appendedOutlineGroupTitles": merge.appendedOutlineGroupTitles,
                ],
            ]
        }

        return DocumentTransactionResults(manifest: cases, recoveries: recoveries)
    }

    // MARK: - Helpers shared with the check

    private static func sessionDirectoryFromRecovery(_ recovery: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: recovery.path) else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: recovery))
        guard let envelope = object as? [String: Any],
              let session = envelope["session"] as? [String: Any],
              let directory = session["directory"] as? String else { return nil }
        return URL(string: directory)
    }

    private static func canonicalRecoveryAfterCrash(
        _ recovery: URL, normalize: @escaping (String) -> String
    ) throws -> Data? {
        guard FileManager.default.fileExists(atPath: recovery.path) else { return nil }
        return try canonicalRecoveryBytes(Data(contentsOf: recovery), normalize: normalize)
    }

    /// Canonical recovery bytes: object keys sorted, compact separators, and every number or
    /// string lexeme preserved exactly as the writer produced it.
    ///
    /// `JSONSerialization` cannot be used here: it re-spells an already short double
    /// (`0.1` becomes `0.10000000000000001`), which would make the freeze disagree with the
    /// writer on ordinary annotation timestamps. The canonicalizer therefore walks the JSON
    /// text itself: it only reorders object keys and applies the caller's path tokenization to
    /// raw string contents, so number spelling, `/` escaping and every value byte stay put.
    private static func canonicalRecoveryBytes(
        _ data: Data, normalize: @escaping (String) -> String
    ) throws -> Data {
        var writer = RawJSONCanonicalizer(bytes: Array(data), normalize: normalize)
        let text = try writer.run()
        return Data(text.utf8)
    }

    private struct RawJSONCanonicalizer {
        let bytes: [UInt8]
        let normalize: (String) -> String
        var index = 0

        init(bytes: [UInt8], normalize: @escaping (String) -> String) {
            self.bytes = bytes
            self.normalize = normalize
        }

        mutating func run() throws -> String {
            let value = try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw canonicalError("trailing bytes") }
            return value
        }

        private mutating func parseValue() throws -> String {
            skipWhitespace()
            guard index < bytes.count else { throw canonicalError("unexpected end") }
            switch bytes[index] {
            case Character("{").asciiValue!:
                return try parseObject()
            case Character("[").asciiValue!:
                return try parseArray()
            case Character("\"").asciiValue!:
                return "\"" + normalize(try parseStringToken()) + "\""
            default:
                return try parseScalar()
            }
        }

        private mutating func parseObject() throws -> String {
            index += 1 // {
            var entries: [(key: String, value: String)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == Character("}").asciiValue! {
                index += 1
                return "{}"
            }
            while true {
                skipWhitespace()
                let key = try parseStringToken()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == Character(":").asciiValue! else {
                    throw canonicalError("expected colon")
                }
                index += 1
                let value = try parseValue()
                entries.append((key, value))
                skipWhitespace()
                guard index < bytes.count else { throw canonicalError("unterminated object") }
                if bytes[index] == Character(",").asciiValue! {
                    index += 1
                    continue
                }
                if bytes[index] == Character("}").asciiValue! {
                    index += 1
                    break
                }
                throw canonicalError("expected comma or brace")
            }
            entries.sort { $0.key < $1.key }
            return "{" + entries.map { "\"" + $0.key + "\":" + $0.value }.joined(separator: ",") + "}"
        }

        private mutating func parseArray() throws -> String {
            index += 1 // [
            var values: [String] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == Character("]").asciiValue! {
                index += 1
                return "[]"
            }
            while true {
                values.append(try parseValue())
                skipWhitespace()
                guard index < bytes.count else { throw canonicalError("unterminated array") }
                if bytes[index] == Character(",").asciiValue! {
                    index += 1
                    continue
                }
                if bytes[index] == Character("]").asciiValue! {
                    index += 1
                    break
                }
                throw canonicalError("expected comma or bracket")
            }
            return "[" + values.joined(separator: ",") + "]"
        }

        /// Returns the raw contents between the quotes, without re-encoding them.
        private mutating func parseStringToken() throws -> String {
            guard index < bytes.count, bytes[index] == Character("\"").asciiValue! else {
                throw canonicalError("expected string")
            }
            index += 1
            let start = index
            while index < bytes.count {
                if bytes[index] == Character("\\").asciiValue! {
                    index += 2
                    continue
                }
                if bytes[index] == Character("\"").asciiValue! {
                    let token = String(decoding: bytes[start..<index], as: UTF8.self)
                    index += 1
                    return token
                }
                index += 1
            }
            throw canonicalError("unterminated string")
        }

        private mutating func parseScalar() throws -> String {
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case Character(",").asciiValue!, Character("}").asciiValue!,
                     Character("]").asciiValue!, 0x20, 0x09, 0x0A, 0x0D:
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                default:
                    index += 1
                }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        private mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        private func canonicalError(_ detail: String) -> NSError {
            NSError(domain: "LyraReaderChecks", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "the recovery JSON could not be canonicalized: \(detail)",
            ])
        }
    }

    /// A recursive, order-sensitive JSON diff for the manifest so a failure names the first
    /// differences instead of printing two dictionaries.
    private static func manifestDifferences(
        expected: Any, actual: Any, path: String = "$"
    ) -> [String] {
        if let expected = expected as? [String: Any], let actual = actual as? [String: Any] {
            var differences: [String] = []
            for key in Set(expected.keys).union(actual.keys).sorted() {
                let expectedValue = expected[key] ?? NSNull()
                let actualValue = actual[key] ?? NSNull()
                if expected[key] == nil || actual[key] == nil {
                    differences.append("\(path).\(key) is missing")
                    continue
                }
                differences += manifestDifferences(
                    expected: expectedValue, actual: actualValue, path: "\(path).\(key)")
            }
            return differences
        }
        if let expected = expected as? [Any], let actual = actual as? [Any] {
            guard expected.count == actual.count else {
                return ["\(path) has \(expected.count) entries, expected \(actual.count)"]
            }
            var differences: [String] = []
            for index in expected.indices {
                differences += manifestDifferences(
                    expected: expected[index], actual: actual[index],
                    path: "\(path)[\(index)]")
            }
            return differences
        }
        let expectedNumber = expected as? NSNumber
        let actualNumber = actual as? NSNumber
        if let expectedNumber, let actualNumber {
            return expectedNumber == actualNumber ? [] : ["\(path): \(expected) != \(actual)"]
        }
        let expectedDescription = String(describing: expected)
        let actualDescription = String(describing: actual)
        return expectedDescription == actualDescription
            ? [] : ["\(path): \(expectedDescription) != \(actualDescription)"]
    }
}

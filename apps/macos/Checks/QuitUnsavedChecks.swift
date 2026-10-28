import AppKit
import Foundation
@testable import LyraReaderKit

extension ReaderChecks {
    /// Child half of the crash-recovery check: starts a real annotation draft and a real page-edit
    /// session in a separate process, then leaves through `_exit(9)`.
    ///
    /// A parent-process simulation cannot prove the crash guarantee: the previous `AppState` is
    /// still alive there (ARC lifetime is not a scope guarantee, and its async work may hold it),
    /// so `pageEditOwners` can still claim the session and the restore path correctly refuses to
    /// open it twice. A real crash has no such owner. This child exercises the durable files at
    /// the process boundary the product actually promises.
    ///
    /// Launched by the parent with `--quit-unsaved-crash-child <annotation-pdf> <page-pdf>
    /// <cache-root>`.
    @MainActor static func quitUnsavedCrashChild() async throws {
        guard CommandLine.arguments.count >= 5 else { exit(2) }
        let annotationFixture = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let pageFixture = URL(fileURLWithPath: CommandLine.arguments[3]).standardizedFileURL
        let cache = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
        DocumentEditCache.rootOverride = cache
        setenv("LYRA_READER_DOCUMENT_CACHE_DIR", cache.path, 1)

        let annotated = AppState(engine: try RustEngine())
        guard annotated.open(url: annotationFixture) else { exit(3) }
        guard annotated.addGeometryAnnotation(
            kind: .square, page: 0,
            shapeRect: CGRect(x: 40, y: 60, width: 30, height: 30)
        ) else { exit(4) }
        guard annotated.annotations.count == 1, annotated.annotationCacheIsDirty else { exit(5) }

        let edited = AppState(engine: try RustEngine())
        guard edited.open(url: pageFixture) else { exit(6) }
        edited.selectPage(1, extending: false, toggling: false)
        let applied = await edited.applyPageEditOperation(
            .rotate(pages: [1], quarterTurns: 1), label: "Rotate page 2")
        guard applied else { exit(7) }
        for _ in 0..<400 {
            if !edited.pageEditBusy { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard edited.pageEditPendingOperations.count == 1 else { exit(8) }
        guard FileManager.default.fileExists(
            atPath: DocumentEditCache.recoveryURL(for: pageFixture).path
        ) else { exit(10) }
        // Hard exit: no AppState deinit, no cache-owner release, no flush, no session close and no
        // clean-exit marker. This is the state a SIGKILL leaves behind.
        _exit(9)
    }

    /// Names the durable state behind a crash-recovery failure instead of leaving CI with only
    /// "no session". Includes the cache directory contents, the manifest's identity/revision/
    /// operation count, marker presence, and the restore path's own decision.
    @MainActor private static func quitCrashRecoveryDiagnostics(
        for url: URL,
        state: AppState?
    ) -> String {
        let manager = FileManager.default
        let directory = DocumentEditCache.directory(for: url)
        let files = (try? manager.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
        let manifest = DocumentEditCache.recoveryURL(for: url)
        var manifestFields = "missing session.json"
        if let data = try? Data(contentsOf: manifest),
           let object = try? JSONSerialization.jsonObject(with: data),
           let envelope = object as? [String: Any],
           let session = envelope["session"] as? [String: Any] {
            let directoryValue = session["directory"] as? String ?? "nil"
            let revisionValue = (session["revisionNumber"] as? NSNumber)?.stringValue ?? "nil"
            let operationValue = ((session["operations"] as? [Any])?.count).map(String.init) ?? "nil"
            let originalValue = session["originalURL"] as? String ?? "nil"
            manifestFields = "directory=\(directoryValue) revision=\(revisionValue)"
                + " operations=\(operationValue) originalURL=\(originalValue)"
        }
        let annotations = DocumentEditCache.annotationsURL(for: url)
        let changes = DocumentEditCache.pendingStateURL(for: url)
        return [
            "cache=\(directory.lastPathComponent)",
            "files=[\(files.joined(separator: ", "))]",
            "manifest=(\(manifestFields))",
            "marker=\(DocumentEditCache.hasCleanExitMarker(for: url))",
            "annotationsFile=\(manager.fileExists(atPath: annotations.path))",
            "changesFile=\(manager.fileExists(atPath: changes.path))",
            "liveOwner=\(AppState.hasLivePageEditOwnerForChecks(at: url))",
            "restoreTrace=\(state?.lastPageEditRestoreOutcomeForChecks ?? "not opened")",
        ].joined(separator: " · ")
    }

    /// A `require` whose failure message carries the durable state behind the assertion. The
    /// diagnostics remain unevaluated on success, so a passing suite's log stays readable.
    @MainActor private static func requireExplaining(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        _ diagnostics: @autoclosure () -> String
    ) {
        guard condition() else { fatalError("FAIL: \(message) — \(diagnostics())") }
        print("PASS: \(message)")
    }

    /// The quit-with-unsaved-changes contract.
    ///
    /// The checks drive the same `QuitUnsavedCoordinator` the app delegate uses, with the modal
    /// prompt and Save As panel replaced by closures. They prove the user-visible behaviour:
    /// Cancel changes nothing, Discard All writes the clean-exit handshake and a simulated next
    /// launch does not restore the drafts, Save All goes through the existing per-document save
    /// paths, a cancelled/failed save aborts the quit, and a crash without the handshake still
    /// recovers the drafts.
    @MainActor static func quitUnsavedChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-quit-unsaved-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        func copyFixture(_ name: String, to fileName: String) throws -> URL {
            let destination = scratch.appendingPathComponent(fileName)
            try fileManager.copyItem(
                at: root.appendingPathComponent("tests/fixtures/\(name)"), to: destination)
            return destination
        }

        func state() throws -> AppState {
            AppState(engine: try RustEngine())
        }

        func mark(_ state: AppState, note: String) {
            require(state.addGeometryAnnotation(
                kind: .square, page: 0,
                shapeRect: CGRect(x: 40, y: 60, width: 30, height: 30)),
                "a geometry annotation marks the draft dirty (\(note), lastError: \(state.lastError ?? "nil"))")
        }

        func rotatePageTwo(_ state: AppState) async {
            state.selectPage(1, extending: false, toggling: false)
            let rotated = await state.applyPageEditOperation(
                .rotate(pages: [1], quarterTurns: 1), label: "Rotate page 2")
            require(rotated,
                    "a page rotation is staged (lastError: \(state.lastError ?? "nil"))")
            require(state.pageEditPendingOperations.count == 1, "one page change is pending")
        }

        func file(_ url: URL, equals bytes: Data) -> Bool {
            (try? Data(contentsOf: url)) == bytes
        }

        let textURL = try copyFixture("text-page.pdf", to: "quit-text.pdf")
        let multipageURL = try copyFixture("multipage.pdf", to: "quit-multipage.pdf")
        let textBytes = try Data(contentsOf: textURL)
        let multipageBytes = try Data(contentsOf: multipageURL)

        // ── Cancel leaves both windows exactly as they were ────────────────────────────────
        var cancelPromptDocuments: [QuitUnsavedDocument] = []
        do {
            let windowA = try state()
            let windowB = try state()
            require(windowA.newTab(url: textURL),
                    "first window opens the text fixture (lastError: \(windowA.lastError ?? "nil"))")
            require(windowB.newTab(url: multipageURL),
                    "second window opens the multipage fixture (lastError: \(windowB.lastError ?? "nil"))")
            mark(windowA, note: "cancel window A")
            await rotatePageTwo(windowB)

            let coordinator = QuitUnsavedCoordinator(
                windows: [windowA, windowB],
                prompt: { documents in
                    cancelPromptDocuments = documents
                    return .cancel
                },
                saveDestination: { _, _ in nil },
                reporter: { _ in })

            let documents = coordinator.documents()
            require(documents.count == 2,
                    "the quit prompt covers both windows (got \(documents.count))")
            require(documents.map(\.windowIndex) == [0, 1],
                    "the prompt preserves window order")
            require(documents[0].title.contains("quit-text")
                        && documents[1].title.contains("quit-multipage"),
                    "the prompt names each document")
            require(documents[0].changeSummary.contains("annotations"),
                    "the prompt says the first document has unsaved annotations "
                        + "(\(documents[0].changeSummary))")
            require(documents[1].changeSummary.contains("page edits"),
                    "the prompt says the second document has page edits "
                        + "(\(documents[1].changeSummary))")
            require(coordinator.decision(for: documents) == .cancel,
                    "the injected prompt decision is the one acted on")
            require(cancelPromptDocuments.count == 2, "the prompt closure saw both documents")

            let mayQuit = await coordinator.resolve(.cancel, documents: documents)
            require(!mayQuit, "Cancel does not quit")
            require(windowA.hasUnsavedDocumentChanges && windowA.annotations.count == 1,
                    "Cancel keeps the first window's annotation")
            require(windowB.hasUnsavedDocumentChanges
                        && windowB.pageEditPendingOperations.count == 1,
                    "Cancel keeps the second window's page edits")
            require(file(textURL, equals: textBytes),
                    "Cancel leaves the first PDF byte-identical")
            require(file(multipageURL, equals: multipageBytes),
                    "Cancel leaves the second PDF byte-identical")
            require(!DocumentEditCache.hasCleanExitMarker(for: textURL),
                    "Cancel writes no clean-exit marker")
        }

        // ── A live in-process owner is not a crash ───────────────────────────────────────────
        // `pageEditOwners` deliberately stops a second reader in this process from opening the
        // same staged session twice. That is the branch the old in-process "crash" simulation
        // could hit when the previous AppState had not been deallocated yet (Swift does not
        // promise scope-end deallocation), which is why this suite exercises real crashes across
        // a process boundary below. Assert the guard and its diagnostic here so a future failure
        // cannot be mistaken for a missing manifest.
        let liveOwnerURL = try copyFixture("multipage.pdf", to: "quit-live-owner.pdf")
        do {
            let owner = try state()
            require(owner.newTab(url: liveOwnerURL),
                    "the live-owner fixture opens (lastError: \(owner.lastError ?? "nil"))")
            await rotatePageTwo(owner)
            let secondReader = try state()
            require(secondReader.newTab(url: liveOwnerURL),
                    "a second reader can open the document (lastError: \(secondReader.lastError ?? "nil"))")
            requireExplaining(
                !secondReader.pageEditSessionActive,
                "a second reader in the same process does not steal a live page-edit session",
                quitCrashRecoveryDiagnostics(for: liveOwnerURL, state: secondReader))
            requireExplaining(
                secondReader.lastPageEditRestoreOutcomeForChecks?
                    .contains("owned by another live AppState") == true,
                "the restore path says a live in-process owner, not a missing session",
                quitCrashRecoveryDiagnostics(for: liveOwnerURL, state: secondReader))
            owner.discardPageEdits()
            require(!DocumentEditCache.hasCleanExitMarker(for: liveOwnerURL),
                    "the live-owner probe writes no clean-exit marker")
        }

        // ── A real process crash still restores both kinds of draft ─────────────────────────
        // The Cancel scenario's AppStates are still alive in this process (and Swift does not
        // guarantee scope-end deallocation), so an in-process "crash" would leave pageEditOwners
        // claiming the session and the second reader would correctly refuse to open it. A crash
        // guarantee is about durable files, so this half stages the drafts in a child process
        // that exits through `_exit(9)`; the parent then opens only the cache the child left.
        let crashTextURL = try copyFixture("text-page.pdf", to: "quit-crash-annotations.pdf")
        let crashPageURL = try copyFixture("multipage.pdf", to: "quit-crash-pages.pdf")
        let crashTextBytes = try Data(contentsOf: crashTextURL)
        let crashPageBytes = try Data(contentsOf: crashPageURL)
        let crashChild = Process()
        crashChild.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        crashChild.arguments = [
            "--quit-unsaved-crash-child",
            crashTextURL.path,
            crashPageURL.path,
            DocumentEditCache.root.path,
        ]
        try crashChild.run()
        crashChild.waitUntilExit()
        require(crashChild.terminationStatus == 9,
                "the crash child really died without cleanup (status \(crashChild.terminationStatus))")
        require(FileManager.default.fileExists(
            atPath: DocumentEditCache.recoveryURL(for: crashPageURL).path),
                "the crashed child left its page-edit manifest on disk")
        require(!DocumentEditCache.hasCleanExitMarker(for: crashTextURL)
                    && !DocumentEditCache.hasCleanExitMarker(for: crashPageURL),
                "the crashed child wrote no clean-exit marker")

        do {
            let recoveredA = try state()
            let recoveredB = try state()
            require(recoveredA.newTab(url: crashTextURL),
                    "the crashed annotation draft reopens (lastError: \(recoveredA.lastError ?? "nil"))")
            require(recoveredB.newTab(url: crashPageURL),
                    "the crashed page-edit document reopens (lastError: \(recoveredB.lastError ?? "nil"))")
            requireExplaining(
                recoveredA.annotations.count == 1 && recoveredA.annotationCacheIsDirty,
                "a crash without a quit handshake still restores the annotation draft",
                quitCrashRecoveryDiagnostics(for: crashTextURL, state: recoveredA))
            requireExplaining(
                recoveredB.pageEditSessionActive
                    && recoveredB.pageEditPendingOperations.count == 1,
                "a crash without a quit handshake still restores the page-edit session",
                quitCrashRecoveryDiagnostics(for: crashPageURL, state: recoveredB))
            require(!DocumentEditCache.hasCleanExitMarker(for: crashTextURL)
                        && !DocumentEditCache.hasCleanExitMarker(for: crashPageURL),
                    "recovery alone writes no clean-exit marker")

            // ── Discard All writes the handshake, and a simulated next launch stays clean ────
            let coordinator = QuitUnsavedCoordinator(
                windows: [recoveredA, recoveredB],
                prompt: { _ in .discardAll },
                saveDestination: { _, _ in nil },
                reporter: { message in fatalError("Discard All reported: \(message)") })
            let documents = coordinator.documents()
            require(documents.count == 2, "both recovered documents are still unsaved")
            let mayQuit = await coordinator.resolve(.discardAll, documents: documents)
            require(mayQuit, "Discard All may quit")
            require(DocumentEditCache.hasCleanExitMarker(for: crashTextURL),
                    "Discard All records a clean-exit marker for the first document")
            require(DocumentEditCache.hasCleanExitMarker(for: crashPageURL),
                    "Discard All records a clean-exit marker for the second document")
            // AppKit flushes every window once more in `applicationWillTerminate`. That flush
            // rewrites `session.json` and `changes.json`; the handshake must survive it, so do it
            // here before the simulated next launch.
            recoveredA.flushPendingWrites()
            recoveredB.flushPendingWrites()
            require(DocumentEditCache.hasCleanExitMarker(for: crashPageURL),
                    "the termination flush leaves the clean-exit marker in place")
        }
        try await Task.sleep(for: .milliseconds(80))

        // ── The next launch consumes the markers: no draft, but the PDFs are untouched ───────
        do {
            let nextA = try state()
            let nextB = try state()
            require(nextA.newTab(url: crashTextURL),
                    "the first document opens after a discarded quit (lastError: \(nextA.lastError ?? "nil"))")
            require(nextB.newTab(url: crashPageURL),
                    "the second document opens after a discarded quit (lastError: \(nextB.lastError ?? "nil"))")
            require(nextA.annotations.isEmpty && nextA.bookmarks.isEmpty,
                    "the next launch does not restore discarded annotations")
            require(!nextA.annotationCacheIsDirty,
                    "a discarded annotation cache does not mark the tab dirty")
            require(!nextB.pageEditSessionActive && nextB.pageEditPendingOperations.isEmpty,
                    "the next launch does not restore a discarded page-edit session")
            require(file(crashTextURL, equals: crashTextBytes),
                    "discarding never writes the first PDF")
            require(file(crashPageURL, equals: crashPageBytes),
                    "discarding never writes the second PDF")
            require(!DocumentEditCache.hasCleanExitMarker(for: crashTextURL),
                    "the first consumed marker is cleared")
            require(!DocumentEditCache.hasCleanExitMarker(for: crashPageURL),
                    "the second consumed marker is cleared")
        }
        try await Task.sleep(for: .milliseconds(80))

        // ── Save All: existing save paths, then a clean next launch ─────────────────────────
        let saveTextURL = try copyFixture("text-page.pdf", to: "quit-save-text.pdf")
        let savePageURL = try copyFixture("multipage.pdf", to: "quit-save-multipage.pdf")
        let saveTextBytes = try Data(contentsOf: saveTextURL)
        do {
            let windowA = try state()
            let windowB = try state()
            require(windowA.newTab(url: saveTextURL),
                    "the Save All fixture opens (lastError: \(windowA.lastError ?? "nil"))")
            require(windowB.newTab(url: savePageURL),
                    "the second Save All fixture opens (lastError: \(windowB.lastError ?? "nil"))")
            mark(windowA, note: "save window A")
            await rotatePageTwo(windowB)
            require(windowA.hasUnsavedDocumentChanges && windowB.hasUnsavedDocumentChanges,
                    "both documents are dirty before Save All")

            let coordinator = QuitUnsavedCoordinator(
                windows: [windowA, windowB],
                prompt: { _ in .saveAll },
                saveDestination: { _, _ in nil },
                reporter: { message in fatalError("Save All reported: \(message)") })
            let mayQuit = await coordinator.resolve(.saveAll, documents: coordinator.documents())
            require(mayQuit, "Save All may quit")
            require(!windowA.hasUnsavedDocumentChanges,
                    "Save All clears the saved annotation state in the first window")
            require(!windowB.hasUnsavedDocumentChanges,
                    "Save All clears the saved page-edit state in the second window")
            require(!file(saveTextURL, equals: saveTextBytes),
                    "Save All writes the first document through the in-place save path")
            require(DocumentEditCache.hasCleanExitMarker(for: saveTextURL),
                    "Save All records the clean-exit marker for the first document")
            require(DocumentEditCache.hasCleanExitMarker(for: savePageURL),
                    "Save All records the clean-exit marker for the second document")
        }
        try await Task.sleep(for: .milliseconds(80))

        do {
            let nextA = try state()
            let nextB = try state()
            require(nextA.newTab(url: saveTextURL),
                    "the first saved document reopens (lastError: \(nextA.lastError ?? "nil"))")
            require(nextB.newTab(url: savePageURL),
                    "the second saved document reopens (lastError: \(nextB.lastError ?? "nil"))")
            require(nextA.annotations.isEmpty && !nextA.annotationCacheIsDirty,
                    "the next launch does not restore a saved draft")
            require(!nextB.pageEditSessionActive && nextB.pageEditPendingOperations.isEmpty,
                    "the next launch does not restore a saved page-edit session")
            try await eventually("the saved annotation is read from the PDF itself", {
                !nextA.documentAnnotations.isEmpty
            })
            let reopenedProbe = try RustEngine()
            _ = try reopenedProbe.openDocument(at: savePageURL)
            let rotations = try await reopenedProbe.pageRotations()
            require(rotations == [0, 1, 0],
                    "Save All's page edit really reached the second PDF")
            require(!DocumentEditCache.hasCleanExitMarker(for: saveTextURL),
                    "the saved first marker is cleared on the next launch")
            require(!DocumentEditCache.hasCleanExitMarker(for: savePageURL),
                    "the saved second marker is cleared on the next launch")
        }
        try await Task.sleep(for: .milliseconds(80))

        // ── Two dirty tabs in one window: the retained tab is saved too ─────────────────────
        let tabAURL = try copyFixture("text-page.pdf", to: "quit-tabs-a.pdf")
        let tabBURL = try copyFixture("multipage.pdf", to: "quit-tabs-b.pdf")
        let tabABytes = try Data(contentsOf: tabAURL)
        let tabBBytes = try Data(contentsOf: tabBURL)
        do {
            let state = try state()
            require(state.newTab(url: tabAURL),
                    "the first tab of the pair opens (lastError: \(state.lastError ?? "nil"))")
            mark(state, note: "retained tab")
            require(state.newTab(url: tabBURL),
                    "the second tab of the pair opens (lastError: \(state.lastError ?? "nil"))")
            mark(state, note: "active tab")
            require(state.tabs.count == 2 && state.tabHasUnsavedChanges(0)
                        && state.tabHasUnsavedChanges(1),
                    "both tabs are dirty, one retained and one active")
            let coordinator = QuitUnsavedCoordinator(
                windows: [state],
                prompt: { _ in .saveAll },
                saveDestination: { _, _ in nil },
                reporter: { message in fatalError("tab Save All reported: \(message)") })
            let documents = coordinator.documents()
            require(documents.count == 2,
                    "the prompt covers the retained tab and the active tab (got \(documents.count))")
            require(documents.contains { $0.title.contains("quit-tabs-a") },
                    "the retained tab is named in the quit prompt")
            let mayQuit = await coordinator.resolve(.saveAll, documents: documents)
            require(mayQuit, "Save All saves both tabs of one window")
            require(!state.tabs.indices.contains { state.tabHasUnsavedChanges($0) },
                    "neither tab is dirty after Save All")
            require(!file(tabAURL, equals: tabABytes) && !file(tabBURL, equals: tabBBytes),
                    "both tab PDFs received their saved annotations")
            require(DocumentEditCache.hasCleanExitMarker(for: tabAURL)
                        && DocumentEditCache.hasCleanExitMarker(for: tabBURL),
                    "Save All records a marker for each tab")
        }
        try await Task.sleep(for: .milliseconds(80))

        do {
            let next = try state()
            require(next.newTab(url: tabAURL),
                    "the retained tab's document reopens (lastError: \(next.lastError ?? "nil"))")
            require(next.annotations.isEmpty && !next.annotationCacheIsDirty,
                    "the next launch does not restore the retained tab's draft")
            let other = try state()
            require(other.newTab(url: tabBURL),
                    "the active tab's document reopens (lastError: \(other.lastError ?? "nil"))")
            require(other.annotations.isEmpty && !other.annotationCacheIsDirty,
                    "the next launch does not restore the active tab's draft")
        }
        try await Task.sleep(for: .milliseconds(80))

        // ── A cancelled Save As aborts the quit and keeps recovery available ───────────────
        let signedURL = try copyFixture("signed-signature.pdf", to: "quit-signed.pdf")
        let signedBytes = try Data(contentsOf: signedURL)
        do {
            let signed = try state()
            require(signed.newTab(url: signedURL),
                    "the signed fixture opens (lastError: \(signed.lastError ?? "nil"))")
            mark(signed, note: "signed draft")
            require(signed.isReadOnlyDocument,
                    "the signed fixture is read-only in place")
            let coordinator = QuitUnsavedCoordinator(
                windows: [signed],
                prompt: { _ in .saveAll },
                saveDestination: { _, _ in nil },
                reporter: { _ in })
            let documents = coordinator.documents()
            require(documents.count == 1 && documents[0].isReadOnly,
                    "the prompt marks the signed document as read-only")
            let mayQuit = await coordinator.resolve(.saveAll, documents: documents)
            require(!mayQuit, "cancelling Save As aborts the quit")
            require(signed.hasUnsavedDocumentChanges,
                    "the cancelled Save As leaves the signed draft in place")
            require(file(signedURL, equals: signedBytes),
                    "the cancelled Save As never writes the signed original")
            require(!DocumentEditCache.hasCleanExitMarker(for: signedURL),
                    "an aborted quit writes no clean-exit marker")
        }
        try await Task.sleep(for: .milliseconds(80))

        do {
            let recovered = try state()
            require(recovered.newTab(url: signedURL),
                    "the signed draft reopens after the aborted quit (lastError: \(recovered.lastError ?? "nil"))")
            require(recovered.annotations.count == 1 && recovered.annotationCacheIsDirty,
                    "an aborted quit leaves the draft recoverable")
        }
        try await Task.sleep(for: .milliseconds(80))

        // ── Save As writes a real copy and the next launch of the original is clean ────────
        let signedCopy = scratch.appendingPathComponent("quit-signed-copy.pdf")
        do {
            let signed = try state()
            require(signed.newTab(url: signedURL),
                    "the signed fixture reopens for Save As (lastError: \(signed.lastError ?? "nil"))")
            mark(signed, note: "signed copy draft")
            let coordinator = QuitUnsavedCoordinator(
                windows: [signed],
                prompt: { _ in .saveAll },
                saveDestination: { _, _ in signedCopy },
                reporter: { message in fatalError("Save As reported: \(message)") })
            let mayQuit = await coordinator.resolve(.saveAll, documents: coordinator.documents())
            require(mayQuit, "Save All completes through the Save As path")
            require(fileManager.fileExists(atPath: signedCopy.path),
                    "Save As writes the copy")
            require(file(signedURL, equals: signedBytes),
                    "Save As never modifies the signed original")
            require(DocumentEditCache.hasCleanExitMarker(for: signedURL),
                    "Save As records the clean-exit marker for the original")
        }
        try await Task.sleep(for: .milliseconds(80))

        do {
            let next = try state()
            require(next.newTab(url: signedURL),
                    "the signed original opens after Save As (lastError: \(next.lastError ?? "nil"))")
            require(next.annotations.isEmpty && !next.annotationCacheIsDirty,
                    "the next launch does not restore drafts saved to a copy")
            require(!DocumentEditCache.hasCleanExitMarker(for: signedURL),
                    "the Save As marker is cleared on the next launch")
            let copy = try state()
            require(copy.newTab(url: signedCopy),
                    "the saved copy opens (lastError: \(copy.lastError ?? "nil"))")
            try await eventually("the copy carries the annotation in its own PDF", {
                !copy.documentAnnotations.isEmpty
            })
        }

        // ── New work after a marker invalidates it ─────────────────────────────────────────
        // This is the aborted-quit case: a marker exists, but the process did not exit and the
        // reader kept editing. The next launch must recover the new work, not resolve it away.
        let staleURL = try copyFixture("text-page.pdf", to: "quit-stale.pdf")
        do {
            let state = try state()
            require(state.newTab(url: staleURL),
                    "the stale-marker fixture opens (lastError: \(state.lastError ?? "nil"))")
            mark(state, note: "before marker")
            let coordinator = QuitUnsavedCoordinator(
                windows: [state],
                prompt: { _ in .discardAll },
                saveDestination: { _, _ in nil },
                reporter: { message in fatalError("stale-marker Discard reported: \(message)") })
            let mayQuit = await coordinator.resolve(.discardAll, documents: coordinator.documents())
            require(mayQuit, "the stale-marker decision may quit")
            require(DocumentEditCache.hasCleanExitMarker(for: staleURL),
                    "the stale-marker fixture has a marker")
            // The quit aborted and the reader kept working: the new annotation rewrites
            // changes.json after the marker.
            mark(state, note: "after marker")
            require(state.annotations.count == 2,
                    "both annotations are in the in-memory cache")
        }
        try await Task.sleep(for: .milliseconds(80))

        do {
            let next = try state()
            require(next.newTab(url: staleURL),
                    "the stale-marker document reopens (lastError: \(next.lastError ?? "nil"))")
            require(next.annotations.count == 2 && next.annotationCacheIsDirty,
                    "work created after the marker is recovered instead of resolved away")
            require(!DocumentEditCache.hasCleanExitMarker(for: staleURL),
                    "the stale marker is removed so the recovered work stays intact")
        }

        // ── The prompt copy names the count and does not promise a silent restore ──────────
        let promptTitle = UnsavedChangesPrompt.quitTitle(count: 2)
        require(promptTitle.contains("2 documents"),
                "the quit title names how many documents are affected (\(promptTitle))")
        let message = UnsavedChangesPrompt.quitMessage(documents: [
            QuitUnsavedDocument(
                id: UUID(), windowIndex: 0, title: "One.pdf",
                documentURL: URL(fileURLWithPath: "/tmp/one.pdf"),
                isReadOnly: false, changeSummary: "annotations"),
            QuitUnsavedDocument(
                id: UUID(), windowIndex: 1, title: "Two.pdf",
                documentURL: URL(fileURLWithPath: "/tmp/two.pdf"),
                isReadOnly: true, changeSummary: "page edits"),
        ])
        require(message.contains("One.pdf") && message.contains("Two.pdf"),
                "the quit message names the affected documents")
        require(message.contains("Read-only documents are written to a copy"),
                "the quit message explains the signed-original copy path")
        require(message.contains("not be restored"),
                "the quit message says the drafts will not come back on the next launch")

        print("PASS: quit with unsaved changes keeps Cancel lossless, writes the clean-exit "
            + "handshake on Save/Discard, saves through the existing paths, aborts on a "
            + "cancelled Save As, and still recovers drafts after a crash.")
    }
}

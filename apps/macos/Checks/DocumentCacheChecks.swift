import AppKit
import Foundation
import PDFKit
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func documentCacheChecks(root: URL) async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("lyra-cache-check-\(UUID())")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let oldRoot = DocumentEditCache.rootOverride
        DocumentEditCache.rootOverride = scratch.appendingPathComponent("cache")
        defer { DocumentEditCache.rootOverride = oldRoot; try? fm.removeItem(at: scratch) }

        func fixture(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try fm.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: url)
            return url
        }
        /// Names used by the retired companion layout. Nothing reads or writes them now; the
        /// checks use them only to prove that old files beside a PDF are ignored.
        func retiredCompanions(of document: URL) -> [URL] {
            [document.appendingPathExtension("lyra-reader-annotations.json"),
             document.appendingPathExtension("aris-annotations.json")]
        }
        let cleanTab = try fixture("clean-tab.pdf")
        let otherTab = try fixture("other-tab.pdf")
        let tracked = AppState(engine: try RustEngine())
        tracked.setViewportSize(CGSize(width: 1000, height: 800))
        require(tracked.newTab(url: cleanTab), "the saved-state check opens a clean tab")
        require(tracked.addGeometryAnnotation(kind: .square, page: 0,
            shapeRect: CGRect(x: 40, y: 60, width: 30, height: 30)), "the first tab gains a pending mark")
        require(tracked.newTab(url: otherTab) && tracked.tabHasUnsavedChanges(0),
                "the inactive tab retains its pending-change indicator")
        tracked.selectTab(0)
        tracked.undo()
        require(!tracked.tabHasUnsavedChanges(0), "returning to a tab retains its saved baseline for Undo")
        tracked.selectTab(1)
        require(!tracked.tabHasUnsavedChanges(0), "the now-clean inactive tab stays clean")

        let source = try fixture("paper.pdf")
        let original = try Data(contentsOf: source)
        let mark = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "Keep this evidence", createdAt: Date())
        let bookmark = Bookmark(page: 0, title: "Research question", yPt: 30)
        let records = try AnnotationRecords.encode(annotations: [mark], bookmarks: [bookmark],
            slots: [.annotation(mark.id), .bookmark(bookmark.id)])
        let cachedRecords = DocumentEditCache.annotationsURL(for: source)
        try records.write(to: cachedRecords)
        weak var previousOwner: AppState?
        do {
        let state = AppState(engine: try RustEngine())
        previousOwner = state
        state.setViewportSize(CGSize(width: 1000, height: 800))
        require(state.open(url: source), "the cached fixture opens")
        require(state.annotations == [mark] && state.bookmarks == [bookmark],
                "cached annotations and bookmarks load without changes")
        require(cachedRecords.path.hasPrefix(scratch.appendingPathComponent("cache").path),
                "records live in the application cache")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: source.path)
        try DocumentEditCache.validateSource(for: source)
        require(true, "touching an unchanged PDF does not invalidate recovery data")
        state.toggleContentEditing()
        await state.reloadContentObjects()
        guard let text = state.contentEditPage?.items.first(where: { $0.can_edit_text }) else {
            fatalError("Editable text missing")
        }
        state.replaceContentText(text, text: "Cached edit", font: "Helvetica", size: text.size)
        try await eventually("body editing succeeds with unsaved marks on the same page") {
            state.pageEditPendingOperations.count == 1 && !state.contentCommandInFlight
        }
        require(state.contentTextRecovery == nil, "unsaved annotations do not force a separate export")
        require((try? Data(contentsOf: source)) == original, "cached editing preserves the original until Save")
        require(PDFDocument(url: state.document!.url!)?.page(at: 0)?.annotations.count == 1,
                "the working PDF carries the highlight as page geometry")
        state.undo()
        try await eventually("undo restores the text and cached marks together") {
            state.pageEditPendingOperations.isEmpty && !state.pageEditBusy && state.annotations == [mark]
        }
        state.redo()
        try await eventually("redo restores the combined PDF revision") {
            state.pageEditPendingOperations.count == 1 && !state.pageEditBusy
        }
        state.flushPendingWrites()
        }
        try await eventually("the interrupted editing owner has been released") { previousOwner == nil }
        let resumed = AppState(engine: try RustEngine())
        resumed.setViewportSize(CGSize(width: 1000, height: 800))
        require(resumed.open(url: source), "the original reopens after an interrupted session")
        require(resumed.pageEditSessionActive && resumed.pageEditPendingOperations.count == 1,
                "the application cache restores unsaved PDF revisions")
        require(PDFDocument(url: resumed.document!.url!)?.string?.contains("Cached edit") == true,
                "recovery restores the actual edited text")
        let saved = await resumed.saveDocumentToOriginal()
        require(saved, "Save writes the cached document to its original path: \(resumed.lastError ?? "")")
        let published = PDFDocument(url: source)
        require(published?.string?.contains("Cached edit") == true, "the original now contains the edited body text")
        require(published?.page(at: 0)?.annotations.count == 1, "Save embeds the annotation exactly once")
        require(!resumed.pageEditSessionActive, "successful Save retires the working session")
        require(!fm.fileExists(atPath: DocumentEditCache.recoveryURL(for: source).path), "successful Save retires the recovery manifest")
        require(retiredCompanions(of: source).allSatisfy { !fm.fileExists(atPath: $0.path) },
                "saving creates no file beside the PDF")
        try await eventually("saved bookmarks reload from the PDF outline") { resumed.bookmarks.count == 1 }
        require(!resumed.annotationCacheIsDirty, "embedded bookmarks do not mark a saved document dirty")
        require(resumed.addGeometryAnnotation(kind: .square, page: 0,
            shapeRect: CGRect(x: 40, y: 60, width: 30, height: 30)),
            "a saved bookmark document accepts an undoable mark")
        require(resumed.hasUnsavedDocumentChanges, "a mark differs from the saved bookmark baseline")
        resumed.undo()
        require(!resumed.hasUnsavedDocumentChanges && resumed.bookmarks.count == 1,
                "undo returns to clean even when the PDF already contains a bookmark")
        resumed.redo()
        let recoveredMarks = AppState(engine: try RustEngine())
        require(recoveredMarks.open(url: source) && recoveredMarks.annotationCacheIsDirty,
                "reopening retains an unsaved annotation and its dirty status")
        for annotation in recoveredMarks.annotations { recoveredMarks.removeAnnotation(annotation.id) }
        require(!recoveredMarks.hasUnsavedDocumentChanges,
                "the persisted saved baseline recognizes restored PDF contents after reopening")

        // ── A retired companion beside a PDF is ignored, not imported ────────────────────
        let stale = try fixture("stale-companion.pdf")
        let staleMark = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[1].color, note: "retired companion mark", createdAt: Date())
        let staleBookmark = Bookmark(page: 0, title: "retired companion bookmark", yPt: 12)
        let staleRecords = try AnnotationRecords.encode(annotations: [staleMark],
            bookmarks: [staleBookmark],
            slots: [.annotation(staleMark.id), .bookmark(staleBookmark.id)])
        let staleCompanions = retiredCompanions(of: stale)
        try staleRecords.write(to: staleCompanions[0])
        let corruptCompanion = Data("{invalid retired companion".utf8)
        try corruptCompanion.write(to: staleCompanions[1])
        let staleState = AppState(engine: try RustEngine())
        staleState.setViewportSize(CGSize(width: 1000, height: 800))
        require(staleState.open(url: stale), "a PDF beside retired companions still opens")
        require(staleState.annotations.isEmpty && staleState.bookmarks.isEmpty,
                "a retired companion is not imported")
        require(!staleState.canRecoverUnreadableAnnotationRecords && staleState.lastError == nil,
                "an unreadable retired companion raises no recovery alert")
        require(staleState.addGeometryAnnotation(kind: .square, page: 0,
            shapeRect: CGRect(x: 20, y: 20, width: 20, height: 20)),
            "the ignored-companion document accepts a mark")
        staleState.flushPendingWrites()
        try await eventually("the ignored-companion document writes its own cache", {
            staleState.annotationWriteCount >= 1
        })
        require(staleState.annotations.count == 1, "the new mark is kept in memory")
        require((try? Data(contentsOf: staleCompanions[0])) == staleRecords,
                "a retired companion is never written back into")
        require((try? Data(contentsOf: staleCompanions[1])) == corruptCompanion,
                "the unreadable retired companion is left byte-identical")
        let staleCacheFiles = try fm.contentsOfDirectory(
            at: DocumentEditCache.directory(for: stale), includingPropertiesForKeys: nil)
        require(staleCacheFiles.contains { $0.lastPathComponent == "annotations.json" },
                "the mark is written to the current document cache")
        require(!staleCacheFiles.contains { $0.lastPathComponent.hasPrefix("import-") },
                "no legacy-import backup is created")

        let conflict = try fixture("external.pdf")
        let editing = AppState(engine: try RustEngine())
        editing.setViewportSize(CGSize(width: 1000, height: 800))
        editing.open(url: conflict)
        editing.toggleContentEditing()
        await editing.reloadContentObjects()
        let block = editing.contentEditPage!.items.first(where: { $0.can_edit_text })!
        editing.replaceContentText(block, text: "Pending", font: "Helvetica", size: block.size)
        try await eventually("external-change fixture has a cached edit") {
            editing.pageEditPendingOperations.count == 1 && !editing.contentCommandInFlight
        }
        var external = try Data(contentsOf: conflict)
        external.append(Data("\n% changed externally\n".utf8))
        try external.write(to: conflict, options: .atomic)
        let refused = await editing.saveDocumentToOriginal()
        require(!refused && (try? Data(contentsOf: conflict)) == external,
                "Save refuses an externally changed original without overwriting it")
        require(fm.fileExists(atPath: DocumentEditCache.recoveryURL(for: conflict).path),
                "a refused save preserves the editing recovery data")

        let invalid = try fixture("corrupt.pdf")
        let invalidRecords = DocumentEditCache.annotationsURL(for: invalid)
        let corrupt = Data("{invalid current annotation records".utf8)
        try corrupt.write(to: invalidRecords)
        let protected = AppState(engine: try RustEngine())
        protected.open(url: invalid)
        require(protected.annotations.isEmpty, "a corrupt current cache shows no annotations")
        require(protected.canRecoverUnreadableAnnotationRecords
                    && protected.lastError?.hasPrefix("Could not restore annotations; recovery data was kept") == true
                    && (try? Data(contentsOf: invalidRecords)) == corrupt,
                "a corrupt current cache raises the kept-data alert, blocks writes and is not replaced")
        let pendingCorrupt = Data("{invalid pending deletions".utf8)
        try pendingCorrupt.write(to: DocumentEditCache.pendingStateURL(for: invalid))
        let backup = protected.recoverUnreadableAnnotationRecords()
        require(backup != nil && (try? Data(contentsOf: backup!)) == corrupt,
                "explicit recovery keeps the original unreadable annotation bytes")
        let recoveryFiles = try fm.contentsOfDirectory(at: DocumentEditCache.directory(for: invalid), includingPropertiesForKeys: nil)
        require(recoveryFiles.contains { (try? Data(contentsOf: $0)) == pendingCorrupt },
                "explicit recovery also preserves unreadable pending deletion metadata")
        require(!protected.canRecoverUnreadableAnnotationRecords && protected.annotations.isEmpty,
                "verified backup permits a fresh annotation cache")

        // ── A readable cache whose PDF identity moved is not a corrupt cache ──
        //
        // This is the shape of the reported failing cache: `annotations.json` is a valid empty
        // array, `changes.json` is clean, and `source.json` records a different revision of the
        // same path (the sample PDF was replaced after the cache was made). The records decode,
        // so the app must not claim they could not be restored or block new annotations; with
        // nothing cached yet it adopts the current bytes as the document's identity.
        func writeStaleSource(_ document: URL) throws {
            let stamp: [String: Any] = [
                "size": 1,
                "modified": 0.0,
                "sha256": String(repeating: "0", count: 64),
            ]
            try JSONSerialization.data(withJSONObject: stamp).write(
                to: DocumentEditCache.directory(for: document).appendingPathComponent("source.json"))
        }
        let movedSource = try fixture("stale-source.pdf")
        try Data("[]".utf8).write(to: DocumentEditCache.annotationsURL(for: movedSource))
        try Data(#"{"erasedInk":[],"deletions":[],"dirty":false}"#.utf8)
            .write(to: DocumentEditCache.pendingStateURL(for: movedSource))
        try writeStaleSource(movedSource)
        let movedSourceState = AppState(engine: try RustEngine())
        movedSourceState.setViewportSize(CGSize(width: 1000, height: 800))
        require(movedSourceState.open(url: movedSource), "a readable cache with a stale source stamp opens")
        require(movedSourceState.annotations.isEmpty && movedSourceState.lastError == nil
                    && !movedSourceState.canRecoverUnreadableAnnotationRecords,
                "a readable empty cache with a stale stamp shows no recovery alert")
        require(movedSourceState.addGeometryAnnotation(kind: .square, page: 0,
            shapeRect: CGRect(x: 40, y: 60, width: 30, height: 30)),
                "a readable cache with a stale stamp accepts an annotation")
        try DocumentEditCache.validateSource(for: movedSource)
        require(true, "adopting the current identity makes later in-place saves possible")

        // One unknown-extra record beside a known one must load, round-trip verbatim, and not
        // stop new annotations from being written.
        let future = try fixture("future-record.pdf")
        let known = AppState.Annotation(id: UUID(), page: 0, start: 0, end: 3,
            color: AppState.highlightPalette[0].color, note: "known", createdAt: Date())
        let futureEncoder = JSONEncoder()
        futureEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let knownArray = String(decoding: try futureEncoder.encode([known]), as: UTF8.self)
        let knownBody = String(knownArray.dropFirst(2).dropLast(2))
        let foreignEntry = """
{
  "extraLayer" : {
    "version" : 7
  },
  "id" : "\(UUID().uuidString)",
  "kind" : "futureMark",
  "page" : 0,
  "strokeWidth" : 3
}
"""
        try Data("[\n\(knownBody),\n\(foreignEntry)\n]".utf8)
            .write(to: DocumentEditCache.annotationsURL(for: future))
        let futureState = AppState(engine: try RustEngine())
        futureState.setViewportSize(CGSize(width: 1000, height: 800))
        require(futureState.open(url: future), "a cache with an unknown-extra record opens")
        require(futureState.annotations.count == 1 && futureState.preservedAnnotationEntryCount == 1,
                "the unknown-extra record is preserved beside the known entry, not fatal")
        require(futureState.addGeometryAnnotation(kind: .circle, page: 0,
            shapeRect: CGRect(x: 60, y: 80, width: 24, height: 24)),
                "a cache with an unknown-extra record accepts a new annotation")
        let rewritten = String(decoding: try Data(
            contentsOf: DocumentEditCache.annotationsURL(for: future)), as: UTF8.self)
        require(rewritten.contains(foreignEntry),
                "the unknown-extra record is written back byte-for-byte")
        require(rewritten.contains(known.id.uuidString), "the known record is still written")

        // A changed PDF with cached work still loads that work and offers the explicit backup
        // action, but the document's own bytes are never replaced by the stale cache.
        let changed = try fixture("changed-source.pdf")
        try futureEncoder.encode([known]).write(to: DocumentEditCache.annotationsURL(for: changed))
        try writeStaleSource(changed)
        let changedState = AppState(engine: try RustEngine())
        changedState.setViewportSize(CGSize(width: 1000, height: 800))
        require(changedState.open(url: changed), "a changed PDF with cached annotations opens")
        require(changedState.annotations == [known] && changedState.lastError != nil
                    && changedState.canRecoverUnreadableAnnotationRecords,
                "a changed PDF keeps readable annotations and offers backup-and-start-fresh")
        require(changedState.lastError?.contains("PDF changed outside LyraReader") == true,
                "the changed-PDF alert names the source change")
        require(changedState.addGeometryAnnotation(kind: .square, page: 0,
            shapeRect: CGRect(x: 20, y: 30, width: 20, height: 20)),
                "a changed PDF still accepts cached annotation edits")
        let before = try Data(contentsOf: changed)
        let replaced = await changedState.saveDocumentToOriginal()
        require(!replaced && (try? Data(contentsOf: changed)) == before,
                "a changed PDF refuses an in-place save and keeps the original bytes")
        let sourceBackup = changedState.recoverUnreadableAnnotationRecords()
        require(sourceBackup != nil, "the changed-PDF alert's backup action runs")
        require(changedState.addGeometryAnnotation(kind: .circle, page: 0,
            shapeRect: CGRect(x: 25, y: 35, width: 20, height: 20)),
                "backing up a changed-PDF cache starts a fresh writable identity")

        // A truly truncated cache is still corruption: the alert names the byte, writes are
        // refused, the bytes are untouched, and only the explicit backup clears the block.
        let truncated = try fixture("truncated.pdf")
        let truncatedBytes = Data(
            #"[{"id":"\#(UUID().uuidString)","kind":"highlight","page":0,"start":0,"end":1"#.utf8)
        try truncatedBytes.write(to: DocumentEditCache.annotationsURL(for: truncated))
        let truncatedState = AppState(engine: try RustEngine())
        truncatedState.setViewportSize(CGSize(width: 1000, height: 800))
        require(truncatedState.open(url: truncated), "a document with a truncated cache still opens")
        require(truncatedState.annotations.isEmpty && truncatedState.canRecoverUnreadableAnnotationRecords,
                "a truncated cache shows the recovery alert")
        require(truncatedState.lastError?.contains("byte") == true,
                "the recovery alert names the corrupt byte")
        require(!truncatedState.addGeometryAnnotation(kind: .square, page: 0,
            shapeRect: CGRect(x: 10, y: 20, width: 30, height: 30)),
                "a truncated cache refuses writes")
        require((try? Data(contentsOf: DocumentEditCache.annotationsURL(for: truncated))) == truncatedBytes,
                "a refused write leaves the truncated bytes untouched")
        let truncatedBackup = truncatedState.recoverUnreadableAnnotationRecords()
        require(truncatedBackup != nil
                    && (try? Data(contentsOf: truncatedBackup!)) == truncatedBytes,
                "explicit recovery backs up the truncated bytes exactly")
        require(truncatedState.addGeometryAnnotation(kind: .square, page: 0,
            shapeRect: CGRect(x: 10, y: 20, width: 30, height: 30)),
                "explicit recovery permits a fresh annotation")

        // The old path-hash layout's page-edit session must be retargeted, not copied verbatim.
        try await legacyRecoveryMigrationChecks(root: root)
        print("Document cache checks passed")
    }
}

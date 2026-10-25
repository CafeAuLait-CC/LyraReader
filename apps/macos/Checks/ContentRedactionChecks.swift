import AppKit
import Foundation
import LyraReaderKit

extension ReaderChecks {
    /// T3.12 redaction through the one remaining path: the Edit workspace.
    ///
    /// The reading view no longer owns a redaction mode. Blackout and Erase are content
    /// commands: each drag stages a new working revision through `edit_content` →
    /// `stage_content_redaction`, and only Edit's own Save Copy / Replace Original publish it.
    /// This check drives the real `AppState` and `RustEngine`, so it covers what the retired
    /// annotation-layer check covered exactly where the product still does it:
    ///
    /// * the covered word is removed from the page's text and the text outside the mark
    ///   survives, for both fills;
    /// * Blackout paints the mark black and Erase leaves the page white;
    /// * the source file is byte-identical while the edit is staged and after Save Copy;
    /// * a page that needs the writer's rasterisation fallback first asks, naming the pages and
    ///   stating that their text layer is gone. Cancel writes nothing; Continue stages the
    ///   fallback, after which that page has no selectable text and the other pages still do;
    /// * an ordinary text redaction never shows that prompt;
    /// * a failed redaction writes no revision and leaves the previous revision intact.
    ///
    /// The engine-side report is also pinned in `redaction.rs`
    /// (`a_page_with_form_text_is_rasterised_and_loses_its_whole_text_layer`); this check covers
    /// the Edit workspace's decision around it.
    @MainActor static func contentRedactionChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-content-redaction-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("page.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: source)
        let originalBytes = try Data(contentsOf: source)

        let engine = try RustEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(CGSize(width: 1000, height: 800))
        state.newTab(url: source)
        try await eventually("the redaction fixture opens", { state.document != nil })

        // ── The menu entry opens Edit with Blackout armed ──────────────────────────────
        state.openRedactionWorkspace()
        require(state.contentEditEnabled && state.contentEditTool == "blackout",
                "Redact… opens the Edit workspace with Blackout armed")
        await state.reloadContentObjects()
        try await eventually("the redaction fixture's content objects load", {
            state.contentEditPage != nil && !state.contentEditLoading
        })

        let page = try await engine.textPage(0)
        func wordRect(_ needle: String) -> CGRect {
            let range = rangeWhile(in: page, needle: needle)
            var rect = CGRect.zero
            for character in page.chars[range] {
                let box = CGRect(
                    x: character.xPt, y: character.yPt,
                    width: character.widthPt, height: character.heightPt)
                rect = rect.isEmpty ? box : rect.union(box)
            }
            return rect.insetBy(dx: -1, dy: -1)
        }

        // ── Blackout: the covered word goes, its neighbours stay, the source is untouched ──
        let brown = wordRect("brown")
        // `Redact…` already armed Blackout; clicking the active tool again would turn it off,
        // so the tool is left as the menu set it, exactly as a reader's first drag would.
        state.redactContent(in: brown, blackout: state.contentEditTool == "blackout")
        try await eventually("the blackout is staged as a working revision", {
            state.pageEditPendingOperations.count == 1 && !state.contentCommandInFlight
                && !state.contentEditLoading && !state.pageEditBusy
        })
        require(state.document?.pageCount == 1, "the redaction keeps the page count")
        require(state.rasterRedactionPrompt == nil,
                "an ordinary text blackout needs no rasterisation confirmation")
        let afterBlackout = try Data(contentsOf: source)
        require(afterBlackout == originalBytes,
                "staging a blackout does not touch the source file")

        var stagedText = try await engine.textPage(0)
        require(!stagedText.text.contains("brown"),
                "the blackout removes the covered word from the page text")
        require(stagedText.text.contains("quick") && stagedText.text.contains("jumps"),
                "text before and after the mark survives the blackout")
        require(stagedText.text.contains("LyraReader fixture") && stagedText.text.contains("Line 6:"),
                "text outside the mark on other lines survives the blackout")

        let scale: CGFloat = 2
        let blackoutImage = try await engine.renderPage(0, scale: scale)
        let blackoutPixel = pixel(blackoutImage, atPagePoint: CGPoint(x: brown.midX, y: brown.midY))
        require(blackoutPixel.red < 40 && blackoutPixel.green < 40 && blackoutPixel.blue < 40,
                "the blackout renders as a black mark (\(blackoutPixel))")

        // ── Erase: the same transaction with the white fill ────────────────────────────
        let quick = wordRect("quick")
        state.selectContentTool("erase")
        state.redactContent(in: quick, blackout: state.contentEditTool == "blackout")
        try await eventually("the erase is staged as a second working revision", {
            state.pageEditPendingOperations.count == 2 && !state.contentCommandInFlight
                && !state.contentEditLoading && !state.pageEditBusy
        })
        require(state.rasterRedactionPrompt == nil,
                "an ordinary text erase needs no rasterisation confirmation")
        let afterErase = try Data(contentsOf: source)
        require(afterErase == originalBytes,
                "staging an erase does not touch the source file")
        stagedText = try await engine.textPage(0)
        require(!stagedText.text.contains("quick"),
                "the erase removes the covered word from the page text")
        require(stagedText.text.contains("fox") && stagedText.text.contains("jumps")
                    && stagedText.text.contains("Line 6:"),
                "text outside the erase mark survives")
        let erasedImage = try await engine.renderPage(0, scale: scale)
        let erasedPixel = pixel(erasedImage, atPagePoint: CGPoint(x: quick.midX, y: quick.midY))
        require(erasedPixel.red > 220 && erasedPixel.green > 220 && erasedPixel.blue > 220,
                "the erase leaves white paper, not a black mark (\(erasedPixel))")

        // ── A stale command fails and writes no revision ───────────────────────────────
        var stale = PDFContentCommand(action: "redact", revision: "not-the-current-revision")
        stale.bounds = PDFContentBox(CGRect(x: 10, y: 10, width: 40, height: 20))
        stale.blackout = true
        let failedOutput = scratch.appendingPathComponent("failed-redaction.pdf")
        do {
            try await engine.applyContentEdit(page: 0, command: stale, to: failedOutput)
            require(false, "a stale redaction command is refused")
        } catch {
            require(error.localizedDescription.localizedCaseInsensitiveContains("reload")
                        || error.localizedDescription.localizedCaseInsensitiveContains("changed"),
                    "the stale redaction explains that the page changed: \(error.localizedDescription)")
        }
        require(!fileManager.fileExists(atPath: failedOutput.path),
                "a failed redaction writes no output")
        require(state.pageEditPendingOperations.count == 2,
                "a failed redaction leaves the previous revision in place")

        // ── Save Copy publishes the staged edits and still leaves the source alone ─────
        let copy = scratch.appendingPathComponent("redacted-copy.pdf")
        let saved = await state.savePageEditsCopy(to: copy)
        require(saved, "the staged redactions publish through the page-edit copy save")
        let afterSave = try Data(contentsOf: source)
        require(afterSave == originalBytes,
                "the copy save leaves the source file byte-identical")
        let copyReader = try RustEngine()
        _ = try copyReader.openDocument(at: copy)
        let copyText = try await copyReader.textPage(0)
        require(!copyText.text.contains("brown") && !copyText.text.contains("quick"),
                "the saved copy does not extract either redacted word")
        require(copyText.text.contains("fox") && copyText.text.contains("Line 6:"),
                "the saved copy keeps the text outside both marks")
        let copyImage = try await copyReader.renderPage(0, scale: scale)
        let copyMark = pixel(copyImage, atPagePoint: CGPoint(x: brown.midX, y: brown.midY))
        require(copyMark.red < 40 && copyMark.green < 40 && copyMark.blue < 40,
                "the saved copy keeps the blackout mark (\(copyMark))")

        // ── A fallback redaction asks first, then writes exactly the page it named ─────
        // `form-text-pages.pdf` puts "In shared form" inside a Form XObject on page 1 and keeps
        // ordinary page-level text on page 2. The writer cannot attribute the form glyphs to a
        // page operator, so removing them safely means replacing page 1 with an image. The
        // confirmation is the only path to that write; Cancel must leave no trace at all.
        let formFixture = root.appendingPathComponent("tests/fixtures/form-text-pages.pdf")

        func textRect(in page: TextPage, needle: String) -> CGRect {
            let range = rangeWhile(in: page, needle: needle)
            var rect = CGRect.zero
            for character in page.chars[range] {
                let box = CGRect(
                    x: character.xPt, y: character.yPt,
                    width: character.widthPt, height: character.heightPt)
                rect = rect.isEmpty ? box : rect.union(box)
            }
            return rect.insetBy(dx: -3, dy: -3)
        }

        /// Opens a fresh copy of the two-page fixture and returns (state, engine, source).
        func openFormDocument(_ name: String) async throws -> (AppState, RustEngine, URL) {
            let source = scratch.appendingPathComponent(name)
            try fileManager.copyItem(at: formFixture, to: source)
            let engine = try RustEngine()
            let state = AppState(engine: engine)
            state.setViewportSize(CGSize(width: 1000, height: 800))
            state.newTab(url: source)
            try await eventually("the two-page form fixture opens", {
                state.document?.pageCount == 2
            })
            state.openRedactionWorkspace()
            await state.reloadContentObjects()
            try await eventually("the two-page form fixture's content objects load", {
                state.contentEditPage != nil && !state.contentEditLoading
            })
            return (state, engine, source)
        }

        // Cancel: the prompt names page 1 and its cost; nothing is staged or written.
        let (cancelState, cancelEngine, cancelSource) = try await openFormDocument(
            "form-text-cancel.pdf")
        let cancelBytes = try Data(contentsOf: cancelSource)
        let cancelPage = try await cancelEngine.textPage(0)
        let cancelRect = textRect(in: cancelPage, needle: "In shared form")
        let revisionBefore = cancelState.contentEditPage?.revision
        let scratchBefore = try fileManager.contentsOfDirectory(atPath: scratch.path).sorted()
        cancelState.redactContent(in: cancelRect, blackout: true)
        try await eventually("the raster fallback asks before staging", {
            cancelState.rasterRedactionPrompt != nil && !cancelState.contentCommandInFlight
        })
        let prompt = try requireUnwrap(
            cancelState.rasterRedactionPrompt, "the confirmation prompt exists")
        require(prompt.pages == [1],
                "the confirmation names page 1 as the page that becomes an image (\(prompt.pages))")
        let promptText = prompt.title + " " + prompt.message
        require(promptText.localizedCaseInsensitiveContains("page 1"),
                "the confirmation text names page 1: \(promptText)")
        require(promptText.localizedCaseInsensitiveContains("text layer"),
                "the confirmation says the text layer is gone: \(promptText)")
        require(promptText.localizedCaseInsensitiveContains("selectable")
                    && promptText.localizedCaseInsensitiveContains("searchable"),
                "the confirmation says the text is no longer selectable or searchable: \(promptText)")
        require(!cancelState.pageEditSessionActive,
                "the confirmation creates no working session")
        require(cancelState.pageEditPendingOperations.isEmpty,
                "the confirmation stages no page change")
        require(cancelState.contentEditPage?.revision == revisionBefore,
                "the confirmation leaves the current revision in place")
        let afterConfirmation = try Data(contentsOf: cancelSource)
        let confirmationFiles = try fileManager.contentsOfDirectory(atPath: scratch.path).sorted()
        require(afterConfirmation == cancelBytes,
                "the confirmation leaves the source byte-identical")
        require(confirmationFiles == scratchBefore,
                "the confirmation writes no output file")
        cancelState.cancelRasterRedaction()
        require(cancelState.rasterRedactionPrompt == nil,
                "Cancel clears the raster confirmation")
        require(!cancelState.pageEditSessionActive
                    && cancelState.pageEditPendingOperations.isEmpty,
                "Cancel leaves no session or revision")
        require(cancelState.contentEditPage?.revision == revisionBefore,
                "Cancel keeps the current revision")
        let afterCancel = try Data(contentsOf: cancelSource)
        let filesAfterCancel = try fileManager.contentsOfDirectory(atPath: scratch.path).sorted()
        require(afterCancel == cancelBytes,
                "Cancel leaves the source file untouched")
        require(filesAfterCancel == scratchBefore,
                "Cancel writes no output file")
        require(cancelState.statusMessage.localizedCaseInsensitiveContains("cancel"),
                "Cancel says the redaction wrote nothing: \(cancelState.statusMessage)")

        // Continue (Blackout): page 1 becomes an image, page 2 keeps its text.
        let (blackoutState, blackoutEngine, blackoutSource) = try await openFormDocument(
            "form-text-blackout.pdf")
        let blackoutBytes = try Data(contentsOf: blackoutSource)
        let blackoutPage = try await blackoutEngine.textPage(0)
        let blackoutRect = textRect(in: blackoutPage, needle: "In shared form")
        blackoutState.redactContent(in: blackoutRect, blackout: true)
        try await eventually("the blackout raster confirmation appears", {
            blackoutState.rasterRedactionPrompt != nil && !blackoutState.contentCommandInFlight
        })
        blackoutState.confirmRasterRedaction()
        try await eventually("the confirmed raster blackout is staged", {
            blackoutState.pageEditPendingOperations.count == 1
                && !blackoutState.contentCommandInFlight
                && !blackoutState.contentEditLoading && !blackoutState.pageEditBusy
        })
        require(blackoutState.rasterRedactionPrompt == nil,
                "Continue clears the raster confirmation")
        require(blackoutState.statusMessage.localizedCaseInsensitiveContains("page 1"),
                "the success status names the rasterised page: \(blackoutState.statusMessage)")
        require(blackoutState.statusMessage.localizedCaseInsensitiveContains("text layer"),
                "the success status repeats that the text layer is gone: \(blackoutState.statusMessage)")
        let blackoutAfterStage = try Data(contentsOf: blackoutSource)
        require(blackoutAfterStage == blackoutBytes,
                "the confirmed blackout leaves the source file untouched")
        let blackoutTargetText = try await blackoutEngine.textPage(0)
        require(blackoutTargetText.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the rasterised page has no extractable text: \(blackoutTargetText.text)")
        let blackoutOtherText = try await blackoutEngine.textPage(1)
        require(blackoutOtherText.text.contains("Page two keeps its selectable text"),
                "the page the redaction did not name keeps its text")
        let rasterBlackoutImage = try await blackoutEngine.renderPage(0, scale: scale)
        let blackoutMark = pixel(
            rasterBlackoutImage,
            atPagePoint: CGPoint(x: blackoutRect.midX, y: blackoutRect.midY))
        require(blackoutMark.red < 40 && blackoutMark.green < 40 && blackoutMark.blue < 40,
                "the rasterised blackout still paints black (\(blackoutMark))")

        let rasterCopy = scratch.appendingPathComponent("form-text-blackout-copy.pdf")
        let rasterPublished = await blackoutState.savePageEditsCopy(to: rasterCopy)
        require(rasterPublished,
                "the confirmed raster redaction publishes to a copy")
        let rasterCopyEngine = try RustEngine()
        _ = try rasterCopyEngine.openDocument(at: rasterCopy)
        let rasterCopyTarget = try await rasterCopyEngine.textPage(0)
        require(rasterCopyTarget.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the saved copy's target page has no selectable text: \(rasterCopyTarget.text)")
        let rasterCopyOther = try await rasterCopyEngine.textPage(1)
        require(rasterCopyOther.text.contains("Page two keeps its selectable text"),
                "the saved copy keeps text on the pages that were not rasterised")
        let rasterCopyImage = try await rasterCopyEngine.renderPage(0, scale: scale)
        let rasterCopyMark = pixel(
            rasterCopyImage,
            atPagePoint: CGPoint(x: blackoutRect.midX, y: blackoutRect.midY))
        require(rasterCopyMark.red < 40 && rasterCopyMark.green < 40 && rasterCopyMark.blue < 40,
                "the saved copy keeps the black mark (\(rasterCopyMark))")

        // Continue (Erase): the same fallback, with the white fill.
        let (eraseState, eraseEngine, eraseSource) = try await openFormDocument(
            "form-text-erase.pdf")
        let eraseBytes = try Data(contentsOf: eraseSource)
        let erasePage = try await eraseEngine.textPage(0)
        let eraseRect = textRect(in: erasePage, needle: "In shared form")
        eraseState.redactContent(in: eraseRect, blackout: false)
        try await eventually("the erase raster confirmation appears", {
            eraseState.rasterRedactionPrompt != nil && !eraseState.contentCommandInFlight
        })
        eraseState.confirmRasterRedaction()
        try await eventually("the confirmed raster erase is staged", {
            eraseState.pageEditPendingOperations.count == 1
                && !eraseState.contentCommandInFlight
                && !eraseState.contentEditLoading && !eraseState.pageEditBusy
        })
        let eraseAfterStage = try Data(contentsOf: eraseSource)
        require(eraseAfterStage == eraseBytes,
                "the confirmed erase leaves the source file untouched")
        let eraseTargetText = try await eraseEngine.textPage(0)
        require(eraseTargetText.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the erased page has no extractable text: \(eraseTargetText.text)")
        let eraseOtherText = try await eraseEngine.textPage(1)
        require(eraseOtherText.text.contains("Page two keeps its selectable text"),
                "the erase leaves the other page's text alone")
        let eraseImage = try await eraseEngine.renderPage(0, scale: scale)
        let eraseMark = pixel(
            eraseImage, atPagePoint: CGPoint(x: eraseRect.midX, y: eraseRect.midY))
        require(eraseMark.red > 220 && eraseMark.green > 220 && eraseMark.blue > 220,
                "the rasterised erase leaves white paper (\(eraseMark))")

        // ── A signed document keeps its read-only rule; redaction goes to a copy ───────
        // The retired reading-view path offered "Apply to Copy" directly. The Edit workspace
        // provides the same capability: it stages against the signed working copy and Save Copy
        // is the only publishing command (in-place replacement stays disabled).
        let signedSource = scratch.appendingPathComponent("signed.pdf")
        try fileManager.copyItem(
            at: root.appendingPathComponent("tests/fixtures/signed-signature.pdf"),
            to: signedSource)
        let signedBytes = try Data(contentsOf: signedSource)
        let signedEngine = try RustEngine()
        let signedState = AppState(engine: signedEngine)
        signedState.setViewportSize(CGSize(width: 1000, height: 800))
        signedState.newTab(url: signedSource)
        try await eventually("the signed fixture opens", { signedState.document != nil })
        require(signedState.isReadOnlyDocument,
                "the signed fixture is still read-only in place")
        signedState.openRedactionWorkspace()
        require(signedState.contentEditEnabled,
                "redaction is available in Edit on a signed document")
        await signedState.reloadContentObjects()
        try await eventually("the signed fixture's content objects load", {
            signedState.contentEditPage != nil && !signedState.contentEditLoading
        })
        let signedPage = try await signedEngine.textPage(0)
        let signedRange = rangeWhile(in: signedPage, needle: "Signed")
        var signedMark = CGRect.zero
        for character in signedPage.chars[signedRange] {
            let box = CGRect(
                x: character.xPt, y: character.yPt,
                width: character.widthPt, height: character.heightPt)
            signedMark = signedMark.isEmpty ? box : signedMark.union(box)
        }
        signedState.redactContent(
            in: signedMark.insetBy(dx: -1, dy: -1),
            blackout: signedState.contentEditTool == "blackout")
        try await eventually("the signed blackout is staged", {
            signedState.pageEditPendingOperations.count == 1
                && !signedState.contentCommandInFlight && !signedState.contentEditLoading
                && !signedState.pageEditBusy
        })
        require(signedState.rasterRedactionPrompt == nil,
                "the signed fixture's text redaction needs no raster confirmation")
        let signedAfterStage = try Data(contentsOf: signedSource)
        require(signedAfterStage == signedBytes,
                "staging redaction on a signed document leaves the original untouched")
        require(!signedState.canReplaceOriginalWithPageEdits,
                "the signed original still cannot receive the redaction in place")
        let signedCopy = scratch.appendingPathComponent("signed-redacted-copy.pdf")
        let published = await signedState.savePageEditsCopy(to: signedCopy)
        require(published, "the signed redaction is published to a copy")
        let signedCopyEngine = try RustEngine()
        let signedCopyDocument = try signedCopyEngine.openDocument(at: signedCopy)
        require(!signedCopyDocument.signature.signed
                    && signedCopyDocument.signature.evidence.isEmpty,
                "the redacted copy carries no signature evidence")
        let signedCopyText = try await signedCopyEngine.textPage(0)
        require(!signedCopyText.text.contains("Signed"),
                "the redacted signed copy no longer extracts the covered word")
        let signedAfterCopy = try Data(contentsOf: signedSource)
        require(signedAfterCopy == signedBytes,
                "the signed original is byte-identical after the copy")

        print("Content redaction checks passed")
    }

    /// The pixel at a page-local point in a rendered page, as sRGB bytes.
    @MainActor static func pixel(
        _ image: PageImage,
        atPagePoint point: CGPoint
    ) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let scale = CGFloat(image.pixelWidth) / max(image.pointSize.width, 1)
        let x = min(max(Int(point.x * scale), 0), image.pixelWidth - 1)
        let y = min(max(Int(point.y * scale), 0), image.pixelHeight - 1)
        let offset = (y * image.pixelWidth + x) * 4
        let pixels = [UInt8](image.bgra)
        return (pixels[offset + 2], pixels[offset + 1], pixels[offset])
    }

    /// A value the check depends on, with a readable failure instead of a force-unwrap.
    @MainActor static func requireUnwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { fatalError("FAIL: \(message)") }
        return value
    }

    /// The character range of `needle` in a text page.
    @MainActor static func rangeWhile(
        in page: TextPage,
        needle: String
    ) -> ClosedRange<Int> {
        let pattern = Array(needle.unicodeScalars.map(\.value))
        outer: for start in 0...(page.chars.count - pattern.count) {
            for offset in 0..<pattern.count
            where page.chars[start + offset].unicode != pattern[offset] {
                continue outer
            }
            return start...(start + pattern.count - 1)
        }
        fatalError("text does not contain \(needle)")
    }
}

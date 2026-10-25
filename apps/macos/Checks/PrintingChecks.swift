import AppKit
import LyraReaderKit
import Foundation
import PDFKit

extension ReaderChecks {
    /// T3.12 printing: page count, page ranges and rendered bitmaps, headlessly.
    ///
    /// `NSPrintOperation` itself would put a panel on screen, so the check drives the same
    /// `ReaderPrintView` the operation paginates: `knowsPageRange` supplies the document's page
    /// count, the print panel's page range is turned into zero-based pages by `selectedPages`,
    /// and `renderPageBitmap` runs the same `drawPage` a printer would receive into an offscreen
    /// context at 300 dpi. A one-page range and a five-page range of a 130-page document are
    /// both exercised; the cache assertion is the memory contract (only two page rasters at
    /// once, however long the range).
    @MainActor static func printingChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-printing-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let shortURL = root.appendingPathComponent("tests/fixtures/multipage.pdf")
        let longURL = root.appendingPathComponent("tests/fixtures/index-past-120.pdf")

        let engine = try RustEngine()
        let shortLoaded = try engine.openDocument(at: shortURL)
        require(shortLoaded.pageCount == 3, "the short print fixture has three pages")
        let textPage = try await engine.textPage(0)

        var annotations: [PrintAnnotation] = []
        let pageText = textPage.chars
        // A highlight over real text, and a deliberately wide ink stroke in a blank margin.
        annotations.append(PrintAnnotation(
            kind: .highlight,
            page: 0,
            start: 0,
            end: min(20, max(pageText.count - 1, 0)),
            color: AppState.highlightPalette[0].color
        ))
        let inkY = max(shortLoaded.firstPageSize.height - 120, 40)
        annotations.append(PrintAnnotation(
            kind: .ink,
            page: 0,
            color: AnnotationColor(red: 220, green: 20, blue: 30, alpha: 255),
            inkPaths: [[CGPoint(x: 40, y: inkY), CGPoint(x: 40, y: inkY + 80)]],
            strokeWidth: 8
        ))

        let shortView = ReaderPrintView(
            pageCount: shortLoaded.pageCount,
            pageSizePt: shortLoaded.firstPageSize,
            annotations: annotations,
            pageImage: { page, scale in
                engine.renderPageForPrint(page, scale: scale)
            },
            textPage: { page in page == 0 ? textPage : nil }
        )

        // ── A uniform document stays exactly as it was ─────────────────────────────────────
        // The old behaviour printed every page on page one's size. A uniform document must
        // still be one operation, one paper, with page one's exact size (not a snapped stock).
        let uniformSpecs = PrintPageSpec.plan(
            pageSizes: Array(repeating: shortLoaded.firstPageSize, count: shortLoaded.pageCount))
        let uniformGroups = PrintPageSpec.groupedByPaper(uniformSpecs)
        require(uniformGroups.count == 1,
                "a uniform document is one paper group, not \(uniformGroups.count)")
        require(uniformSpecs.allSatisfy { $0.paper.size == shortLoaded.firstPageSize },
                "a uniform document keeps its exact shared page size as the paper")
        require(uniformSpecs.allSatisfy { $0.contentScale == 1 },
                "a uniform document prints at 100%, as before")
        require(uniformSpecs.allSatisfy { $0.paper.standardName == "A4" },
                "the uniform A4 fixture is still named A4")

        // ── The view supplies the page count the print panel needs ─────────────────────────
        var range = NSRange()
        require(shortView.knowsPageRange(&range), "the print view reports a page range")
        require(range.location == 1 && range.length == 3,
                "the page range is 1…3 in print terms ({\(range.location), \(range.length)})")
        require(shortView.pageCount == 3, "the view's page count matches the document")

        // ── One-page range ─────────────────────────────────────────────────────────────────
        let single = NSPrintInfo.shared.copy() as! NSPrintInfo
        single.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
        single.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 1
        single.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 1
        single.dictionary()[NSPrintInfo.AttributeKey.copies] = 2
        require(shortView.selectedPages(from: single) == [0],
                "a one-page range selects exactly one page")
        let onePage = try requireUnwrap(
            shortView.renderPageBitmap(0), "the selected page renders a bitmap")
        let expectedWidth = Int((shortLoaded.firstPageSize.width * ReaderPrintView.printDPI / 72).rounded())
        require(abs(onePage.pixelsWide - expectedWidth) <= 2,
                "the printed page is at 300 dpi (\(onePage.pixelsWide) px wide, expected \(expectedWidth))")
        require(onePage.pixelsHigh > 0, "the printed page has height")
        var nonWhite = 0
        if let data = onePage.bitmapData {
            let bytesPerRow = onePage.bytesPerRow
            for topY in stride(from: 0, to: onePage.pixelsHigh, by: 17) {
                let y = onePage.pixelsHigh - 1 - topY
                for x in stride(from: 0, to: onePage.pixelsWide, by: 17) {
                    let offset = y * bytesPerRow + x * 4
                    if data[offset] < 250 || data[offset + 1] < 250 || data[offset + 2] < 250 {
                        nonWhite += 1
                    }
                }
            }
        }
        require(nonWhite > 20, "the printed page has visible content (\(nonWhite) samples)")

        var redCount = 0
        var redBounds = (minX: Int.max, maxX: Int.min, minY: Int.max, maxY: Int.min)
        if let data = onePage.bitmapData {
            let row = onePage.bytesPerRow
            for topY in 0..<onePage.pixelsHigh {
                let y = onePage.pixelsHigh - 1 - topY
                for x in 0..<onePage.pixelsWide {
                    let offset = y * row + x * 4
                    if data[offset] > 170 && data[offset + 1] < 90 && data[offset + 2] < 90 {
                        redCount += 1
                        redBounds.minX = min(redBounds.minX, x)
                        redBounds.maxX = max(redBounds.maxX, x)
                        redBounds.minY = min(redBounds.minY, topY)
                        redBounds.maxY = max(redBounds.maxY, topY)
                    }
                }
            }
        }
        let highlightBoxes = textPage.selectionRects(in: 0...min(20, max(pageText.count - 1, 0)))
        if let box = highlightBoxes.first {
            let highlightPixel = printPixel(
                onePage, atPagePoint: CGPoint(x: box.maxX - 1, y: box.minY + 1))
            require(highlightPixel.2 < 245,
                    "the reader's highlight is tinted into the printed bitmap (\(highlightPixel))")
        } else {
            require(false, "the highlight range has printed geometry")
        }

        let inkPixel = printPixel(onePage, atPagePoint: CGPoint(x: 40, y: inkY + 40))
        require(redCount > 100,
                "the reader's ink annotation is in the printed bitmap (\(inkPixel), red pixels \(redCount))")
        require(redBounds.minX < Int(40.0 * CGFloat(onePage.pixelsWide) / 595.0) + 40,
                "the printed ink is at the page position it was drawn at (x \(redBounds.minX))")

        // ── Five-page range of a 130-page document ────────────────────────────────────────
        let longEngine = try RustEngine()
        let longLoaded = try longEngine.openDocument(at: longURL)
        require(longLoaded.pageCount == 130, "the long print fixture has 130 pages")
        let longView = ReaderPrintView(
            pageCount: longLoaded.pageCount,
            pageSizePt: longLoaded.firstPageSize,
            pageImage: { page, scale in
                longEngine.renderPageForPrint(page, scale: scale)
            }
        )
        var longRange = NSRange()
        require(longView.knowsPageRange(&longRange), "the long document reports a page range")
        require(longRange.length == 130, "the long document's page count reaches the print view")
        let many = NSPrintInfo.shared.copy() as! NSPrintInfo
        many.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
        many.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 10
        many.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 14
        many.dictionary()[NSPrintInfo.AttributeKey.copies] = 3
        let selected = longView.selectedPages(from: many)
        require(selected == [9, 10, 11, 12, 13],
                "a five-page range selects exactly five pages (\(selected))")

        var rendered = 0
        for page in selected {
            let bitmap = try requireUnwrap(
                longView.renderPageBitmap(page), "page \(page + 1) renders for printing")
            require(bitmap.pixelsWide > 100 && bitmap.pixelsHigh > 100,
                    "page \(page + 1) printed at print resolution")
            require(longView.cachedPageCount <= ReaderPrintView.maximumCachedPages,
                    "printing a long range never caches more than \(ReaderPrintView.maximumCachedPages) pages")
            rendered += 1
        }
        require(rendered == 5, "the five-page range produced five bitmaps")
        require(longView.renderedPages == selected,
                "the rendered pages are exactly the selected pages, in order")

        // ── A real NSPrintOperation, saved to PDF instead of a printer ────────────────────
        // The print panel's page range is what `NSPrintSaveJob` honours; running the operation
        // headlessly proves that the view's pagination and `draw` produce the selected pages,
        // not merely that `selectedPages` does the arithmetic.
        func savedJob(firstPage: Int, lastPage: Int, name: String) throws -> URL {
            let savedURL = scratch.appendingPathComponent(name)
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.paperSize = longLoaded.firstPageSize
            info.topMargin = 0
            info.bottomMargin = 0
            info.leftMargin = 0
            info.rightMargin = 0
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = savedURL
            info.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
            info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = firstPage
            info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = lastPage
            info.dictionary()[NSPrintInfo.AttributeKey.copies] = 1
            let view = ReaderPrintView(
                pageCount: longLoaded.pageCount,
                pageSizePt: longLoaded.firstPageSize,
                pageImage: { page, scale in
                    longEngine.renderPageForPrint(page, scale: scale)
                }
            )
            let operation = NSPrintOperation(view: view, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            require(operation.run(), "the headless print operation ran (\(name))")
            return savedURL
        }

        let manyJob = try savedJob(firstPage: 10, lastPage: 12, name: "many-pages.pdf")
        let manyDocument = PDFDocument(url: manyJob)
        require(manyDocument?.pageCount == 3,
                "a three-page print range produces a three-page job (\(manyDocument?.pageCount ?? -1))")
        if let manyDocument, manyDocument.pageCount == 3 {
            for index in 0..<manyDocument.pageCount {
                let bounds = manyDocument.page(at: index)?.bounds(for: .mediaBox) ?? .zero
                require(abs(bounds.width - longLoaded.firstPageSize.width) <= 0.5
                        && abs(bounds.height - longLoaded.firstPageSize.height) <= 0.5,
                        "a uniform job stays on page one's exact paper (page \(index + 1): \(bounds.size))")
            }
            func signature(_ index: Int) -> Data? {
                manyDocument.page(at: index)?.thumbnail(
                    of: NSSize(width: 120, height: 170), for: .mediaBox).tiffRepresentation
            }
            let first = signature(0)
            let second = signature(1)
            let third = signature(2)
            require(first != nil && second != nil && third != nil,
                    "every page of the print job has a rendered page")
            require(first != second && second != third && first != third,
                    "the print range printed three different pages, not one page three times")
        }
        let oneJob = try savedJob(firstPage: 2, lastPage: 2, name: "one-page.pdf")
        let oneDocument = PDFDocument(url: oneJob)
        require(oneDocument?.pageCount == 1,
                "a one-page print range produces a one-page job (\(oneDocument?.pageCount ?? -1))")

        // ── Mixed paper sizes: every page keeps its own paper ────────────────────────────────
        // `mixed-paper.pdf` is A4 (595×842), US Letter (612×792), A4 again, a page just inside
        // A4's tolerance but 5 pt shorter (590×835), a landscape Letter page (792×612), and a
        // 300×400 custom page that matches no stock.
        // Every page carries a red top-left square, a blue bottom-right square and a green
        // diagonal, so a wrong paper, a crop or a rotation is visible on the rendered bitmap.
        let mixedEngine = try RustEngine()
        let mixedLoaded = try mixedEngine.openDocument(
            at: root.appendingPathComponent("tests/fixtures/mixed-paper.pdf"))
        require(mixedLoaded.pageCount == 6, "the mixed-paper fixture has six pages")
        let expectedPageSizes = [
            CGSize(width: 595, height: 842),
            CGSize(width: 612, height: 792),
            CGSize(width: 595, height: 842),
            CGSize(width: 590, height: 835),
            CGSize(width: 792, height: 612),
            CGSize(width: 300, height: 400),
        ]
        var mixedSizes: [CGSize] = []
        for page in 0..<mixedLoaded.pageCount {
            let size = mixedEngine.pageSizeForPrint(page) ?? .zero
            let expected = expectedPageSizes[page]
            require(abs(size.width - expected.width) <= 0.5
                    && abs(size.height - expected.height) <= 0.5,
                    "mixed page \(page + 1) reports its own size (\(size), expected \(expected))")
            mixedSizes.append(size)
        }
        let mixedSpecs = PrintPageSpec.plan(pageSizes: mixedSizes)
        require(mixedSpecs.count == 6, "the mixed-paper plan covers every page")
        let a4 = try requireUnwrap(
            PrintPaperSelection.standards.first { $0.name == "A4" }, "A4 is a known stock")
        let letter = try requireUnwrap(
            PrintPaperSelection.standards.first { $0.name == "US Letter" },
            "US Letter is a known stock")
        require(mixedSpecs[0].paper.standardName == "A4"
                && abs(mixedSpecs[0].paper.size.width - a4.size.width) <= 0.01
                && abs(mixedSpecs[0].paper.size.height - a4.size.height) <= 0.01,
                "an A4 page prints on A4 paper (\(mixedSpecs[0].paper))")
        require(mixedSpecs[0].contentScale < 1 && mixedSpecs[0].contentScale > 0.999,
                "the 595×842 fixture is fitted to A4 by a hair, not cropped")
        require(mixedSpecs[1].paper.standardName == "US Letter"
                && mixedSpecs[1].paper.size == letter.size,
                "a US Letter page prints on US Letter paper (\(mixedSpecs[1].paper))")
        require(mixedSpecs[2].paper == mixedSpecs[0].paper,
                "two A4 pages share one paper group")
        require(mixedSpecs[3].paper.standardName == "A4"
                && mixedSpecs[3].paper.size == a4.size,
                "a 590×835 page is within A4 tolerance and prints on A4")
        require(mixedSpecs[3].pageSize == CGSize(width: 590, height: 835),
                "the small page keeps its own page size")
        require(mixedSpecs[3].contentScale == 1,
                "a page smaller than its paper is not enlarged beyond 100%")
        require(abs(mixedSpecs[3].contentRect.width - 590) <= 0.01
                && abs(mixedSpecs[3].contentRect.height - 835) <= 0.01,
                "the small page is drawn at 100% (\(mixedSpecs[3].contentRect.size))")
        require(mixedSpecs[3].contentRect.minX > 0 && mixedSpecs[3].contentRect.minY > 0,
                "the small page is centred with paper margins")
        require(mixedSpecs[4].paper.standardName == "US Letter"
                && abs(mixedSpecs[4].paper.size.width - 792) <= 0.01
                && abs(mixedSpecs[4].paper.size.height - 612) <= 0.01,
                "a landscape Letter page gets landscape Letter paper (\(mixedSpecs[4].paper))")
        require(mixedSpecs[4].contentScale == 1,
                "a landscape page already matching its stock is not rescaled")
        require(mixedSpecs[5].paper.isCustom
                && mixedSpecs[5].paper.size == CGSize(width: 300, height: 400),
                "a 300×400 page that matches no stock keeps a custom paper (\(mixedSpecs[5].paper))")
        require(mixedSpecs[5].contentScale == 1 && mixedSpecs[5].contentRect.origin == .zero,
                "a custom page fills its own paper at 100%")
        let mixedGroups = PrintPageSpec.groupedByPaper(mixedSpecs)
        require(mixedGroups.count == 4,
                "A4, Letter portrait, Letter landscape and custom are four jobs (\(mixedGroups.count))")
        require(mixedGroups[0].documentPages == [0, 2, 3],
                "the A4 group is pages 1, 3 and 4 in document order (\(mixedGroups[0].documentPages))")
        require(mixedGroups[1].documentPages == [1],
                "the Letter portrait group is page 2 (\(mixedGroups[1].documentPages))")
        require(mixedGroups[2].documentPages == [4],
                "the Letter landscape group is page 5 (\(mixedGroups[2].documentPages))")
        require(mixedGroups[3].documentPages == [5],
                "the custom group is page 6 (\(mixedGroups[3].documentPages))")

        let mixedView = ReaderPrintView(
            pages: mixedSpecs,
            pageImage: { page, scale in
                mixedEngine.renderPageForPrint(page, scale: scale)
            }
        )
        var mixedRange = NSRange()
        require(mixedView.knowsPageRange(&mixedRange) && mixedRange.length == 6,
                "the mixed view still reports all six pages")
        var expectedY: CGFloat = 0
        for (index, spec) in mixedSpecs.enumerated() {
            let rect = mixedView.rectForPage(index + 1)
            require(abs(rect.minY - expectedY) <= 0.01
                    && abs(rect.width - spec.paper.size.width) <= 0.01
                    && abs(rect.height - spec.paper.size.height) <= 0.01,
                    "page \(index + 1) has its own paper rect (\(rect))")
            expectedY += spec.paper.size.height
        }

        func runMixedGroup(_ group: PrintPageGroup, name: String) throws -> ReaderPrintView {
            let savedURL = scratch.appendingPathComponent(name)
            let view = ReaderPrintView(
                pages: group.pages,
                pageImage: { page, scale in
                    mixedEngine.renderPageForPrint(page, scale: scale)
                }
            )
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.paperSize = group.paper.size
            info.topMargin = 0
            info.bottomMargin = 0
            info.leftMargin = 0
            info.rightMargin = 0
            info.horizontalPagination = .fit
            info.verticalPagination = .fit
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = savedURL
            info.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
            info.dictionary()[NSPrintInfo.AttributeKey.copies] = 1
            let operation = NSPrintOperation(view: view, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            require(operation.run(), "the \(name) paper job ran")
            let document = try requireUnwrap(
                PDFDocument(url: savedURL), "the \(name) paper job is a PDF")
            require(document.pageCount == group.pageCount,
                    "the \(name) job has \(group.pageCount) page(s) (\(document.pageCount))")
            for index in 0..<document.pageCount {
                let bounds = try requireUnwrap(
                    document.page(at: index), "the \(name) job has page \(index + 1)"
                ).bounds(for: .mediaBox)
                require(abs(bounds.width - group.paper.size.width) <= 1
                        && abs(bounds.height - group.paper.size.height) <= 1,
                        "the \(name) job prints on its own paper (\(bounds.size))")
            }
            require(view.printedPages == group.documentPages,
                    "the \(name) job draws exactly its document pages (\(view.printedPages))")
            return view
        }

        for (groupIndex, group) in mixedGroups.enumerated() {
            let view = try runMixedGroup(group, name: "mixed-\(groupIndex).pdf")
            for (viewIndex, spec) in group.pages.enumerated() {
                let bitmap = try requireUnwrap(
                    view.renderPageBitmap(viewIndex),
                    "mixed page \(spec.documentPage + 1) renders")
                let expectedWidthPx = Int(
                    (group.paper.size.width * ReaderPrintView.printDPI / 72).rounded())
                require(abs(bitmap.pixelsWide - expectedWidthPx) <= 2,
                        "mixed page \(spec.documentPage + 1) is at 300 dpi on its paper"
                        + " (\(bitmap.pixelsWide) px, expected \(expectedWidthPx))")
                let red = paperPixel(bitmap, spec: spec, atPagePoint: CGPoint(x: 48, y: 48))
                require(red.0 > 170 && red.1 < 90 && red.2 < 90,
                        "the top-left red probe is at the top-left of page \(spec.documentPage + 1)"
                        + " (\(red))")
                let blue = paperPixel(
                    bitmap,
                    spec: spec,
                    atPagePoint: CGPoint(
                        x: spec.pageSize.width - 48,
                        y: spec.pageSize.height - 48
                    )
                )
                require(blue.2 > 170 && blue.0 < 90 && blue.1 < 90,
                        "the bottom-right blue probe is at the bottom-right of page"
                        + " \(spec.documentPage + 1) (\(blue))")
                let green = paperPixel(
                    bitmap,
                    spec: spec,
                    atPagePoint: CGPoint(
                        x: spec.pageSize.width / 2,
                        y: spec.pageSize.height / 2
                    )
                )
                require(green.1 > 90 && green.0 < 120 && green.2 < 120,
                        "the green diagonal is upright and uncropped on page"
                        + " \(spec.documentPage + 1) (\(green))")
                require(spec.contentRect.minX >= -0.01 && spec.contentRect.minY >= -0.01
                        && spec.contentRect.maxX <= spec.paper.size.width + 0.01
                        && spec.contentRect.maxY <= spec.paper.size.height + 0.01,
                        "page \(spec.documentPage + 1) content fits inside its paper")
                if spec.contentRect.minX > 1 {
                    let margin = paperPointPixel(
                        bitmap,
                        atPaperPoint: CGPoint(
                            x: spec.contentRect.minX / 2,
                            y: spec.paper.size.height / 2
                        )
                    )
                    require(margin.0 > 245 && margin.1 > 245 && margin.2 > 245,
                            "the small page's paper margin is white, not stretched content"
                            + " (\(margin))")
                }
            }
        }

        // ── The print panel's attributes reach the operation ──────────────────────────────
        let operation = NSPrintOperation(view: longView, printInfo: many)
        require((operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.copies] as? NSNumber)?.intValue == 3,
                "the operation carries the print panel's copies attribute")
        require((many.dictionary()[NSPrintInfo.AttributeKey.firstPage] as? NSNumber)?.intValue == 10,
                "the print panel's first page is carried")

        print("Printing checks passed")
    }

    /// One pixel of an `NSBitmapImageRep`, using page-local top-left points.
    @MainActor static func printPixel(
        _ bitmap: NSBitmapImageRep,
        atPagePoint point: CGPoint
    ) -> (UInt8, UInt8, UInt8) {
        let scale = CGFloat(bitmap.pixelsWide) / max(CGFloat(bitmap.size.width), 1)
        let x = min(max(Int(point.x * scale), 0), bitmap.pixelsWide - 1)
        let y = min(max(Int(point.y * scale), 0), bitmap.pixelsHigh - 1)
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return (0, 0, 0)
        }
        return (
            UInt8(min(max(color.redComponent * 255, 0), 255)),
            UInt8(min(max(color.greenComponent * 255, 0), 255)),
            UInt8(min(max(color.blueComponent * 255, 0), 255))
        )
    }

    /// One pixel of a **paper** bitmap, using top-left paper points.
    @MainActor static func paperPointPixel(
        _ bitmap: NSBitmapImageRep,
        atPaperPoint point: CGPoint
    ) -> (UInt8, UInt8, UInt8) {
        let scale = CGFloat(bitmap.pixelsWide) / max(CGFloat(bitmap.size.width), 1)
        let x = min(max(Int(point.x * scale), 0), bitmap.pixelsWide - 1)
        let y = min(max(Int(point.y * scale), 0), bitmap.pixelsHigh - 1)
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            return (0, 0, 0)
        }
        return (
            UInt8(min(max(color.redComponent * 255, 0), 255)),
            UInt8(min(max(color.greenComponent * 255, 0), 255)),
            UInt8(min(max(color.blueComponent * 255, 0), 255))
        )
    }

    /// A page-local top-left point, mapped through the page's fitted content rect onto the
    /// printed paper bitmap. The paper's own top margin is `height - contentRect.maxY`.
    @MainActor static func paperPixel(
        _ bitmap: NSBitmapImageRep,
        spec: PrintPageSpec,
        atPagePoint point: CGPoint
    ) -> (UInt8, UInt8, UInt8) {
        let content = spec.contentRect
        let paperPoint = CGPoint(
            x: content.minX + point.x * spec.contentScale,
            y: spec.paper.size.height - content.maxY + point.y * spec.contentScale
        )
        return paperPointPixel(bitmap, atPaperPoint: paperPoint)
    }
}

import AppKit
import CoreGraphics
import CoreText
import ImageIO

/// One mark the reader added, snapshotted for printing.
///
/// This is deliberately a value: a print job runs while the reader may keep editing, and the
/// sheet that comes out must be the document as it was when Print was chosen. The fields mirror
/// `AppState.Annotation`; only the fields the renderer needs are copied.
public struct PrintAnnotation: Sendable {
    public let kind: AppState.Annotation.Kind
    public let page: Int
    /// Character range for the three text-markup kinds.
    public let start: Int
    public let end: Int
    public let color: AnnotationColor
    public let note: String
    public let inkPaths: [[CGPoint]]
    public let shapeRect: CGRect?
    public let lineStart: CGPoint?
    public let lineEnd: CGPoint?
    public let strokeWidth: CGFloat
    public let fontSize: CGFloat
    /// An image signature's picture; `nil` for every other kind.
    public let imageData: Data?

    public init(
        kind: AppState.Annotation.Kind,
        page: Int,
        start: Int = 0,
        end: Int = 0,
        color: AnnotationColor,
        note: String = "",
        inkPaths: [[CGPoint]] = [],
        shapeRect: CGRect? = nil,
        lineStart: CGPoint? = nil,
        lineEnd: CGPoint? = nil,
        strokeWidth: CGFloat = 0,
        fontSize: CGFloat = 0,
        imageData: Data? = nil
    ) {
        self.kind = kind
        self.page = page
        self.start = start
        self.end = end
        self.color = color
        self.note = note
        self.inkPaths = inkPaths
        self.shapeRect = shapeRect
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.strokeWidth = strokeWidth
        self.fontSize = fontSize
        self.imageData = imageData
    }

    public init(_ annotation: AppState.Annotation) {
        self.init(
            kind: annotation.kind,
            page: annotation.page,
            start: annotation.start,
            end: annotation.end,
            color: annotation.color,
            note: annotation.note,
            inkPaths: annotation.inkPaths,
            shapeRect: annotation.shapeRect,
            lineStart: annotation.lineStart,
            lineEnd: annotation.lineEnd,
            strokeWidth: annotation.strokeWidth,
            fontSize: annotation.fontSize,
            imageData: annotation.imageData
        )
    }
}

/// The paper one printed page is composed on.
///
/// A page is printed on its own paper size, not on the first page's. `standardName` names the
/// standard stock the page was matched to (`A4`, `US Letter`, …) and is `nil` for a page that
/// matches no standard within ``PrintPaperSelection/tolerancePt``; such a page keeps its exact
/// dimensions as a custom paper.
public struct PrintPaper: Equatable, Sendable {
    /// Paper size in points, in the page's orientation (a landscape page gets landscape paper).
    public let size: CGSize
    /// The matched standard's name, or `nil` for custom paper.
    public let standardName: String?

    public init(size: CGSize, standardName: String? = nil) {
        self.size = size
        self.standardName = standardName
    }

    public var isCustom: Bool { standardName == nil }
}

/// A standard paper stock the reader can print on.
public struct PrintPaperStandard: Equatable, Sendable {
    public let name: String
    /// Portrait dimensions in points.
    public let size: CGSize

    public init(name: String, size: CGSize) {
        self.name = name
        self.size = size
    }
}

/// Chooses the paper for a page from that page's own size.
///
/// # Rule
///
/// 1. A page whose dimensions (orientation-normalised) are within
///    ``tolerancePt`` of a standard stock on **both** dimensions is printed on that standard's
///    paper, in the page's orientation. The nearest standard wins (smallest total difference).
/// 2. Otherwise the page is printed on custom paper of exactly its own size.
/// 3. The page is then fitted to that paper preserving aspect ratio, and the fit factor is
///    capped at 1: a page smaller than its paper is **centred at 100%**, never enlarged.
///
/// A document whose pages all share one size is a special case: the shared size is used as the
/// paper size as well. That keeps an ordinary uniform document printing exactly as it did before
/// per-page paper selection existed (no sub-point snap margins), while still naming the stock.
public enum PrintPaperSelection {
    /// Both dimensions must be this close to a standard to count as that stock. 12 pt is smaller
    /// than the difference between A4 and US Letter on the short edge (16.7 pt), so the two
    /// never collapse into one another.
    public static let tolerancePt: CGFloat = 12

    /// The stocks the reader recognises. ISO sizes use their exact 72 dpi values; US sizes are
    /// exact by definition. The names match what the system print panel calls them.
    public static let standards: [PrintPaperStandard] = [
        PrintPaperStandard(name: "A3", size: CGSize(width: 841.89, height: 1190.55)),
        PrintPaperStandard(name: "A4", size: CGSize(width: 595.28, height: 841.89)),
        PrintPaperStandard(name: "A5", size: CGSize(width: 420.94, height: 595.28)),
        PrintPaperStandard(name: "A6", size: CGSize(width: 297.64, height: 420.94)),
        PrintPaperStandard(name: "B4", size: CGSize(width: 708.66, height: 1000.63)),
        PrintPaperStandard(name: "B5", size: CGSize(width: 498.90, height: 708.66)),
        PrintPaperStandard(name: "US Letter", size: CGSize(width: 612, height: 792)),
        PrintPaperStandard(name: "US Legal", size: CGSize(width: 612, height: 1008)),
        PrintPaperStandard(name: "US Tabloid", size: CGSize(width: 792, height: 1224)),
        PrintPaperStandard(name: "US Executive", size: CGSize(width: 522, height: 756)),
    ]

    /// The nearest standard within ``tolerancePt``, or `nil` when the page is custom-sized.
    public static func standard(forPageSize size: CGSize) -> PrintPaperStandard? {
        let size = normalized(size)
        let pagePortrait = size.height >= size.width
        let pageSmall = pagePortrait ? size.width : size.height
        let pageLarge = pagePortrait ? size.height : size.width
        var best: (standard: PrintPaperStandard, distance: CGFloat)?
        for standard in standards {
            let standardSmall = min(standard.size.width, standard.size.height)
            let standardLarge = max(standard.size.width, standard.size.height)
            let widthDifference = abs(pageSmall - standardSmall)
            let heightDifference = abs(pageLarge - standardLarge)
            guard widthDifference <= tolerancePt, heightDifference <= tolerancePt else { continue }
            let distance = widthDifference + heightDifference
            if best == nil || distance < best!.distance {
                best = (standard, distance)
            }
        }
        return best?.standard
    }

    /// The paper a page of `size` prints on.
    public static func paper(forPageSize size: CGSize) -> PrintPaper {
        let size = normalized(size)
        guard let standard = standard(forPageSize: size) else {
            return PrintPaper(size: size)
        }
        let landscape = size.width > size.height
        let paperSize = landscape
            ? CGSize(width: standard.size.height, height: standard.size.width)
            : standard.size
        return PrintPaper(size: paperSize, standardName: standard.name)
    }

    /// A usable page size: non-positive or non-finite geometry falls back to US Letter, the
    /// same fallback the print view has always used for a document with no usable page size.
    public static func normalized(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 1, size.height > 1 else {
            return CGSize(width: 612, height: 792)
        }
        return size
    }
}

/// Everything the print view needs to know about one printed page.
///
/// `documentPage` is the zero-based page in the document (the key for the page raster,
/// annotations and text layer); the view's own page numbers are the positions in the array the
/// view was built from. A per-paper-size print operation therefore prints a subset of the
/// document's pages while still asking the engine and the annotation store for the right ones.
public struct PrintPageSpec: Equatable, Sendable {
    public let documentPage: Int
    /// The page's own size in points, already rotated.
    public let pageSize: CGSize
    /// The paper this page is composed on.
    public let paper: PrintPaper

    public init(documentPage: Int, pageSize: CGSize, paper: PrintPaper) {
        self.documentPage = documentPage
        self.pageSize = pageSize
        self.paper = paper
    }

    /// Fit factor from page points to paper points. Never above 1 (never enlarges).
    public var contentScale: CGFloat {
        let page = PrintPaperSelection.normalized(pageSize)
        let fit = min(paper.size.width / page.width, paper.size.height / page.height)
        return min(1, max(0, fit))
    }

    /// Where the page's content sits on the paper, in paper coordinates with the paper's
    /// bottom-left corner at the origin. Centred; aspect ratio preserved; never cropped.
    public var contentRect: CGRect {
        let page = PrintPaperSelection.normalized(pageSize)
        let scale = contentScale
        let width = page.width * scale
        let height = page.height * scale
        return CGRect(
            x: (paper.size.width - width) / 2,
            y: (paper.size.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// Plans a whole document from its page sizes, applying the per-page paper rule.
    ///
    /// A document whose pages all share one size keeps that exact size as the paper (see
    /// ``PrintPaperSelection``), so a uniform document is unchanged.
    public static func plan(pageSizes: [CGSize]) -> [PrintPageSpec] {
        let sizes = pageSizes.map(PrintPaperSelection.normalized)
        guard let first = sizes.first else { return [] }
        let uniform = sizes.allSatisfy {
            abs($0.width - first.width) <= 0.5 && abs($0.height - first.height) <= 0.5
        }
        if uniform {
            let paper = PrintPaper(
                size: first,
                standardName: PrintPaperSelection.standard(forPageSize: first)?.name
            )
            return sizes.enumerated().map {
                PrintPageSpec(documentPage: $0.offset, pageSize: $0.element, paper: paper)
            }
        }
        return sizes.enumerated().map { index, size in
            PrintPageSpec(
                documentPage: index,
                pageSize: size,
                paper: PrintPaperSelection.paper(forPageSize: size)
            )
        }
    }

    /// Groups pages by paper, preserving document order inside a group and first-appearance
    /// order between groups. Each group becomes one `NSPrintOperation`, because AppKit binds one
    /// paper size to an operation (see ``ReaderPrintView``).
    public static func groupedByPaper(_ pages: [PrintPageSpec]) -> [PrintPageGroup] {
        var groups: [PrintPageGroup] = []
        for page in pages {
            if let index = groups.firstIndex(where: { $0.paper == page.paper }) {
                groups[index].pages.append(page)
            } else {
                groups.append(PrintPageGroup(paper: page.paper, pages: [page]))
            }
        }
        return groups
    }
}

/// The pages printed together on one paper size, in document order.
public struct PrintPageGroup: Equatable, Sendable {
    public let paper: PrintPaper
    public var pages: [PrintPageSpec]

    public init(paper: PrintPaper, pages: [PrintPageSpec]) {
        self.paper = paper
        self.pages = pages
    }

    public var pageCount: Int { pages.count }
    public var documentPages: [Int] { pages.map(\.documentPage) }
}

/// The view `NSPrintOperation` paginates: one page of the document per printed page.
///
/// # Per-page paper
///
/// Each page is laid out on its own paper rectangle (`PrintPageSpec.paper`), selected by
/// ``PrintPaperSelection`` from that page's size. Pages are stacked bottom-to-top in the view,
/// so `rectForPage` can hand AppKit a different rectangle for every page. AppKit still binds a
/// single paper size to an `NSPrintOperation`, so `AppState` splits a mixed-size document into
/// one operation per distinct paper (`PrintPageSpec.groupedByPaper`); a view is built for each
/// group with only that group's pages.
///
/// # Scaling
///
/// The page raster is drawn into the page's paper rectangle with aspect ratio preserved,
/// centred, and never enlarged past 100%. A page smaller than the stock it was matched to keeps
/// its size and gets paper-coloured margins rather than being blown up.
///
/// # Resolution
///
/// Each page is rasterised at [`printDPI`] (300 dpi) and drawn into the page's point rectangle.
/// The print system then maps that to the printer's own resolution; the screen scale is never
/// involved. A page rendered at 2× for a Retina screen is 144 dpi; this is more than twice that.
///
/// # Memory
///
/// Only the page being drawn (and one recently drawn page, so a repeated dirty rect is cheap) is
/// held. A 900-page document never loads 900 rasters: [`cachedPageCount`] is at most
/// [`maximumCachedPages`] however many pages are printed. The page range and the copy count come
/// from the print panel (`NSPrintInfo`'s `firstPage` / `lastPage` / `copies` attributes); this
/// view supplies the total page count through `knowsPageRange`, which is what lets the panel show
/// a page range at all.
///
/// # Annotations
///
/// The page raster is requested with the PDF's own annotations burned in (the same path the
/// sidebar thumbnail uses), and the reader's own marks are drawn on top in page coordinates with
/// the same colours, line widths and multiply-blended text marks the canvas shows. Highlights are
/// drawn from the selected character rectangles, so the printed mark covers exactly the text the
/// reader selected, at print resolution.
@MainActor
public final class ReaderPrintView: NSView {
    /// 300 dpi: print resolution, not screen resolution.
    public static let printDPI: CGFloat = 300

    /// A page raster is large (a Letter page at 300 dpi is ~24 MB); keep only the page in the
    /// press and the one just drawn.
    public static let maximumCachedPages = 2

    /// The pages this view prints, in print order. The array index is the view's page number
    /// minus one; `documentPage` names the page in the document.
    public let pages: [PrintPageSpec]
    public var pageCount: Int { pages.count }
    /// Paper size of the first page. Kept for the tear checks, which compare two views of the
    /// same document; use ``pages`` for per-page paper.
    public var pageSizePt: CGSize { pages[0].paper.size }
    private let pageRects: [CGRect]
    private let annotations: [PrintAnnotation]
    private let pageImage: (Int, CGFloat) -> PageImage?
    private let textPage: (Int) -> TextPage?

    private var cache: [Int: CGImage] = [:]
    private var cacheOrder: [Int] = []
    /// The pages whose rasters were actually produced, in order, for the headless check.
    public private(set) var renderedPages: [Int] = []
    /// The pages the last print panel asked for, in order.
    public private(set) var printedPages: [Int] = []

    /// Builds a view for an explicit list of pages, each with its own paper.
    public init(
        pages: [PrintPageSpec],
        annotations: [PrintAnnotation] = [],
        pageImage: @escaping (Int, CGFloat) -> PageImage?,
        textPage: @escaping (Int) -> TextPage? = { _ in nil }
    ) {
        // A print operation needs at least one page. An empty plan is a programming error, but
        // falling back to one blank Letter page is safer than a zero-sized view.
        let pages = pages.isEmpty
            ? [PrintPageSpec(
                documentPage: 0,
                pageSize: CGSize(width: 612, height: 792),
                paper: PrintPaper(size: CGSize(width: 612, height: 792), standardName: "US Letter")
            )]
            : pages
        self.pages = pages
        self.annotations = annotations
        self.pageImage = pageImage
        self.textPage = textPage
        var rects: [CGRect] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        for page in pages {
            let size = page.paper.size
            rects.append(CGRect(x: 0, y: y, width: size.width, height: size.height))
            y += size.height
            width = max(width, size.width)
        }
        self.pageRects = rects
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: y))
    }

    /// Uniform-size convenience initializer. The whole document is planned with the per-page
    /// paper rule, so a uniform document keeps its exact shared size (see ``PrintPageSpec.plan``).
    public convenience init(
        pageCount: Int,
        pageSizePt: CGSize,
        annotations: [PrintAnnotation] = [],
        pageImage: @escaping (Int, CGFloat) -> PageImage?,
        textPage: @escaping (Int) -> TextPage? = { _ in nil }
    ) {
        self.init(
            pages: PrintPageSpec.plan(
                pageSizes: Array(repeating: pageSizePt, count: max(pageCount, 1))
            ),
            annotations: annotations,
            pageImage: pageImage,
            textPage: textPage
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ReaderPrintView is programmatic") }

    public override var isFlipped: Bool { false }

    /// What AppKit asks before showing the page range control. One-based, as `NSRange` expects.
    public override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    public override func rectForPage(_ page: Int) -> NSRect {
        guard page >= 1, page <= pageRects.count else { return .zero }
        return pageRects[page - 1]
    }

    /// The pages the print panel selected, as zero-based view page indices.
    ///
    /// `NSPrintInfo` stores the panel's choice in its dictionary (`NSPrintFirstPage`,
    /// `NSPrintLastPage`, `NSPrintAllPages`); the operation's `pageRange` is derived from it and
    /// is what AppKit uses to call `rectForPage` for selected pages only.
    public func selectedPages(from info: NSPrintInfo) -> [Int] {
        Self.selectedPages(from: info, pageCount: pageCount)
    }

    /// The page-range attributes of `info`, as zero-based pages of a `pageCount`-page document.
    ///
    /// Used for the full document view before it is split into per-paper print operations.
    public static func selectedPages(from info: NSPrintInfo, pageCount: Int) -> [Int] {
        let count = max(pageCount, 1)
        let dictionary = info.dictionary()
        let allPages = (dictionary[NSPrintInfo.AttributeKey.allPages] as? NSNumber)?.boolValue
            ?? true
        guard !allPages else { return Array(0..<count) }
        let first = (dictionary[NSPrintInfo.AttributeKey.firstPage] as? NSNumber)?.intValue ?? 1
        let last = (dictionary[NSPrintInfo.AttributeKey.lastPage] as? NSNumber)?.intValue ?? count
        let low = min(max(first, 1), count)
        let high = min(max(last, low), count)
        return Array((low - 1)..<high)
    }

    /// How many page rasters are alive right now. Never more than
    /// [`maximumCachedPages`], whatever the range.
    public var cachedPageCount: Int { cache.count }

    public override func draw(_ dirtyRect: NSRect) {
        for (index, rect) in pageRects.enumerated() where rect.intersects(dirtyRect) {
            let page = pages[index].documentPage
            if !printedPages.contains(page) { printedPages.append(page) }
            drawPage(index, in: rect)
        }
    }

    /// Renders one printed page to an `NSBitmapImageRep` at print resolution. `page` is a
    /// zero-based view page index; the bitmap is the page's paper, with the fitted content.
    ///
    /// This is the same `drawPage` the print operation calls, into an offscreen context, so the
    /// bitmap the check inspects is the bitmap the printer receives (before the print system's
    /// own scaling).
    public func renderPageBitmap(_ page: Int) -> NSBitmapImageRep? {
        guard page >= 0, page < pages.count else { return nil }
        let paperSize = pages[page].paper.size
        let scale = Self.printDPI / 72.0
        let width = max(1, Int((paperSize.width * scale).rounded()))
        let height = max(1, Int((paperSize.height * scale).rounded()))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        representation.size = NSSize(width: paperSize.width, height: paperSize.height)
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // `NSGraphicsContext(bitmapImageRep:)` already maps the rep's point size to its pixel
        // size (300/72 here), so drawing in paper points is already at print resolution. Scaling
        // again would draw a quarter of the page off the bitmap.
        drawPage(page, in: CGRect(origin: .zero, size: paperSize))
        NSGraphicsContext.restoreGraphicsState()
        return representation
    }

    // MARK: - Drawing

    /// Draws one page on its paper rect. `paperRect` is in the view's bottom-left coordinates.
    private func drawPage(_ index: Int, in paperRect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let spec = pages[index]
        let pageSize = PrintPaperSelection.normalized(spec.pageSize)
        let content = spec.contentRect.offsetBy(dx: paperRect.minX, dy: paperRect.minY)
        let scale = spec.contentScale

        context.saveGState()
        // The paper is white; a page smaller than the stock shows these margins.
        context.setFillColor(NSColor.white.cgColor)
        context.fill(paperRect)

        // Page space is top-left in this app; printing is bottom-left. Flip around the content
        // rect, then scale page points to fitted paper points, so every page-local geometry
        // (raster, annotations, highlight boxes) can be used as stored.
        context.translateBy(x: content.minX, y: content.minY + content.height)
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: pageSize))

        if let image = pageImageForPrint(spec.documentPage) {
            // CGImage draws in an unflipped coordinate space; flip locally so it comes out
            // upright inside the already-flipped page context.
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: pageSize))
            context.restoreGState()
        } else {
            drawMissingPage(
                spec.documentPage,
                in: CGRect(origin: .zero, size: pageSize),
                context: context
            )
        }

        for annotation in annotations where annotation.page == spec.documentPage {
            draw(annotation, context: context)
        }
        context.restoreGState()
    }

    private func pageImageForPrint(_ page: Int) -> CGImage? {
        if let cached = cache[page] {
            cacheOrder.removeAll { $0 == page }
            cacheOrder.append(page)
            return cached
        }
        let scale = Self.printDPI / 72.0
        guard let image = pageImage(page, scale) else { return nil }
        let cgImage = image.makeCGImage()
        cache[page] = cgImage
        cacheOrder.append(page)
        renderedPages.append(page)
        while cacheOrder.count > Self.maximumCachedPages {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
        return cgImage
    }

    private func drawMissingPage(_ page: Int, in rect: CGRect, context: CGContext) {
        let message = "Page \(page + 1) could not be rendered"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (message as NSString).size(withAttributes: attributes)
        let point = CGPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2)
        // The page is already flipped top-left; the string draw expects bottom-left.
        context.saveGState()
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        (message as NSString).draw(at: point, withAttributes: attributes)
        context.restoreGState()
    }

    private func draw(_ annotation: PrintAnnotation, context: CGContext) {
        let color = NSColor(
            srgbRed: CGFloat(annotation.color.red) / 255,
            green: CGFloat(annotation.color.green) / 255,
            blue: CGFloat(annotation.color.blue) / 255,
            alpha: CGFloat(annotation.color.alpha) / 255
        )
        switch annotation.kind {
        case .highlight, .underline, .strikeout:
            guard let text = textPage(annotation.page) else { return }
            let range = annotation.start...max(annotation.start, annotation.end)
            let boxes = text.selectionRects(in: range)
            guard !boxes.isEmpty else { return }
            context.saveGState()
            // Highlights are multiplied into the page on screen; the same blend here is what
            // keeps printed text readable under the tint.
            context.setBlendMode(annotation.kind == .highlight ? .multiply : .normal)
            for box in boxes {
                switch annotation.kind {
                case .highlight:
                    context.setFillColor(color.cgColor)
                    context.fill(box)
                case .underline:
                    context.setFillColor(color.cgColor)
                    context.fill(CGRect(x: box.minX, y: box.minY + box.height * 0.85,
                                        width: box.width, height: max(box.height * 0.12, 0.5)))
                case .strikeout:
                    context.setFillColor(color.cgColor)
                    context.fill(CGRect(x: box.minX, y: box.minY + box.height * 0.45,
                                        width: box.width, height: max(box.height * 0.12, 0.5)))
                default:
                    break
                }
            }
            context.restoreGState()
        case .ink, .square, .circle, .line, .arrow:
            let mark = CanvasAnnotationMark(
                id: "print",
                page: annotation.page,
                kind: annotation.kind,
                inkPaths: annotation.inkPaths,
                shapeRect: annotation.shapeRect,
                lineStart: annotation.lineStart,
                lineEnd: annotation.lineEnd,
                color: annotation.color,
                strokeWidth: annotation.strokeWidth,
                isSelected: false,
                isEditable: false
            )
            let path = AnnotationGeometry.path(for: mark)
            guard !path.isEmpty else { return }
            context.saveGState()
            context.setStrokeColor(color.withAlphaComponent(1).cgColor)
            context.setFillColor(color.withAlphaComponent(1).cgColor)
            context.setLineWidth(max(annotation.strokeWidth, 0.5))
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.addPath(path)
            // Ink is stroked; shapes are outlines; the arrowhead is filled too.
            context.strokePath()
            if annotation.kind == .arrow {
                context.addPath(path)
                context.fillPath()
            }
            context.restoreGState()
        case .stickyNote:
            guard let box = annotation.shapeRect else { return }
            let path = CGPath(
                roundedRect: box,
                cornerWidth: min(4, box.width / 4),
                cornerHeight: min(4, box.height / 4),
                transform: nil
            )
            context.saveGState()
            context.setFillColor(color.withAlphaComponent(1).cgColor)
            context.addPath(path)
            context.fillPath()
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
            context.setLineWidth(0.5)
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
            drawNoteIcon(in: box)
        case .textBox:
            guard let box = annotation.shapeRect else { return }
            context.saveGState()
            context.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            context.fill(box)
            context.setStrokeColor(color.withAlphaComponent(1).cgColor)
            context.setLineWidth(0.5)
            context.stroke(box)
            context.restoreGState()
            drawNoteText(annotation.note, in: box.insetBy(dx: 3, dy: 3),
                         fontSize: max(annotation.fontSize, 6), color: .black, context: context)
        case .stamp:
            guard let box = annotation.shapeRect else { return }
            drawStampBadge(annotation.note, in: box, color: color, context: context)
        case .signature:
            guard let box = annotation.shapeRect, let data = annotation.imageData,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            context.saveGState()
            // The print context is already flipped top-left; flip locally so the picture is not
            // printed upside down.
            context.translateBy(x: 0, y: box.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: box.minX, y: 0, width: box.width,
                                           height: box.height))
            context.restoreGState()
        }
    }

    /// A stamp as it prints: the same border insets and fitted text the canvas and PDF use.
    private func drawStampBadge(_ text: String, in box: CGRect, color: NSColor,
                                context: CGContext) {
        let words = NoteGlyph.collapsedStampText(text)
        let border = NoteGlyph.stampBorderWidth(box.size)
        context.saveGState()
        context.setStrokeColor(color.withAlphaComponent(1).cgColor)
        context.setLineWidth(max(border, 0.5))
        context.stroke(box.insetBy(dx: border / 2, dy: border / 2))
        context.setLineWidth(max(border * 0.75, 0.4))
        context.stroke(box.insetBy(dx: 4.5, dy: 4.5))
        guard !words.isEmpty else {
            context.restoreGState()
            return
        }
        let size = AnnotationTextFont.stampFontSize(words, width: box.width, height: box.height)
        let font = AnnotationTextFont.font(size: size)
        let attributed = NSAttributedString(
            string: words,
            attributes: [.font: font, .kern: 0, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.translateBy(x: 0, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: box.midX - width / 2,
                                       y: box.height / 2 - size * 0.35)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The sticky-note icon the canvas shows, drawn white inside the note's colour.
    private func drawNoteIcon(in box: CGRect) {
        let inset = min(box.width, box.height) * 0.18
        let iconBox = box.insetBy(dx: inset, dy: inset)
        guard iconBox.width > 2, iconBox.height > 2,
              let symbol = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white]))
        else { return }
        symbol.draw(
            in: iconBox,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func drawNoteText(
        _ text: String,
        in box: CGRect,
        fontSize: CGFloat,
        color: NSColor,
        context: CGContext
    ) {
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        context.saveGState()
        // Flip locally for NSString drawing (bottom-left origin).
        context.translateBy(x: 0, y: box.maxY)
        context.scaleBy(x: 1, y: -1)
        (text as NSString).draw(
            in: CGRect(x: box.minX, y: 0, width: box.width, height: box.height),
            withAttributes: attributes
        )
        context.restoreGState()
    }
}

private extension PageImage {
    /// A `CGImage` over the BGRA buffer the engine produced.
    func makeCGImage() -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0,
              bgra.count >= pixelWidth * pixelHeight * 4 else { return nil }
        let data = bgra as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little)
        return CGImage(
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pixelWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

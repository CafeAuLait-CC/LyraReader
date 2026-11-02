import AppKit
import CoreGraphics
import CoreText
import Foundation

/// The two glyphs a PDF annotation can need that are not a tinted box: a sticky note's icon and a
/// free-text annotation's own text.
///
/// The canvas draws textured quads and nothing else (see `MetalCanvasView`), so both are rendered
/// here into a bitmap that the existing pipeline can upload. Two rules follow from that pipeline
/// and are the reason this file exists rather than a call to `NSImage` at the draw site:
///
/// * **Straight alpha.** CoreGraphics hands back premultiplied bytes, and the quad pipeline blends
///   straight alpha (`src·a + dst·(1 − a)`), so a premultiplied bitmap is composited with its alpha
///   applied twice — which shows up as dark fringes along every antialiased edge. The buffer is
///   divided back out by its own alpha before it is uploaded.
/// * **A resolution, not a size.** The bitmap is rasterized at `zoom × deviceScale` pixels per
///   point, rounded up to a power of two, because the canvas scales it by the same zoom the page
///   under it is rasterized at. Without that, a note icon is crisp at 100% and mush at 400%.
///
/// Nothing here reads the file's font: a free-text annotation names a face this process does not
/// have (`/DFWaWaSC-W5`, a Chinese face, in 22 of the 23 free-text annotations in the local review
/// corpus), so the text is drawn in the system font at the size `/DA` states.
enum NoteGlyph {
    /// The default size of a free-text annotation whose `/DA` states none, in points.
    ///
    /// `/DA` is required on a `/FreeText` by PDF 32000-1 table 174, so this is the malformed-file
    /// case only. 12 pt is the size Acrobat writes in its own default appearance string and about
    /// the size of the body text these annotations sit next to.
    static let defaultFreeTextSizePt: CGFloat = 12

    /// The largest glyph either renderer will produce, on its longest side, in pixels.
    ///
    /// A guard against a malformed annotation rather than a rendering choice. A `/Rect` the size
    /// of a poster at 800% zoom would otherwise ask for a texture larger than the GPU will take,
    /// and the failure would be an allocation, not a picture. 2048 is ~4 MP (16 MB), which is more
    /// than a normal annotation box needs at any zoom: the 26 pt sticky notes in the review corpus
    /// are 208 px square at 8 px/pt, and its 328 pt free-text boxes are 2624 px wide, which this
    /// brings back to 2048 — still six pixels per point, three times what a 2× display shows at
    /// 100%. Beyond it the canvas's linear sampler stretches the glyph instead.
    static let maximumGlyphPixels = 2_048

    /// Pixels per point to rasterize a glyph at, for the current zoom and display.
    ///
    /// Rounded **up** to a power of two and capped, which is what keeps the texture cache small:
    /// a pinch from 100% to 800% walks through four entries rather than one per event, and each of
    /// them is at worst twice the pixels the display can show.
    static func scale(zoom: CGFloat, deviceScale: CGFloat) -> CGFloat {
        let wanted = max(zoom, 0.05) * max(deviceScale, 1)
        var scale: CGFloat = 1
        while scale < wanted && scale < 8 {
            scale *= 2
        }
        return scale
    }

    enum State: Hashable { case normal, hovered, active }

    /// The supplied 24-point folded-paper artwork, rasterized at the canvas scale.
    /// Inline comments share the silhouette and use three central dots instead of ruled lines.
    @MainActor static func noteIcon(color: AnnotationColor, boxPt: CGSize, scale: CGFloat,
                                    generation: UInt64, state: State = .normal,
                                    paper: PaperAppearance = .original) -> PageImage? {
        commentBadge(boxPt: boxPt, scale: scale, generation: generation, inline: false, state: state, paper: paper)
    }

    @MainActor static func inlineComment(color: AnnotationColor, boxPt: CGSize, scale: CGFloat,
                                        generation: UInt64, state: State = .normal,
                                        paper: PaperAppearance = .original) -> PageImage? {
        commentBadge(boxPt: boxPt, scale: scale, generation: generation, inline: true, state: state, paper: paper)
    }

    @MainActor private static func commentBadge(boxPt: CGSize, scale: CGFloat, generation: UInt64,
                                               inline: Bool, state: State, paper: PaperAppearance) -> PageImage? {
        guard let (width, height) = pixelSize(boxPt, scale: scale),
              let context = context(width: width, height: height) else { return nil }
        let side = CGFloat(min(width, height))
        context.translateBy(x: (CGFloat(width) - side) / 2, y: (CGFloat(height) - side) / 2)
        context.scaleBy(x: side / 24, y: side / 24)
        // SVG uses top-down coordinates; the bitmap context's drawing axis points upward.
        context.translateBy(x: 0, y: 24)
        context.scaleBy(x: 1, y: -1)
        let colors = LyraReaderTheme.noteIconColors(state: state, darkPaper: paper == .night)
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: 6.5, y: 3.75))
        outline.addLine(to: CGPoint(x: 17.5, y: 3.75))
        outline.addCurve(to: CGPoint(x: 20.25, y: 6.5), control1: CGPoint(x: 19.019, y: 3.75),
                         control2: CGPoint(x: 20.25, y: 4.981))
        outline.addLine(to: CGPoint(x: 20.25, y: 14.75))
        outline.addLine(to: CGPoint(x: 14.75, y: 20.25))
        outline.addLine(to: CGPoint(x: 6.5, y: 20.25))
        outline.addCurve(to: CGPoint(x: 3.75, y: 17.5), control1: CGPoint(x: 4.981, y: 20.25),
                         control2: CGPoint(x: 3.75, y: 19.019))
        outline.addLine(to: CGPoint(x: 3.75, y: 6.5))
        outline.addCurve(to: CGPoint(x: 6.5, y: 3.75), control1: CGPoint(x: 3.75, y: 4.981),
                         control2: CGPoint(x: 4.981, y: 3.75))
        outline.closeSubpath()
        context.addPath(outline)
        context.setFillColor(colors.paper.cgColor)
        context.fillPath()
        let fold = CGMutablePath()
        fold.move(to: CGPoint(x: 20.25, y: 14.75))
        fold.addLine(to: CGPoint(x: 17, y: 14.75))
        fold.addCurve(to: CGPoint(x: 14.75, y: 17), control1: CGPoint(x: 15.757, y: 14.75),
                      control2: CGPoint(x: 14.75, y: 15.757))
        fold.addLine(to: CGPoint(x: 14.75, y: 20.25))
        context.addPath(fold)
        context.setFillColor(colors.fold.cgColor)
        context.fillPath()
        context.setStrokeColor(colors.ink.cgColor)
        context.setLineWidth(1.35)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(outline)
        context.strokePath()
        context.addPath(fold)
        context.strokePath()
        context.setFillColor(colors.ink.cgColor)
        if inline {
            for x: CGFloat in [7.5, 11, 14.5] {
                context.fillEllipse(in: CGRect(x: x, y: 9, width: 1.75, height: 1.75))
            }
        } else {
            for line in [CGRect(x: 6.825, y: 7.575, width: 10.1, height: 1.35),
                         CGRect(x: 6.825, y: 11.075, width: 7.35, height: 1.35)] {
                context.addPath(CGPath(roundedRect: line, cornerWidth: 0.675, cornerHeight: 0.675, transform: nil))
                context.fillPath()
            }
        }
        return finish(context, width: width, height: height, pointSize: boxPt, generation: generation)
    }

    /// A free-text annotation's text, laid out in its own rectangle.
    ///
    /// `alignment` is `/Q` as the reader reports it (`left`, `center`, `right`); the text is
    /// wrapped to the box, which is what a free-text annotation's own appearance stream does.
    @MainActor static func freeText(
        _ text: String,
        color: AnnotationColor,
        fontSizePt: CGFloat,
        alignment: String,
        boxPt: CGSize,
        scale: CGFloat,
        generation: UInt64,
        useAppearanceFont: Bool = false
    ) -> PageImage? {
        guard let (width, height) = pixelSize(boxPt, scale: scale),
              let context = context(width: width, height: height)
        else { return nil }

        // Only the size comes from the file; the face is the system's (see the type's comment).
        let size = max(fontSizePt, 1) * scale
        let font = useAppearanceFont ? AnnotationTextFont.font(size: size) : NSFont.systemFont(ofSize: size)
        var quadding: CTTextAlignment = switch alignment {
        case "center": .center
        case "right": .right
        default: .left
        }
        let paragraph = withUnsafePointer(to: &quadding) { pointer in
            CTParagraphStyleCreate(
                [CTParagraphStyleSetting(
                    spec: .alignment,
                    valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: pointer
                )],
                1
            )
        }
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .kern: 0,
                .foregroundColor: NSColor(
                    srgbRed: CGFloat(color.red) / 255,
                    green: CGFloat(color.green) / 255,
                    blue: CGFloat(color.blue) / 255,
                    alpha: CGFloat(color.alpha) / 255
                ),
                .paragraphStyle: paragraph,
            ]
        )

        // A hair of padding, so a descender or an accent is not clipped by the box: a real
        // free-text appearance stream has the same problem and solves it the same way.
        let padding = useAppearanceFont ? AnnotationTextFont.padding(size: fontSizePt) * scale
            : min(size * 0.12, CGFloat(min(width, height)) * 0.1)
        let frame = CGRect(
            x: padding,
            y: padding,
            width: max(CGFloat(width) - 2 * padding, 1),
            height: max(CGFloat(height) - 2 * padding, 1)
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            CGPath(rect: frame, transform: nil),
            nil
        )
        CTFrameDraw(textFrame, context)
        return finish(
            context,
            width: width,
            height: height,
            pointSize: boxPt,
            generation: generation
        )
    }

    /// A text stamp's badge: a double border and one line of words in the bundled font.
    ///
    /// The numbers are the same ones the PDF writer uses (`stamp_appearance` in
    /// `geometry_write.rs`): a border stroke width of 3.5% of the height, an outer inset of half
    /// that, a 4.5 pt inner rule, a text box inset 6 pt horizontally, a size of at most 42% of the
    /// height fitted to the width, and a baseline 35% of the size below the centre. Keeping the
    /// two in step is what "the reader and the file show the same stamp" means in practice.
    @MainActor static func stamp(
        _ text: String,
        color: AnnotationColor,
        boxPt: CGSize,
        scale: CGFloat,
        generation: UInt64
    ) -> PageImage? {
        guard let (width, height) = pixelSize(boxPt, scale: scale),
              let context = context(width: width, height: height) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let effective = min(w / max(boxPt.width, 0.01), h / max(boxPt.height, 0.01))
        let nsColor = nsColor(color)

        let borderPt = stampBorderWidth(boxPt)
        let border = borderPt * effective
        let outerInset = border / 2
        let innerInset = 4.5 * effective
        context.setStrokeColor(nsColor.cgColor)
        context.setLineWidth(max(border, 0.5))
        context.stroke(CGRect(x: outerInset, y: outerInset,
                              width: w - 2 * outerInset, height: h - 2 * outerInset))
        context.setLineWidth(max(border * 0.75, 0.4))
        context.stroke(CGRect(x: innerInset, y: innerInset,
                              width: w - 2 * innerInset, height: h - 2 * innerInset))

        let words = collapsedStampText(text)
        guard !words.isEmpty else {
            return finish(context, width: width, height: height, pointSize: boxPt,
                          generation: generation)
        }
        let sizePt = AnnotationTextFont.stampFontSize(words, width: boxPt.width,
                                                      height: boxPt.height)
        let size = sizePt * effective
        let font = AnnotationTextFont.font(size: size)
        let attributed = NSAttributedString(
            string: words,
            attributes: [.font: font, .kern: 0, .foregroundColor: nsColor]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: (w - textWidth) / 2, y: h / 2 - size * 0.35)
        CTLineDraw(line, context)
        return finish(context, width: width, height: height, pointSize: boxPt,
                      generation: generation)
    }

    /// An image signature drawn into its page box. The picture is stretched to the box the
    /// reader chose; the box starts at the picture's aspect ratio (see
    /// `AppState.signatureBoxSize`) so it is only distorted by a deliberate resize.
    @MainActor static func signatureImage(
        _ image: CGImage,
        boxPt: CGSize,
        scale: CGFloat,
        generation: UInt64
    ) -> PageImage? {
        guard let (width, height) = pixelSize(boxPt, scale: scale),
              let context = context(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return finish(context, width: width, height: height, pointSize: boxPt,
                      generation: generation)
    }

    /// The stamp border width in page points, shared with the PDF writer.
    static func stampBorderWidth(_ boxPt: CGSize) -> CGFloat {
        min(max(boxPt.height * 0.035, 0.75), 2.0)
    }

    /// One line: runs of whitespace collapse to a single space, as the written appearance does.
    static func collapsedStampText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Drawing

    // MARK: - Bitmap plumbing

    /// `boxPt` at `scale`, in whole pixels, or `nil` when the box has no area.
    private static func pixelSize(_ boxPt: CGSize, scale: CGFloat) -> (Int, Int)? {
        guard boxPt.width > 0, boxPt.height > 0, boxPt.width.isFinite, boxPt.height.isFinite
        else { return nil }
        let wanted = CGSize(width: boxPt.width * scale, height: boxPt.height * scale)
        let longest = max(wanted.width, wanted.height)
        let shrink = longest > CGFloat(maximumGlyphPixels) ? CGFloat(maximumGlyphPixels) / longest : 1
        let width = max(1, Int((wanted.width * shrink).rounded()))
        let height = max(1, Int((wanted.height * shrink).rounded()))
        return (width, height)
    }

    /// A bitmap context in the byte order every texture in this engine is uploaded in: BGRA,
    /// little-endian, premultiplied while drawing (see `straightAlpha` for the conversion).
    private static func context(width: Int, height: Int) -> CGContext? {
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info
        )
    }

    private static func finish(
        _ context: CGContext,
        width: Int,
        height: Int,
        pointSize: CGSize,
        generation: UInt64
    ) -> PageImage? {
        guard let data = context.data else { return nil }
        var bgra = Data(bytes: data, count: width * height * 4)
        straightAlpha(&bgra)
        return PageImage(
            pixelWidth: width,
            pixelHeight: height,
            pointSize: CGSize(
                width: pointSize.width,
                height: pointSize.height
            ),
            bgra: bgra,
            generation: generation
        )
    }

    /// Divides CoreGraphics' premultiplied bytes back out by their own alpha.
    ///
    /// `PageImage.bgra` is documented as premultiplied because that is what PDFium hands over, but
    /// the quad pipeline's alpha-over state is `src·a + dst·(1 − a)`, i.e. **straight** alpha;
    /// uploaded premultiplied, a translucent edge is darkened twice. The icon and the text are the
    /// first textures in this engine that are mostly transparent, which is why this exists here
    /// and not on the page path (a page raster is opaque, and `a = 255` is the identity).
    private static func straightAlpha(_ bgra: inout Data) {
        bgra.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for pixel in stride(from: 0, to: bytes.count - 3, by: 4) {
                let alpha = Int(bytes[pixel + 3])
                if alpha == 255 { continue }
                if alpha == 0 {
                    bytes[pixel] = 0
                    bytes[pixel + 1] = 0
                    bytes[pixel + 2] = 0
                    continue
                }
                for channel in 0..<3 {
                    let value = (Int(bytes[pixel + channel]) * 255 + alpha / 2) / alpha
                    bytes[pixel + channel] = UInt8(min(value, 255))
                }
            }
        }
    }

    private static func nsColor(_ color: AnnotationColor) -> NSColor {
        NSColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255
        )
    }
}

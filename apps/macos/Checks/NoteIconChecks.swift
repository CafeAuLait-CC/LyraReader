import AppKit
import ImageIO
@testable import LyraReaderKit

extension ReaderChecks {
    @MainActor static func noteIconChecks(root: URL) async throws {
        _ = NSApplication.shared
        let color = AnnotationColor(red: 255, green: 0, blue: 255, alpha: 255)
        func render(_ state: NoteGlyph.State = .normal, _ paper: PaperAppearance = .original,
                    inline: Bool = false, size: CGFloat = 24, tint: AnnotationColor? = nil) -> PageImage {
            let box = CGSize(width: size, height: size)
            let image = inline
                ? NoteGlyph.inlineComment(color: tint ?? color, boxPt: box, scale: 2, generation: 1, state: state, paper: paper)
                : NoteGlyph.noteIcon(color: tint ?? color, boxPt: box, scale: 2, generation: 1, state: state, paper: paper)
            return image!
        }
        func cgImage(_ image: PageImage) -> CGImage {
            CGImage(width: image.pixelWidth, height: image.pixelHeight, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: image.pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                    provider: CGDataProvider(data: image.bgra as CFData)!, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)!
        }
        func rgba(_ image: CGImage) -> [UInt8] {
            let context = CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 48 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 48, height: 48))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 48 * 48 * 4))
        }
        let normal = render(), hovered = render(.hovered), active = render(.active), dark = render(.normal, .night)
        let reference = root.appendingPathComponent("tests/fixtures/note-icon-reference.png")
        let supplied = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(reference as CFURL, nil)!, 0, nil)!
        let error = zip(rgba(cgImage(normal)), rgba(supplied)).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
            / Double(48 * 48 * 4)
        if let directory = ProcessInfo.processInfo.environment["LYRA_READER_CHECK_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: cgImage(normal)).representation(using: .png, properties: [:])!
                .write(to: folder.appendingPathComponent("note-icon-default.png"))
        }
        require(error < 5, "native folded-paper artwork matches the supplied 2x PNG (mean error \(error))")
        require(normal.bgra != hovered.bgra && hovered.bgra != active.bgra && normal.bgra != dark.bgra,
                "default, hovered, open and dark-paper markers have distinct palettes")
        let masks = [normal, hovered, active, dark].map { image in
            stride(from: 3, to: image.bgra.count, by: 4).map { image.bgra[$0] }
        }
        require(masks.dropFirst().allSatisfy { $0 == masks[0] },
                "state changes preserve the icon silhouette and position")
        require(normal.bgra[(7 * 48 + 41) * 4 + 3] == 0,
                "the upper-right margin is transparent, with no unread indicator")
        require(render(inline: true).bgra != normal.bgra,
                "inline text comments remain distinguishable from ordinary sticky notes")
        let orange = AnnotationColor(red: 255, green: 128, blue: 0, alpha: 102)
        for paper in [PaperAppearance.original, .warm, .night] {
            for state in [NoteGlyph.State.normal, .hovered, .active] {
                let pinkIcon = render(state, paper, inline: true)
                let orangeIcon = render(state, paper, inline: true, tint: orange)
                require(pinkIcon.bgra != orangeIcon.bgra,
                        "inline note colours follow their highlights in every paper and interaction state")
                require(render(state, paper).bgra == render(state, paper, tint: orange).bgra,
                        "ordinary stickers keep their supplied palette regardless of highlight colour")
                let alpha = stride(from: 3, to: pinkIcon.bgra.count, by: 4)
                require(alpha.allSatisfy { pinkIcon.bgra[$0] == orangeIcon.bgra[$0] },
                        "highlight colours preserve the folded-paper silhouette")
                let palette = LyraReaderTheme.noteIconColors(state: state, darkPaper: paper == .night,
                                                             highlight: orange)
                require(palette.fold.redComponent < palette.paper.redComponent
                        && palette.fold.greenComponent < palette.paper.greenComponent
                        && palette.fold.blueComponent <= palette.paper.blueComponent,
                        "the lower-right fold is slightly darker than the tinted paper")
            }
        }
        let opaqueOrange = AnnotationColor(red: 255, green: 128, blue: 0, alpha: 255)
        require(render(inline: true, tint: orange).bgra == render(inline: true, tint: opaqueOrange).bgra,
                "translucent highlights still have opaque, identifiable note markers")
        let savedAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        require(render().bgra == normal.bgra, "dark window chrome keeps the default icon on original white paper")
        NSApp.appearance = savedAppearance
        require(NoteGlyph.noteIcon(color: color, boxPt: .zero, scale: 2, generation: 1) == nil,
                "an empty icon rectangle produces no texture")
        if let directory = ProcessInfo.processInfo.environment["LYRA_READER_CHECK_SNAPSHOT_DIR"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, image) in [("hover", hovered), ("active", active), ("night", dark),
                                  ("inline", render(inline: true)), ("inline-orange", render(inline: true, tint: orange)),
                                  ("16", render(size: 16))] {
                let png = NSBitmapImageRep(cgImage: cgImage(image)).representation(using: .png, properties: [:])!
                try png.write(to: folder.appendingPathComponent("note-icon-\(name).png"))
            }
        }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lyra-note-icons-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("notes.pdf")
        try FileManager.default.copyItem(at: root.appendingPathComponent("tests/fixtures/annotated-notes.pdf"), to: file)
        let original = try Data(contentsOf: file)
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 800))
        require(state.open(url: file), "the note state fixture opens")
        try await eventually("the PDF's note glyph reaches the canvas", {
            state.canvasPages.contains { $0.placement.index == PlacementIndex.documentNote(0) }
        })
        func quad() -> CanvasPage { state.canvasPages.first { $0.placement.index == PlacementIndex.documentNote(0) }! }
        let resting = quad()
        let point = CGPoint(x: resting.placement.leftPt + resting.placement.widthPt / 2,
                            y: resting.placement.topPt + resting.placement.heightPt / 2)
        require(state.updateNoteHover(atContentPoint: point), "hover finds the note without moving its anchor")
        require(quad().image.bgra != resting.image.bgra && quad().placement == resting.placement
                && state.openDocumentNoteID == nil, "hover changes colour without opening the note or shifting its box")
        require(state.openDocumentNote(at: point), "clicking opens the note")
        let opened = quad()
        require(opened.image.bgra != resting.image.bgra && opened.placement == resting.placement,
                "the open note uses its active palette at exactly the same position")
        state.updateNoteHover(atContentPoint: nil)
        state.closeDocumentNote()
        require(quad().image.bgra == resting.image.bgra, "closing and leaving the note restores its default appearance")
        state.setNotePaperAppearance(.night)
        require(quad().blend == .interface && quad().image.bgra != resting.image.bgra,
                "night paper uses the dedicated marker palette without a second GPU colour conversion")
        state.setNotePaperAppearance(.original)
        require(quad().image.bgra == resting.image.bgra, "returning to original paper restores the default marker")
        require(state.placeStickyNote(page: 0, at: CGPoint(x: 180, y: 220)), "a new sticky note opens its editor")
        let own = state.annotations.first { $0.kind == .stickyNote }!
        let index = state.annotations.firstIndex { $0.id == own.id }!
        func ownQuad() -> CanvasPage { state.canvasPages.first { $0.placement.index == PlacementIndex.ownNote(index) }! }
        let editing = ownQuad()
        state.updateEditingText("A draft kept while the icon changes state.")
        require(state.commitTextEditing(), "the note draft commits through the existing editor")
        require(ownQuad().image.bgra != editing.image.bgra && ownQuad().placement == editing.placement,
                "closing an owned note restores its default palette at the same anchor")
        state.beginEditingAnnotation(own.id)
        require(state.editingAnnotation?.note == "A draft kept while the icon changes state.",
                "reopening the note preserves its draft")
        require(ownQuad().image.bgra == editing.image.bgra, "reopening an owned note restores its active palette")
        require(state.commitTextEditing(), "the reopened draft closes cleanly")
        let finalBytes = try Data(contentsOf: file)
        require(finalBytes == original, "marker states never rewrite source annotation colours or geometry")
        print("PASS: note icons match supplied artwork and retain stable hover/open/paper behavior")
    }
}

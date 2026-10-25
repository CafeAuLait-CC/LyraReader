import AppKit
import SwiftUI

/// The annotation row's fixed geometry and the names its frames are measured by.
///
/// The row has three tool groups, left to right, separated by exactly one button width. The
/// buttons have a fixed width so "one button width" is a number rather than a side effect of the
/// widest SF Symbol: at every window width the gap is ``groupGap`` and every tool occupies
/// ``buttonWidth`` points. The trailing colour picker and the row's close button are chrome, not
/// tool groups, and sit after a flexible spacer.
public enum AnnotationToolbarLayout {
    /// One tool button's outer frame. The toolbar's button style asks for at least 30 × 32; a
    /// fixed 34 pt cell gives the icon breathing room and makes the group gap exact.
    public static let buttonWidth: CGFloat = 34
    public static let buttonHeight: CGFloat = 32
    /// Space between two buttons inside one group.
    public static let itemSpacing: CGFloat = 2
    /// Space between two groups: exactly one button width.
    public static var groupGap: CGFloat { buttonWidth }
    /// The row's leading/trailing padding, applied by ``ReaderSecondaryRow`` and by the hosted
    /// measurement so an absolute x is the same in both.
    public static let horizontalPadding: CGFloat = 14
    /// The row's top/bottom padding: the 46 pt slot around a 32 pt control. Applied by
    /// ``ReaderSecondaryRow``; no row may add padding of its own.
    public static var verticalPadding: CGFloat {
        (ReaderChrome.secondaryToolbarHeightPt - buttonHeight) / 2
    }
    /// Coordinate space the frame probe reports in.
    public static let coordinateSpace = "lyra.annotation-toolbar"

    /// The Fill & Sign button's glyph. A form/field glyph, deliberately not `signature`: the
    /// Signature tool in the placement group is the annotation row's signature picture.
    public static let fillAndSignIcon = "list.bullet.rectangle"

    /// The Fill & Sign button's accessible name.
    public static let fillAndSignLabel = "Fill & Sign"

    /// The Export button's glyph. A document with a downward arrow, never the system Share
    /// symbol (`square.and.arrow.up`) the old Export menu used.
    public static let exportIcon = "arrow.down.doc"
    public static let exportLabel = "Export"

    public enum Group: String, CaseIterable, Sendable {
        case markup
        case pointer
        case placement

        /// Stable display ids, in order. They are also the accessibility labels the buttons use.
        public var itemIDs: [String] {
            switch self {
            case .markup: return ["Highlight", "Underline", "Strikethrough"]
            case .pointer: return ["Pen", "Eraser", "Text box", "Shapes"]
            case .placement: return ["Note", "Stamp", "Signature"]
            }
        }

        public var frameID: String { "group.\(rawValue)" }
    }

    /// The three groups in their left-to-right order.
    public static let groupOrder: [Group] = [.markup, .pointer, .placement]

    /// The Edit row's tools in order. There is no Select entry: the implicit pointer state is
    /// the absence of a content tool, not another button.
    public static let contentEditItemIDs = ["Text", "Image", "Link", "Redact"]

    /// Every tool id the annotation row may contain. Used to assert that no removed control (in
    /// particular Select or Redact) survives in the built row.
    public static var annotationToolIDs: [String] {
        groupOrder.flatMap(\.itemIDs)
    }
}

/// The metrics every secondary sub-toolbar row shares.
///
/// Annotate is the reference row: one control height, one inter-item spacing, one group gap and
/// one horizontal padding. Edit, Fill & Sign, Export and Lyra use the same values, so their
/// buttons sit on the same baseline and their gaps read as one family. The checks measure the
/// hosted rows against these constants.
public enum ReaderSecondaryRowMetrics {
    public static let horizontalPadding = AnnotationToolbarLayout.horizontalPadding
    public static let verticalPadding = AnnotationToolbarLayout.verticalPadding
    public static let controlHeight = AnnotationToolbarLayout.buttonHeight
    public static let itemSpacing = AnnotationToolbarLayout.itemSpacing
    public static let groupGap = AnnotationToolbarLayout.groupGap

    /// Width of an explicit group-gap view in a row whose `HStack` already inserts
    /// ``itemSpacing`` on both sides of every child: `34 - 2 * 2 = 30`. The annotation row's
    /// `HStack(spacing: 0)` uses ``groupGap`` directly instead.
    public static var groupGapSpacerWidth: CGFloat { groupGap - 2 * itemSpacing }
}

/// Collects the resolved label fonts each host reports while a probe measurement is running.
///
/// Like the frame probe, it is nil in the app, so a reader builds none of the reporting views.
final class ReaderTypographyProbe: @unchecked Sendable {
    private(set) var fonts: [String: ReaderResolvedTypography] = [:]

    func report(_ id: String, _ font: ReaderResolvedTypography) {
        fonts[id] = font
    }
}

private struct ReaderTypographyProbeKey: EnvironmentKey {
    static let defaultValue: ReaderTypographyProbe? = nil
}

extension EnvironmentValues {
    var readerTypographyProbe: ReaderTypographyProbe? {
        get { self[ReaderTypographyProbeKey.self] }
        set { self[ReaderTypographyProbeKey.self] = newValue }
    }
}

/// Frames the hosted row reports to ``ReaderToolbarProbe``. Nil in the app, so no probe views are
/// built for a reader. The probe is only touched on the main actor during a synchronous
/// measurement; the unchecked conformance is what lets it sit in a SwiftUI environment value.
final class AnnotationToolbarFrameProbe: @unchecked Sendable {
    private(set) var frames: [String: CGRect] = [:]

    func report(_ id: String, _ frame: CGRect) {
        frames[id] = frame
    }
}

private struct AnnotationToolbarFrameProbeKey: EnvironmentKey {
    static let defaultValue: AnnotationToolbarFrameProbe? = nil
}

extension EnvironmentValues {
    var annotationToolbarFrameProbe: AnnotationToolbarFrameProbe? {
        get { self[AnnotationToolbarFrameProbeKey.self] }
        set { self[AnnotationToolbarFrameProbeKey.self] = newValue }
    }
}

/// Reports one view's laid-out frame in the row's coordinate space, but only when a measurement
/// is in progress.
struct AnnotationToolbarFrameReader: View {
    @Environment(\.annotationToolbarFrameProbe) private var probe
    let id: String

    var body: some View {
        if let probe {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named(AnnotationToolbarLayout.coordinateSpace))
                Color.clear
                    .onAppear { probe.report(id, frame) }
                    .onChange(of: frame) { _, newFrame in probe.report(id, newFrame) }
            }
        }
    }
}

/// A tool cell: the fixed button height and report, with either a fixed cell width (icon rows)
/// or the control's natural width (labelled rows).
struct AnnotationToolbarItemFrame: ViewModifier {
    let id: String
    var width: CGFloat? = AnnotationToolbarLayout.buttonWidth
    var height: CGFloat = AnnotationToolbarLayout.buttonHeight

    func body(content: Content) -> some View {
        content
            .frame(width: width, height: height)
            .background(AnnotationToolbarFrameReader(id: id))
    }
}

/// Hosts the real rows and returns what SwiftUI laid out, in row coordinates.
///
/// The checks use this instead of a screenshot or a private layout mirror: the frames are the
/// same views the reader sees, measured through a probe that exists only while this function
/// hosts them.
@MainActor
public enum ReaderToolbarProbe {
    /// Frames for the annotation row, including `group.*` entries, at a given row width.
    ///
    /// The real ``ReaderSecondaryRow`` container is hosted, not a copy of its padding, so the
    /// measured row is the row the reader sees.
    public static func annotationRowFrames(state: AppState, width: CGFloat) -> [String: CGRect] {
        measure(ReaderSecondaryRow { AnnotationToolRow(state: state) }, width: width)
    }

    /// Frames for the Edit (content editing) row at a given row width, through the row's real
    /// container.
    public static func contentEditRowFrames(state: AppState, width: CGFloat) -> [String: CGRect] {
        measure(ReaderSecondaryRow { ContentEditToolRow(state: state) }, width: width)
    }

    /// The resolved label fonts each host reports, for the typography contract check.
    ///
    /// `row` selects the real row; the main toolbar is measured through ``toolbarFonts``. Every
    /// label reports the font it applied, so a row that bypasses the shared label shows up as a
    /// missing or different entry.
    public static func rowFonts(row: SecondaryRow, state: AppState,
                                model: AIAssistantModel,
                                width: CGFloat) -> [String: ReaderResolvedTypography] {
        let view: AnyView
        switch row {
        case .annotations:
            view = AnyView(ReaderSecondaryRow { AnnotationToolRow(state: state) })
        case .contentEdit:
            view = AnyView(ReaderSecondaryRow { ContentEditToolRow(state: state) })
        case .fillAndSign:
            view = AnyView(ReaderSecondaryRow { FillSignToolRow(state: state) })
        case .export:
            view = AnyView(ReaderSecondaryRow { ExportToolRow(state: state) })
        case .lyra:
            view = AnyView(ReaderSecondaryRow { LyraToolRow(state: state, model: model) })
        }
        return host(view, width: width, height: ReaderChrome.secondaryToolbarHeightPt).fonts
    }

    /// The resolved label fonts in the primary toolbar at `width`.
    public static func toolbarFonts(state: AppState,
                                    width: CGFloat) -> [String: ReaderResolvedTypography] {
        host(ReaderToolbar(state: state), width: width, height: 60).fonts
    }

    static func measure<V: View>(
        _ view: V,
        width: CGFloat,
        height: CGFloat = ReaderChrome.secondaryToolbarHeightPt
    ) -> [String: CGRect] {
        host(view, width: width, height: height).frames
    }

    private static func host<V: View>(
        _ view: V,
        width: CGFloat,
        height: CGFloat
    ) -> (frames: [String: CGRect], fonts: [String: ReaderResolvedTypography]) {
        let frameProbe = AnnotationToolbarFrameProbe()
        let fontProbe = ReaderTypographyProbe()
        let root = view
            .environment(\.annotationToolbarFrameProbe, frameProbe)
            .environment(\.readerTypographyProbe, fontProbe)
            .coordinateSpace(name: AnnotationToolbarLayout.coordinateSpace)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        // The geometry readers report on their first layout pass; give SwiftUI one short run-loop
        // turn so a hosted row has the same frames it has in a window.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        return (frameProbe.frames, fontProbe.fonts)
    }
}

// MARK: - The Edit row

/// The content-editing tools. There is no Select button: when no content tool is armed the
/// pointer selects and moves page objects, and clicking the active tool again returns to it.
struct ContentEditToolRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: ReaderSecondaryRowMetrics.itemSpacing) {
            contentTool(
                "Text", "textformat", "text",
                help: "Select text to edit it, or click an empty area to add text.")
            contentTool(
                "Image", "photo", "image",
                help: "Click a page to insert an image, or select an existing image.")
            contentTool(
                "Link", "link", "link",
                help: "Drag a region to add a link, or select an existing link.")
            contentTool(
                "Redact", "rectangle.slash", "blackout",
                help: "Drag a rectangle to remove the content under it and cover the area in black. "
                    + "Erase is in the inspector.")
        }
    }

    private func contentTool(_ title: String, _ icon: String, _ tool: String,
                             help: String) -> some View {
        let selected = tool == "blackout"
            ? ["erase", "blackout"].contains(state.contentEditTool)
            : state.contentEditTool == tool
        return Button { state.selectContentTool(tool) } label: {
            ReaderToolbarLabel(title: title, id: title) {
                Image(systemName: icon)
            }
        }
        .buttonStyle(LyraReaderToolStyle(selected: selected))
        .help(selected ? help + " Click it again to return to the pointer." : help)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "")
        .background(AnnotationToolbarFrameReader(id: title))
    }
}

// MARK: - The annotation row

/// Three groups, left to right, with exactly one button width between them:
///
///   markup    Highlight, Underline, Strikethrough
///   pointer   Pen, Eraser, Text box, Shapes
///   placement Note, Stamp, Signature
///
/// There is no Select button: the absence of an armed tool is the pointer state. Redaction is
/// not here at all - it is a destructive content operation and lives in Edit's Redact tool.
/// The colour picker and the close button are trailing chrome, not a fourth tool group.
struct AnnotationToolRow: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            group(.markup) {
                toggleTool(
                    "Highlight", "highlighter", .highlight,
                    help: writeHelp("Highlight tool: new selections are highlighted until you turn it off"))
                toggleTool(
                    "Underline", "underline", .underline,
                    help: writeHelp("Underline tool: new selections are underlined until you turn it off"))
                toggleTool(
                    "Strikethrough", "strikethrough", .strikeout,
                    help: writeHelp("Strikethrough tool: new selections are struck through until you turn it off"))
            }
            gap
            group(.pointer) {
                toggleTool(
                    "Pen", "pencil.tip", .pen,
                    help: writeHelp("Draw with the pen; click it again or press Escape to return to the pointer"))
                toggleTool(
                    "Eraser", "eraser", .eraser,
                    help: writeHelp("Eraser: drag over ink to cut it where you pass; click it again or press Escape to leave it"))
                toggleTool(
                    "Text box", "textbox", .textBox,
                    help: writeHelp("Place a text box (double-click)"))
                shapesMenu
            }
            gap
            group(.placement) {
                toggleTool(
                    "Note", "text.bubble", .note,
                    help: writeHelp("Place a sticky note; click it again or press Escape to return to the pointer"))
                stampMenu
                signatureMenu
            }
            Color.clear.frame(width: 8, height: 1).allowsHitTesting(false)
            colorMenu
            closeButton
        }
    }

    private func group<Content: View>(
        _ group: AnnotationToolbarLayout.Group,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: AnnotationToolbarLayout.itemSpacing) { content() }
            .background(AnnotationToolbarFrameReader(id: group.frameID))
    }

    /// The requested gap: exactly one button width, and not a hit target.
    private var gap: some View {
        Color.clear
            .frame(width: AnnotationToolbarLayout.groupGap,
                   height: AnnotationToolbarLayout.buttonHeight)
            .accessibilityHidden(true)
    }

    private func toggleTool(
        _ title: String, _ icon: String, _ tool: AnnotationTool, help: String
    ) -> some View {
        Button { state.toggleAnnotationTool(tool) } label: {
            Image(systemName: icon)
        }
        .buttonStyle(LyraReaderToolStyle(selected: state.annotationTool == tool))
        .disabled(tool == .eraser ? !state.canUseEraserTool : !state.canEditAnnotations)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(state.annotationTool == tool ? "Selected" : "")
        .modifier(AnnotationToolbarItemFrame(id: title))
    }

    private var shapesMenu: some View {
        LyraReaderMenu(title: "Shapes", items: [
            LyraReaderMenuItem("Line", icon: "line.diagonal", selected: state.annotationTool == .line) {
                state.toggleAnnotationTool(.line)
            },
            LyraReaderMenuItem("Arrow", icon: "arrow.up.right", selected: state.annotationTool == .arrow) {
                state.toggleAnnotationTool(.arrow)
            },
            LyraReaderMenuItem("Rectangle", icon: "rectangle", selected: state.annotationTool == .rectangle) {
                state.toggleAnnotationTool(.rectangle)
            },
            LyraReaderMenuItem("Ellipse", icon: "circle", selected: state.annotationTool == .ellipse) {
                state.toggleAnnotationTool(.ellipse)
            },
        ]) {
            Image(systemName: "square.on.circle")
        }
        .disabled(!state.canEditAnnotations)
        .help(writeHelp("Shapes: line, arrow, rectangle or ellipse; click the active shape again or press Escape to return to the pointer"))
        .accessibilityLabel("Shapes")
        .modifier(AnnotationToolbarItemFrame(id: "Shapes"))
    }

    /// Stamps: one small set of meaningful marks, not a text field pretending to be a stamp.
    private var stampMenu: some View {
        LyraReaderMenu(title: "Stamp", items: stampMenuItems) {
            Image(systemName: "seal")
        }
        .disabled(!state.canEditAnnotations)
        .help(writeHelp("Stamps: Approved, Reviewed, Draft, Confidential or a dated mark; click the page to place it"))
        .accessibilityLabel("Stamp")
        .modifier(AnnotationToolbarItemFrame(id: "Stamp"))
    }

    private var stampMenuItems: [LyraReaderMenuItem] {
        AppState.StampStyle.allCases.map { style in
            LyraReaderMenuItem(
                style.title, icon: "seal",
                selected: state.annotationTool == .stamp && state.pendingStampStyle == style,
                color: Color(red: Double(style.color.red) / 255,
                             green: Double(style.color.green) / 255,
                             blue: Double(style.color.blue) / 255),
                action: { state.armStampTool(style) }
            )
        }
    }

    /// A signature image, plus the honest alternative: a hand-drawn signature *is* the pen.
    private var signatureMenu: some View {
        LyraReaderMenu(title: "Signature", items: signatureMenuItems) {
            Image(systemName: "signature")
        }
        .disabled(!state.canEditAnnotations)
        .help(writeHelp("Signature: place a picture of a signature, or draw one with the pen"))
        .accessibilityLabel("Signature")
        .modifier(AnnotationToolbarItemFrame(id: "Signature"))
    }

    private var signatureMenuItems: [LyraReaderMenuItem] {
        [
            LyraReaderMenuItem("Place Image Signature…", icon: "photo",
                               enabled: state.canEditAnnotations,
                               selected: state.annotationTool == .signature,
                               action: { Self.chooseSignatureImage(for: state) }),
            .separator("signature-pen"),
            LyraReaderMenuItem("Draw with the Pen", icon: "pencil.tip",
                               enabled: state.canEditAnnotations,
                               help: "A hand-drawn signature is a pen stroke, not a picture",
                               selected: state.annotationTool == .pen,
                               action: { state.toggleAnnotationTool(.pen) }),
        ]
    }

    private var colorMenu: some View {
        LyraReaderMenu(title: "Annotation color",
                       items: AppState.annotationPalette.enumerated().map { _, item in
            LyraReaderMenuItem(item.name, icon: "circle.fill",
                               selected: state.annotationColor == item.color,
                               color: Color(red: Double(item.color.red) / 255,
                                            green: Double(item.color.green) / 255,
                                            blue: Double(item.color.blue) / 255)) {
                state.annotationColor = item.color
            }
        }) {
            Image(systemName: "circle.fill")
                .foregroundStyle(Color(red: Double(annotationColor.red) / 255,
                                       green: Double(annotationColor.green) / 255,
                                       blue: Double(annotationColor.blue) / 255))
                .font(.system(size: 17)).frame(width: 32, height: 32)
        }
        .help("Annotation color")
        .modifier(AnnotationToolbarItemFrame(id: "Annotation color", width: 32))
    }

    private var closeButton: some View {
        Button { state.annotationToolsVisible = false } label: {
            Image(systemName: "xmark").font(.system(size: 11))
        }
        .help("Hide annotation tools")
        .accessibilityLabel("Hide annotation tools")
        .modifier(AnnotationToolbarItemFrame(id: "Hide annotation tools", width: 30))
    }

    private var annotationColor: AnnotationColor { state.annotationColor }

    /// Help for a tool that changes the document: a signed file says where the edit can go.
    private func writeHelp(_ normal: String) -> String {
        if state.isXfaDocument {
            return normal + " · not available: this XFA form is rendered read-only from its XML"
        }
        return state.isReadOnlyDocument ? normal + " · edits are saved to a copy" : normal
    }

    /// Asks for the PNG (or JPEG) a reader signs with, then arms the signature tool.
    ///
    /// PNG with transparency is the normal case: the picture's alpha is carried into the PDF as
    /// an image `/SMask`, so the page shows through around the strokes exactly as it does here.
    @MainActor
    private static func chooseSignatureImage(for state: AppState) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Signature Image"
        panel.message = "This places a picture of a signature, not a digital signature. "
            + "Only a digital signature can detect later changes. Choose a PNG with a "
            + "transparent background (or a JPEG); it stays an annotation until you save."
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        state.armSignatureTool(imageData: data)
    }
}

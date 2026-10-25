import AppKit
import SwiftUI

/// The Fill & Sign sub-toolbar row.
///
/// Seven items, in the order the request names them: Text, Signature, Date, Checkmark, Cross,
/// Stamp, Image. Choosing one arms it (the row button stays selected) and opens the right-hand
/// inspector for its options. The labels fall back to icons at narrow widths, exactly like the
/// primary toolbar's compact row; the help and the inspector still name every item.
///
/// The row is its controls only: ``ReaderSecondaryRow`` centers it, pads it and gives it the
/// slot height, like every other row.
struct FillSignToolRow: View {
    @ObservedObject var state: AppState
    @Environment(\.readerRowWidth) private var rowWidth

    var body: some View {
        // Constrain the fit test to the shared container's inside width: the scroll view would
        // otherwise propose "as wide as needed" and the labels would never fall back to icons.
        ViewThatFits(in: .horizontal) {
            row(labels: true)
            row(labels: false)
        }
        .frame(width: rowWidth)
    }

    @ViewBuilder
    private func row(labels: Bool) -> some View {
        HStack(spacing: ReaderSecondaryRowMetrics.itemSpacing) {
            ForEach(FillSignTool.rowOrder) { tool in
                let command = state.fillSignRowCommands.first { $0.tool == tool }
                Button { state.selectFillSignTool(tool) } label: {
                    if labels {
                        ReaderToolbarLabel(title: tool.title, id: tool.title) {
                            Image(systemName: tool.icon)
                        }
                    } else {
                        Image(systemName: tool.icon)
                            .modifier(ReaderToolbarIcon(id: "\(tool.title).icon"))
                    }
                }
                .buttonStyle(LyraReaderToolStyle(selected: state.armedFillSignTool == tool))
                .disabled(!(command?.enabled ?? false))
                .help(command?.help ?? tool.title)
                .accessibilityLabel(tool.title)
                .accessibilityValue(state.armedFillSignTool == tool ? "Armed" : "")
                // A labelled item is as wide as its label; the old fixed 116 pt cell centered
                // a short label inside a wide box and read as a much larger gap than every
                // other row. The compact row keeps the shared 34 pt icon cell.
                .modifier(AnnotationToolbarItemFrame(
                    id: tool.title,
                    width: labels ? nil : AnnotationToolbarLayout.buttonWidth))
            }
            // The clear button is trailing chrome, not another tool: separate it with the same
            // group gap the annotation row uses between its tool groups. The spacer's width
            // discounts the HStack spacing on each side of it.
            Color.clear
                .frame(width: ReaderSecondaryRowMetrics.groupGapSpacerWidth, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Button { state.clearFillSignTool() } label: {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .disabled(state.armedFillSignTool == nil)
            .help("Clear the Fill & Sign tool")
            .accessibilityLabel("Clear Fill & Sign tool")
            .modifier(AnnotationToolbarItemFrame(
                id: "Clear Fill & Sign tool", width: 30))
        }
    }
}

/// The Export sub-toolbar row.
///
/// #153 had these commands in a toolbar menu. They are now the row itself: Save, Save As, Save
/// Annotated Copy, Flattened Copy, Filled Form Copy, Form Values to Original, Export Annotations
/// and Print, in that order. The icon is a download-arrow document, not the system Share glyph
/// (`square.and.arrow.up`), which the toolbar used before and which macOS reserves for sharing.
///
/// The row is its controls only: ``ReaderSecondaryRow`` centers it, pads it and gives it the
/// slot height, like every other row.
struct ExportToolRow: View {
    @ObservedObject var state: AppState
    @Environment(\.readerRowWidth) private var rowWidth

    /// The toolbar button's glyph, shared with the row tests.
    static var icon: String { AnnotationToolbarLayout.exportIcon }

    var body: some View {
        // Same width-aware fallback as the Fill & Sign row; see FillSignToolRow.
        ViewThatFits(in: .horizontal) {
            row(labels: true)
            row(labels: false)
        }
        .frame(width: rowWidth)
    }

    @ViewBuilder
    private func row(labels: Bool) -> some View {
        HStack(spacing: ReaderSecondaryRowMetrics.itemSpacing) {
            ForEach(ExportCommand.all) { command in
                Button { command.perform(on: state) } label: {
                    if labels {
                        ReaderToolbarLabel(title: command.title, id: "export.\(command.id)") {
                            Image(systemName: command.icon)
                        }
                    } else {
                        Image(systemName: command.icon)
                            .modifier(ReaderToolbarIcon(id: "export.\(command.id).icon"))
                    }
                }
                .buttonStyle(LyraReaderToolStyle())
                .disabled(!command.isEnabled(state))
                .help(command.helpText(state))
                .accessibilityLabel(command.fullTitle)
                .modifier(ExportItemFrame(id: command.id, labels: labels))
            }
        }
    }
}

/// Export items keep the shared fixed cell in the compact row and their natural width when the
/// labels are shown, so every labelled row has the same gap between controls.
private struct ExportItemFrame: ViewModifier {
    let id: String
    let labels: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: labels ? nil : AnnotationToolbarLayout.buttonWidth,
                   height: AnnotationToolbarLayout.buttonHeight)
            .background(AnnotationToolbarFrameReader(id: "export.\(id)"))
    }
}

extension ReaderToolbarProbe {
    /// Frames for the Fill & Sign row at a given row width, through the row's real container.
    public static func fillSignRowFrames(state: AppState, width: CGFloat) -> [String: CGRect] {
        measure(ReaderSecondaryRow { FillSignToolRow(state: state) }, width: width)
    }

    /// Frames for the Export row at a given row width, through the row's real container.
    public static func exportRowFrames(state: AppState, width: CGFloat) -> [String: CGRect] {
        measure(ReaderSecondaryRow { ExportToolRow(state: state) }, width: width)
    }

    /// Frames for the Lyra row at a given row width, through the row's real container.
    ///
    /// The row needs the window's assistant model for its workspace selection, but only reads
    /// `selectedTab` and `rightPanelVisible`; a fresh model is enough for a layout measurement.
    public static func lyraRowFrames(state: AppState, model: AIAssistantModel,
                                     width: CGFloat) -> [String: CGRect] {
        measure(ReaderSecondaryRow { LyraToolRow(state: state, model: model) }, width: width)
    }
}

/// One layout outcome of the primary toolbar: which labels it chose, and the Fill & Sign
/// button's frame. The checks use it to prove the label is present at a wide window and absent
/// at the minimum width, without a screenshot.
extension ReaderToolbarProbe {
    /// Hosts the real primary toolbar at `width` and reports the labels and Fill & Sign button.
    public static func toolbarFrames(state: AppState, width: CGFloat) -> [String: CGRect] {
        measure(
            ReaderToolbar(state: state),
            width: width,
            height: 60
        )
    }
}

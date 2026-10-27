import AppKit
import SwiftUI

/// The right-hand inspector for the Fill & Sign row.
///
/// It exists only while a Fill & Sign tool is armed: choosing a row item opens it, and placing
/// the mark, pressing Escape, clicking the active item again or closing the row removes it. Its
/// sections are the tool's secondary options, not more commands in the row:
///
/// * Signature — the four methods and a preview of the picture that will be placed;
/// * Stamp — the five styles as a grid;
/// * Date — the format and rotation, with the resulting date as a preview;
/// * Image — the picture and its initial size;
/// * Text, Checkmark and Cross — the placement hint (their only option is the click).
///
/// The two form writes stay at the bottom, where #153's menu had them, and File carries them
/// whenever no Fill & Sign tool is armed.
struct FillSignInspector: View {
    @ObservedObject var state: AppState
    /// Keep the same controller while AppKit's asynchronous device service is in flight.
    @State private var controller: FillSignCommandController

    init(state: AppState) {
        self.state = state
        _controller = State(initialValue: FillSignCommandController(state: state))
    }

    private var tool: FillSignTool? { state.armedFillSignTool }

    var body: some View {
        ReaderInspectorHost(
            title: "Fill & Sign",
            subtitle: tool?.inspectorTitle,
            closeAccessibilityLabel: "Clear Fill & Sign tool",
            closeHelp: "Clear the tool and close this inspector",
            close: { state.clearFillSignTool() },
            marker: .fillSignInspector,
            isBusy: state.pageEditBusy || state.contentCommandInFlight,
            bodyContent: {
                // The armed tool selects its options here; every case is content for the same
                // host, not a separate inspector with its own padding.
                if let tool {
                    switch tool {
                    case .text: textOptions
                    case .signature: signatureOptions
                    case .date: dateOptions
                    case .checkmark, .cross: markOptions(tool)
                    case .stamp: stampOptions
                    case .image: imageOptions
                    }
                } else {
                    emptySelection
                }
                formSection
            },
            footer: { footer }
        )
    }

    private var emptySelection: some View {
        ReaderInspectorEmptyState(
            icon: "list.bullet.rectangle",
            message: "Choose a Fill & Sign tool in the row above.",
            detail: "The tool's options appear here until the mark is placed or the tool is cleared."
        )
    }

    // MARK: - Text

    private var textOptions: some View {
        ReaderPanelSection(title: "Text") {
            Text("Click the page to place a text box. It opens for typing at once; the first "
                 + "keystroke goes into the new box.")
                .font(.caption)
                .foregroundStyle(LyraReaderTheme.textSecondary)
            placementHint("Click the page to place the text box")
        }
    }

    // MARK: - Signature

    private var signatureOptions: some View {
        ReaderPanelSection(title: "Signature") {
            signaturePreview
            if state.canRotatePendingSignature {
                HStack(spacing: 8) {
                    Button { state.rotatePendingSignature(clockwise: false) } label: {
                        Label("90°", systemImage: "rotate.left")
                    }
                    .accessibilityLabel("Rotate signature counterclockwise 90 degrees")
                    .help("Rotate signature left by 90°")
                    Button { state.rotatePendingSignature(clockwise: true) } label: {
                        Label("90°", systemImage: "rotate.right")
                    }
                    .accessibilityLabel("Rotate signature clockwise 90 degrees")
                    .help("Rotate signature right by 90°")
                }
            }
            Text("Type a name, draw with the pointer, choose a picture, or sign on a paired "
                 + "iPhone or iPad. All four place a picture of a signature, not a digital "
                 + "signature.")
                .font(.caption)
                .foregroundStyle(LyraReaderTheme.textSecondary)
            Button { controller.chooseTypedSignature() } label: {
                Label("Type…", systemImage: "keyboard")
            }.disabled(!state.canPlaceFillSignAnnotation)
            Button { controller.chooseDrawnSignature() } label: {
                Label("Draw…", systemImage: "scribble")
            }.disabled(!state.canPlaceFillSignAnnotation)
            Button { controller.chooseSignatureImage() } label: {
                Label("Image…", systemImage: "photo")
            }.disabled(!state.canPlaceFillSignAnnotation)
            SignatureContinuityButton(
                controller: controller, enabled: state.canPlaceFillSignAnnotation)
                .frame(height: 32)
            if let hint = signaturePlacementHint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.accent)
            }
        }
    }

    @ViewBuilder private var signaturePreview: some View {
        if let image = signaturePreviewImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 140)
                .padding(8)
                .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(LyraReaderTheme.controlBorder))
                .accessibilityLabel("Signature preview")
        } else {
            VStack(spacing: 6) {
                Image(systemName: "signature")
                    .font(.system(size: 30, weight: .light))
                Text("No signature yet")
                    .font(.caption)
            }
            .foregroundStyle(LyraReaderTheme.iconSecondary)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var signaturePreviewImage: NSImage? {
        if let data = state.pendingSignatureImageData { return NSImage(data: data) }
        if case .drawnSignature(let drawn) = state.pendingFillSignPlacement {
            return DrawnSignaturePreview.image(drawn)
        }
        return nil
    }

    private var signaturePlacementHint: String? {
        if state.pendingSignatureImageData != nil {
            return "Click the page to place the signature"
        }
        if state.pendingFillSignPlacement != nil {
            return "Click the page to place the drawn signature"
        }
        return nil
    }

    // MARK: - Date

    private var dateOptions: some View {
        ReaderPanelSection(title: "Date") {
            Text(state.fillSignDateFormat.string())
                .font(.system(size: 22, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
            Picker("Format", selection: $state.fillSignDateFormat) {
                ForEach(FillSignDateFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Format").font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            Picker("Rotation", selection: $state.fillSignDateRotation) {
                ForEach(FillSignDateRotation.allCases) { rotation in
                    Text(rotation.title).tag(rotation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Rotation").font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            if state.fillSignDateRotation.isRotated {
                Text("A rotated date is placed as a picture so every PDF viewer paints the "
                     + "same orientation. A 0° date stays an editable text box.")
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
            }
            placementHint("Click the page to place the date")
        }
    }

    // MARK: - Checkmark / Cross

    private func markOptions(_ tool: FillSignTool) -> some View {
        ReaderPanelSection(title: tool.inspectorTitle) {
            Text("A \(tool.title.lowercased()) is two ink strokes in the annotation colour, so "
                 + "every viewer can draw it and one undo removes the whole mark.")
                .font(.caption)
                .foregroundStyle(LyraReaderTheme.textSecondary)
            placementHint("Click the page to place the \(tool.title.lowercased())")
        }
    }

    // MARK: - Stamp

    private var stampOptions: some View {
        ReaderPanelSection(title: "Stamp") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(AppState.StampStyle.allCases) { style in
                    Button { state.selectFillSignStamp(style) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "seal")
                                .font(.system(size: 18))
                                .foregroundStyle(Color(red: Double(style.color.red) / 255,
                                                       green: Double(style.color.green) / 255,
                                                       blue: Double(style.color.blue) / 255))
                            Text(style.title).font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                    }
                    .buttonStyle(ReaderPanelButtonStyle(
                        selected: state.annotationTool == .stamp
                            && state.pendingStampStyle == style))
                    .accessibilityLabel("\(style.title) stamp")
                }
            }
            placementHint("Click the page to place the \(state.pendingStampStyle?.title ?? "selected") stamp")
        }
    }

    // MARK: - Image

    private var imageOptions: some View {
        ReaderPanelSection(title: "Image") {
            if let data = state.pendingSignatureImageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 140)
                    .padding(8)
                    .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Picture preview")
            }
            Button { controller.chooseImage() } label: {
                Label(state.pendingSignatureImageData == nil ? "Choose Image…" : "Replace Image…",
                      systemImage: "photo")
            }.disabled(!state.canPlaceFillSignAnnotation)
            Text("Size").font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
            Picker("Size", selection: $state.fillSignImageSize) {
                ForEach(FillSignImageSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            placementHint(state.pendingSignatureImageData == nil
                          ? "Choose a PNG or JPEG, then click the page"
                          : "Click the page to place the picture")
        }
    }

    // MARK: - Form

    private var formSection: some View {
        ReaderPanelSection(title: "Form") {
            ForEach(state.fillSignFormCommands) { command in
                Button { state.performFillAndSignCommand(command.id) } label: {
                    Text(command.title)
                }
                .disabled(!command.enabled)
                .help(command.help ?? command.title)
            }
        }
    }

    // MARK: - Chrome

    private func placementHint(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cursorarrow.click")
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(LyraReaderTheme.accent)
    }

    private var footer: some View {
        ReaderInspectorFooter {
            if state.isReadOnlyDocument {
                Text("Signed original is read-only. Save a copy to keep Fill & Sign marks.")
                    .font(.caption)
                    .foregroundStyle(LyraReaderTheme.textSecondary)
            }
            Button("Done") { state.clearFillSignTool() }
                .buttonStyle(ReaderPanelButtonStyle(prominent: true))
        }
    }
}

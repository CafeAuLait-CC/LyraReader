import AppKit
import SwiftUI

/// A screen-sized piece of paper that stays attached to the note as the document moves.
struct DocumentNoteOverlay: View {
    @ObservedObject var state: AppState

    var body: some View {
        GeometryReader { geometry in
            if let source = state.openNoteSource,
               let anchor = state.openNoteAnchor,
               anchor.intersects(CGRect(origin: .zero, size: geometry.size)) {
                let frame = DocumentNoteLayout.frame(anchor: anchor, viewport: geometry.size)
                VStack(spacing: 0) {
                    HStack {
                        Text(state.openDocumentNote?.author.flatMap { $0.isEmpty ? nil : $0 }
                             ?? (state.openOwnNote?.kind == .stickyNote ? "Sticky Note" : "Note"))
                            .font(.headline).lineLimit(1)
                        Spacer()
                        Button { state.closeDocumentNote() } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close note")
                    }
                    .padding(12)
                    Divider()
                    NotePaperText(text: state.openOwnNote?.note ?? state.openDocumentNote?.contents ?? "",
                                  onEdit: { state.editOpenNote() })
                        .padding(8)
                }
                .foregroundStyle(LyraReaderTheme.noteFg)
                .frame(width: frame.width, height: frame.height)
                .background(LyraReaderTheme.noteBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(LyraReaderTheme.border))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .transition(ReaderMotion.paperTransition)
                .position(x: frame.midX, y: frame.midY)
                .id(source)
            }
        }
        .animation(ReaderMotion.paperAnimation, value: state.openNoteSource)
    }
}

public enum DocumentNoteLayout {
    public static let size = CGSize(width: 280, height: 220)

    public static func frame(anchor: CGRect, viewport: CGSize) -> CGRect {
        let margin: CGFloat = 8
        let x = anchor.maxX + margin + size.width <= viewport.width - margin
            ? anchor.maxX + margin : anchor.minX - margin - size.width
        return CGRect(x: max(margin, min(x, viewport.width - size.width - margin)),
                      y: max(margin, min(anchor.minY, viewport.height - size.height - margin)),
                      width: size.width, height: size.height)
    }
}

/// Always show a vertical scrollbar, including when macOS normally hides overlay scrollers.
/// This native scroll view consumes wheel input over the paper without scrolling the PDF.
struct NotePaperText: NSViewRepresentable {
    let text: String
    var onEdit: (() -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.drawsBackground = true
        scroll.backgroundColor = LyraReaderTheme.noteBgColor
        scroll.contentView.drawsBackground = false
        LyraReaderSidebarScroller.install(on: scroll, trackColor: LyraReaderTheme.noteBgColor)
        let body = NoteTextView(frame: scroll.contentView.bounds)
        body.onEdit = onEdit
        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.font = .systemFont(ofSize: 13)
        body.textColor = LyraReaderTheme.noteTextColor
        body.textContainerInset = CGSize(width: 4, height: 6)
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        body.textContainer?.containerSize = CGSize(width: scroll.contentSize.width,
                                                  height: .greatestFiniteMagnitude)
        scroll.documentView = body
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let body = scroll.documentView as? NoteTextView else { return }
        body.onEdit = onEdit
        body.textColor = LyraReaderTheme.noteTextColor
        guard body.string != text else { return }
        body.string = text
        body.scrollToBeginningOfDocument(nil)
    }
}

/// A body click explicitly starts editing while wheel events keep scrolling the paper.
private final class NoteTextView: NSTextView {
    var onEdit: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let onEdit else { super.mouseDown(with: event); return }
        onEdit()
    }
}

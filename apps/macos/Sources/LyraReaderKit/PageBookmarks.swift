import AppKit
import SwiftUI

extension Bookmark {
    package var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Page \(page + 1)" : title
    }
}

package struct BookmarkEditor: View {
    @ObservedObject var state: AppState
    let bookmark: Bookmark
    let close: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    package var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Page \(bookmark.page + 1) bookmark")
                    .font(.caption).foregroundStyle(LyraReaderTheme.textSecondary)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(LyraReaderToolStyle()).accessibilityLabel("Close bookmark editor")
            }
            Text("Bookmark name").font(.system(size: 12, weight: .medium))
            TextField("Name", text: $name)
                .textFieldStyle(ReaderPanelFieldStyle()).focused($focused)
                .accessibilityLabel("Bookmark name")
                .onSubmit { save() }
            HStack {
                Button("Remove Bookmark", role: .destructive) {
                    state.removeBookmark(bookmark.id); close()
                }.buttonStyle(.plain).foregroundStyle(LyraReaderTheme.errorFg)
                Spacer()
                Button("Done") { save() }
                    .buttonStyle(ReaderPanelButtonStyle(prominent: true)).frame(width: 70)
            }
        }
        .padding(16).frame(width: 280)
        .foregroundStyle(LyraReaderTheme.textPrimary).background(LyraReaderTheme.menuBg)
        .onAppear { name = bookmark.title; focused = true }
        .onChange(of: state.document?.id) { _, _ in close() }
    }

    private func save() {
        state.renameBookmark(bookmark.id, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
        close()
    }
}

package enum PageBookmarkGeometry {
    /// One flag at the original page top; a torn page's continuation gets no duplicate flag.
    package static func frames(pages: [PagePlacement], width: CGFloat, contentWidth: CGFloat,
                               zoom: CGFloat, scroll: CGFloat, viewport: CGRect) -> [Int: CGRect] {
        guard zoom.isFinite, zoom > 0 else { return [:] }
        let offset = max(0, (width - contentWidth * zoom) / 2)
        var result: [Int: CGRect] = [:]
        for page in pages where page.sourceTopPt == 0 {
            let rect = CGRect(x: offset + (page.leftPt + page.widthPt) * zoom - 62,
                              y: (page.topPt - scroll) * zoom - 6, width: 60, height: 56)
            if rect.intersects(viewport) { result[page.index] = rect }
        }
        return result
    }
}

@MainActor
package final class PageBookmarkFlagView: NSView {
    package override var isFlipped: Bool { true }
    private let button = PageBookmarkButton()
    private var tracking: NSTrackingArea?
    private var hovered = false
    package var bookmarked = false { didSet { updateVisibility() } }
    var activate: (() -> Void)? { didSet { button.activate = activate } }

    package override init(frame: NSRect) {
        super.init(frame: frame)
        button.frame = NSRect(x: 28, y: 0, width: 22, height: 36)
        addSubview(button)
        updateVisibility()
    }
    required init?(coder: NSCoder) { fatalError() }

    package override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    package override func mouseEntered(with event: NSEvent) { setHovered(true) }
    package override func mouseExited(with event: NSEvent) { setHovered(false) }
    func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value; updateVisibility()
    }
    private func updateVisibility() {
        button.isHidden = !bookmarked && !hovered
        button.bookmarked = bookmarked
        button.needsDisplay = true
    }
    func setPage(_ page: Int) {
        button.toolTip = bookmarked ? "Edit bookmark on page \(page + 1)" : "Bookmark page \(page + 1)"
        button.setAccessibilityLabel(button.toolTip)
        button.setAccessibilityIdentifier("page-bookmark-\(page + 1)")
    }
    package override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !button.isHidden, button.frame.contains(local) else { return nil }
        return button
    }
}

@MainActor
private final class PageBookmarkButton: NSButton {
    var bookmarked = false
    var activate: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; target = self; action = #selector(openBookmark)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 1, y: 0)); path.line(to: CGPoint(x: bounds.width - 1, y: 0))
        path.line(to: CGPoint(x: bounds.width - 1, y: bounds.height - 1))
        path.line(to: CGPoint(x: bounds.midX, y: bounds.height - 9))
        path.line(to: CGPoint(x: 1, y: bounds.height - 1)); path.close()
        LyraReaderTheme.accentColor.withAlphaComponent(bookmarked ? 1 : 0.45).setFill()
        path.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
    @objc private func openBookmark() { activate?() }
}

@MainActor
package final class PageBookmarkCanvasHost: NSView {
    package override var isFlipped: Bool { true }
    private weak var state: AppState?
    private var documentID: UUID?
    private var snapshot: [Bookmark] = []
    private var markers: [Int: PageBookmarkFlagView] = [:]
    private var popover: NSPopover?
    package var markerFrames: [Int: CGRect] { markers.mapValues(\.frame) }

    package func updateHover(at point: CGPoint?) {
        for flag in markers.values { flag.setHovered(point.map { flag.frame.contains($0) } ?? false) }
    }

    package func configure(state: AppState?) -> Bool {
        let changed = self.state !== state || documentID != state?.document?.id
            || snapshot != (state?.bookmarks ?? [])
        if documentID != state?.document?.id { popover?.performClose(nil) }
        self.state = state; documentID = state?.document?.id; snapshot = state?.bookmarks ?? []
        return changed
    }

    package func sync(size: CGSize, viewport: CGRect, scroll: CGFloat, zoom: CGFloat,
              contentWidth: CGFloat, pages: [PagePlacement]) {
        frame = CGRect(origin: .zero, size: size)
        let frames = state == nil ? [:] : PageBookmarkGeometry.frames(
            pages: pages, width: size.width, contentWidth: contentWidth,
            zoom: zoom, scroll: scroll, viewport: viewport)
        for page in markers.keys where frames[page] == nil {
            markers.removeValue(forKey: page)?.removeFromSuperview()
        }
        for (page, rect) in frames {
            let flag = markers[page] ?? PageBookmarkFlagView(frame: rect)
            if flag.superview == nil { addSubview(flag); markers[page] = flag }
            flag.frame = rect
            flag.bookmarked = snapshot.contains { $0.page == page }
            flag.setPage(page)
            flag.activate = { [weak self, weak flag] in
                guard let self, let flag else { return }
                self.editBookmark(page: page, from: flag)
            }
        }
        if let window { updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    private func editBookmark(page: Int, from flag: NSView) {
        guard let state, documentID != nil, documentID == state.document?.id else { return }
        if !state.bookmarks.contains(where: { $0.page == page }) {
            guard state.addBookmark(onPage: page) else { return }
        }
        guard let bookmark = state.bookmarks.first(where: { $0.page == page }) else { return }
        popover?.performClose(nil)
        let editor = NSPopover(); editor.behavior = .transient
        editor.contentViewController = NSHostingController(rootView: BookmarkEditor(
            state: state, bookmark: bookmark, close: { [weak editor] in editor?.performClose(nil) }))
        popover = editor
        editor.show(relativeTo: NSRect(x: 28, y: 0, width: 22, height: 36), of: flag, preferredEdge: .minY)
    }

    package override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { popover?.performClose(nil) }
        super.viewWillMove(toWindow: newWindow)
    }
    package override func hitTest(_ point: NSPoint) -> NSView? {
        // MetalCanvasView is y-up; this overlay is y-down. NSView receives hit-test points
        // in its parent's coordinates, and must convert before comparing local flag frames.
        let local = convert(point, from: superview)
        guard markers.values.contains(where: { $0.frame.contains(local) }) else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

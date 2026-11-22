import AppKit
import SwiftUI

/// Commands shared by toolbar dropdowns and document context menus.
struct LyraReaderMenuItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    var nativeImage: NSImage? = nil
    var shortcut: String? = nil
    var enabled = true
    /// Why a disabled command is disabled. A signed document says so instead of showing a
    /// grey row that explains nothing.
    var help: String? = nil
    var selected = false
    var color: Color? = nil
    var action: () -> Void = {}
    var isSeparator = false

    init(_ title: String, icon: String, shortcut: String? = nil, enabled: Bool = true,
         help: String? = nil, selected: Bool = false, color: Color? = nil,
         action: @escaping () -> Void) {
        id = title; self.title = title; self.icon = icon; self.shortcut = shortcut
        self.enabled = enabled; self.help = help; self.selected = selected
        self.color = color; self.action = action
    }

    static func separator(_ id: String) -> Self {
        var item = Self(id, icon: "", enabled: false, action: {})
        item.isSeparator = true
        return item
    }
}

struct LyraReaderMenu<Label: View>: View {
    let title: String
    let items: [LyraReaderMenuItem]
    @ViewBuilder let label: () -> Label
    @State private var presented = false
    @State private var placement = CGRect.zero

    var body: some View {
        Button { presented.toggle() } label: { label() }
            .lyraToolStyle(selected: presented)
            .help(title).accessibilityLabel(title)
            .accessibilityValue(presented ? "Expanded" : "Collapsed")
            .background(LyraReaderMenuAnchor(presented: $presented, items: items, placement: placement))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { placement = $0 }
    }
}

private struct LyraReaderMenuContent: View {
    let items: [LyraReaderMenuItem]
    let dismiss: () -> Void
    @State private var activeID: String?
    @FocusState private var keyboardFocused: Bool

    private var hasCheckmarks: Bool { items.contains(where: \.selected) }

    static func width(for items: [LyraReaderMenuItem]) -> CGFloat {
        let title = items.filter { !$0.isSeparator }.map {
            ($0.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        }.max() ?? 0
        let shortcut = items.compactMap(\.shortcut).map {
            ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        }.max() ?? 0
        let checks: CGFloat = items.contains(where: \.selected) ? 20 : 0
        return ceil(max(160, 10 + 16 + 18 + 16 + title + (shortcut > 0 ? shortcut + 8 : 0) + checks))
    }

    static func height(for items: [LyraReaderMenuItem]) -> CGFloat {
        10 + CGFloat(items.filter { !$0.isSeparator }.count) * 30
            + CGFloat(items.filter(\.isSeparator).count) * 11 + CGFloat(max(0, items.count - 1)) * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                if item.isSeparator {
                    LyraReaderTheme.separator.frame(height: 1).padding(.horizontal, 6).padding(.vertical, 4)
                } else {
                    Button { perform(item) } label: {
                        HStack(spacing: 8) {
                            Group {
                                if let image = item.nativeImage { Image(nsImage: image) }
                                else { Image(systemName: item.icon) }
                            }
                                .font(.system(size: 14))
                                .foregroundStyle(item.enabled ? (item.color ?? LyraReaderTheme.iconPrimary) : LyraReaderTheme.textDisabled)
                                .frame(width: 18)
                            Text(item.title).font(.system(size: 12))
                            Spacer(minLength: 0)
                            if let shortcut = item.shortcut {
                                Text(shortcut).font(.system(size: 11)).foregroundStyle(LyraReaderTheme.textTertiary)
                            }
                            if hasCheckmarks {
                                Image(systemName: "checkmark")
                                    .opacity(item.selected ? 1 : 0).accessibilityHidden(true)
                                    .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                            }
                        }
                        .foregroundStyle(!item.enabled ? LyraReaderTheme.textDisabled :
                            (activeID == item.id ? LyraReaderTheme.menuSelectedFg : LyraReaderTheme.textPrimary))
                        .padding(.horizontal, 8).frame(height: 30)
                        .background(activeID == item.id && item.enabled ? LyraReaderTheme.menuSelectedBg : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain).disabled(!item.enabled).focusable(false)
                    .help(item.help ?? item.title)
                    .onHover { hovered in if hovered && item.enabled { activeID = item.id } }
                    .accessibilityValue(item.selected ? "Selected" : "")
                }
            }
        }
        .padding(5).frame(width: Self.width(for: items))
        .background(LyraReaderTheme.menuBg)
        .focusable().focused($keyboardFocused).focusEffectDisabled()
        .onAppear { activeID = items.first(where: { $0.enabled && !$0.isSeparator })?.id; keyboardFocused = true }
        .onMoveCommand { direction in
            if direction == .down { move(1) }
            if direction == .up { move(-1) }
        }
        .onKeyPress(.return) { activate(); return .handled }
        .onKeyPress(.space) { activate(); return .handled }
        .onExitCommand(perform: dismiss)
    }

    private func move(_ direction: Int) {
        let enabled = items.filter { $0.enabled && !$0.isSeparator }
        guard !enabled.isEmpty else { return }
        let current = enabled.firstIndex { $0.id == activeID } ?? 0
        activeID = enabled[(current + direction + enabled.count) % enabled.count].id
    }
    private func activate() {
        if let item = items.first(where: { $0.id == activeID }) { perform(item) }
    }
    private func perform(_ item: LyraReaderMenuItem) {
        guard item.enabled else { return }
        dismiss()
        // Close the transient panel before presenting a save sheet, note prompt, or Settings.
        DispatchQueue.main.async { item.action() }
    }
}

/// An anchor behind a SwiftUI button. The panel is positioned in screen coordinates so a
/// toolbar dropdown always opens below its button, independently of space above the window.
private struct LyraReaderMenuAnchor: NSViewRepresentable {
    @Binding var presented: Bool
    let items: [LyraReaderMenuItem]
    let placement: CGRect

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.requested = presented
        if view.placement != placement { view.placement = placement; view.needsLayout = true }
        view.present = { [weak view] in
            guard let view, view.requested, let window = view.window else { return }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            LyraReaderMenuPresenter.shared.show(items: items, below: rect, in: window,
                                              owner: view, dismiss: { presented = false })
        }
        if presented { view.schedulePresentation() }
        else {
            LyraReaderMenuPresenter.shared.dismiss(owner: view)
        }
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.requested = false; view.present = nil
        LyraReaderMenuPresenter.shared.dismiss(owner: view)
    }
    final class AnchorView: NSView {
        var requested = false
        var placement = CGRect.zero
        var present: (() -> Void)?
        private var pending = false
        override func layout() { super.layout(); schedulePresentation() }
        override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); schedulePresentation() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); schedulePresentation() }
        func schedulePresentation() {
            guard requested, !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                if self.requested { self.present?() }
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// One transient command surface at a time. No NSPopover edge flipping or system menu padding.
@MainActor final class LyraReaderMenuPresenter {
    static let shared = LyraReaderMenuPresenter()
    private var panel: CommandPanel?
    private weak var owner: NSView?
    private var onDismiss: (() -> Void)?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    func show(menu: NSMenu, at point: NSPoint, in window: NSWindow, owner: NSView) {
        let items = menu.items.enumerated().map { index, source -> LyraReaderMenuItem in
            if source.isSeparatorItem { return .separator("separator-\(index)") }
            let shortcut = source.keyEquivalent.isEmpty ? nil : "⌘" + source.keyEquivalent.uppercased()
            var item = LyraReaderMenuItem(source.title, icon: "doc", shortcut: shortcut,
                                    enabled: source.isEnabled, selected: source.state == .on) {
                menu.performActionForItem(at: index)
            }
            item.nativeImage = source.image
            return item
        }
        show(items: items, below: NSRect(origin: point, size: .zero), in: window,
             owner: owner, contextMenu: true, dismiss: {})
    }

    func show(items: [LyraReaderMenuItem], below anchor: NSRect, in window: NSWindow,
              owner: NSView, contextMenu: Bool = false, dismiss: @escaping () -> Void) {
        guard !items.isEmpty else { close(); return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let width = LyraReaderMenuContent.width(for: items)
        let naturalHeight = LyraReaderMenuContent.height(for: items)
        let top = anchor.minY - (contextMenu ? 0 : 5)
        let available = max(1, top - visible.minY - 5)
        let height = contextMenu ? min(naturalHeight, visible.height - 10) : min(naturalHeight, available)
        let preferredX = contextMenu ? anchor.minX : anchor.maxX - width
        let x = min(max(preferredX, visible.minX + 5), visible.maxX - width - 5)
        let y = contextMenu ? max(visible.minY + 5, top - height) : top - height
        let frame = NSRect(x: x, y: y, width: width, height: height)
        if self.owner === owner, let panel {
            // Content layout can settle after the menu opens, for example when a scroller appears.
            // Move the existing panel without recreating its keyboard focus or selection.
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            return
        }
        close()
        self.owner = owner
        onDismiss = dismiss
        let panel = CommandPanel(contentRect: frame,
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = window.effectiveAppearance
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel(contextMenu ? "Document commands" : "Toolbar commands")
        let content = ScrollView(.vertical) {
            LyraReaderMenuContent(items: items, dismiss: { [weak self] in self?.close() })
        }
        .scrollIndicators(.hidden)
        .frame(width: width, height: height)
        .background(LyraReaderTheme.menuBg)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(LyraReaderTheme.border, lineWidth: 1))
        panel.contentView = NSHostingView(rootView: content)
        self.panel = panel
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            MainActor.assumeIsolated {
                if event.window !== panel { self?.close() }
            }
            return event
        }
        let center = NotificationCenter.default
        for (name, object) in [(NSWindow.didResignKeyNotification, panel as AnyObject),
                               (NSWindow.willCloseNotification, window as AnyObject),
                               (NSWindow.didMoveNotification, window as AnyObject),
                               (NSWindow.didResizeNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
    }

    func dismiss(owner: NSView) { if self.owner === owner { close() } }

    private func close() {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        owner = nil
        let dismissed = onDismiss
        onDismiss = nil
        // SwiftUI may be updating or processing the anchor button's click. Let that finish
        // before clearing its state, otherwise clicking the open anchor would reopen the menu.
        if let dismissed { DispatchQueue.main.async { dismissed() } }
    }

    private final class CommandPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}

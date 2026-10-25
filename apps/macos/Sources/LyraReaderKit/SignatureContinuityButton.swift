import AppKit
import SwiftUI

/// AppKit supplies Continuity's device actions in a contextual menu when the owning view is
/// an image requestor. A normal pop-up with a custom pasteboard action never starts a sketch.
/// https://developer.apple.com/documentation/appkit/supporting-continuity-camera-in-your-mac-app
package struct SignatureContinuityButton: NSViewRepresentable {
    package let controller: FillSignCommandController
    package let enabled: Bool

    package func makeNSView(context: Context) -> ContinuitySignatureRequestor {
        let button = ContinuitySignatureRequestor(controller: controller)
        button.isEnabled = enabled
        return button
    }

    package func updateNSView(_ button: ContinuitySignatureRequestor, context: Context) {
        button.update(controller: controller, enabled: enabled)
    }

    package static func dismantleNSView(_ button: ContinuitySignatureRequestor, coordinator: ()) {
        button.invalidateRequest()
    }
}

@MainActor
package final class ContinuitySignatureRequestor: NSButton,
    @preconcurrency NSServicesMenuRequestor {
    private var controller: FillSignCommandController
    private struct Destination: Equatable {
        let documentID: UUID
        let tabID: UUID?
    }
    private var requestedDestination: Destination?
    private var keyboardFocusVisible = false

    private var currentDestination: Destination? {
        guard let documentID = controller.state.document?.id else { return nil }
        let state = controller.state
        let tabID = state.activeTabIndex.flatMap {
            state.tabs.indices.contains($0) ? state.tabs[$0].id : nil
        }
        return Destination(documentID: documentID, tabID: tabID)
    }

    package init(controller: FillSignCommandController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        title = "From iPhone or iPad"
        bezelStyle = .rounded
        isBordered = false
        focusRingType = .none
        controlSize = .regular
        font = .systemFont(ofSize: 12)
        target = self
        action = #selector(showDeviceMenu(_:))
        toolTip = "Choose Add Sketch on a nearby device, then click the page to place your signature"
        setAccessibilityIdentifier("signature-continuity")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    package override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 32)
    }

    package override var acceptsFirstResponder: Bool { isEnabled }

    package func update(controller: FillSignCommandController, enabled: Bool) {
        if self.controller !== controller || requestedDestination != currentDestination || !enabled {
            invalidateRequest()
        }
        self.controller = controller
        isEnabled = enabled
    }

    /// Capture before menu tracking. Keep this responder after the menu closes: Continuity
    /// delivers asynchronously, after the person finishes (or cancels) on the other device.
    @discardableResult
    package func beginRequest() -> Bool {
        invalidateRequest()
        guard isEnabled, controller.state.canPlaceFillSignAnnotation,
              let destination = currentDestination, let window,
              window.makeFirstResponder(self) else { return false }
        requestedDestination = destination
        return true
    }

    package func invalidateRequest() { requestedDestination = nil }

    package override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor(isHighlighted ? LyraReaderTheme.pressedBg : LyraReaderTheme.fieldBg).setFill()
        shape.fill()
        let focused = keyboardFocusVisible && window?.firstResponder === self
        NSColor(focused ? LyraReaderTheme.focusRing : LyraReaderTheme.controlBorder).setStroke()
        shape.lineWidth = focused ? 2 : 1
        shape.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: LyraReaderTheme.textPrimaryColor.withAlphaComponent(isEnabled ? 1 : 0.45),
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: CGPoint(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }

    package override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var canReceiveSketch: Bool {
        isEnabled && requestedDestination != nil
            && requestedDestination == currentDestination
            && controller.state.canPlaceFillSignAnnotation
            && window?.firstResponder === self
    }

    package override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // This service creates an image; it must not export an existing selection.
        if sendType == nil, let returnType,
           NSImage.imageTypes.contains(returnType.rawValue), canReceiveSketch {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    package func readSelection(from pasteboard: NSPasteboard) -> Bool {
        defer { invalidateRequest() }
        guard canReceiveSketch else { return false }
        return controller.receiveContinuitySelection(pasteboard)
    }

    package override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { invalidateRequest(); keyboardFocusVisible = false }
        needsDisplay = true
        return resigned
    }

    package override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        keyboardFocusVisible = NSApp.currentEvent?.type == .keyDown
        needsDisplay = true
        return focused
    }

    package override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { invalidateRequest() }
        super.viewWillMove(toWindow: newWindow)
    }

    package override func mouseDown(with event: NSEvent) {
        keyboardFocusVisible = false
        highlight(true)
        defer { highlight(false) }
        presentDeviceMenu(with: event)
    }

    @objc private func showDeviceMenu(_ sender: Any?) {
        // Accessibility and keyboard activation need the same contextual-menu path.
        guard let window, let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: convert(NSPoint(x: 0, y: bounds.minY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1) else { return }
        presentDeviceMenu(with: event)
    }

    // Retain the original system item for the duration of tracking, including its service data.
    private var deviceSourceItem: NSMenuItem?

    @objc private func deviceMenuDidAddItem(_ notification: Notification) {
        guard deviceSourceItem == nil, canReceiveSketch,
              let menu = notification.object as? NSMenu else { return }
        // Stop nested didAdd notifications from reentering while moving the original items.
        guard let item = Self.deviceGroupItem(in: menu) else { return }
        deviceSourceItem = item
        Self.showDeviceGroups(in: menu, from: item)
    }

    package static func deviceGroupItem(in menu: NSMenu) -> NSMenuItem? {
        let items = menu.items.filter { !$0.isSeparatorItem }
        guard items.count == 1, let item = items.first,
              item.identifier == NSMenuItem.importFromDeviceIdentifier,
              let actions = item.submenu, !actions.items.isEmpty else { return nil }
        return item
    }

    package static func showDeviceGroups(in menu: NSMenu, from item: NSMenuItem) {
        guard let actions = item.submenu else { return }
        let deviceItems = actions.items
        menu.removeAllItems()
        for action in deviceItems {
            actions.removeItem(action)
            menu.addItem(action)
        }
    }

    private func presentDeviceMenu(with event: NSEvent) {
        guard beginRequest() else { return }
        deviceSourceItem = nil
        NotificationCenter.default.addObserver(self,
            selector: #selector(deviceMenuDidAddItem(_:)),
            name: NSMenu.didAddItemNotification, object: nil)
        defer {
            NotificationCenter.default.removeObserver(self,
                name: NSMenu.didAddItemNotification, object: nil)
            deviceSourceItem = nil
        }
        let menu = NSMenu(title: "From iPhone or iPad")
        // AppKit builds a separate contextual menu after menuWillOpen. Observe only during
        // this synchronous request and expand its public import marker in that live menu.
        // Moving the actual items preserves device targets, payloads and system validation.
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

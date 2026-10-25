import AppKit

/// What a double-click on the custom titlebar row should do.
///
/// macOS exposes this as the global `AppleActionOnDoubleClick` preference: System Settings →
/// Desktop & Dock → "Double-click a window's title bar to" offers Zoom, Minimise and Do Nothing
/// (the stored values are `Maximize`, `Minimize` and `None`). The names here are the reader-facing
/// actions, not the stored strings, so the default is explicit: an absent or unrecognised value
/// means zoom, which is macOS's own default.
public enum TitlebarDoubleClickAction: String, CaseIterable, Sendable {
    case zoom
    case minimize
    case none

    /// The action for a raw preference value. `nil` (the key is unset) and values written by
    /// older macOS releases fall back to the platform default, zoom.
    public init(preferenceValue: String?) {
        switch preferenceValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "minimize": self = .minimize
        case "none": self = .none
        case "maximize", "zoom", nil: self = .zoom
        default: self = .zoom
        }
    }

    /// Runs the action through AppKit's standard window commands. Using `performZoom` and
    /// `miniaturize` rather than setting frames or flags keeps the window's own zoom state, the
    /// green button and full-screen transitions consistent.
    @MainActor
    public func perform(on window: NSWindow) {
        switch self {
        case .zoom: window.performZoom(nil)
        case .minimize: window.miniaturize(nil)
        case .none: break
        }
    }
}

/// The system titlebar double-click preference and its application to one window.
///
/// The window draws its own 44 pt titlebar strip, so AppKit never sees the double-click that a
/// standard titlebar would handle itself. The strip's empty AppKit drag area forwards the gesture
/// here, and this type translates the global preference into the same standard window action.
@MainActor
public enum ReaderTitlebarDoubleClick {
    /// The global preference System Settings writes. Read from `UserDefaults.standard`, whose
    /// search list includes `NSGlobalDomain`; this is the key AppKit's own titlebar consults.
    public static let preferenceKey = "AppleActionOnDoubleClick"

    /// A check seam: set this to pretend the preference has a given value (or `.some(nil)` to
    /// pretend it is unset) without writing the person's global defaults. `nil` means "read the
    /// real preference". The app never sets it.
    public static var preferenceOverride: String??

    /// The action the next double-click should perform.
    public static var action: TitlebarDoubleClickAction {
        if let override = preferenceOverride {
            return TitlebarDoubleClickAction(preferenceValue: override)
        }
        return TitlebarDoubleClickAction(preferenceValue: UserDefaults.standard.string(forKey: preferenceKey))
    }

    /// Applies the current preference to `window`; a double-click with no window does nothing.
    public static func perform(on window: NSWindow?) {
        guard let window else { return }
        action.perform(on: window)
    }
}

/// The empty, draggable part of the custom titlebar row (and the titlebar's leading inset when it
/// is used for that).
///
/// A single press still starts the standard window drag, so drag-to-move is unchanged. A
/// double-click performs the user's titlebar action instead. The tab titles, their close buttons
/// and the add button are separate SwiftUI views above this one and never reach it.
public final class ReaderTitlebarDragView: NSView {
    public override var mouseDownCanMoveWindow: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            ReaderTitlebarDoubleClick.perform(on: window)
            return
        }
        window?.performDrag(with: event)
    }
}

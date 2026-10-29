// Focus and place the reader's window for a native measurement run.
//
// The app activates itself on launch, but a command-line launch can still leave its window
// behind the terminal or on a display whose visible frame is smaller; Metal then reports zero
// host presentation timestamps and the presented metrics are "unavailable". This helper makes
// the window visible and frontmost *without touching the document or the render path*, so a
// measured run observes the same pixels a reader would. Window placement needs Accessibility
// permission; without it the app is still activated and the helper says `trusted=false`.
//
// Usage: focus-reader-window <pid> [x y width height]
// Prints one line: `lyra-perf-window: pid=… frontmost=… bounds=… scale=… trusted=…`
import AppKit
import ApplicationServices
import CoreGraphics

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("focus-reader-window: \(message)\n".utf8))
    exit(1)
}

func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
    return size
}

let arguments = CommandLine.arguments
guard arguments.count >= 2, let pid = Int32(arguments[1]) else {
    fail("usage: focus-reader-window <pid> [x y width height]")
}
guard let app = NSRunningApplication(processIdentifier: pid) else {
    fail("no running application with pid \(pid)")
}
let trusted = AXIsProcessTrusted()
let ax = AXUIElementCreateApplication(pid)
var windowsValue: CFTypeRef?
var window: AXUIElement?
if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &windowsValue) == .success,
   let windows = windowsValue as? [AXUIElement], let first = windows.first {
    window = first
}
if let window, arguments.count == 6,
   let x = Double(arguments[2]), let y = Double(arguments[3]),
   let width = Double(arguments[4]), let height = Double(arguments[5]) {
    var point = CGPoint(x: x, y: y)
    if let value = AXValueCreate(.cgPoint, &point) {
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }
    var size = CGSize(width: width, height: height)
    if let value = AXValueCreate(.cgSize, &size) {
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }
}
if let window {
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
}
_ = AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
_ = app.activate(options: [])

// Activation and the AX raise are asynchronous; give the window server one run-loop turn.
RunLoop.current.run(until: Date().addingTimeInterval(0.35))

var bounds = "unavailable"
if let window,
   let position = pointAttribute(window, kAXPositionAttribute as String),
   let size = sizeAttribute(window, kAXSizeAttribute as String) {
    bounds = "\(Int(position.x)),\(Int(position.y)),\(Int(size.width)),\(Int(size.height))"
}
let scale = NSScreen.main?.backingScaleFactor ?? 0
let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
print("lyra-perf-window: pid=\(pid) frontmost=\(frontmost) bounds=\(bounds) scale=\(scale) trusted=\(trusted)")

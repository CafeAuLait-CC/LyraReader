// Run scripts/measure-wheel.sh. Captures only scroll events delivered to this window;
// no global event tap, accessibility permission, document or credentials are involved.
import AppKit
import Foundation

@main
@MainActor
final class WheelProbe: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var output: FileHandle!
    private var monitor: Any?
    private var idle: DispatchWorkItem?
    private var motion = WheelMotion()
    private var mode = "slow"
    private var sequence = 0
    private var events = 0
    private var start: TimeInterval = 0
    private var end: TimeInterval = 0
    private var raw: CGFloat = 0
    private var points: CGFloat = 0
    private var precise = false
    private let status = NSTextField(wrappingLabelWithString: "")
    private let results = NSTextView()
    private let nativeScroll = NSScrollView()
    private var nativeStart: CGFloat = 0

    static func main() {
        let app = NSApplication.shared
        let delegate = WheelProbe()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = CommandLine.arguments.dropFirst().first ?? "/private/tmp/lyra-wheel-events.jsonl"
        FileManager.default.createFile(atPath: path, contents: nil)
        output = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Lyra · 鼠标滚轮距离探针"
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let instructions = NSTextField(wrappingLabelWithString:
            "先选「慢拨」或「快拨」，再在下方白色纸面拨一下滚轮，停止半秒。每种各做 3 次即可。会同时记录原生 AppKit 的滚动距离，供系统速度对照。\n只记录滚轮距离，不会访问或改动文档。")
        instructions.font = .systemFont(ofSize: 15)
        let buttons = NSStackView()
        buttons.spacing = 12
        buttons.addArrangedSubview(NSButton(title: "慢拨", target: self, action: #selector(slow)))
        buttons.addArrangedSubview(NSButton(title: "快拨", target: self, action: #selector(fast)))
        buttons.addArrangedSubview(NSButton(title: "完成并关闭", target: self, action: #selector(finish)))
        status.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        status.stringValue = "当前：慢拨。等待滚轮输入……"
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        results.isEditable = false
        results.isSelectable = true
        results.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        results.autoresizingMask = [.width]
        scroll.documentView = results
        nativeScroll.hasVerticalScroller = true
        nativeScroll.borderType = .bezelBorder
        nativeScroll.drawsBackground = true
        nativeScroll.backgroundColor = .white
        let nativeDocument = ProbePaper(frame: NSRect(x: 0, y: 0, width: 650, height: 500_000))
        nativeScroll.documentView = nativeDocument
        stack.addArrangedSubview(instructions)
        stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(status)
        stack.addArrangedSubview(nativeScroll)
        stack.addArrangedSubview(scroll)
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nativeScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nativeScroll.heightAnchor.constraint(equalToConstant: 220),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return }
                self.record(event)
            }
            return event
        }
        emit(["kind": "session", "points_per_line": Double(WheelMotion.pointsPerLine),
              "output": path, "gesture_idle_ms": 350])
        window.center()
        window.makeKeyAndOrderFront(nil)
        nativeScroll.contentView.scroll(to: NSPoint(x: 0, y: 200_000))
        nativeScroll.reflectScrolledClipView(nativeScroll.contentView)
        NSApp.activate(ignoringOtherApps: true)
        print("wheel-probe ready: \(path)")
        fflush(stdout)
    }

    @objc private func slow() { flush(); mode = "slow"; updateStatus() }
    @objc private func fast() { flush(); mode = "fast"; updateStatus() }
    @objc private func finish() { flush(); NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { flush(); try? output?.close() }

    private func updateStatus() {
        status.stringValue = "当前：\(mode == "slow" ? "慢拨" : "快拨")。等待滚轮输入……"
    }

    private func record(_ event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        if events > 0, event.timestamp - end > 0.35 { flush() }
        if events == 0 {
            start = event.timestamp; motion.reset()
            nativeStart = nativeScroll.contentView.bounds.minY
        }
        let delta = motion.delta(scrollingDeltaY: event.scrollingDeltaY,
                                 precise: event.hasPreciseScrollingDeltas, timestamp: event.timestamp)
        events += 1
        raw += event.scrollingDeltaY
        points += delta
        precise = precise || event.hasPreciseScrollingDeltas
        end = event.timestamp
        emit(["kind": "event", "gesture": sequence + 1, "mode": mode,
              "timestamp": event.timestamp, "raw_delta_y": Double(event.deltaY),
              "scrolling_delta_y": Double(event.scrollingDeltaY),
              "precise": event.hasPreciseScrollingDeltas, "phase": event.phase.rawValue,
              "momentum_phase": event.momentumPhase.rawValue, "current_points": Double(delta),
              "system_point_delta_y": event.cgEvent?.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) ?? 0])
        status.stringValue = String(format: "记录中：%d 个事件，当前 Lyra 距离 %.0f pt", events, abs(points))
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        idle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func flush() {
        idle?.cancel()
        idle = nil
        guard events > 0 else { return }
        sequence += 1
        let nativePoints = nativeScroll.contentView.bounds.minY - nativeStart
        emit(["kind": "gesture", "gesture": sequence, "mode": mode, "events": events,
              "duration_ms": (end - start) * 1000, "raw_sum_y": Double(raw),
              "current_points": Double(points), "precise": precise,
              "native_points": Double(nativePoints), "native_line_scroll": Double(nativeScroll.verticalLineScroll),
              "letter_pages_at_100_percent": Double(abs(points) / 804)])
        results.string += String(format: "#%d %@：%d 个事件 · %.0f ms · Lyra %.0f pt · 系统 %.0f pt\n",
                                 sequence, mode == "slow" ? "慢拨" : "快拨", events,
                                 (end - start) * 1000, abs(points), abs(nativePoints))
        results.scrollToEndOfDocument(nil)
        events = 0; raw = 0; points = 0; precise = false
        motion.reset()
        updateStatus()
    }

    private func emit(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        output.write(data)
        output.write(Data([10]))
    }
}

private final class ProbePaper: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        let first = Int(dirtyRect.minY / 100)
        let last = Int(dirtyRect.maxY / 100) + 1
        for line in first...last {
            let y = CGFloat(line) * 100
            NSColor.separatorColor.setStroke()
            NSBezierPath.strokeLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: bounds.width, y: y))
            ("原生系统滚动 · \(line * 100) pt" as NSString).draw(at: CGPoint(x: 18, y: y + 16),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

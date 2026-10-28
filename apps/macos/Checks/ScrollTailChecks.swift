import AppKit
import LyraReaderKit
import Foundation

extension ReaderChecks {
    @MainActor static func scrollGlideTailChecks() {
        func distance(interval: TimeInterval) -> CGFloat {
            var wheel = WheelMotion()
            var sum: CGFloat = 0
            for index in 0..<10 {
                sum += wheel.delta(scrollingDeltaY: -1, precise: false,
                                   timestamp: 1 + Double(index) * interval)
            }
            return sum
        }
        let slow = distance(interval: 0.15)
        let medium = distance(interval: 0.05)
        let fast = distance(interval: 0.01)
        require(slow == 250 && medium == slow && fast == slow,
                "event cadence never accelerates the system wheel distance a second time")
        var wheel = WheelMotion()
        _ = wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 1)
        require(wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 1.01) == 25,
                "a rapid event keeps the calibrated line distance")
        require(wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 1.11) == 25,
                "slowing the wheel leaves no retained boost")
        require(wheel.delta(scrollingDeltaY: 1, precise: false, timestamp: 1.12) == -25,
                "direction reversal moves immediately")
        require(wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 2) == 25,
                "a pause carries no acceleration debt")
        require(wheel.delta(scrollingDeltaY: 2.5, precise: true, timestamp: 2.1) == -2.5,
                "precise input preserves its system distance")
        require(wheel.delta(scrollingDeltaY: -1, precise: false, timestamp: 2.11) == 25,
                "a discrete event after precise input uses its own units")
    }

    @MainActor static func wheelGestureReplayChecks(root: URL) throws {
        struct Event: Decodable { let t: Double; let dy: CGFloat; let precise: Bool }
        struct Gesture: Decodable { let mode: String; let events: [Event] }
        struct Recording: Decodable {
            let reference_page_height_pt: CGFloat
            let gestures: [Gesture]
        }
        let data = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/mouse-wheel-gestures.json"))
        let recording = try JSONDecoder().decode(Recording.self, from: data)
        var pages: [String: [CGFloat]] = [:]
        for gesture in recording.gestures {
            var wheel = WheelMotion()
            let distance = gesture.events.reduce(CGFloat(0)) { sum, event in
                sum + wheel.delta(scrollingDeltaY: event.dy, precise: event.precise,
                                  timestamp: event.t)
            }
            pages[gesture.mode, default: []].append(abs(distance) / recording.reference_page_height_pt)
        }
        func median(_ mode: String) -> CGFloat {
            let sorted = pages[mode, default: []].sorted()
            guard !sorted.isEmpty else { fatalError("Missing real \(mode) wheel samples") }
            return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
        }
        require((0.7...1.5).contains(median("slow")), "real slow flick travels about one page")
        require((1.5...2.5).contains(median("fast")), "real quick flick travels about two pages")
    }

    @MainActor static func scrollTailDriverChecks(url: URL) async throws {
        let state = AppState(engine: try RustEngine(), preferFullPageRasters: false)
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: url), "wheel fixture opens")
        let view = MetalCanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.onScrollStep = { state.scrollByWheelStep($0) }
        view.onScroll = { state.scroll(byScreenPoints: $0) }
        func event(at seconds: TimeInterval, wheel: Int32 = -1) -> NSEvent {
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                             wheel1: wheel, wheel2: 0, wheel3: 0)!
            cg.timestamp = UInt64(seconds * 1_000_000_000)
            return NSEvent(cgEvent: cg)!
        }
        for interval in [0.15, 0.05, 0.01] {
            state.scroll(toFraction: 0.1)
            let start = state.scrollYPt
            for index in 0..<8 {
                let before = state.scrollYPt
                view.scrollWheel(with: event(at: 10 + Double(index) * interval))
                require(state.scrollYPt > before && state.scrollDestinationYPt == nil,
                        "wheel event \(index + 1) at \(Int(interval * 1000)) ms moves immediately with no debt")
            }
            let parked = state.scrollYPt
            require(abs((parked - start) * state.zoomFactor - 200) < 1e-6,
                    "eight wheel notches keep the same calibrated screen distance at every cadence")
            // Advance both the production arithmetic and the real driver's clock after input.
            for _ in 0..<20 { state.advanceScrollGlide(elapsed: 0.04) }
            try await Task.sleep(for: .milliseconds(160))
            require(state.scrollYPt == parked, "the document has zero motion after the final wheel event")
        }
        state.scroll(toFraction: 0.5)
        let beforeReverse = state.scrollYPt
        view.scrollWheel(with: event(at: 20, wheel: 1))
        require(state.scrollYPt < beforeReverse, "reversing the wheel reverses motion on the same event")
        state.scrollByWheelStep(-1_000_000)
        require(state.scrollYPt == 0 && state.scrollDestinationYPt == nil, "wheel motion clamps at the document top")
        state.scrollByWheelStep(1_000_000)
        let bottom = state.scrollYPt
        state.scrollByWheelStep(100)
        require(state.scrollYPt == bottom && state.scrollDestinationYPt == nil,
                "wheel motion clamps at the document bottom without animation")
        state.zoomIn()
        state.scroll(toFraction: 0.2)
        let zoomedStart = state.scrollYPt
        state.scrollByWheelStep(80)
        require(abs((state.scrollYPt - zoomedStart) * state.zoomFactor - 80) < 1e-6,
                "wheel distance remains in screen points after zooming")
    }
}

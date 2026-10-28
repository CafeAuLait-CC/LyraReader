import AppKit
import SwiftUI

enum PaperRevealCurve {
    static func value(_ fraction: Double) -> CGFloat {
        let t = min(1, max(0, fraction))
        return CGFloat(t * t * (3 - 2 * t))
    }
}

extension AppState {
    var canAnimateRegionPaper: Bool {
        !ReaderMotion.reduceMotionEnabled && attachedCanvas?.window?.isVisible == true
    }
    package func regionPaperRevealProgress(for id: UUID) -> CGFloat { regionPaperProgress[id] ?? 1 }
    func beginRegionPaperReveal(_ id: UUID) -> Bool {
        guard canAnimateRegionPaper else { return false }
        regionPaperProgress[id] = 0
        return true
    }
    func setRegionPaperProgress(_ id: UUID, _ value: CGFloat) {
        guard let card = regionCards.first(where: { $0.id == id }) else { return }
        let previous = regionGapTotalPt
        let top = regionGapTop(for: card) ?? 0
        regionPaperProgress[id] = min(1, max(0, value))
        let delta = regionGapTotalPt - previous
        if scrollYPt > top { scrollYPt = max(top, scrollYPt + delta) }
        refreshRegionPaperGeometry()
    }
    func animateRegionPaper(_ id: UUID, to target: CGFloat, completion: @escaping @MainActor () -> Void) {
        regionPaperMotionTasks[id]?.cancel()
        let token = UUID()
        regionPaperMotionIDs[id] = token
        let from = regionPaperRevealProgress(for: id)
        let started = ProcessInfo.processInfo.systemUptime
        regionPaperMotionTasks[id] = Task { @MainActor [weak self] in
            while let self, self.regionPaperMotionIDs[id] == token, !Task.isCancelled {
                let elapsed = (ProcessInfo.processInfo.systemUptime - started) / ReaderMotion.paperDuration
                let progress = ReaderMotion.reduceMotionEnabled ? CGFloat(1) : PaperRevealCurve.value(elapsed)
                self.setRegionPaperProgress(id, from + (target - from) * progress)
                if progress >= 1 {
                    self.regionPaperMotionTasks[id] = nil
                    self.regionPaperMotionIDs[id] = nil
                    completion()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
    func cancelRegionPaperMotions() {
        regionPaperMotionTasks.values.forEach { $0.cancel() }
        regionPaperMotionTasks.removeAll(); regionPaperMotionIDs.removeAll()
        regionPaperProgress.removeAll(); closingRegionPapers.removeAll()
    }
}

/// Reveal the paper from its top edge while keeping text at its resting size.
nonisolated struct PaperUnfoldModifier: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        content.opacity(0.65 + 0.35 * progress)
            .mask(alignment: .top) {
                GeometryReader { geometry in
                    Rectangle().frame(height: geometry.size.height * min(1, max(0, progress)))
                }
            }
    }
}

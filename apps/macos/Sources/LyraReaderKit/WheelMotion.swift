import Foundation

/// Discrete wheel deltas already reflect the system's acceleration. Convert their line units
/// to screen points once; multiplying again by event cadence made a quick flick cross 6–10 pages.
/// Precise devices already report screen-point distances and pass through unchanged.
public struct WheelMotion {
    /// Calibrated with real mouse gestures: median slow flick ~1 page, quick flick ~2 pages.
    public static let pointsPerLine: CGFloat = 25

    public init() {}

    /// Kept for gesture owners; wheel input carries no velocity or acceleration state.
    public mutating func reset() {}

    public mutating func delta(scrollingDeltaY: CGFloat, precise: Bool,
                               timestamp: TimeInterval) -> CGFloat {
        -scrollingDeltaY * (precise ? 1 : Self.pointsPerLine)
    }
}

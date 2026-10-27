import CoreGraphics
import Foundation

/// Geometry for dragging a tab to a new position in the custom tab strip.
///
/// The strip lays its tabs out itself (fixed width, fixed 4 pt spacing), so the drop position is
/// arithmetic rather than a chain of SwiftUI preference values: the insertion gap is the gap
/// nearest the pointer, and the dragged tab is inserted there. Keeping the arithmetic here — and
/// not inside the gesture closure — lets the checks drive the same numbers the row uses.
public enum TabReorder {
    /// The coordinate space of the row that contains the tabs and the add button. A drag gesture
    /// reports its location in this space, so the location does not depend on how far the
    /// `ScrollView` has scrolled.
    public static let coordinateSpaceName = "lyra.reader.tabStrip"

    /// Horizontal distance occupied by `tabCount` tabs and the gaps between them. The add
    /// button's own gap and width are not included.
    public static func contentWidth(
        tabCount: Int,
        tabWidth: CGFloat,
        spacing: CGFloat = TabRowLayout.tabSpacing
    ) -> CGFloat {
        guard tabCount > 0 else { return 0 }
        return CGFloat(tabCount) * tabWidth + CGFloat(tabCount - 1) * spacing
    }

    /// Total width of the strip's content: the tabs, the gap before the add button, and the add
    /// button. A drag that ends anywhere in this rectangle ends on the strip.
    public static func stripWidth(
        tabCount: Int,
        tabWidth: CGFloat,
        spacing: CGFloat = TabRowLayout.tabSpacing
    ) -> CGFloat {
        guard tabCount > 0 else { return TabRowLayout.plusButtonSize }
        return contentWidth(tabCount: tabCount, tabWidth: tabWidth, spacing: spacing)
            + spacing + TabRowLayout.plusButtonSize
    }

    /// The insertion gap nearest `x`, in `0...tabCount`, in the row's content coordinates.
    ///
    /// Gap 0 is before the first tab and gap `tabCount` is after the last one. A pointer past the
    /// midpoint of a tab inserts after that tab; the gaps themselves belong to the tab on their
    /// right, which is why a pointer that has only reached the first half of tab 1 still says
    /// "before tab 1".
    public static func insertionIndex(
        forX x: CGFloat,
        tabWidth: CGFloat,
        spacing: CGFloat = TabRowLayout.tabSpacing,
        tabCount: Int
    ) -> Int {
        guard tabCount > 0, tabWidth > 0 else { return 0 }
        let pitch = tabWidth + spacing
        guard pitch > 0 else { return 0 }
        let clamped = max(0, x)
        let tab = Int(clamped / pitch)
        guard tab < tabCount else { return tabCount }
        let offsetInTab = clamped - CGFloat(tab) * pitch
        return min(tabCount, offsetInTab < tabWidth / 2 ? tab : tab + 1)
    }

    /// Where the insertion indicator is drawn, in the row's content coordinates: the leading edge
    /// for gap 0, the middle of the gap for a gap between tabs, and the trailing edge for the final
    /// gap. The indicator is a vertical line centred on this x.
    public static func indicatorX(
        insertionIndex: Int,
        tabWidth: CGFloat,
        spacing: CGFloat = TabRowLayout.tabSpacing,
        tabCount: Int
    ) -> CGFloat {
        guard tabCount > 0 else { return 0 }
        let gap = min(max(insertionIndex, 0), tabCount)
        if gap == 0 { return 0 }
        if gap == tabCount {
            return contentWidth(tabCount: tabCount, tabWidth: tabWidth, spacing: spacing)
        }
        return CGFloat(gap - 1) * (tabWidth + spacing) + tabWidth + spacing / 2
    }

    /// The array index the dragged tab would occupy for `insertionIndex`, in the array *before*
    /// the move. `insertionIndex == sourceIndex` and `sourceIndex + 1` both leave the tab where it
    /// is: they are the gaps on either side of it.
    public static func destinationIndex(
        sourceIndex: Int,
        insertionIndex: Int,
        tabCount: Int
    ) -> Int? {
        guard sourceIndex >= 0, sourceIndex < tabCount else { return nil }
        let gap = min(max(insertionIndex, 0), tabCount)
        let destination = gap > sourceIndex ? gap - 1 : gap
        return destination == sourceIndex ? nil : destination
    }

    /// Whether a drag location is still on *this* strip. The row is 44 pt high; leaving it
    /// vertically (into the toolbar below, or above the titlebar) means the coordinator must
    /// decide the drop — another window's strip, or a tear-off. Horizontally the add button still
    /// belongs to the strip, so dropping on it means "after the last tab".
    public static func isInsideStrip(
        location: CGPoint,
        tabCount: Int,
        tabWidth: CGFloat,
        spacing: CGFloat = TabRowLayout.tabSpacing
    ) -> Bool {
        guard location.y >= 0, location.y <= TabRowLayout.height else { return false }
        let width = stripWidth(tabCount: tabCount, tabWidth: tabWidth, spacing: spacing)
        return location.x >= 0 && location.x <= width
    }
}

/// One in-flight tab drag. The view owns an instance while the pointer is down; the checks drive
/// the same value to assert what a drop does.
public struct TabDragSession: Equatable {
    public let sourceIndex: Int
    public let tabCount: Int
    public let tabWidth: CGFloat
    public let spacing: CGFloat

    /// The local insertion gap, in `0...tabCount`, accounting for the initial grab offset.
    public private(set) var insertionIndex: Int
    /// Whether the latest location is on the strip (see `TabReorder.isInsideStrip`).
    public private(set) var isInsideStrip: Bool
    /// Translation from the drag's start, used to follow the pointer with the dragged tab.
    public private(set) var translation: CGSize
    private var pressLocationX: CGFloat?

    public init(
        sourceIndex: Int,
        tabCount: Int,
        tabWidth: CGFloat,
        spacing: CGFloat = TabRowLayout.tabSpacing
    ) {
        self.sourceIndex = sourceIndex
        self.tabCount = tabCount
        self.tabWidth = tabWidth
        self.spacing = spacing
        self.insertionIndex = sourceIndex
        self.isInsideStrip = true
        self.translation = .zero
    }

    /// Updates the drop position from a `DragGesture` location in the strip's coordinate space.
    public mutating func update(location: CGPoint, translation: CGSize = .zero) {
        let startX = pressLocationX ?? (location.x - translation.width)
        pressLocationX = startX
        let displacement = location.x - startX
        isInsideStrip = TabReorder.isInsideStrip(
            location: location, tabCount: tabCount, tabWidth: tabWidth, spacing: spacing)
        self.translation = CGSize(width: displacement, height: translation.height)
        insertionIndex = sourceIndex
        let pitch = tabWidth + spacing
        guard isInsideStrip, tabCount > 0, tabWidth > 0, pitch > 0,
              abs(displacement) >= tabWidth / 2 else { return }
        // Swap after half a tab's travel, regardless of where the title or padding was grabbed.
        // Further neighbours are one pitch apart. Keep the anchor when mouse-up supplies only
        // the final location, so releasing cannot undo the shorter-distance reorder.
        let steps = Int(min(CGFloat(tabCount),
                            1 + floor((abs(displacement) - tabWidth / 2) / pitch)))
        let destination = min(tabCount - 1, max(0,
            sourceIndex + (displacement < 0 ? -steps : steps)))
        insertionIndex = destination > sourceIndex ? destination + 1 : destination
    }

    /// The array index the tab would occupy for a reorder in this strip, or `nil` when the drop
    /// would change nothing. This is only the local, reorder half; the coordinator decides whether
    /// the drop is local at all.
    public var dropDestination: Int? {
        guard isInsideStrip else { return nil }
        return TabReorder.destinationIndex(
            sourceIndex: sourceIndex, insertionIndex: insertionIndex, tabCount: tabCount)
    }

    /// The x of the insertion indicator in the strip's content coordinates.
    public var indicatorX: CGFloat {
        TabReorder.indicatorX(
            insertionIndex: insertionIndex, tabWidth: tabWidth,
            spacing: spacing, tabCount: tabCount)
    }
}

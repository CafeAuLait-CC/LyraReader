import AppKit
import Foundation
import LyraReaderBindings
import LyraReaderKit

// Equivalence evidence for moving the Back/Forward state machine from Swift into
// `lyra-reader-session` (driven through `LyraReaderNavigationHistory`).
//
// `LegacyNavigationHistory` below is the **pre-change** Swift implementation, copied from
// `AppState.swift` at `ffc53b9` (the "Preview jumps and Back" section) and kept only as the
// check's oracle. It is not production code: the shell no longer pushes, clears or trims a stack
// itself. Every scripted step drives both implementations and compares the stacks, the direction
// flags and the target location Back/Forward returned.
//
// A second scenario uses the real `AppState` and PDF engine to prove the location still
// round-trips through the published mirror and that the unchanged Swift apply path still clamps a
// remembered offset against shrunken content and re-derives the page from the clamped offset.
extension ReaderChecks {
    /// One location in the check's own value space; `Double` so the FFI record compares directly.
    private struct Location: Equatable {
        var page: Int
        var scrollYPt: Double
        var selection: SelectionValue?
    }

    private struct SelectionValue: Equatable {
        var page: Int
        var start: Int
        var end: Int
    }

    /// The old Swift stacks. This mirrors `AppState.swift` at `ffc53b9` exactly:
    /// `recordReaderLocation` appends and clears forward; `goBack`/`goForward` pop the newest
    /// entry, push the current location onto the other stack and trim; `trimNavigationHistory`
    /// drops from the front; a direction returns false when its stack is empty.
    private struct LegacyNavigationHistory {
        static let limit = 20

        var back: [Location] = []
        var forward: [Location] = []

        var canGoBack: Bool { !back.isEmpty }
        var canGoForward: Bool { !forward.isEmpty }

        mutating func record(_ location: Location) {
            back.append(location)
            // A new jump has a new future: the forward branch it replaced is stale.
            forward.removeAll()
            trim()
        }

        mutating func goBack(current: Location) -> Location? {
            guard let target = back.popLast() else { return nil }
            forward.append(current)
            trim()
            return target
        }

        mutating func goForward(current: Location) -> Location? {
            guard let target = forward.popLast() else { return nil }
            back.append(current)
            trim()
            return target
        }

        mutating func clear() {
            back = []
            forward = []
        }

        private mutating func trim() {
            if back.count > Self.limit {
                back.removeFirst(back.count - Self.limit)
            }
            if forward.count > Self.limit {
                forward.removeFirst(forward.count - Self.limit)
            }
        }
    }

    private static func location(from record: ReaderLocationRecord) -> Location {
        Location(
            page: Int(record.page),
            scrollYPt: record.scrollYPt,
            selection: record.selection.map {
                SelectionValue(page: Int($0.page), start: Int($0.start), end: Int($0.end))
            })
    }

    private static func record(from location: Location) -> ReaderLocationRecord {
        ReaderLocationRecord(
            page: UInt32(location.page),
            scrollYPt: location.scrollYPt,
            selection: location.selection.map {
                ReaderSelectionRecord(
                    page: UInt32($0.page), start: UInt32($0.start), end: UInt32($0.end))
            })
    }

    @MainActor static func navigationHistoryChecks(url: URL) async throws {
        let history = LyraReaderNavigationHistory()
        var legacy = LegacyNavigationHistory()

        func stacks() -> (back: [Location], forward: [Location]) {
            let snapshot = history.snapshot()
            return (snapshot.back.map(location(from:)), snapshot.forward.map(location(from:)))
        }

        func requireSameStacks(_ step: String) {
            let rust = stacks()
            require(rust.back == legacy.back && rust.forward == legacy.forward,
                    "\(step): Rust stacks equal the pre-change Swift stacks")
            require((!rust.back.isEmpty) == legacy.canGoBack
                        && (!rust.forward.isEmpty) == legacy.canGoForward,
                    "\(step): canGoBack/canGoForward equal the pre-change flags")
        }

        func recordBoth(_ value: Location, _ step: String) {
            history.record(location: record(from: value))
            legacy.record(value)
            requireSameStacks(step)
        }

        func backBoth(current: Location, _ step: String) -> Bool {
            let rustTarget = history.goBack(current: record(from: current)).map(location(from:))
            let swiftTarget = legacy.goBack(current: current)
            require(rustTarget == swiftTarget, "\(step): Back returns the pre-change target")
            requireSameStacks(step)
            return rustTarget != nil
        }

        func forwardBoth(current: Location, _ step: String) -> Bool {
            let rustTarget = history.goForward(current: record(from: current)).map(location(from:))
            let swiftTarget = legacy.goForward(current: current)
            require(rustTarget == swiftTarget, "\(step): Forward returns the pre-change target")
            requireSameStacks(step)
            return rustTarget != nil
        }

        require(Int(LyraReaderBindings.navigationHistoryLimit()) == 20
                    && AppState.navigationHistoryLimit == 20,
                "the history cap is 20 on both sides of the FFI")
        requireSameStacks("empty history")

        // ── Record after record, including a selection and a non-integral offset ──────────────
        let first = Location(page: 0, scrollYPt: 0, selection: nil)
        let second = Location(page: 1, scrollYPt: 913.25, selection: nil)
        let third = Location(page: 2, scrollYPt: 1804.5,
                             selection: SelectionValue(page: 2, start: 10, end: 24))
        recordBoth(first, "first record")
        recordBoth(second, "second record")
        recordBoth(third, "third record with selection")
        require(stacks().back.last == third, "the newest record is the next Back target")
        require(stacks().back.first == first, "the stack keeps oldest-first order")
        require(!legacy.canGoForward, "recording does not create a forward branch")

        // Forward is empty: both return false/nil and change nothing.
        let noForwardCurrent = Location(page: 0, scrollYPt: 5, selection: nil)
        _ = forwardBoth(current: noForwardCurrent, "Forward with an empty branch")

        // ── Alternating Back and Forward ─────────────────────────────────────────────────────
        let firstBackCurrent = Location(page: 1, scrollYPt: 700.5, selection: nil)
        require(backBoth(current: firstBackCurrent, "first Back"),
                "Back succeeds with a recorded entry")
        require(stacks().back == [first, second], "first Back pops the newest entry")
        require(stacks().forward == [firstBackCurrent],
                "first Back pushes the current location forward")

        let secondBackCurrent = Location(page: 0, scrollYPt: 40, selection: nil)
        require(backBoth(current: secondBackCurrent, "second Back"), "second Back succeeds")
        require(stacks().back == [first], "second Back walks further back")
        require(stacks().forward == [firstBackCurrent, secondBackCurrent],
                "the forward branch keeps the locations Back left")

        let forwardCurrent = Location(page: 2, scrollYPt: 1777,
                                      selection: SelectionValue(page: 2, start: 0, end: 5))
        require(forwardBoth(current: forwardCurrent, "middle Forward"), "Forward succeeds after Back")
        require(stacks().back == [first, forwardCurrent],
                "Forward pushes the current location back")
        require(stacks().forward == [firstBackCurrent], "Forward pops its newest entry")

        // A new record while a forward branch exists clears it.
        let recordCurrent = Location(page: 1, scrollYPt: 512, selection: nil)
        recordBoth(recordCurrent, "record over a forward branch")
        require(stacks().back == [first, forwardCurrent, recordCurrent],
                "the record lands after the Forward target")
        require(stacks().forward.isEmpty && !legacy.canGoForward,
                "a new record clears the forward branch")

        // ── Back to empty and Forward to empty ───────────────────────────────────────────────
        var guardCount = 0
        while legacy.canGoBack && guardCount < 100 {
            let drainCurrent = Location(page: guardCount % 3,
                                        scrollYPt: Double(guardCount) * 31.5,
                                        selection: nil)
            require(backBoth(current: drainCurrent, "drain Back \(guardCount)"),
                    "Back drains the stack")
            guardCount += 1
        }
        require(guardCount == 3, "the three-entry branch drains in three Backs")
        let drainedBack = stacks()
        require(!backBoth(current: Location(page: 1, scrollYPt: 99, selection: nil),
                          "Back at empty"),
                "Back at empty returns false")
        require(stacks() == drainedBack, "a false Back does not move the stacks")

        guardCount = 0
        while legacy.canGoForward && guardCount < 100 {
            let drainCurrent = Location(page: guardCount % 3,
                                        scrollYPt: Double(guardCount) * 23.25,
                                        selection: nil)
            require(forwardBoth(current: drainCurrent, "drain Forward \(guardCount)"),
                    "Forward drains the branch")
            guardCount += 1
        }
        require(guardCount == 3, "the three-entry forward branch drains in three Forwards")
        let drainedForward = stacks()
        require(!forwardBoth(current: Location(page: 2, scrollYPt: 1, selection: nil),
                             "Forward at empty"),
                "Forward at empty returns false")
        require(stacks() == drainedForward, "a false Forward does not move the stacks")

        // ── Trim beyond 20: the oldest entries are the ones dropped ──────────────────────────
        history.clear()
        legacy.clear()
        requireSameStacks("clear")
        for page in 0..<(LegacyNavigationHistory.limit + 5) {
            recordBoth(Location(page: page, scrollYPt: Double(page) * 10.0, selection: nil),
                       "record \(page) for trim")
        }
        let keptPages = stacks().back.map(\.page)
        let droppedPages = (0..<(LegacyNavigationHistory.limit + 5)).filter { !keptPages.contains($0) }
        print("TRIM: kept pages \(keptPages), dropped pages \(droppedPages)")
        require(keptPages == Array(5..<25), "trim keeps the twenty newest entries")
        require(droppedPages == Array(0..<5), "trim drops the five oldest entries")
        require(stacks().back.count == 20 && legacy.back.count == 20,
                "both implementations cap the back stack at 20")

        // Walk all twenty Backs: Forward reaches exactly the cap, and never needs its trim.
        for index in 0..<LegacyNavigationHistory.limit {
            let trimCurrent = Location(page: index, scrollYPt: 0, selection: nil)
            require(backBoth(current: trimCurrent, "trim Back \(index)"),
                    "Back inside the cap succeeds")
        }
        require(stacks().forward.count == 20 && stacks().back.isEmpty,
                "twenty Backs fill a twenty-entry forward branch")
        require(stacks().forward.count <= AppState.navigationHistoryLimit,
                "Forward never exceeds the cap")

        // ── Clear ────────────────────────────────────────────────────────────────────────────
        history.clear()
        legacy.clear()
        requireSameStacks("clear after a full branch")
        require(!historyCanGoBack(history) && !historyCanGoForward(history),
                "clear empties both directions")

        // ── AppState integration: mirror round-trip, clamp and page re-derivation ────────────
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 700, height: 500))
        require(state.open(url: url), "the navigation-history fixture opens")
        state.gotoPage(1)
        state.scroll(byScreenPoints: 123)
        let startOffset = state.scrollYPt
        let startPage = state.currentPage
        require(startOffset > 0 && startPage == 2,
                "the reader starts partway down the second page")

        let target = min(2, (state.document?.pageCount ?? 1) - 1)
        state.jumpFromPreview(to: target)
        require(state.backHistory.count == 1 && state.canGoBack,
                "a preview jump records through the FFI object")
        guard let stored = state.backHistory.last else {
            fatalError("FAIL: missing mirrored history entry")
        }
        require(stored.page == startPage - 1 && stored.scrollYPt == startOffset,
                "the published mirror round-trips page and exact offset")
        require(stored.selection == state.selection,
                "the published mirror round-trips the selection (nil here)")

        require(state.goBack(), "Back succeeds through the FFI object")
        require(state.scrollYPt == startOffset && state.currentPage == startPage,
                "Back restores the exact offset and re-derives the same page")
        require(state.forwardHistory.count == 1, "Back publishes its forward branch")
        require(!state.canGoBack && state.canGoForward,
                "the published flags follow the Rust stacks")

        // Record again, then make the viewport tall enough that the remembered offset is beyond
        // the new maximum. The Swift apply path stays put and must clamp, while the page is
        // re-derived from the clamped offset.
        state.jumpFromPreview(to: target)
        guard let remembered = state.backHistory.last else {
            fatalError("FAIL: missing second mirrored history entry")
        }
        state.setViewportSize(CGSize(width: 700, height: 2200))
        let expected = CGFloat(LyraReaderBindings.clampScroll(
            offsetPt: Double(remembered.scrollYPt),
            contentHeightPt: Double(state.contentHeightPt),
            viewportHeightPt: 2200))
        require(expected < remembered.scrollYPt,
                "the taller viewport really shrinks the scrollable range")
        require(state.goBack(), "Back succeeds against shrunken content")
        require(state.scrollYPt == expected,
                "Back clamps the remembered offset to the shrunken content")
        require(state.currentPage
                    == state.engine.pageIndex(atScrollYPt: state.scrollYPt, gapPt: state.pageGapPt) + 1,
                "the page is re-derived from the clamped offset exactly as before")
        require(state.currentPage == 1, "the clamped offset lands on the first page")
    }

    private static func historyCanGoBack(_ history: LyraReaderNavigationHistory) -> Bool {
        !history.snapshot().back.isEmpty
    }

    private static func historyCanGoForward(_ history: LyraReaderNavigationHistory) -> Bool {
        !history.snapshot().forward.isEmpty
    }
}

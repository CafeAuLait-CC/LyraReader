import AppKit
import Foundation
import LyraReaderKit
import SwiftUI

/// The secondary toolbar's rows: Annotate, Edit, Fill & Sign and Export share one slot, each
/// reveals with the pinned-progress slide, and the right-hand inspector follows the armed tool.
///
/// The checks measure the real reader window through hit testing and the chrome markers the
/// transition views already expose, not a private layout mirror. The measurement rows host the
/// real SwiftUI rows through `ReaderToolbarProbe`, so the item order is the order a reader sees.
extension ReaderChecks {
    @MainActor static func toolbarRowsChecks(root: URL) async throws {
        _ = NSApplication.shared
        // Use a scratch copy, not the checked-in fixture: this suite places and undoes
        // annotations, and the reader's process-wide annotation cache is keyed by path. Writing
        // to the repository fixture would leave a dirty cache for every later suite that opens
        // it (the titlebar discard check's "clean second tab" is the one that caught this).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyra-reader-toolbar-rows-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("toolbar-rows.pdf")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: fixture)

        // ── 1. The rows and their one-at-a-time state machine ────────────────────────────
        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 1200, height: 800))
        state.newTab(url: fixture)
        try await eventually("the toolbar-rows fixture opens", { state.document != nil })
        require(state.openSecondaryRows.isEmpty, "no secondary row is open at launch")

        state.toggleFillAndSign()
        require(state.openSecondaryRows == [.fillAndSign],
                "the Fill & Sign button opens exactly its row")
        state.toggleContentEditing()
        require(state.openSecondaryRows == [.contentEdit],
                "opening Edit closes Fill & Sign")
        state.toggleAnnotationTools()
        require(state.openSecondaryRows == [.annotations],
                "opening Annotate closes Edit")
        state.toggleExport()
        require(state.openSecondaryRows == [.export],
                "opening Export closes Annotate")
        state.toggleFillAndSign()
        require(state.openSecondaryRows == [.fillAndSign],
                "opening Fill & Sign closes Export")
        state.toggleFillAndSign()
        require(state.openSecondaryRows.isEmpty, "clicking the selected row's button closes it")

        // Every row's main toolbar button is its only close control: clicking it again closes
        // the row (the row itself has no xmark). Fill & Sign is covered above; the other four
        // buttons are exercised through the same toggle rule here.
        state.toggleAnnotationTools()
        require(state.openSecondaryRows == [.annotations], "the Annotate button opens Annotate")
        state.toggleAnnotationTools()
        require(state.openSecondaryRows.isEmpty, "the Annotate button closes Annotate")
        state.toggleContentEditing()
        require(state.openSecondaryRows == [.contentEdit], "the Edit button opens Edit")
        state.toggleContentEditing()
        require(state.openSecondaryRows.isEmpty, "the Edit button closes Edit")
        state.toggleExport()
        require(state.openSecondaryRows == [.export], "the Export button opens Export")
        state.toggleExport()
        require(state.openSecondaryRows.isEmpty, "the Export button closes Export")
        state.toggleAITools()
        require(state.openSecondaryRows == [.lyra], "the Lyra button opens Lyra")
        state.toggleAITools()
        require(state.openSecondaryRows.isEmpty, "the Lyra button closes Lyra")

        // Direct assignments take the same path: no caller can open a second row.
        state.contentEditEnabled = true
        state.fillAndSignVisible = true
        require(state.openSecondaryRows == [.fillAndSign],
                "assigning a row's boolean directly still closes the others")
        state.annotationToolsVisible = true
        require(state.openSecondaryRows == [.annotations],
                "the annotation row's direct assignment closes Fill & Sign")
        state.exportVisible = true
        require(state.openSecondaryRows == [.export],
                "the Export row's direct assignment closes Annotate")
        state.pageOverviewVisible = true
        require(state.openSecondaryRows == [.export],
                "page overview leaves the row's state alone so closing it restores the row")
        state.pageOverviewVisible = false
        state.exportVisible = false
        require(state.openSecondaryRows.isEmpty, "the row slot is empty after closing page overview")

        // ── 2. Fill & Sign row geometry and order ────────────────────────────────────────
        require(FillSignTool.rowOrder.map(\.title)
                    == ["Text", "Signature", "Date", "Checkmark", "Cross", "Stamp", "Image"],
                "the Fill & Sign row declares the seven requested items in order")
        require(state.fillSignRowCommands.map(\.title) == FillSignTool.rowOrder.map(\.title),
                "the state's row commands follow the declared order")
        require(state.fillSignRowCommands.allSatisfy(\.enabled),
                "every Fill & Sign item is enabled on a plain document")
        require(state.fillSignRowCommands.allSatisfy {
                    NSImage(systemSymbolName: $0.icon, accessibilityDescription: nil) != nil
                }, "every Fill & Sign row icon exists on this macOS")

        let rowWidth = 1200 - ReaderChrome.sidebarTotalWidthPt
            - ReaderChrome.scrollIndicatorLaneWidthPt
        let minimumRowWidth = 900 - ReaderChrome.sidebarTotalWidthPt
            - ReaderChrome.scrollIndicatorLaneWidthPt
        func frame(_ id: String, _ frames: [String: CGRect], _ label: String) -> CGRect {
            guard let frame = frames[id] else {
                fatalError("FAIL: \(label) reports no frame for \(id)")
            }
            return frame
        }
        func assertFillSignFrames(width: CGFloat, label: String) -> [String: CGRect] {
            let frames = ReaderToolbarProbe.fillSignRowFrames(state: state, width: width)
            let ordered = FillSignTool.rowOrder.map { frame($0.title, frames, label) }
            print("FILL & SIGN \(label): "
                  + zip(FillSignTool.rowOrder, ordered)
                    .map { "\($0.title)=\(Int($1.minX))..\(Int($1.maxX))" }
                    .joined(separator: " "))
            require(ordered.count == 7, "\(label): the Fill & Sign row hosts all seven items")
            require(zip(ordered, ordered.dropFirst()).allSatisfy { $0.maxX <= $1.minX },
                    "\(label): the seven Fill & Sign items do not overlap")
            require(ordered.allSatisfy { $0.width > 1 && $0.height > 1 },
                    "\(label): every Fill & Sign item has a measurable control")
            require(ordered[0].minX >= AnnotationToolbarLayout.horizontalPadding - 0.01,
                    "\(label): the Text item starts at the row's leading padding")
            require(!frames.keys.contains("Clear Fill & Sign tool"),
                    "\(label): the Fill & Sign row has no close control")
            require(ordered.last!.maxX <= width - AnnotationToolbarLayout.horizontalPadding + 0.01,
                    "\(label): the row fits inside the canvas width "
                        + "(\(ordered.last!.maxX) of \(width))")
            require(abs(ordered[0].minX - (width - ordered.last!.maxX)) < 0.5,
                    "\(label): the row's trailing edge is flush after the Image item "
                        + "(leading \(ordered[0].minX), trailing \(width - ordered.last!.maxX))")
            return frames
        }
        _ = assertFillSignFrames(width: rowWidth, label: "1200 pt window")
        _ = assertFillSignFrames(width: minimumRowWidth, label: "900 pt minimum")

        // ── 3. Each Fill & Sign item arms its tool and its inspector ─────────────────────
        require(!state.fillSignInspectorVisible,
                "the Fill & Sign inspector is absent while no tool is armed")
        for tool in FillSignTool.rowOrder {
            state.selectFillSignTool(tool)
            require(state.armedFillSignTool == tool, "\(tool.title) becomes the armed row item")
            require(state.fillAndSignVisible, "\(tool.title) keeps the Fill & Sign row open")
            require(state.fillSignInspectorVisible,
                    "\(tool.title) opens the Fill & Sign inspector")
            switch tool {
            case .text:
                require(state.pendingFillSignPlacement == .text
                            && state.annotationTool == .textBox,
                        "Text arms the text-box placement")
            case .signature:
                require(state.pendingFillSignPlacement == nil && state.annotationTool == .select,
                        "Signature waits in the inspector for a method")
                require(state.fillSignSignatureMethods.map(\.title)
                            == ["Type", "Draw", "Image…", "From iPhone or iPad"],
                        "the Signature inspector offers the four methods in order")
            case .date:
                require(state.pendingFillSignPlacement == .date,
                        "Date arms its one-click placement")
                require(FillSignDateFormat.allCases.map(\.title)
                            == ["Medium", "Long", "Short", "ISO"],
                        "the Date inspector offers four formats")
                require(FillSignDateRotation.allCases.map(\.rawValue) == [0, 90, 180, 270],
                        "the Date inspector offers four rotations")
            case .checkmark:
                require(state.pendingFillSignPlacement == .checkmark,
                        "Checkmark arms its one-click placement")
            case .cross:
                require(state.pendingFillSignPlacement == .cross,
                        "Cross arms its one-click placement")
            case .stamp:
                require(state.annotationTool == .stamp && state.pendingStampStyle != nil,
                        "Stamp arms the stamp tool with a style")
                require(AppState.StampStyle.allCases.count >= 5,
                        "the Stamp inspector has the existing five styles")
            case .image:
                require(state.pendingFillSignPlacement == nil && state.annotationTool == .select,
                        "Image waits in the inspector for a picture")
                require(FillSignImageSize.allCases.map(\.title) == ["Small", "Medium", "Large"],
                        "the Image inspector offers three sizes")
                require(FillSignImageSize.medium.height == AppState.Annotation.defaultPictureHeight,
                        "the Image inspector's default keeps the historical picture height")
            }
            // Clicking the active item again clears it and closes the inspector.
            state.selectFillSignTool(tool)
            require(state.armedFillSignTool == nil,
                    "clicking \(tool.title) again clears it")
            require(!state.fillSignInspectorVisible,
                    "\(tool.title)'s inspector disappears when it is cleared")
            require(state.pendingFillSignPlacement == nil,
                    "\(tool.title)'s placement is dropped with the tool")
        }

        // Signature and Image wait for a choice in the inspector, so they have no pending
        // placement yet; Escape must still clear them and close the inspector.
        state.selectFillSignTool(.signature)
        require(state.cancelActiveAnnotationTool()
                    && state.armedFillSignTool == nil && !state.fillSignInspectorVisible,
                "Escape clears the Signature item before a method is chosen")
        state.selectFillSignTool(.image)
        require(state.cancelActiveAnnotationTool()
                    && state.armedFillSignTool == nil && !state.fillSignInspectorVisible,
                "Escape clears the Image item before a picture is chosen")

        // Date format and rotation, and the picture size, are real options rather than a
        // decorative picker: each changes the annotation the next click places.
        guard let pageFrame = state.canvasPageFrames.first(where: { $0.index == 0 }) else {
            require(false, "the Fill & Sign option checks need a laid-out first page")
            return
        }
        func contentPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: pageFrame.leftPt + point.x, y: pageFrame.topPt + point.y)
        }
        let dateClick = CGPoint(x: 240, y: 260)
        state.fillSignDateFormat = .iso
        state.fillSignDateRotation = .none
        state.selectFillSignTool(.date)
        require(state.placePendingFillSign(atContentPoint: contentPoint(dateClick)),
                "the ISO date option places a date")
        guard let isoDate = state.annotations.last else {
            require(false, "the ISO date placed an annotation")
            return
        }
        require(isoDate.kind == .textBox
                    && isoDate.note.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$",
                                          options: .regularExpression) != nil,
                "the Date inspector's ISO format changes the placed text (\(isoDate.note))")
        state.undo()
        state.fillSignDateFormat = .medium

        state.fillSignDateRotation = .quarter
        state.selectFillSignTool(.date)
        require(state.placePendingFillSign(atContentPoint: contentPoint(dateClick)),
                "a rotated date places through the image path")
        guard let rotatedDate = state.annotations.last else {
            require(false, "the rotated date placed an annotation")
            return
        }
        require(rotatedDate.kind == .signature && rotatedDate.imageData != nil,
                "a rotated date is an image annotation so the PDF keeps its orientation")
        require((rotatedDate.shapeRect?.height ?? 0) > (rotatedDate.shapeRect?.width ?? 0),
                "a 90° date is placed taller than it is wide")
        state.undo()
        state.fillSignDateRotation = .none

        state.fillSignImageSize = .small
        let picture = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: picture)
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 32).fill()
        NSGraphicsContext.restoreGraphicsState()
        let pictureData = picture.representation(using: .png, properties: [:])!
        state.selectFillSignTool(.image)
        state.armPicturePlacement(imageData: pictureData)
        require(state.placeSignature(atContentPoint: contentPoint(CGPoint(x: 360, y: 420))),
                "the Image inspector's size option places a picture")
        guard let smallPicture = state.annotations.last else {
            require(false, "the small picture placed an annotation")
            return
        }
        require(abs((smallPicture.shapeRect?.height ?? 0) - FillSignImageSize.small.height) < 0.6,
                "the Image inspector's Small size sets the placed picture's height")
        state.undo()
        state.fillSignImageSize = .medium

        // ── 4. The Edit inspector follows an armed content tool, not the row ────────────
        state.contentEditEnabled = true
        state.contentEditTool = "select"
        state.contentEditSelection = nil
        require(!state.contentEditInspectorVisible,
                "Edit's row with no tool armed does not open the right inspector")
        state.selectContentTool("text")
        require(state.contentEditInspectorVisible,
                "arming the Text content tool opens the Edit inspector")
        state.selectContentTool("text")
        require(state.contentEditTool == "select" && !state.contentEditInspectorVisible,
                "clearing the content tool closes the Edit inspector")
        state.contentEditEnabled = false
        require(!state.contentEditInspectorVisible,
                "closing Edit also leaves the inspector closed")

        // The inspector is real chrome in the window, so its absence is measured too.
        let harness = try await ToolbarRowHarness.make(state: state)
        defer { harness.close() }
        harness.host.layoutSubtreeIfNeeded()
        let canvasWithRowOnly = harness.canvasRect
        require(canvasWithRowOnly.width > 100, "the hosted canvas has a measurable width")
        func waitForInspector(_ visible: Bool, _ message: String) async throws {
            try await eventually(message, {
                let width = harness.host.bounds.width - harness.canvasRect.maxX
                    - ReaderChrome.scrollIndicatorLaneWidthPt
                let expected: CGFloat = visible
                    ? ReaderChrome.editingPanelWidthPt : 0
                return abs(width - expected) < 1
            })
        }

        state.contentEditEnabled = true
        try await Task.sleep(for: .milliseconds(80))
        harness.host.layoutSubtreeIfNeeded()
        let editRowOnlyWidth = harness.canvasRect.width
        require(abs(editRowOnlyWidth - canvasWithRowOnly.width) < 0.5,
                "opening Edit with no tool armed does not take inspector width "
                    + "(\(editRowOnlyWidth) vs \(canvasWithRowOnly.width))")
        state.selectContentTool("text")
        try await waitForInspector(true, "arming a content tool opens the Edit inspector column")
        require(abs(harness.canvasRect.width
                    - (canvasWithRowOnly.width - ReaderChrome.editingPanelWidthPt)) < 1,
                "the Edit inspector takes its 292 pt from the canvas")
        state.selectContentTool("text")
        try await waitForInspector(false, "clearing the content tool closes the Edit inspector")

        state.contentEditEnabled = false
        state.fillAndSignVisible = true
        state.selectFillSignTool(.signature)
        try await waitForInspector(true, "arming a Fill & Sign tool opens its inspector column")
        require(abs(harness.canvasRect.width
                    - (canvasWithRowOnly.width - ReaderChrome.editingPanelWidthPt)) < 1,
                "the Fill & Sign inspector takes the same 292 pt from the canvas")
        try await eventually("the Fill & Sign inspector slot settles at 292 pt", {
            abs((harness.chromeRect(.fillSignInspectorSlot)?.width ?? 0)
                - ReaderChrome.editingPanelWidthPt) < 0.5
        })
        if let rowRect = harness.chromeRect(.secondaryToolbar),
           let slot = harness.chromeRect(.fillSignInspectorSlot) {
            require(abs(rowRect.maxX - slot.minX) < 1,
                    "the Fill & Sign row ends flush against its inspector column")
            require(abs(slot.width - ReaderChrome.editingPanelWidthPt) < 0.5,
                    "the Fill & Sign inspector column is the full 292 pt")
            require(abs(slot.minX - (harness.canvasRect.maxX
                                     + ReaderChrome.scrollIndicatorLaneWidthPt)) < 0.5,
                    "the Fill & Sign inspector begins after the canvas and its scroll lane")
            require(abs(slot.maxY - harness.canvasRect.maxY) < 0.5,
                    "the Fill & Sign inspector begins at the content top")
        } else {
            require(false, "the Fill & Sign row and inspector slot have measurable chrome frames")
        }
        state.clearFillSignTool()
        try await waitForInspector(false, "clearing the Fill & Sign tool closes its inspector")
        state.fillAndSignVisible = false

        // ── 4a. Closing a row disarms the tool it owns ───────────────────────────────────
        // A tool is only meaningful while its row is visible. Closing or collapsing the row must
        // return the page to the implicit pointer state; otherwise a highlight, pen or Fill &
        // Sign placement keeps applying with no visible control left to turn it off.
        guard let firstPage = state.canvasPageFrames.first(where: { $0.index == 0 }) else {
            require(false, "the toolbar-rows fixture lays out its first page")
            return
        }
        let ringPoint = CGPoint(x: min(160, firstPage.widthPt / 2),
                                y: min(220, firstPage.heightPt / 2))
        func waitForCanvasTool(_ tool: AnnotationTool, _ message: String) async throws {
            try await eventually(message, { harness.canvas.annotationTool == tool })
        }

        // Annotate: a note is placed by one click, so the same click is a positive control while
        // the row is open and must be inert after it closes.
        state.annotationToolsVisible = true
        state.toggleAnnotationTool(.note)
        require(state.annotationTool == .note, "the Note tool arms inside the Annotate row")
        try await waitForCanvasTool(.note, "the hosted canvas receives the armed Note tool")
        let notesBefore = state.annotations.count
        require(harness.clickPage(0, at: ringPoint), "the hosted canvas receives a page click")
        try await eventually("the armed Note tool places one annotation on that click", {
            state.annotations.count == notesBefore + 1
        })
        guard state.deleteSelectedAnnotation() else {
            require(false, "the positive-control note is removed")
            return
        }
        try await eventually("the positive-control note is gone before the row closes", {
            state.annotations.count == notesBefore
        })
        state.annotationToolsVisible = false
        require(state.annotationTool == .select,
                "closing the Annotate row returns the annotation tool to Select")
        try await waitForCanvasTool(.select, "the canvas sees Select after Annotate closes")
        require(harness.clickPage(0, at: ringPoint),
                "the page click after closing Annotate is delivered")
        require(state.annotations.count == notesBefore,
                "a page click after Annotate closes no longer applies its tool")

        // Edit: closing the row clears the armed content tool and closes its inspector. A click
        // after it closes cannot select a page object for editing.
        state.contentEditEnabled = true
        state.selectContentTool("text")
        require(state.contentEditInspectorVisible,
                "Edit's Text tool opens the inspector before the row closes")
        state.contentEditEnabled = false
        require(state.contentEditTool == "select",
                "closing the Edit row returns the content tool to Select")
        require(!state.contentEditInspectorVisible,
                "closing the Edit row closes its inspector")
        let editsBefore = state.pageEditPendingOperations.count
        require(harness.clickPage(0, at: ringPoint),
                "the page click after closing Edit is delivered")
        require(state.contentEditSelection == nil
                    && state.pageEditPendingOperations.count == editsBefore,
                "a page click after Edit closes no longer applies its content tool")

        // Fill & Sign: closing the row clears the armed item and its inspector. Its Date item
        // claims the next click, so the click is a positive control before the close and must
        // place nothing after it.
        state.fillAndSignVisible = true
        state.selectFillSignTool(.date)
        require(state.armedFillSignTool == .date && state.fillSignInspectorVisible,
                "the Date item arms and opens the Fill & Sign inspector")
        try await eventually("the hosted canvas receives the armed Date placement", {
            harness.canvas.fillSignPlacementPending
        })
        let datesBefore = state.annotations.count
        require(harness.clickPage(0, at: ringPoint),
                "the page click with Date armed is delivered")
        try await eventually("the armed Date item places one annotation on that click", {
            state.annotations.count == datesBefore + 1
        })
        guard state.deleteSelectedAnnotation() else {
            require(false, "the positive-control date is removed")
            return
        }
        state.selectFillSignTool(.date)
        require(state.pendingFillSignPlacement == .date,
                "the Date item arms its one-click placement again")
        state.fillAndSignVisible = false
        require(state.armedFillSignTool == nil,
                "closing the Fill & Sign row clears its armed item")
        require(state.pendingFillSignPlacement == nil && !state.fillSignInspectorVisible,
                "closing the Fill & Sign row drops its placement and closes its inspector")
        try await eventually("the hosted canvas sees the closed Fill & Sign row", {
            !harness.canvas.fillSignPlacementPending
        })
        let fillsBefore = state.annotations.count
        require(harness.clickPage(0, at: ringPoint),
                "the page click after closing Fill & Sign is delivered")
        require(state.annotations.count == fillsBefore,
                "a page click after Fill & Sign closes places nothing")

        // Switching rows deactivates the old row's tool: Annotate -> Edit can never leave a
        // highlight armed behind the Edit row.
        state.annotationToolsVisible = true
        state.toggleTextMarkupTool(.highlight)
        require(state.annotationTool == .highlight, "Highlight arms inside the Annotate row")
        state.contentEditEnabled = true
        require(!state.annotationToolsVisible && state.openSecondaryRows == [.contentEdit],
                "opening Edit switches the one row slot from Annotate")
        require(state.annotationTool == .select,
                "switching Annotate -> Edit clears the armed highlight")

        // Closing Edit while its inspector is open is the same rule seen from the row's own
        // toolbar button: the tool and the inspector go with the row.
        state.selectContentTool("text")
        require(state.contentEditInspectorVisible,
                "the content tool reopened the Edit inspector")
        state.contentEditEnabled = false
        require(state.contentEditTool == "select" && !state.contentEditInspectorVisible,
                "closing Edit clears the content tool and its inspector")

        // Page overview covers the page, so opening it disarms an annotation tool while leaving
        // the row state alone (the row returns in the pointer state when the overview closes).
        state.annotationToolsVisible = true
        state.toggleAnnotationTool(.pen)
        require(state.annotationTool == .pen, "the Pen tool arms before page overview opens")
        state.pageOverviewVisible = true
        require(state.annotationTool == .select,
                "opening page overview clears an armed annotation tool")
        require(state.openSecondaryRows == [.annotations],
                "page overview leaves the Annotate row open behind it")
        state.pageOverviewVisible = false
        require(state.annotationTool == .select,
                "closing page overview does not re-arm the old tool")
        state.annotationToolsVisible = false

        // Export owns no persistent page tool. Closing its row is still checked, and the other
        // rows' tools must stay in the implicit pointer state.
        state.exportVisible = true
        state.exportVisible = false
        require(state.openSecondaryRows.isEmpty, "closing the Export row closes the row slot")
        require(state.annotationTool == .select && state.armedFillSignTool == nil
                    && state.contentEditTool == "select",
                "closing Export leaves no tool armed")
        let exportsBefore = state.annotations.count
        require(harness.clickPage(0, at: ringPoint),
                "the page click after closing Export is delivered")
        require(state.annotations.count == exportsBefore,
                "a page click after Export closes applies nothing")

        // ── 4b. One host for both tool inspectors ────────────────────────────────────────
        // By inspection there were two inspector hosts (ContentEditInspector and
        // FillSignInspector) that repeated the same header/scroll/footer scaffold and the same
        // 16 / 22 / 9 / 292 numbers. Each Fill & Sign tool's options were already content
        // selected by one switch, not separate inspectors; now both hosts are ReaderInspectorHost
        // and the metrics live in ReaderInspectorMetrics.
        let contentEditInspectorSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/ContentEditInspector.swift"),
            encoding: .utf8)
        let fillSignInspectorSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/FillSignInspector.swift"),
            encoding: .utf8)
        let inspectorChromeSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/ReaderInspectorChrome.swift"),
            encoding: .utf8)
        for (name, source) in [("Edit", contentEditInspectorSource),
                               ("Fill & Sign", fillSignInspectorSource)] {
            require(source.contains("ReaderInspectorHost("),
                    "the \(name) inspector uses the shared inspector host")
            require(!source.contains("ReaderChromeMarkerHost(kind:"),
                    "the \(name) inspector does not add its own chrome/background")
            require(!source.contains(".padding(16)") && !source.contains(".frame(width: 292)"),
                    "the \(name) inspector does not repeat the host's padding or width")
            require(!source.contains(".font(.system(size: 13, weight: .semibold))"),
                    "the \(name) inspector does not repeat the host's title font")
        }
        require(inspectorChromeSource.contains("public enum ReaderInspectorMetrics")
                    && inspectorChromeSource.contains("struct ReaderInspectorHost"),
                "the inspector host and its metrics have one definition")
        require(ReaderInspectorMetrics.width == ReaderChrome.editingPanelWidthPt
                    && ReaderInspectorMetrics.bodySpacing == 22,
                "the inspector width and section spacing are the shared numbers")
        print("INSPECTOR HOST: both inspectors use ReaderInspectorHost; width "
              + "\(Int(ReaderInspectorMetrics.width)) pt, section spacing "
              + "\(Int(ReaderInspectorMetrics.bodySpacing)) pt, padding "
              + "\(Int(ReaderInspectorMetrics.bodyPadding)) pt")

        // ── 5. The rows slide with the pinned progress ──────────────────────────────────
        // One harness, one document, all five rows: the canvas frame and the page top must be
        // identical while each row reveals, and each row must move through Annotate's exact
        // content heights/offsets at the same pinned steps. The pinned progress is the test seam
        // the sidebar and annotation row already use, so this never races the display link.
        state.transitionProgressOverride = ReaderTransitionProgress(row: 0)
        let frameBefore = harness.canvasRect
        let pageTopBefore = harness.pageTopInHost(page: 0) ?? .nan
        /// Annotate's row-content frames at [0.25, 0.5, 0.75, 1.0], the reference every other
        /// row must match.
        var annotateReveal: [(slot: CGRect, content: CGRect)] = []
        func assertSlide(row: SecondaryRow, open: @escaping () -> Void,
                         close: @escaping () -> Void) async throws {
            state.transitionProgressOverride = ReaderTransitionProgress(row: 0)
            open()
            try await eventually("\(row.title) is pinned collapsed", {
                harness.rowHeight == 0
            })
            var samples: [CGFloat] = []
            for (step, progress) in [0.25, 0.5, 0.75, 1.0].enumerated() {
                state.transitionProgressOverride = ReaderTransitionProgress(row: progress)
                let expected = ReaderChrome.secondaryToolbarHeightPt * CGFloat(progress)
                try await eventually("\(row.title) lays out at progress \(progress)", {
                    abs(harness.rowHeight - expected) <= 2
                })
                samples.append(harness.rowHeight)
                require(abs(harness.canvasRect.height - frameBefore.height) < 0.01
                            && abs(harness.canvasRect.minY - frameBefore.minY) < 0.01,
                        "\(row.title) at progress \(progress) leaves the canvas frame unchanged")
                let pageTop = harness.pageTopInHost(page: 0) ?? .nan
                require(abs(pageTop - pageTopBefore) < 0.01,
                        "\(row.title) at progress \(progress) leaves the page top unchanged")

                // The row content is always the same 46 pt view and the reveal is its offset
                // into the clipped slot; only the slot's height changes. These are the numbers
                // the five rows must share.
                guard let slot = harness.chromeRect(.secondaryRowSlot),
                      let content = harness.chromeRect(.secondaryToolbar) else {
                    require(false, "\(row.title) at progress \(progress) has no row markers")
                    continue
                }
                let expectedOffset = -ReaderChrome.secondaryToolbarHeightPt * CGFloat(1 - progress)
                do {
                    require(abs(content.height - ReaderChrome.secondaryToolbarHeightPt) < 0.5,
                            "\(row.title) keeps its full 46 pt content at progress \(progress) "
                                + "(\(content.height) pt)")
                    require(abs((content.minY - slot.minY) - expectedOffset) <= 0.5,
                            "\(row.title)'s content sits at Annotate's offset at progress "
                                + "\(progress) (offset \(content.minY - slot.minY), "
                                + "expected \(expectedOffset))")
                    require(abs(content.maxY - slot.maxY) <= 0.5,
                            "\(row.title)'s content bottom follows the revealed edge at progress "
                                + "\(progress) (\(content.maxY) vs \(slot.maxY))")
                    require(abs(content.width - slot.width) <= 0.5,
                            "\(row.title)'s content spans the row slot at progress \(progress)")
                }
                // No row may fade: at each intermediate layout the whole content must be fully
                // opaque. The old branch insertion used SwiftUI's default opacity transition,
                // which ghosted Edit / Fill & Sign / Export / Lyra over the page.
                let visible = harness.rowContentIsOpaque
                require(visible,
                        "\(row.title) has opacity 1 on every ancestor at progress \(progress)")
                if row == .annotations {
                    annotateReveal.append((slot, content))
                } else if step < annotateReveal.count {
                    let reference = annotateReveal[step]
                    require(abs(content.minY - reference.content.minY) <= 0.5
                                && abs(content.height - reference.content.height) <= 0.5
                                && abs(content.width - reference.content.width) <= 0.5,
                            "\(row.title) at progress \(progress) uses Annotate's row content "
                                + "frame (y \(content.minY), h \(content.height), "
                                + "w \(content.width); Annotate y \(reference.content.minY), "
                                + "h \(reference.content.height), w \(reference.content.width))")
                }
            }
            print("ROW SLIDE \(row.title): \(samples.map { Int($0) }) pt")
            require(samples.contains { $0 > 2 && $0 < 44 },
                    "\(row.title) reveals its content over time instead of appearing whole "
                        + "(\(samples.map { Int($0) }))")
            require(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 },
                    "\(row.title)'s pinned reveal is monotonic (\(samples.map { Int($0) }))")
            state.transitionProgressOverride = nil
            try await eventually("\(row.title) reaches its full 46 pt", {
                harness.rowHeight >= 44
            })
            require(harness.rowHeight <= 46,
                    "\(row.title) stops at the full 46 pt row")
            state.transitionProgressOverride = ReaderTransitionProgress(row: 1)
            close()
            for progress in stride(from: 1.0, through: 0.0, by: -0.25) {
                state.transitionProgressOverride = ReaderTransitionProgress(row: progress)
                let expected = ReaderChrome.secondaryToolbarHeightPt * CGFloat(progress)
                try await eventually("\(row.title) collapses at progress \(progress)", {
                    abs(harness.rowHeight - expected) <= 2
                })
                require(abs(harness.canvasRect.height - frameBefore.height) < 0.01,
                        "\(row.title) closing at progress \(progress) leaves the canvas unchanged")
            }
            state.transitionProgressOverride = nil
            try await eventually("\(row.title) is closed", {
                harness.rowHeight == 0
            })
            require(state.openSecondaryRows.isEmpty, "\(row.title) closes the row slot")
        }

        try await assertSlide(row: .annotations, open: {
            state.annotationToolsVisible = true
        }, close: {
            state.annotationToolsVisible = false
        })
        try await assertSlide(row: .contentEdit, open: {
            state.contentEditEnabled = true
        }, close: {
            state.contentEditEnabled = false
        })
        try await assertSlide(row: .fillAndSign, open: {
            state.fillAndSignVisible = true
        }, close: {
            state.fillAndSignVisible = false
        })
        try await assertSlide(row: .export, open: {
            state.exportVisible = true
        }, close: {
            state.exportVisible = false
        })
        try await assertSlide(row: .lyra, open: {
            state.aiToolsVisible = true
        }, close: {
            state.aiToolsVisible = false
        })

        // ── 5b. All five rows use the same control and icon metrics ─────────────────────
        // The probes host the real rows through ReaderSecondaryRow, so these are the cells,
        // baselines and gaps a reader sees. Fill & Sign used to give every label a fixed 116 pt
        // cell, which centered a short label in a wide box and read as a much wider gap than
        // the other rows. The annotation row is the reference: 32 pt controls, a 2 pt item
        // spacing, a 34 pt group gap and 14 pt horizontal padding.
        //
        // Lyra is one group: Interleaf is not separated by a group gap from the four workspace
        // buttons. Its custom glyph and the SF Symbols all go through ReaderToolbarIcon, so every
        // icon reports the same 18 pt square and the same vertical centre.
        let spacingModel = AIAssistantModel()
        func spacingFrames(_ ids: [String], _ frames: [String: CGRect],
                           _ title: String) -> [CGRect] {
            ids.map { frame($0, frames, "\(title) row") }
        }
        let annotationLayout = ReaderToolbarProbe.annotationRowFrames(state: state, width: rowWidth)
        let editLayout = ReaderToolbarProbe.contentEditRowFrames(state: state, width: rowWidth)
        let fillLayout = ReaderToolbarProbe.fillSignRowFrames(state: state, width: rowWidth)
        let exportLayout = ReaderToolbarProbe.exportRowFrames(state: state, width: rowWidth)
        let lyraLayout = ReaderToolbarProbe.lyraRowFrames(
            state: state, model: spacingModel, width: rowWidth)
        let lyraIDs = ["lyra.interleaf", "lyra.summary", "lyra.translation",
                       "lyra.chat", "lyra.regions"]
        // No row has an xmark of its own. The Annotate and Fill & Sign rows used to end with
        // one; those controls and every frame they reported are gone, and the row ends at its
        // last real control. Closing is the main toolbar button's toggle alone.
        for (title, frames) in [("Annotate", annotationLayout), ("Edit", editLayout),
                                ("Fill & Sign", fillLayout), ("Export", exportLayout),
                                ("Lyra", lyraLayout)] {
            require(!frames.keys.contains("Hide annotation tools")
                        && !frames.keys.contains("Clear Fill & Sign tool")
                        && !frames.keys.contains("Clear Fill & Sign"),
                    "\(title) row reports no close-control frame")
            require(frames.keys.allSatisfy {
                !$0.localizedCaseInsensitiveContains("close")
                    && !$0.localizedCaseInsensitiveContains("xmark")
            }, "\(title) row has no close control anywhere in its frames")
        }
        let spacingSamples: [(title: String, ids: [String], frames: [CGRect],
                              iconIDs: [String], groupGapsAfter: Set<Int>)] = [
            ("Annotate", AnnotationToolbarLayout.annotationToolIDs,
             spacingFrames(AnnotationToolbarLayout.annotationToolIDs, annotationLayout, "Annotate"),
             AnnotationToolbarLayout.annotationToolIDs, [2, 6]),
            ("Edit", AnnotationToolbarLayout.contentEditItemIDs,
             spacingFrames(AnnotationToolbarLayout.contentEditItemIDs, editLayout, "Edit"),
             AnnotationToolbarLayout.contentEditItemIDs, []),
            ("Fill & Sign", FillSignTool.rowOrder.map(\.title),
             spacingFrames(FillSignTool.rowOrder.map(\.title), fillLayout, "Fill & Sign"),
             FillSignTool.rowOrder.map(\.title), []),
            ("Export", ExportCommand.all.map { "export.\($0.id)" },
             spacingFrames(ExportCommand.all.map { "export.\($0.id)" }, exportLayout, "Export"),
             ExportCommand.all.map { "export.\($0.id)" }, []),
            ("Lyra", lyraIDs, spacingFrames(lyraIDs, lyraLayout, "Lyra"), lyraIDs, []),
        ]
        var itemSpacings: [CGFloat] = []
        var groupSpacings: [CGFloat] = []
        var controlHeights: [CGFloat] = []
        var controlTops: [CGFloat] = []
        var iconHeights: [CGFloat] = []
        var iconCentres: [CGFloat] = []
        for sample in spacingSamples {
            require(sample.frames.count >= 2,
                    "\(sample.title) row has at least two measurable items")
            let gaps = zip(sample.frames, sample.frames.dropFirst())
                .map { $1.minX - $0.maxX }
            require(gaps.allSatisfy { $0 >= -0.01 },
                    "\(sample.title) row items do not overlap (\(gaps.map { String(format: "%.1f", $0) }))")
            for (index, gap) in gaps.enumerated() {
                let grouped = sample.groupGapsAfter.contains(index)
                let expected = grouped
                    ? ReaderSecondaryRowMetrics.groupGap
                    : ReaderSecondaryRowMetrics.itemSpacing
                require(abs(gap - expected) <= 0.5,
                        "\(sample.title): \(sample.ids[index]) → \(sample.ids[index + 1]) "
                            + "gap is \(gap), expected \(expected)")
                if grouped { groupSpacings.append(gap) } else { itemSpacings.append(gap) }
            }
            let heights = sample.frames.map(\.height)
            require(heights.allSatisfy {
                        abs($0 - ReaderSecondaryRowMetrics.controlHeight) <= 0.5
                    }, "\(sample.title) controls are all 32 pt high (\(heights.map { Int($0) }))")
            controlHeights.append(contentsOf: heights)
            let tops = sample.frames.map(\.minY)
            require(tops.allSatisfy { abs($0 - tops[0]) <= 0.5 },
                    "\(sample.title) controls share one baseline (\(tops.map { Int($0) }))")
            controlTops.append(tops[0])
            require(sample.frames[0].minX >= ReaderSecondaryRowMetrics.horizontalPadding - 0.5,
                    "\(sample.title) starts inside the row's leading padding "
                        + "(\(sample.frames[0].minX))")
            require(sample.frames.last!.maxX
                        <= rowWidth - ReaderSecondaryRowMetrics.horizontalPadding + 0.5,
                    "\(sample.title) ends inside the row's trailing padding "
                        + "(\(sample.frames.last!.maxX) of \(rowWidth))")
            // Annotate's trailing colour picker is chrome outside the tool ids; the layout check
            // in AnnotationToolbarChecks covers it. Every other row's last item is its trailing
            // edge, so the leading and trailing margins must match exactly.
            if sample.title != "Annotate" {
                require(abs(sample.frames[0].minX
                            - (rowWidth - sample.frames.last!.maxX)) <= 0.5,
                        "\(sample.title) row ends flush at its last control "
                            + "(leading \(sample.frames[0].minX), "
                            + "trailing \(rowWidth - sample.frames.last!.maxX))")
            }
            // Every tool's icon is reported by ReaderToolbarIcon, including the glyph-only
            // Annotate row and the compact fallback of Fill & Sign / Export. A row with a
            // different icon font or an un-framed custom vector reports a different size here.
            let rowLayout: [String: CGRect]
            switch sample.title {
            case "Annotate": rowLayout = annotationLayout
            case "Edit": rowLayout = editLayout
            case "Fill & Sign": rowLayout = fillLayout
            case "Export": rowLayout = exportLayout
            default: rowLayout = lyraLayout
            }
            let iconFrames = sample.iconIDs.map {
                frame("\($0).icon", rowLayout, "\(sample.title) row icon")
            }
            let expectedIconFrame = ReaderToolbarTypography.iconFrameSize
            require(iconFrames.allSatisfy {
                        abs($0.width - expectedIconFrame) <= 0.5
                            && abs($0.height - expectedIconFrame) <= 0.5
                    }, "\(sample.title) icons all use the \(Int(expectedIconFrame)) pt square frame "
                        + "(\(iconFrames.map { "\(Int($0.width))x\(Int($0.height))" }))")
            require(iconFrames.allSatisfy {
                        abs($0.midY - iconFrames[0].midY) <= 0.5
                    }, "\(sample.title) icons share one vertical centre "
                        + "(\(iconFrames.map { String(format: "%.1f", $0.midY) }))")
            iconHeights.append(contentsOf: iconFrames.map(\.height))
            iconCentres.append(contentsOf: iconFrames.map(\.midY))
            let itemLog = zip(sample.ids, sample.frames).map {
                "\($0)=\(Int($1.minX))..\(Int($1.maxX))"
            }.joined(separator: " ")
            let gapLog = gaps.map { String(format: "%.1f", $0) }.joined(separator: ",")
            let iconLog = iconFrames.map {
                "\(Int($0.width))x\(Int($0.height))@\(String(format: "%.1f", $0.midY))"
            }.joined(separator: ",")
            print("ROW SPACING \(sample.title): \(itemLog) | gaps \(gapLog) | icons \(iconLog)")
        }
        let spacingSpread = (itemSpacings.max() ?? 0) - (itemSpacings.min() ?? 0)
        require(spacingSpread <= 0.5,
                "all five rows share one inter-item spacing "
                    + "(\(itemSpacings.map { String(format: "%.1f", $0) }))")
        require(groupSpacings.allSatisfy {
                    abs($0 - ReaderSecondaryRowMetrics.groupGap) <= 0.5
                }, "every group gap is 34 pt (\(groupSpacings.map { String(format: "%.1f", $0) }))")
        require(controlHeights.allSatisfy {
                    abs($0 - ReaderSecondaryRowMetrics.controlHeight) <= 0.5
                }, "all rows use the same 32 pt control height")
        require(controlTops.allSatisfy { abs($0 - controlTops[0]) <= 0.5 },
                "all rows put their controls on the same baseline "
                    + "(\(controlTops.map { String(format: "%.1f", $0) }))")
        require(iconHeights.allSatisfy {
                    abs($0 - ReaderToolbarTypography.iconFrameSize) <= 0.5
                }, "every row's icons use the same \(Int(ReaderToolbarTypography.iconFrameSize)) pt "
                    + "frame height (\(iconHeights.map { Int($0) }))")
        require(iconCentres.allSatisfy { abs($0 - iconCentres[0]) <= 0.5 },
                "all rows put their icons on the same vertical centre "
                    + "(\(iconCentres.map { String(format: "%.1f", $0) }))")

        // ── 5b(ii). Typography: the main toolbar and the rows swap their label sizes ─────
        // The rows used to render at the button style's 14 pt medium while the main toolbar
        // rendered its explicit 12 pt medium. The user wants the two exchanged: main 14 medium,
        // rows 12 regular, icons 14 medium everywhere.
        let expectedMainTypography = ReaderResolvedTypography(size: 14, weight: .medium)
        let expectedRowTypography = ReaderResolvedTypography(size: 12, weight: .regular)
        require(ReaderToolbarTypography.mainLabelSize == expectedMainTypography.size,
                "the main toolbar takes the rows' previous \(expectedMainTypography.size) pt size")
        require(ReaderToolbarTypography.mainLabelWeight == expectedMainTypography.weight,
                "the main toolbar takes the rows' previous medium weight")
        require(ReaderToolbarTypography.rowLabelSize == expectedRowTypography.size,
                "row labels take the main toolbar's previous \(expectedRowTypography.size) pt size")
        require(ReaderToolbarTypography.rowLabelWeight == expectedRowTypography.weight,
                "row labels use regular weight")
        require(ReaderToolbarTypography.iconSize == 14,
                "icons keep the annotation row's 14 pt scale")
        require(ReaderToolbarTypography.iconFrameSize == 18,
                "every row icon occupies the same 18 pt square")

        let wideMainFonts = ReaderToolbarProbe.toolbarFonts(state: state, width: 1400)
        let mainLabelIDs = ["toolbar.annotate.label", "toolbar.edit.label",
                            "toolbar.fillSign.label", "toolbar.export.label",
                            "toolbar.lyra.label"]
        for id in mainLabelIDs {
            require(wideMainFonts[id] == expectedMainTypography,
                    "the main toolbar label \(id) resolves to 14 pt medium "
                        + "(\(String(describing: wideMainFonts[id])))")
        }
        let rowLabelIDs: [SecondaryRow: [String]] = [
            .contentEdit: ["Text.label", "Image.label", "Link.label", "Redact.label"],
            .fillAndSign: FillSignTool.rowOrder.map { "\($0.title).label" },
            .export: ExportCommand.all.map { "export.\($0.id).label" },
            .lyra: ["lyra.interleaf.label", "lyra.summary.label", "lyra.translation.label",
                    "lyra.chat.label", "lyra.regions.label"],
        ]
        for row in [SecondaryRow.contentEdit, .fillAndSign, .export, .lyra] {
            let fonts = ReaderToolbarProbe.rowFonts(
                row: row, state: state, model: spacingModel, width: rowWidth)
            for id in rowLabelIDs[row] ?? [] {
                require(fonts[id] == expectedRowTypography,
                        "\(row.title) label \(id) resolves to 12 pt regular "
                            + "(\(String(describing: fonts[id])))")
            }
        }
        // Annotate has icons only; it must not grow a text label. The row's typography sample is
        // the only font report there.
        require(Set(ReaderToolbarProbe.rowFonts(
                    row: .annotations, state: state, model: spacingModel, width: rowWidth).keys)
                == ["typography.font"],
                "the Annotate row has no text label to restyle")

        // The rendered sample uses the same string and symbol in every host, so equal frames
        // prove the hosts resolve the same font. Main (14 pt) must render wider than any row
        // label (12 pt), while every icon box stays identical.
        let mainSample = ReaderToolbarProbe.toolbarFrames(state: state, width: 1400)
        guard let mainSampleLabel = mainSample["typography.label"],
              let mainSampleIcon = mainSample["typography.icon"] else {
            require(false, "the main toolbar reports its typography sample frames")
            return
        }
        var rowSampleLabels: [CGRect] = []
        var rowSampleIcons: [CGRect] = []
        for sample in spacingSamples {
            let frames: [String: CGRect]
            switch sample.title {
            case "Annotate": frames = annotationLayout
            case "Edit": frames = editLayout
            case "Fill & Sign": frames = fillLayout
            case "Export": frames = exportLayout
            default: frames = lyraLayout
            }
            guard let label = frames["typography.label"],
                  let icon = frames["typography.icon"] else {
                require(false, "\(sample.title) reports its typography sample frames")
                continue
            }
            rowSampleLabels.append(label)
            rowSampleIcons.append(icon)
        }
        require(rowSampleLabels.allSatisfy {
                    abs($0.width - rowSampleLabels[0].width) <= 0.5
                        && abs($0.height - rowSampleLabels[0].height) <= 0.5
                }, "every row renders the sample label at one size "
                    + "(\(rowSampleLabels.map { "\(Int($0.width))x\(Int($0.height))" }))")
        require(mainSampleLabel.height > rowSampleLabels[0].height + 0.5,
                "the main toolbar's sample label is larger than the row labels "
                    + "(\(mainSampleLabel.height) vs \(rowSampleLabels[0].height))")
        require(abs(mainSampleIcon.width - rowSampleIcons[0].width) <= 0.5
                    && abs(mainSampleIcon.height - rowSampleIcons[0].height) <= 0.5,
                "the shared 14 pt icon renders the same in the main toolbar and every row "
                    + "(\(mainSampleIcon.size) vs \(rowSampleIcons[0].size))")
        print("ROW TYPOGRAPHY main: label \(Int(mainSampleLabel.width))x"
              + "\(Int(mainSampleLabel.height)) pt, icon \(Int(mainSampleIcon.width))x"
              + "\(Int(mainSampleIcon.height)) pt")
        for (sample, label) in zip(spacingSamples, rowSampleLabels) {
            print("ROW TYPOGRAPHY \(sample.title): label \(Int(label.width))x"
                  + "\(Int(label.height)) pt")
        }

        // ── 5c. One reveal, no fade ─────────────────────────────────────────────────────
        // A clean slide means opacity 1 at every intermediate layout (5) and no per-row
        // transition/animation in the code that could fade or double-move the content. The old
        // branch insertion used SwiftUI's default opacity transition; the Lyra branch also had
        // an explicit move+opacity transition and a second .animation.
        func codeOnly(_ source: String) -> String {
            source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let windowSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/ReaderWindow.swift"),
            encoding: .utf8)
        let rowSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/ReaderToolbar.swift"),
            encoding: .utf8)
        let rowsSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/SecondaryToolbarRows.swift"),
            encoding: .utf8)
        let layoutSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/AnnotationToolbarLayout.swift"),
            encoding: .utf8)
        let windowCode = codeOnly(windowSource)
        let rowCode = codeOnly(rowSource)
        let rowsCode = codeOnly(rowsSource)
        let layoutCode = codeOnly(layoutSource)
        require(!windowCode.contains(".transition(.move(edge: .top)"),
                "the row host adds no second move transition")
        require(!windowCode.contains(".animation(secondaryRowAnimation, value: state.aiToolsVisible)"),
                "the Lyra row has no second animation")
        require(windowCode.components(
                    separatedBy: ".animation(secondaryRowAnimation, value: secondaryToolbarVisible)")
                .count == 2,
                "the row host has exactly one reveal animation transaction")
        require(windowCode.contains("ReaderSecondaryToolbar(state: state, model: aiAssistant)"),
                "Annotate, Edit, Fill & Sign, Export and Lyra are one ReaderSecondaryToolbar")
        // ReaderToolbar.swift also contains document tabs, whose move/drop feedback may fade.
        // This guard belongs only to the secondary toolbar's six insertion branches.
        let secondaryDeclarations = rowCode.components(separatedBy: "struct ReaderSecondaryToolbar: View {")
        require(secondaryDeclarations.count == 2, "the secondary toolbar has one source declaration")
        let secondaryCode = secondaryDeclarations[1].components(separatedBy: "\n}")[0]
        let rowTransitions = secondaryCode.components(separatedBy: ".transition(").dropFirst()
        require(rowTransitions.count == 6,
                "the six row branches each declare their insertion transition "
                    + "(found \(rowTransitions.count))")
        require(rowTransitions.allSatisfy { $0.hasPrefix(".identity)") },
                "every row branch uses an identity transition, never opacity")
        require(!rowsCode.contains(".transition(") && !rowsCode.contains(".animation("),
                "the Fill & Sign and Export rows bring no transition or animation")
        require(!rowsCode.contains("ReaderCenteredTools")
                    && !layoutCode.contains("ReaderCenteredTools"),
                "the rows do not wrap themselves in their own centered container")
        require(!rowsCode.contains(".frame(maxWidth: .infinity"),
                "the rows do not bring their own full-width container")
        require(rowCode.components(separatedBy: "ReaderCenteredTools").count == 3,
                "ReaderCenteredTools is used once, by the shared row container")
        require(!layoutCode.contains("ReaderCenteredTools")
                    && !layoutCode.contains(".transition("),
                "the Edit and Annotate probes host the shared row container, not their own")

        // ── 5d. The row's width follows the panels frame by frame ───────────────────────
        // A settled leading/trailing inset made the row's background snap to its final edge
        // while the drawer was still sliding, leaving a strip of page visible for a frame
        // ("white sliver"). The pinned progress steps the drawer and the row together, so an
        // inset that ignores the animated width fails at an intermediate step, not only at the
        // endpoints. Every sample also asserts that the row's opaque background spans the
        // canvas and ends flush against the moving panel edge.
        state.transitionProgressOverride = nil
        state.aiToolsVisible = false
        state.contentEditEnabled = false
        state.fillAndSignVisible = false
        state.exportVisible = false
        state.clearFillSignTool()
        state.searchSidebarVisible = false
        state.rightPanelVisible = false
        state.sidebarVisible = false
        state.annotationToolsVisible = true
        try await eventually("the row is open for the width checks", {
            harness.rowHeight >= 44
        })

        // Right tool inspector: it slides out of the same slot and the row must end on its edge.
        state.annotationToolsVisible = false
        state.fillAndSignVisible = true
        state.selectFillSignTool(.signature)
        try await eventually("the Fill & Sign inspector is open for the width check", {
            state.fillSignInspectorVisible
        })
        // Let the opening inspector's own animation finish before pinning its width; otherwise
        // the row is still easing toward the 292 pt inset at the first sampled step.
        try await eventually("the row settles against the full-height inspector", {
            guard let row = harness.chromeRect(.secondaryToolbar) else { return false }
            return abs(row.minX) <= 0.5
                && abs(row.maxX - (harness.host.bounds.width
                                   - ReaderChrome.editingPanelWidthPt)) <= 0.5
        })
        var inspectorRowWidths: [CGFloat] = []
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] + [0.75, 0.5, 0.25, 0.0] {
            state.transitionProgressOverride = ReaderTransitionProgress(
                row: 1, panel: 0, editingPanel: progress)
            let expectedInspector = ReaderChrome.editingPanelWidthPt * CGFloat(progress)
            try await eventually("the Fill & Sign inspector is pinned at \(progress)", {
                abs((harness.chromeRect(.fillSignInspectorSlot)?.width ?? -1)
                    - expectedInspector) <= 1
            })
            harness.host.layoutSubtreeIfNeeded()
            guard let row = harness.chromeRect(.secondaryToolbar),
                  let slot = harness.chromeRect(.secondaryRowSlot),
                  let inspector = harness.chromeRect(.fillSignInspectorSlot) else {
                require(false, "the row, slot and inspector markers exist at \(progress)")
                continue
            }
            let canvas = harness.canvasRect
            require(abs(row.maxX - inspector.minX) <= 0.5,
                    "the row ends flush against the moving Fill & Sign inspector at "
                        + "progress \(progress) (row \(row.maxX), inspector \(inspector.minX))")
            require(abs(row.minX) <= 0.5,
                    "the row starts at the content edge with the sidebar closed at "
                        + "\(progress) (row minX \(row.minX))")
            require(abs(row.width - slot.width) <= 0.5,
                    "the row background spans its whole slot at progress \(progress) "
                        + "(\(row.width) vs \(slot.width))")
            require(row.minX <= canvas.minX + 0.5 && row.maxX >= canvas.maxX - 0.5,
                    "the row background covers the canvas at inspector progress \(progress) "
                        + "(row \(row.minX)..\(row.maxX), canvas \(canvas.minX)..\(canvas.maxX))")
            require(abs(row.height - ReaderChrome.secondaryToolbarHeightPt) <= 0.5,
                    "the row stays 46 pt high at inspector progress \(progress)")
            inspectorRowWidths.append(row.width)
        }
        require(zip(inspectorRowWidths, inspectorRowWidths.dropFirst()).allSatisfy {
                    abs($1 - $0) > 1
                },
                "the row width changes on every sampled inspector frame "
                    + "(\(inspectorRowWidths.map { Int($0) }))")
        print("ROW WIDTH inspector: \(inspectorRowWidths.map { Int($0) }) pt")
        state.clearFillSignTool()
        state.fillAndSignVisible = false
        state.transitionProgressOverride = nil

        // Right assistant drawer: same rule, through its own transition.
        state.rightPanelVisible = true
        try await eventually("the assistant panel is open for the width check", {
            harness.sidePanelRect() != nil
        })
        let fullPanelWidth = ReaderSidePanelMetrics.totalWidth(
            contentWidth: state.rightPanelWidthPt)
        try await eventuallyExplaining(
            "the row settles against the full assistant panel",
            {
                let row = harness.chromeRect(.secondaryToolbar)
                return "row=\(String(describing: row)) width=\(harness.host.bounds.width) "
                    + "panel=\(String(describing: harness.sidePanelRect())) "
                    + "visible=\(state.rightPanelVisible) full=\(fullPanelWidth)"
            },
            {
                guard let row = harness.chromeRect(.secondaryToolbar) else { return false }
                return abs(row.minX) <= 0.5
                    && abs(row.maxX - (harness.host.bounds.width - fullPanelWidth)) <= 0.5
            })
        var panelRowWidths: [CGFloat] = []
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] + [0.75, 0.5, 0.25, 0.0] {
            state.transitionProgressOverride = ReaderTransitionProgress(
                row: 1, panel: progress, editingPanel: 0)
            let expectedWidth = ReaderSidePanelMetrics.totalWidth(
                contentWidth: state.rightPanelWidthPt) * CGFloat(progress)
            // Wait for the pinned frame *and* the row/panel edge together. The width alone can
            // reach its target one layout pass before the marker's leading edge settles after a
            // close, which made this assertion depend on how loaded the run loop was.
            try await eventually("the assistant panel is pinned at \(progress)", {
                guard let panel = harness.sidePanelRect(),
                      let row = harness.chromeRect(.secondaryToolbar) else { return false }
                return abs(panel.width - expectedWidth) <= 1
                    && abs(row.maxX - panel.minX) <= 0.5
            })
            harness.host.layoutSubtreeIfNeeded()
            guard let row = harness.chromeRect(.secondaryToolbar),
                  let panel = harness.sidePanelRect() else {
                require(false, "the row and assistant panel markers exist at \(progress)")
                continue
            }
            require(abs(row.maxX - panel.minX) <= 0.5,
                    "the row ends flush against the moving assistant panel at progress "
                        + "\(progress) (row \(row.maxX), panel \(panel.minX))")
            require(abs(row.minX) <= 0.5,
                    "the row starts at the content edge with the sidebar closed at "
                        + "\(progress) (row minX \(row.minX))")
            panelRowWidths.append(row.width)
        }
        require(zip(panelRowWidths, panelRowWidths.dropFirst()).allSatisfy {
                    abs($1 - $0) > 1
                },
                "the row width changes on every sampled assistant-panel frame "
                    + "(\(panelRowWidths.map { Int($0) }))")
        print("ROW WIDTH assistant: \(panelRowWidths.map { Int($0) }) pt")
        state.transitionProgressOverride = nil
        state.rightPanelVisible = false

        // Left sidebar: the row's leading edge must follow the drawer's moving trailing edge.
        state.annotationToolsVisible = true
        state.sidebarVisible = true
        try await eventually("the sidebar and row are open for the width check", {
            harness.rowHeight >= 44
        })
        try await eventually("the row settles against the open sidebar", {
            guard let row = harness.chromeRect(.secondaryToolbar) else { return false }
            return abs(row.minX - ReaderChrome.sidebarTotalWidthPt) <= 0.5
        })
        var sidebarRowWidths: [CGFloat] = []
        var sidebarLeftEdges: [CGFloat] = []
        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] + [0.75, 0.5, 0.25, 0.0] {
            state.transitionProgressOverride = ReaderTransitionProgress(
                sidebar: progress, row: 1, panel: 0, editingPanel: 0)
            let expectedInset = ReaderChrome.sidebarTotalWidthPt * CGFloat(progress)
            // The row reaches its pinned edge before the canvas has finished following it; wait
            // for both so the coverage assertion is a fact about the settled frame.
            try await eventually("the sidebar is pinned at \(progress)", {
                guard let row = harness.chromeRect(.secondaryToolbar) else { return false }
                let canvas = harness.canvasRect
                return abs(row.minX - expectedInset) <= 0.5
                    && row.minX <= canvas.minX + 0.5 && row.maxX >= canvas.maxX - 0.5
            })
            harness.host.layoutSubtreeIfNeeded()
            guard let row = harness.chromeRect(.secondaryToolbar) else {
                require(false, "the row and canvas exist at sidebar progress \(progress)")
                continue
            }
            let canvas = harness.canvasRect
            require(abs(row.minX - ReaderChrome.sidebarTotalWidthPt * CGFloat(progress)) <= 0.5,
                    "the row starts on the moving sidebar edge at progress \(progress) "
                        + "(\(row.minX) vs "
                        + "\(ReaderChrome.sidebarTotalWidthPt * CGFloat(progress)))")
            require(abs(row.maxX - harness.host.bounds.width) <= 0.5,
                    "the row still reaches the window's trailing edge at progress \(progress)")
            require(row.minX <= canvas.minX + 0.5 && row.maxX >= canvas.maxX - 0.5,
                    "the row background covers the canvas at sidebar progress \(progress) "
                        + "(row \(row.minX)..\(row.maxX), canvas \(canvas.minX)..\(canvas.maxX))")
            sidebarRowWidths.append(row.width)
            sidebarLeftEdges.append(row.minX)
        }
        require(zip(sidebarRowWidths, sidebarRowWidths.dropFirst()).allSatisfy {
                    abs($1 - $0) > 1
                },
                "the row width changes on every sampled sidebar frame "
                    + "(\(sidebarRowWidths.map { Int($0) }))")
        print("ROW WIDTH sidebar: \(sidebarRowWidths.map { Int($0) }) pt at x "
              + "\(sidebarLeftEdges.map { Int($0) })")
        state.transitionProgressOverride = nil
        state.sidebarVisible = false
        state.annotationToolsVisible = false
        try await eventually("the width checks leave the row closed", {
            harness.rowHeight == 0
        })

        // ── 6. No animation on first layout, during a live resize, or with Reduce Motion ─
        let firstLayoutState = AppState(engine: try RustEngine())
        firstLayoutState.setViewportSize(CGSize(width: 1100, height: 750))
        firstLayoutState.newTab(url: fixture)
        try await eventually("the first-layout fixture opens", {
            firstLayoutState.document != nil && !firstLayoutState.canvasPageFrames.isEmpty
        })
        firstLayoutState.contentEditEnabled = true
        let firstLayout = try await ToolbarRowHarness.make(
            state: firstLayoutState, mountWait: false)
        defer { firstLayout.close() }
        // Give the first layout one short run-loop turn, well inside the 180 ms animation. A
        // row that animated its initial value would still be part-way open here.
        try await Task.sleep(for: .milliseconds(20))
        firstLayout.host.layoutSubtreeIfNeeded()
        let firstBottom = firstLayout.rowHeight
        require(firstBottom >= 44,
                "a row that is open at first layout is at full height immediately "
                    + "(\(firstBottom) pt after 20 ms)")

        // The same first-layout rule for Fill & Sign, whose first layout also opens the
        // inspector: neither may animate from zero on the window's first frame.
        let fillFirstState = AppState(engine: try RustEngine())
        fillFirstState.setViewportSize(CGSize(width: 1100, height: 750))
        fillFirstState.newTab(url: fixture)
        try await eventually("the Fill & Sign first-layout fixture opens", {
            fillFirstState.document != nil && !fillFirstState.canvasPageFrames.isEmpty
        })
        fillFirstState.fillAndSignVisible = true
        fillFirstState.selectFillSignTool(.signature)
        let fillFirst = try await ToolbarRowHarness.make(
            state: fillFirstState, mountWait: false)
        defer { fillFirst.close() }
        try await Task.sleep(for: .milliseconds(20))
        fillFirst.host.layoutSubtreeIfNeeded()
        require(fillFirst.rowHeight >= 44,
                "the Fill & Sign row is at full height on its first layout "
                    + "(\(fillFirst.rowHeight) pt after 20 ms)")
        require(fillFirstState.fillSignInspectorVisible,
                "the Fill & Sign inspector is present on that first layout")

        state.transitionProgressOverride = nil
        if state.fillAndSignVisible { state.fillAndSignVisible = false }
        if state.exportVisible { state.exportVisible = false }
        if state.contentEditEnabled { state.contentEditEnabled = false }
        state.annotationToolsVisible = false
        // The live-resize rule is about the *window*, not about the machine's Reduce Motion
        // preference. Pin the preference off for this block (CI runners sometimes have it on)
        // and restore whatever the process had afterwards.
        let savedReduceMotion = ReaderMotion.reduceMotionOverride
        defer { ReaderMotion.reduceMotionOverride = savedReduceMotion }
        ReaderMotion.reduceMotionOverride = false
        NotificationCenter.default.post(
            name: NSWindow.willStartLiveResizeNotification, object: harness.window)
        try await Task.sleep(for: .milliseconds(80))
        state.contentEditEnabled = true
        try await Task.sleep(for: .milliseconds(120))
        require(harness.rowHeight >= 44,
                "a row toggled during a live window resize is open after 120 ms "
                    + "(\(harness.rowHeight) pt; an animated one would be part-way)")
        NotificationCenter.default.post(
            name: NSWindow.didEndLiveResizeNotification, object: harness.window)
        try await Task.sleep(for: .milliseconds(80))
        require(ReaderMotion.secondaryRowAnimation != nil,
                "the row animation is available again after the live resize")
        state.contentEditEnabled = false
        try await Task.sleep(for: .milliseconds(120))

        ReaderMotion.reduceMotionOverride = true
        require(ReaderMotion.secondaryRowAnimation == nil,
                "Reduce Motion removes the row animation")
        state.fillAndSignVisible = true
        try await Task.sleep(for: .milliseconds(80))
        require(harness.rowHeight >= 44,
                "with Reduce Motion on, the Fill & Sign row is at full height after 80 ms")
        state.fillAndSignVisible = false
        try await Task.sleep(for: .milliseconds(120))
        ReaderMotion.reduceMotionOverride = false

        // ── 7. The primary toolbar's Fill & Sign label hides at the minimum width ───────
        let wideToolbar = ReaderToolbarProbe.toolbarFrames(state: state, width: 1400)
        let defaultToolbar = ReaderToolbarProbe.toolbarFrames(state: state, width: 1200)
        let minimumToolbar = ReaderToolbarProbe.toolbarFrames(state: state, width: 900)
        print("TOOLBAR LABELS wide: \(wideToolbar.keys.sorted().filter { $0.contains("label") })")
        print("TOOLBAR LABELS 900: \(minimumToolbar.keys.sorted().filter { $0.contains("label") })")
        require(wideToolbar["toolbar.fillSign.label"] != nil,
                "the Fill & Sign label is present at a wide window")
        require(defaultToolbar["toolbar.fillSign.label"] != nil,
                "the Fill & Sign label is present at the 1200 pt default window")
        require(minimumToolbar["toolbar.fillSign.label"] == nil,
                "the Fill & Sign label is hidden at the 900 pt minimum width")
        require((wideToolbar["toolbar.annotate.label"] != nil)
                    == (wideToolbar["toolbar.fillSign.label"] != nil),
                "the Fill & Sign label follows Annotate at wide widths")
        require((minimumToolbar["toolbar.annotate.label"] != nil)
                    == (minimumToolbar["toolbar.fillSign.label"] != nil),
                "the Fill & Sign label follows Annotate at the minimum width")
        require((wideToolbar["toolbar.edit.label"] != nil)
                    == (wideToolbar["toolbar.fillSign.label"] != nil),
                "the Fill & Sign label follows Edit at wide widths")
        require((minimumToolbar["toolbar.edit.label"] != nil)
                    == (minimumToolbar["toolbar.fillSign.label"] != nil),
                "the Fill & Sign label follows Edit at the minimum width")
        require(wideToolbar["toolbar.fillSign"] != nil,
                "the Fill & Sign toolbar button is measurable")
        require(wideToolbar["toolbar.fillSign"]!.width
                    >= (minimumToolbar["toolbar.fillSign"]?.width ?? 0),
                "hiding the label does not make the button wider at the minimum window")

        // The Annotate button is a mode toggle too: it keeps its icon and text and has no
        // trailing chevron, so the label is the button's last content. The tail after the text
        // is just the label padding (6) plus the button style's padding (3); the chevron and its
        // 6 pt gap would add ~12 more.
        let wideAnnotateButton = wideToolbar["toolbar.annotate"]
        let wideAnnotateLabel = wideToolbar["toolbar.annotate.label"]
        require(wideAnnotateButton != nil && wideAnnotateLabel != nil,
                "the Annotate button and its text are measurable")
        if let button = wideAnnotateButton, let label = wideAnnotateLabel {
            let tail = button.maxX - label.maxX
            require(tail <= 12,
                    "the Annotate button ends at its text with no chevron (tail \(tail) pt)")
        }

        // The Lyra button keeps its icon and text but has no trailing chevron. The label is the
        // button's last content, so the tail after the text is just the label padding (6) plus
        // the button style's padding (3) - the chevron and its 6 pt gap would add ~12 more.
        let wideLyraButton = wideToolbar["toolbar.lyra"]
        let wideLyraIcon = wideToolbar["toolbar.lyra.icon"]
        let wideLyraLabel = wideToolbar["toolbar.lyra.label"]
        require(wideToolbar["toolbar.lyra.label"] != nil,
                "the Lyra button keeps its text at a wide window")
        require(minimumToolbar["toolbar.lyra.label"] == nil,
                "the Lyra label follows the other labels and hides at the 900 pt minimum")
        require(wideLyraButton != nil && wideLyraIcon != nil,
                "the Lyra button and its icon are measurable")
        if let button = wideLyraButton, let icon = wideLyraIcon, let label = wideLyraLabel {
            require(icon.maxX <= label.minX + 0.01,
                    "the Lyra icon precedes the text (\(icon.maxX) <= \(label.minX))")
            require(abs((label.minX - icon.maxX) - 6) <= 1,
                    "the Lyra icon and text keep their 6 pt spacing "
                        + "(\(label.minX - icon.maxX))")
            let tail = button.maxX - label.maxX
            require(tail <= 12,
                    "the Lyra button ends at its text with no chevron (tail \(tail) pt)")
        }

        // ── 8. Organise pages is gone; every command has a menu-bar home ───────────────
        let toolbarSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/ReaderToolbar.swift"),
            encoding: .utf8)
        for retired in ["Organise pages", "FillSignMenuButton",
                        "LyraReaderMenu(title: \"Organise pages\"",
                        "LyraReaderMenu(title: \"Export and save\""] {
            require(!toolbarSource.contains(retired),
                    "the toolbar source no longer contains \(retired)")
        }
        require(toolbarSource.contains("AnnotationToolbarLayout.exportIcon"),
                "the Export button uses the row's own glyph constant")
        require(toolbarSource.contains("toggleFillAndSign()")
                    && toolbarSource.contains("toggleExport()"),
                "the primary toolbar has buttons for both new rows")
        // The Annotate button's own source: icon, text, selected style and tooltip, and no
        // chevron between the label and the button's trailing edge.
        if let start = toolbarSource.range(
                of: "Button { state.toggleAnnotationTools() }")?.lowerBound,
           let end = toolbarSource.range(
                of: ".background(AnnotationToolbarFrameReader(id: \"toolbar.annotate\"))",
                range: start..<toolbarSource.endIndex)?.upperBound {
            let annotateButtonSource = toolbarSource[start..<end]
            require(annotateButtonSource.contains("Image(systemName: \"highlighter\")")
                        && annotateButtonSource.contains("Text(\"Annotate\")"),
                    "the Annotate button keeps its icon and text")
            require(annotateButtonSource.contains(
                        ".buttonStyle(LyraReaderToolStyle(selected: state.annotationToolsVisible"),
                    "the Annotate button keeps its selected state")
            require(annotateButtonSource.contains(".help(\"Show annotation tools\")"),
                    "the Annotate button keeps its tooltip")
            require(!annotateButtonSource.contains("chevron"),
                    "the Annotate button has no chevron glyph or its gap")
        } else {
            require(false, "the Annotate toolbar button source is locatable")
        }
        // The Lyra button's own source: icon, text, and no chevron between the label and the
        // button's trailing edge.
        if let start = toolbarSource.range(of: "Button { state.toggleAITools() }")?.lowerBound,
           let end = toolbarSource.range(
                of: ".keyboardShortcut(\"a\"", range: start..<toolbarSource.endIndex)?.upperBound {
            let lyraButtonSource = toolbarSource[start..<end]
            require(lyraButtonSource.contains("LyraAIIcon()")
                        && lyraButtonSource.contains("Text(\"Lyra\")"),
                    "the Lyra button keeps its icon and text")
            require(!lyraButtonSource.contains("chevron"),
                    "the Lyra button has no chevron glyph or its gap")
        } else {
            require(false, "the Lyra toolbar button source is locatable")
        }

        let appMenuSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReader/LyraReaderApp.swift"),
            encoding: .utf8)
        require(appMenuSource.contains("Menu(PageOperationsMenu.title)"),
                "the system Edit menu has a Page Operations submenu")
        require(appMenuSource.contains("ForEach(PageOperationsMenu.commands)"),
                "the Edit submenu is built from the same command list the checks hold")
        let expectedPageOperations = ["rotateClockwise", "rotateAnticlockwise",
                                      "insertBlankPageAfter", "extractSelectedPages",
                                      "appendPagesFromPDFs", "splitPages"]
        require(PageOperationsMenu.commands.map(\.id) == expectedPageOperations,
                "the six Organise pages commands all have a Page Operations entry")
        require(PageOperationsMenu.commands.map(\.title)
                    == ["Rotate Clockwise", "Rotate Anticlockwise", "Insert Blank Page After",
                        "Extract Selected Pages…", "Append Pages from PDFs…", "Split Pages…"],
                "the Page Operations submenu keeps the toolbar menu's command names")
        // And the full Pages menu still carries the same operations for reading workflows.
        for method in ["rotateSelectedPages(clockwise: true)",
                       "rotateSelectedPages(clockwise: false)",
                       "insertBlankPage(before: false)",
                       "presentExtractPagesPanel()",
                       "presentMergeDocumentsPanel()",
                       "presentSplitPagesPanel()"] {
            require(appMenuSource.contains(method),
                    "the menu bar still reaches Page Operations' \(method)")
        }

        // ── 9. The Export row carries every old command and its new icon ───────────────
        require(AnnotationToolbarLayout.exportIcon == "arrow.down.doc",
                "Export uses the document-download glyph")
        require(AnnotationToolbarLayout.exportIcon != "square.and.arrow.up",
                "Export's glyph is not the system Share glyph")
        require(NSImage(systemSymbolName: AnnotationToolbarLayout.exportIcon,
                        accessibilityDescription: nil) != nil,
                "the Export glyph exists on this macOS")
        require(ExportCommand.all.map(\.action) == ExportCommand.Action.allCases,
                "the Export row declares all eight commands")
        require(ExportCommand.all.map(\.fullTitle)
                    == ["Save", "Save As…", "Save Annotated Copy…",
                        "Export as Flattened Copy…", "Save Filled Form Copy…",
                        "Write Form Values to Original…", "Export Annotations…", "Print…"],
                "the Export row's items are the requested commands in order")
        require(ExportCommand.all.map(\.title)
                    == ["Save", "Save As…", "Annotated…", "Flattened…", "Filled Form…",
                        "Form Values…", "Annotations…", "Print…"],
                "the Export row's short labels fit the row in order")
        require(ExportCommand.all.allSatisfy {
                    NSImage(systemSymbolName: $0.icon, accessibilityDescription: nil) != nil
                }, "every Export item's glyph exists on this macOS")
        let enabledByAction: [ExportCommand.Action: Bool] = [
            .save: state.canSaveDocument,
            .saveAs: state.canSaveDocument,
            .saveAnnotatedCopy: state.document != nil && !state.annotationSaveInProgress,
            .exportFlattenedCopy: state.canFlattenDocument,
            .saveFilledFormCopy: state.canSaveFilledForm,
            .writeFormValuesToOriginal: state.canReplaceOriginalWithFilledForm,
            .exportAnnotations: state.canExportAnnotations,
            .print: state.document != nil,
        ]
        for command in ExportCommand.all {
            require(command.isEnabled(state) == enabledByAction[command.action],
                    "Export's \(command.title) uses the reader's own enabled rule")
            require(command.helpText(state).contains(command.help),
                    "Export's \(command.title) keeps its help sentence")
        }
        let wideExport = ReaderToolbarProbe.exportRowFrames(state: state, width: rowWidth)
        let minimumExport = ReaderToolbarProbe.exportRowFrames(
            state: state, width: minimumRowWidth)
        for (frames, label, width) in [(wideExport, "1200 pt window", rowWidth),
                                       (minimumExport, "900 pt minimum", minimumRowWidth)] {
            let ordered = ExportCommand.all.map {
                frame("export.\($0.id)", frames, label)
            }
            print("EXPORT \(label): "
                  + zip(ExportCommand.all, ordered)
                    .map { "\($0.title)=\(Int($1.minX))..\(Int($1.maxX))" }
                    .joined(separator: " "))
            require(zip(ordered, ordered.dropFirst()).allSatisfy { $0.maxX <= $1.minX },
                    "\(label): the Export items do not overlap")
            require(ordered.allSatisfy { $0.width > 1 },
                    "\(label): every Export item has a measurable control")
            require(ordered.last!.maxX <= width - AnnotationToolbarLayout.horizontalPadding + 0.01,
                    "\(label): the Export row fits inside the canvas width "
                        + "(\(ordered.last!.maxX) of \(width))")
        }

        // Every command that used to be in a toolbar menu still has a named home.
        let exportSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/ExportCommands.swift"),
            encoding: .utf8)
        for method in ["state.saveDocument()", "state.presentSaveDocumentCopyPanel()",
                       "state.presentSaveAnnotatedCopyPanel()", "state.presentFlattenCopyPanel()",
                       "state.presentSaveFilledFormPanel()",
                       "state.presentReplaceOriginalWithFilledFormConfirmation()",
                       "state.presentExportAnnotationsPanel()", "state.printDocument()"] {
            require(exportSource.contains(method),
                    "the Export row keeps \(method)")
        }
        require(toolbarSource.contains("ExportToolRow(state: state)"),
                "the primary toolbar hosts the Export row")
        require(appMenuSource.contains("presentSaveFilledFormPanel")
                    && appMenuSource.contains("presentReplaceOriginalWithFilledFormConfirmation"),
                "the File menu carries both Fill & Sign form writes")
        let fillInspectorSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/FillSignInspector.swift"),
            encoding: .utf8)
        require(fillInspectorSource.contains("state.fillSignFormCommands")
                    && fillInspectorSource.contains("performFillAndSignCommand"),
                "the Fill & Sign inspector carries both form writes too")

        // ── 10. Continuity is hosted in the inspector and still wired ────────────────────
        let controller = FillSignCommandController(state: state)
        let requestor = ContinuitySignatureRequestor(controller: controller)
        require(requestor.title == "From iPhone or iPad",
                "the Signature inspector retains its device entry")
        let inspectorSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/FillSignInspector.swift"),
            encoding: .utf8)
        require(inspectorSource.contains("SignatureContinuityButton"),
                "the inspector hosts the continuity button")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lyra-toolbar-rows-\(UUID())"))
        pasteboard.clearContents()
        let png = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: png)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        pasteboard.setData(png.representation(using: .png, properties: [:])!, forType: .png)
        state.selectFillSignTool(.signature)
        let requestorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        requestorWindow.isReleasedWhenClosed = false
        requestorWindow.contentView = requestor
        defer { requestorWindow.close(); pasteboard.releaseGlobally() }
        require(requestor.beginRequest(), "the inspector's device button becomes the requestor")
        require(requestor.readSelection(from: pasteboard),
                "the continuity requestor accepts a sketch from the pasteboard")
        require(state.pendingSignatureImageData != nil,
                "the received sketch becomes the armed signature image")
        state.clearFillSignTool()

        // ── 11. Closing the document closes the rows and disarms their tools ─────────────
        // The tool belongs to the document's page. Closing the active tab must leave the next
        // document—or the empty window—with no row or tool armed against a page that is gone.
        let closeState = AppState(engine: try RustEngine())
        closeState.setViewportSize(CGSize(width: 1000, height: 750))
        func reopenCloseFixture(_ label: String) async throws {
            closeState.newTab(url: fixture)
            try await eventually("\(label): the fixture opens", { closeState.document != nil })
        }

        try await reopenCloseFixture("document-close annotation")
        closeState.annotationToolsVisible = true
        closeState.toggleAnnotationTool(.pen)
        require(closeState.annotationTool == .pen,
                "the Pen is armed before the document closes")
        closeState.closeTab(0)
        require(closeState.document == nil, "closing the only tab closes the document")
        require(closeState.annotationTool == .select && closeState.openSecondaryRows.isEmpty,
                "closing the document clears an armed annotation tool and its row")

        try await reopenCloseFixture("document-close content")
        closeState.contentEditEnabled = true
        closeState.selectContentTool("text")
        require(closeState.contentEditInspectorVisible,
                "the Edit inspector is open before the document closes")
        closeState.closeTab(0)
        require(closeState.document == nil, "the reopened document closes")
        require(closeState.contentEditTool == "select"
                    && !closeState.contentEditInspectorVisible
                    && closeState.openSecondaryRows.isEmpty,
                "closing the document clears the content tool, its inspector and its row")

        try await reopenCloseFixture("document-close fill")
        closeState.fillAndSignVisible = true
        closeState.selectFillSignTool(.date)
        require(closeState.armedFillSignTool == .date && closeState.fillSignInspectorVisible,
                "the Fill & Sign item and inspector are open before the document closes")
        closeState.closeTab(0)
        require(closeState.document == nil, "the Fill & Sign document closes")
        require(closeState.armedFillSignTool == nil && closeState.pendingFillSignPlacement == nil
                    && !closeState.fillSignInspectorVisible
                    && closeState.openSecondaryRows.isEmpty,
                "closing the document clears the Fill & Sign item, inspector and row")

        print("Toolbar row checks passed")
    }
}

/// The hosted reader a row's slide and inspector are measured on.
@MainActor
private final class ToolbarRowHarness {
    let state: AppState
    let host: NSHostingView<ReaderWindow>
    let window: NSWindow
    private(set) var canvas: MetalCanvasView!

    private init(state: AppState) {
        self.state = state
        self.host = NSHostingView(rootView: ReaderWindow(
            state: state, opener: DocumentOpenCoordinator(state: state)))
        self.window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1100, height: 750),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
    }

    /// Builds a harness around a state that already has a document, and (by default) waits for
    /// the canvas to lay out. `mountWait: false` is for the first-layout check: it returns after
    /// ordering the window so the caller can measure the initial layout.
    static func make(state: AppState, mountWait: Bool = true) async throws
        -> ToolbarRowHarness {
        let harness = ToolbarRowHarness(state: state)
        harness.window.orderFrontRegardless()
        if mountWait {
            try await ReaderChecks.eventually("the row harness lays out its canvas", {
                harness.host.layoutSubtreeIfNeeded()
                harness.canvas = harness.findCanvas(in: harness.host)
                return harness.canvas != nil
            })
            harness.host.layoutSubtreeIfNeeded()
        } else {
            harness.host.layoutSubtreeIfNeeded()
            harness.canvas = harness.findCanvas(in: harness.host)
        }
        return harness
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func findCanvas(in view: NSView) -> MetalCanvasView? {
        if let found = view as? MetalCanvasView { return found }
        return view.subviews.lazy.compactMap { self.findCanvas(in: $0) }.first
    }

    var canvasRect: CGRect {
        host.layoutSubtreeIfNeeded()
        guard let canvas else { return .zero }
        if let clip = canvas.enclosingScrollView?.contentView {
            return host.convert(clip.bounds, from: clip)
        }
        return host.convert(canvas.bounds, from: canvas)
    }

    func pageTopInHost(page: Int) -> CGFloat? {
        guard let placement = state.canvasPageFrames.first(where: { $0.index == page }) else {
            return nil
        }
        let fromCanvasTop = (placement.topPt - state.scrollYPt) * state.zoomFactor
        return canvasRect.maxY - fromCanvasTop
    }

    func hit(fromCanvasTop offset: CGFloat, xFraction: CGFloat = 0.5) -> NSView? {
        host.layoutSubtreeIfNeeded()
        guard let canvas else { return nil }
        let local = CGPoint(x: canvas.bounds.width * xFraction,
                            y: canvas.bounds.height - offset)
        let inHost = host.convert(local, from: canvas)
        return host.hitTest(host.convert(inHost, to: host.superview))
    }

    /// The animated height of the one secondary-row slot, measured from the marker the
    /// transition hosts around the row. Hit testing cannot be used here: when Edit is open its
    /// content editor covers the canvas below the row, and a click below the row would still
    /// miss the Metal canvas.
    var rowHeight: CGFloat {
        chromeRect(.secondaryRowSlot)?.height ?? 0
    }

    /// Whether the row content and every view between it and the host are fully opaque.
    ///
    /// A fade during the reveal would leave one of these ancestors or the content itself below
    /// opacity 1 at a pinned intermediate height; a clean slide keeps them all at 1.
    var rowContentIsOpaque: Bool {
        guard let marker = chromeView(.secondaryToolbar) else { return false }
        var view: NSView = marker
        while true {
            if view.alphaValue < 0.999 { return false }
            if view.isHidden { return false }
            if let opacity = view.layer?.opacity, opacity < 0.999 { return false }
            guard let parent = view.superview else { return true }
            view = parent
        }
    }

    /// Sends one left click to a page-local point through the real canvas.
    ///
    /// This drives the same `mouseDown`/`mouseUp` path a reader's click takes, including the
    /// canvas's tool dispatch and the ReaderWindow closures, rather than calling an AppState
    /// placement helper directly. It is how the row checks prove that a tool really stopped
    /// applying after its row closed, not just that a boolean was reset.
    @discardableResult
    func clickPage(_ page: Int, at point: CGPoint) -> Bool {
        host.layoutSubtreeIfNeeded()
        guard let canvas,
              let placement = state.canvasPageFrames.first(where: { $0.index == page }) else {
            return false
        }
        let zoom = state.zoomFactor
        let offsetX = CanvasGeometry.contentOffsetX(
            viewportWidthPt: canvas.bounds.width,
            contentWidthPt: state.contentWidthPt,
            zoom: zoom)
        let content = CGPoint(x: placement.leftPt + point.x, y: placement.topPt + point.y)
        let viewPoint = CGPoint(
            x: offsetX + content.x * zoom,
            y: canvas.bounds.height - (content.y - state.scrollYPt) * zoom)
        let location = canvas.convert(viewPoint, to: nil)
        guard let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 0) else {
            return false
        }
        canvas.mouseDown(with: down)
        canvas.mouseUp(with: up)
        return true
    }

    /// The right-hand drawer's marker, so the checks can compare its moving leading edge with
    /// the secondary row's trailing edge.
    func sidePanelRect() -> CGRect? {
        func find(_ view: NSView) -> ReaderSidePanelMarkerView? {
            if let found = view as? ReaderSidePanelMarkerView { return found }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        host.layoutSubtreeIfNeeded()
        guard let marker = find(host) else { return nil }
        return host.convert(marker.bounds, from: marker)
    }

    /// Any of the chrome markers by kind, as the view itself.
    func chromeView(_ kind: ReaderChromeMarkerView.Kind) -> ReaderChromeMarkerView? {
        func find(_ view: NSView) -> ReaderChromeMarkerView? {
            if let found = view as? ReaderChromeMarkerView, found.kind == kind { return found }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        host.layoutSubtreeIfNeeded()
        return find(host)
    }

    /// Any of the chrome markers by kind, in host coordinates.
    func chromeRect(_ kind: ReaderChromeMarkerView.Kind) -> CGRect? {
        guard let marker = chromeView(kind) else { return nil }
        return host.convert(marker.bounds, from: marker)
    }
}

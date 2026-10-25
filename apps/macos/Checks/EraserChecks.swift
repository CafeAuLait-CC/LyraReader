import AppKit
import LyraReaderKit
import Foundation
import PDFKit

/// The eraser: a mode that cuts **ink**, not annotations. This suite covers the whole-stroke
/// behaviour it started with (a drag along a stroke removes it); `PartialEraseChecks` covers the
/// split, identity, undo and save rules for a drag that cuts only part of a stroke.
///
/// Every check runs through the real `AppState`, the real `MetalCanvasView` event path and the
/// real engine, on scratch copies of the committed fixtures. The canvas is wired exactly as
/// `ReaderWindow` wires it, so a press/drag here takes the same route a hand does: `mouseDown` →
/// `beginEraserGesture`, `mouseDragged` → `extendEraserGesture`, `mouseUp` → `endEraserGesture`.
extension ReaderChecks {
    @MainActor static func eraserChecks(root: URL, drawing: URL, strokes: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-reader-eraser-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        func copy(_ source: URL, _ name: String) throws -> URL {
            let destination = scratch.appendingPathComponent(name)
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.removeItem(at: records(for: destination))
            return destination
        }
        func records(for document: URL) -> URL {
            DocumentEditCache.annotationsURL(for: document)
        }
        func placement(_ state: AppState, page: Int) -> PagePlacement {
            guard let frame = state.canvasPageFrames.first(where: { $0.index == page }) else {
                fatalError("FAIL: page \(page + 1) has no canvas frame")
            }
            return frame
        }
        /// A page-local point in the content space the canvas reports.
        func content(_ state: AppState, page: Int, _ point: CGPoint) -> CGPoint {
            let frame = placement(state, page: page)
            return CGPoint(x: frame.leftPt + point.x, y: frame.topPt + point.y)
        }
        func ids(_ state: AppState) -> [UUID] { state.annotations.map(\.id) }
        func requireTargetIsDocument(_ target: AppState.EraserTarget?, _ message: String) {
            guard case .document = target else {
                require(false, "\(message) (got \(String(describing: target)))")
                return
            }
            require(true, message)
        }

        let viewport = CGSize(width: 700, height: 500)
        func makeState(_ url: URL) throws -> AppState {
            let state = AppState(engine: try RustEngine())
            state.setViewportSize(viewport)
            state.newTab(url: url)
            require(state.document != nil, "\(url.lastPathComponent) opens")
            return state
        }

        /// The canvas wired to `state` exactly as `ReaderWindow` wires it.
        func makeCanvas(_ state: AppState) -> MetalCanvasView {
            let view = MetalCanvasView(frame: CGRect(origin: .zero, size: viewport))
            view.annotationTool = .eraser
            view.annotationPageFrames = state.canvasPageFrames
            view.onEraseGestureBegan = { point in
                state.beginEraserGesture(atContentPoint: point)
            }
            view.onEraseGestureDragged = { previous, point in
                state.extendEraserGesture(fromContentPoint: previous, toContentPoint: point)
            }
            view.onEraseGestureEnded = { state.endEraserGesture() }
            view.onEraserHover = { point in state.updateEraserHover(atContentPoint: point) }
            return view
        }
        /// One press-drag-release through that canvas, in content points.
        func drag(_ view: MetalCanvasView, from start: CGPoint, through path: [CGPoint],
                  to end: CGPoint) {
            func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type,
                    location: CGPoint(x: point.x, y: viewport.height - point.y),
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown, start))
            for point in path { view.mouseDragged(with: event(.leftMouseDragged, point)) }
            view.mouseDragged(with: event(.leftMouseDragged, end))
            view.mouseUp(with: event(.leftMouseUp, end))
        }
        func escapeEvent() -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        }
        /// A mouse event at a **top-left** view point, the space the cursor ring reports in.
        /// AppKit carries bottom-left window coordinates, so the conversion matches `drag`'s.
        func mouseEvent(_ type: NSEvent.EventType, in view: MetalCanvasView,
                        atTopLeft point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: CGPoint(x: point.x, y: view.bounds.height - point.y),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        // ── 1. The mode arms and disarms like the other tools ──────────────────────────────
        let document = try copy(drawing, "eraser.pdf")
        let originalPDFBytes = try Data(contentsOf: document)
        let state = try makeState(document)
        require(state.annotationTool == .select, "the reader opens in selection mode")
        require(state.canUseEraserTool,
                "the toolbar's eraser button is enabled while a document is open")
        require(!state.annotationTool.draws && state.annotationTool.kind == nil,
                "the eraser is a mode, not a drawing tool")
        require(AnnotationTool.eraser.erasesInk, "the tool reports that it erases ink")

        state.toggleEraserTool()
        require(state.annotationTool == .eraser, "the eraser button arms the mode")
        state.toggleEraserTool()
        require(state.annotationTool == .select, "clicking the armed eraser again leaves the mode")

        state.annotationTool = .pen
        state.toggleEraserTool()
        require(state.annotationTool == .eraser,
                "arming the eraser replaces another tool: the canvas has one mode")
        state.selectTool()
        require(state.annotationTool == .select, "returning to the implicit pointer state leaves the eraser")

        state.toggleEraserTool()
        require(state.cancelActiveAnnotationTool(), "Escape leaves the eraser")
        require(state.annotationTool == .select, "Escape restores reading mode")
        require(!state.cancelActiveAnnotationTool(),
                "Escape in selection mode is not consumed by the eraser")

        // The same through the canvas' Escape path, which is what the window actually calls.
        let escapeCanvas = makeCanvas(state)
        escapeCanvas.onCancelTool = { state.cancelActiveAnnotationTool() }
        state.toggleEraserTool()
        escapeCanvas.keyDown(with: escapeEvent())
        require(state.annotationTool == .select, "Escape on the canvas leaves the eraser")

        let noDocument = AppState(engine: try RustEngine())
        require(!noDocument.canUseEraserTool,
                "the eraser button has nothing to act on without a document")

        // ── 1b. The cursor ring: reach-sized, pointer-following and click-through ─────────
        // The ring is an AppKit overlay, not `NSCursor.eraser`: the system cursor cannot show
        // the tool's reach. It must be exactly `eraserReach × zoom` in view points, follow the
        // pointer at every zoom, hide on exit/disarm and never take a press from the canvas.
        let ringCanvas = makeCanvas(state)
        let ring = ringCanvas.eraserCursorRing
        ringCanvas.zoom = 1
        require(ring.superview === ringCanvas,
                "the eraser ring is an overlay inside the page canvas, not a system cursor")
        require(!ring.isRingVisible,
                "the ring starts hidden until the pointer is over the canvas")

        let firstPointer = CGPoint(x: 220, y: 140)
        ringCanvas.mouseMoved(
            with: mouseEvent(.mouseMoved, in: ringCanvas, atTopLeft: firstPointer))
        require(ring.isRingVisible,
                "the ring appears while the eraser is armed and the pointer is over the canvas")
        require(abs(ring.ringCenterViewPt.x - firstPointer.x) < 0.01
                    && abs(ring.ringCenterViewPt.y - firstPointer.y) < 0.01,
                "the ring is centred under the pointer (\(ring.ringCenterViewPt))")
        let reachAt100 = AnnotationGeometry.eraserReach(strokeWidth: 2, zoom: 1)
        let radiusAt100 = AnnotationGeometry.eraserCursorRadiusViewPt(strokeWidth: 2, zoom: 1)
        require(abs(reachAt100 - 9) < 0.001 && abs(radiusAt100 - 9) < 0.001,
                "at 100% the ring radius is the eraser's 9 pt reach (8 view pt + half the stroke)")
        require(abs(ring.ringRadiusViewPt - radiusAt100) < 0.01,
                "the ring's measured radius is the eraser's reach (\(ring.ringRadiusViewPt) pt)")

        // Follows the pointer, not a cached first position.
        let secondPointer = CGPoint(x: 380, y: 260)
        ringCanvas.mouseMoved(
            with: mouseEvent(.mouseMoved, in: ringCanvas, atTopLeft: secondPointer))
        require(abs(ring.ringCenterViewPt.x - secondPointer.x) < 0.01
                    && abs(ring.ringCenterViewPt.y - secondPointer.y) < 0.01,
                "the ring follows the pointer to a new position at 100%")

        // The radius is the erase reach at the live zoom: the page-space reach shrinks with
        // zoom while its on-screen representation grows with the stroke's visible width.
        ringCanvas.zoom = 2
        let radiusAt200 = AnnotationGeometry.eraserCursorRadiusViewPt(strokeWidth: 2, zoom: 2)
        require(abs(radiusAt200 - 10) < 0.001,
                "at 200% a 2 pt stroke's on-screen reach is 10 view pt (8 + its 4 pt width / 2)")
        require(abs(ring.ringRadiusViewPt - radiusAt200) < 0.01,
                "the ring updates its radius when the zoom changes under a still pointer "
                    + "(\(ring.ringRadiusViewPt) pt)")
        require(abs(ring.ringRadiusViewPt / 2
                    - AnnotationGeometry.eraserReach(strokeWidth: 2, zoom: 2)) < 0.001,
                "the on-screen radius converts back to the page-space erase reach at 200%")
        ringCanvas.mouseMoved(
            with: mouseEvent(.mouseMoved, in: ringCanvas, atTopLeft: firstPointer))
        require(abs(ring.ringCenterViewPt.x - firstPointer.x) < 0.01
                    && abs(ring.ringCenterViewPt.y - firstPointer.y) < 0.01,
                "the ring still follows the pointer at 200%")
        ringCanvas.annotationStrokeWidth = 4
        require(abs(ring.ringRadiusViewPt
                    - AnnotationGeometry.eraserCursorRadiusViewPt(strokeWidth: 4, zoom: 2)) < 0.01,
                "a wider ink setting widens the ring by half the extra stroke width")
        ringCanvas.annotationStrokeWidth = 2
        ringCanvas.zoom = 1

        // Leaving the canvas hides it; moving outside its bounds does too.
        ringCanvas.mouseExited(
            with: mouseEvent(.mouseMoved, in: ringCanvas, atTopLeft: firstPointer))
        require(!ring.isRingVisible, "leaving the canvas hides the ring")
        ringCanvas.mouseMoved(
            with: mouseEvent(.mouseMoved, in: ringCanvas, atTopLeft: CGPoint(x: -4, y: 30)))
        require(!ring.isRingVisible, "a pointer outside the canvas does not draw the ring")
        ringCanvas.mouseMoved(
            with: mouseEvent(.mouseMoved, in: ringCanvas, atTopLeft: firstPointer))
        require(ring.isRingVisible, "moving back over the canvas restores the ring")

        // A drag hides it: the ring marks the reach before/after the cut, not a ghost under the
        // hand while the gesture is running. It returns at the release point, still armed.
        ringCanvas.mouseDown(
            with: mouseEvent(.leftMouseDown, in: ringCanvas, atTopLeft: secondPointer))
        require(!ring.isRingVisible, "the ring hides while an eraser drag owns the pointer")
        ringCanvas.mouseDragged(
            with: mouseEvent(.leftMouseDragged, in: ringCanvas, atTopLeft: secondPointer))
        require(!ring.isRingVisible, "the ring stays hidden through the drag")
        ringCanvas.mouseUp(
            with: mouseEvent(.leftMouseUp, in: ringCanvas, atTopLeft: secondPointer))
        require(ring.isRingVisible, "the ring returns at the release point after the drag")
        require(abs(ring.ringCenterViewPt.x - secondPointer.x) < 0.01
                    && abs(ring.ringCenterViewPt.y - secondPointer.y) < 0.01,
                "the returned ring is centred on the release point")

        // Click-through: the ring is never a hit target, and the event still belongs to the page.
        require(ring.hitTest(CGPoint(x: firstPointer.x, y: firstPointer.y)) == nil,
                "the ring's hitTest returns nil: it cannot intercept a click")
        let hitPoint = CGPoint(x: firstPointer.x,
                               y: ringCanvas.bounds.height - firstPointer.y)
        require(ringCanvas.hitTest(hitPoint) === ringCanvas,
                "a click at the ring's centre still reaches the canvas")

        // Disarming hides it and further pointer movement cannot bring it back.
        ringCanvas.annotationTool = .select
        require(!ring.isRingVisible, "disarming the eraser hides the ring")
        ringCanvas.mouseMoved(
            with: mouseEvent(.mouseMoved, in: ringCanvas, atTopLeft: firstPointer))
        require(!ring.isRingVisible,
                "a pointer move with the eraser disarmed does not show the ring")

        // Theme: a subtle theme-coloured outline with a transparent fill, resolving differently
        // in light and dark. The ring is drawn over arbitrary page content, so it uses the
        // secondary text token rather than a fixed colour.
        require(EraserCursorRingView.fillColor.alphaComponent == 0,
                "the ring's fill is transparent")
        require(EraserCursorRingView.lineWidth == 1,
                "the ring's stroke is the subtle 1 pt line")
        let lightAppearance = NSAppearance(named: .aqua)!
        let darkAppearance = NSAppearance(named: .darkAqua)!
        func components(_ color: NSColor, _ appearance: NSAppearance)
            -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB) ?? .clear
            }
            return (resolved.redComponent, resolved.greenComponent,
                    resolved.blueComponent, resolved.alphaComponent)
        }
        let lightStroke = components(ring.strokeColor(for: lightAppearance), lightAppearance)
        let darkStroke = components(ring.strokeColor(for: darkAppearance), darkAppearance)
        require(abs(lightStroke.a - 0.85) < 0.01 && abs(darkStroke.a - 0.85) < 0.01,
                "the ring keeps the theme's subtle 0.85 alpha in both appearances")
        require(lightStroke.r < darkStroke.r && lightStroke.g < darkStroke.g
                    && lightStroke.b < darkStroke.b,
                "the light appearance draws a dark-on-paper stroke and the dark one a light "
                    + "stroke (\(lightStroke) vs \(darkStroke))")

        let ringSource = try String(
            contentsOf: root.appendingPathComponent(
                "apps/macos/Sources/LyraReaderKit/EraserCursorRing.swift"),
            encoding: .utf8)
        require(!ringSource.contains("NSCursor"),
                "the ring is an AppKit overlay, not a system cursor push")
        require(ringSource.contains("override func hitTest"),
                "the ring's click-through rule is part of the overlay itself")

        // ── 2. Eraser geometry: a stated reach; tracing a stroke removes the whole stroke ──
        // Reach = half the stroke's width + 8 view points at the current zoom. At 100% a 2 pt
        // stroke is therefore removed within 9 page points of its centreline. Partial erase uses
        // the same number; see `PartialEraseChecks` for the cut geometry.
        let red = AnnotationColor(red: 200, green: 30, blue: 40, alpha: 255)
        let twoPointReach = AnnotationGeometry.eraserReach(strokeWidth: 2, zoom: 1)
        require(abs(twoPointReach - 9) < 0.001,
                "at 100% a 2 pt stroke's eraser reach is 9 page pt (8 view pt + half the width)")
        let wideReach = AnnotationGeometry.eraserReach(strokeWidth: 12, zoom: 1)
        require(abs(wideReach - 14) < 0.001,
                "a wider stroke is easier to catch: reach adds half the stroke width")
        // Crossing segments must count as distance zero even when neither segment's endpoints
        // are near the other line; this is what lets one fast drag sample erase a stroke.
        require(AnnotationGeometry.distance(
                    fromSegment: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 50),
                    andPolyline: [CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100)]) == 0,
                "a pointer segment crossing a stroke has distance 0, not endpoint distance")
        require(abs(AnnotationGeometry.distance(
                        fromSegment: CGPoint(x: 0, y: 50), to: CGPoint(x: 100, y: 50),
                        andPolyline: [CGPoint(x: 50, y: 59), CGPoint(x: 50, y: 100)]) - 9) < 0.001,
                "distance to a stroke segment is the segment distance")

        // ── 3. Hover indicates the stroke a press would remove, before it removes it ────
        require(state.addInkAnnotation(page: 0,
                                       points: [CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200)],
                                       color: red, strokeWidth: 2),
                "stroke A is created")
        guard let strokeA = state.annotations.last else {
            require(false, "stroke A is in the model")
            return
        }
        require(state.addInkAnnotation(page: 0,
                                       points: [CGPoint(x: 100, y: 240), CGPoint(x: 300, y: 240)],
                                       color: red, strokeWidth: 2),
                "stroke B is created")
        guard let strokeB = state.annotations.last else {
            require(false, "stroke B is in the model")
            return
        }
        state.toggleEraserTool()
        state.updateEraserHover(atContentPoint: content(state, page: 0, CGPoint(x: 200, y: 204)))
        require(state.eraserHoverMarkID == strokeA.id.uuidString,
                "hovering within the tolerance marks stroke A as the erase target")
        require(state.canvasAnnotationMarks.first(where: { $0.id == strokeA.id.uuidString })?
                    .isEraseTarget == true,
                "the canvas mark carries the target flag the overlay draws the halo for")
        require(state.canvasAnnotationMarks.first(where: { $0.id == strokeB.id.uuidString })?
                    .isEraseTarget == false,
                "a stroke outside the tolerance is not marked")
        state.updateEraserHover(atContentPoint: content(state, page: 0, CGPoint(x: 200, y: 220)))
        require(state.eraserHoverMarkID == nil,
                "moving 20 pt away removes the pre-erase indication")
        state.selectTool()
        require(state.eraserHoverMarkID == nil,
                "leaving the eraser drops its hover indication")

        // ── 4. One drag across one stroke removes exactly that stroke ─────────────────────
        // A copy saved *before* erasing is the control for the one saved after it: both strokes
        // are in it, so the later copy's missing /NM is the erasure and not a write-path quirk.
        let beforeCopyURL = scratch.appendingPathComponent("before-erase.pdf")
        let savedBefore = await state.saveAnnotatedCopy(to: beforeCopyURL)
        require(savedBefore, "a copy saved before erasing holds both strokes")
        let beforeCopyBytes = try Data(contentsOf: beforeCopyURL)
        require(beforeCopyBytes.range(of: Data(strokeA.id.uuidString.utf8)) != nil,
                "the pre-erase copy contains stroke A's /NM")
        require(beforeCopyBytes.range(of: Data(strokeB.id.uuidString.utf8)) != nil,
                "the pre-erase copy contains stroke B's /NM")

        let recordsBeforeFirstErase = try Data(contentsOf: records(for: document))
        state.toggleEraserTool()
        let undoBeforeFirstErase = state.undoStack.count
        let writesBeforeFirstErase = state.annotationWriteCount
        let canvas = makeCanvas(state)
        canvas.mouseMoved(
            with: mouseEvent(.mouseMoved, in: canvas, atTopLeft: CGPoint(x: 200, y: 150)))
        require(canvas.eraserCursorRing.isRingVisible,
                "the reach ring is on screen before the erasing drag")
        drag(canvas, from: content(state, page: 0, CGPoint(x: 90, y: 205)),
             through: [content(state, page: 0, CGPoint(x: 160, y: 205)),
                       content(state, page: 0, CGPoint(x: 240, y: 205))],
             to: content(state, page: 0, CGPoint(x: 310, y: 205)))
        require(!state.annotations.contains(where: { $0.id == strokeA.id }),
                "the drag removed stroke A")
        require(canvas.eraserCursorRing.isRingVisible,
                "the ring returns after the drag: the gesture is unchanged by the overlay")
        require(state.annotations.contains(where: { $0.id == strokeB.id }),
                "the parallel stroke B, 40 pt away, is untouched")
        require(state.undoStack.count == undoBeforeFirstErase + 1,
                "the whole gesture is one undo step")
        require(state.annotationWriteCount == writesBeforeFirstErase + 1,
                "the gesture wrote the annotation cache once, on release")

        // ── 5. The pending banner says the PDF on disk is unchanged ──────────────────────
        require(state.hasPendingInkErasure, "the erased stroke is pending a PDF write")
        require(state.eraserPendingSummary?.contains("the PDF on disk is unchanged") == true,
                "the pending banner's summary says the PDF on disk is unchanged")
        let pdfAfterFirstErase = try Data(contentsOf: document)
        require(pdfAfterFirstErase == originalPDFBytes,
                "erasing changed the reader's state, not the PDF on disk")
        let recordsAfterFirstErase = try Data(contentsOf: records(for: document))
        require(recordsAfterFirstErase != recordsBeforeFirstErase,
                "the cache is the pending store and did change")
        let pendingRecords = String(decoding: try Data(contentsOf: records(for: document)),
                                    as: UTF8.self)
        require(!pendingRecords.contains(strokeA.id.uuidString),
                "the erased stroke is gone from the annotation cache")
        require(pendingRecords.contains(strokeB.id.uuidString),
                "the untouched stroke is still in the annotation cache")

        // ── 6. A drag across two strokes removes both as one undo step ───────────────────
        require(state.addInkAnnotation(page: 0,
                                       points: [CGPoint(x: 100, y: 340), CGPoint(x: 300, y: 340)],
                                       color: red, strokeWidth: 2),
                "stroke C is created for the two-stroke sweep")
        guard let strokeC = state.annotations.last else {
            require(false, "stroke C is in the model")
            return
        }
        let orderBeforeSweep = ids(state)
        let undoBeforeSweep = state.undoStack.count
        require(state.annotationTool == .eraser, "the eraser is still armed after the first drag")
        state.updateEraserHover(atContentPoint: nil)
        drag(canvas, from: content(state, page: 0, CGPoint(x: 90, y: 240)),
             through: [content(state, page: 0, CGPoint(x: 310, y: 240)),
                       content(state, page: 0, CGPoint(x: 310, y: 340))],
             to: content(state, page: 0, CGPoint(x: 90, y: 340)))
        require(!state.annotations.contains(where: { $0.id == strokeB.id }),
                "the sweep crossed and removed stroke B")
        require(!state.annotations.contains(where: { $0.id == strokeC.id }),
                "the same sweep crossed and removed stroke C")
        require(state.undoStack.count == undoBeforeSweep + 1,
                "two strokes erased by one drag are ONE undo step, not two")

        state.undo()
        require(state.annotations.contains(where: { $0.id == strokeB.id })
                    && state.annotations.contains(where: { $0.id == strokeC.id }),
                "one undo restores both erased strokes")
        require(ids(state) == orderBeforeSweep,
                "undo restores the strokes at their original positions in drawing order")
        require(state.annotationWriteCount == writesBeforeFirstErase + 4,
                "undo wrote the restored annotation cache once (erase A, add C, erase sweep, undo sweep)")
        state.redo()
        require(!state.annotations.contains(where: { $0.id == strokeB.id })
                    && !state.annotations.contains(where: { $0.id == strokeC.id }),
                "one redo removes both again")
        state.undo() // leave them on the page for the saved-copy check
        require(state.annotations.contains(where: { $0.id == strokeB.id })
                    && state.annotations.contains(where: { $0.id == strokeC.id }),
                "the two strokes are back for the remaining checks")

        // ── 7. A drag that hits nothing changes nothing ─────────────────────────────────
        let idsBeforeNoOp = ids(state)
        let writesBeforeNoOp = state.annotationWriteCount
        let undoBeforeNoOp = state.undoStack.count
        let recordsBeforeNoOp = try Data(contentsOf: records(for: document))
        drag(canvas, from: content(state, page: 0, CGPoint(x: 500, y: 600)),
             through: [content(state, page: 0, CGPoint(x: 540, y: 620))],
             to: content(state, page: 0, CGPoint(x: 580, y: 640)))
        require(ids(state) == idsBeforeNoOp, "a drag over empty page erases nothing")
        require(state.annotationWriteCount == writesBeforeNoOp,
                "a gesture that erased nothing does not write the annotation cache")
        require(state.undoStack.count == undoBeforeNoOp,
                "a gesture that erased nothing adds no undo step")
        let recordsAfterNoOp = try Data(contentsOf: records(for: document))
        require(recordsAfterNoOp == recordsBeforeNoOp,
                "a gesture that erased nothing leaves the cache byte-identical")

        // ── 8. A stroke outside the tolerance survives; one inside is erased ───────────
        require(state.addInkAnnotation(page: 0,
                                       points: [CGPoint(x: 100, y: 450), CGPoint(x: 300, y: 450)],
                                       color: red, strokeWidth: 2),
                "stroke D is created for the tolerance check")
        guard let strokeD = state.annotations.last else {
            require(false, "stroke D is in the model")
            return
        }
        drag(canvas, from: content(state, page: 0, CGPoint(x: 90, y: 470)),
             through: [content(state, page: 0, CGPoint(x: 200, y: 470))],
             to: content(state, page: 0, CGPoint(x: 310, y: 470)))
        require(state.annotations.contains(where: { $0.id == strokeD.id }),
                "a drag 20 pt from the stroke is outside the 9 pt reach and erases nothing")
        drag(canvas, from: content(state, page: 0, CGPoint(x: 90, y: 457)),
             through: [content(state, page: 0, CGPoint(x: 200, y: 457))],
             to: content(state, page: 0, CGPoint(x: 310, y: 457)))
        require(!state.annotations.contains(where: { $0.id == strokeD.id }),
                "a drag 7 pt from the stroke is inside the 9 pt reach and erases it")

        // ── 9. Only ink is erased: a highlight and a shape survive the same mode ────────
        // Create the non-ink marks with the tools that normally create them, then re-arm the
        // eraser: the mode change must not disturb them.
        state.selectTool()
        let text = try await state.engine.textPage(0)
        let textRects = text.selectionRects(in: 0...min(24, text.chars.count - 1))
        guard let textRect = textRects.first else {
            require(false, "the fixture has text to highlight")
            return
        }
        let textPoint = content(state, page: 0,
                                CGPoint(x: textRect.midX, y: textRect.midY))
        // The text layer is fetched asynchronously on open; a press only resolves a character
        // once it has arrived, so wait for one instead of sleeping.
        try await eventually("the text layer is ready for the highlight selection", {
            state.beginSelection(at: textPoint)
            return state.selection != nil
        })
        require(state.selection != nil, "a text selection exists for the highlight")
        require(state.addAnnotationFromSelection(kind: .highlight, color: red),
                "a highlight is created for the eraser-mode check")
        state.clearSelection()
        require(state.addShapeAnnotation(kind: .square, page: 0,
                                         start: CGPoint(x: 380, y: 300),
                                         end: CGPoint(x: 480, y: 380),
                                         color: red, strokeWidth: 2),
                "a square is created for the eraser-mode check")
        state.toggleEraserTool()
        require(state.annotationTool == .eraser,
                "the eraser can be re-armed after other tools were used")
        guard let highlightID = state.annotations.first(where: { $0.kind == .highlight })?.id,
              let squareID = state.annotations.first(where: { $0.kind == .square })?.id else {
            require(false, "the highlight and square are in the model")
            return
        }
        require(state.addInkAnnotation(page: 0,
                                       points: [CGPoint(x: 380, y: 500), CGPoint(x: 520, y: 500)],
                                       color: red, strokeWidth: 2),
                "a stroke is created next to the non-ink marks")
        guard let inkNearMarks = state.annotations.last else {
            require(false, "the non-ink check's stroke is in the model")
            return
        }
        drag(canvas, from: content(state, page: 0, CGPoint(x: 370, y: 500)),
             through: [content(state, page: 0, CGPoint(x: 450, y: 500))],
             to: content(state, page: 0, CGPoint(x: 530, y: 500)))
        require(!state.annotations.contains(where: { $0.id == inkNearMarks.id }),
                "the eraser removed the stroke")
        require(state.annotations.contains(where: { $0.id == highlightID }),
                "the highlight is not an ink stroke and survives the eraser")
        require(state.annotations.contains(where: { $0.id == squareID }),
                "the square is not an ink stroke and survives the eraser")

        // ── 10. A saved copy has no annotation for the erased stroke ───────────────────
        // The copy is written from the reader's current list: the erased stroke is absent, so
        // its /Ink (and /NM) never reach the file. Reopening the copy proves it from the PDF
        // side; the raw bytes prove the erased identity is nowhere in the file.
        let copyURL = scratch.appendingPathComponent("erased-copy.pdf")
        let savedCopy = await state.saveAnnotatedCopy(to: copyURL)
        require(savedCopy, "a copy is saved after erasing")
        require(!state.hasPendingInkErasure,
                "saving the copy clears the pending-erasure banner")
        let pdfAfterSave = try Data(contentsOf: document)
        require(pdfAfterSave == originalPDFBytes,
                "saving a copy still leaves the original PDF untouched")
        let copyBytes = try Data(contentsOf: copyURL)
        require(copyBytes.range(of: Data(strokeA.id.uuidString.utf8)) == nil,
                "the saved copy contains no /NM for the erased stroke")
        require(copyBytes.range(of: Data(strokeB.id.uuidString.utf8)) != nil,
                "the saved copy keeps the stroke that was not erased")
        require(copyBytes.range(of: Data("/InkList".utf8)) != nil,
                "the saved copy still carries the kept ink")
        let reopened = try makeState(copyURL)
        try await eventually("the saved copy's annotations are read from the PDF", {
            let loaded = reopened.documentAnnotations.filter { $0.kind == "ink" }
            return loaded.count >= 2 || reopened.documentAnnotationsError != nil
        })
        require(reopened.documentAnnotationsError == nil,
                "the saved copy's annotations read without error")
        let reopenedInkIDs = Set(reopened.documentAnnotations
            .filter { $0.kind == "ink" }
            .map(\.id))
        require(!reopenedInkIDs.contains("nm:\(strokeA.id.uuidString)"),
                "reopening the copy finds no annotation for the erased stroke")
        require(reopenedInkIDs.contains("nm:\(strokeB.id.uuidString)"),
                "reopening the copy finds the kept stroke's annotation")

        // ── 11. A file-owned stroke with review text is refused, not deleted ───────────
        // The fixture's ink carries `/Contents`, so splitting or deleting its annotation would
        // delete somebody's comment. The new partial-erase guard must leave it whole and say so.
        // (`PartialEraseChecks` covers the bare file-owned stroke that may still be cut.)
        let external = try makeState(try copy(strokes, "external-ink.pdf"))
        try await eventually("the external ink fixture is read", {
            external.documentAnnotations.count == 5 || external.documentAnnotationsError != nil
        })
        require(external.documentAnnotationsError == nil,
                "the external ink fixture reads without error")
        guard let externalInk = external.documentAnnotations.first(where: { $0.kind == "ink" }),
              let externalPath = externalInk.inkPaths.first, externalPath.count >= 2 else {
            require(false, "the external fixture carries an ink stroke")
            return
        }
        external.toggleEraserTool()
        let externalPoint = CGPoint(x: (externalPath[0].x + externalPath[1].x) / 2,
                                    y: (externalPath[0].y + externalPath[1].y) / 2)
        let externalContent = content(external, page: externalInk.page, externalPoint)
        require(external.eraserTarget(atContentPoint: externalContent) == nil,
                "the eraser does not promise a cut on a stroke whose comment would be lost")
        external.updateEraserHover(atContentPoint: externalContent)
        require(external.eraserHoverMarkID == nil,
                "a protected file-owned stroke gets no erase halo")
        let externalCanvas = makeCanvas(external)
        let externalUndo = external.undoStack.count
        let externalWrites = external.annotationWriteCount
        let externalPDF = try Data(contentsOf: external.document!.url!)
        let externalStrokeContent = externalPath.map {
            content(external, page: externalInk.page, $0)
        }
        drag(externalCanvas, from: externalStrokeContent[0],
             through: Array(externalStrokeContent.dropFirst().dropLast()),
             to: externalStrokeContent[externalStrokeContent.count - 1])
        require(external.documentAnnotations.contains(where: { $0.id == externalInk.id }),
                "the commented file-owned stroke is left intact")
        require(external.pendingFileDeletions.isEmpty,
                "a refused file-owned stroke stages no deletion")
        require(external.annotations.isEmpty,
                "a refused file-owned stroke writes no reader ink")
        require(external.undoStack.count == externalUndo,
                "a refused file-owned stroke adds no undo step")
        require(external.annotationWriteCount == externalWrites,
                "a refused file-owned stroke writes nothing to the annotation cache")
        let externalRefusal = external.eraserRefusalNotice ?? ""
        require(externalRefusal.contains("belongs to the PDF")
                    && externalRefusal.contains("comment"),
                "the refusal says the stroke belongs to the PDF and carries a comment")
        let externalSourceAfter = try Data(contentsOf: external.document!.url!)
        require(externalSourceAfter == externalPDF,
                "the refused gesture leaves the PDF on disk byte-identical")

        // ── 12. Erasing did not disturb the geometry the select tool relies on ─────────
        // (The full suite's selection, click and form checks run on a state that never armed
        // the eraser; this pins the one interaction the mode could plausibly break: a click on
        // a kept stroke still selects it after an erase gesture.)
        state.selectTool()
        guard let keptInk = state.annotations.first(where: { $0.kind == .ink }) else {
            require(false, "a kept ink stroke remains for the selection check")
            return
        }
        let keptBounds = keptInk.geometryBounds ?? .zero
        let keptContent = content(state, page: keptInk.page,
                                  CGPoint(x: keptBounds.midX, y: keptBounds.midY))
        if let hit = state.geometryAnnotationHit(atContentPoint: keptContent) {
            require(hit.id == keptInk.id,
                    "after erasing, clicking a kept stroke still selects it")
        } else {
            require(false, "a kept stroke is still selectable after erasing")
        }

        // ── 13. Erasing the last annotation still produces a saveable copy ────────────────
        // The pending banner's "Save Copy…" must not become a disabled promise when the last
        // stroke was the last annotation: the copy is the source bytes, without any /Ink.
        let loneDocument = try copy(drawing, "lone-stroke.pdf")
        let lone = try makeState(loneDocument)
        require(lone.addInkAnnotation(page: 0,
                                      points: [CGPoint(x: 120, y: 220), CGPoint(x: 260, y: 220)],
                                      color: red, strokeWidth: 2),
                "the lone stroke is created")
        lone.toggleEraserTool()
        let loneCanvas = makeCanvas(lone)
        drag(loneCanvas, from: content(lone, page: 0, CGPoint(x: 110, y: 220)),
             through: [content(lone, page: 0, CGPoint(x: 190, y: 220))],
             to: content(lone, page: 0, CGPoint(x: 270, y: 220)))
        require(lone.annotations.isEmpty, "the lone stroke was the last annotation")
        require(lone.hasPendingInkErasure, "the erasure is pending even with no annotations left")
        require(lone.canSaveAnnotationsToPDF,
                "the pending banner's Save Copy is enabled after the last stroke is erased")
        require(!lone.canReplaceOriginalWithAnnotations,
                "replacing the original is not offered when there is nothing to append")
        let loneCopyURL = scratch.appendingPathComponent("lone-stroke-copy.pdf")
        let savedLone = await lone.saveAnnotatedCopy(to: loneCopyURL)
        require(savedLone, "a copy can be saved with no annotations left")
        require(!lone.hasPendingInkErasure, "the successful copy clears the pending-erasure state")
        let loneBytes = try Data(contentsOf: loneDocument)
        let loneCopyBytes = try Data(contentsOf: loneCopyURL)
        require(loneCopyBytes == loneBytes,
                "with nothing to append, the copy is the original PDF byte for byte (no /Ink)")
        require(lone.lastAnnotationWriteReport?.writtenIDs.isEmpty == true,
                "the report says nothing was appended")
        require(lone.lastAnnotationWriteReport?.sourceBytesPreserved == true,
                "the report says the source bytes were preserved")

        print("Eraser checks passed")
    }
}

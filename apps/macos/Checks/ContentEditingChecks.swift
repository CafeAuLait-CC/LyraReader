import AppKit
import Combine
import Foundation
import PDFKit
import SwiftUI

@testable import LyraReaderKit

extension ReaderChecks {
  @MainActor static func contentEditingChecks(root: URL) async throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "lyra-content-native-\(UUID())")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let source = scratch.appendingPathComponent("source.pdf")
    try FileManager.default.copyItem(
      at: root.appendingPathComponent("tests/fixtures/text-page.pdf"), to: source)
    let original = try Data(contentsOf: source)
    let state = AppState(engine: try RustEngine())
    state.setViewportSize(CGSize(width: 1000, height: 800))
    state.newTab(url: source)
    try await eventually("content fixture opens and lays out") {
      state.document?.url == source && !state.canvasPageFrames.isEmpty
    }
    try await eventually("the content fixture has visible page pixels") {
      state.canvasPages.contains { $0.placement.index >= 0 || PlacementIndex.pageRasterPage($0.placement.index) != nil }
    }
    var blankRevisionFrames = 0
    let continuity = state.$canvasPages.sink { pages in
      if !pages.contains(where: { $0.placement.index >= 0 || PlacementIndex.pageRasterPage($0.placement.index) != nil }) {
        blankRevisionFrames += 1
      }
    }
    defer { continuity.cancel() }
    state.toggleContentEditing()
    await state.reloadContentObjects()
    guard let first = state.contentEditPage?.items.first(where: { $0.can_edit_text }) else {
      fatalError("No editable fixture text")
    }
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.borderless],
      backing: .buffered, defer: false)
    let view = ContentEditorView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    view.state = state
    window.contentView = view
    defer {
      window.contentView = nil
      window.orderOut(nil)
    }
    func point(_ item: PDFContentItem) -> CGPoint {
      let placement = state.canvasPageFrames.first { $0.index == 0 }!
      let z = state.zoomFactor
      let offset = max(0, (view.bounds.width - state.contentWidthPt * z) / 2)
      return CGPoint(
        x: offset + (placement.leftPt + item.bounds.x + item.bounds.width / 2) * z,
        y: (placement.topPt + item.bounds.y + item.bounds.height / 2 - state.scrollYPt) * z)
    }
    func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    let p = point(first)
    state.selectContentTool("select")
    view.mouseMoved(with: event(.mouseMoved, p))
    require(view.hoveredContentID == first.id, "Edit hover identifies the complete text block")
    for tool in ["text", "image", "link", "erase", "blackout"] {
      state.selectContentTool(tool)
      view.mouseMoved(with: event(.mouseMoved, p))
      require(view.hoveredContentID == nil, "the \(tool) tool suppresses the implicit edit hover frame")
    }
    state.selectContentTool("text")
    view.mouseDown(with: event(.leftMouseDown, p))
    view.mouseUp(with: event(.leftMouseUp, p))
    require(
      state.contentEditSelection == first.id,
      "Text tool selects existing text instead of inserting a new block")
    require(
      contentTextViews(view).isEmpty,
      "selection and caret editing are distinct states")
    state.selectContentTool("select")
    require(state.contentEditSelection == nil, "switching tools clears the previous object selection")
    state.contentEditSelection = first.id
    let moved = CGPoint(x: p.x + 20 * state.zoomFactor, y: p.y + 12 * state.zoomFactor)
    view.mouseDown(with: event(.leftMouseDown, p))
    view.mouseDragged(with: event(.leftMouseDragged, moved))
    try await eventually("PDF text pixels follow the held pointer before mouse-up") {
      state.canvasPages.contains { $0.placement.index == PlacementIndex.contentDragForeground }
    }
    let live = state.canvasPages.first { $0.placement.index == PlacementIndex.contentDragForeground }!
    let stationary = state.canvasPages.first { $0.placement.index == PlacementIndex.contentDragBackground }!
    require(abs(live.placement.leftPt - stationary.placement.leftPt - 20) < 0.5
              && abs(live.placement.topPt - stationary.placement.topPt) > 6,
            "live text pixels follow the drag in both directions, including alignment snapping")
    require(live.image.bgra.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 },
            "the moving preview contains visible glyph pixels")
    require(state.pageEditPendingOperations.isEmpty, "pointer samples do not stage PDF revisions")
    view.mouseUp(with: event(.leftMouseUp, moved))
    try await eventually("drag stages and reopens a content revision") {
      state.pageEditPendingOperations.count == 1 && !state.contentEditLoading && !state.pageEditBusy
    }
    require(blankRevisionFrames == 0, "moving page content never publishes a blank PDF frame")
    try await eventually("the committed page replaces its temporary drag textures") {
      !state.canvasPages.contains { $0.placement.index == PlacementIndex.contentDragForeground }
    }
    guard let block = state.contentEditPage?.items.first(where: { $0.text == first.text }) else {
      fatalError("Moved text missing: \(state.lastError ?? "")")
    }
    require(
      abs(block.bounds.x - first.bounds.x - 20) < 0.5, "drag uses page points at the current zoom")
    require(abs(block.bounds.x - first.bounds.x - live.placement.leftPt + stationary.placement.leftPt) < 0.5
              && abs(block.bounds.y - first.bounds.y - live.placement.topPt + stationary.placement.topPt) < 0.5,
            "mouse-up preserves the preview's exact snapped text position")
    let q = point(block)
    view.mouseDown(with: event(.leftMouseDown, q))
    view.mouseUp(with: event(.leftMouseUp, q))
    view.mouseDown(with: event(.leftMouseDown, q))
    view.mouseUp(with: event(.leftMouseUp, q))
    guard let editor = contentTextViews(view).first else {
      fatalError("Second click must open a native caret editor")
    }
    require(
      editor.selectedRange().length == 0,
      "second click places a caret instead of selecting all text")
    editor.string = "Edited"
    view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 5, y: 5)))
    try await eventually("typing changes actual page content in a new revision") {
      state.pageEditPendingOperations.count == 2 && !state.contentEditLoading && !state.pageEditBusy
    }
    require(
      state.contentEditPage?.items.contains(where: { $0.text == "Edited" }) == true,
      "modified words survive reopening")
    state.undo()
    try await eventually("content undo restores the moved text revision") {
      state.pageEditPendingOperations.count == 1 && !state.pageEditBusy
    }
    await state.reloadContentObjects()
    require(
      state.contentEditPage?.items.contains(where: { $0.text == first.text }) == true,
      "undo restores original words")
    state.redo()
    try await eventually("content redo restores the edited revision") {
      state.pageEditPendingOperations.count == 2 && !state.pageEditBusy
    }
    await state.reloadContentObjects()
    require(blankRevisionFrames == 0, "content editing, undo and redo retain continuous page pixels")
    guard let edited = state.contentEditPage?.items.first(where: { $0.text == "Edited" }) else {
      fatalError("Edited block missing")
    }
    let r = point(edited)
    view.mouseDown(with: event(.leftMouseDown, r))
    view.mouseUp(with: event(.leftMouseUp, r))
    view.mouseDown(with: event(.leftMouseDown, r))
    view.mouseUp(with: event(.leftMouseUp, r))
    guard let draft = contentTextViews(view).first else {
      fatalError("Draft editor missing")
    }
    draft.string = "Saved draft"
    let saved = scratch.appendingPathComponent("published.pdf")
    let published = await state.savePageEditsCopy(to: saved)
    require(
      published,
      "content working revision publishes through the verified page-edit save: \(state.lastError ?? "")"
    )
    require(
      PDFDocument(url: saved)?.string?.contains("Saved draft") == true,
      "Save commits an active caret draft before PDFKit reopens the modified body text")
    let preserved = try Data(contentsOf: source)
    require(preserved == original, "content editing and copy export preserve the source bytes")
    state.contentEditEnabled = true
    await state.reloadContentObjects()
    // A failed write keeps both the previous PDF revision and the user's draft.
    guard let savedBlock = state.contentEditPage?.items.first(where: { $0.text == "Saved draft" })
    else { fatalError("Saved frame missing") }
    let revision = state.contentEditPage?.revision
    let operationCount = state.pageEditPendingOperations.count
    state.replaceContentText(savedBlock, text: String(repeating: "Overflow ", count: 500))
    try await eventually("overflow preserves a recoverable draft") {
      state.contentTextRecovery != nil && !state.contentCommandInFlight
    }
    require(
      state.contentEditPage?.revision == revision
        && state.pageEditPendingOperations.count == operationCount,
      "failed text write keeps the previous revision")
    let tabCount = state.tabs.count
    state.newTab(url: source)
    require(
      state.tabs.count == tabCount, "a failed draft prevents a tab switch that could lose its text")
    state.contentTextRecovery = "Retry"
    state.retryContentText(font: "Helvetica")
    try await eventually("recovered draft retries with a supported font") {
      state.contentTextRecovery == nil
        && state.pageEditPendingOperations.count == operationCount + 1
        && !state.contentCommandInFlight
    }
    require(
      state.contentEditPage?.items.contains(where: { $0.text == "Retry" }) == true,
      "retry publishes the recovered words")

    // Exercise the same native drag that creates a link rectangle in the product.
    state.contentEditTool = "link"
    let placement = state.canvasPageFrames.first { $0.index == 0 }!
    func localPoint(_ x: Double, _ y: Double) -> CGPoint {
      let z = state.zoomFactor
      let offset = max(0, (view.bounds.width - state.contentWidthPt * z) / 2)
      return CGPoint(
        x: offset + (placement.leftPt + x) * z, y: (placement.topPt + y - state.scrollYPt) * z)
    }
    let linkStart = localPoint(80, 230)
    let linkEnd = localPoint(200, 255)
    view.mouseDown(with: event(.leftMouseDown, linkStart))
    view.mouseDragged(with: event(.leftMouseDragged, linkEnd))
    view.mouseUp(with: event(.leftMouseUp, linkEnd))
    require(
      abs((state.contentLinkDraft?.width ?? 0) - 120) < 0.01,
      "Link drag creates a page-space rectangle")
    let beforeLink = state.pageEditPendingOperations.count
    state.setContentLink(nil, page: 0, uri: nil)
    try await eventually("new link survives FFI write and reopen") {
      state.contentEditPage?.items.contains(where: { $0.kind == "link" && $0.link_page == 0 })
        == true && !state.contentCommandInFlight
    }
    require(
      state.pageEditPendingOperations.count == beforeLink + 1,
      "link creation joins the document undo history")
    state.contentEditTool = "select"
    state.insertContentText(at: CGRect(x: 80, y: 300, width: 180, height: 50))
    try await eventually("Text tool inserts actual page text") {
      state.contentEditPage?.items.contains(where: { $0.text == "New text" }) == true
        && !state.contentCommandInFlight
    }
    guard let inserted = state.contentEditPage?.items.first(where: { $0.text == "New text" }) else {
      fatalError("Inserted text missing")
    }
    state.contentEditTool = "erase"
    let eraseStart = localPoint(inserted.bounds.x - 2, inserted.bounds.y - 2)
    let eraseEnd = localPoint(
      inserted.bounds.x + inserted.bounds.width + 2, inserted.bounds.y + inserted.bounds.height + 2)
    view.mouseDown(with: event(.leftMouseDown, eraseStart))
    view.mouseDragged(with: event(.leftMouseDragged, eraseEnd))
    view.mouseUp(with: event(.leftMouseUp, eraseEnd))
    try await eventually("Erase drag removes real text and rebuilds hit regions") {
      state.contentEditPage?.items.contains(where: { $0.text == "New text" }) == false
        && !state.contentCommandInFlight
    }
    let editedTab = state.activeTabIndex!
    state.closeTab(editedTab)
    require(
      state.contentCloseRequested && state.tabs.count == tabCount,
      "closing an edited tab offers Save, Discard, or Cancel")
    state.cancelContentClose()
    require(
      state.activeTabIndex == editedTab && !state.pageEditPendingOperations.isEmpty,
      "cancel close keeps all working edits")
    state.contentEditEnabled = false
    let signed = scratch.appendingPathComponent("signed.pdf")
    try FileManager.default.copyItem(
      at: root.appendingPathComponent("tests/fixtures/signed-signature.pdf"), to: signed)
    state.newTab(url: signed)
    require(
      state.isReadOnlyDocument && !state.canReplaceOriginalWithPageEdits,
      "signed original remains protected from content replacement")
    state.contentEditEnabled = true
    state.selectTab(editedTab)
    await state.reloadContentObjects()
    require(
      !state.pageEditPendingOperations.isEmpty
        && state.contentEditPage?.items.contains(where: { $0.text == "Retry" }) == true,
      "switching tabs restores the complete working revision")
    state.closeTab(editedTab)
    state.discardContentAndClose()
    require(
      !state.tabs.contains(where: { $0.url == saved }), "explicit Discard closes the edited tab")
    let discardedSource = try Data(contentsOf: source)
    require(discardedSource == original, "discard never modifies the source PDF")
    try await contentImageContinuityChecks(scratch: scratch)
    for factor in [38.0 / 72.0, 1.0, 108.5 / 72.0] {
      try await hostedContentEditingChecks(root: root, source: source, calibrationFactor: factor)
    }
    print("Content editing native checks passed")
  }
}

extension ReaderChecks {
  @MainActor private static func contentImageContinuityChecks(scratch: URL) async throws {
    let file = scratch.appendingPathComponent("image-continuity.pdf")
    var media = CGRect(x: 0, y: 0, width: 600, height: 800)
    let context = CGContext(file as CFURL, mediaBox: &media, nil)!
    let pixels = Data(Array(repeating: [UInt8(220), 50, 30, 255], count: 64).flatMap { $0 })
    let image = CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)!
    context.beginPDFPage(nil)
    context.draw(image, in: CGRect(x: 80, y: 480, width: 100, height: 60))
    context.endPDFPage()
    context.closePDF()
    let source = try Data(contentsOf: file)
    let state = AppState(engine: try RustEngine())
    state.setViewportSize(CGSize(width: 700, height: 400))
    state.newTab(url: file)
    state.scroll(toFraction: 0.25)
    state.toggleContentEditing()
    await state.reloadContentObjects()
    try await eventually("the image fixture has page pixels and editable image objects") {
      state.contentEditPage?.items.contains { $0.kind == "image" } == true
        && state.canvasPages.contains { $0.placement.index >= 0 || PlacementIndex.pageRasterPage($0.placement.index) != nil }
    }
    let scroll = state.scrollYPt
    var blankFrames = 0
    let continuity = state.$canvasPages.sink { pages in
      if !pages.contains(where: { $0.placement.index >= 0 || PlacementIndex.pageRasterPage($0.placement.index) != nil }) {
        blankFrames += 1
      }
    }
    defer { continuity.cancel() }
    for number in 1...4 {
      let oldGenerations = Set(state.canvasPages.map(\.image.generation))
      let item = state.contentEditPage!.items.first { $0.kind == "image" }!
      state.transformContent(item, to: item.bounds.rect.offsetBy(dx: 7, dy: 5))
      try await eventually("moving an image replaces its visible revision completely") {
        let pages = state.canvasPages.filter {
          $0.placement.index >= 0 || PlacementIndex.pageRasterPage($0.placement.index) != nil
        }
        return state.pageEditPendingOperations.count == number && !state.contentCommandInFlight
          && !pages.isEmpty && pages.allSatisfy { !oldGenerations.contains($0.image.generation) }
      }
      let moved = state.contentEditPage!.items.first { $0.kind == "image" }!
      require(abs(moved.bounds.x - item.bounds.x - 7) < 0.5
              && abs(moved.bounds.y - item.bounds.y - 5) < 0.5,
              "each image move reaches the PDF objects and the replacement canvas")
      require(abs(state.scrollYPt - scroll) < 0.01,
              "content revision replacement preserves the exact reading position")
    }
    require(blankFrames == 0, "repeated image moves never publish a blank PDF frame")
    let unchanged = try Data(contentsOf: file)
    require(unchanged == source, "image continuity retains the staged-save contract")
  }

  @MainActor static func hostedContentEditingChecks(
    root: URL, source: URL, calibrationFactor: CGFloat
  ) async throws {
    let state = AppState(engine: try RustEngine())
    state.sidebarVisible = false
    // This check tests pointer/caret behavior. Drawer animation has its own regression;
    // pin the open endpoint so the pointer target cannot move during this assertion.
    state.transitionProgressOverride = ReaderTransitionProgress(editingPanel: 1)
    let host = NSHostingView(
      rootView: ReaderWindow(state: state, opener: DocumentOpenCoordinator(state: state)))
    let window = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 1150, height: 800),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.title = "LyraReader Content Editing Check"
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    window.acceptsMouseMovedEvents = true
    defer {
      window.contentView = nil
      window.orderOut(nil)
    }
    state.newTab(url: source)
    state.contentEditEnabled = true
    await state.reloadContentObjects()
    func overlay(_ view: NSView) -> ContentEditorView? {
      if let view = view as? ContentEditorView { return view }
      return view.subviews.lazy.compactMap { overlay($0) }.first
    }
    try await eventually("ReaderWindow hosts the native content editing overlay") {
      host.layoutSubtreeIfNeeded()
      return overlay(host) != nil && state.contentEditPage != nil && !state.canvasPageFrames.isEmpty
    }
    let view = overlay(host)!
    state.setDisplayCalibration(DisplayCalibration(factor: calibrationFactor))
    try await eventuallyExplaining("the hosted editor applies its viewport at scale \(calibrationFactor)", {
      "model width \(state.canvasViewportWidthPt), view \(view.bounds), zoom \(state.zoomFactor)"
    }, {
      host.layoutSubtreeIfNeeded()
      guard let clip = view.enclosingScrollView?.contentView else { return false }
      let inspectorWidth = state.contentEditInspectorVisible
        ? ReaderEditingPanelTransition<ContentEditInspector>.width : 0
      let expected = host.bounds.width - ReaderChrome.scrollIndicatorLaneWidthPt - inspectorWidth
      // The viewport is reported asynchronously. At low DPI the paragraph is centered, so
      // calculating a click before that report produces a stale X coordinate on CI.
      return abs(clip.bounds.width - expected) < 0.5
        && abs(state.canvasViewportWidthPt - expected) < 0.5
        && abs(view.bounds.width - max(expected, state.contentWidthPt * state.zoomFactor)) < 0.5
        && !state.contentEditLoading
    })
    guard let item = state.contentEditPage?.items.first(where: { $0.can_edit_text }),
      let placement = state.canvasPageFrames.first(where: { $0.index == 0 })
    else { fatalError("Hosted paragraph missing") }
    let z = state.zoomFactor
    let offset = max(0, (view.bounds.width - state.contentWidthPt * z) / 2)
    let point = CGPoint(
      x: offset + (placement.leftPt + item.bounds.x + item.bounds.width / 2) * z,
      y: (placement.topPt + item.bounds.y + item.bounds.height / 2 - state.scrollYPt) * z)
    let hit = host.hitTest(host.convert(point, from: view))
    require(hit === view, "page text clicks reach the Edit overlay through SwiftUI hit testing")
    func event(_ type: NSEvent.EventType) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    view.mouseMoved(with: event(.mouseMoved))
    require(view.hoveredContentID == item.id, "hosted hover shows a whole paragraph")
    view.mouseDown(with: event(.leftMouseDown))
    view.mouseUp(with: event(.leftMouseUp))
    require(state.contentEditSelection == item.id, "hosted first click selects the paragraph")
    host.layoutSubtreeIfNeeded()
    if let directory = ProcessInfo.processInfo.environment["LYRA_CONTENT_EVIDENCE"] {
      // Wait for the secondary-row reveal and selection properties before capturing chrome.
      try await Task.sleep(for: .milliseconds(450))
      host.layoutSubtreeIfNeeded()
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent("native-editor-selected.png"))
      }
    }
    view.mouseDown(with: event(.leftMouseDown))
    view.mouseUp(with: event(.leftMouseUp))
    require(
      contentEditorFont("NimbusRomNo9L-Regu", size: 10).familyName?.contains("Times") == true,
      "embedded Times fonts use a matching caret family")
    require(
      contentTextViews(view).first?.enclosingScrollView?.hasVerticalScroller == true,
      "long native text drafts can scroll inside their frame")
    require(
      !contentTextViews(view).isEmpty,
      "hosted second click opens a native text caret")
    if ProcessInfo.processInfo.environment["LYRA_CONTENT_UI_PAUSE"] != nil {
      try await Task.sleep(for: .seconds(55))
    }
  }
}

@MainActor private func contentTextViews(_ view: NSView) -> [NSTextView] {
  if let view = view as? NSTextView { return [view] }
  return view.subviews.flatMap { contentTextViews($0) }
}

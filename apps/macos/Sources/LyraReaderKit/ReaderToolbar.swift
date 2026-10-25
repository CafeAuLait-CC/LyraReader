import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Full-width document tabs sit above all commands, independently of the sidebar.
///
/// The row uses one set of numbers, ``TabRowLayout``: the traffic lights (positioned by
/// ``ReaderTitlebarLayout``), the tab titles, their close affordances and the plus button all
/// share the 44 pt row's centre line. The tab's *whole* rectangle selects it; only the 24 pt
/// close affordance on the right closes it, and its 4 pt right-hand padding still selects.
public struct TabStrip: View {
    public static let height: CGFloat = TabRowLayout.height

    @ObservedObject public var state: AppState
    /// The process-wide drag: it resolves drops on another window's strip and outside every strip.
    @ObservedObject private var dragCoordinator = TabDragCoordinator.shared
    /// The drag in flight, if any. `nil` means no tab is being dragged.
    @State private var tabDrag: TabDragSession?

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        GeometryReader { geometry in
            // Reserve the add button and a small draggable gap before dividing the remaining
            // space equally. Filename length never participates in a tab's width.
            let count = CGFloat(max(1, state.tabs.count))
            let available = max(0, geometry.size.width - 20 - 24 - 6)
            let tabWidth = min(TabRowLayout.maximumTabWidth,
                               max(TabRowLayout.minimumTabWidth,
                                   (available - 32 - CGFloat(state.tabs.count) * 4) / count))
            let stripWidth = min(available, CGFloat(state.tabs.count) * (tabWidth + 4) + 32)
            // One indicator for three sources: the local drag while the pointer is over this
            // strip, the target-window indicator while another window's drag hovers here, and
            // nothing while that drag is over a third strip or off every strip.
            let hover = dragCoordinator.hover
            let indicatorX: CGFloat? = {
                if let hover, hover.state === state {
                    return TabReorder.indicatorX(
                        insertionIndex: hover.insertionIndex, tabWidth: tabWidth,
                        tabCount: state.tabs.count)
                }
                if hover != nil { return nil }
                if let tabDrag, tabDrag.isInsideStrip { return tabDrag.indicatorX }
                return nil
            }()
            HStack(spacing: 6) {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .center, spacing: TabRowLayout.tabSpacing) {
                            ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                                tabItem(tab, index: index, width: tabWidth)
                                    .id(tab.id)
                            }
                            Button { state.showFileImporter = true } label: { Image(systemName: "plus") }
                                .buttonStyle(LyraReaderToolStyle())
                                .frame(width: TabRowLayout.plusButtonSize,
                                       height: TabRowLayout.plusButtonSize, alignment: .center)
                                .help("Open a PDF in a new tab (⌘O)")
                                .accessibilityLabel("Open PDF").id("new-tab")
                        }
                        .frame(height: TabRowLayout.height)
                        // The drag location is reported in the row's own content coordinates, so
                        // scrolling the strip cannot move the insertion gap under the pointer.
                        .coordinateSpace(name: TabReorder.coordinateSpaceName)
                        .background {
                            TabDropZoneReporter(
                                state: state,
                                tabWidth: tabWidth,
                                tabCount: state.tabs.count
                            )
                        }
                        .overlay(alignment: .topLeading) {
                            if let indicatorX {
                                Capsule()
                                    .fill(LyraReaderTheme.accent)
                                    .frame(width: 3, height: TabRowLayout.contentHeight)
                                    .offset(x: max(0, indicatorX - 1.5),
                                            y: (TabRowLayout.height - TabRowLayout.contentHeight) / 2)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .onChange(of: state.activeTabIndex) { _, index in
                        guard let index, state.tabs.indices.contains(index) else { return }
                        if index == state.tabs.count - 1 { scroll.scrollTo("new-tab", anchor: .trailing) }
                        else { scroll.scrollTo(state.tabs[index].id) }
                    }
                }
                .frame(width: stripWidth)
                ReaderWindowDragArea().frame(minWidth: 24, maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
            .frame(height: TabRowLayout.height)
            .padding(.horizontal, TabRowLayout.tabStripHorizontalPadding)
        }
        .frame(height: Self.height)
        .background(LyraReaderTheme.tabbarBg)
        .overlay(alignment: .bottom) { LyraReaderTheme.separator.frame(height: 1) }
        // Escape may cancel the SwiftUI gesture without delivering `onEnded`; clear the local
        // preview so the insertion line cannot outlive the cancelled drag.
        .onChange(of: dragCoordinator.cancelGeneration) { _, _ in
            tabDrag = nil
        }
    }

    /// One tab. The selection surface covers the whole rectangle; the close button is drawn on
    /// top of its right-hand end and takes only its own 24 pt. A drag wins over the tap gesture
    /// at 3 pt, so a click still selects while a drag never half-switches. The drag reorders the
    /// tab on drop; the empty part of the row is still an AppKit window-drag area.
    private func tabItem(_ tab: AppState.OpenTab, index: Int, width: CGFloat) -> some View {
        let active = index == state.activeTabIndex
        return ZStack(alignment: .trailing) {
            HStack(spacing: 4) {
                Image(systemName: active && state.isReadOnlyDocument ? "lock.doc" : "doc.text")
                Text(tab.title)
                    .lineLimit(1).truncationMode(.tail)
                if active && state.isReadOnlyDocument {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LyraReaderTheme.warningFg)
                        .help(state.readOnlyReason ?? state.readOnlyBannerTitle)
                        .accessibilityLabel(state.isXfaDocument
                                            ? "XFA form, read-only"
                                            : "Signed PDF, read-only")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: active ? .medium : .regular))
            .padding(.leading, 12)
            .padding(.trailing, TabRowLayout.closeButtonWidth
                     + TabRowLayout.closeButtonTrailingInset + 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { state.selectTab(index) }
            .highPriorityGesture(tabDragGesture(index: index, width: width))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(active ? "Selected" : "")
            .accessibilityAction { state.selectTab(index) }

            Button { state.closeTab(index) } label: {
                Group {
                    if state.tabHasUnsavedChanges(index) {
                        // A little larger than lowercase title letters for a readable visual weight.
                        let diameter = NSFont.systemFont(ofSize: 12, weight: active ? .medium : .regular).xHeight * 1.15
                        Circle().fill(LyraReaderTheme.accent)
                            .frame(width: diameter, height: diameter)
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(active ? LyraReaderTheme.textPrimary : LyraReaderTheme.textSecondary)
                    }
                }
                .frame(width: TabRowLayout.closeButtonWidth, height: TabRowLayout.contentHeight, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, TabRowLayout.closeButtonTrailingInset)
            .help(state.tabHasUnsavedChanges(index) ? "Unsaved changes · Close \(tab.title)" : "Close \(tab.title)")
            .accessibilityLabel("Close \(tab.title)")
        }
        .frame(width: width, height: TabRowLayout.height)
        // The dragged tab follows the pointer above its neighbours. Its layout slot stays where
        // it was, so the other tabs do not move until the drop commits the new order.
        .offset(x: tabDrag?.sourceIndex == index ? tabDrag?.translation.width ?? 0 : 0)
        .zIndex(tabDrag?.sourceIndex == index ? 1 : 0)
        .foregroundStyle(active ? LyraReaderTheme.textPrimary : LyraReaderTheme.textSecondary)
        .background {
            if active {
                UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7)
                    .fill(LyraReaderTheme.raisedBg)
                    .padding(.top, (TabRowLayout.height - TabRowLayout.contentHeight) / 2)
            }
        }
        .overlay(alignment: .bottom) {
            if active { LyraReaderTheme.accent.frame(height: 2) }
        }
        .overlay(alignment: .trailing) {
            if !active {
                LyraReaderTheme.controlBorder.opacity(0.45)
                    .frame(width: 1, height: 22).padding(.trailing, -2)
            }
        }
        .help(tab.title)
    }

    /// The tab drag. `TabDragSession` owns the local arithmetic (which gap, whether the pointer is
    /// still on this strip); `TabDragCoordinator` owns the part that looks outside this window:
    /// another window's strip at the release point, or no strip at all (a tear-off).
    ///
    /// The local session is followed by a target-window indicator in the strip being hovered. A
    /// drop is committed only by the coordinator, so the visible indicator and the side effect
    /// use the same target: this strip reorders, another strip receives the tab, and no strip
    /// tears the tab off into a new window.
    private func tabDragGesture(index: Int, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(TabReorder.coordinateSpaceName))
            .onChanged { value in
                // A cancelled drag ignores the rest of its own movement: the gesture can keep
                // reporting locations after Escape until the button comes up.
                guard !dragCoordinator.isCancelled else { return }
                if tabDrag == nil { dragCoordinator.beginDrag() }
                // Continue this tab's session, or start a fresh one. A session left behind by an
                // interrupted gesture must not block the next drag on another tab.
                var session: TabDragSession
                if let current = tabDrag, current.sourceIndex == index {
                    session = current
                } else {
                    session = TabDragSession(
                        sourceIndex: index, tabCount: state.tabs.count, tabWidth: width)
                }
                session.update(location: value.location, translation: value.translation)
                tabDrag = session
                // Screen coordinates are what a drop in another window (or on the desktop) is
                // expressed in; the local `value.location` cannot see past this view.
                dragCoordinator.updateHover(screenPoint: NSEvent.mouseLocation, source: state)
            }
            .onEnded { value in
                guard var session = tabDrag, session.sourceIndex == index else {
                    tabDrag = nil
                    dragCoordinator.endDrag()
                    return
                }
                // Use the release location for the local arithmetic, but the screen point for
                // deciding where the drop actually lands: the pointer can leave the strip between
                // the last onChanged event and the release.
                session.update(location: value.location, translation: value.translation)
                let screenPoint = NSEvent.mouseLocation
                tabDrag = nil
                if dragCoordinator.isCancelled {
                    dragCoordinator.endDrag()
                    return
                }
                _ = dragCoordinator.finishDrag(
                    source: state,
                    sourceIndex: index,
                    localInsertionIndex: session.insertionIndex,
                    screenPoint: screenPoint
                )
            }
    }
}

/// Reader controls and tool categories. Unimplemented commands have reserved, disabled
/// positions; existing annotation commands still act on the current selection.
///
/// The contextual second row (annotation tools, page overview) is no longer part of this
/// `VStack`: it is drawn over the canvas by ``ReaderSecondaryToolbar`` so that opening it does not
/// move the document. The primary row keeps its position and height.
struct ReaderToolbar: View {
    @ObservedObject var state: AppState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            primaryRow(compact: false)
            primaryRow(compact: true)
        }
        .background(ReaderTypographySample(role: .main))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(LyraReaderTheme.toolbarBg)
        .overlay(alignment: .bottom) { LyraReaderTheme.separator.frame(height: 1) }
        .buttonStyle(LyraReaderToolStyle())
        .fixedSize(horizontal: false, vertical: true)
    }

    private func primaryRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 3 : 7) {
            tool("Toggle sidebar", "sidebar.left", selected: state.sidebarVisible) {
                if state.pageOverviewVisible {
                    state.pageOverviewVisible = false
                    state.sidebarVisible = true
                } else { state.sidebarVisible.toggle() }
            }
            tool("Page overview", "square.grid.2x2", selected: state.pageOverviewVisible) {
                state.pageOverviewVisible.toggle()
            }.disabled(state.document == nil)
            LyraReaderMenu(title: "View settings", items: ReaderLayoutMode.allCases.map { mode in
                LyraReaderMenuItem(mode.title, icon: mode == .facing ? "book" : "rectangle",
                             selected: state.layoutMode == mode) { state.setLayoutMode(mode) }
            }) { menuLabel("book") }.disabled(state.pageOverviewVisible)
            separator
            HStack(spacing: 0) {
                tool("Zoom out (⌘−)", "minus") { state.zoomOut() }
                LyraReaderMenu(title: "Zoom", items: [
                    LyraReaderMenuItem("Actual Size (100%)", icon: "1.magnifyingglass", shortcut: "⌘0") { state.zoomActual() },
                    LyraReaderMenuItem("Fit Width", icon: "arrow.left.and.right", shortcut: "⌘9") { state.zoomFitWidth() },
                    LyraReaderMenuItem("Fit Page", icon: "arrow.up.left.and.arrow.down.right", shortcut: "⇧⌘9") { state.zoomFitPage() },
                    LyraReaderMenuItem("Zoom In", icon: "plus.magnifyingglass", shortcut: "⌘+") { state.zoomIn() },
                    LyraReaderMenuItem("Zoom Out", icon: "minus.magnifyingglass", shortcut: "⌘−") { state.zoomOut() },
                ]) {
                    HStack(spacing: 4) {
                        Text("\(state.zoomPercent)%").monospacedDigit().fixedSize()
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }.font(.system(size: 12)).frame(minWidth: 60, minHeight: 32)
                }
                tool("Zoom in (⌘+)", "plus") { state.zoomIn() }
            }.disabled(state.pageOverviewVisible)
            separator
            Button { state.toggleAnnotationTools() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "highlighter")
                    if !compact {
                        Text("Annotate").modifier(ReaderToolbarFont(id: "toolbar.annotate.label", role: .main))
                            .background(AnnotationToolbarFrameReader(id: "toolbar.annotate.label"))
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }.padding(.horizontal, 6)
            }
            .buttonStyle(LyraReaderToolStyle(selected: state.annotationToolsVisible && !state.pageOverviewVisible))
            .help("Show annotation tools").accessibilityLabel("Annotation tools")
            .accessibilityValue(state.annotationToolsVisible ? "Expanded" : "Collapsed")
            .background(AnnotationToolbarFrameReader(id: "toolbar.annotate"))
            Button { state.toggleContentEditing() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "character.cursor.ibeam")
                    if !compact {
                        Text("Edit").modifier(ReaderToolbarFont(id: "toolbar.edit.label", role: .main))
                            .background(AnnotationToolbarFrameReader(id: "toolbar.edit.label"))
                    }
                }.padding(.horizontal, 6)
            }.buttonStyle(LyraReaderToolStyle(selected: state.contentEditEnabled))
                .disabled(!state.canPageEdit)
                .help("Show PDF editing tools").accessibilityLabel("Edit")
                .accessibilityValue(state.contentEditEnabled ? "Expanded" : "Collapsed")
                .background(AnnotationToolbarFrameReader(id: "toolbar.edit"))
            // Fill & Sign is one of the four secondary rows, not a menu. Its button stays
            // selected while the row is open; the row's seven tools are the placement commands
            // #153 carried in a menu. Its inspector holds the per-tool options.
            Button { state.toggleFillAndSign() } label: {
                HStack(spacing: 6) {
                    Image(systemName: AnnotationToolbarLayout.fillAndSignIcon)
                    if !compact {
                        Text("Fill & Sign").modifier(ReaderToolbarFont(id: "toolbar.fillSign.label", role: .main))
                            .background(AnnotationToolbarFrameReader(id: "toolbar.fillSign.label"))
                    }
                }.padding(.horizontal, 6)
            }
            .buttonStyle(LyraReaderToolStyle(selected: state.fillAndSignVisible))
            .disabled(!state.canOpenFillAndSign)
            .help(state.fillAndSignHelp)
            .accessibilityLabel(AnnotationToolbarLayout.fillAndSignLabel)
            .accessibilityValue(state.fillAndSignVisible ? "Expanded" : "Collapsed")
            .background(AnnotationToolbarFrameReader(id: "toolbar.fillSign"))
            // Export is a row too. The glyph is a document with a download arrow, never the
            // system Share symbol (`square.and.arrow.up`) the old menu used.
            Button { state.toggleExport() } label: {
                HStack(spacing: 6) {
                    Image(systemName: AnnotationToolbarLayout.exportIcon)
                    if !compact {
                        Text("Export").modifier(ReaderToolbarFont(id: "toolbar.export.label", role: .main))
                            .background(AnnotationToolbarFrameReader(id: "toolbar.export.label"))
                    }
                }.padding(.horizontal, 6)
            }
            .buttonStyle(LyraReaderToolStyle(selected: state.exportVisible))
            .disabled(state.document == nil)
            .help("Export and save: Save, Save As, annotated and flattened copies, form copies, "
                  + "annotation export and Print")
            .accessibilityLabel("Export")
            .accessibilityValue(state.exportVisible ? "Expanded" : "Collapsed")
            .background(AnnotationToolbarFrameReader(id: "toolbar.export"))
            separator
            // The Lyra button is a mode toggle, not a menu: it keeps the icon and text and has
            // no trailing chevron. A chevron here read as a third control and stretched the
            // button's label past its text.
            Button { state.toggleAITools() } label: {
                HStack(spacing: 6) {
                    LyraAIIcon().frame(width: 20, height: 20)
                        .background(AnnotationToolbarFrameReader(id: "toolbar.lyra.icon"))
                    if !compact {
                        Text("Lyra").modifier(ReaderToolbarFont(id: "toolbar.lyra.label", role: .main))
                            .background(AnnotationToolbarFrameReader(id: "toolbar.lyra.label"))
                    }
                }.padding(.horizontal, 6)
            }
            .buttonStyle(LyraReaderToolStyle(selected: state.aiToolsVisible))
            .help("Show Lyra tools (⇧⌘A)")
            .accessibilityLabel("Lyra tools")
            .accessibilityValue(state.aiToolsVisible ? "Expanded" : "Collapsed")
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .background(AnnotationToolbarFrameReader(id: "toolbar.lyra"))
            Spacer(minLength: 4)
            search(compact: compact)
        }
    }

    private func menuLabel(_ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }.padding(.horizontal, 4)
    }

    private func search(compact: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(LyraReaderTheme.iconSecondary)
            TextField("Search", text: $state.searchQuery)
                .textFieldStyle(.plain).font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .onSubmit { state.pageOverviewVisible = false; state.runSearch() }
            if !state.searchQuery.isEmpty {
                Button { state.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(LyraReaderTheme.iconSecondary)
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search").help("Clear search")
            }
        }
        .padding(.leading, 9).padding(.trailing, 5)
        .frame(width: compact ? 140 : 190, height: 32)
        .background(LyraReaderTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(LyraReaderTheme.controlBorder, lineWidth: 0.5))
    }

    private var separator: some View { LyraReaderTheme.separator.frame(width: 1, height: 22).padding(.horizontal, 4) }

    private func tool(_ title: String, _ icon: String, selected: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(LyraReaderToolStyle(selected: selected))
            .help(title).accessibilityLabel(title)
            .accessibilityValue(selected ? "Selected" : "")
    }

    private func pending(_ title: String, _ icon: String) -> some View {
        Button {} label: { Image(systemName: icon) }
            .disabled(true).help("\(title) · Coming soon").accessibilityLabel("\(title), coming soon")
    }
}

/// The one centered container every secondary sub-toolbar row is laid out in.
///
/// It owns the row's horizontal and vertical padding and its full slot height, and it puts the
/// controls in the scrollable, horizontally centered ``ReaderCenteredTools`` area. The reveal
/// belongs to ``ReaderSecondaryToolbarTransition``; this view only owns layout, and the hosted
/// probes measure this same view. A row must not bring another container, padding, frame,
/// background or animation of its own: that is what made the rows reveal differently.
struct ReaderSecondaryRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ReaderCenteredTools { content() }
            .background(ReaderTypographySample(role: .row))
            .padding(.horizontal, ReaderSecondaryRowMetrics.horizontalPadding)
            .padding(.vertical, ReaderSecondaryRowMetrics.verticalPadding)
            .frame(height: ReaderChrome.secondaryToolbarHeightPt)
    }
}

/// The contextual second row, drawn **over** the canvas instead of above it.
///
/// Annotate, Edit, Fill & Sign, Export and Lyra are five branches of this one view, inside the
/// same ``ReaderSecondaryRow`` container, so they share one layout, one padding, one height and
/// one reveal. Page overview is the sixth branch and wins over the others, exactly like the row
/// that used to sit in ``ReaderToolbar``'s `VStack`: because every state feeds the same view,
/// turning page overview on while another row is open swaps the content in place - it cannot
/// stack a second overlay or leave the row's height empty.
///
/// The row is always laid out at `ReaderChrome.secondaryToolbarHeightPt` with an opaque panel
/// background and a bottom separator, so it reads as a floating row over the page and catches
/// clicks for its whole rectangle.
struct ReaderSecondaryToolbar: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: AIAssistantModel

    var body: some View {
        ReaderSecondaryRow {
            // Every branch is inserted with an identity transition. The host's moving, clipped
            // height is the row's only reveal: without this, SwiftUI's default insertion
            // transition fades a branch in while the row slides, which is why Edit, Fill & Sign
            // and Export ghosted over the page while Annotate (the branch already on screen)
            // slid cleanly. The transition affects content insertion only; the 46 pt slot still
            // animates through the host.
            if state.pageOverviewVisible {
                overviewRow.transition(.identity)
            } else if state.contentEditEnabled {
                contentEditRow.transition(.identity)
            } else if state.fillAndSignVisible {
                fillSignRow.transition(.identity)
            } else if state.exportVisible {
                exportRow.transition(.identity)
            } else if state.aiToolsVisible {
                lyraRow.transition(.identity)
            } else {
                annotationRow.transition(.identity)
            }
        }
        .background(ReaderChromeMarkerHost(kind: .secondaryToolbar))
        .background(LyraReaderTheme.panelBg)
        .overlay(alignment: .bottom) { LyraReaderTheme.separator.frame(height: 1) }
        .buttonStyle(LyraReaderToolStyle())
    }

    /// Help for a tool that changes the document: a signed file says where the edit can go.
    private func writeHelp(_ normal: String) -> String {
        if state.isXfaDocument {
            return normal + " · not available: this XFA form is rendered read-only from its XML"
        }
        return state.isReadOnlyDocument ? normal + " · edits are saved to a copy" : normal
    }

    private var overviewRow: some View {
        HStack(spacing: ReaderSecondaryRowMetrics.itemSpacing) {
            Button { state.insertBlankPage(before: false) } label: {
                ReaderToolbarLabel(title: "Insert Page", id: "overview.insert") {
                    Image(systemName: "doc.badge.plus")
                }
            }.disabled(!state.canPageEdit)
            Button { state.rotateSelectedPages(clockwise: true) } label: {
                ReaderToolbarLabel(title: "Rotate", id: "overview.rotate") {
                    Image(systemName: "rotate.right")
                }
            }.disabled(!state.canPageEdit)
            Button { state.presentExtractPagesPanel() } label: {
                ReaderToolbarLabel(title: "Extract", id: "overview.extract") {
                    Image(systemName: "square.and.arrow.up")
                }
            }.disabled(!state.canPageOperations)
             .help(writeHelp("Write the selected pages to a new PDF"))
            Button { state.confirmDeleteSelectedPages() } label: {
                ReaderToolbarLabel(title: "Delete", id: "overview.delete") {
                    Image(systemName: "trash")
                }
            }.disabled(!state.canPageEdit || state.selectedPageIndices.count >= (state.document?.pageCount ?? 0))
            Text("\(state.selectedPageIndices.count) selected")
                .font(ReaderToolbarTypography.rowLabelFont)
                .foregroundStyle(LyraReaderTheme.textSecondary)
            Button { state.pageOverviewVisible = false } label: {
                ReaderToolbarLabel(title: "Done", id: "overview.done") {
                    Image(systemName: "checkmark")
                }
            }.accessibilityLabel("Close page overview")
        }
    }

    private var contentEditRow: some View {
        ContentEditToolRow(state: state)
    }

    private var fillSignRow: some View {
        FillSignToolRow(state: state)
    }

    private var exportRow: some View {
        ExportToolRow(state: state)
    }

    private var lyraRow: some View {
        LyraToolRow(state: state, model: model)
    }

    private var annotationRow: some View {
        AnnotationToolRow(state: state)
    }
}

/// An explicit empty tab-bar region owns window dragging and the titlebar double-click action;
/// tab/close/open buttons keep their own pointer handling, and document drags continue to select
/// text in the Metal canvas.
private struct ReaderWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ReaderTitlebarDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// AI actions share the reader's contextual row; the sidebar displays only the chosen workspace.
///
/// This is the row's content only. The centered container, padding, height, background and
/// reveal all come from ``ReaderSecondaryRow``/``ReaderSecondaryToolbar`` like the other four
/// rows; adding them here is what made Lyra slide over a row that was already open while the
/// other rows swapped in place.
struct LyraToolRow: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: AIAssistantModel
    var body: some View {
        HStack(spacing: ReaderSecondaryRowMetrics.itemSpacing) {
            Button { state.rightPanelVisible = false; state.toggleRegionSelection() } label: {
                ReaderToolbarLabel(title: "Interleaf", id: "lyra.interleaf") {
                    InterleafIcon()
                        .frame(width: ReaderToolbarTypography.iconSize,
                               height: ReaderToolbarTypography.iconSize)
                }
            }.buttonStyle(LyraReaderToolStyle(selected: state.regionSelectionArmed))
                .disabled(!state.canArmRegionSelection).help("Select & Ask").accessibilityLabel("Interleaf · Select & Ask")
                .background(AnnotationToolbarFrameReader(id: "lyra.interleaf"))
            // Interleaf is the one-off page action; the four workspace buttons are the row's
            // group. They are separated by the same group gap as the annotation row's groups;
            // the spacer's width discounts the HStack spacing on each side of it.
            Color.clear
                .frame(width: ReaderSecondaryRowMetrics.groupGapSpacerWidth, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            workspace("Summary", icon: "text.alignleft", tab: .summary)
            workspace("Translate", icon: "character.bubble", tab: .translation)
            workspace("Chat", icon: "bubble.left.and.bubble.right", tab: .chat)
            workspace("Reading notes", icon: "note.text", tab: .regions)
        }
    }
    private func workspace(_ title: String, icon: String, tab: AIAssistantTab) -> some View {
        Button {
            state.cancelRegionSelection()
            model.selectedTab = tab
            state.rightPanelVisible = true
        } label: {
            ReaderToolbarLabel(title: title, id: "lyra.\(tab.rawValue)") {
                if tab == .translation {
                    TranslationIcon()
                        .frame(width: ReaderToolbarTypography.iconSize,
                               height: ReaderToolbarTypography.iconSize)
                } else {
                    Image(systemName: icon)
                }
            }
        }
            .buttonStyle(LyraReaderToolStyle(selected: state.rightPanelVisible && model.selectedTab == tab))
            .disabled(state.document == nil).help(title)
            .background(AnnotationToolbarFrameReader(id: "lyra.\(tab.rawValue)"))
    }
}

/// The row's inside width, so a labelled row can choose its compact layout instead of relying
/// on the scroll view's unbounded horizontal proposal.
private struct ReaderRowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var readerRowWidth: CGFloat? {
        get { self[ReaderRowWidthKey.self] }
        set { self[ReaderRowWidthKey.self] = newValue }
    }
}

/// Centred at normal widths, horizontally scrollable when every tool cannot fit.
///
/// The scroll view proposes an unbounded width along its axis, so `ViewThatFits` rows would
/// always pick their label layout and then scroll. The viewport width is exposed to the content
/// as ``EnvironmentValues/readerRowWidth`` so the Fill & Sign and Export rows can constrain
/// their adaptive row to it and fall back to icons exactly when the labels do not fit.
struct ReaderCenteredTools<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    .environment(\.readerRowWidth, geometry.size.width)
            }
        }
    }
}

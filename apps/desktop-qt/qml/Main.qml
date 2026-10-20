import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import LyraReader 1.0
import "ReaderLogic.js" as Logic

ApplicationWindow {
    id: root
    objectName: "readerWindow"
    visible: true
    width: 1200
    height: 820
    minimumWidth: 640
    minimumHeight: 440
    title: currentReader.title === "LyraReader" ? "LyraReader" : currentReader.title + " — LyraReader"
    color: theme.windowBg
    // Palette specification defaults to light; the user can opt into dark or system.
    readonly property var session: typeof workspace !== "undefined" ? workspace : null
    readonly property var previewController: session ? session.preview : null
    property var navigationHistory: []
    readonly property bool canGoBack: navigationHistory.length > 0
    readonly property var currentReader: session ? session.activeReader : reader
    readonly property var signatureStatus: currentReader.data.signature_status || {}
    readonly property bool originalReadOnly: !!signatureStatus.signed
    readonly property string readOnlyReason: signatureStatus.read_only_reason || ""
    readonly property var colors: theme
    readonly property var pageList: canvas.view
    property string appearance: session ? session.preference("appearance", "light") : "light"
    property string sidebarTab: "thumbnails"
    property bool annotationToolsVisible: false
    property bool overviewVisible: false
    property bool textViewVisible: false
    readonly property real textViewZoom: accessibleTextView.textSize / 16
    onOverviewVisibleChanged: if (overviewVisible)
        textViewVisible = false
    function setTextViewEnabled(show) {
        const returningToPage = textViewVisible && !show;
        const page = currentPage;
        textViewVisible = show;
        if (show) {
            overviewVisible = false;
            annotationToolsVisible = false;
            formToolActive = false;
            selection = null;
        }
        if (returningToPage)
            Qt.callLater(function () {
                root.navigate(page);
            });
    }
    property bool formToolActive: false
    property string annotationTool: "select"
    property string layoutMode: "Continuous"
    property real pageGap: 12
    property var selection: null
    property string searchQuery: ""
    property var searchResults: []
    property int searchIndex: -1
    property bool searchVisible: false
    readonly property var activeSearchHit: searchIndex >= 0 && searchIndex < searchResults.length ? searchResults[searchIndex] : null
    readonly property var markState: currentReader.data.marks || {
        annotations: [],
        file_annotations: currentReader.data.annotations || [],
        bookmarks: []
    }
    readonly property var bookmarks: markState.bookmarks || []
    readonly property var annotations: (markState.annotations || []).map(function (a) {
        return Logic.normalized(a, false);
    }).concat((markState.file_annotations || []).map(function (a) {
        return Logic.normalized(a, true);
    }))
    readonly property var annotationThreads: Logic.annotationThreads(annotations)
    property var annotationDraft: null
    property var redactionDraft: null
    property var eraseDraft: []
    property double pendingDraftRequestId: -1
    property double searchRequestId: -1
    property string brushColor: "#E8BC55"
    property real brushOpacity: 0.32
    property real brushWidth: 2
    property string annotationFont: "LyraReader Sans SC"
    property var aiSettings: session ? session.preference("ai", {}) : ({})
    property var previousReader: null
    property var pendingPosition: null
    property alias searchDebounce: searchTimer
    property var selectedAnnotation: null
    property var infoData: ({})
    readonly property var formValues: currentReader.editDrafts.forms || ({})
    readonly property var pendingRedactions: currentReader.editDrafts.redactions || []
    readonly property bool canRedact: currentReader.pageCount > 0 && !pageEditsPending && currentReader.pendingCommands === 0
    property string exportKind: ""
    readonly property bool pageEditsPending: !!markState.page_pending
    property bool pageEditBusy: false
    property var selectedPages: [0]
    property int pendingPage: 0
    property var pendingPageSelection: []
    property string paperAppearance: session ? session.preference("paper", "original") : "original"
    readonly property string bibtex: currentReader.data.bibtex || (currentReader.data.metadata ? currentReader.data.metadata.bibtex : "")
    property var metadataDraft: null
    property string operationStatus: ""
    onAppearanceChanged: if (session)
        session.setPreference("appearance", appearance)
    onCurrentReaderChanged: {
        printRequested = false;
        navigationHistory = [];
        previousReader = currentReader;
        selectedAnnotation = null;
        annotationDraft = null;
        redactionDraft = null;
        pendingDraftRequestId = -1;
        selection = null;
        searchResults = [];
        searchIndex = -1;
        if (currentReader && currentReader.pageCount > 0) {
            Qt.callLater(restorePosition);
            if (formToolActive)
                currentReader.submit("forms");
        }
    }
    property bool closeApproved: false
    property int closingTab: -2
    function saveReadingPosition() {
        positionTimer.stop();
        if (session && currentReader.pageCount > 0) {
            const state = {
                page: currentPage,
                zoom: zoom,
                fitting: fitting,
                layout: layoutMode,
                gap: pageGap
            };
            if (!textViewVisible)
                state.offset = pageList.contentY;
            session.saveViewState(currentReader, state);
        }
    }
    function hasPendingCloseWork(index) {
        const tabs = session ? session.tabs : [
            {
                reader: currentReader
            }
        ];
        return tabs.some(function (tab, i) {
            return (index < 0 || i === index) && tab.reader.pendingCommands > 0;
        });
    }
    function hasUnsavedChanges(index) {
        const tabs = session ? session.tabs : [
            {
                reader: currentReader
            }
        ];
        return tabs.some(function (tab, i) {
            const marks = tab.reader.data.marks || {};
            return (index < 0 || i === index) && (marks.page_pending || marks.pending_deletions > 0 || Object.keys(tab.reader.noteDrafts).length > 0 || tab.reader.hasEditDrafts);
        });
    }
    function requestCloseTab(index) {
        if (!session)
            return;
        dialogs.flushAnnotation();
        closingTab = index;
        if (hasPendingCloseWork(index)) {
            closeRetry.start();
            return;
        }
        closingTab = -2;
        if (hasUnsavedChanges(index))
            dialogs.confirmClose(index);
        else
            session.closeTab(index);
    }
    function discardAndClose(index) {
        dialogs.cancelAnnotationDraft();
        saveReadingPosition();
        if (index < 0) {
            closeApproved = true;
            root.close();
        } else if (session)
            session.closeTab(index, true);
    }
    onClosing: function (event) {
        if (closeApproved)
            return;
        dialogs.flushAnnotation();
        saveReadingPosition();
        if (hasPendingCloseWork(-1)) {
            event.accepted = false;
            closingTab = -1;
            closeRetry.start();
            return;
        }
        if (hasUnsavedChanges(-1)) {
            event.accepted = false;
            dialogs.confirmClose(-1);
        }
    }
    Timer {
        id: closeRetry
        interval: 80
        onTriggered: {
            if (root.closingTab === -2)
                return;
            if (root.hasPendingCloseWork(root.closingTab)) {
                restart();
                return;
            }
            if (dialogs.annotationWriteError.length) {
                root.operationStatus = dialogs.annotationWriteError;
                root.closingTab = -2;
                return;
            }
            const index = root.closingTab;
            root.closingTab = -2;
            if (index < 0)
                root.close();
            else
                root.requestCloseTab(index);
        }
    }
    SystemPalette {
        id: systemPalette
    }
    LyraReaderTheme {
        id: theme
        objectName: "lyraReaderTheme"
        dark: root.appearance === "dark" || (root.appearance === "system" && systemPalette.window.hslLightness < 0.5)
    }
    palette.window: theme.windowBg
    palette.windowText: theme.textPrimary
    palette.base: theme.fieldBg
    palette.alternateBase: theme.panelBg
    palette.text: theme.textPrimary
    palette.button: theme.toolbarBg
    palette.buttonText: theme.textPrimary
    palette.highlight: theme.selectedBg
    palette.highlightedText: theme.selectedFg
    palette.accent: theme.accent
    palette.link: theme.accent
    palette.placeholderText: theme.textPlaceholder
    palette.mid: theme.controlBorder
    palette.dark: theme.border
    palette.light: theme.raisedBg
    palette.toolTipBase: theme.raisedBg
    palette.toolTipText: theme.textPrimary
    palette.disabled.text: theme.textDisabled
    palette.disabled.buttonText: theme.textDisabled
    palette.disabled.windowText: theme.textDisabled
    palette.inactive.highlight: theme.inactiveSelectionBg
    palette.inactive.highlightedText: theme.inactiveSelectionFg
    property real zoom: 1
    property bool fitting: true
    property bool sidebarVisible: true
    property int currentPage: 0

    function navigate(page, y) {
        if (currentReader.pageCount === 0)
            return;
        page = Math.max(0, Math.min(currentReader.pageCount - 1, page));
        if (!textViewVisible)
            canvas.navigate(page, y || 0);
        root.currentPage = page;
        if (textViewVisible)
            schedulePositionSave();
    }
    function changeZoom(value, anchorX, anchorY) {
        const old = root.zoom;
        const next = Math.max(0.1, Math.min(4, value));
        const oldLeft = (pageList.contentWidth - currentReader.documentWidth * old) / 2;
        const x = currentReader.zoomOffset(pageList.contentX, anchorX - oldLeft, old, next);
        const y = currentReader.zoomOffset(pageList.contentY, anchorY, old, next);
        root.zoom = next;
        Qt.callLater(function () {
            const newLeft = (pageList.contentWidth - currentReader.documentWidth * next) / 2;
            pageList.contentX = Math.max(0, Math.min(pageList.contentWidth - pageList.width, x + newLeft));
            pageList.contentY = Math.max(-pageList.topMargin, Math.min(Math.max(-pageList.topMargin, pageList.contentHeight - pageList.height + pageList.bottomMargin), y));
        });
    }
    function zoomBy(factor) {
        if (textViewVisible) {
            accessibleTextView.zoomBy(factor);
            return;
        }
        root.fitting = false;
        changeZoom(zoom * factor, pageList.width / 2, pageList.height / 2);
    }
    function fitWidth() {
        if (currentReader.pageCount > 0)
            changeZoom(currentReader.fitWidth(pageList.width), pageList.width / 2, 0);
        root.fitting = true;
    }
    function updateCurrentPage() {
        if (currentReader.pageCount > 0 && !textViewVisible)
            root.currentPage = canvas.pageAtOffset();
    }

    function openDialog() {
        fileDialog.open();
    }
    function showSidebar(tab) {
        sidebarTab = tab;
        sidebarVisible = true;
        overviewVisible = false;
    }
    function setPageLayout(mode) {
        layoutMode = mode;
        currentReader.setLayout(mode, pageGap);
    }
    function fitResize() {
        resizeTimer.restart();
    }
    function schedulePositionSave() {
        positionTimer.restart();
    }
    function restorePosition() {
        const state = session ? session.viewState(currentReader) : ({});
        pendingPosition = Object.assign({}, state);
        if (requestedPage >= 0) {
            pendingPosition.page = requestedPage;
            pendingPosition.y = requestedY;
            delete pendingPosition.offset;
            requestedPage = -1;
        }
        layoutMode = state.layout || "Continuous";
        pageGap = state.gap === undefined ? 12 : state.gap;
        currentReader.setLayout(layoutMode, pageGap);
    }
    function runSearch() {
        if (currentReader.pageCount > 0)
            searchRequestId = currentReader.submit("search", {
                pattern: searchQuery
            });
    }
    function stepSearch(delta) {
        if (!searchResults.length)
            return;
        searchIndex = (searchIndex + delta + searchResults.length) % searchResults.length;
        navigate(activeSearchHit.page);
    }
    function selectedText() {
        if (!selection)
            return "";
        const text = currentReader.textPages[selection.page.toString()];
        return text ? Logic.selectedText(text.chars, selection.start, selection.end) : "";
    }
    function copySelection() {
        if (session && selection)
            session.copyText(selectedText());
    }
    function selectionFinished() {
        if (["highlight", "underline", "strikeout"].indexOf(annotationTool) >= 0)
            markSelection(annotationTool);
    }
    function pageClicked(page, x, y, sceneX, sceneY) {
        currentPage = page;
        if (annotationTool === "stickyNote" || annotationTool === "textBox") {
            const size = currentReader.pages[page];
            const width = annotationTool === "stickyNote" ? 22 : Math.min(180, size.width);
            const height = annotationTool === "stickyNote" ? 22 : Math.min(60, size.height);
            currentReader.submit("mark_create", {
                entry: {
                    kind: annotationTool,
                    page: page,
                    version: 1,
                    rect: {
                        x: Math.max(0, Math.min(size.width - width, x)),
                        y: Math.max(0, Math.min(size.height - height, y)),
                        width: width,
                        height: height
                    },
                    fontSize: 14,
                    color: brushColor + "ff",
                    note: ""
                }
            });
        } else if (annotationTool === "select") {
            const hit = annotationAt(page, x, y, false);
            if (hit)
                selectAnnotation(hit, false);
            else {
                selectedAnnotation = null;
                if (previewController) {
                    selection = null;
                    previewController.openAt(currentReader, page, x, y, sceneX === undefined ? width / 2 : sceneX, sceneY === undefined ? height / 2 : sceneY, zoom);
                }
            }
        }
    }
    function jumpFromPreview(page, y) {
        const history = navigationHistory.slice();
        history.push({
            page: currentPage,
            offset: pageList.contentY,
            x: pageList.contentX,
            zoom: zoom,
            fitting: fitting,
            selection: selection
        });
        navigationHistory = history.slice(-64);
        selection = null;
        navigate(page, y);
    }
    function goBack() {
        if (!navigationHistory.length)
            return;
        const history = navigationHistory.slice(), location = history.pop();
        navigationHistory = history;
        fitting = false;
        zoom = location.zoom;
        selection = location.selection;
        Qt.callLater(function () {
            pageList.contentY = location.offset;
            pageList.contentX = location.x;
            fitting = location.fitting;
        });
    }
    Connections {
        target: root.previewController
        function onStatusMessage(message) {
            root.operationStatus = message;
        }
        function onNavigateRequested(page, y) {
            root.jumpFromPreview(page, y);
        }
    }
    function showMergeDialog() {
        pageExports.show(true);
    }
    function showSplitDialog() {
        pageExports.show(false);
    }
    PageExports {
        id: pageExports
        app: root
    }
    RedactionReview {
        id: redactionReview
        app: root
    }
    PreviewPanel {
        app: root
        controller: root.previewController
    }
    Shortcut {
        sequence: "Alt+Left"
        enabled: root.canGoBack
        onActivated: root.goBack()
    }
    function showSelectionMenu(item, page, x, y) {
        const point = item.mapToItem(Overlay.overlay, x, y);
        dialogs.selectionMenu.x = point.x;
        dialogs.selectionMenu.y = point.y;
        dialogs.selectionMenu.open();
    }
    function showExportMenu(item) {
        const point = item.mapToItem(Overlay.overlay, 0, item.height);
        dialogs.exportMenu.x = point.x;
        dialogs.exportMenu.y = point.y;
        dialogs.exportMenu.open();
    }
    function showSettings() {
        dialogs.settingsDialog.open();
    }
    function showDocumentInformation() {
        currentReader.submit("document_info");
        currentReader.submit("metadata");
        dialogs.informationDialog.open();
    }
    function showFormsDialog() {
        currentReader.submit("forms");
        dialogs.formsDialog.open();
    }
    function toggleForms() {
        setTextViewEnabled(false);
        formToolActive = !formToolActive;
        if (formToolActive)
            currentReader.submit("forms");
    }
    function selectAnnotation(annotation, edit) {
        dialogs.flushAnnotation();
        if (edit === false)
            dialogs.annotationDialog.close();
        const reason = Logic.annotationUnsupportedReason(annotation);
        if (reason.length) {
            selectedAnnotation = annotation;
            operationStatus = reason;
            dialogs.showAnnotation();
        } else if (annotation.foreign) {
            currentReader.submit("file_adopt", {
                id: annotation.id
            });
            selectedAnnotation = annotation;
        } else {
            selectedAnnotation = annotation;
            if (edit !== false)
                dialogs.showAnnotation();
        }
        if (edit !== false)
            navigate(annotation.page);
    }
    function addBookmark() {
        if (currentReader.pageCount > 0) {
            showSidebar("bookmarks");
            currentReader.submit("bookmark_create", {
                page: currentPage,
                title: qsTr("Page %1").arg(currentPage + 1),
                yPt: Math.max(0, pageList.contentY / zoom - currentReader.pages[currentPage].top)
            });
        }
    }
    function editBookmark(bookmark, index) {
        dialogs.openBookmark(bookmark, index);
    }
    function annotationAt(page, x, y, inkOnly) {
        const values = annotations.filter(function (a) {
            return a.page === page && (!inkOnly || a.kind === "ink");
        });
        for (let i = values.length - 1; i >= 0; --i)
            if (Logic.hit(values[i], x, y, inkOnly ? 10 : 4))
                return values[i];
        return null;
    }
    function setAnnotationTool(tool) {
        annotationTool = annotationTool === tool ? "select" : tool;
        if (["highlight", "underline", "strikeout"].indexOf(annotationTool) >= 0 && selection)
            markSelection(annotationTool);
    }
    function addRedaction(page, rect) {
        if (!canRedact)
            return;
        const size = currentReader.pages[page];
        if (!size)
            return;
        const left = Math.max(0, rect.x), top = Math.max(0, rect.y);
        const right = Math.min(size.width, rect.x + rect.width), bottom = Math.min(size.height, rect.y + rect.height);
        if (right - left < 1 || bottom - top < 1)
            return;
        const area = {
            page: page,
            x_pt: left,
            y_pt: top,
            width_pt: right - left,
            height_pt: bottom - top
        };
        if (pendingRedactions.some(function (a) {
            return JSON.stringify(a) === JSON.stringify(area);
        }))
            return;
        currentReader.setEditDraft("redactions", pendingRedactions.concat([area]));
        operationStatus = qsTr("%1 pending redaction areas; the file is unchanged.").arg(pendingRedactions.length);
    }
    function markSelectionForRedaction() {
        if (!selection || !canRedact)
            return;
        const text = currentReader.textPages[selection.page.toString()];
        if (!text)
            return;
        for (const rect of Logic.quads(text.chars, selection.start, selection.end))
            addRedaction(selection.page, rect);
        selection = null;
    }
    function reviewRedactions(replacing) {
        redactionReview.review(replacing);
    }
    function markSelection(kind) {
        if (!selection)
            return;
        currentReader.submit("mark_create", {
            entry: {
                kind: kind,
                page: selection.page,
                start: Math.min(selection.start, selection.end),
                end: Math.max(selection.start, selection.end),
                color: brushColor + Logic.hex(brushOpacity * 255),
                note: ""
            }
        });
        selection = null;
    }
    function updateSelectedAnnotation(patch) {
        if (selectedAnnotation && !selectedAnnotation.foreign)
            return currentReader.submit("mark_update", {
                id: selectedAnnotation.id,
                patch: patch
            });
        return -1;
    }
    function commitAnnotationGeometry(id, patch) {
        if (!annotationDraft || annotationDraft.id !== id)
            return;
        pendingDraftRequestId = currentReader.submit("mark_update", {
            id: id,
            patch: patch
        });
    }
    function updateAnnotationNote(note) {
        if (selectedAnnotation)
            currentReader.submit("mark_update", {
                id: selectedAnnotation.id,
                patch: {
                    note: note
                }
            });
    }
    function deleteSelectedAnnotation() {
        dialogs.cancelAnnotationDraft();
        if (selectedAnnotation)
            currentReader.clearNoteDraft(selectedAnnotation.id);
        if (!selectedAnnotation)
            return;
        currentReader.submit(selectedAnnotation.foreign ? "file_delete" : "mark_delete", {
            id: selectedAnnotation.id
        });
        selectedAnnotation = null;
    }
    function eraseAlong(page, start, end) {
        const ids = eraseDraft.slice();
        for (const a of annotations) {
            if (a.page !== page || a.kind !== "ink" || ids.indexOf(a.id) >= 0)
                continue;
            let hit = false;
            for (const path of a.paths || [])
                for (let i = 1; i < path.length; ++i)
                    if (Logic.segmentsNear(start, end, path[i - 1], path[i], 10 + (a.strokeWidth || 2) / 2)) {
                        hit = true;
                        break;
                    }
            if (hit)
                ids.push(a.id);
        }
        eraseDraft = ids;
    }
    function commitErase() {
        if (eraseDraft.length)
            currentReader.submit("marks_erase", {
                ids: eraseDraft.slice()
            });
    }
    function selectPage(index, modifiers) {
        if (modifiers & Qt.ShiftModifier) {
            const first = Math.min(currentPage, index), last = Math.max(currentPage, index);
            const pages = [];
            for (let p = first; p <= last; ++p)
                pages.push(p);
            selectedPages = pages;
        } else if (modifiers & Qt.ControlModifier) {
            const pages = selectedPages.slice();
            const at = pages.indexOf(index);
            if (at >= 0)
                pages.splice(at, 1);
            else
                pages.push(index);
            selectedPages = pages.sort(function (a, b) {
                return a - b;
            });
        } else
            selectedPages = [index];
        currentPage = index;
    }
    function pageOperation(operation) {
        if (pageEditBusy)
            return;
        pageEditBusy = true;
        pendingPage = currentPage;
        pendingPageSelection = selectedPages.slice();
        currentReader.submit("page_stage", {
            operation: operation
        });
    }
    function movePages(destination) {
        if (selectedPages.length)
            pageOperation({
                Move: {
                    pages: selectedPages,
                    destination: destination
                }
            });
    }
    function confirmPageDeletion() {
        dialogs.confirmPageDeletion();
    }
    function confirmDiscardPages() {
        dialogs.confirmDiscardPages();
    }
    function undo() {
        if (markState.can_undo)
            currentReader.submit("marks_undo");
        else if (markState.can_page_undo) {
            pendingPage = currentPage;
            currentReader.submit("page_undo");
        }
    }
    function redo() {
        if (markState.can_redo)
            currentReader.submit("marks_redo");
        else if (markState.can_page_redo) {
            pendingPage = currentPage;
            currentReader.submit("page_redo");
        }
    }
    property bool printRequested: false
    function printDocument() {
        if (dialogs.annotationWriteError.length) {
            operationStatus = dialogs.annotationWriteError;
            printRequested = false;
            return;
        }
        dialogs.flushAnnotation();
        if (currentReader.pendingCommands > 0) {
            printRequested = true;
            printRetry.restart();
            return;
        }
        printRequested = false;
        if (session)
            session.printDocument(currentReader, currentPage);
    }
    Timer {
        id: printRetry
        interval: 80
        onTriggered: if (root.printRequested)
            root.printDocument()
    }
    property var exportContext: null
    function chooseExport(kind) {
        exportKind = kind;
        exportContext = {
            reader: currentReader,
            kind: kind,
            forms: formPayload(),
            redactions: pendingRedactions.slice(),
            pages: selectedPages.slice(),
            properties: kind === "properties" ? dialogs.informationDialog.draft() : null,
            text: kind === "bibtex" ? bibtex : (kind === "markdown" || kind === "csv" ? annotationExport(kind) : "")
        };
        dialogs.saveDialog.open();
    }
    function chooseRedactionExport(owner, areas) {
        exportKind = "redactions";
        exportContext = {
            reader: owner,
            kind: "redactions",
            redactions: areas
        };
        dialogs.saveDialog.open();
    }
    function updateFormValue(id, value) {
        const next = Object.assign({}, formValues);
        const field = currentReader.data.forms ? currentReader.data.forms.fields.find(function (f) {
            return f.id === id;
        }) : null;
        if (!field || !field.editable)
            return;
        const same = field.kind === "text" ? value.text === (field.value || "") : field.kind === "checkBox" ? value.checked === field.checked : value.selected === (field.selected.length ? field.selected[0] : -1);
        if (same)
            delete next[id];
        else
            next[id] = Object.assign({
                field_id: id
            }, value);
        currentReader.setEditDraft("forms", next);
    }
    function formPayload() {
        return Object.keys(formValues).map(function (key) {
            return formValues[key];
        });
    }
    function editMetadata(key, text) {
        if (!metadataDraft) {
            const m = currentReader.data.metadata || ({});
            const values = function (k) {
                return m[k] ? m[k].values.join(" ") : "";
            };
            metadataDraft = {
                title: values("title"),
                authors: m.authors ? m.authors.values : [],
                venue: values("venue"),
                year: values("year"),
                doi: values("doi"),
                arxiv_id: values("arxiv_id")
            };
        }
        const draft = Object.assign({}, metadataDraft);
        draft[key] = key === "authors" ? text.split(";").map(function (s) {
            return s.trim();
        }).filter(function (s) {
            return s.length;
        }) : text;
        metadataDraft = draft;
        currentReader.submit("bibtex", {
            draft: draft
        });
    }
    function exportTo(url) {
        if (!session)
            return;
        const context = exportContext || {
            reader: currentReader,
            kind: exportKind,
            forms: formPayload(),
            redactions: pendingRedactions.slice()
        };
        const owner = context.reader;
        if (!owner)
            return;
        const destination = session.localPath(url);
        if (context.kind === "redactions")
            owner.submit("save_redactions", {
                destination: destination,
                areas: context.redactions
            });
        else if (context.kind === "properties")
            owner.submit("save_properties", Object.assign({
                destination: destination
            }, context.properties));
        else if (context.kind === "forms")
            owner.submit("save_forms", {
                destination: destination,
                values: context.forms
            });
        else if (context.kind === "extract")
            owner.submit("extract_pages", {
                destination: destination,
                pages: context.pages
            });
        else if (context.kind === "pages")
            owner.submit("save_current_edited_copy", {
                destination: destination
            });
        else if (context.kind === "bibtex")
            operationStatus = session.writeTextFile(url, context.text) || qsTr("BibTeX saved.");
        else if (context.kind === "markdown" || context.kind === "csv")
            operationStatus = session.writeTextFile(url, context.text) || qsTr("Annotations exported.");
        else
            owner.submit("save_current_annotations", {
                destination: destination
            });
    }
    function annotationPayload() {
        return {
            annotations: [],
            bookmarks: [],
            updates: [],
            deletions: []
        };
    }
    function annotationExport(format) {
        const quote = function (s) {
            return '"' + String(s || "").replace(/"/g, '""') + '"';
        };
        if (format === "csv")
            return "page,kind,text\r\n" + annotations.map(function (a) {
                return (a.page + 1) + "," + quote(a.kind) + "," + quote(a.note || a.contents);
            }).join("\r\n") + "\r\n";
        return "# " + currentReader.title + "\n\n" + annotations.map(function (a) {
            return "## Page " + (a.page + 1) + " · " + a.kind + "\n\n" + (a.note || a.contents || "") + "\n";
        }).join("\n");
    }
    function confirmReplace(kind) {
        if (originalReadOnly) {
            operationStatus = readOnlyReason;
            return;
        }
        dialogs.confirmReplacement(kind);
    }
    function performReplace(kind) {
        if (originalReadOnly) {
            operationStatus = readOnlyReason;
            return;
        }
        dialogs.flushAnnotation();
        dialogs.annotationDialog.close();
        if (kind === "pages")
            currentReader.submit("page_apply");
        else if (kind === "properties")
            currentReader.submit("replace_properties", dialogs.informationDialog.draft());
        else if (kind === "forms")
            currentReader.submit("replace_forms", {
                values: formPayload()
            });
        else
            currentReader.submit("replace_current_annotations");
    }
    function saveAiCredential(account, key) {
        if (session)
            session.credentials.write(account, key);
    }
    function removeAiCredential(account) {
        if (session)
            session.credentials.remove(account);
    }
    function sendAi(owner, plan) {
        if (!owner || !plan)
            return;
        if (plan.is_local) {
            if (!owner.startAi("local", plan))
                operationStatus = qsTr("The request changed or the document is busy. Preview and Send again.");
        } else {
            pendingAiReader = owner;
            pendingAiPlan = plan;
            credentialReadId = session ? session.credentials.read(plan.base_url) : -1;
            if (!session)
                dialogs.credentialDialog.open();
        }
    }
    onAiSettingsChanged: {
        if (session)
            for (const tab of session.tabs)
                tab.reader.invalidateAiPlan();
        else if (currentReader)
            currentReader.invalidateAiPlan();
    }
    property int requestedPage: -1
    property real requestedY: 0
    property double credentialReadId: -1
    property var pendingAiReader: null
    property var pendingAiPlan: null

    Action {
        id: openAction
        text: qsTr("Open PDF…")
        shortcut: StandardKey.Open
        onTriggered: fileDialog.open()
    }
    Action {
        id: quitAction
        text: qsTr("Quit")
        shortcut: StandardKey.Quit
        onTriggered: if (root.session)
            root.session.requestQuit()
        else
            root.close()
    }
    Action {
        id: zoomIn
        text: qsTr("Zoom In")
        shortcut: StandardKey.ZoomIn
        enabled: currentReader.pageCount > 0
        onTriggered: root.zoomBy(1.2)
    }
    Action {
        id: zoomOut
        text: qsTr("Zoom Out")
        shortcut: StandardKey.ZoomOut
        enabled: currentReader.pageCount > 0
        onTriggered: root.zoomBy(1 / 1.2)
    }
    Action {
        id: fitAction
        text: qsTr("Fit Width")
        shortcut: "Ctrl+1"
        enabled: currentReader.pageCount > 0 && !root.textViewVisible
        onTriggered: root.fitWidth()
    }
    Action {
        id: actualAction
        text: qsTr("Actual Size")
        shortcut: "Ctrl+0"
        enabled: currentReader.pageCount > 0 && !root.textViewVisible
        onTriggered: {
            root.fitting = false;
            root.changeZoom(1, pageList.width / 2, pageList.height / 2);
        }
    }
    Action {
        id: readPageTextAction
        objectName: "readPageTextAction"
        text: qsTr("Read Page Text")
        shortcut: "Ctrl+Shift+R"
        enabled: currentReader.pageCount > 0
        checkable: true
        checked: root.textViewVisible
        onTriggered: root.setTextViewEnabled(checked)
    }
    Shortcut {
        sequence: "PageDown"
        enabled: !root.textViewVisible
        onActivated: root.navigate(root.currentPage + 1)
    }
    Shortcut {
        sequence: "PageUp"
        enabled: !root.textViewVisible
        onActivated: root.navigate(root.currentPage - 1)
    }
    Shortcut {
        sequence: "Ctrl+Home"
        enabled: !root.textViewVisible
        onActivated: root.navigate(0)
    }
    Shortcut {
        sequence: "Ctrl+End"
        enabled: !root.textViewVisible
        onActivated: root.navigate(currentReader.pageCount - 1)
    }
    Shortcut {
        sequence: "Ctrl+L"
        onActivated: {
            pageNumber.forceActiveFocus();
            pageNumber.selectAll();
        }
    }
    Shortcut {
        sequence: "Ctrl+B"
        onActivated: root.sidebarVisible = !root.sidebarVisible
    }
    Shortcut {
        sequence: "F11"
        onActivated: root.visibility = root.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen
    }
    Shortcut {
        sequences: [StandardKey.Copy]
        enabled: !!root.selection && root.activeFocusItem && root.activeFocusItem.objectName === "pdfPointer"
        onActivated: root.copySelection()
    }
    Shortcut {
        sequences: [StandardKey.Find]
        onActivated: {
            root.searchVisible = true;
            const field = root.findSearchField();
            if (field)
                field.forceActiveFocus();
        }
    }
    Shortcut {
        sequence: "Ctrl+D"
        onActivated: root.addBookmark()
    }
    Shortcut {
        sequence: "Ctrl+W"
        onActivated: if (root.session)
            root.requestCloseTab(root.session.activeIndex)
    }
    Shortcut {
        sequence: "Ctrl+Tab"
        onActivated: if (root.session)
            root.session.selectTab((root.session.activeIndex + 1) % root.session.tabs.length)
    }
    function findSearchField() {
        return chromeSearchField;
    }
    property var chromeSearchField: null

    Shortcut {
        sequences: [StandardKey.Undo]
        enabled: !(root.activeFocusItem && typeof root.activeFocusItem.selectedText !== "undefined")
        onActivated: root.undo()
    }
    Shortcut {
        sequences: [StandardKey.Redo]
        enabled: !(root.activeFocusItem && typeof root.activeFocusItem.selectedText !== "undefined")
        onActivated: root.redo()
    }
    Shortcut {
        sequence: "Escape"
        onActivated: {
            if (root.previewController && root.previewController.visible)
                root.previewController.close();
            root.annotationTool = "select";
            root.annotationDraft = null;
            root.redactionDraft = null;
            root.selectedAnnotation = null;
            root.selection = null;
            root.overviewVisible = false;
        }
    }
    menuBar: MenuBar {
        background: Rectangle {
            color: theme.titlebarBg
        }
        Menu {
            title: qsTr("&File")
            MenuItem {
                action: openAction
            }
            MenuSeparator {}
            MenuItem {
                action: quitAction
            }
        }
        Menu {
            title: qsTr("&View")
            MenuItem {
                action: readPageTextAction
            }
            MenuItem {
                action: zoomIn
            }
            MenuItem {
                action: zoomOut
            }
            MenuItem {
                action: fitAction
            }
            MenuItem {
                action: actualAction
            }
            MenuSeparator {}
            MenuItem {
                text: qsTr("Pages Sidebar")
                checkable: true
                checked: root.sidebarVisible
                onTriggered: root.sidebarVisible = checked
            }
            MenuSeparator {}
            Menu {
                title: qsTr("Appearance")
                ActionGroup {
                    id: appearanceGroup
                }
                MenuItem {
                    action: Action {
                        text: qsTr("Light")
                        checkable: true
                        checked: root.appearance === "light"
                        ActionGroup.group: appearanceGroup
                        onTriggered: root.appearance = "light"
                    }
                }
                MenuItem {
                    action: Action {
                        text: qsTr("Dark")
                        checkable: true
                        checked: root.appearance === "dark"
                        ActionGroup.group: appearanceGroup
                        onTriggered: root.appearance = "dark"
                    }
                }
                MenuItem {
                    action: Action {
                        text: qsTr("Follow System")
                        checkable: true
                        checked: root.appearance === "system"
                        ActionGroup.group: appearanceGroup
                        onTriggered: root.appearance = "system"
                    }
                }
            }
        }
    }
    header: ReaderChrome {
        app: root
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Frame {
            visible: (currentReader.error.length > 0 || !!root.markState.error) && !currentReader.passwordRequired
            Layout.fillWidth: true
            background: Rectangle {
                color: theme.errorBg
            }
            RowLayout {
                anchors.fill: parent
                Label {
                    text: qsTr("Error: %1").arg(root.markState.error || currentReader.error)
                    color: theme.errorFg
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                    Accessible.role: Accessible.AlertMessage
                }
                ToolButton {
                    text: qsTr("Back Up & Start Fresh…")
                    visible: !!root.markState.error
                    onClicked: dialogs.recoverSidecar()
                }
                ToolButton {
                    text: qsTr("Dismiss")
                    onClicked: currentReader.dismissError()
                }
            }
        }
        DocumentDraftBar {
            app: root
            Layout.fillWidth: true
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0
            ReaderSidebar {
                objectName: "readerSidebar"
                app: root
                visible: root.sidebarVisible && currentReader.pageCount > 0 && !(root.searchVisible && root.width < 950)
                Layout.preferredWidth: root.width < 850 ? 210 : 246
                Layout.fillHeight: true
            }

            Rectangle {
                visible: root.sidebarVisible && currentReader.pageCount > 0 && !(root.searchVisible && root.width < 950)
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                color: theme.separator
            }
            Item {
                id: readingArea
                objectName: "readingArea"
                Layout.fillWidth: true
                Layout.fillHeight: true
                Rectangle {
                    anchors.fill: parent
                    color: currentReader.pageCount > 0 ? theme.canvasBg : theme.emptyBg
                }
                DocumentCanvas {
                    id: canvas
                    anchors.fill: parent
                    app: root
                    visible: !root.overviewVisible && !root.textViewVisible
                }
                PageTextView {
                    id: accessibleTextView
                    objectName: "pageTextView"
                    anchors.fill: parent
                    app: root
                    visible: root.textViewVisible && currentReader.pageCount > 0
                }
                PageOverview {
                    anchors.fill: parent
                    app: root
                    visible: root.overviewVisible && currentReader.pageCount > 0
                }
                AnnotationTools {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    app: root
                    visible: root.annotationToolsVisible && currentReader.pageCount > 0 && !root.overviewVisible
                    z: 5
                }
                WelcomeView {
                    anchors.fill: parent
                    visible: currentReader.pageCount === 0
                    app: root
                }
                DropArea {
                    anchors.fill: parent
                    onDropped: function (drop) {
                        if (drop.hasUrls && drop.urls.length > 0) {
                            if (root.session)
                                root.session.openFiles(drop.urls);
                            else
                                currentReader.openFile(drop.urls[0]);
                            drop.accepted = true;
                        }
                    }
                }
            }
            SearchPanel {
                objectName: "searchPanel"
                app: root
                visible: root.searchVisible && currentReader.pageCount > 0
                Layout.preferredWidth: Math.min(280, root.width / 3)
                Layout.fillHeight: true
            }
        }
    }
    footer: ToolBar {
        visible: currentReader.pageCount > 0
        padding: 5
        background: Rectangle {
            color: theme.statusbarBg
        }
        RowLayout {
            anchors.fill: parent
            ToolButton {
                text: "‹"
                font.pixelSize: 22
                enabled: root.currentPage > 0
                Accessible.name: qsTr("Previous page")
                onClicked: root.navigate(root.currentPage - 1)
            }
            TextField {
                id: pageNumber
                objectName: "pageNumber"
                text: (root.currentPage + 1).toString()
                Layout.preferredWidth: 52
                horizontalAlignment: Text.AlignHCenter
                validator: IntValidator {
                    bottom: 1
                    top: Math.max(1, currentReader.pageCount)
                }
                Accessible.name: qsTr("Go to page")
                onAccepted: {
                    root.navigate(Number(text) - 1);
                    pageList.forceActiveFocus();
                }
            }
            Label {
                text: "/ " + currentReader.pageCount
                color: theme.textTertiary
            }
            ToolButton {
                text: "›"
                font.pixelSize: 22
                enabled: root.currentPage < currentReader.pageCount - 1
                Accessible.name: qsTr("Next page")
                onClicked: root.navigate(root.currentPage + 1)
            }
            Item {
                Layout.fillWidth: true
            }
            Label {
                text: root.operationStatus
                elide: Text.ElideMiddle
                Layout.maximumWidth: Math.max(100, root.width / 3)
                color: root.colors.textSecondary
                font.pixelSize: 11
                visible: text.length > 0
            }
            ToolButton {
                action: fitAction
            }
            Label {
                text: qsTr("Ctrl + scroll to zoom")
                color: theme.textTertiary
                font.pixelSize: 11
                visible: root.width > 850
                Layout.rightMargin: 12
            }
        }
    }
    FileDialog {
        id: fileDialog
        title: qsTr("Open a PDF")
        nameFilters: [qsTr("PDF documents (*.pdf)"), qsTr("All files (*)")]
        fileMode: FileDialog.OpenFiles
        onAccepted: {
            if (root.session)
                root.session.openFiles(selectedFiles);
            else if (selectedFiles.length)
                currentReader.openFile(selectedFiles[0]);
        }
    }
    Dialog {
        id: passwordDialog
        anchors.centerIn: parent
        title: qsTr("Password required")
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        ColumnLayout {
            Label {
                text: qsTr("Enter the password for this PDF.")
            }
            TextField {
                id: passwordField
                echoMode: TextInput.Password
                Accessible.name: qsTr("PDF password")
                onAccepted: passwordDialog.accept()
            }
        }
        onOpened: passwordField.forceActiveFocus()
        onAccepted: {
            currentReader.retryPassword(passwordField.text);
            passwordField.clear();
        }
        onRejected: passwordField.clear()
    }
    ReaderDialogs {
        id: dialogs
        app: root
    }
    Timer {
        id: searchTimer
        interval: 250
        onTriggered: root.runSearch()
    }
    Timer {
        id: positionTimer
        interval: 500
        onTriggered: root.saveReadingPosition()
    }
    Timer {
        id: resizeTimer
        interval: 0
        onTriggered: if (root.fitting)
            root.fitWidth()
    }
    Connections {
        target: root.session ? root.session.credentials : null
        function onFinished(id, operation, secret, error) {
            if (operation === "read" && id === root.credentialReadId && root.pendingAiReader) {
                if (secret.length) {
                    if (!root.pendingAiReader.startAi(secret, root.pendingAiPlan))
                        root.operationStatus = qsTr("The request changed or the document is busy. Preview and Send again.");
                    root.pendingAiPlan = null;
                    root.pendingAiReader = null;
                } else {
                    root.operationStatus = error;
                    dialogs.credentialDialog.open();
                }
            } else if (operation === "write" || operation === "remove")
                root.operationStatus = error || qsTr("System keychain updated.");
        }
    }
    Connections {
        target: root.session
        function onPrintFinished(error) {
            root.operationStatus = error || qsTr("Print job completed.");
        }
        function onCloseTabRequested(index) {
            root.requestCloseTab(index);
        }
        function onActiveReaderAboutToChange() {
            dialogs.flushAnnotation();
            dialogs.annotationDialog.close();
            root.saveReadingPosition();
        }
    }
    Connections {
        target: root.currentReader
        function onDocumentReset() {
            root.selection = null;
            root.selectedAnnotation = null;
            root.annotationDraft = null;
            root.redactionDraft = null;
            root.metadataDraft = null;
            root.infoData = {};
        }
        function onOpenFinished(success) {
            if (success) {
                Qt.callLater(root.restorePosition);
                if (root.formToolActive)
                    currentReader.submit("forms");
            }
        }
        function onCommandFinished(id, op, result, error) {
            if (op.indexOf("page_") === 0 && op !== "page_operation") {
                root.pageEditBusy = false;
                if (!error.length) {
                    const map = result.report ? result.report.page_map : null;
                    const page = map && map[root.pendingPage] !== null && map[root.pendingPage] !== undefined ? map[root.pendingPage] : Math.min(root.pendingPage, currentReader.pageCount - 1);
                    root.selection = null;
                    root.selectedAnnotation = null;
                    root.searchResults = [];
                    root.selectedPages = map ? root.pendingPageSelection.map(function (p) {
                        return map[p];
                    }).filter(function (p) {
                        return p !== null && p !== undefined;
                    }) : [page];
                    root.pendingPosition = {
                        page: result.report && result.report.inserted_page !== null && result.report.inserted_page !== undefined ? result.report.inserted_page : page,
                        zoom: root.zoom,
                        fitting: root.fitting
                    };
                    currentReader.setLayout(root.layoutMode, root.pageGap);
                    root.operationStatus = op === "page_apply" ? qsTr("Page changes applied. Backup: %1").arg(result.report.backup_path || "") : qsTr("Page session updated; original unchanged.");
                }
            }
            if (id === root.pendingDraftRequestId)
                root.annotationDraft = null;
            if (op === "marks_erase")
                root.eraseDraft = [];
            if (error.length) {
                if (op === "file_adopt")
                    dialogs.showAnnotation();
                return;
            }
            if (op === "mark_create" || op === "file_adopt") {
                if (result.selected_id) {
                    root.selectedAnnotation = root.annotations.find(function (a) {
                        return a.id === result.selected_id;
                    }) || null;
                    if (root.selectedAnnotation && (root.selectedAnnotation.kind === "stickyNote" || root.selectedAnnotation.kind === "textBox"))
                        dialogs.showAnnotation();
                }
            } else if (op.indexOf("mark_") === 0 || op.indexOf("marks_") === 0) {
                if (root.selectedAnnotation)
                    root.selectedAnnotation = root.annotations.find(function (a) {
                        return a.id === root.selectedAnnotation.id;
                    }) || null;
            }

            if (op === "layout") {
                if (root.pendingPosition) {
                    const state = root.pendingPosition;
                    root.pendingPosition = null;
                    if (state.zoom && !state.fitting) {
                        root.fitting = false;
                        root.zoom = state.zoom;
                    } else
                        root.fitWidth();
                    Qt.callLater(function () {
                        root.navigate(state.page || 0, state.y || 0);
                        if (state.offset !== undefined)
                            pageList.contentY = state.offset;
                    });
                } else if (root.fitting)
                    root.fitWidth();
            } else if (op === "search" && id === root.searchRequestId) {
                root.searchResults = result;
                root.searchIndex = result.length ? 0 : -1;
                root.searchVisible = true;
                if (root.activeSearchHit)
                    root.navigate(root.activeSearchHit.page);
            } else if (op === "document_info")
                root.infoData = result;
            else if (op === "save_merge")
                root.operationStatus = qsTr("Merged %1 pages into %2. Appended outline entries not imported: %3.").arg(result.page_count).arg(result.destination_path).arg(result.dropped_outline_entries);
            else if (op === "save_split")
                root.operationStatus = qsTr("Wrote %1 verified split PDFs with their annotation sidecars.").arg(result.parts.length);
            else if (op === "save_redactions") {
                root.annotationTool = "select";
                root.operationStatus = qsTr("Verified redacted copy saved: %1 · %2 characters removed.").arg(result.destination_path).arg(result.removed_characters);
            } else if (op.indexOf("save_") === 0)
                root.operationStatus = qsTr("Saved to %1").arg(result.destination_path || "");
            else if (op.indexOf("replace_") === 0) {
                root.operationStatus = qsTr("Saved. Verified backup: %1").arg(result.backup_path || "");
                currentReader.openFile(currentReader.fileUrl);
            }
        }
        function onPasswordRequiredChanged() {
            if (currentReader.passwordRequired)
                passwordDialog.open();
        }
    }
}

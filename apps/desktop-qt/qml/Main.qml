import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import QtQml.Models
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
    readonly property bool xfaReadOnly: !!(currentReader.data.xfa_status || {}).is_xfa
    readonly property string readOnlyReason: (currentReader.data.xfa_status || {}).read_only_reason || signatureStatus.read_only_reason || ""
    readonly property bool canModifyPdf: currentReader.pageCount > 0 && !xfaReadOnly
    function blockXfaWrite() {
        if (!xfaReadOnly) return false;
        operationStatus=readOnlyReason;
        return true;
    }
    onXfaReadOnlyChanged: if (xfaReadOnly) {
        cancelErase();
        annotationTool="select";
        annotationToolsVisible=false;
        formToolActive=false;
        selectedAnnotation=null;
        setSecondaryRow("",true);
    }
    readonly property var colors: theme
    readonly property var pageList: canvas.view
    property string appearance: session ? session.preference("appearance", "light") : "light"
    property string sidebarTab: "thumbnails"
    property bool aiPanelVisible: false
    property real aiPanelWidth: session ? Number(session.preference("aiPanelWidth", 360)) : 360
    function showAiPanel(show) {
        if (show && secondaryRow==="edit" && contentController.deferAction({kind:"assistant",value:true})) return;
        if (show) setSecondaryRow("lyra",true);
        aiPanelVisible = show;
        if (show && width < 1200) searchVisible = false;
    }
    onSearchVisibleChanged: if (searchVisible && width < 1200) aiPanelVisible = false
    onWidthChanged: if (width < 1200 && aiPanelVisible && searchVisible) searchVisible = false
    function resizeAiPanel(value, save) {
        aiPanelWidth = Math.max(280, Math.min(520, value));
        if (save && session) session.setPreference("aiPanelWidth", aiPanelWidth);
    }
    property string secondaryRow: ""
    property alias contentEditor: contentController
    readonly property var placedTextEditor: placedTextController
    readonly property var fillTools: secondaryTools.fillTools
    property string fillTool: ""
    property string fillText: "Text"
    property int fillFontSize: 14
    property string fillDateFormat: "medium"
    property int fillDateRotation: 0
    property var fillDateGeneration: null
    property var formattedFillDate: ({})
    onFillDateFormatChanged: if (fillTool === "date") refreshFillDate()
    property string fillImageSize: "medium"
    property color fillColor: theme.documentInk
    readonly property bool editInspectorVisible: currentReader.pageCount>0 && secondaryRow==="edit" && (contentController.tool!=="select" || !!contentController.selected || contentController.hasDraft)
    readonly property bool fillInspectorVisible: currentReader.pageCount>0 && secondaryRow==="fill" && fillTool.length>0
    onSecondaryRowChanged: {
        annotationToolsVisible=secondaryRow==="annotate";
        if (secondaryRow!=="fill") {clearFillTool();formToolActive=false;}
        if (secondaryRow==="edit" || secondaryRow==="fill") aiPanelVisible=false;
        if (secondaryRow!=="annotate" && secondaryRow!=="fill") {cancelErase();annotationTool="select";}
        if (secondaryRow==="edit") {overviewVisible=false;textViewVisible=false;contentController.reload();}
        else if (secondaryRow==="fill") currentReader.submit("forms");
    }
    function toggleSecondaryRow(value) {setSecondaryRow(secondaryRow===value && !overviewVisible ? "" : value);}
    function setSecondaryRow(value,force) {
        if(placedTextController.waitingForCreation)placedTextController.suppressPendingEditor();
        if (placedTextController.deferAction(function(){root.setSecondaryRow(value,force);})) return;
        if (!force && secondaryRow==="edit" && contentController.deferAction({kind:"row",value:value})) return;
        if (value.length && !currentReader.pageCount) return;
        if (["annotate","edit","fill"].indexOf(value)>=0 && blockXfaWrite()) return;
        dialogs.flushAnnotation();
        if(value.length){overviewVisible=false;textViewVisible=false;dialogs.annotationDialog.close();}
        secondaryRow=value;
        if (value!=="edit") {contentController.tool="select";contentController.selected=null;contentController.inlineEditing=false;contentController.gesture=null;}
    }
    function selectReaderTab(index,force) {
        if (!session || index<0 || index>=session.tabs.length) return;
        const target=session.tabs[index].reader;
        if(placedTextController.deferAction(function(){root.selectReaderTab(root.readerIndex(target),force);}))return;
        if (!force && secondaryRow==="edit" && contentController.deferAction({kind:"tab",reader:session.tabs[index].reader})) return;
        session.selectTab(index);
    }
    signal tabReorderFinished(var owner)
    signal cancelTabReorder()
    function reorderReaderTab(owner,before,force) {
        if(!session || readerIndex(owner)<0 || (before && readerIndex(before)<0))return;
        if(!force && owner!==currentReader && secondaryRow==="edit" && contentController.deferAction({kind:"reorder",reader:owner,before:before}))return;
        if(session.moveTab(owner,before))tabReorderFinished(owner);
    }
    function showOverview(force) {
        if(placedTextController.deferAction(function(){root.showOverview(force);}))return;
        if(placedTextController.waitingForCreation)placedTextController.suppressPendingEditor();
        if (!force && secondaryRow==="edit" && contentController.deferAction({kind:"overview"})) return;
        overviewVisible=!overviewVisible;
    }
    function clearFillTool() {fillTool="";fillDateGeneration=null;pendingStampStyle="";pendingSignatureImage=null;pendingDrawnSignature=null;annotationTool="select";}
    function refreshFillDate() {
        const result=currentReader.formattedDate(fillDateFormat,"","");
        if(result.error){operationStatus=result.error;return false;}
        formattedFillDate=result;fillText=result.text;return true;
    }
    function setFillTool(value) {
        if(placedTextController.waitingForCreation || (placedTextController.active && !placedTextController.current)) {
            operationStatus=qsTr("Wait for the pending placed-text edit to finish.");return;
        }
        if(placedTextController.deferAction(function(){root.setFillTool(value);}))return;
        if (blockXfaWrite()) return;
        if (secondaryRow!=="fill") setSecondaryRow("fill");
        if (secondaryRow!=="fill") return;
        const next=fillTool===value ? "" : value;
        clearFillTool();fillTool=next;
        if (["text","date","check","cross"].indexOf(next)>=0) {
            annotationTool="textBox";
            if(next==="date") {
                fillDateGeneration=currentReader.documentGeneration;
                if(!refreshFillDate()){clearFillTool();return;}
            } else fillText=next==="check" ? "✓" : next==="cross" ? "✕" : qsTr("Text");
        }
        setTextViewEnabled(false);overviewVisible=false;
    }
    function fillColour() {return "#"+Logic.hex(fillColor.r*255)+Logic.hex(fillColor.g*255)+Logic.hex(fillColor.b*255)+Logic.hex(fillColor.a*255);}
    ContentEditing {id:contentController;app:root}
    PlacedTextEditing {id:placedTextController;app:root}
    property bool annotationToolsVisible: false
    onAnnotationToolsVisibleChanged: {
        if(annotationToolsVisible && secondaryRow!=="annotate")secondaryRow="annotate";
        else if(!annotationToolsVisible && secondaryRow==="annotate")secondaryRow="";
    }
    property bool overviewVisible: false
    property bool textViewVisible: false
    readonly property real textViewZoom: accessibleTextView.textSize / 16
    onOverviewVisibleChanged: if (overviewVisible)
        textViewVisible = false
    function setTextViewEnabled(show) {
        if(placedTextController.deferAction(function(){root.setTextViewEnabled(show);}))return;
        if(show && placedTextController.waitingForCreation)placedTextController.suppressPendingEditor();
        if (show && secondaryRow==="edit" && contentController.deferAction({kind:"textView",value:show})) return;
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
    property string pendingStampStyle: ""
    property var pendingSignatureImage: null
    property var pendingDrawnSignature: null
    property var pendingDrawnGeneration: null
    onAnnotationToolChanged: {
        if (annotationTool !== "eraser")
            cancelErase();
        if (annotationTool !== "stamp")
            pendingStampStyle = "";
        if (annotationTool !== "signature") {
            pendingSignatureImage = null;
            pendingDrawnSignature = null;
        }
    }
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
    property bool positionRestoring: true
    property int positionRestoreEpoch: 0
    property alias searchDebounce: searchTimer
    property var selectedAnnotation: null
    property var infoData: ({})
    readonly property var formValues: currentReader.editDrafts.forms || ({})
    readonly property var pendingRedactions: currentReader.editDrafts.redactions || []
    readonly property bool canRedact: false // Annotation redaction is retired; content editing has its own tools.
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
    property string previewStatus: ""
    onOperationStatusChanged: previewStatus = ""
    onAppearanceChanged: if (session)
        session.setPreference("appearance", appearance)
    onCurrentReaderChanged: {
        Qt.callLater(function(){contentController.reset();});
        if (fillTool.length>0) clearFillTool();
        else fillTool="";
        cancelErase();
        pendingArtworkRequest = -1;
        pendingStampStyle = "";
        pendingSignatureImage = null;
        pendingDrawnSignature = null;
        if (annotationTool === "stamp" || annotationTool === "signature")
            annotationTool = "select";
        ++positionRestoreEpoch;
        positionRestoring = true;
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
            const epoch = positionRestoreEpoch;
            Qt.callLater(function () {
                if (epoch === root.positionRestoreEpoch)
                    root.restorePosition();
            });
            if (formToolActive)
                currentReader.submit("forms");
        }
    }
    property bool closeApproved: false
    property int closingTab: -2
    property var pendingCloseReader: null
    function prepareForQuit() {
        if (closeOperation || pendingDocumentSave || dialogs.closePromptVisible || dialogs.saveDialog.visible) return false;
        cancelErase();dialogs.flushAnnotation();saveReadingPosition();return true;
    }
    function prepareDiscardForQuit() {dialogs.cancelAnnotationDraft();}
    function prepareQuitSave(operation) {
        saveReadingPosition();
        if (operation==="document_save") {
            pendingSavePosition={reader:currentReader,position:session ? session.viewState(currentReader) : {page:currentPage,zoom:zoom,fitting:fitting}};
            pendingPage=currentPage;pendingPageSelection=selectedPages.slice();
        }
        // A restore in progress keeps the previously captured viewport, without waiting
        // for an animation frame or replacing it with an intermediate page-list position.
        return positionRestoring ? {} : {current_page:currentPage,selected_pages:selectedPages.slice()};
    }
    function saveReadingPosition() {
        positionTimer.stop();
        if (session && currentReader.pageCount > 0 && !positionRestoring) {
            const state = {
                page: currentPage,
                zoom: zoom,
                zoomPercent: zoomPercent,
                fitPreset: fitPreset,
                fitting: fitting,
                layout: layoutMode,
                gap: pageGap
            };
            if (!textViewVisible) {
                state.viewportAnchor = canvas.viewportAnchor(0);
                state.offset = canvas.documentOffset(state.viewportAnchor);
                state.documentX = canvas.documentX();
            }
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
        const tabs = session ? session.tabs : [{reader:currentReader}];
        return tabs.some(function (tab,i) { return (index < 0 || i === index) && tab.reader.hasUnsavedChanges; });
    }
    function closeTarget(index) {
        const tabs = session ? session.tabs : [{reader:currentReader}];
        if (index >= 0) return index < tabs.length ? tabs[index].reader : null;
        const dirty = tabs.find(function (tab) { return tab.reader.hasUnsavedChanges; });
        return dirty ? dirty.reader : null;
    }
    function readerIndex(owner) {
        return session ? session.tabs.findIndex(function (tab) { return tab.reader === owner; }) : (owner === currentReader ? 0 : -1);
    }
    function closeNeedsReview(owner) {
        return !!owner && (owner.hasEditDrafts || Object.keys(owner.noteDrafts).length > 0);
    }
    function reviewClose(owner) {
        if (!owner) return;
        if (session) session.selectTab(readerIndex(owner));
        if (owner.editDrafts.content && Object.keys(owner.editDrafts.content).length) {
            setSecondaryRow("edit",true);
            contentController.inlineEditing=contentController.textDraft;
            navigate(owner.editDrafts.content.page);
            operationStatus=qsTr("Review the preserved PDF content draft before closing.");
            return;
        }
        const forms=owner.editDrafts.forms || {};
        if (Object.keys(forms).length) {
            formToolActive=true;
            owner.submit("forms");
            operationStatus=qsTr("Review the form values, then use Save before closing.");
        } else {
            const ids=Object.keys(owner.noteDrafts);
            const annotation=annotations.find(function (item) { return ids.indexOf(item.id)>=0; });
            if (annotation) selectAnnotation(annotation,true);
            operationStatus=qsTr("Review the pending edit before saving or discarding it.");
        }
    }
    function requestCloseTab(index) {
        if (session && session.tabs[index] && session.tabs[index].reader===currentReader && secondaryRow==="edit" && contentController.deferAction({kind:"tabClose",reader:currentReader})) return;
        if (!session || closeOperation || dialogs.closePromptVisible) return;
        const owner=closeTarget(index);
        if (!owner) return;
        dialogs.flushAnnotation();
        closingTab=index;
        pendingCloseReader=owner;
        if (owner.pendingCommands>0) { closeRetry.start(); return; }
        closingTab=-2;
        pendingCloseReader=null;
        const currentIndex=readerIndex(owner);
        if (owner.hasUnsavedChanges) dialogs.confirmClose(currentIndex);
        else session.closeTab(currentIndex);
    }
    property var closeOperation: null
    function cancelCloseOperation(message) {
        closeOperation=null;
        if (message) operationStatus=message;
    }
    function closeCommand(ticket,operation,args) {
        ticket.phase="command";
        ticket.id=ticket.reader.submit(operation,args || {});
        ticket.revision=ticket.reader.editRevision;
    }
    function beginCloseOperation(kind,owner,wholeWindow) {
        if (!owner || closeOperation || owner.pendingCommands>0) return;
        if (kind === "save" && closeNeedsReview(owner)) { reviewClose(owner); return; }
        if (dialogs.noteReader === owner && kind === "discard") dialogs.cancelAnnotationDraft();
        const ticket={reader:owner,window:wholeWindow,phase:"command",id:-1,revision:owner.editRevision,next:"finish"};
        closeOperation=ticket;
        if (kind === "discard") closeCommand(ticket,"document_discard",{});
        else if ((owner.data.signature_status || {}).signed) {
            exportKind="document";
            exportContext={reader:owner,revision:owner.data.document_revision,kind:"document",forms:[],closeTicket:ticket};
            ticket.phase="panel";
            dialogs.saveDialog.open();
        } else closeCommand(ticket,"document_save",{expected_revision:owner.data.document_revision});
    }
    function discardAndClose(index) { beginCloseOperation("discard",closeTarget(index),index<0); }
    function closeCommandFinished(owner,id,operation,result,error) {
        const ticket=closeOperation;
        if (!ticket || ticket.reader !== owner || ticket.id !== id) return;
        if (error.length) { cancelCloseOperation(error); return; }
        const report=result.report || result;
        const warning=report.cache_cleanup_error || report.sidecar_error || report.sidecar_cleanup_error || report.recovery_warning;
        if (warning) { cancelCloseOperation(qsTr("The PDF was saved, but its draft needs attention: %1").arg(warning)); return; }
        ticket.next=operation === "save_document_copy" ? "discard-copy-draft" : "finish";
        ticket.phase="draining";
        Qt.callLater(advanceCloseOperation);
    }
    function advanceCloseOperation() {
        const ticket=closeOperation;
        if (!ticket || ticket.phase !== "draining") return;
        const owner=ticket.reader;
        if (!owner || readerIndex(owner)<0) { closeOperation=null; return; }
        if (owner.pendingCommands>0) return;
        if (owner.editRevision !== ticket.revision || Object.keys(owner.noteDrafts).length || owner.hasEditDrafts) {
            cancelCloseOperation(qsTr("New changes remain unsaved. The document is still open."));
            return;
        }
        if (ticket.next === "discard-copy-draft") { closeCommand(ticket,"document_discard",{}); return; }
        if (owner.hasUnsavedChanges) { cancelCloseOperation(qsTr("Changes remain unsaved. The document is still open.")); return; }
        const index=readerIndex(owner),wholeWindow=ticket.window;
        closeOperation=null;
        if (session) session.closeTab(index,true);
        if (wholeWindow) Qt.callLater(function () { root.close(); });
    }
    onClosing: function (event) {
        if (closeApproved) return;
        if (session && session.quitCoordinator.busy) {event.accepted=false;return;}
        if (secondaryRow==="edit" && contentController.deferAction({kind:"windowClose"})) {event.accepted=false;return;}
        cancelErase();
        if (closeOperation || dialogs.closePromptVisible) {event.accepted=false;return;}
        dialogs.flushAnnotation();
        saveReadingPosition();
        if (hasPendingCloseWork(-1)) {
            event.accepted = false;
            closingTab = -1;
            pendingCloseReader=null;
            closeRetry.start();
            return;
        }
        if (hasUnsavedChanges(-1)) {
            event.accepted = false;
            dialogs.confirmClose(-1);
        }
    }
    function retryPendingClose() {
        if (closingTab === -2) return;
        const owner=pendingCloseReader;
        if (closingTab >= 0 && (!owner || readerIndex(owner)<0)) {closingTab=-2;pendingCloseReader=null;return;}
        if (closingTab < 0 ? hasPendingCloseWork(-1) : owner.pendingCommands>0) return;
        if (dialogs.annotationWriteError.length && (closingTab<0 || dialogs.noteReader === owner)) {
            operationStatus = dialogs.annotationWriteError;
            closingTab = -2;
            pendingCloseReader=null;
            return;
        }
        const index = closingTab<0 ? -1 : readerIndex(owner);
        closingTab = -2;
        pendingCloseReader=null;
        if (index < 0)
            root.close();
        else
            requestCloseTab(index);
    }
    Instantiator {
        model: root.session ? root.session.tabs : [
            {
                reader: root.currentReader
            }
        ]
        delegate: Connections {
            required property var modelData
            target: modelData.reader
            function onCommandFinished(id, operation, result, error) {
                root.closeCommandFinished(modelData.reader,id,operation,result,error);
            }
            function onCommandsChanged() {
                // Defer until the command's data/error notifications finish.
                // Unlike animation timers this also runs without frame callbacks.
                if (root.closingTab !== -2)
                    Qt.callLater(root.retryPendingClose);
                if (root.pendingDocumentSave)
                    Qt.callLater(root.finishDocumentSave);
                if (root.closeOperation)
                    Qt.callLater(root.advanceCloseOperation);
            }
        }
    }
    Timer {
        id: closeRetry
        interval: 80
        onTriggered: {
            if (root.closingTab === -2)
                return;
            root.retryPendingClose();
            if (root.closingTab !== -2) restart();
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
    onZoomChanged: if (eraserToken.length && !eraserCommitting) cancelErase()
    property real zoom: 1
    property bool fitting: true
    property string fitPreset: "width"
    readonly property real calibrationFactor: displayCalibration.factor
    readonly property real zoomPercent: zoom / calibrationFactor * 100
    property real previousCalibrationFactor: 1
    property bool calibrationReady: false
    DisplayCalibration {
        id: displayCalibration
        objectName: "displayCalibration"
        window: root
        onCalibrationChanged: {
            if (root.calibrationReady && root.currentReader.pageCount > 0) {
                if (root.fitting) root.refit();
                else root.changeZoom(root.zoom / root.previousCalibrationFactor * factor,
                                     pageList.width / 2, pageList.height / 2);
            }
            root.previousCalibrationFactor = factor;
        }
        Component.onCompleted: {
            root.previousCalibrationFactor = factor;
            root.calibrationReady = true;
        }
    }
    property bool sidebarVisible: true
    property int currentPage: 0
    onCurrentPageChanged: if (secondaryRow==="edit")contentController.reload()

    function navigate(page, y) {
        if (currentReader.pageCount === 0)
            return;
        page = Math.max(0, Math.min(currentReader.pageCount - 1, page));
        if (!textViewVisible) {
            canvas.navigate(page, y || 0);
            canvas.revealPage(page);
        }
        root.currentPage = page;
        if (textViewVisible)
            schedulePositionSave();
    }
    function changeZoom(value, anchorX, anchorY) {
        canvas.changeZoom(value, anchorX, anchorY);
    }

    function zoomBy(factor) {
        if (textViewVisible) {
            accessibleTextView.zoomBy(factor);
            return;
        }
        root.fitting = false;
        changeZoom(Math.max(25, Math.min(400, Math.round(zoomPercent) + (factor > 1 ? 10 : -10))) / 100 * calibrationFactor, pageList.width / 2, pageList.height / 2);
    }
    function actualSize() {
        fitting = false;
        changeZoom(calibrationFactor, pageList.width / 2, pageList.height / 2);
        operationStatus = displayCalibration.fallbackReason.length
            ? qsTr("100% · Uncalibrated display: ") + displayCalibration.fallbackReason
            : qsTr("Actual Size · 100%");
    }
    function applyFit(preset) {
        if (currentReader.pageCount === 0) return;
        const page = currentPage;
        const row = canvas.rows[canvas.pageRows[page]];
        if (!row || !row.pages.length) return;
        const left = Math.min.apply(null, row.pages.map(p => p.left));
        const right = Math.max.apply(null, row.pages.map(p => p.left + p.width));
        const extent = preset === "page" ? row.bottom - row.top : right - left;
        // Keep the native canvas' 32 point side margins; percentages round down.
        const available = preset === "page" ? pageList.height - 16 : pageList.width - 64;
        if (!(extent > 0 && available > 0)) return;
        const percent = Math.max(25, Math.min(400, Math.floor(available / extent / calibrationFactor * 100)));
        fitPreset = preset;
        changeZoom(percent / 100 * calibrationFactor, pageList.width / 2, 0);
        const rowCenter = (pageList.contentWidth - currentReader.documentWidth * zoom) / 2 + (left + right) / 2 * zoom;
        pageList.contentX = Math.max(0, Math.min(pageList.contentWidth - pageList.width, rowCenter - pageList.width / 2));
        if (preset === "page") navigate(page, 0);
        fitting = true;
    }
    function fitWidth() { applyFit("width"); }
    function fitPage() { applyFit("page"); }
    function refit() { applyFit(fitPreset); }
    function updateCurrentPage() {
        if (currentReader.pageCount > 0 && !textViewVisible && !overviewVisible && !canvas.positioning)
            root.currentPage = canvas.pageAtOffset();
    }

    function openDialog() {
        fileDialog.open();
    }
    function showSidebar(tab) {
        if (tab === "ai") { showAiPanel(true); return; }
        if (width < 1100) aiPanelVisible = false;
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
        positionTimer.stop();
        positionRestoring = true;
        ++positionRestoreEpoch;
        const state = session ? session.viewState(currentReader) : ({});
        pendingPosition = Object.assign({}, state);
        const recovered = currentReader.data.recovery ? currentReader.data.recovery.location : null;
        if (recovered && recovered.page !== undefined) {
            pendingPosition.page = recovered.page;
            selectedPages = recovered.selection || [];
            delete pendingPosition.offset;
            delete pendingPosition.viewportAnchor;
            delete pendingPosition.documentX;
        }
        if (requestedPage >= 0) {
            pendingPosition.page = requestedPage;
            pendingPosition.y = requestedY;
            delete pendingPosition.offset;
            delete pendingPosition.viewportAnchor;
            delete pendingPosition.documentX;
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
        if(placedTextController.deferAction(function(){root.pageClicked(page,x,y,sceneX,sceneY);}))return;
        currentPage = page;
        if (annotationTool === "signature" && pendingDrawnSignature) {
            if(pendingArtworkRequest>=0 || blockXfaWrite())return;
            if(pendingDrawnGeneration!==currentReader.documentGeneration){clearFillTool();operationStatus=qsTr("The document changed. Draw the signature again.");return;}
            const size=currentReader.pages[page],rules=currentReader.data.annotation_rules,signature=pendingDrawnSignature;
            if(!size || !rules || !Number.isFinite(rules.default_signature_height_pt) || rules.default_signature_height_pt<=0 || !Number.isFinite(rules.default_stroke_width_pt) || rules.default_stroke_width_pt<=0){operationStatus=qsTr("The document service did not provide valid placement defaults. Reopen the document.");return;}
            const height=Math.min(size.height,rules.default_signature_height_pt),width=Math.min(size.width,rules.default_signature_height_pt*signature.aspect);
            const left=Math.max(0,Math.min(size.width-width,x-width/2)),top=Math.max(0,Math.min(size.height-height,y-height/2));
            const paths=signature.strokes.map(function(path){return path.map(function(p){return {x:left+p.x*width,y:top+p.y*height};});});
            pendingArtworkRequest=currentReader.submit("mark_create",{entry:{kind:"ink",page:page,version:rules.geometry_version,paths:paths,rect:{x:left,y:top,width:width,height:height},strokeWidth:rules.default_stroke_width_pt,color:fillColour(),note:""}});
        } else if (annotationTool === "stamp" || annotationTool === "signature") {
            if (pendingArtworkRequest >= 0)
                return;
            const size = currentReader.pages[page];
            const style = pendingStampStyle;
            const image = pendingSignatureImage;
            if (!size || (annotationTool === "stamp" && !style.length) || (annotationTool === "signature" && !image))
                return;
            const signature = annotationTool === "signature";
            const rules=currentReader.data.annotation_rules;
            if (!rules || ![rules.default_signature_height_pt,rules.default_picture_height_pt,rules.default_stamp_height_pt,rules.default_stamp_width_pt].every(function(n){return Number.isFinite(n) && n>0;})) {
                operationStatus=qsTr("The document service did not provide valid placement defaults. Reopen the document.");return;
            }
            const picture=signature && fillTool==="image";
            const requestedHeight=signature ? (picture ? (fillImageSize==="small" ? 80 : fillImageSize==="large" ? 220 : rules.default_picture_height_pt) : rules.default_signature_height_pt) : rules.default_stamp_height_pt;
            const height = Math.min(size.height, requestedHeight);
            const width = Math.min(size.width, signature ? requestedHeight * Math.max(.2, Math.min(8, image.width / image.height)) : rules.default_stamp_width_pt);
            const words = {
                approved: "APPROVED",
                reviewed: "REVIEWED",
                draft: "DRAFT",
                confidential: "CONFIDENTIAL",
                date: Qt.formatDate(new Date(), "yyyy-MM-dd")
            };
            const colors = {
                approved: "#1B7F3BFF",
                reviewed: "#1F5FA8FF",
                draft: "#6B7280FF",
                confidential: "#B3261EFF",
                date: "#334155FF"
            };
            const entry = {
                kind: annotationTool,
                page: page,
                version: signature ? rules.signature_version : rules.stamp_version,
                rect: {
                    x: Math.max(0, Math.min(size.width - width, x - width / 2)),
                    y: Math.max(0, Math.min(size.height - height, y - height / 2)),
                    width: width,
                    height: height
                },
                color: signature ? "#000000FF" : colors[style],
                note: signature ? "" : words[style],
                stampStyle: signature ? (picture ? "image" : "signature") : style
            };
            if (signature)
                entry.image = image.image;
            pendingArtworkRequest = currentReader.submit("mark_create", {
                entry: entry
            });
        } else if (secondaryRow==="fill" && ["text","date","check","cross"].indexOf(fillTool)>=0) {
            if(pendingArtworkRequest>=0)return;
            const date=fillTool==="date";
            if(date && fillDateGeneration!==currentReader.documentGeneration){clearFillTool();operationStatus=qsTr("The document changed. Choose Date again.");return;}
            if(date && !refreshFillDate())return;
            const size=currentReader.pages[page],symbol=["check","cross"].indexOf(fillTool)>=0;
            if(date && fillDateRotation!==0) {
                const picture=currentReader.datePicture(fillText,fillDateRotation),rules=currentReader.data.annotation_rules;
                if(picture.error){operationStatus=picture.error;return;}
                if(!rules || !Number.isInteger(rules.signature_version)){operationStatus=qsTr("The document service did not provide a valid image schema. Reopen the document.");return;}
                const fit=Math.min(1,size.width/picture.widthPt,size.height/picture.heightPt),w=picture.widthPt*fit,h=picture.heightPt*fit;
                pendingArtworkRequest=currentReader.submit("mark_create",{entry:{kind:"signature",page:page,version:rules.signature_version,
                    rect:{x:Math.max(0,Math.min(size.width-w,x-w/2)),y:Math.max(0,Math.min(size.height-h,y-h/2)),width:w,height:h},
                    image:picture.image,stampStyle:"date",note:"",strokeWidth:0,color:"#000000ff"}});
                return;
            }
            const width=Math.min(size.width,date ? formattedFillDate.width : symbol ? 30 : 180),height=Math.min(size.height,date ? formattedFillDate.height : symbol ? 32 : 50);
            const left=Math.max(0,Math.min(size.width-width,x-(date ? width/2 : 0))),top=Math.max(0,Math.min(size.height-height,y-(date ? height/2 : 0)));
            if(symbol) {
                const paths=fillTool==="check" ? [[{x:left+3,y:top+15},{x:left+11,y:top+24},{x:left+27,y:top+4}]] :
                    [[{x:left+4,y:top+4},{x:left+26,y:top+26}],[{x:left+26,y:top+4},{x:left+4,y:top+26}]];
                pendingArtworkRequest=currentReader.submit("mark_create",{entry:{kind:"ink",page:page,version:1,paths:paths,strokeWidth:2.5,color:fillColour(),note:""}});
            } else {
                pendingArtworkRequest=currentReader.submit("mark_create",{entry:{kind:"textBox",page:page,version:1,
                    rect:{x:left,y:top,width:width,height:height},fontSize:date ? formattedFillDate.fontSize : fillFontSize,color:date ? "#000000ff" : fillColour(),note:fillText}});
                if(date)placedTextController.expectCreation(currentReader,pendingArtworkRequest);
            }
        } else if (annotationTool === "stickyNote" || annotationTool === "textBox") {
            if(placedTextController.waitingForCreation)return;
            const size = currentReader.pages[page];
            const rules=currentReader.data.annotation_rules;
            if(!rules || !Number.isInteger(rules.placed_text_version) || !Number.isFinite(rules.default_text_box_font_size_pt)) {
                operationStatus=qsTr("The document service did not provide valid text defaults. Reopen the document.");return;
            }
            const textBox=annotationTool==="textBox";
            const width = annotationTool === "stickyNote" ? 22 : Math.min(180, size.width);
            const height = annotationTool === "stickyNote" ? 22 : Math.min(60, size.height);
            const request=currentReader.submit("mark_create", {
                entry: {
                    kind: annotationTool,
                    page: page,
                    version: rules.placed_text_version,
                    rect: {
                        x: Math.max(0, Math.min(size.width - width, x)),
                        y: Math.max(0, Math.min(size.height - height, y)),
                        width: width,
                        height: height
                    },
                    fontSize: rules.default_text_box_font_size_pt,
                    color: textBox ? "#2B2B2EFF" : brushColor + "ff",
                    note: ""
                }
            });
            if(textBox) {
                annotationTool="select";
                placedTextController.expectCreation(currentReader,request,false);
            }
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
            viewportAnchor: canvas.viewportAnchor(0),
            offset: canvas.documentOffset(canvas.viewportAnchor(0)),
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
            if (location.viewportAnchor)
                canvas.navigate(location.viewportAnchor.page, location.viewportAnchor.y);
            else
                canvas.restoreDocumentOffset(location.offset);
            root.currentPage = location.page;
            pageList.contentX = location.x;
            fitting = location.fitting;
        });
    }
    Connections {
        target: root.previewController
        function onChanged() {
            root.previewStatus = "";
        }
        function onStatusMessage(message) {
            root.previewStatus = message;
        }
        function onNavigateRequested(page, y) {
            root.jumpFromPreview(page, y);
        }
    }
    function showMergeDialog() {
        if (blockXfaWrite()) return;
        pageExports.show(true);
    }
    function showSplitDialog() {
        if (blockXfaWrite()) return;
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
        const hit=annotationAt(page,x/zoom,y/zoom,false);
        selectedAnnotation=hit || null;
        const point = item.mapToItem(Overlay.overlay, x, y);
        dialogs.selectionMenu.x = point.x;
        dialogs.selectionMenu.y = point.y;
        dialogs.selectionMenu.open();
    }
    function showAnnotationProperties() {
        const selected=selectedAnnotation;
        if(!selected)return;
        if(placedTextController.deferAction(function(){
            root.selectedAnnotation=root.annotations.find(function(a){return a.id===selected.id;}) || null;
            root.showAnnotationProperties();
        }))return;
        dialogs.showAnnotation();
    }
    function showExportMenu(item) {
        const point = item.mapToItem(Overlay.overlay, 0, item.height);
        dialogs.exportMenu.x = point.x;
        dialogs.exportMenu.y = point.y;
        dialogs.exportMenu.open();
    }
    Component {id:pdfPreviewFactory;PdfPreviewWindow {}}
    function showPdfPreviewWindow() {
        if(!previewController || !previewController.visible)return null;
        const target=previewController.model;
        const window=pdfPreviewFactory.createObject(root,{app:root});
        if(!window){operationStatus=qsTr("The PDF preview window could not be created.");return null;}
        window.previewReader=previewController.createWindowReader(window);
        window.requestedPage=target.page;window.targetRegion=target.region || ({});
        if(!window.previewReader || !window.open()){window.destroy();operationStatus=qsTr("The PDF preview window could not be opened.");return null;}
        previewController.close();return window;
    }
    Connections {
        target:root.previewController
        function onWindowRequested(){root.showPdfPreviewWindow();}
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
        if (blockXfaWrite()) return;
        if(secondaryRow!=="fill")setSecondaryRow("fill");
        setTextViewEnabled(false);
        formToolActive = !formToolActive;
        if (formToolActive)
            currentReader.submit("forms");
    }
    function selectAnnotation(annotation, edit) {
        if(placedTextController.deferAction(function(){root.selectAnnotation(annotation,edit);}))return;
        dialogs.flushAnnotation();
        if (edit === false)
            dialogs.annotationDialog.close();
        if (xfaReadOnly) {
            selectedAnnotation=annotation;
            if (edit !== false) dialogs.showAnnotation();
            operationStatus=readOnlyReason;
            return;
        }
        const reason = Logic.annotationUnsupportedReason(annotation);
        if (reason.length) {
            selectedAnnotation = annotation;
            operationStatus = reason;
            dialogs.showAnnotation();
        } else if (annotation.foreign) {
            if(edit!==false && annotation.kind==="textBox")dialogs.annotationDialog.close();
            const request=currentReader.submit("file_adopt", {
                id: annotation.id
            });
            selectedAnnotation = annotation;
            if(edit!==false && annotation.kind==="textBox")placedTextController.expectCreation(currentReader,request,false,false);
        } else {
            selectedAnnotation = annotation;
            if (edit !== false) {
                if(annotation.kind==="textBox") {
                    dialogs.annotationDialog.close();annotationTool="select";
                    placedTextController.openExisting(annotation);
                } else dialogs.showAnnotation();
            }
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
                yPt: canvas.pageOffset(currentPage)
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
        if(placedTextController.deferAction(function(){root.setAnnotationTool(tool);}))return;
        if (tool !== "select" && blockXfaWrite()) return;
        annotationTool = annotationTool === tool ? "select" : tool;
        if (["highlight", "underline", "strikeout"].indexOf(annotationTool) >= 0 && selection)
            markSelection(annotationTool);
    }
    property double pendingArtworkRequest: -1
    function armStamp(style) {armStampForRow(style,"fill");}
    function armStampForRow(style,row) {
        if (blockXfaWrite()) return;
        if (currentReader.pageCount === 0 || ["approved", "reviewed", "draft", "confidential", "date"].indexOf(style) < 0)
            return;
        setTextViewEnabled(false);
        overviewVisible = false;
        formToolActive = false;
        const target=row==="annotate" ? "annotate" : "fill";
        setSecondaryRow(target);
        if (secondaryRow!==target) return;
        fillTool=target==="fill" ? "stamp" : "";
        annotationTool = "stamp";
        pendingStampStyle = style;
        selectedAnnotation = null;
        selection = null;
        operationStatus = qsTr("Click on the page to place the stamp. Escape cancels.");
    }
    function armSignature(url) {return armImage(url,false);}
    function armPicture(url) {return armImage(url,true);}
    function armImage(url,picture) {
        if (blockXfaWrite()) return false;
        if (currentReader.pageCount === 0)
            return false;
        const image = currentReader.signatureImage(url);
        return armImageData(image,!!picture);
    }
    function armSignatureData(image) {return armImageData(image,false);}
    function armDrawnSignature(signature) {
        if(blockXfaWrite() || currentReader.pageCount===0 || !signature || !Number.isFinite(signature.aspect) || signature.aspect<.3 || signature.aspect>6 || !signature.strokes || !signature.strokes.length)return false;
        setTextViewEnabled(false);overviewVisible=false;formToolActive=false;setSecondaryRow("fill");
        if(secondaryRow!=="fill")return false;
        fillTool="signature";annotationTool="signature";pendingSignatureImage=null;pendingDrawnSignature=signature;pendingDrawnGeneration=currentReader.documentGeneration;selectedAnnotation=null;selection=null;
        operationStatus=qsTr("Click on the page to place the drawn signature. Escape cancels.");return true;
    }
    function armImageData(image,picture) {return armImageDataForRow(image,picture,"fill");}
    function armImageDataForRow(image,picture,row) {
        if (blockXfaWrite() || currentReader.pageCount===0) return false;
        if (!image || (!image.error && (!image.image || !Number.isFinite(image.width) || !Number.isFinite(image.height) || image.width<=0 || image.height<=0))) {
            operationStatus=qsTr("The signature preview is unavailable.");return false;
        }
        if (image.error) {
            operationStatus = image.error;
            return false;
        }
        setTextViewEnabled(false);
        overviewVisible = false;
        formToolActive = false;
        const target=row==="annotate" ? "annotate" : "fill";
        setSecondaryRow(target);
        if (secondaryRow!==target) return false;
        fillTool=target==="fill" ? (picture ? "image" : "signature") : "";
        annotationTool = "signature";
        pendingSignatureImage = image;
        pendingDrawnSignature = null;
        selectedAnnotation = null;
        selection = null;
        operationStatus = picture ? qsTr("Click on the page to place the picture. Escape cancels.") : qsTr("Click on the page to place the signature image. Escape cancels.");
        return true;
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
        if (blockXfaWrite()) return;
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
        const selected=selectedAnnotation;
        if(selected && placedTextController.deferAction(function(){
            root.selectedAnnotation=root.annotations.find(function(a){return a.id===selected.id;}) || null;
            root.updateSelectedAnnotation(patch);
        }))return -1;
        if (blockXfaWrite()) return -1;
        if (selectedAnnotation && !selectedAnnotation.foreign)
            return currentReader.submit("mark_update", {
                id: selectedAnnotation.id,
                patch: patch
            });
        return -1;
    }
    function commitAnnotationGeometry(id, patch) {
        if (blockXfaWrite()) return;
        if (!annotationDraft || annotationDraft.id !== id)
            return;
        if(placedTextController.deferAction(function(){root.pendingDraftRequestId=root.currentReader.submit("mark_update",{id:id,patch:patch});}))return;
        pendingDraftRequestId = currentReader.submit("mark_update", {
            id: id,
            patch: patch
        });
    }
    function updateAnnotationNote(note) {
        updateSelectedAnnotation({note:note});
    }
    function deleteSelectedAnnotation() {
        const selected=selectedAnnotation;
        if(selected && placedTextController.deferAction(function(){
            root.selectedAnnotation=root.annotations.find(function(a){return a.id===selected.id;}) || null;
            root.deleteSelectedAnnotation();
        }))return;
        if (blockXfaWrite()) return;
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
    property var erasePreview: []
    property string eraserToken: ""
    property var eraserOwner: null
    property int eraserSequence: 0
    property double eraserPending: -1
    property var eraserQueue: []
    property bool eraserFinishing: false
    property bool eraserCommitting: false
    function cancelErase() {
        if (eraserToken.length && eraserOwner && !eraserCommitting)
            eraserOwner.submit("ink_erase_cancel", { token: eraserToken });
        eraserToken = "";
        eraserOwner = null;
        eraserPending = -1;
        eraserQueue = [];
        eraserFinishing = false;
        eraserCommitting = false;
        eraseDraft = [];
        erasePreview = [];
    }
    function beginErase(page, point) {
        if (blockXfaWrite()) return;
        cancelErase();
        dialogs.flushAnnotation();
        selectedAnnotation = null;
        selection = null;
        eraserOwner = currentReader;
        eraserToken = "erase-" + (++eraserSequence) + "-" + Date.now();
        eraserPending = eraserOwner.submit("ink_erase_begin", {
            token: eraserToken, page: page, zoom: zoom,
            segments: canvas.eraserSegments(page, point, point)
        });
    }
    function eraseAlong(page, start, end) {
        if (!eraserToken.length || eraserFinishing)
            return;
        // Release at the last sampled point adds no swept area. Avoid a redundant circle
        // changing a fractional cut boundary through a second numerical intersection.
        if (Math.abs(start.x - end.x) < 1e-9 && Math.abs(start.y - end.y) < 1e-9)
            return;
        if (eraserQueue.length >= 4096) {
            cancelErase();
            operationStatus = qsTr("The eraser is busy. Try a shorter stroke; no cut was saved.");
            return;
        }
        eraserQueue = eraserQueue.concat(canvas.eraserSegments(page, start, end));
        flushErase();
    }
    function flushErase() {
        if (!eraserToken.length || !eraserOwner || eraserPending >= 0)
            return;
        if (eraserQueue.length) {
            const batch = eraserQueue.slice(0, 512);
            eraserQueue = eraserQueue.slice(512);
            eraserPending = eraserOwner.submit("ink_erase_preview", {token: eraserToken, segments: batch});
        } else if (eraserFinishing) {
            eraserCommitting = true;
            eraserPending = eraserOwner.submit("ink_erase_commit", {token: eraserToken, segments: []});
        }
    }
    function commitErase() {
        if (!eraserToken.length)
            return;
        eraserFinishing = true;
        flushErase();
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
        if(placedTextController.deferAction(function(){root.pageOperation(operation);}))return;
        if (blockXfaWrite()) return;
        if (pageEditBusy)
            return;
        pageEditBusy = true;
        pendingPage = currentPage;
        pendingPageSelection = selectedPages.slice();
        currentReader.submit("page_stage", {
            operation: operation,
            current_page: currentPage,
            selected_pages: selectedPages
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
        if(placedTextController.deferAction(function(){root.undo();}))return;
        if (secondaryRow==="edit" && contentController.deferAction({kind:"undo"})) return;
        if (markState.can_undo)
            currentReader.submit("marks_undo");
        else if (markState.can_page_undo) {
            pendingPage = currentPage;
            currentReader.submit("page_undo", {current_page: currentPage, selected_pages: selectedPages});
        }
    }
    function redo() {
        if(placedTextController.deferAction(function(){root.redo();}))return;
        if (secondaryRow==="edit" && contentController.deferAction({kind:"redo"})) return;
        if (markState.can_redo)
            currentReader.submit("marks_redo");
        else if (markState.can_page_redo) {
            pendingPage = currentPage;
            currentReader.submit("page_redo", {current_page: currentPage, selected_pages: selectedPages});
        }
    }
    property bool printRequested: false
    function printDocument() {
        if(placedTextController.deferAction(function(){root.printDocument();}))return;
        if (secondaryRow==="edit" && contentController.deferAction({kind:"print"})) return;
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
    property var pendingSavePosition: null
    property var pendingDocumentSave: null
    function saveDocument(copy) {
        if(placedTextController.deferAction(function(){root.saveDocument(copy);}))return;
        if (secondaryRow==="edit" && contentController.deferAction({kind:"save",value:!!copy})) return;
        if (closeOperation || pendingDocumentSave) return;
        if (xfaReadOnly) {operationStatus=currentReader.data.xfa_status.read_only_reason;return;}
        if (pendingRedactions.length) {
            operationStatus = qsTr("Finish or clear the content redaction before saving.");
            return;
        }
        saveReadingPosition();
        pendingDocumentSave = {reader:currentReader,revision:currentReader.data.document_revision,copy:!!copy || originalReadOnly,forms:formPayload(),page:currentPage,selection:selectedPages.slice(),position:session ? session.viewState(currentReader) : {page:currentPage,zoom:zoom,fitting:fitting}};
        dialogs.flushAnnotation();
        finishDocumentSave();
    }
    function finishDocumentSave() {
        const context=pendingDocumentSave;
        if (!context || !context.reader || context.reader.pendingCommands > 0) return;
        pendingDocumentSave=null;
        if (Object.keys(context.reader.noteDrafts).length) {
            operationStatus=qsTr("The annotation note could not be saved. Retry or discard the note before saving the document.");
            return;
        }
        if (context.copy) {
            exportKind="document";
            exportContext={reader:context.reader,revision:context.revision,kind:"document",forms:context.forms};
            dialogs.saveDialog.open();
        } else {
            pendingSavePosition={reader:context.reader,position:context.position};
            if (context.reader===currentReader) {pendingPage=context.page;pendingPageSelection=context.selection;}
            context.reader.submit("document_save",{forms:context.forms,current_page:context.page,selected_pages:context.selection,expected_revision:context.revision});
        }
    }
    function exportActionReason(action) {
        if(!currentReader.pageCount || currentReader.loading)return qsTr("Open a PDF first.");
        if(action==="print")return "";
        if(action==="annotations")return annotations.length ? "" : qsTr("This document has no annotations to export.");
        if(xfaReadOnly)return readOnlyReason || qsTr("XFA forms are read-only.");
        if(pageEditBusy || pendingDocumentSave || currentReader.pendingCommands>0)return qsTr("Wait for the current document operation to finish.");
        if(action==="save" && !currentReader.hasUnsavedChanges)return qsTr("The document has no unsaved changes.");
        if(action==="flattened") {
            const info=currentReader.data.document_info;
            if(!info)return qsTr("Reading the document's export options…");
            if(info.is_encrypted)return qsTr("Flattened copies are unavailable for encrypted PDFs.");
        }
        if(action==="filledForm" || action==="formValues") {
            const forms=currentReader.data.forms;
            if(!forms)return qsTr("Reading the document's form options…");
            if(forms.encrypted)return qsTr("Form exports are unavailable for encrypted PDFs.");
            if(!formPayload().length)return qsTr("There are no pending form values to write.");
            if(action==="formValues" && originalReadOnly)return readOnlyReason || qsTr("Signed originals are read-only. Save a copy instead.");
            if(action==="formValues" && pageEditsPending)return qsTr("Save the page or content changes before replacing form values in the original.");
            if(action==="formValues" && (markState.pdf_dirty || Object.keys(currentReader.noteDrafts).length || currentReader.editDrafts.content || pendingRedactions.length))
                return qsTr("Save the other document changes before writing only form values to the original.");
        }
        return "";
    }
    function performExportAction(action) {
        const reason=exportActionReason(action);
        if(reason.length){operationStatus=reason;return;}
        if(action==="save")saveDocument(false);
        else if(action==="saveAs")saveDocument(true);
        else if(action==="annotated")chooseExport("annotations");
        else if(action==="flattened")dialogs.showFlattenNotice();
        else if(action==="filledForm")chooseExport("forms");
        else if(action==="formValues")confirmReplace("forms");
        else if(action==="annotations")chooseExport("annotation-text");
        else if(action==="print")printDocument();
    }
    function setAnnotationExportFormat(index) {
        if(!exportContext || exportContext.kind!=="annotation-text")return;
        if(index!==0 && index!==1)return;
        const kind=index===1 ? "csv" : "markdown";
        exportContext=Object.assign({},exportContext,{kind:kind,text:exportContext.textOptions[kind]});
    }
    function chooseExport(kind) {
        if(placedTextController.deferAction(function(){root.chooseExport(kind);}))return;
        if (secondaryRow==="edit" && contentController.deferAction({kind:"export",value:kind})) return;
        if (["bibtex","markdown","csv","annotation-text"].indexOf(kind)<0 && blockXfaWrite()) return;
        exportKind = kind;
        exportContext = {
            reader: currentReader,
            kind: kind,
            generation: currentReader.documentGeneration,
            textOptions: kind==="annotation-text" ? {markdown:annotationExport("markdown"),csv:annotationExport("csv")} : null,
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
        if (blockXfaWrite()) return;
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
        if(context.generation!==undefined && context.generation!==owner.documentGeneration) {
            operationStatus=qsTr("The document changed. Choose the export again.");exportContext=null;return;
        }
        if(context.kind==="annotation-text") {
            operationStatus=qsTr("Choose Markdown or CSV before exporting annotation text.");return;
        }
        exportContext=null;
        const destination = session.localPath(url);
        if (context.kind === "document")
            {
                const args=Object.assign({destination:destination,forms:context.forms},context.revision ? {expected_revision:context.revision} : {});
                if (context.closeTicket && context.closeTicket === closeOperation) closeCommand(context.closeTicket,"save_document_copy",args);
                else owner.submit("save_document_copy",args);
            }
        else if (context.kind === "redactions")
            owner.submit("save_redactions", {
                destination: destination,
                areas: context.redactions
            });
        else if (context.kind === "properties")
            owner.submit("save_properties", Object.assign({
                destination: destination
            }, context.properties));
        else if (context.kind === "flattened")
            owner.submit("save_flattened_copy",{destination:destination});
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
    property var replacementContext: null
    function confirmReplace(kind) {
        if(placedTextController.deferAction(function(){root.confirmReplace(kind);}))return;
        if(secondaryRow==="edit" && contentController.deferAction({kind:"replace",value:kind}))return;
        if (blockXfaWrite()) return;
        if (originalReadOnly) {
            operationStatus = readOnlyReason;
            return;
        }
        if(kind==="forms") {
            const reason=exportActionReason("formValues");
            if(reason.length){operationStatus=reason;return;}
        }
        replacementContext={reader:currentReader,generation:currentReader.documentGeneration,kind:kind,
            forms:formPayload(),properties:kind==="properties" ? dialogs.informationDialog.draft() : null};
        dialogs.confirmReplacement(kind);
    }
    function performReplace(kind) {
        const context=replacementContext;replacementContext=null;
        if(!context || context.kind!==kind || context.reader!==currentReader || context.generation!==currentReader.documentGeneration) {
            operationStatus=qsTr("The document changed. Review the replacement again.");return;
        }
        if (blockXfaWrite()) return;
        if (originalReadOnly) {
            operationStatus = readOnlyReason;
            return;
        }
        dialogs.flushAnnotation();
        dialogs.annotationDialog.close();
        if (kind === "pages")
            currentReader.submit("page_apply");
        else if (kind === "properties")
            currentReader.submit("replace_properties", context.properties);
        else if (kind === "forms") {
            const reason=exportActionReason("formValues");
            if(reason.length){operationStatus=reason;return;}
            if(JSON.stringify(context.forms)!==JSON.stringify(formPayload())) {
                operationStatus=qsTr("The form values changed. Review the replacement again.");return;
            }
            // The unified save owns the source/cache identity change and reopening,
            // including when this reader is no longer the active tab on completion.
            saveDocument(false);
        }
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
        const base=aiSettings.baseUrl || "";
        if(base!==credentialSessionBaseUrl){
            credentialSessionBaseUrl=base;
            if(session)session.credentials.clearSession();
        }
        credentialReadId=-1;pendingAiReader=null;pendingAiPlan=null;
        if (session)
            for (const tab of session.tabs)
                tab.reader.invalidateAiPlan();
        else if (currentReader)
            currentReader.invalidateAiPlan();
    }
    property int requestedPage: -1
    property real requestedY: 0
    property double credentialReadId: -1
    property string credentialSessionBaseUrl: ""
    property var pendingAiReader: null
    property var pendingAiPlan: null

    Action {
        objectName: "toggleAiPanelAction"
        text: qsTr("AI Assistant")
        shortcut: "Ctrl+Shift+A"
        enabled: currentReader.pageCount > 0
        onTriggered: root.showAiPanel(!root.aiPanelVisible)
    }
    Action {
        id: openAction
        text: qsTr("Open PDF…")
        shortcut: StandardKey.Open
        onTriggered: fileDialog.open()
    }
    Action {
        id: saveDocumentAction
        objectName: "saveDocumentAction"
        text: qsTr("Save")
        shortcut: StandardKey.Save
        enabled: currentReader.pageCount > 0 && currentReader.pendingCommands === 0 && !root.positionRestoring && !root.xfaReadOnly && !root.closeOperation && !root.pendingDocumentSave && (currentReader.hasUnsavedChanges || root.originalReadOnly)
        onTriggered: root.saveDocument()
    }
    Action {
        id: saveDocumentAsAction
        objectName: "saveDocumentAsAction"
        text: qsTr("Save As…")
        shortcut: StandardKey.SaveAs
        enabled: currentReader.pageCount > 0 && currentReader.pendingCommands === 0 && !root.positionRestoring && !root.xfaReadOnly && !root.closeOperation && !root.pendingDocumentSave
        onTriggered: root.saveDocument(true)
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
            root.actualSize();
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
        onTriggered: root.setTextViewEnabled(!root.textViewVisible)
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
        onActivated: root.focusSearch()
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
            root.selectReaderTab((root.session.activeIndex + 1) % root.session.tabs.length)
    }
    function focusSearch() {
        if (secondaryRow==="edit" && contentController.deferAction({kind:"search"})) return;
        if (editInspectorVisible || fillInspectorVisible) setSecondaryRow("",true);
        searchVisible=true;
        Qt.callLater(function(){const field=findSearchField();if(field)field.forceActiveFocus();});
    }
    function findSearchField() {
        return chromeSearchField && chromeSearchField.visible ? chromeSearchField : searchPane.field;
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
            if(placedTextController.waitingForCreation)placedTextController.cancelPendingCreation();
            if(placedTextController.current){placedTextController.finish(true);return;}
            if(contentController.inlineEditing && contentController.textDraft){contentController.discard();return;}
            root.cancelTabReorder();
            if (root.previewController && root.previewController.visible)
                root.previewController.close();
            root.cancelErase();
            root.clearFillTool();
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
            MenuItem { action: saveDocumentAction }
            MenuItem { action: saveDocumentAsAction }
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
                onTriggered: root.sidebarVisible = !root.sidebarVisible
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
                    textFormat: Text.PlainText
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
        SecondaryTools {
            id:secondaryTools
            objectName:"secondaryTools"
            app:root
            visible:root.secondaryRow.length>0 && currentReader.pageCount>0 && !root.overviewVisible && !root.textViewVisible
            Layout.fillWidth:true
            Layout.preferredHeight:46
            Layout.minimumHeight:46
            Layout.maximumHeight:46
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
                visible: root.sidebarVisible && currentReader.pageCount > 0 && !(root.searchVisible && root.width < 950) && !((root.aiPanelVisible || root.editInspectorVisible || root.fillInspectorVisible) && root.width < 1100)
                Layout.preferredWidth: root.width < 850 ? 210 : 246
                Layout.fillHeight: true
            }

            Rectangle {
                visible: root.sidebarVisible && currentReader.pageCount > 0 && !(root.searchVisible && root.width < 950) && !((root.aiPanelVisible || root.editInspectorVisible || root.fillInspectorVisible) && root.width < 1100)
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
            ContentInspector {
                objectName:"contentInspector";app:root;visible:root.editInspectorVisible
                Layout.preferredWidth:Math.min(310,root.width*.4);Layout.fillHeight:true
            }
            FillSignInspector {
                objectName:"fillSignInspector";app:root;visible:root.fillInspectorVisible
                Layout.preferredWidth:Math.min(310,root.width*.4);Layout.fillHeight:true
            }
            SearchPanel {
                id:searchPane
                objectName: "searchPanel"
                app: root
                visible: root.searchVisible && currentReader.pageCount > 0 && !root.editInspectorVisible && !root.fillInspectorVisible
                Layout.preferredWidth: Math.min(280, root.width / 3)
                Layout.fillHeight: true
            }
            Pane {
                id: aiDock
                objectName: "aiDock"
                visible: root.aiPanelVisible && currentReader.pageCount > 0
                padding: 0
                Layout.minimumWidth: 280
                Layout.maximumWidth: Math.min(520, Math.max(280, root.width - 360))
                Layout.preferredWidth: Math.min(root.aiPanelWidth, Layout.maximumWidth)
                Layout.fillHeight: true
                background: Rectangle { color: theme.sidebarBg }
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 14
                        Layout.rightMargin: 8
                        Label { text: qsTr("AI Assistant"); color: theme.textPrimary; font.weight: Font.DemiBold; Layout.fillWidth: true }
                        LyraToolButton {
                            objectName: "closeAiPanel"
                            symbol: "close"
                            text: qsTr("Close AI panel (Ctrl+Shift+A)")
                            onClicked: root.showAiPanel(false)
                        }
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: theme.separator }
                    AiPanel { app: root; Layout.fillWidth: true; Layout.fillHeight: true }
                }
                Rectangle {
                    width: 1; height: parent.height; color: theme.separator
                }
                MouseArea {
                    objectName: "aiPanelResizeHandle"
                    anchors.left: parent.left
                    width: 6; height: parent.height
                    cursorShape: Qt.SizeHorCursor
                    activeFocusOnTab: true
                    Accessible.name: qsTr("Resize AI panel; Left widens, Right narrows")
                    property real pressedX: 0
                    property real initialWidth: 0
                    onPressed: function(mouse) {
                        pressedX = mapToItem(root.contentItem, mouse.x, mouse.y).x;
                        initialWidth = aiDock.width;
                    }
                    onPositionChanged: function(mouse) {
                        if (pressed) root.resizeAiPanel(initialWidth + pressedX - mapToItem(root.contentItem, mouse.x, mouse.y).x, false);
                    }
                    onReleased: root.resizeAiPanel(root.aiPanelWidth, true)
                    Keys.onLeftPressed: root.resizeAiPanel(root.aiPanelWidth + 20, true)
                    Keys.onRightPressed: root.resizeAiPanel(root.aiPanelWidth - 20, true)
                }
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
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                objectName: "operationStatusLabel"
                text: root.previewStatus || root.operationStatus
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
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
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
            root.refit()
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
                    if(error.length){root.pendingAiReader=null;root.pendingAiPlan=null;}
                    else dialogs.credentialDialog.open();
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
            if(placedTextController.waitingForCreation)placedTextController.suppressPendingEditor();
            dialogs.flushAnnotation();
            dialogs.annotationDialog.close();
            root.saveReadingPosition();
        }
    }
    Connections {
        target: root.currentReader
        function onDocumentReset() {
            root.cancelErase();
            ++root.positionRestoreEpoch;
            root.positionRestoring = true;
            root.selection = null;
            root.selectedAnnotation = null;
            root.annotationDraft = null;
            root.redactionDraft = null;
            root.metadataDraft = null;
            root.infoData = {};
        }
        function onOpenFinished(success) {
            if (success) {
                root.restorePosition();
                if (root.formToolActive)
                    currentReader.submit("forms");
            }
        }
        function onCommandFinished(id, op, result, error) {
            const artworkPlacement=id===root.pendingArtworkRequest;
            if (op.indexOf("ink_erase_") === 0) {
                if (id !== root.eraserPending || !root.eraserToken.length)
                    return;
                root.eraserPending = -1;
                if (error.length || result.cancelled) {
                    root.cancelErase();
                    if (error.length) root.operationStatus = error;
                    return;
                }
                if (op === "ink_erase_commit") {
                    const changed = result.erase_changed || 0;
                    const refused = (result.erase_refused || []).length;
                    root.cancelErase();
                    root.operationStatus = changed ? qsTr("Cut %1 ink strokes into %2 pieces.").arg(changed).arg(result.erase_pieces || 0) : qsTr("No ink was changed.");
                    if (changed) root.operationStatus += " " + (result.erase_requires_pdf_save ? qsTr("PDF ink cuts are staged. Save to PDF to keep them; Discard and Close restores the original ink.") : qsTr("Saved in the application cache; the PDF on disk is unchanged."));
                    if (refused) root.operationStatus += " " + qsTr("Left %1 protected PDF ink strokes unchanged. Comments and reply threads are preserved.").arg(refused);
                } else {
                    root.eraseDraft = result.hidden || [];
                    root.erasePreview = result.annotations || [];
                    if ((result.refused || []).length)
                        root.operationStatus = qsTr("Protected PDF ink remains unchanged to preserve comments and reply threads.");
                    root.flushErase();
                }
                return;
            }
            if (id === root.pendingArtworkRequest) {
                root.pendingArtworkRequest = -1;
                if (!error.length) {
                    root.clearFillTool();
                    root.operationStatus = qsTr("Placement cached. Save writes it into the PDF.");
                }
            }
            if ((op.indexOf("page_") === 0 && op !== "page_operation") || op === "content_stage" || op === "document_save" || op === "document_discard") {
                root.pageEditBusy = false;
                if (!error.length) {
                    const map = result.report ? result.report.page_map : null;
                    const location = result.marks ? result.marks.page_location : null;
                    const page = location ? location.page : (map && map[root.pendingPage] !== null && map[root.pendingPage] !== undefined ? map[root.pendingPage] : Math.min(root.pendingPage, currentReader.pageCount - 1));
                    root.selection = null;
                    root.selectedAnnotation = null;
                    root.searchResults = [];
                    root.selectedPages = location ? location.selection : (map ? root.pendingPageSelection.map(function (p) {
                        return map[p];
                    }).filter(function (p) {
                        return p !== null && p !== undefined;
                    }) : [page]);
                    root.pendingPosition = op === "document_save" && root.pendingSavePosition && root.pendingSavePosition.reader === currentReader ? root.pendingSavePosition.position : {
                        page: result.report && result.report.inserted_page !== null && result.report.inserted_page !== undefined ? result.report.inserted_page : page,
                        zoom: root.zoom,
                        fitting: root.fitting
                    };
                    currentReader.setLayout(root.layoutMode, root.pageGap);
                    root.pendingSavePosition = null;
                    root.operationStatus = op === "document_save" ? qsTr("Document saved. Verified backup: %1").arg(result.report.backup_path || "") : (op === "page_apply" ? qsTr("Page changes applied. Backup: %1").arg(result.report.backup_path || "") : qsTr("Page session updated; original unchanged."));
                    const warning = result.report ? (result.report.recovery_warning || result.report.cache_cleanup_error || result.report.sidecar_error) : null;
                    if (warning) root.operationStatus += " " + warning;
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
                    const inlineText=placedTextController.owner===root.currentReader && (placedTextController.creationRequest===id || (placedTextController.active && placedTextController.entry.id===result.selected_id));
                    // A first click adopts/selects FreeText. Opening the legacy property
                    // dialog here would intercept the second click of a real double-click.
                    const selectedFreeText=op==="file_adopt" && root.selectedAnnotation && root.selectedAnnotation.kind==="textBox";
                    if (!selectedFreeText && !inlineText && !artworkPlacement && root.secondaryRow!=="fill" && root.selectedAnnotation && (root.selectedAnnotation.kind === "stickyNote" || root.selectedAnnotation.kind === "textBox"))
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
                    root.positionRestoring = true;
                    positionTimer.stop();
                    const state = root.pendingPosition;
                    const epoch = root.positionRestoreEpoch;
                    root.pendingPosition = null;
                    if (state.zoom && !state.fitting) {
                        root.fitting = false;
                        root.zoom = state.zoomPercent ? state.zoomPercent / 100 * root.calibrationFactor : state.zoom;
                    } else {
                        root.currentPage = Math.max(0, Math.min(currentReader.pageCount - 1, state.page || 0));
                        root.fitPreset = state.fitPreset === "page" ? "page" : "width";
                        root.refit();
                    }
                    Qt.callLater(function () {
                        if (epoch !== root.positionRestoreEpoch)
                            return;
                        root.navigate(state.page || 0, state.y || 0);
                        if (state.viewportAnchor)
                            canvas.navigate(state.viewportAnchor.page, state.viewportAnchor.y);
                        else if (state.offset !== undefined)
                            canvas.restoreDocumentOffset(state.offset);
                        if (state.documentX !== undefined)
                            canvas.restoreDocumentX(state.documentX);
                        else
                            canvas.revealPage(state.page || 0);
                        root.currentPage = state.page || 0;
                        root.positionRestoring = false;
                        root.schedulePositionSave();
                    });
                } else if (root.fitting)
                    root.refit();
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
                root.operationStatus = qsTr("Wrote %1 verified split PDFs with their application caches.").arg(result.parts.length);
            else if (op === "save_redactions") {
                root.annotationTool = "select";
                root.operationStatus = qsTr("Verified redacted copy saved: %1 · %2 characters removed.").arg(result.destination_path).arg(result.removed_characters);
            } else if (op === "save_content_image") {
                root.operationStatus=qsTr("Image exported to %1").arg(result.destination_path);
                if(result.publication_warning)root.operationStatus+=" · "+result.publication_warning;
            } else if (op==="save_flattened_copy") {
                root.operationStatus=qsTr("Flattened copy saved: %1 · %2 annotations and %3 fields painted; %4 annotations and %5 fields kept. Original unchanged.").arg(result.destination_path).arg(result.flattened_annotations).arg(result.flattened_fields).arg(result.kept_annotations.length).arg(result.kept_fields.length);
                if(result.comments_not_carried)root.operationStatus+=" "+qsTr("Comments not carried: %1.").arg(result.comments_not_carried);
                if(result.signature_fields_removed)root.operationStatus+=" "+qsTr("Signature fields removed: %1.").arg(result.signature_fields_removed);
            } else if (op.indexOf("save_") === 0) {
                root.operationStatus = qsTr("Saved to %1").arg(result.destination_path || "");
                if (result.cache_cleanup_error) root.operationStatus += " " + result.cache_cleanup_error;
            } else if (op.indexOf("replace_") === 0) {
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

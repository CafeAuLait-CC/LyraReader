import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import LyraReader 1.0
import "ReaderLogic.js" as Logic

Item {
    id: dialogs
    required property var app
    property alias settingsDialog: settings
    property alias informationDialog: information
    property alias formsDialog: forms
    property alias annotationDialog: annotation
    property alias credentialDialog: credential
    property alias selectionMenu: selection
    property alias exportMenu: exports
    property alias saveDialog: save
    property int closeIndex: -1
    property var closeReader: null
    readonly property bool closePromptVisible: closeConfirmation.visible
    readonly property bool tabTransferDialogVisible: closeConfirmation.visible || flattenNotice.visible || replaceConfirmation.visible || sidecarRecovery.visible || bookmarkEditor.visible || deletePages.visible || discardPages.visible || save.visible || settings.visible || information.visible || forms.visible || annotation.visible || annotationColor.visible || credential.visible
    function confirmClose(index) {
        closeIndex = index;
        closeReader=app.closeTarget(index);
        if (!closeReader) return;
        closeConfirmation.open();
    }
    Dialog {
        id: closeConfirmation
        objectName: "closeChangesConfirmation"
        width: Math.min(480, Math.max(240, app.width - 48))
        title: qsTr("Unsaved Changes")
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Save | Dialog.Discard | Dialog.Cancel
        onOpened: standardButton(Dialog.Save).text=app.closeNeedsReview(dialogs.closeReader) ? qsTr("Review") : qsTr("Save")
        Label {
            textFormat: Text.PlainText
            width: Math.min(400, app.width - 80)
            wrapMode: Text.Wrap
            text: app.closeNeedsReview(dialogs.closeReader) ? qsTr("Review the pending edit before closing. Discard removes the unsaved draft; Cancel keeps the document open.") : ((dialogs.closeReader && (dialogs.closeReader.data.signature_status || {}).signed) ? qsTr("Save an unsigned copy before closing, or discard the draft. The signed original stays unchanged.") : qsTr("Save changes to the PDF before closing, or discard the draft. Cancel keeps the document open."))
        }
        onAccepted: app.beginCloseOperation("save",dialogs.closeReader,dialogs.closeIndex<0)
        onDiscarded: app.beginCloseOperation("discard",dialogs.closeReader,dialogs.closeIndex<0)
    }
    property var noteReader: null
    property string noteId: ""
    property string savedNote: ""
    property bool noteDirty: false
    property bool noteReady: false
    property double noteRequestId: -1
    property string annotationWriteError: ""
    property double coverageRequestId: -1
    property string coverageText: ""
    property var missingGlyphs: []
    Timer {
        id: coverageTimer
        interval: 350
        onTriggered: if (annotation.visible && dialogs.noteReader && app.selectedAnnotation && ["textBox", "stamp"].indexOf(app.selectedAnnotation.kind) >= 0) {
            dialogs.coverageText = noteText.text;
            dialogs.coverageRequestId = dialogs.noteReader.submit("font_coverage", {
                text: dialogs.coverageText
            });
        }
    }
    function cancelAnnotationDraft() {
        noteSave.stop();
        noteDirty = false;
    }
    function flushAnnotation(finishPlacedText) {
        if(finishPlacedText!==false && app.placedTextEditor.active)app.placedTextEditor.finish(false);
        noteSave.stop();
        if (!noteReader || !noteDirty || !noteId.length)
            return;
        noteRequestId = noteReader.submit("mark_update", {
            id: noteId,
            patch: {
                note: noteText.text
            }
        });
        savedNote = noteText.text;
        noteDirty = false;
        annotationWriteError = "";
    }
    Timer {
        id: noteSave
        interval: 500
        onTriggered: dialogs.flushAnnotation()
    }
    Connections {
        target: dialogs.noteReader
        function onCommandFinished(id, op, result, error) {
            if (id === dialogs.coverageRequestId && !error.length && dialogs.coverageText === noteText.text)
                dialogs.missingGlyphs = result.missing || [];
            if (id === dialogs.noteRequestId && error.length) {
                dialogs.annotationWriteError = error;
                dialogs.noteDirty = true;
            }
        }
    }
    property string replaceKind: ""
    function confirmReplacement(kind) {
        replaceKind = kind;
        replaceConfirmation.open();
    }
    property var flattenOwner: null
    property var flattenGeneration: null
    function showFlattenNotice() {
        flattenOwner=app.currentReader;flattenGeneration=flattenOwner.documentGeneration;
        flattenNotice.open();
    }
    Dialog {
        id: flattenNotice
        objectName: "flattenExportNotice"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(540,app.width-32)
        modal: true
        title: qsTr("Export as Flattened Copy")
        standardButtons: Dialog.Ok | Dialog.Cancel
        // This notice always has a title and buttons. Reserve their intrinsic
        // chrome even while closed, before the overlay reparents the popup.
        implicitHeight: topPadding + bottomPadding + flattenDescription.implicitHeight
            + (header ? header.implicitHeight + spacing : 0)
            + (footer ? footer.implicitHeight + spacing : 0)
        Label {
            id: flattenDescription
            width: flattenNotice.availableWidth
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: qsTr("Paints saved annotations and form values into a new PDF. Pending annotation and form drafts are not included; save them first to include them. Links and sticky notes remain annotations, and unsupported fields are kept and reported. The original is unchanged. This is not tamper-proof: the painted content remains editable, and only a digital signature can detect later changes.")
        }
        onAccepted: {
            if(dialogs.flattenOwner===app.currentReader && dialogs.flattenGeneration===app.currentReader.documentGeneration)
                app.chooseExport("flattened");
            else app.operationStatus=qsTr("The document changed. Choose the flattened export again.");
            dialogs.flattenOwner=null;
        }
        onRejected: dialogs.flattenOwner=null
    }
    Dialog {
        id: replaceConfirmation
        objectName: "originalReplaceConfirmation"
        title: qsTr("Replace Original PDF?")
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Yes | Dialog.Cancel
        Label {
            textFormat: Text.PlainText
            text: qsTr("A byte-identical backup will be verified before the original is replaced. Pending changes are written only after this confirmation.")
            width: Math.min(400, app.width - 80)
            wrapMode: Text.Wrap
        }
        onAccepted: app.performReplace(dialogs.replaceKind)
        onRejected: app.replacementContext=null
    }
    property var editingBookmark: null
    property var bookmarkOwner: null
    property var bookmarkGeneration: null
    property var bookmarkAnchor: null
    property bool bookmarkAbove: false
    property double bookmarkRequest: -1
    property string bookmarkError: ""
    function bookmarkContextCurrent() {
        return bookmarkOwner && bookmarkOwner===app.currentReader && !bookmarkOwner.loading
            && !bookmarkOwner.documentRevisionPending && bookmarkGeneration===bookmarkOwner.documentGeneration
            && editingBookmark && app.bookmarks.some(function(b){return b.id===editingBookmark.id;});
    }
    function openBookmark(bookmark, index, anchor, above) {
        if (!bookmark || !app.currentReader || app.currentReader.loading || app.currentReader.documentRevisionPending
                || !app.bookmarks.some(function(b){return b.id===bookmark.id;})) return;
        bookmarkOwner=app.currentReader;
        bookmarkGeneration=bookmarkOwner.documentGeneration;
        bookmarkAnchor=anchor;
        bookmarkAbove=above===true;
        bookmarkRequest=-1;
        bookmarkError="";
        editingBookmark = Object.assign({},bookmark);
        bookmarkTitle.text = bookmark.title;
        bookmarkEditor.open();
    }
    function saveBookmarkEditor(remove) {
        if (bookmarkRequest>=0) return;
        if (!bookmarkContextCurrent()) {bookmarkEditor.close();return;}
        bookmarkError="";
        const request={id:editingBookmark.id};
        if (!remove) {
            const title=bookmarkOwner.trimBookmarkEditorText(bookmarkTitle.text);
            const current=app.bookmarks.find(function(b){return b.id===editingBookmark.id;});
            if (current && title===current.title) {bookmarkEditor.close();return;}
            request.patch={title:title};
        }
        bookmarkRequest=bookmarkOwner.submit(remove ? "bookmark_delete" : "bookmark_update",request);
    }
    Connections {
        target:app
        function onCurrentReaderChanged(){bookmarkEditor.close();selection.close();}
        function onTranslationSelectionContextChanged(){
            if(selection.visible && (!app.translationSelectionContext || !selection.translationContext
                    || app.translationSelectionContext.signature!==selection.translationContext.signature))selection.close();
        }
    }
    Connections {
        target:dialogs.bookmarkOwner
        function onDocumentChanged(){if(bookmarkEditor.visible && !dialogs.bookmarkContextCurrent())bookmarkEditor.close();}
        function onCommandFinished(id,op,result,error) {
            if(id!==dialogs.bookmarkRequest)return;
            dialogs.bookmarkRequest=-1;
            if(error.length)dialogs.bookmarkError=error;
            else bookmarkEditor.close();
        }
    }
    function recoverSidecar() {
        sidecarRecovery.open();
    }
    Dialog {
        id: sidecarRecovery
        title: qsTr("Recover Annotation Sidecar")
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label {
            textFormat: Text.PlainText
            width: Math.min(400, app.width - 80)
            text: qsTr("The unreadable sidecar will be copied and verified as a backup before a fresh annotation file is created. The PDF is unchanged.")
            wrapMode: Text.Wrap
        }
        onAccepted: app.currentReader.submit("marks_recover")
    }
    Dialog {
        id: bookmarkEditor
        objectName: "bookmarkEditor"
        title: qsTr("Edit Bookmark")
        Binding {
            target: bookmarkEditor.contentItem ? bookmarkEditor.contentItem.parent : null
            property: "Accessible.name"
            value: bookmarkEditor.title
            when: bookmarkEditor.contentItem && bookmarkEditor.contentItem.parent
        }
        header: null
        footer: null
        standardButtons: Dialog.NoButton
        modal: false
        parent: Overlay.overlay
        width: Math.min(280, app.width - 16)
        margins: 8
        padding: 16
        height: Math.min(implicitHeight, app.height - 16)
        focus: true
        closePolicy: dialogs.bookmarkRequest>=0 ? Popup.NoAutoClose : Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onAboutToShow: {
            const anchor=dialogs.bookmarkAnchor;
            const p=anchor ? anchor.mapToItem(parent,0,anchor.height) : Qt.point((app.width-width)/2,(app.height-height)/2);
            if(anchor && dialogs.bookmarkAbove) {
                const top=anchor.mapToItem(parent,0,0).y-height;
                if(top>=8)p.y=top;
            }
            x=Math.max(8,Math.min(parent.width-width-8,p.x));
            y=Math.max(8,Math.min(parent.height-height-8,p.y));
        }
        onOpened: {bookmarkTitle.forceActiveFocus();bookmarkTitle.selectAll();}
        onClosed: {dialogs.editingBookmark=null;dialogs.bookmarkOwner=null;dialogs.bookmarkGeneration=null;dialogs.bookmarkAnchor=null;dialogs.bookmarkAbove=false;dialogs.bookmarkRequest=-1;}
        background: Rectangle { color:app.colors.menuBg; radius:8; border.width:1; border.color:app.colors.controlBorder }
        contentItem: ColumnLayout {
            spacing: 14
            RowLayout {
                Label {
                    textFormat: Text.PlainText
                    text: dialogs.editingBookmark ? qsTr("Page %1 bookmark").arg(dialogs.editingBookmark.page+1) : ""
                    font.pixelSize: 12
                    color: app.colors.textSecondary
                    Layout.fillWidth: true
                }
                LyraToolButton { symbol:"close";text:qsTr("Close bookmark editor");enabled:dialogs.bookmarkRequest<0;onClicked:bookmarkEditor.close() }
            }
            Label { text:qsTr("Bookmark name");font.pixelSize:12;font.weight:Font.Medium;color:app.colors.textPrimary }
            ReadingTextField {
                id: bookmarkTitle
                app: dialogs.app
                objectName: "bookmarkNameField"
                placeholderText: qsTr("Name")
                Layout.fillWidth: true
                enabled: dialogs.bookmarkRequest<0
                Accessible.name: qsTr("Bookmark name")
                onAccepted: dialogs.saveBookmarkEditor(false)
            }
            Label { textFormat:Text.PlainText;Layout.fillWidth:true;visible:dialogs.bookmarkError.length>0;text:dialogs.bookmarkError;color:app.colors.errorFg;wrapMode:Text.Wrap }
            RowLayout {
                Button {
                    text: qsTr("Remove Bookmark")
                    flat: true
                    font.pixelSize: 12
                    palette.buttonText: enabled ? app.colors.errorFg : app.colors.textDisabled
                    enabled: dialogs.bookmarkRequest<0
                    onClicked: dialogs.saveBookmarkEditor(true)
                }
                Item { Layout.fillWidth:true }
                ReadingPrimaryButton {
                    app:dialogs.app
                    text:qsTr("Done")
                    Layout.preferredWidth:70
                    enabled:dialogs.bookmarkRequest<0
                    onClicked:dialogs.saveBookmarkEditor(false)
                }
            }
        }
    }
    function confirmPageDeletion() {
        deletePages.open();
    }
    function confirmDiscardPages() {
        discardPages.open();
    }
    Dialog {
        id: deletePages
        title: qsTr("Delete Selected Pages?")
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Yes | Dialog.Cancel
        Label {
            textFormat: Text.PlainText
            text: qsTr("Pages and their marks are removed from the working copy. Undo restores them. The original stays unchanged until Apply.")
            width: Math.min(400, app.width - 80)
            wrapMode: Text.Wrap
        }
        onAccepted: app.pageOperation({
            Delete: {
                pages: app.selectedPages
            }
        })
    }
    Dialog {
        id: discardPages
        title: qsTr("Discard Page Session?")
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Yes | Dialog.Cancel
        Label {
            textFormat: Text.PlainText
            text: qsTr("Discard staged page changes and marks made in the working copy, then reopen the original PDF.")
            width: Math.min(400, app.width - 80)
            wrapMode: Text.Wrap
        }
        onAccepted: app.currentReader.submit("page_discard")
    }
    QuitDialog { app: dialogs.app }

    FileDialogNavigation {id:saveNavigation}
    function openSaveDialog(suggestion) {
        save.suggestion=suggestion;
        save.adjustingFormat=true;
        save.selectedNameFilter.index=0;
        save.currentFolder=app.session.urlForLocalPath(suggestion.folder);
        const initialFile=app.session.urlForLocalPath(suggestion.path);
        save.selectedFile=initialFile;
        save.open();
        saveNavigation.setSaveName(save,app,initialFile,true);
        save.adjustingFormat=false;
    }
    FileDialog {
        id: save
        objectName: "documentSaveDialog"
        property var suggestion:null
        property bool adjustingFormat:false
        function updateFormat() {
            if(adjustingFormat || app.exportKind!=="annotation-text" || !suggestion)return;
            const suffix=selectedNameFilter.index===1 ? "csv" : "md";
            const current=app.session.localPath(saveNavigation.currentSaveFile(save,app));
            const previous=current===suggestion.markdown || current===suggestion.csv;
            const separator=Math.max(current.lastIndexOf("/"),current.lastIndexOf("\\"));
            const dot=current.lastIndexOf(".");
            const stem=dot>separator+1 ? current.slice(0,dot) : current;
            selectedFile=app.session.urlForLocalPath(!current.length || previous ? suggestion[suffix==="md" ? "markdown" : "csv"] : stem+"."+suffix);
            saveNavigation.setSaveName(save,app,selectedFile,false);
        }
        Connections {
            target:save.selectedNameFilter
            function onIndexChanged() {save.updateFormat();}
        }
        fileMode: FileDialog.SaveFile
        title: {
            if(app.exportKind==="flattened")return qsTr("Export as Flattened Copy");
            if(app.exportKind==="properties")return qsTr("Save Document Properties Copy");
            if(app.exportKind==="forms")return qsTr("Save Filled Form Copy");
            if(app.exportKind==="bibtex")return qsTr("Save BibTeX");
            if(["annotation-text","markdown","csv"].indexOf(app.exportKind)>=0)return qsTr("Export Annotations");
            if(app.exportKind==="extract")return qsTr("Extract Pages");
            if(app.exportKind==="pages" || (app.exportKind==="document" && app.exportContext && app.exportContext.pageEdits))return qsTr("Save Edited Copy");
            if(app.exportKind==="annotations" || app.exportKind==="document")return qsTr("Save Annotated Copy");
            return qsTr("Save a copy");
        }
        nameFilters: app.exportKind==="annotation-text" ? [qsTr("Markdown (*.md)"),qsTr("CSV (*.csv)")] : app.exportKind === "bibtex" ? [qsTr("BibTeX (*.bib)")] : app.exportKind === "markdown" ? [qsTr("Markdown (*.md)")] : app.exportKind === "csv" ? [qsTr("CSV (*.csv)")] : [qsTr("PDF documents (*.pdf)")]
        defaultSuffix: app.exportKind==="annotation-text" ? (selectedNameFilter.index===1 ? "csv" : "md") : app.exportKind==="markdown" ? "md" : app.exportKind==="csv" ? "csv" : app.exportKind==="bibtex" ? "bib" : "pdf"
        onAccepted: {
            if(app.exportKind==="annotation-text")app.setAnnotationExportFormat(selectedNameFilter.index);
            app.exportTo(selectedFile);
        }
        onRejected: {
            if(app.exportContext && app.exportContext.closeTicket === app.closeOperation)app.cancelCloseOperation("");
            app.exportContext=null;
        }
    }
    LyraMenu {
        id: selection
        objectName:"selectionContextMenu"
        property var translationContext:null
        parent: Overlay.overlay
        onAboutToShow:translationContext=app.translationSelectionContext
        onClosed: {
            const previous=translationContext;
            Qt.callLater(function(){if(!selection.visible && selection.translationContext===previous)selection.translationContext=null;});
        }
        LyraMenuItem {
            objectName:"editAnnotationTextAction"
            text:qsTr("Edit Annotation Text")
            enabled:app.canModifyPdf && !!app.selectedAnnotation && app.selectedAnnotation.kind==="textBox" && !Logic.annotationUnsupportedReason(app.selectedAnnotation).length
            onTriggered:app.selectAnnotation(app.selectedAnnotation,true)
        }
        LyraMenuItem {
            objectName:"annotationPropertiesAction"
            text:qsTr("Annotation Properties…")
            enabled:!!app.selectedAnnotation
            onTriggered:app.showAnnotationProperties()
        }
        LyraMenuSeparator {}
        LyraMenuItem {
            text: qsTr("Copy Text")
            enabled: !!app.selection
            onTriggered: app.copySelection()
        }
        LyraMenuItem {
            text: qsTr("Highlight")
            enabled: app.canModifyPdf && !!app.selection
            onTriggered: app.markSelection("highlight")
        }
        LyraMenuItem {
            text: qsTr("Underline")
            enabled: app.canModifyPdf && !!app.selection
            onTriggered: app.markSelection("underline")
        }
        LyraMenuItem {
            text: qsTr("Strikethrough")
            enabled: app.canModifyPdf && !!app.selection
            onTriggered: app.markSelection("strikeout")
        }
        LyraMenuSeparator {}
        LyraMenuItem {
            objectName:"selectionTranslationAction"
            text:app.translationSelectionTitle
            Accessible.description:qsTr("Control+Shift+L. Saved translations switch locally; new requests require preview and Send.")
            enabled:!!app.translationSelectionContext && app.translationSelectionContext.enabled
            onTriggered:if(selection.translationContext)app.performTranslationAction(selection.translationContext)
        }
        LyraMenuItem {
            text: qsTr("Ask AI about Selection")
            enabled: !!app.selection
            onTriggered: { app.currentReader.setAiInput("action",2); app.showAiPanel(true); }
        }
    }
    LyraMenu {
        id: exports
        parent: Overlay.overlay
        LyraMenuItem {
            text: qsTr("Save Annotated Copy…")
            enabled: app.canModifyPdf
            onTriggered: app.chooseExport("annotations")
        }
        LyraMenuItem {
            text: qsTr("Save and Replace Original…")
            enabled: app.canModifyPdf && !app.originalReadOnly
            onTriggered: app.confirmReplace("annotations")
        }
        LyraMenuSeparator {}
        LyraMenuItem {
            text: qsTr("Save Filled Form Copy…")
            enabled: app.canModifyPdf
            onTriggered: app.chooseExport("forms")
        }
        LyraMenuItem {
            text: qsTr("Save Edited Copy…")
            enabled: app.canModifyPdf && app.pageEditsPending
            onTriggered: app.chooseExport("pages")
        }
        LyraMenuItem {
            text: qsTr("Export Annotations as Markdown…")
            onTriggered: app.chooseExport("markdown")
        }
        LyraMenuItem {
            text: qsTr("Export Annotations as CSV…")
            onTriggered: app.chooseExport("csv")
        }
        LyraMenuItem {
            text: qsTr("Export BibTeX…")
            onTriggered: app.chooseExport("bibtex")
        }
    }
    SettingsWindow {id:settings;app:dialogs.app}
    Dialog {
        id: information
        objectName: "documentInformationDialog"
        title: qsTr("Document Information")
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(600, app.width - 32)
        height: Math.min(580, app.height - 32)
        modal: true
        focus: true
        padding: 0
        standardButtons: Dialog.NoButton
        background: Rectangle {color: app.colors.panelBg; border.color: app.colors.separator; radius: 8}
        header: Item {
            implicitHeight: 68
            RowLayout {
                anchors.fill: parent; anchors.margins: 18; spacing: 8
                LyraToolButton {
                    symbol: "info"; implicitWidth: 18; implicitHeight: 18
                    icon.width: 18; icon.height: 18; padding: 0; background: null
                    focusPolicy: Qt.NoFocus; hoverEnabled: false; Accessible.ignored: true
                }
                Label {text: information.title; textFormat: Text.PlainText; font.pixelSize: 14; font.weight: Font.DemiBold; color: app.colors.textPrimary; Layout.fillWidth: true; elide: Text.ElideRight}
                ReadingPrimaryButton {
                    id: informationDone; objectName: "documentInformationDone"; app: dialogs.app
                    text: qsTr("Done"); implicitWidth: 72
                    onClicked: information.accept()
                    Keys.onReturnPressed: information.accept()
                    Keys.onEnterPressed: information.accept()
                }
            }
            Rectangle {anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: app.colors.separator}
        }
        footer: null
        onOpened: informationDone.forceActiveFocus(Qt.TabFocusReason)
        readonly property bool propertiesReady: !!app.currentReader.data.document_info
        readonly property bool propertiesDirty: propertiesReady && (titleField.text !== (app.infoData.title || "") || authorField.text !== (app.infoData.author || "") || subjectField.text !== (app.infoData.subject || "") || keywordsField.text !== (app.infoData.keywords || ""))
        readonly property bool canSaveProperties: propertiesReady && propertiesDirty && app.canModifyPdf && !app.infoData.is_encrypted && app.currentReader.pendingCommands===0 && !app.pendingDocumentSave && !app.closeOperation
        readonly property string propertiesReplaceReason: app.originalReadOnly ? app.readOnlyReason : app.pageEditsPending ? qsTr("Save or discard the pending page changes before replacing the original's properties.") : Object.keys(app.currentReader.noteDrafts).length || app.currentReader.hasEditDrafts ? qsTr("Save the other document edits before replacing its properties. Save Copy keeps those drafts here.") : ""
        readonly property bool canReplaceProperties: canSaveProperties && !propertiesReplaceReason.length
        function draft() {
            return {
                title: titleField.text,
                author: authorField.text,
                subject: subjectField.text,
                keywords: keywordsField.text
            };
        }
        contentItem: ScrollView {
            id: informationScroll
            padding: 18
            clip: true
            contentWidth: availableWidth
            function revealFocus() {
                if(!information.visible)return;
                const item=dialogs.app.activeFocusItem,source=dialogs.app.currentReader;
                const generation=source ? source.documentGeneration : -1;
                Qt.callLater(function() {
                    if(!information.visible || !item || dialogs.app.activeFocusItem!==item
                            || source!==dialogs.app.currentReader || !source || generation!==source.documentGeneration)return;
                    const f=informationScroll.contentItem;
                    if(!f || f.height<=0)return;
                    let parent=item;
                    while(parent && parent!==f)parent=parent.parent;
                    if(!parent)return;
                    let rect=item.mapToItem(f.contentItem,0,0,item.width,item.height);
                    if(rect.height>f.height-4 && typeof item.cursorRectangle!=="undefined") {
                        const cursor=item.cursorRectangle;
                        rect=item.mapToItem(f.contentItem,cursor.x,cursor.y,cursor.width,cursor.height);
                    }
                    let y=f.contentY;
                    if(rect.y<y+2)y=rect.y-2;
                    else if(rect.y+rect.height>y+f.height-2)y=rect.y+rect.height-f.height+2;
                    f.contentY=Math.max(0,Math.min(Math.max(0,f.contentHeight-f.height),y));
                });
            }
            onAvailableWidthChanged:revealFocus()
            onAvailableHeightChanged:revealFocus()
            Connections {target:dialogs.app;function onActiveFocusItemChanged(){informationScroll.revealFocus();}}
            Connections {target:informationScroll.contentItem;function onContentHeightChanged(){informationScroll.revealFocus();}}
            ColumnLayout {
                width: informationScroll.availableWidth
                spacing: 10
                Label {
                    textFormat: Text.PlainText
                    text: qsTr("Document properties in the PDF")
                    font.weight: Font.DemiBold
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 18
                    Repeater {
                        model: [
                            {label: qsTr("Pages"), value: String(app.currentReader.pageCount)},
                            {label: qsTr("PDF version"), value: app.infoData.pdf_version || "—"},
                            {label: qsTr("Encrypted"), value: typeof app.infoData.is_encrypted === "boolean" ? (app.infoData.is_encrypted ? qsTr("Yes") : qsTr("No")) : "—"}
                        ]
                        ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true; spacing: 1
                            Accessible.role: Accessible.StaticText
                            Accessible.name: modelData.label + ": " + modelData.value
                            Label {text: modelData.label; font.pixelSize: 11; color: app.colors.textSecondary; Accessible.ignored: true}
                            Label {text: modelData.value; font.pixelSize: 12; font.weight: Font.Medium; color: app.colors.textPrimary; Accessible.ignored: true}
                        }
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 3
                    Label {text: qsTr("Title"); font.pixelSize: 11; font.weight: Font.DemiBold; color: app.colors.textPrimary}
                    TextField {
                        id: titleField; Accessible.name: qsTr("Title")
                        readOnly: app.xfaReadOnly || !!app.infoData.is_encrypted
                        enabled: information.propertiesReady
                        Layout.fillWidth: true
                        text: typeof app.propertiesDraft.title !== "undefined" ? app.propertiesDraft.title : app.infoData.title || ""
                        onTextEdited: app.editDocumentProperty("title", text)
                        placeholderText: qsTr("Title")
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 3
                    Label {text: qsTr("Author"); font.pixelSize: 11; font.weight: Font.DemiBold; color: app.colors.textPrimary}
                    TextField {
                        id: authorField; Accessible.name: qsTr("Author")
                        readOnly: app.xfaReadOnly || !!app.infoData.is_encrypted
                        enabled: information.propertiesReady
                        Layout.fillWidth: true
                        text: typeof app.propertiesDraft.author !== "undefined" ? app.propertiesDraft.author : app.infoData.author || ""
                        onTextEdited: app.editDocumentProperty("author", text)
                        placeholderText: qsTr("Author")
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 3
                    Label {text: qsTr("Subject"); font.pixelSize: 11; font.weight: Font.DemiBold; color: app.colors.textPrimary}
                    TextField {
                        id: subjectField; Accessible.name: qsTr("Subject")
                        readOnly: app.xfaReadOnly || !!app.infoData.is_encrypted
                        enabled: information.propertiesReady
                        Layout.fillWidth: true
                        text: typeof app.propertiesDraft.subject !== "undefined" ? app.propertiesDraft.subject : app.infoData.subject || ""
                        onTextEdited: app.editDocumentProperty("subject", text)
                        placeholderText: qsTr("Subject")
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 3
                    Label {text: qsTr("Keywords"); font.pixelSize: 11; font.weight: Font.DemiBold; color: app.colors.textPrimary}
                    TextField {
                        id: keywordsField; Accessible.name: qsTr("Keywords")
                        readOnly: app.xfaReadOnly || !!app.infoData.is_encrypted
                        enabled: information.propertiesReady
                        Layout.fillWidth: true
                        text: typeof app.propertiesDraft.keywords !== "undefined" ? app.propertiesDraft.keywords : app.infoData.keywords || ""
                        onTextEdited: app.editDocumentProperty("keywords", text)
                        placeholderText: qsTr("Keywords")
                    }
                }
                RowLayout {
                    LyraToolButton {
                        text: qsTr("Save Copy…"); symbol: "export"; fitLabel: true; display: AbstractButton.TextBesideIcon
                        enabled: information.canSaveProperties
                        onClicked: app.chooseExport("properties")
                    }
                    LyraToolButton {
                        text: qsTr("Write to This File…"); symbol: "document"; fitLabel: true; display: AbstractButton.TextBesideIcon
                        enabled: information.canReplaceProperties
                        onClicked: app.confirmReplace("properties")
                    }
                    Item {Layout.fillWidth: true}
                    Label {text: qsTr("Unsaved"); visible: information.propertiesDirty; font.pixelSize: 11; color: app.colors.warningFg}
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    text: app.xfaReadOnly ? app.readOnlyReason : app.infoData.is_encrypted ? qsTr("This PDF is encrypted. Its document properties cannot be written safely.") : app.originalReadOnly ? qsTr("Signed PDF: properties can be saved to an unsigned copy. The original stays read-only.") : qsTr("Save Copy writes these properties to a new PDF. Other unsaved drafts stay here. Write to This File backs up the original before replacing it.")
                    font.pixelSize: 11; color: app.colors.textSecondary
                }
                Label {Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText; text: information.propertiesReplaceReason; visible: !app.originalReadOnly && text.length>0; font.pixelSize: 11; color: app.colors.warningFg}
                Rectangle {Layout.fillWidth: true; height: 1; color: app.colors.separator; Layout.topMargin: 6}
                Label {
                    textFormat: Text.PlainText
                    text: qsTr("Found in this PDF")
                    font.weight: Font.DemiBold
                    Layout.topMargin: 12
                }
                Repeater {
                    model: [
                        {
                            key: "title",
                            label: qsTr("Title")
                        },
                        {
                            key: "authors",
                            label: qsTr("Authors")
                        },
                        {
                            key: "venue",
                            label: qsTr("Venue")
                        },
                        {
                            key: "year",
                            label: qsTr("Year")
                        },
                        {
                            key: "doi",
                            label: "DOI"
                        },
                        {
                            key: "arxiv_id",
                            label: "arXiv"
                        }
                    ]
                    ColumnLayout {
                        required property var modelData
                        readonly property var field: app.currentReader.data.metadata ? app.currentReader.data.metadata[modelData.key] : null
                        readonly property var inputs: app.metadataDraft.texts || ({})
                        readonly property bool corrected: typeof inputs[modelData.key] !== "undefined"
                        Layout.fillWidth: true
                        spacing: 3
                        RowLayout {
                            Layout.fillWidth: true
                            Label {text: modelData.label; font.pixelSize: 11; font.weight: Font.DemiBold; color: app.colors.textPrimary}
                            Item {Layout.fillWidth: true}
                            Label {
                                textFormat: Text.PlainText
                                text: corrected ? qsTr("Edited") : !field || field.trust === "none" ? qsTr("empty") : field.source_label
                                font.pixelSize: 11
                                color: !corrected && field && field.guessed ? app.colors.warningFg : app.colors.textSecondary
                            }
                        }
                        TextField {
                            Layout.fillWidth: true
                            enabled: !!app.currentReader.data.metadata
                            Accessible.name: qsTr("Recognised %1").arg(modelData.label)
                            text: corrected ? inputs[modelData.key] : field ? field.values.join(modelData.key === "authors" ? "; " : " ") : ""
                            onTextEdited: app.editMetadata(modelData.key, text)
                        }
                    }
                }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    text: qsTr("“Guessed” fields come from the page layout. Correct anything that is wrong; edits regenerate the entry below without writing the PDF.")
                    font.pixelSize: 11; color: app.colors.textSecondary
                }
                Rectangle {Layout.fillWidth: true; height: 1; color: app.colors.separator; Layout.topMargin: 6}
                Label {text: qsTr("Generated BibTeX"); font.weight: Font.DemiBold; color: app.colors.textPrimary}
                TextArea {
                    textFormat: TextEdit.PlainText
                    text: app.bibtex
                    Accessible.name: qsTr("BibTeX")
                    readOnly: true
                    selectByMouse: true
                    selectByKeyboard: true
                    wrapMode: Text.WrapAnywhere
                    Layout.fillWidth: true
                    font.family: "monospace"
                    font.pixelSize: 11
                    background: null
                    padding: 0
                    color: app.colors.textPrimary
                    implicitHeight: Math.ceil(contentHeight + topPadding + bottomPadding)
                    onCursorRectangleChanged: informationScroll.revealFocus()
                }
                RowLayout {
                    LyraToolButton {
                        text: qsTr("Copy"); symbol: "copy"; fitLabel: true; display: AbstractButton.TextBesideIcon
                        Accessible.name: qsTr("Copy BibTeX")
                        enabled: app.bibtex.length > 0
                        onClicked: if (app.session)
                            app.session.copyText(app.bibtex)
                    }
                    LyraToolButton {
                        text: qsTr("Save…"); symbol: "export"; fitLabel: true; display: AbstractButton.TextBesideIcon
                        Accessible.name: qsTr("Save BibTeX")
                        enabled: app.bibtex.length > 0
                        onClicked: app.chooseExport("bibtex")
                    }
                }
            }
        }
    }
    Dialog {
        id: forms
        title: qsTr("Fill & Sign")
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(560, app.width - 40)
        height: Math.min(600, app.height - 40)
        modal: false
        standardButtons: Dialog.Close
        ScrollView {
            anchors.fill: parent
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
                spacing: 10
                Label {
                    textFormat: Text.PlainText
                    text: app.currentReader.data.forms ? (app.currentReader.data.forms.refusal || qsTr("Changes stay in this session until saved.")) : qsTr("Reading form fields…")
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: app.colors.textSecondary
                }
                Repeater {
                    model: app.currentReader.data.forms ? app.currentReader.data.forms.fields : []
                    ColumnLayout {
                        required property var modelData
                        readonly property var draft: app.formValues[modelData.id] || null
                        Layout.fillWidth: true
                        Label {
                            textFormat: Text.PlainText
                            text: modelData.name + qsTr(" · p.%1").arg(modelData.page + 1)
                            font.pixelSize: 11
                            color: app.colors.textSecondary
                        }
                        TextField {
                            visible: modelData.kind === "text"
                            Accessible.name: modelData.name
                            Layout.fillWidth: true
                            text: parent.draft && typeof parent.draft.text === "string" ? parent.draft.text : modelData.value || ""
                            enabled: modelData.editable
                            maximumLength: modelData.max_length || 32767
                            onTextEdited: app.updateFormValue(modelData.id, {
                                text: text,
                                checked: null,
                                selected: null
                            })
                        }
                        CheckBox {
                            visible: modelData.kind === "checkBox"
                            text: modelData.name
                            checked: parent.draft && typeof parent.draft.checked === "boolean" ? parent.draft.checked : !!modelData.checked
                            enabled: modelData.editable
                            function toggleField() {
                                if (enabled)
                                    app.updateFormValue(modelData.id, {
                                        text: null,
                                        checked: !checked,
                                        selected: null
                                    });
                            }
                            Accessible.onPressAction: toggleField()
                            Accessible.onToggleAction: toggleField()
                            onToggled: app.updateFormValue(modelData.id, {
                                text: null,
                                checked: checked,
                                selected: null
                            })
                        }
                        ComboBox {
                            visible: modelData.options.length > 0
                            Accessible.name: modelData.name
                            Layout.fillWidth: true
                            model: modelData.options
                            textRole: "label"
                            currentIndex: parent.draft && typeof parent.draft.selected === "number" ? parent.draft.selected : modelData.selected.length ? modelData.selected[0] : -1
                            enabled: modelData.editable
                            onActivated: app.updateFormValue(modelData.id, {
                                text: null,
                                checked: null,
                                selected: currentIndex
                            })
                        }
                        Label {
                            textFormat: Text.PlainText
                            visible: !modelData.editable
                            text: qsTr("This field cannot be edited.")
                            font.pixelSize: 10
                            color: app.colors.textTertiary
                        }
                    }
                }
                RowLayout {
                    Button {
                        text: qsTr("Save Filled Copy…")
                        onClicked: app.chooseExport("forms")
                    }
                    Button {
                        text: qsTr("Write to Original…")
                        enabled: app.canModifyPdf && !app.originalReadOnly
                        onClicked: app.confirmReplace("forms")
                    }
                }
            }
        }
    }
    function showAnnotation() {
        flushAnnotation();
        annotation.open();
        loadAnnotation();
    }
    function loadAnnotation() {
        dialogs.noteReady = false;
        dialogs.noteReader = app.currentReader;
        dialogs.noteId = app.selectedAnnotation ? app.selectedAnnotation.id : "";
        noteText.text = app.selectedAnnotation ? app.selectedAnnotation.note || app.selectedAnnotation.contents || "" : "";
        dialogs.savedNote = noteText.text;
        if (dialogs.noteId.length && dialogs.noteReader.noteDrafts[dialogs.noteId] !== undefined)
            noteText.text = dialogs.noteReader.noteDrafts[dialogs.noteId];
        dialogs.noteDirty = noteText.text !== dialogs.savedNote;
        dialogs.annotationWriteError = "";
        dialogs.noteReady = true;
        dialogs.missingGlyphs = [];
        coverageTimer.restart();
        noteText.forceActiveFocus();
    }
    Dialog {
        id: annotation
        objectName: "annotationEditor"
        onOpened: dialogs.loadAnnotation()
        onClosed: dialogs.flushAnnotation(false)
        title: qsTr("Annotation")
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(440, app.width - 40)
        modal: false
        standardButtons: Dialog.Close
        ColumnLayout {
            anchors.fill: parent
            Label {
                textFormat: Text.PlainText
                text: app.selectedAnnotation ? app.selectedAnnotation.kind + qsTr(" · page %1").arg(app.selectedAnnotation.page + 1) : ""
                color: app.colors.textTertiary
            }
            RowLayout {
                enabled: app.canModifyPdf && !!app.selectedAnnotation && !app.selectedAnnotation.foreign
                visible: !app.selectedAnnotation || app.selectedAnnotation.kind !== "signature"
                Label {
                    textFormat: Text.PlainText
                    text: qsTr("Colour")
                }
                Repeater {
                    model: ["#E8BC55", "#EFA77D", "#90B79A", "#7DADD6", "#AB9ACB", "#D99A9B"]
                    ToolButton {
                        required property string modelData
                        implicitWidth: 26
                        implicitHeight: 28
                        Accessible.name: qsTr("Set annotation colour %1").arg(modelData)
                        background: Rectangle {
                            anchors.centerIn: parent
                            width: 18
                            height: 18
                            radius: 9
                            color: modelData
                            border.width: app.selectedAnnotation && app.selectedAnnotation.color.slice(0, 7).toLowerCase() === modelData.toLowerCase() ? 2 : 1
                            border.color: app.colors.focusRing
                        }
                        onClicked: if (app.selectedAnnotation)
                            app.updateSelectedAnnotation({
                                color: modelData + app.selectedAnnotation.color.slice(7, 9)
                            })
                    }
                }
                ToolButton {
                    text: "…"
                    Accessible.name: qsTr("Custom annotation colour")
                    onClicked: {
                        annotationColor.selectedColor = Logic.color(app.selectedAnnotation);
                        annotationColor.open();
                    }
                }
            }
            RowLayout {
                enabled: app.canModifyPdf && !!app.selectedAnnotation && !app.selectedAnnotation.foreign
                Label {
                    textFormat: Text.PlainText
                    text: qsTr("Opacity")
                }
                Slider {
                    objectName: "annotationOpacity"
                    Layout.fillWidth: true
                    from: 0
                    to: 1
                    stepSize: .01
                    live: false
                    value: app.selectedAnnotation ? Logic.color(app.selectedAnnotation).a : 1
                    Accessible.name: qsTr("Annotation opacity")
                    onMoved: if (app.selectedAnnotation)
                        app.updateSelectedAnnotation({
                            color: app.selectedAnnotation.color.slice(0, 7) + Logic.hex(value * 255)
                        })
                }
                SpinBox {
                    objectName: "annotationStrokeWidth"
                    visible: app.selectedAnnotation && ["ink", "square", "circle", "line", "arrow"].indexOf(app.selectedAnnotation.kind) >= 0
                    from: 1
                    to: 32
                    value: app.selectedAnnotation ? app.selectedAnnotation.strokeWidth || 2 : 2
                    editable: true
                    Accessible.name: qsTr("Annotation stroke width")
                    onValueModified: app.updateSelectedAnnotation({
                        strokeWidth: value
                    })
                }
            }
            RowLayout {
                visible: !!app.selectedAnnotation && app.selectedAnnotation.kind === "textBox"
                enabled: app.canModifyPdf && !!app.selectedAnnotation && !app.selectedAnnotation.foreign
                Label {
                    textFormat: Text.PlainText
                    text: qsTr("Text size")
                }
                SpinBox {
                    objectName: "annotationFontSize"
                    from: 4
                    to: 144
                    value: app.selectedAnnotation ? app.selectedAnnotation.fontSize || 14 : 14
                    editable: true
                    Accessible.name: qsTr("Text box font size")
                    onValueModified: app.updateSelectedAnnotation({
                        fontSize: value
                    })
                }
                ComboBox {
                    objectName: "annotationAlignment"
                    model: [qsTr("Left"), qsTr("Centre"), qsTr("Right")]
                    currentIndex: app.selectedAnnotation ? Math.max(0, ["left", "center", "right"].indexOf(app.selectedAnnotation.textAlignment || "left")) : 0
                    Accessible.name: qsTr("Text alignment")
                    onActivated: app.updateSelectedAnnotation({
                        textAlignment: ["left", "center", "right"][currentIndex]
                    })
                }
            }
            Label {
                textFormat: Text.PlainText
                visible: !!app.selectedAnnotation && Logic.annotationUnsupportedReason(app.selectedAnnotation).length > 0
                text: Logic.annotationUnsupportedReason(app.selectedAnnotation)
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: app.colors.warningFg
            }
            TextArea {
                id: noteText
                textFormat: TextEdit.PlainText
                objectName: "annotationNoteText"
                Accessible.name: qsTr("Annotation note")
                Layout.fillWidth: true
                implicitHeight: 150
                readOnly: app.xfaReadOnly || !!(app.selectedAnnotation && (app.selectedAnnotation.foreign || app.selectedAnnotation.kind === "signature"))
                selectByKeyboard: true
                wrapMode: Text.Wrap
                placeholderText: qsTr("Note")
                onTextChanged: if (dialogs.noteReady && annotation.visible && !readOnly) {
                    coverageTimer.restart();
                    dialogs.noteDirty = text !== dialogs.savedNote;
                    if (dialogs.noteDirty)
                        dialogs.noteReader.setNoteDraft(dialogs.noteId, text);
                    else
                        dialogs.noteReader.clearNoteDraft(dialogs.noteId);
                    if (dialogs.noteDirty)
                        noteSave.restart();
                }
            }
            Label {
                textFormat: Text.PlainText
                objectName: "annotationGlyphWarning"
                visible: !!app.selectedAnnotation && ["textBox", "stamp"].indexOf(app.selectedAnnotation.kind) >= 0 && dialogs.missingGlyphs.length > 0
                text: qsTr("The PDF font cannot draw: %1. The saved text stays intact; these characters appear as missing-glyph boxes.").arg(dialogs.missingGlyphs.join(" "))
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: app.colors.warningFg
            }
            Label {
                textFormat: Text.PlainText
                visible: dialogs.annotationWriteError.length > 0
                text: dialogs.annotationWriteError
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: app.colors.errorFg
            }
            RowLayout {
                Button {
                    text: qsTr("Save Note")
                    enabled: !noteText.readOnly
                    onClicked: dialogs.flushAnnotation()
                }
                Button {
                    text: qsTr("Delete Annotation")
                    enabled: app.canModifyPdf && !!app.selectedAnnotation && !Logic.annotationUnsupportedReason(app.selectedAnnotation).length
                    onClicked: {
                        app.deleteSelectedAnnotation();
                        annotation.close();
                    }
                }
            }
        }
    }
    ColorDialog {
        id: annotationColor
        title: qsTr("Annotation colour")
        options: ColorDialog.ShowAlphaChannel
        onAccepted: app.updateSelectedAnnotation({
            color: "#" + Logic.hex(selectedColor.r * 255) + Logic.hex(selectedColor.g * 255) + Logic.hex(selectedColor.b * 255) + Logic.hex(selectedColor.a * 255)
        })
    }
    Dialog {
        id: credential
        objectName: "aiCredentialDialog"
        title: qsTr("API key")
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        ColumnLayout {
            Label {
                textFormat: Text.PlainText
                text: qsTr("Use a key for this request, or save one in Settings.")
                wrapMode: Text.Wrap
                Layout.maximumWidth: 350
            }
            TextField {
                id: requestKey
                objectName: "requestAiCredential"
                Layout.fillWidth: true
                echoMode: TextInput.Password
                Accessible.name: qsTr("API key for this request")
            }
        }
        onAccepted: {
            if (app.pendingAiReader && !app.startPreparedAi(app.pendingAiReader,requestKey.text,app.pendingAiPlan,app.pendingAiPurpose,app.pendingAiToken))
                app.operationStatus = qsTr("The request changed or the document is busy. Preview and Send again.");
            requestKey.clear();
            app.pendingAiReader = null;
            app.pendingAiPlan = null;
        }
        onRejected: {
            requestKey.clear();
            app.pendingAiReader = null;
            app.pendingAiPlan = null;
        }
    }
}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

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
    function confirmClose(index) {
        closeIndex = index;
        closeConfirmation.open();
    }
    Dialog {
        id: closeConfirmation
        objectName: "closeChangesConfirmation"
        title: qsTr("Unapplied Changes")
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Discard | Dialog.Cancel
        Label {
            width: Math.min(400, app.width - 80)
            wrapMode: Text.Wrap
            text: qsTr("Page edits, pending deletions, or unsaved annotation notes have not been written to the PDF. Discard them and close? Choose Cancel to apply or export your changes first. Saved annotations remain in their sidecar.")
        }
        onDiscarded: app.discardAndClose(dialogs.closeIndex)
    }
    property var noteReader: null
    property string noteId: ""
    property string savedNote: ""
    property bool noteDirty: false
    property bool noteReady: false
    property double noteRequestId: -1
    property string annotationWriteError: ""
    function cancelAnnotationDraft() {
        noteSave.stop();
        noteDirty = false;
    }
    function flushAnnotation() {
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
    Dialog {
        id: replaceConfirmation
        title: qsTr("Replace Original PDF?")
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Yes | Dialog.Cancel
        Label {
            text: qsTr("A byte-identical backup will be verified before the original is replaced. Pending changes are written only after this confirmation.")
            width: Math.min(400, app.width - 80)
            wrapMode: Text.Wrap
        }
        onAccepted: app.performReplace(dialogs.replaceKind)
    }
    property var editingBookmark: null
    function openBookmark(bookmark, index) {
        editingBookmark = bookmark;
        bookmarkTitle.text = bookmark.title;
        bookmarkEditor.open();
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
            width: Math.min(400, app.width - 80)
            text: qsTr("The unreadable sidecar will be copied and verified as a backup before a fresh annotation file is created. The PDF is unchanged.")
            wrapMode: Text.Wrap
        }
        onAccepted: app.currentReader.submit("marks_recover")
    }
    Dialog {
        id: bookmarkEditor
        title: qsTr("Edit Bookmark")
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Save | Dialog.Cancel
        ColumnLayout {
            TextField {
                id: bookmarkTitle
                Layout.fillWidth: true
                Accessible.name: qsTr("Bookmark title")
            }
            RowLayout {
                Button {
                    text: qsTr("Move Up")
                    onClicked: if (dialogs.editingBookmark)
                        app.currentReader.submit("bookmark_move", {
                            id: dialogs.editingBookmark.id,
                            delta: -1
                        })
                }
                Button {
                    text: qsTr("Move Down")
                    onClicked: if (dialogs.editingBookmark)
                        app.currentReader.submit("bookmark_move", {
                            id: dialogs.editingBookmark.id,
                            delta: 1
                        })
                }
                Button {
                    text: qsTr("Delete")
                    onClicked: {
                        if (dialogs.editingBookmark)
                            app.currentReader.submit("bookmark_delete", {
                                id: dialogs.editingBookmark.id
                            });
                        bookmarkEditor.close();
                    }
                }
            }
        }
        onAccepted: if (dialogs.editingBookmark)
            app.currentReader.submit("bookmark_update", {
                id: dialogs.editingBookmark.id,
                patch: {
                    title: bookmarkTitle.text
                }
            })
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
            text: qsTr("Discard staged page changes and marks made in the working copy, then reopen the original PDF.")
            width: Math.min(400, app.width - 80)
            wrapMode: Text.Wrap
        }
        onAccepted: app.currentReader.submit("page_discard")
    }
    FileDialog {
        id: save
        fileMode: FileDialog.SaveFile
        title: qsTr("Save a copy")
        nameFilters: app.exportKind === "bibtex" ? [qsTr("BibTeX (*.bib)")] : app.exportKind === "markdown" ? [qsTr("Markdown (*.md)")] : app.exportKind === "csv" ? [qsTr("CSV (*.csv)")] : [qsTr("PDF documents (*.pdf)")]
        onAccepted: app.exportTo(selectedFile)
    }
    Menu {
        id: selection
        parent: Overlay.overlay
        MenuItem {
            text: qsTr("Copy Text")
            enabled: !!app.selection
            onTriggered: app.copySelection()
        }
        MenuItem {
            text: qsTr("Highlight")
            enabled: !!app.selection
            onTriggered: app.markSelection("highlight")
        }
        MenuItem {
            text: qsTr("Underline")
            enabled: !!app.selection
            onTriggered: app.markSelection("underline")
        }
        MenuItem {
            text: qsTr("Strikethrough")
            enabled: !!app.selection
            onTriggered: app.markSelection("strikeout")
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Ask AI about Selection")
            enabled: !!app.selection
            onTriggered: app.showSidebar("ai")
        }
    }
    Menu {
        id: exports
        parent: Overlay.overlay
        MenuItem {
            text: qsTr("Save Annotated Copy…")
            onTriggered: app.chooseExport("annotations")
        }
        MenuItem {
            text: qsTr("Save and Replace Original…")
            enabled: !app.originalReadOnly
            onTriggered: app.confirmReplace("annotations")
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Save Filled Form Copy…")
            onTriggered: app.chooseExport("forms")
        }
        MenuItem {
            text: qsTr("Save Edited Copy…")
            enabled: app.pageEditsPending
            onTriggered: app.chooseExport("pages")
        }
        MenuItem {
            text: qsTr("Export Annotations as Markdown…")
            onTriggered: app.chooseExport("markdown")
        }
        MenuItem {
            text: qsTr("Export Annotations as CSV…")
            onTriggered: app.chooseExport("csv")
        }
        MenuItem {
            text: qsTr("Export BibTeX…")
            onTriggered: app.chooseExport("bibtex")
        }
    }
    Dialog {
        id: settings
        title: qsTr("Settings")
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(550, app.width - 40)
        height: Math.min(650, app.height - 40)
        modal: true
        standardButtons: Dialog.Save | Dialog.Cancel
        ScrollView {
            anchors.fill: parent
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
                spacing: 12
                Label {
                    text: qsTr("Reading")
                    font.weight: Font.DemiBold
                }
                ComboBox {
                    id: appearance
                    Layout.fillWidth: true
                    model: [qsTr("Light"), qsTr("Dark"), qsTr("Follow System")]
                    currentIndex: ["light", "dark", "system"].indexOf(app.appearance)
                }
                ComboBox {
                    id: paper
                    Layout.fillWidth: true
                    model: [qsTr("Original Colours"), qsTr("Warm Paper"), qsTr("Night Reading")]
                    currentIndex: ["original", "warm", "night"].indexOf(app.paperAppearance)
                }
                RowLayout {
                    Label {
                        text: qsTr("Page gap (pt)")
                        Layout.fillWidth: true
                    }
                    SpinBox {
                        id: gap
                        from: 0
                        to: 100
                        value: app.pageGap
                    }
                }
                Label {
                    text: qsTr("AI Assistant")
                    font.weight: Font.DemiBold
                    Layout.topMargin: 12
                }
                TextField {
                    id: baseUrl
                    Layout.fillWidth: true
                    placeholderText: qsTr("Base URL, e.g. http://localhost:11434/v1")
                    text: app.aiSettings.baseUrl || "http://localhost:11434/v1"
                    Accessible.name: qsTr("AI base URL")
                }
                TextField {
                    id: modelName
                    Layout.fillWidth: true
                    placeholderText: qsTr("Model name")
                    text: app.aiSettings.model || ""
                    Accessible.name: qsTr("AI model")
                }
                ComboBox {
                    id: reasoning
                    Layout.fillWidth: true
                    model: ["default", "off", "low", "high", "max"]
                    currentIndex: Math.max(0, model.indexOf(app.aiSettings.reasoningMode || "default"))
                }
                ComboBox {
                    id: encoding
                    Layout.fillWidth: true
                    model: ["none", "thinking", "reasoning_effort", "output_config", "reasoning.effort"]
                    currentIndex: Math.max(0, model.indexOf(app.aiSettings.reasoningEncoding || "none"))
                }
                TextField {
                    id: apiKey
                    Layout.fillWidth: true
                    placeholderText: qsTr("API key — saved only in the system keychain")
                    echoMode: TextInput.Password
                    Accessible.name: qsTr("AI API key")
                }
                Label {
                    text: qsTr("Remote requests send the previewed document text only after Send. Keys use the system keychain; no plaintext fallback.")
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                    color: app.colors.textSecondary
                    font.pixelSize: 11
                }
                Button {
                    text: qsTr("Remove Saved Key")
                    onClicked: app.removeAiCredential(baseUrl.text)
                }
            }
        }
        onAccepted: {
            app.appearance = ["light", "dark", "system"][appearance.currentIndex];
            app.paperAppearance = ["original", "warm", "night"][paper.currentIndex];
            app.pageGap = gap.value;
            app.setPageLayout(app.layoutMode);
            app.aiSettings = {
                baseUrl: baseUrl.text,
                model: modelName.text,
                reasoningMode: reasoning.currentText,
                reasoningEncoding: encoding.currentText
            };
            if (app.session) {
                app.session.setPreference("ai", app.aiSettings);
                app.session.setPreference("paper", app.paperAppearance);
            }
            if (apiKey.text.length)
                app.saveAiCredential(baseUrl.text, apiKey.text);
            apiKey.clear();
        }
        onRejected: apiKey.clear()
    }
    Dialog {
        id: information
        title: qsTr("Document Information")
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(640, app.width - 40)
        height: Math.min(650, app.height - 40)
        modal: true
        standardButtons: Dialog.Close
        function draft() {
            return {
                title: titleField.text,
                author: authorField.text,
                subject: subjectField.text,
                keywords: keywordsField.text
            };
        }
        ScrollView {
            anchors.fill: parent
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
                spacing: 9
                Label {
                    text: qsTr("PDF properties")
                    font.weight: Font.DemiBold
                }
                TextField {
                    id: titleField
                    Layout.fillWidth: true
                    text: app.infoData.title || ""
                    placeholderText: qsTr("Title")
                }
                TextField {
                    id: authorField
                    Layout.fillWidth: true
                    text: app.infoData.author || ""
                    placeholderText: qsTr("Author")
                }
                TextField {
                    id: subjectField
                    Layout.fillWidth: true
                    text: app.infoData.subject || ""
                    placeholderText: qsTr("Subject")
                }
                TextField {
                    id: keywordsField
                    Layout.fillWidth: true
                    text: app.infoData.keywords || ""
                    placeholderText: qsTr("Keywords")
                }
                Label {
                    text: qsTr("%1 pages · PDF %2%3").arg(app.currentReader.pageCount).arg(app.infoData.pdf_version || "").arg(app.infoData.is_encrypted ? qsTr(" · encrypted") : "")
                    color: app.colors.textTertiary
                }
                RowLayout {
                    Button {
                        text: qsTr("Save Properties Copy…")
                        enabled: !app.infoData.is_encrypted && !app.originalReadOnly
                        onClicked: app.chooseExport("properties")
                    }
                    Button {
                        text: qsTr("Write to Original…")
                        enabled: !app.infoData.is_encrypted && !app.originalReadOnly
                        onClicked: app.confirmReplace("properties")
                    }
                }
                Label {
                    text: qsTr("Recognised paper metadata")
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
                        Layout.fillWidth: true
                        spacing: 2
                        Label {
                            text: modelData.label + " · " + (field ? field.source_label : "")
                            font.pixelSize: 11
                            color: app.colors.textTertiary
                        }
                        TextField {
                            Layout.fillWidth: true
                            text: field ? field.values.join(modelData.key === "authors" ? "; " : " ") : ""
                            onTextEdited: app.editMetadata(modelData.key, text)
                        }
                    }
                }
                TextArea {
                    text: app.bibtex
                    readOnly: true
                    selectByMouse: true
                    wrapMode: Text.WrapAnywhere
                    Layout.fillWidth: true
                    font.family: "monospace"
                    implicitHeight: 120
                }
                RowLayout {
                    Button {
                        text: qsTr("Copy BibTeX")
                        onClicked: if (app.session)
                            app.session.copyText(app.bibtex)
                    }
                    Button {
                        text: qsTr("Export BibTeX…")
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
                    text: app.currentReader.data.forms ? (app.currentReader.data.forms.refusal || qsTr("Changes stay in this session until saved.")) : qsTr("Reading form fields…")
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: app.colors.textSecondary
                }
                Repeater {
                    model: app.currentReader.data.forms ? app.currentReader.data.forms.fields : []
                    ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        Label {
                            text: modelData.name + qsTr(" · p.%1").arg(modelData.page + 1)
                            font.pixelSize: 11
                            color: app.colors.textSecondary
                        }
                        TextField {
                            visible: modelData.kind === "text"
                            Layout.fillWidth: true
                            text: modelData.value || ""
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
                            checked: modelData.checked
                            enabled: modelData.editable
                            onToggled: app.updateFormValue(modelData.id, {
                                text: null,
                                checked: checked,
                                selected: null
                            })
                        }
                        ComboBox {
                            visible: modelData.options.length > 0
                            Layout.fillWidth: true
                            model: modelData.options
                            textRole: "label"
                            currentIndex: modelData.selected.length ? modelData.selected[0] : -1
                            enabled: modelData.editable
                            onActivated: app.updateFormValue(modelData.id, {
                                text: null,
                                checked: null,
                                selected: currentIndex
                            })
                        }
                        Label {
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
                        enabled: !app.originalReadOnly
                        onClicked: app.confirmReplace("forms")
                    }
                }
            }
        }
    }
    Dialog {
        id: annotation
        objectName: "annotationEditor"
        onOpened: {
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
            noteText.forceActiveFocus();
        }
        onClosed: dialogs.flushAnnotation()
        title: qsTr("Annotation")
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(440, app.width - 40)
        modal: false
        standardButtons: Dialog.Close
        ColumnLayout {
            anchors.fill: parent
            Label {
                text: app.selectedAnnotation ? app.selectedAnnotation.kind + qsTr(" · page %1").arg(app.selectedAnnotation.page + 1) : ""
                color: app.colors.textTertiary
            }
            TextArea {
                id: noteText
                objectName: "annotationNoteText"
                Layout.fillWidth: true
                implicitHeight: 150
                readOnly: !!(app.selectedAnnotation && app.selectedAnnotation.foreign)
                wrapMode: Text.Wrap
                placeholderText: qsTr("Note")
                onTextChanged: if (dialogs.noteReady && annotation.visible && !readOnly) {
                    dialogs.noteDirty = text !== dialogs.savedNote;
                    if (dialogs.noteDirty)
                        dialogs.noteReader.setNoteDraft(dialogs.noteId, text);
                    else
                        dialogs.noteReader.clearNoteDraft(dialogs.noteId);
                    if (dialogs.noteDirty)
                        noteSave.restart();
                }
            }
            RowLayout {
                Button {
                    text: qsTr("Save Note")
                    enabled: !noteText.readOnly
                    onClicked: dialogs.flushAnnotation()
                }
                Button {
                    text: qsTr("Delete Annotation")
                    onClicked: {
                        app.deleteSelectedAnnotation();
                        annotation.close();
                    }
                }
            }
        }
    }
    Dialog {
        id: credential
        title: qsTr("API key")
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        ColumnLayout {
            Label {
                text: qsTr("Use a key for this request, or save one in Settings.")
                wrapMode: Text.Wrap
                Layout.maximumWidth: 350
            }
            TextField {
                id: requestKey
                Layout.fillWidth: true
                echoMode: TextInput.Password
                Accessible.name: qsTr("API key for this request")
            }
        }
        onAccepted: {
            if (app.pendingAiPanel)
                app.pendingAiPanel.send(requestKey.text);
            requestKey.clear();
            app.pendingAiPanel = null;
        }
        onRejected: {
            requestKey.clear();
            app.pendingAiPanel = null;
        }
    }
}

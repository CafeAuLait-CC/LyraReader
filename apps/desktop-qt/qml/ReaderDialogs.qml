import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
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
    Dialog {
        id: replaceConfirmation
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
            textFormat: Text.PlainText
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
    FileDialog {
        id: save
        objectName: "documentSaveDialog"
        fileMode: FileDialog.SaveFile
        title: qsTr("Save a copy")
        nameFilters: app.exportKind === "bibtex" ? [qsTr("BibTeX (*.bib)")] : app.exportKind === "markdown" ? [qsTr("Markdown (*.md)")] : app.exportKind === "csv" ? [qsTr("CSV (*.csv)")] : [qsTr("PDF documents (*.pdf)")]
        onAccepted: app.exportTo(selectedFile)
        onRejected: if (app.exportContext && app.exportContext.closeTicket === app.closeOperation) app.cancelCloseOperation("")
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
            enabled: app.canModifyPdf && !!app.selection
            onTriggered: app.markSelection("highlight")
        }
        MenuItem {
            text: qsTr("Underline")
            enabled: app.canModifyPdf && !!app.selection
            onTriggered: app.markSelection("underline")
        }
        MenuItem {
            text: qsTr("Strikethrough")
            enabled: app.canModifyPdf && !!app.selection
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
            enabled: app.canModifyPdf
            onTriggered: app.chooseExport("annotations")
        }
        MenuItem {
            text: qsTr("Save and Replace Original…")
            enabled: app.canModifyPdf && !app.originalReadOnly
            onTriggered: app.confirmReplace("annotations")
        }
        MenuSeparator {}
        MenuItem {
            text: qsTr("Save Filled Form Copy…")
            enabled: app.canModifyPdf
            onTriggered: app.chooseExport("forms")
        }
        MenuItem {
            text: qsTr("Save Edited Copy…")
            enabled: app.canModifyPdf && app.pageEditsPending
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
    SettingsWindow {id:settings;app:dialogs.app}
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
                    textFormat: Text.PlainText
                    text: qsTr("PDF properties")
                    font.weight: Font.DemiBold
                }
                TextField {
                    id: titleField
                    readOnly: app.xfaReadOnly
                    Layout.fillWidth: true
                    text: app.infoData.title || ""
                    placeholderText: qsTr("Title")
                }
                TextField {
                    id: authorField
                    readOnly: app.xfaReadOnly
                    Layout.fillWidth: true
                    text: app.infoData.author || ""
                    placeholderText: qsTr("Author")
                }
                TextField {
                    id: subjectField
                    readOnly: app.xfaReadOnly
                    Layout.fillWidth: true
                    text: app.infoData.subject || ""
                    placeholderText: qsTr("Subject")
                }
                TextField {
                    id: keywordsField
                    readOnly: app.xfaReadOnly
                    Layout.fillWidth: true
                    text: app.infoData.keywords || ""
                    placeholderText: qsTr("Keywords")
                }
                Label {
                    textFormat: Text.PlainText
                    text: qsTr("%1 pages · PDF %2%3").arg(app.currentReader.pageCount).arg(app.infoData.pdf_version || "").arg(app.infoData.is_encrypted ? qsTr(" · encrypted") : "")
                    color: app.colors.textTertiary
                }
                RowLayout {
                    Button {
                        text: qsTr("Save Properties Copy…")
                        enabled: app.canModifyPdf && !app.infoData.is_encrypted && !app.originalReadOnly
                        onClicked: app.chooseExport("properties")
                    }
                    Button {
                        text: qsTr("Write to Original…")
                        enabled: app.canModifyPdf && !app.infoData.is_encrypted && !app.originalReadOnly
                        onClicked: app.confirmReplace("properties")
                    }
                }
                Label {
                    textFormat: Text.PlainText
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
                            textFormat: Text.PlainText
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
                    textFormat: TextEdit.PlainText
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
                Layout.fillWidth: true
                implicitHeight: 150
                readOnly: app.xfaReadOnly || !!(app.selectedAnnotation && (app.selectedAnnotation.foreign || app.selectedAnnotation.kind === "signature"))
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
                Layout.fillWidth: true
                echoMode: TextInput.Password
                Accessible.name: qsTr("API key for this request")
            }
        }
        onAccepted: {
            if (app.pendingAiReader && !app.pendingAiReader.startAi(requestKey.text, app.pendingAiPlan))
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

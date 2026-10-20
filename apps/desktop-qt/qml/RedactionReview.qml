import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: reviewDialog
    objectName: "redactionReview"
    required property var app
    property var owner: null
    property var areas: []
    property var preview: null
    property double requestId: -1
    property bool replacing: false
    property bool loading: false
    property string error: ""
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(650, app.width - 32)
    height: Math.min(620, app.height - 32)
    modal: true
    standardButtons: Dialog.Cancel
    title: replacing ? qsTr("Replace with Redacted Content?") : qsTr("Review Redacted Copy")
    function review(replace) {
        if (!app.canRedact || !app.pendingRedactions.length)
            return;
        if (replace && app.originalReadOnly)
            return;
        owner = app.currentReader;
        areas = app.pendingRedactions.slice();
        replacing = replace;
        preview = null;
        error = "";
        loading = true;
        requestId = owner.submit("preview_redactions", {
            areas: areas
        });
        open();
    }
    function apply() {
        if (loading || error.length || !preview || !owner || owner !== app.currentReader)
            return;
        if (replacing) {
            if (app.originalReadOnly)
                return;
            owner.submit("replace_redactions", {
                areas: areas
            });
        } else
            app.chooseRedactionExport(owner, areas);
        close();
    }
    Connections {
        target: reviewDialog.owner
        function onCommandFinished(id, op, result, error) {
            if (id !== reviewDialog.requestId || op !== "preview_redactions")
                return;
            reviewDialog.loading = false;
            reviewDialog.error = error;
            reviewDialog.preview = error.length ? null : result;
        }
    }
    Connections {
        target: app
        function onCurrentReaderChanged() {
            reviewDialog.close();
            reviewDialog.owner = null;
        }
    }
    ColumnLayout {
        anchors.fill: parent
        Label {
            textFormat: Text.PlainText
            text: qsTr("Covered text is deleted from page content. Intersecting vectors and images are removed whole. A page whose content cannot be attributed is rasterised and loses its entire text layer. Marks are painted black.")
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
        Label {
            textFormat: Text.PlainText
            text: reviewDialog.replacing ? qsTr("This changes the original file. A byte-identical backup is verified before the replacement is written.") : qsTr("The source PDF stays unchanged. The copy is reopened and verified before it is saved. Session form edits and sidecar annotations are not included.")
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: app.colors.warningFg
        }
        BusyIndicator {
            visible: reviewDialog.loading
            running: visible
            Layout.alignment: Qt.AlignHCenter
        }
        Label {
            textFormat: Text.PlainText
            visible: reviewDialog.error.length > 0
            text: reviewDialog.error
            color: app.colors.errorFg
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
        Label {
            textFormat: Text.PlainText
            visible: !!reviewDialog.preview
            text: qsTr("%1 areas · %2 characters under the marks").arg(reviewDialog.areas.length).arg(reviewDialog.preview ? reviewDialog.preview.removed_characters : 0)
            color: app.colors.textSecondary
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
                Repeater {
                    model: reviewDialog.preview ? reviewDialog.preview.pages : []
                    ColumnLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        Label {
                            textFormat: Text.PlainText
                            text: qsTr("Page %1 · %2 characters · %3 graphic objects").arg(modelData.page + 1).arg(modelData.characters).arg(modelData.graphics)
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            font.bold: true
                        }
                        TextArea {
                            text: modelData.text_preview || qsTr("No extractable text under these marks.")
                            readOnly: true
                            selectByMouse: true
                            textFormat: TextEdit.PlainText
                            wrapMode: TextEdit.Wrap
                            Layout.fillWidth: true
                        }
                    }
                }
            }
        }
        Button {
            objectName: "applyReviewedRedactions"
            text: reviewDialog.replacing ? qsTr("Replace Original") : qsTr("Choose Copy Destination…")
            enabled: !reviewDialog.loading && !!reviewDialog.preview && !reviewDialog.error.length
            onClicked: reviewDialog.apply()
            Layout.alignment: Qt.AlignRight
        }
    }
}

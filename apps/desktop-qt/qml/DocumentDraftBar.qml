import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: bar
    required property var app
    visible: app.pendingRedactions.length > 0 || app.formToolActive
    padding: 6
    background: Rectangle {
        color: app.colors.panelBg
        border.color: app.colors.separator
    }
    Flow {
        width: parent.width
        spacing: 6
        Label {
            textFormat: Text.PlainText
            height: 30
            verticalAlignment: Text.AlignVCenter
            text: app.pendingRedactions.length ? qsTr("%1 pending redactions").arg(app.pendingRedactions.length) : (app.currentReader.data.forms && app.currentReader.data.forms.refusal ? app.currentReader.data.forms.refusal : qsTr("Fill form fields on the page"))
            color: app.colors.textSecondary
        }
        Button {
            visible: app.pendingRedactions.length > 0
            text: qsTr("Review & Save Copy…")
            enabled: app.canRedact
            onClicked: app.reviewRedactions(false)
        }
        Button {
            visible: app.pendingRedactions.length > 0
            text: qsTr("Replace Original…")
            enabled: app.canRedact && !app.originalReadOnly
            onClicked: app.reviewRedactions(true)
        }
        Button {
            visible: app.pendingRedactions.length > 0
            text: qsTr("Remove Last")
            enabled: app.currentReader.pendingCommands === 0
            onClicked: app.currentReader.setEditDraft("redactions", app.pendingRedactions.slice(0, -1))
        }
        Button {
            visible: app.pendingRedactions.length > 0
            text: qsTr("Clear Marks")
            enabled: app.currentReader.pendingCommands === 0
            onClicked: app.currentReader.setEditDraft("redactions", [])
        }
        Button {
            visible: app.formToolActive
            text: qsTr("All Fields…")
            onClicked: app.showFormsDialog()
        }
        Button {
            visible: app.formToolActive
            text: qsTr("Save Filled Copy…")
            enabled: Object.keys(app.formValues).length > 0 && app.currentReader.pendingCommands === 0
            onClicked: app.chooseExport("forms")
        }
        Button {
            visible: app.formToolActive
            text: qsTr("Write to Original…")
            enabled: Object.keys(app.formValues).length > 0 && !app.originalReadOnly && app.currentReader.pendingCommands === 0
            onClicked: app.confirmReplace("forms")
        }
        Button {
            visible: app.formToolActive
            text: qsTr("Reset Form Edits")
            enabled: Object.keys(app.formValues).length > 0 && app.currentReader.pendingCommands === 0
            onClicked: app.currentReader.setEditDraft("forms", {})
        }
    }
}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

Item {
    id: control
    required property var app
    readonly property var coordinator: app.session ? app.session.quitCoordinator : null
    readonly property bool owns: !!coordinator && coordinator.owner===app.session
    Connections {
        target: control.coordinator
        function onChanged() {
            if (control.owns && control.coordinator.busy) confirmation.open();
            else confirmation.close();
        }
        function onCopyRequested(suggestion,title) {
            if (!control.owns) return;
            copy.currentFile=suggestion;copy.title=qsTr("Save Changes to a Copy — %1").arg(title);copy.open();
        }
        function onFinished(accepted,error) {
            copy.close();
            if (error.length) control.app.operationStatus=error;
        }
    }
    Dialog {
        id: confirmation
        objectName: "quitChangesConfirmation"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(540,control.app.width-48)
        height: Math.min(implicitHeight,control.app.height-48)
        modal: true
        closePolicy: Popup.NoAutoClose
        title: control.coordinator && control.coordinator.phase==="prompt" ?
            (control.coordinator.documents.length===1 ? qsTr("Save changes to 1 document before quitting?") : qsTr("Save changes to %1 documents before quitting?").arg(control.coordinator.documents.length)) : qsTr("Preparing to Quit")
        background: Rectangle {color:control.app.colors.panelBg;border.color:control.app.colors.border;radius:6}
        contentItem: ScrollView {
            clip: true
            implicitHeight: details.implicitHeight
            contentWidth: availableWidth
            ColumnLayout {
                id: details
                width: parent.width
                spacing: 12
                Repeater {
                    model: control.coordinator ? control.coordinator.documents : []
                    delegate: Label {
                        required property var modelData
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: modelData.title+" — "+modelData.summary+(modelData.copy ? qsTr(" · Save a copy") : "")
                        color: control.app.colors.textPrimary
                        wrapMode: Text.Wrap
                    }
                }
                Label {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: control.coordinator ? control.coordinator.message : ""
                    color: control.app.colors.textSecondary
                    wrapMode: Text.Wrap
                }
            }
        }
        footer: DialogButtonBox {
            Button {
                text: qsTr("Save All")
                enabled: control.coordinator && control.coordinator.phase==="prompt"
                DialogButtonBox.buttonRole: DialogButtonBox.ActionRole
                onClicked: control.coordinator.decide("save")
            }
            Button {
                text: qsTr("Discard All Changes")
                enabled: control.coordinator && control.coordinator.phase==="prompt"
                DialogButtonBox.buttonRole: DialogButtonBox.ActionRole
                onClicked: control.coordinator.decide("discard")
            }
            Button {
                text: qsTr("Cancel")
                enabled: control.coordinator && ["preparing","prompt","copy"].indexOf(control.coordinator.phase)>=0
                DialogButtonBox.buttonRole: DialogButtonBox.ActionRole
                onClicked: control.coordinator.cancel()
                Keys.onEscapePressed: control.coordinator.cancel()
            }
        }
        onRejected: if (control.coordinator) control.coordinator.cancel()
        Shortcut {sequence:"Escape";enabled:confirmation.opened;onActivated:control.coordinator.cancel()}
    }
    FileDialog {
        id: copy
        objectName: "quitSaveCopyDialog"
        fileMode: FileDialog.SaveFile
        nameFilters: [qsTr("PDF documents (*.pdf)")]
        onAccepted: control.coordinator.chooseCopy(selectedFile)
        onRejected: control.coordinator.cancel()
    }
}

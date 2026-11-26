import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: notice
    objectName: "aiReadingNotice"
    required property var app
    required property string message
    signal dismissed()
    visible: !!message
    padding: 10
    background: Rectangle { color: app.colors.noteBg }
    contentItem: RowLayout {
        spacing: 8
        LyraToolButton {
            symbol: "info"
            implicitWidth: 16; implicitHeight: 16
            icon.width: 16; icon.height: 16
            padding: 0; background: null
            focusPolicy: Qt.NoFocus; hoverEnabled: false
            Accessible.ignored: true
        }
        Label {
            objectName: "aiReadingNoteSavedNotice"
            text: notice.message
            textFormat: Text.PlainText
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: app.colors.textPrimary
            font.pixelSize: 11
            Accessible.role: Accessible.AlertMessage
        }
        LyraToolButton {
            objectName: "dismissAiReadingNotice"
            symbol: "close"; text: qsTr("Dismiss notification")
            implicitWidth: 24; implicitHeight: 24
            focusPolicy: Qt.TabFocus
            onClicked: notice.dismissed()
        }
    }
}

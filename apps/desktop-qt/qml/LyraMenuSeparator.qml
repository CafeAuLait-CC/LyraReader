import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.MenuSeparator {
    property var theme: parent && parent.Window.window ? parent.Window.window.colors : null
    enabled: false
    implicitHeight: 11
    padding: 0
    leftPadding: 6
    rightPadding: 6
    contentItem: Item {
        implicitHeight: 11
        Rectangle {
            width: parent.width
            height: 1
            anchors.verticalCenter: parent.verticalCenter
            color: parent.parent.theme ? parent.parent.theme.separator : "transparent"
        }
    }
}

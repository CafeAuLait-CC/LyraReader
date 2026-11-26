import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Button {
    id: heading
    required property var app
    property bool expanded: false
    padding: 0
    implicitHeight: Math.max(30, implicitContentHeight)
    Accessible.name: text
    Accessible.description: expanded ? qsTr("Expanded") : qsTr("Collapsed")
    contentItem: RowLayout {
        spacing: 7
        Label { text: heading.expanded ? "⌄" : "›"; font.pixelSize: 10; color: heading.app.colors.textSecondary }
        Label {
            text: heading.text; textFormat: Text.PlainText; wrapMode: Text.Wrap
            Layout.fillWidth: true; Layout.minimumWidth: 0
            font.pixelSize: 13; color: heading.app.colors.textPrimary
            font.underline: heading.hovered
        }
    }
    background: Rectangle {
        color: "transparent"; radius: 3
        border.width: heading.visualFocus ? 2 : 0; border.color: heading.app.colors.focusRing
    }
    onClicked: expanded = !expanded
}

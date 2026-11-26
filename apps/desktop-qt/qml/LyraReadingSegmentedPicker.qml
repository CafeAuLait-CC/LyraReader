import QtQuick
import QtQuick.Controls

Item {
    id: picker
    required property var app
    required property var choices
    property int currentIndex: 0
    property real indicatorIndex: currentIndex
    signal activated(int index)
    implicitHeight: 36
    readonly property real cellWidth: Math.max(0, (width - 10) / 2)
    Accessible.role: Accessible.PageTabList

    function choose(index, reason) {
        const button = buttons.itemAt(index);
        if (!enabled || !button) return;
        if (currentIndex !== index) activated(index);
        button.forceActiveFocus(reason);
    }
    Behavior on indicatorIndex {
        enabled: !picker.app.reduceMotion
        NumberAnimation { duration: 180; easing.type: Easing.InOutQuad }
    }
    Rectangle {
        anchors.fill: parent
        radius: 8; color: "transparent"
        border.color: app.colors.controlBorder
    }
    Rectangle {
        objectName: picker.objectName + "Indicator"
        x: 3 + (picker.cellWidth + 4) * (app.reduceMotion ? picker.currentIndex : picker.indicatorIndex)
        y: 3; width: picker.cellWidth; height: picker.height - 6
        radius: 6; color: app.colors.selectedBg
    }
    Row {
        anchors.fill: parent; anchors.margins: 3; spacing: 4
        Repeater {
            id: buttons
            model: picker.choices
            ToolButton {
                id: segment
                required property int index
                required property var modelData
                objectName: picker.objectName + "Segment" + index
                width: picker.cellWidth; height: picker.height - 6
                text: modelData.title
                font.pixelSize: 13
                icon.source: modelData.icon ? "qrc:/icons/" + modelData.icon + ".svg" : ""
                icon.width: 14; icon.height: 14
                icon.color: !enabled ? app.colors.textDisabled : selected ? app.colors.selectedFg : app.colors.textPrimary
                palette.buttonText: !enabled ? app.colors.textDisabled : selected ? app.colors.selectedFg : app.colors.textPrimary
                readonly property bool selected: picker.currentIndex === index
                padding: 6; spacing: 7
                display: AbstractButton.TextBesideIcon
                focusPolicy: Qt.StrongFocus
                Accessible.role: Accessible.PageTab
                Accessible.name: text
                Accessible.selectable: true
                Accessible.selected: selected
                Accessible.onPressAction: picker.choose(index, Qt.TabFocusReason)
                background: Rectangle {
                    radius: 6
                    color: !segment.enabled || segment.selected ? "transparent" : segment.down ? app.colors.pressedBg : segment.hovered ? app.colors.hoverBg : "transparent"
                    border.width: segment.visualFocus ? 2 : 0
                    border.color: app.colors.focusRing
                }
                onClicked: picker.choose(index, visualFocus ? Qt.TabFocusReason : Qt.MouseFocusReason)
                Keys.onLeftPressed: picker.choose(0, Qt.TabFocusReason)
                Keys.onRightPressed: picker.choose(1, Qt.TabFocusReason)
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
                        picker.choose(event.key === Qt.Key_Home ? 0 : 1, Qt.TabFocusReason);
                        event.accepted = true;
                    }
                }
                ToolTip.visible: hovered
                ToolTip.text: text
                ToolTip.delay: 500
            }
        }
    }
}

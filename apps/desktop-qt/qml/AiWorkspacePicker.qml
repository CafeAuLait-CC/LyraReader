import QtQuick
import QtQuick.Controls

Item {
    id: picker
    objectName: "aiWorkspacePicker"
    required property var app
    required property string selectedKey
    signal picked(string key)

    readonly property var choices: [
        {key: "summary", title: qsTr("Summary")},
        {key: "translation", title: qsTr("Translate")},
        {key: "chat", title: qsTr("Chat")},
        {key: "notes", title: qsTr("Notes"), accessibleName: qsTr("Reading notes")}
    ]
    readonly property int selectedIndex: Math.max(0, choices.findIndex(choice => choice.key === selectedKey))
    readonly property real cellWidth: row.width / choices.length
    property real indicatorIndex: selectedIndex
    implicitHeight: 34
    Accessible.role: Accessible.PageTabList
    Accessible.name: qsTr("AI reading tools")

    function select(index, reason) {
        const button = buttons.itemAt(index);
        if (!button || !button.enabled) return;
        const owner = app.currentReader;
        const key = choices[index].key;
        if (key !== selectedKey) picked(key);
        if (owner === app.currentReader && button.visible) button.forceActiveFocus(reason);
    }

    // Only the selected index drives motion. Changes to the dock's width use the
    // new cell geometry immediately, even in the middle of a selection transition.
    Behavior on indicatorIndex {
        enabled: !picker.app.reduceMotion
        NumberAnimation { duration: 180; easing.type: Easing.InOutQuad }
    }
    Rectangle { anchors.fill: parent; radius: 7; color: app.colors.toolbarBg }
    Rectangle {
        objectName: "aiWorkspaceIndicator"
        x: row.x + picker.cellWidth * (app.reduceMotion ? picker.selectedIndex : picker.indicatorIndex)
        y: row.y; width: picker.cellWidth; height: row.height
        radius: 5; color: app.colors.selectedBg
    }
    Row {
        id: row
        anchors.fill: parent
        anchors.margins: 2
        Repeater {
            id: buttons
            model: picker.choices
            ToolButton {
                id: tab
                required property var modelData
                required property int index
                readonly property bool selected: picker.selectedKey === modelData.key
                objectName: "aiWorkspace" + modelData.key
                width: picker.cellWidth; height: row.height
                text: modelData.title
                padding: 4
                focusPolicy: Qt.StrongFocus
                Accessible.role: Accessible.PageTab
                Accessible.name: modelData.accessibleName || modelData.title
                Accessible.selectable: true
                Accessible.selected: selected
                Accessible.onPressAction: picker.select(index, Qt.TabFocusReason)
                contentItem: Text {
                    text: tab.text; font: tab.font; elide: Text.ElideRight
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    color: tab.selected ? app.colors.selectedFg : app.colors.textPrimary
                }
                background: Rectangle {
                    radius: 5
                    color: tab.selected ? "transparent" : tab.down ? app.colors.pressedBg
                         : tab.hovered ? app.colors.hoverBg : "transparent"
                    border.width: tab.visualFocus ? 2 : 0
                    border.color: app.colors.focusRing
                }
                onClicked: picker.select(index, visualFocus ? Qt.TabFocusReason : Qt.MouseFocusReason)
                Keys.onLeftPressed: picker.select((index + picker.choices.length - 1) % picker.choices.length, Qt.TabFocusReason)
                Keys.onRightPressed: picker.select((index + 1) % picker.choices.length, Qt.TabFocusReason)
                Keys.onReturnPressed: picker.select(index, Qt.TabFocusReason)
                Keys.onEnterPressed: picker.select(index, Qt.TabFocusReason)
                ToolTip.visible: hovered && contentItem.truncated
                ToolTip.text: Accessible.name
                ToolTip.delay: 500
            }
        }
    }
}

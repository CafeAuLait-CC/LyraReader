import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Basic as Basic

Basic.Menu {
    id: commands
    property var theme: parent && parent.Window.window ? parent.Window.window.colors : null
    readonly property var ownerWindow: parent ? parent.Window.window : null
    readonly property bool hasCheckmarks: {
        for (let i = 0; i < count; ++i) {
            const item = itemAt(i);
            if (item && item.checked) return true;
        }
        return false;
    }
    implicitWidth: {
        let natural = 150;
        for (let i = 0; i < count; ++i) {
            const item = itemAt(i);
            if (item) natural = Math.max(natural, item.implicitWidth);
        }
        return Math.ceil(natural + leftPadding + rightPadding);
    }
    padding: 5
    margins: 5
    focus: true
    popupType: Popup.Item
    enter: null
    exit: null
    delegate: LyraMenuItem {}

    function firstEnabledIndex() {
        for (let i = 0; i < count; ++i) {
            const item = itemAt(i);
            if (item && item.enabled && item.visible && typeof item.triggered === "function") return i;
        }
        return -1;
    }
    function openBelow(anchor) {
        parent = anchor;
        popup(anchor.width - width, anchor.height + 5);
    }
    function select(index) {
        currentIndex = index;
        const item = index >= 0 ? itemAt(index) : null;
        if (item) item.forceActiveFocus(Qt.PopupFocusReason);
        else contentItem.forceActiveFocus(Qt.PopupFocusReason);
    }
    function moveSelection(direction) {
        for (let step = 1; step <= count; ++step) {
            const index = (currentIndex + direction * step + count) % count;
            const item = itemAt(index);
            if (item && item.enabled && item.visible && typeof item.triggered === "function") { select(index); return; }
        }
    }
    Connections {
        target: commands
        function onOpened() { commands.select(commands.firstEnabledIndex()); }
    }
    Connections {
        target: commands.ownerWindow
        function onXChanged() { commands.close(); }
        function onYChanged() { commands.close(); }
        function onWidthChanged() { commands.close(); }
        function onHeightChanged() { commands.close(); }
        function onActiveChanged() { if (commands.ownerWindow && !commands.ownerWindow.active) commands.close(); }
        function onClosing() { commands.close(); }
    }
    contentItem: ListView {
        implicitHeight: contentHeight
        model: commands.contentModel
        currentIndex: commands.currentIndex
        spacing: 2
        clip: true
        keyNavigationWraps: true
        interactive: contentHeight > height
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                commands.moveSelection(event.key === Qt.Key_Down ? 1 : -1);
                event.accepted = true;
            }
        }
        ScrollIndicator.vertical: ScrollIndicator {}
    }
    background: Rectangle {
        radius: 9
        color: commands.theme ? commands.theme.menuBg : "transparent"
        border.color: commands.theme ? commands.theme.border : "transparent"
    }
}

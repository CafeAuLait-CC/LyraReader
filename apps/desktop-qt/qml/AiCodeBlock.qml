import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: block
    required property var app
    required property string sourceText
    property string language: ""
    property string textName: ""
    property var renderer: null
    readonly property var textControl: area
    readonly property bool limited: sourceText.length > 128 * 1024
    Layout.minimumWidth: 0
    spacing: 4
    function pan(dx) { view.contentX = Math.max(0, Math.min(Math.max(0, view.contentWidth - view.width), view.contentX - dx)); }
    function reveal(owner, generation, source) {
        if (!area.activeFocus || !visible || !owner || app.currentReader !== owner
                || owner.documentGeneration !== generation || source !== sourceText) return;
        const cursor = area.cursorRectangle;
        const rect = area.mapToItem(view.contentItem, cursor.x, cursor.y, cursor.width, cursor.height);
        if (!Number.isFinite(rect.x) || !Number.isFinite(rect.width) || view.width <= 0) return;
        let next = view.contentX;
        // Reveal the leading padding together with a cursor at the native
        // leading edge. This does not assume a font's document inset or force
        // a right-to-left line's far-away logical start to the left edge.
        if (rect.x <= area.leftPadding + area.font.pixelSize) next = 0;
        else if (rect.x < next + 2) next = rect.x - 2;
        else if (rect.x + rect.width > next + view.width - 2) next = rect.x + rect.width - view.width + 2;
        view.contentX = Math.max(0, Math.min(Math.max(0, view.contentWidth - view.width), next));
    }
    Label {
        visible: block.language.length > 0
        text: block.language; textFormat: Text.PlainText
        font.family: "monospace"; font.pixelSize: 9; color: app.colors.textSecondary
        Layout.fillWidth: true; wrapMode: Text.WrapAnywhere
    }
    Flickable {
        id: view
        objectName: block.textName + "HorizontalViewport"
        Layout.fillWidth: true; Layout.minimumWidth: 0
        implicitHeight: area.implicitHeight + (bar.visible ? bar.implicitHeight + 2 : 0)
        contentWidth: block.limited ? width : Math.max(width, area.implicitWidth)
        contentHeight: height
        clip: true; boundsBehavior: Flickable.StopAtBounds
        // Text owns pointer selection. The native bar and horizontal wheel own
        // panning; vertical input uses the enclosing panel's existing handler.
        interactive: false
        onContentWidthChanged: contentX = Math.max(0, Math.min(Math.max(0, contentWidth - width), contentX))
        Rectangle { objectName: block.textName + "Surface"; parent: view; anchors.fill: parent; z: -1; radius: 4; color: app.colors.raisedBg }
        ReadingWheelHandler {
            zoomEnabled: false; horizontalOnly: true
            onScrollRequested: function(dx, dy) { block.pan(dx); }
        }
        ReadingWheelHandler {
            zoomEnabled: false; horizontalOnly: true; orientation: Qt.Vertical
            acceptedModifiers: Qt.ShiftModifier
            onScrollRequested: function(dx, dy) { block.pan(dx); }
        }
        ReadingWheelHandler {
            zoomEnabled: false; acceptedModifiers: Qt.NoModifier
            scrollEnabled: !!block.renderer && !!block.renderer.viewport
            onScrollRequested: function(dx, dy) { block.renderer.scrollParent(dy); }
        }
        TextArea {
            id: area
            objectName: block.textName
            width: block.limited ? view.width : Math.max(view.width, implicitWidth)
            text: block.sourceText
            textFormat: TextEdit.PlainText
            wrapMode: block.limited ? TextEdit.WrapAnywhere : TextEdit.NoWrap
            readOnly: true; selectByMouse: true; selectByKeyboard: true
            padding: 7; background: null
            font.family: "monospace"; font.pixelSize: 12; color: app.colors.textPrimary
            Accessible.name: qsTr("Code example")
            Keys.onPressed: function(event) {
                if (block.renderer) block.renderer.cursorKey(area, event);
                if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down, Qt.Key_Home,
                     Qt.Key_End, Qt.Key_PageUp, Qt.Key_PageDown].indexOf(event.key) >= 0) {
                    const owner = app.currentReader;
                    Qt.callLater(block.reveal, owner, owner ? owner.documentGeneration : 0, block.sourceText);
                }
                event.accepted = false;
            }
        }
        ScrollBar.horizontal: AiReadingScrollBar { id: bar }
    }
    Label {
        visible: block.limited
        text: qsTr("This long code example wraps to keep the native view bounded. Copy keeps the complete original answer.")
        textFormat: Text.PlainText; wrapMode: Text.Wrap
        Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11
    }
}

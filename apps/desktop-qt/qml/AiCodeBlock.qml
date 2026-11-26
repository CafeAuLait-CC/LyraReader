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
    function reveal(owner, generation, source) {
        if (!area.activeFocus || !visible || !owner || app.currentReader !== owner
                || owner.documentGeneration !== generation || source !== sourceText) return;
        view.revealCursor(area);
    }
    Label {
        visible: block.language.length > 0
        text: block.language; textFormat: Text.PlainText
        font.family: "monospace"; font.pixelSize: 9; color: app.colors.textSecondary
        Layout.fillWidth: true; wrapMode: Text.WrapAnywhere
    }
    AiHorizontalReadingView {
        id: view
        app: block.app; renderer: block.renderer; viewName: block.textName
        Layout.fillWidth: true
        measuredWidth: block.limited ? 0 : area.implicitWidth
        measuredHeight: area.implicitHeight
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
    }
    Label {
        visible: block.limited
        text: qsTr("This long code example wraps to keep the native view bounded. Copy keeps the complete original answer.")
        textFormat: Text.PlainText; wrapMode: Text.Wrap
        Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11
    }
}

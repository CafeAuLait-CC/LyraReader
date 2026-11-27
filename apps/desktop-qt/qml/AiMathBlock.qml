import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: block
    required property var app
    required property string sourceText
    required property string markup
    property string textName: ""
    property var renderer: null
    readonly property var textControl: area
    Layout.minimumWidth: 0
    TextArea {
        id: area
        objectName: block.textName
        text: block.markup; textFormat: TextEdit.RichText
        Layout.fillWidth: true; Layout.minimumWidth: 0
        readOnly: true; selectByMouse: true; selectByKeyboard: true
        wrapMode: TextEdit.Wrap; padding: 0; background: null
        font.pixelSize: 17; color: block.app.colors.textPrimary
        Accessible.name: qsTr("Mathematics: %1").arg(block.sourceText)
        ContextMenu.menu: sourceMenu
        Keys.onShortcutOverride: function(event) {
            if(event.key===Qt.Key_Menu || (event.key===Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier)))event.accepted=true;
        }
        Keys.onPressed: function(event) {
            if(event.key===Qt.Key_Menu || (event.key===Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
                sourceMenu.popup(0,Math.max(0,Math.min(area.height,area.cursorRectangle.y+area.cursorRectangle.height)));
                event.accepted=true;
            } else if(block.renderer)block.renderer.cursorKey(area,event);
        }
        ReadingTextToolTip {app: block.app; area: parent}
    }
    LyraMenu {
        id: sourceMenu
        parent: area
        objectName: block.textName + "MathMenu"
        property string sourceSnapshot: ""
        onAboutToShow: sourceSnapshot = block.sourceText

        LyraMenuItem {
            objectName: block.textName + "CopyMathSource"
            text: qsTr("Copy LaTeX source")
            onTriggered: if(block.app.session)block.app.session.copyText(sourceMenu.sourceSnapshot)
        }
    }
}

import QtQuick
import QtQuick.Controls

Item {
    id: layer
    required property var app
    required property int page
    readonly property var editor: app.contentEditor
    ScrollView {
        id: textScroll
        objectName: "contentInlineScroll"+layer.page
        visible: app.secondaryRow==="edit" && editor.inlineEditing && editor.textDraft && editor.draft.page===layer.page
        x: visible ? Math.max(0,editor.payload.bounds.x*app.zoom) : 0
        y: visible ? Math.max(0,editor.payload.bounds.y*app.zoom) : 0
        width: visible ? Math.max(1,Math.min(layer.width-x,Math.max(80,editor.payload.bounds.width*app.zoom))) : 0
        readonly property real viewportY: {
            const scrollPosition=app.pageList.contentY;
            return layer.mapToItem(app.pageList,0,y).y;
        }
        readonly property real heightLimit: Math.max(48,Math.min(layer.height-y,app.pageList.height-viewportY-8))
        // This changes only the native editing viewport, never the command's PDF bounds.
        height: visible ? Math.min(heightLimit,Math.max(48,editor.payload.bounds.height*app.zoom,
            Math.ceil(textEditor.contentHeight+textEditor.topPadding+textEditor.bottomPadding+2))) : 0
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        background: Rectangle {color:app.colors.fieldBg;border.color:app.colors.focusRing;border.width:2}
        TextArea {
            id: textEditor
            objectName: "contentInlineText"+layer.page
            width: textScroll.availableWidth
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.Wrap
            text: textScroll.visible ? (editor.payload.text || "") : ""
            font.pixelSize: textScroll.visible ? Math.max(8,editor.payload.size*app.zoom) : 12
            color: app.colors.textPrimary
            selectByMouse: true
            background: null
            onVisibleChanged: {
                if(visible)Qt.callLater(function(){if(textEditor.visible)textEditor.forceActiveFocus();});
                else if(activeFocus){focus=false;app.pageList.forceActiveFocus();}
            }
            onTextChanged: if(textScroll.visible && editor.inlineEditing && activeFocus)editor.changeText(text)
            Keys.onEscapePressed: editor.discard()
            Keys.onPressed: function(event){if(event.key===Qt.Key_Return && (event.modifiers & Qt.ControlModifier)){editor.commitDraft();event.accepted=true;}}
            Accessible.name: qsTr("Edit actual PDF text; Control+Return applies, Escape cancels")
        }
    }
}

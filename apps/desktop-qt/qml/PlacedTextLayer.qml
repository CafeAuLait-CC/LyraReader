import QtQuick
import QtQuick.Controls
import "ReaderLogic.js" as Logic

Item {
    id: layer
    required property var app
    required property int page
    readonly property var editor: app.placedTextEditor
    readonly property bool showing: editor.current && !!editor.entry && editor.entry.page===page && editor.token.length>0 && !editor.cancelling
    readonly property real paddingPt: 3
    readonly property real maximumWidth: showing ? Math.max(1,app.currentReader.pages[page].width-editor.rect.x) : 1
    readonly property real maximumHeight: showing ? Math.max(1,app.currentReader.pages[page].height-editor.rect.y) : 1
    Text {
        id: measure
        visible: false
        text: layer.showing ? editor.text : ""
        textFormat: Text.PlainText
        font: input.font
        width: Math.max(1,(layer.maximumWidth-2*layer.paddingPt)*app.zoom)
        wrapMode: Text.Wrap
        function fit() {
            if(!layer.showing || editor.cancelling)return;
            // QTextDocument can wrap a fractional-pixel edge differently from Text.
            // Keep a pixel of width slack and use the editor's actual line height.
            const width=Math.min(layer.maximumWidth,Math.max(24,(Math.ceil(contentWidth)+1)/app.zoom+2*layer.paddingPt));
            const height=Math.min(layer.maximumHeight,Math.max(20,(Math.ceil(Math.max(contentHeight,input.contentHeight))+1)/app.zoom+2*layer.paddingPt));
            editor.resizeBox(width,height);
        }
        onContentWidthChanged: Qt.callLater(fit)
        onContentHeightChanged: Qt.callLater(fit)
    }
    TextArea {
        id: input
        objectName: "placedTextInput"+layer.page
        visible: layer.showing
        enabled: !editor.cancelling
        readOnly: editor.closing
        x: visible ? editor.rect.x*app.zoom : 0
        y: visible ? editor.rect.y*app.zoom : 0
        width: visible ? editor.rect.width*app.zoom : 0
        height: visible ? editor.rect.height*app.zoom : 0
        padding: layer.paddingPt*app.zoom
        text: visible ? editor.text : ""
        textFormat: TextEdit.PlainText
        wrapMode: TextEdit.Wrap
        selectByMouse: true
        font.family: app.annotationFont
        font.pixelSize: visible ? Math.max(1,editor.entry.fontSize*app.zoom) : 14
        color: visible ? Logic.displayColor(Logic.color(editor.entry),app.paperAppearance) : app.colors.textPrimary
        selectionColor: app.colors.selectedBg
        selectedTextColor: app.colors.selectedFg
        background: Rectangle {color:app.currentReader.paperBackground(app.paperAppearance);border.color:app.colors.focusRing;border.width:1}
        onTextChanged: if(visible && activeFocus && !readOnly)editor.change(text)
        onContentHeightChanged: Qt.callLater(measure.fit)
        onVisibleChanged: if(!visible && activeFocus) {
            focus=false;
            app.pageList.forceActiveFocus();
        }
        Keys.onEscapePressed: function(event){editor.finish(true);event.accepted=true;}
        Keys.onPressed: function(event) {
            if((event.key===Qt.Key_Return || event.key===Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                editor.finish(false);event.accepted=true;
            }
        }
        Accessible.name: qsTr("Edit placed text; Control+Return finishes, Escape cancels")
    }
    Label {
        visible: layer.showing && (editor.error.length>0 || editor.missingGlyphs.length>0)
        x: input.x;y:input.y+input.height+4
        width: Math.min(320,layer.width-x)
        text: editor.error || qsTr("The PDF font cannot draw: %1. The text is preserved; unsupported characters appear as boxes in the PDF.").arg(editor.missingGlyphs.join(" "))
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: editor.error.length ? app.colors.errorFg : app.colors.warningFg
        background: Rectangle {color:app.colors.fieldBg}
    }
    Connections {
        target: editor
        function onLayoutRequested() {measure.fit();}
        function onFocusSerialChanged() {
            if(!layer.showing)return;
            const token=editor.token;
            Qt.callLater(function(){if(layer.showing && editor.token===token){input.forceActiveFocus();input.selectAll();}});
        }
    }
}

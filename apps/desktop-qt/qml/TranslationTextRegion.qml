import QtQuick
import QtQuick.Controls

// Native read-only text, with stable source-sized layouts behind the paper clips.
// A paper reveal changes only clip frames, never the text or its selection.
Item {
    id: region
    required property var app
    required property var paperMap
    required property rect sourceRect
    required property string translatedText
    required property string displayText
    required property real fontSize
    required property color paper
    property bool showing: true
    readonly property real zoom: app.zoom
    readonly property bool current: !!paperMap && paperMap.controller===app.currentReader && !app.currentReader.loading
    PaperRegion { id: geometry; app:region.app;paperMap:region.paperMap;sourceRect:region.sourceRect }
    x: geometry.bounds.x*zoom
    y: geometry.bounds.y*zoom
    width: geometry.bounds.width*zoom
    height: geometry.bounds.height*zoom
    visible: showing && current && geometry.hit
    Repeater {
        id: pieces
        model: 2
        Item {
            id: piece
            required property int index
            readonly property var target: (geometry.packet.pieces || [])[index] || null
            readonly property var original: {
                if(!target || !region.current)return {hit:false};
                const epoch=region.paperMap.paperGeometryRevision;
                if(epoch!==geometry.revision)return {hit:false};
                return region.paperMap.paperGeometryActive ? region.paperMap.paperPoint(Qt.point(target.x,target.y))
                    : {hit:true,x:target.x,y:target.y};
            }
            readonly property bool present: !!target && original.hit===true
            x: present ? (target.x-geometry.bounds.x)*region.zoom : 0
            y: present ? (target.y-geometry.bounds.y)*region.zoom : 0
            width: present ? target.width*region.zoom : 0
            height: present ? target.height*region.zoom : 0
            clip: true
            visible: present
            Rectangle { anchors.fill:parent;color:region.paper }
            Loader {
                active: region.showing && region.current && !!piece.target
                anchors.fill:parent
                sourceComponent: Item {
                    MouseArea {
                        anchors.fill:parent
                        cursorShape:Qt.IBeamCursor
                        acceptedButtons:Qt.LeftButton
                        // Insets cover original PDF glyphs too. They belong to this
                        // native text view, rather than the PDF pointer below it.
                        onPressed: function(mouse) {
                            editor.forceActiveFocus(Qt.MouseFocusReason);
                            const point=mapToItem(editor,mouse.x,mouse.y);
                            editor.cursorPosition=editor.positionAt(point.x,point.y);
                            mouse.accepted=true;
                        }
                    }
                    TextEdit {
                        id: editor
                        objectName:"inplaceTranslationText"
                        x: piece.present ? (region.sourceRect.x+2-piece.original.x)*region.zoom : 0
                        y: piece.present ? (region.sourceRect.y+1-piece.original.y)*region.zoom : 0
                        width: Math.max(1,region.sourceRect.width-4)
                        height: Math.max(1,region.sourceRect.height-2)
                        scale: region.zoom
                        transformOrigin:Item.TopLeft
                        // Bound idle layout work; entering the native text control
                        // exposes the full answer for selection and plain-text copy.
                        property bool fullLayout: false
                        text: fullLayout ? region.translatedText : region.displayText
                        textFormat:TextEdit.PlainText
                        font.pixelSize:region.fontSize
                        color:region.paperMap.translationInkColor(region.paper)
                        selectionColor:region.app.colors.selectedBg
                        selectedTextColor:region.app.colors.selectedFg
                        textMargin:0
                        padding:0
                        activeFocusOnTab:true
                        readOnly:true
                        selectByMouse:true
                        selectByKeyboard:true
                        wrapMode:TextEdit.Wrap
                        onActiveFocusChanged: {
                            if(activeFocus && region.current && region.visible) {
                                fullLayout=true;
                                region.app.selection=null;
                            } else Qt.callLater(function() {
                                if(!editor.activeFocus && !textMenu.visible) {
                                    editor.deselect();editor.fullLayout=false;
                                }
                            });
                        }
                        onVisibleChanged: if(!visible){focus=false;deselect();fullLayout=false;textMenu.close();}
                        function openTextMenu(point) {
                            if(!region.visible || !region.current)return;
                            forceActiveFocus(Qt.PopupFocusReason);
                            textMenu.popup(point.x,point.y);
                        }
                        TapHandler {
                            acceptedButtons:Qt.RightButton
                            onTapped: function(eventPoint) { editor.openTextMenu(eventPoint.position); }
                        }
                        Keys.onShortcutOverride: function(event) {
                            if(event.key===Qt.Key_Escape || event.key===Qt.Key_Menu
                                    || (event.key===Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier)))event.accepted=true;
                        }
                        Keys.onPressed: function(event) {
                            if(event.key===Qt.Key_Menu || (event.key===Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
                                editor.openTextMenu(Qt.point(cursorRectangle.x,cursorRectangle.y+cursorRectangle.height));
                                event.accepted=true;
                            }
                        }
                        Keys.onEscapePressed: function(event) {
                            deselect();focus=false;region.app.focusReadingView();event.accepted=true;
                        }
                        Accessible.name:qsTr("Translated passage")
                        Accessible.description:qsTr("Read-only translation. Select text to copy it; Escape returns to the PDF.")
                        LyraMenu {
                            id:textMenu
                            objectName:"translationTextMenu"
                            theme:region.app.colors
                            onClosed: if(region.visible && region.current)editor.forceActiveFocus(Qt.PopupFocusReason)
                            LyraMenuItem { text:qsTr("Copy");icon.source:"qrc:/icons/copy.svg";enabled:editor.selectedText.length>0;onTriggered:editor.copy() }
                            LyraMenuItem { text:qsTr("Select all");icon.source:"";onTriggered:editor.selectAll() }
                        }
                    }
                }
            }
        }
    }
}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "ReaderLogic.js" as Logic

// One paper outside virtualized delegates; source identity owns both text and edit callbacks.
Item {
    id: paper
    objectName:"annotationNotePaperController"
    required property var app
    property var owner:null
    property var generation:null
    property string sourceId:""
    property bool sourceForeign:false
    property bool opened:false
    property int epoch:0
    property var adoptionOwner:null
    property double adoptionRequest:-1
    property int adoptionEpoch:-1
    property bool adopting:false
    property string error:""
    property bool revealPending:false
    property bool navigatePending:false
    property bool awaitingRestore:false
    property int revealInteraction:-1

    readonly property var editor:app.placedTextEditor
    readonly property bool current:opened && owner===app.currentReader && generation===owner.documentGeneration
    readonly property var entry:current ? app.annotations.find(function(a){return a.id===sourceId && !!a.foreign===sourceForeign;}) || null : null
    readonly property bool editing:!!entry && editor.current && editor.noteOnly && editor.entry.id===entry.id && !!editor.token && !editor.cancelling
    readonly property string savedText:entry ? String(entry.note || entry.contents || "") : ""
    readonly property int textLimit:120000
    readonly property bool tooLong:savedText.length>textLimit
    readonly property bool canEdit:!!entry && app.annotationNoteKind(entry) && app.canModifyPdf && !tooLong && !Logic.annotationUnsupportedReason(entry).length
    readonly property var frame:entry ? app.documentCanvas.pageFrame(entry.page,app.documentCanvas.placementEpoch) : null
    property int returnBodyEpoch:-1
    function restoreReadingFocus() {
        const expectedEpoch=returnBodyEpoch;returnBodyEpoch=-1;
        if(expectedEpoch<0)return;
        Qt.callLater(function(){if(paper.epoch===expectedEpoch && paper.current && !paper.editing && !paper.revealPending && body.visible)body.forceActiveFocus();});
    }
    function finishEditing(cancel) {
        if(!editing)return;
        returnBodyEpoch=epoch;body.forceActiveFocus();editor.finish(cancel);
    }
    function handlesAdoption(source,id){return adoptionOwner===source && adoptionRequest===id;}
    function display(source,annotation) {
        if(!source || !annotation)return;
        if(opened && owner===source && sourceId===annotation.id && sourceForeign===!!annotation.foreign)return;
        ++epoch;owner=source;generation=source.documentGeneration;sourceId=annotation.id;sourceForeign=!!annotation.foreign;error="";opened=true;
    }
    function openNote(annotation,toggle,navigate) {
        if(toggle && current && entry && entry.id===annotation.id && sourceForeign===!!annotation.foreign){close();return;}
        display(app.currentReader,annotation);app.selectedAnnotation=annotation;app.selection=null;
        revealPending=true;navigatePending=!!navigate;awaitingRestore=!!(app.positionRestoring || app.pendingPosition || app.pendingLayoutPosition);revealInteraction=app.documentCanvas.interactionEpoch;revealTimer.restart();
    }
    function reveal() {
        if(!revealPending || !current || !entry)return;
        if(app.positionRestoring || app.pendingPosition || app.pendingLayoutPosition){awaitingRestore=true;return;}
        if(awaitingRestore)return;
        if(revealInteraction!==app.documentCanvas.interactionEpoch){revealPending=false;return;}
        if(navigatePending){navigatePending=false;app.navigate(entry.page,entry.rect ? entry.rect.y : 0);revealInteraction=app.documentCanvas.interactionEpoch;revealTimer.restart();return;}
        if(!frame || !geometry.hit)return;
        // This is view-pixel clipping against the actual instantiated sheet. PDF/crop/rotate
        // transforms remain in PaperRegion and the shared geometry service.
        const view=app.pageList,left=anchor.x,right=left+anchor.width;
        revealPending=false;
        if(left<12)view.contentX=Math.max(0,view.contentX+left-12);
        else if(right>width-12)view.contentX=Math.min(Math.max(0,view.contentWidth-view.width),view.contentX+right-width+12);
        if(!editing)body.forceActiveFocus();
    }
    function restored() {
        if(!revealPending || !current || app.positionRestoring || app.pendingPosition || app.pendingLayoutPosition)return;
        // A known restore owns its internal navigate. A subsequent input/navigation
        // still changes this epoch and wins over our queued note reveal.
        if(awaitingRestore){awaitingRestore=false;revealInteraction=app.documentCanvas.interactionEpoch;}
        revealTimer.restart();
    }
    function restoreLayoutSettled() {
        if(!revealPending)return;
        const requestEpoch=epoch;
        Qt.callLater(function(){if(paper.epoch===requestEpoch)paper.restored();});
    }
    Connections {target:paper.app.pageList;function onMovementStarted(){paper.revealPending=false;paper.awaitingRestore=false;}}
    Timer {id:revealTimer;interval:0;onTriggered:paper.reveal();}
    onFrameChanged:if(revealPending)revealTimer.restart()
    onAnchorChanged:if(revealPending)revealTimer.restart()
    function close() {
        // A rejected begin has no token and cannot have accepted any new text. Keep any
        // pre-existing Reader draft, while allowing its unchanged reading paper to close.
        if(editor.current && editor.noteOnly && editor.request<0 && !editor.token.length && editor.error.length && !editor.dirty)editor.abandon();
        if(editor.current && editor.noteOnly && editor.deferAction(function(){paper.close();}))return;
        ++epoch;opened=false;owner=null;sourceId="";error="";revealPending=false;revealTimer.stop();
        app.focusReadingView();
    }
    function edit() {
        if(!current || !entry || !canEdit || adopting || editing)return;
        if(editor.deferAction(function(){paper.edit();}))return;
        error="";
        app.selectedAnnotation=entry;
        if(entry.foreign){adoptionOwner=owner;adoptionEpoch=epoch;adopting=true;adoptionRequest=owner.submit("file_adopt",{id:entry.id});}
        else editor.openExisting(entry);
    }
    Connections {
        target:paper.owner
        function onDocumentReset(){paper.opened=false;++paper.epoch;paper.owner=null;}
    }
    Connections {
        target:paper.adoptionOwner
        function onCommandFinished(id,op,result,message) {
            if(id!==paper.adoptionRequest || op!=="file_adopt")return;
            paper.adopting=false;
            if(!paper.current || paper.adoptionEpoch!==paper.epoch)return;
            if(message.length){paper.error=message;return;}
            const a=(result.annotations || []).find(function(a){return a.id===result.selected_id;});
            if(!a){paper.error=qsTr("The adopted note is unavailable. Reopen the note.");return;}
            const annotation=Logic.normalized(a,false);paper.sourceId=annotation.id;paper.sourceForeign=false;paper.app.selectedAnnotation=annotation;
            paper.editor.openExisting(annotation);
        }
    }
    Connections {
        target:paper.editor
        // Wait for the acknowledged end; cancellation leaves edit mode before its
        // shared transaction closes and transfers focus back to the canvas.
        function onActiveChanged(){if(!paper.editor.active)paper.restoreReadingFocus();}
        function onEntryChanged(){if(paper.editor.entry && paper.editor.owner && paper.editor.current && paper.editor.noteOnly)paper.display(paper.editor.owner,paper.editor.entry);}
        function onFocusSerialChanged(){if(paper.editor.entry && paper.editor.owner && paper.editor.current && paper.editor.noteOnly)paper.display(paper.editor.owner,paper.editor.entry);if(paper.editing)Qt.callLater(function(){if(paper.editing){body.forceActiveFocus();body.cursorPosition=body.length;}});}
    }
    Connections {target:paper.app;function onPositionRestoringChanged(){paper.restored();} function onPendingPositionChanged(){paper.restoreLayoutSettled();} function onPendingLayoutPositionChanged(){paper.restoreLayoutSettled();} function onCurrentReaderChanged(){paper.opened=false;paper.owner=null;paper.revealPending=false;++paper.epoch;} function onAnnotationsChanged(){if(paper.current && !paper.entry && !paper.adopting){paper.opened=false;paper.owner=null;++paper.epoch;}}}
    PaperRegion {
        id:geometry
        app:paper.app
        paperMap:paper.frame ? paper.frame.paperMap : null
        sourceRect:paper.entry && paper.entry.rect ? Qt.rect(paper.entry.rect.x,paper.entry.rect.y,paper.entry.rect.width,paper.entry.rect.height) : Qt.rect(0,0,0,0)
    }
    readonly property rect anchor:frame && geometry.hit ? Qt.rect(frame.x+geometry.bounds.x*app.zoom,frame.y+geometry.bounds.y*app.zoom,geometry.bounds.width*app.zoom,geometry.bounds.height*app.zoom) : Qt.rect(0,0,0,0)
    Rectangle {
        id:panel;objectName:"annotationNotePaper"
        visible:paper.current && !paper.revealPending && !!paper.entry && !!paper.frame && geometry.hit && paper.anchor.x+paper.anchor.width>0 && paper.anchor.x<paper.width && paper.anchor.y+paper.anchor.height>0 && paper.anchor.y<paper.height
        width:Math.min(360,Math.max(1,paper.width-24));height:Math.min(340,Math.max(1,paper.height-24))
        x:Math.max(12,Math.min(paper.width-width-12,paper.anchor.x+paper.anchor.width+10))
        y:Math.max(12,Math.min(paper.height-height-12,paper.anchor.y))
        color:app.colors.noteBg;border.color:app.colors.noteFg;border.width:1;radius:6;clip:true
        MouseArea {
            anchors.fill:parent;acceptedButtons:Qt.AllButtons
            onWheel:function(event){event.accepted=true;}
        }
        ColumnLayout {
            anchors.fill:parent;anchors.margins:10;anchors.topMargin:paper.editing ? 10 : 30;spacing:6
            ScrollView {
                id:scroll;objectName:"annotationNoteScroll";Layout.fillWidth:true;Layout.fillHeight:true;clip:true;contentWidth:availableWidth
                TextArea {
                    id:body;objectName:"annotationNoteBody";width:scroll.availableWidth
                    text:paper.editing ? paper.editor.text : paper.savedText.slice(0,paper.textLimit)
                    readOnly:!paper.editing || paper.editor.closing;selectByMouse:true;wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText
                    font.pixelSize:13;rightPadding:14;color:app.colors.noteFg;selectionColor:app.colors.selectedBg;selectedTextColor:app.colors.selectedFg
                    background:Rectangle {color:app.colors.noteBg}
                    onTextChanged:if(paper.editing && activeFocus && !readOnly)paper.editor.change(text)
                    TapHandler {acceptedButtons:Qt.LeftButton;onTapped:if(body.readOnly)paper.edit();}
                    Accessible.name:paper.editing ? qsTr("Edit note; Control+Return finishes, Escape cancels") : qsTr("Read note")
                    Accessible.description:!paper.canEdit ? qsTr("Read only") : !paper.editing ? qsTr("Click the body or press Return or F2 to edit this note") : ""
                    Keys.onShortcutOverride:function(event){if(event.key===Qt.Key_Escape)event.accepted=true;}
                    Keys.onEscapePressed:function(event){if(paper.editing)paper.finishEditing(true);else paper.close();event.accepted=true;}
                    Keys.onPressed:function(event){
                        if(paper.editing && (event.modifiers & Qt.ControlModifier) && (event.key===Qt.Key_Return || event.key===Qt.Key_Enter)){paper.finishEditing(false);event.accepted=true;}
                        else if(!paper.editing && (event.key===Qt.Key_F2 || event.key===Qt.Key_Return || event.key===Qt.Key_Enter)){paper.edit();event.accepted=true;}
                    }
                }
                ScrollBar.vertical:ScrollBar {
                    id:bar;objectName:"annotationNoteScrollBar";policy:ScrollBar.AlwaysOn
                    parent:scroll;x:scroll.mirrored ? 0 : scroll.width-width;y:scroll.topPadding;height:scroll.availableHeight
                    background:Rectangle {color:app.colors.noteBg}
                    contentItem:Rectangle {implicitWidth:10;implicitHeight:28;radius:4;color:app.colors.noteFg;opacity:bar.pressed || bar.active ? 1 : .85}
                }
            }
            Label {visible:text.length>0;Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText;color:app.colors.noteFg;text:paper.error || (paper.editor.current && paper.editor.noteOnly && paper.editor.error || "") || (paper.tooLong ? qsTr("Showing the first %1 characters. Export annotations to read the complete note.").arg(paper.textLimit) : !paper.canEdit ? Logic.annotationUnsupportedReason(paper.entry) || qsTr("Read only") : "")}
            RowLayout {
                objectName:"annotationNoteActions";visible:paper.editing;Layout.fillWidth:true;spacing:8
                Item {Layout.fillWidth:true}
                Button {objectName:"cancelReadingNote";text:qsTr("Cancel");flat:true;font.pixelSize:11;palette.buttonText:app.colors.noteFg;enabled:!paper.editor.closing;onClicked:paper.finishEditing(true)}
                Button {objectName:"doneReadingNote";text:qsTr("Done");flat:true;font.pixelSize:11;font.bold:true;palette.buttonText:app.colors.noteFg;enabled:!paper.editor.closing;onClicked:paper.finishEditing(false)}
            }
        }
        LyraToolButton {
            objectName:"closeReadingNote";anchors.top:parent.top;anchors.right:parent.right;anchors.margins:6
            visible:!paper.editing;width:28;height:28;symbol:"close";text:qsTr("Close note");icon.color:app.colors.noteFg
            onClicked:paper.close()
        }
    }
}

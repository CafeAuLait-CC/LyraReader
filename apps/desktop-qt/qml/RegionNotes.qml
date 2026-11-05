import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

Dialog {
    id:notes
    objectName:"regionNotes"
    required property var app
    property var owner:null
    property var detail:null
    property var readId:0
    property string selectedId:""
    property int turnIndex:0
    readonly property var history:owner ? owner.regionHistory : ({})
    readonly property var turns:detail ? detail.turns || [] : []
    readonly property var turn:turns.length ? turns[Math.min(turnIndex,turns.length-1)] : detail && (detail.question || detail.answer) ? detail : null
    function stateLabel(state){return state==="finished" ? qsTr("Completed") : state==="cancelled" ? qsTr("Stopped") : state==="failed" ? qsTr("Failed") : qsTr("No answer yet");}
    parent:Overlay.overlay
    x:(app.width-width)/2;y:(app.height-height)/2
    width:Math.min(720,app.width-24);height:Math.min(760,app.height-48)
    title:qsTr("Reading notes");modal:false;focus:true;standardButtons:Dialog.Close
    background:Rectangle {color:notes.app.colors.panelBg;border.color:notes.app.colors.separator;radius:8}
    onAboutToShow:{owner=app.currentReader;detail=null;selectedId="";owner.submit("region_list",{});if(owner.regionNoteDraft.id)load(owner.regionNoteDraft.id);}
    onClosed:{remove.close();detail=null;readId=0;if(owner===app.currentReader)app.focusReadingView();}
    Connections {target:notes.app;function onCurrentReaderChanged(){notes.close();}}
    function load(id){if(owner.regionNoteDraft.id && owner.regionNoteDraft.id!==id){app.operationStatus=qsTr("Save or discard the current reading note before selecting another area.");return;}selectedId=id;detail=null;readId=owner.submit("region_get",{id:id});}
    Connections {
        target:notes.owner
        function onDocumentReset(){notes.close();}
        function onCommandFinished(id,op,result,error){
            if(id===notes.readId){notes.readId=0;if(!error){notes.detail=result;notes.turnIndex=0;noteText.text=notes.owner.regionNoteDraft.id===result.id ? notes.owner.regionNoteDraft.text : result.knowledgeNote || "";}}
            if(op==="region_note" && !error && notes.detail && result.saved_id===notes.selectedId){var updated=notes.detail;updated.knowledgeNote=result.saved_note;notes.detail=updated;}
            if(op==="region_delete" && !error && result.saved_id===notes.selectedId){notes.detail=null;notes.selectedId="";}
        }
    }
    contentItem:ColumnLayout {
        spacing:8
        Label {text:qsTr("Local captures and conversations. Opening notes sends no request.");wrapMode:Text.Wrap;Layout.fillWidth:true;color:notes.app.colors.textSecondary}
        Label {text:notes.history.error || (notes.history.warnings || []).join("\n");visible:text.length>0;textFormat:Text.PlainText;wrapMode:Text.Wrap;Layout.fillWidth:true;color:notes.app.colors.warningFg}
        Label {objectName:"regionNotesEmpty";visible:!list.count && !notes.history.error && !notes.history.foreign_count && !notes.history.writes_blocked;text:qsTr("No saved areas. Use Select & Ask, then Save to Reading notes.");wrapMode:Text.Wrap;Layout.fillWidth:true}
        ListView {
            id:list;objectName:"regionNotesList"
            Layout.fillWidth:true;Layout.preferredHeight:Math.min(150,contentHeight);Layout.minimumHeight:Math.min(70,contentHeight)
            model:notes.history.entries || [];clip:true;spacing:2
            ScrollBar.vertical:ScrollBar{}
            delegate:ItemDelegate {
                required property var modelData
                width:list.width
                objectName:"regionNoteRow"+modelData.number
                text:qsTr("Region %1 · page %2 · %3").arg(modelData.number).arg(modelData.page+1).arg(modelData.draft || modelData.question || notes.stateLabel(modelData.state))
                highlighted:notes.selectedId===modelData.id
                onClicked:notes.load(modelData.id)
            }
        }
        BusyIndicator {visible:!!notes.readId;running:visible;Layout.alignment:Qt.AlignHCenter}
        ScrollView {
            visible:!!notes.detail;Layout.fillWidth:true;Layout.fillHeight:true;contentWidth:availableWidth;clip:true
            ColumnLayout {
                width:parent.width;spacing:8
                Label {text:notes.detail && notes.detail.locationInvalidated ? qsTr("The document revision changed. This saved capture remains readable; its old location is unavailable.") : qsTr("Saved capture in original colours. PDF edits do not change this snapshot.");wrapMode:Text.Wrap;Layout.fillWidth:true;color:notes.app.colors.textSecondary}
                Item {
                    Layout.fillWidth:true;Layout.preferredHeight:160
                    PdfCrop {
                        objectName:"regionNoteImage"
                        anchors.centerIn:parent
                        readonly property var attachment:notes.detail ? notes.detail.attachment : ({})
                        width:Math.min(parent.width,160*(attachment.pixelWidth || 1)/(attachment.pixelHeight || 1));height:width*(attachment.pixelHeight || 1)/(attachment.pixelWidth || 1)
                        source:attachment.png ? "data:image/png;base64,"+attachment.png : ""
                        Accessible.role:Accessible.Graphic;Accessible.name:qsTr("Saved region capture")
                    }
                }
                TextArea {objectName:"regionNoteCapturedText";Layout.fillWidth:true;readOnly:true;selectByMouse:true;wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText;text:notes.detail ? notes.detail.attachment.text.slice(0,120000) : "";Accessible.name:qsTr("Captured text")}
                Label {text:notes.detail ? qsTr("Saved question draft: %1").arg((notes.detail.draftQuestion || "").slice(0,120000)) : "";wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                ComboBox {visible:notes.turns.length>1;Layout.fillWidth:true;model:notes.turns.map((t,i)=>qsTr("Turn %1 · %2").arg(i+1).arg(notes.stateLabel(t.state)));onActivated:notes.turnIndex=currentIndex;Accessible.name:qsTr("Conversation turn")}
                Label {text:notes.turn ? qsTr("%1 · %2").arg(notes.stateLabel(notes.turn.state)).arg(notes.turn.question.slice(0,120000)) : "";wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                TextArea {objectName:"regionNoteAnswer";visible:!!notes.turn;Layout.fillWidth:true;readOnly:true;selectByMouse:true;wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText;text:notes.turn ? notes.turn.answer.slice(0,120000) : "";Accessible.name:qsTr("Saved answer")}
                Label {visible:!!notes.turn && notes.turn.answer.length>120000;text:qsTr("Long answer preview limited to 120,000 characters. Copy answer keeps the complete text.");wrapMode:Text.Wrap;Layout.fillWidth:true;color:notes.app.colors.textSecondary}
                Label {visible:!!notes.turn;text:qsTr("Historical page markers are shown as text; they do not create verified navigation links.");wrapMode:Text.Wrap;Layout.fillWidth:true;color:notes.app.colors.textSecondary}
                Button {text:qsTr("Copy answer");visible:!!notes.turn;enabled:!!notes.turn && !!notes.app.session;onClicked:notes.app.session.copyText(notes.turn.answer)}
                Label {text:qsTr("Knowledge note");font.bold:true}
                TextArea {id:noteText;objectName:"regionKnowledgeNote";readOnly:!!notes.history.writes_blocked;selectByMouse:true;Layout.fillWidth:true;wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText;placeholderText:qsTr("Keep your own reading note…");Accessible.name:qsTr("Knowledge note");onTextChanged:if(notes.detail && notes.owner){if(text!==(notes.detail.knowledgeNote || "") || notes.owner.isSavingRegionNote())notes.owner.setRegionNoteDraft(notes.selectedId,text);else if(notes.owner.regionNoteDraft.id===notes.selectedId)notes.owner.discardRegionNoteDraft();}}
                Button {objectName:"saveRegionKnowledgeNote";text:qsTr("Save knowledge note");enabled:notes.owner && !!notes.owner.regionNoteDraft.id && !notes.owner.pendingCommands && !notes.history.writes_blocked;onClicked:notes.owner.saveRegionNoteDraft()}
                Label {visible:notes.owner && notes.owner.regionNoteDraft.id===notes.selectedId;text:qsTr("Unsaved reading note. Save or discard it before closing this document.");Layout.fillWidth:true;wrapMode:Text.Wrap;color:notes.app.colors.warningFg}
                Button {objectName:"discardRegionNoteDraft";text:qsTr("Discard note draft");visible:notes.owner && notes.owner.regionNoteDraft.id===notes.selectedId;enabled:notes.owner && !notes.owner.pendingCommands;onClicked:{notes.owner.discardRegionNoteDraft();noteText.text=notes.detail.knowledgeNote || "";}}
                Button {objectName:"deleteRegionKnowledgeNote";text:qsTr("Delete saved region…");enabled:notes.owner && !notes.owner.hasUnsavedReadingNotes && !notes.owner.pendingCommands && !notes.history.writes_blocked && !notes.history.error;onClicked:remove.open()}
            }
        }
    }
    Dialog {
        id:remove;objectName:"deleteRegionNoteConfirmation";title:qsTr("Delete saved region?");modal:true
        parent:Overlay.overlay;x:(notes.app.width-width)/2;y:(notes.app.height-height)/2
        standardButtons:Dialog.Cancel|Dialog.Ok
        Label {text:qsTr("This removes the local capture, conversation and knowledge note. The PDF is unchanged.");width:Math.min(320,notes.app.width-64);wrapMode:Text.Wrap}
        property var targetOwner:null
        property string targetId:""
        onAboutToShow:{targetOwner=notes.owner;targetId=notes.selectedId;}
        onAccepted:if(targetOwner && targetOwner===notes.owner && targetOwner===notes.app.currentReader && targetId===notes.selectedId && !targetOwner.pendingCommands)targetOwner.submit("region_delete",{id:targetId})
        onClosed:{targetOwner=null;targetId="";}
    }
}

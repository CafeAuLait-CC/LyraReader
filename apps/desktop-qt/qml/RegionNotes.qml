import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import LyraReader 1.0

Pane {
    id:notes
    objectName:"regionNotes"
    required property var app
    property var owner:null
    property var detail:null
    property var readId:0
    property var reopenId:0
    property var continueContext:null
    property string selectedId:""
    property int turnIndex:0
    readonly property var history:owner ? owner.regionHistory : ({})
    readonly property var turns:detail ? detail.turns || [] : []
    readonly property var turn:turns.length ? turns[Math.min(turnIndex,turns.length-1)] : detail && detail.question ? detail : null
    readonly property var verifiedPages:detail && !detail.locationInvalidated ? (detail.verified_source_pages || [])[turnIndex] || [] : []
    function stateLabel(state){return state==="finished" ? qsTr("Completed") : state==="cancelled" ? qsTr("Stopped") : state==="failed" ? qsTr("Failed") : qsTr("No answer yet");}
    readonly property bool active:app.aiPanelVisible && app.aiPanelMode==="notes" && app.currentReader.pageCount>0
    property string readError:""
    property int ownerGeneration:-1
    property var exportContext:null
    property var exportReader:null
    property var exportId:0
    readonly property bool canExport:owner && !owner.pendingCommands && !owner.hasUnsavedReadingNotes && !exportId && !history.error && (history.entries || []).some(e=>e.has_answer)
    visible:active;enabled:active;focus:active;padding:10
    background:Rectangle {color:notes.app.colors.sidebarBg}
    signal closed()
    function open(){app.openRegionNotes();}
    function close(){if(app.aiPanelVisible && app.aiPanelMode==="notes")app.showAiPanel(false);}
    function activate() {
        owner=app.currentReader;ownerGeneration=owner.documentGeneration;
        detail=null;selectedId="";readError="";owner.submit("region_list",{});
        if(owner.regionNoteDraft.id)load(owner.regionNoteDraft.id);
        else list.forceActiveFocus();
    }
    function deactivate() {
        let focused=app.activeFocusItem;let ownedFocus=false;
        while(focused){if(focused===notes){ownedFocus=true;break;}focused=focused.parent;}
        continueReveal.stop();continueContext=null;exportFile.close();exportContext=null;remove.close();detail=null;readId=0;reopenId=0;owner=null;
        if(ownedFocus)app.focusReadingView();closed();
    }
    onActiveChanged:if(active)activate();else deactivate()
    Connections {
        target:notes.app
        function onCurrentReaderChanged(){notes.close();if(notes.exportReader!==notes.app.currentReader)notes.clearExportPresentation();}
    }
    Keys.onShortcutOverride:function(event){if(event.key===Qt.Key_Escape)event.accepted=true;}
    Keys.onEscapePressed:function(event){close();event.accepted=true;}
    function load(id){if(owner.regionNoteDraft.id && owner.regionNoteDraft.id!==id){app.operationStatus=qsTr("Save or discard the current reading note before selecting another area.");return;}selectedId=id;detail=null;readError="";readId=owner.submit("region_get",{id:id});}
    function continueConversation() {
        if(!owner || !detail || !detail.can_reopen || owner.pendingCommands || owner.hasUnsavedReadingNotes || history.writes_blocked)return;
        continueReveal.stop();readError="";continueContext={reader:owner,generation:owner.documentGeneration,id:selectedId};reopenId=owner.reopenAiRegion(selectedId,history.revision);
        if(!reopenId)readError=qsTr("Save the current region or reading-note draft before continuing another conversation.");
    }
    // The command signal also updates the controller. Reveal only after all its consumers settle.
    Timer {id:continueReveal;interval:0;onTriggered:notes.finishContinue()}
    function finishContinue() {
        if(reopenId)return;
        const context=continueContext;continueContext=null;
        if(!context)return;
        if(context.reader===owner && owner===app.currentReader && context.generation===owner.documentGeneration && context.id===selectedId && owner.aiRegion.history_id===context.id){close();app.openRegionTool();}
        else if(owner)readError=qsTr("The document or region changed. Choose the saved conversation again.");
    }
    function followSource(page) {
        if(!owner || owner!==app.currentReader || ownerGeneration!==owner.documentGeneration || !Number.isInteger(page) || page<1 || page>owner.pageCount || verifiedPages.indexOf(page)<0) {
            app.operationStatus=qsTr("This earlier source is unavailable for the current document revision.");return;
        }
        app.navigate(page-1,0);app.focusReadingView();
    }
    function clearExportPresentation(){exportReader=null;exportId=0;}
    function beginExport() {
        if(!canExport)return;
        exportContext={reader:owner,generation:owner.documentGeneration,revision:history.revision};
        exportFile.open();
    }
    function exportTo(url) {
        const context=exportContext;exportContext=null;
        if(!context || !context.reader || context.reader!==owner || owner!==app.currentReader || context.generation!==owner.documentGeneration || owner.hasUnsavedReadingNotes) {
            app.operationStatus=qsTr("The document or reading-note draft changed. Choose the export again.");return;
        }
        exportReader=context.reader;app.operationStatus=qsTr("Exporting saved reading notes…");
        exportId=exportReader.submit("region_export_markdown",{destination:app.session.localPath(url),expected_history_revision:context.revision});
    }
    Connections {
        target:notes.exportReader
        function onDocumentReset(){notes.clearExportPresentation();}
        function onCommandFinished(id,op,result,error) {
            if(id!==notes.exportId)return;
            notes.clearExportPresentation();
            notes.app.operationStatus=error || result.warning || qsTr("Exported %1 original region pictures with Markdown. Omitted %2 unanswered conversations; %3 unsupported records were kept in the cache.").arg(result.image_count).arg(result.omitted_count).arg(result.unavailable_count);
        }
    }
    Connections {
        target:notes.owner
        function onDocumentReset(){notes.close();}
        function onCommandFinished(id,op,result,error){
            if(id===notes.reopenId) {
                notes.reopenId=0;
                if(error){notes.continueContext=null;notes.readError=error;return;}
                continueReveal.restart();
                return;
            }
            if(id===notes.readId){notes.readId=0;notes.readError=error;if(!error){notes.detail=result;notes.turnIndex=0;noteText.text=notes.owner.regionNoteDraft.id===result.id ? notes.owner.regionNoteDraft.text : result.knowledgeNote || "";}}
            if(op==="region_note" && !error && notes.detail && result.saved_id===notes.selectedId){var updated=notes.detail;updated.knowledgeNote=result.saved_note;notes.detail=updated;}
            if(op==="region_delete" && !error && result.saved_id===notes.selectedId){notes.detail=null;notes.selectedId="";}
        }
    }
    contentItem:ColumnLayout {
        spacing:8
        RowLayout {
            Layout.fillWidth:true
            Button {objectName:"regionNotesBack";text:qsTr("All notes");visible:!!notes.detail;enabled:notes.owner && !notes.owner.hasUnsavedReadingNotes && !notes.owner.pendingCommands;onClicked:{notes.detail=null;notes.selectedId="";list.forceActiveFocus();}}
            Label {text:qsTr("Saved locally");color:notes.app.colors.textSecondary;Layout.fillWidth:true}
            LyraToolButton {objectName:"exportRegionNotes";symbol:"export";text:qsTr("Export Reading notes as Markdown and pictures (new file)");enabled:notes.canExport;onClicked:notes.beginExport()}
            LyraToolButton {objectName:"regionNotesNewArea";symbol:"plus";text:qsTr("Select a new region");enabled:notes.owner && !notes.owner.hasUnsavedReadingNotes && !notes.owner.pendingCommands && !notes.owner.aiState.running;onClicked:{notes.close();notes.app.armRegion(false);}}
        }
        Label {text:qsTr("Local captures and conversations. Opening notes sends no request.");wrapMode:Text.Wrap;Layout.fillWidth:true;color:notes.app.colors.textSecondary}
        Label {text:notes.readError || notes.history.error || (notes.history.warnings || []).join("\n");visible:text.length>0;textFormat:Text.PlainText;wrapMode:Text.Wrap;Layout.fillWidth:true;color:notes.app.colors.warningFg}
        Label {objectName:"regionNotesEmpty";visible:!list.count && !notes.history.error && !notes.history.foreign_count && !notes.history.writes_blocked;text:qsTr("No saved areas. Use Select & Ask, then Save to Reading notes.");wrapMode:Text.Wrap;Layout.fillWidth:true}
        ListView {
            id:list;objectName:"regionNotesList"
            visible:!notes.detail && !notes.readId;activeFocusOnTab:true
            Layout.fillWidth:true;Layout.fillHeight:true
            model:notes.history.entries || [];clip:true;spacing:6
            onCountChanged:if(count && currentIndex<0)currentIndex=0
            Keys.onReturnPressed:if(currentItem)notes.load(currentItem.modelData.id)
            Keys.onEnterPressed:if(currentItem)notes.load(currentItem.modelData.id)
            ScrollBar.vertical:ScrollBar{}
            delegate:ItemDelegate {
                id:row
                required property var modelData
                required property int index
                width:list.width
                objectName:"regionNoteRow"+modelData.number
                text:qsTr("Region %1 · page %2").arg(modelData.number).arg(modelData.page+1)
                implicitHeight:Math.max(86,contentItem.implicitHeight+20)
                property var thumbnail:null
                property string thumbnailError:""
                property var thumbnailId:0
                property var thumbnailOwner:null
                property string thumbnailRevision:""
                property int thumbnailGeneration:-1
                readonly property bool inViewport:list.visible && notes.active && y+height>list.contentY && y<list.contentY+list.height
                function refreshThumbnail() {
                    if(!inViewport || !notes.owner || !notes.history.revision || notes.history.error || thumbnailId)return;
                    if(thumbnail && thumbnailRevision===notes.history.revision)return;
                    thumbnail=null;thumbnailError="";thumbnailOwner=notes.owner;thumbnailGeneration=thumbnailOwner.documentGeneration;thumbnailRevision=notes.history.revision;
                    thumbnailId=thumbnailOwner.submit("region_thumbnail",{id:modelData.id,expected_history_revision:thumbnailRevision});
                }
                Timer {id:thumbnailRefresh;interval:0;onTriggered:row.refreshThumbnail()}
                onInViewportChanged:if(inViewport)thumbnailRefresh.restart()
                onModelDataChanged:thumbnailRefresh.restart()
                Component.onCompleted:thumbnailRefresh.restart()
                Connections {target:notes;function onHistoryChanged(){thumbnailRefresh.restart();}}
                Connections {
                    target:row.thumbnailOwner
                    function onCommandFinished(id,op,result,error) {
                        if(id!==row.thumbnailId || op!=="region_thumbnail")return;
                        row.thumbnailId=0;
                        if(row.thumbnailOwner!==notes.owner || row.thumbnailGeneration!==notes.ownerGeneration || row.thumbnailRevision!==notes.history.revision || (!error && result.id!==row.modelData.id)) {thumbnailRefresh.restart();return;}
                        row.thumbnailError=error;if(!error)row.thumbnail=result;
                    }
                }
                contentItem:RowLayout {
                    spacing:10
                    Rectangle {
                        Layout.preferredWidth:52;Layout.preferredHeight:42;Layout.alignment:Qt.AlignTop
                        radius:4;color:notes.app.colors.canvasBg
                        PdfCrop {
                            objectName:"regionNoteThumbnail"+row.modelData.number
                            anchors.centerIn:parent
                            width:row.thumbnail ? Math.min(52,42*row.thumbnail.width/row.thumbnail.height) : 52
                            height:row.thumbnail ? width*row.thumbnail.height/row.thumbnail.width : 42
                            source:row.thumbnail ? row.thumbnail.image_url : ""
                            resourceActive:row.inViewport
                            Accessible.role:Accessible.Graphic;Accessible.name:qsTr("Saved capture for region %1").arg(row.modelData.number)
                            Accessible.description:row.thumbnailError
                        }
                        Label {anchors.fill:parent;text:row.thumbnailError ? qsTr("No preview") : "…";visible:!row.thumbnail;wrapMode:Text.Wrap;horizontalAlignment:Text.AlignHCenter;verticalAlignment:Text.AlignVCenter;color:notes.app.colors.textSecondary;font.pixelSize:10}
                        ToolTip.visible:row.hovered && !!row.thumbnailError;ToolTip.text:row.thumbnailError
                    }
                    ColumnLayout {
                        spacing:4;Layout.fillWidth:true
                        Label {text:row.text;textFormat:Text.PlainText;font.bold:true;Layout.fillWidth:true;color:row.highlighted ? notes.app.colors.selectedFg : notes.app.colors.accent}
                        Label {text:row.modelData.question || row.modelData.draft || qsTr("New region");textFormat:Text.PlainText;wrapMode:Text.Wrap;maximumLineCount:2;elide:Text.ElideRight;Layout.fillWidth:true;color:notes.app.colors.textPrimary}
                        Label {text:qsTr("%1 turns · %2").arg(row.modelData.turns).arg(row.modelData.has_note ? qsTr("Reading note") : notes.stateLabel(row.modelData.state));textFormat:Text.PlainText;Layout.fillWidth:true;color:notes.app.colors.textSecondary;font.pixelSize:11}
                    }
                }
                background:Rectangle {radius:6;color:parent.highlighted ? notes.app.colors.selectedBg : parent.down ? notes.app.colors.pressedBg : parent.hovered ? notes.app.colors.hoverBg : notes.app.colors.raisedBg;border.width:list.activeFocus && list.currentIndex===row.index ? 2 : 1;border.color:list.activeFocus && list.currentIndex===row.index ? notes.app.colors.focusRing : notes.app.colors.separator}
                highlighted:notes.selectedId===modelData.id
                onClicked:notes.load(modelData.id)
            }
        }
        BusyIndicator {visible:!!notes.readId;running:visible;Layout.alignment:Qt.AlignHCenter}
        ScrollView {
            visible:!!notes.detail;Layout.fillWidth:true;Layout.fillHeight:true;contentWidth:availableWidth;clip:true
            ColumnLayout {
                width:parent.width;spacing:8
                Button {
                    objectName:"regionNoteSourcePage";visible:!!notes.detail
                    text:notes.detail ? qsTr("Page %1").arg(notes.detail.attachment.page+1) : ""
                    enabled:notes.detail && !notes.detail.locationInvalidated && notes.owner===notes.app.currentReader && notes.ownerGeneration===notes.owner.documentGeneration && notes.detail.attachment.page>=0 && notes.detail.attachment.page<notes.owner.pageCount
                    onClicked:{notes.app.navigate(notes.detail.attachment.page,0);notes.app.focusReadingView();}
                }
                Label {text:notes.detail && notes.detail.locationInvalidated ? qsTr("The document revision changed. This saved capture remains readable; its old location is unavailable.") : qsTr("Saved capture in original colours. PDF edits do not change this snapshot.");wrapMode:Text.Wrap;Layout.fillWidth:true;color:notes.app.colors.textSecondary}
                Label {text:notes.detail ? notes.detail.reopen_error || "" : "";visible:text.length>0;wrapMode:Text.Wrap;Layout.fillWidth:true;color:notes.app.colors.textSecondary}
                Item {
                    Layout.fillWidth:true;Layout.preferredHeight:160
                    PdfCrop {
                        objectName:"regionNoteImage"
                        anchors.centerIn:parent
                        readonly property var attachment:notes.detail ? notes.detail.attachment : ({})
                        width:Math.min(parent.width,160*(attachment.pixelWidth || 1)/(attachment.pixelHeight || 1));height:width*(attachment.pixelHeight || 1)/(attachment.pixelWidth || 1)
                        source:notes.detail ? notes.detail.image_url || "" : ""
                        Accessible.role:Accessible.Graphic;Accessible.name:qsTr("Saved region capture")
                    }
                }
                TextArea {objectName:"regionNoteCapturedText";Layout.fillWidth:true;readOnly:true;selectByMouse:true;wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText;text:notes.detail ? notes.detail.attachment.text.slice(0,120000) : "";Accessible.name:qsTr("Captured text")}
                Label {text:notes.detail ? qsTr("Saved question draft: %1").arg((notes.detail.draftQuestion || "").slice(0,120000)) : "";wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                ComboBox {visible:notes.turns.length>1;Layout.fillWidth:true;model:notes.turns.map((t,i)=>qsTr("Turn %1 · %2").arg(i+1).arg(notes.stateLabel(t.state)));onActivated:notes.turnIndex=currentIndex;Accessible.name:qsTr("Conversation turn")}
                Label {text:notes.turn ? qsTr("%1 · %2").arg(notes.stateLabel(notes.turn.state)).arg(notes.turn.question.slice(0,120000)) : "";wrapMode:Text.Wrap;Layout.fillWidth:true;textFormat:Text.PlainText}
                TextArea {objectName:"regionNoteAnswer";visible:!!notes.turn;Layout.fillWidth:true;readOnly:true;selectByMouse:true;wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText;text:notes.turn ? notes.turn.answer.slice(0,120000) : "";Accessible.name:qsTr("Saved answer")}
                Label {visible:!!notes.turn && notes.turn.answer.length>120000;text:qsTr("Long answer preview limited to 120,000 characters. Copy answer keeps the complete text.");wrapMode:Text.Wrap;Layout.fillWidth:true;color:notes.app.colors.textSecondary}
                Label {visible:!!notes.turn;text:notes.verifiedPages.length ? qsTr("Pages sent with this turn. Answer page markers remain plain text.") : qsTr("No verified source pages for this turn. Answer page markers remain plain text.");wrapMode:Text.Wrap;Layout.fillWidth:true;color:notes.app.colors.textSecondary}
                ListView {
                    id:sourcePages
                    objectName:"regionNoteSources";visible:notes.verifiedPages.length>0
                    Layout.fillWidth:true;Layout.preferredHeight:currentItem ? currentItem.implicitHeight+8 : 40
                    model:notes.verifiedPages;orientation:ListView.Horizontal;clip:true;spacing:4
                    activeFocusOnTab:true;keyNavigationEnabled:true
                    Accessible.role:Accessible.List;Accessible.name:qsTr("Pages sent with this conversation turn")
                    Keys.onReturnPressed:if(currentItem)currentItem.clicked()
                    Keys.onEnterPressed:if(currentItem)currentItem.clicked()
                    ScrollBar.horizontal:ScrollBar{}
                    delegate:Button {required property int modelData;objectName:"regionNoteSource"+modelData;text:qsTr("Page %1").arg(modelData);enabled:notes.owner===notes.app.currentReader && notes.ownerGeneration===notes.owner.documentGeneration;onClicked:notes.followSource(modelData)}
                }
                Button {text:qsTr("Copy answer");visible:!!notes.turn;enabled:!!notes.turn && !!notes.app.session;onClicked:notes.app.session.copyText(notes.turn.answer)}
                Label {text:qsTr("Knowledge note");font.bold:true}
                TextArea {
                    id:noteText;objectName:"regionKnowledgeNote"
                    readOnly:!!notes.history.writes_blocked;selectByMouse:true
                    Layout.fillWidth:true;wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText
                    placeholderText:qsTr("Keep your own reading note…");Accessible.name:qsTr("Knowledge note")
                    Keys.priority:Keys.BeforeItem
                    Keys.onPressed:function(event) {
                        if((event.key!==Qt.Key_Tab && event.key!==Qt.Key_Backtab) || (event.modifiers & (Qt.ControlModifier|Qt.AltModifier|Qt.MetaModifier)))return;
                        const forward=event.key!==Qt.Key_Backtab && !(event.modifiers & Qt.ShiftModifier);
                        const next=nextItemInFocusChain(forward);
                        if(next && next!==noteText)next.forceActiveFocus(forward ? Qt.TabFocusReason : Qt.BacktabFocusReason);
                        event.accepted=true;
                    }
                    onTextChanged:if(notes.detail && notes.owner){if(text!==(notes.detail.knowledgeNote || "") || notes.owner.isSavingRegionNote())notes.owner.setRegionNoteDraft(notes.selectedId,text);else if(notes.owner.regionNoteDraft.id===notes.selectedId)notes.owner.discardRegionNoteDraft();}
                }
                Button {objectName:"saveRegionKnowledgeNote";text:qsTr("Save knowledge note");enabled:notes.owner && !!notes.owner.regionNoteDraft.id && !notes.owner.pendingCommands && !notes.history.writes_blocked;onClicked:notes.owner.saveRegionNoteDraft()}
                Label {visible:notes.owner && notes.owner.regionNoteDraft.id===notes.selectedId;text:qsTr("Unsaved reading note. Save or discard it before closing this document.");Layout.fillWidth:true;wrapMode:Text.Wrap;color:notes.app.colors.warningFg}
                Button {objectName:"discardRegionNoteDraft";text:qsTr("Discard note draft");visible:notes.owner && notes.owner.regionNoteDraft.id===notes.selectedId;enabled:notes.owner && !notes.owner.pendingCommands;onClicked:{notes.owner.discardRegionNoteDraft();noteText.text=notes.detail.knowledgeNote || "";}}
                Button {objectName:"deleteRegionKnowledgeNote";text:qsTr("Delete saved region…");enabled:notes.owner && !notes.owner.hasUnsavedReadingNotes && !notes.owner.pendingCommands && !notes.history.writes_blocked && !notes.history.error;onClicked:remove.open()}
            }
        }
        Button {objectName:"continueRegionConversation";visible:!!notes.detail;Layout.fillWidth:true;text:qsTr("Continue conversation");enabled:notes.detail && !!notes.detail.can_reopen && notes.owner && !notes.owner.pendingCommands && !notes.owner.hasUnsavedReadingNotes && !notes.history.writes_blocked;onClicked:notes.continueConversation()}
    }
    FileDialog {
        id:exportFile;objectName:"readingNotesExportDialog"
        title:qsTr("Export Reading Notes to a New File")
        fileMode:FileDialog.SaveFile;nameFilters:[qsTr("Markdown (*.md)")];defaultSuffix:"md"
        onAccepted:notes.exportTo(selectedFile)
        onRejected:notes.exportContext=null
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

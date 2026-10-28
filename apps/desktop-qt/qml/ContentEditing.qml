import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs

Item {
    id: editing
    objectName:"contentEditing"
    required property var app
    property string tool: "select"
    property var selected: null
    property bool inlineEditing: false
    property var gesture: null
    property var transition: null
    property var pending: null
    property var rasterRequest: null
    property var imageRequest: null
    property var imageExportRequest:null
    readonly property var owner: app.currentReader
    readonly property var model: owner.data.content_objects || ({revision:"",page:-1,items:[]})
    readonly property var draft: owner.editDrafts.content || ({})
    readonly property string draftKind: Object.keys(draft.command || {})[0] || ""
    readonly property var payload: draftKind.length ? draft.command[draftKind] : ({})
    readonly property bool hasDraft: Object.keys(draft).length > 0
    readonly property bool canCommit: hasDraft && payload.revision === model.revision &&
        app.canModifyPdf && owner.pendingCommands === 0 && Object.keys(owner.noteDrafts).length===0 && !pending
    readonly property bool textDraft: draftKind === "ReplaceText" || draftKind === "InsertText"

    function reload() {
        if (app.secondaryRow === "edit" && owner.pageCount > 0)
            owner.submit("content_objects",{page:app.currentPage});
    }
    function reset() {
        selected=null;inlineEditing=false;gesture=null;tool="select";transition=null;pending=null;
        rasterRequest=null;rasterConfirmation.close();
        reload();
    }
    function arm(value) {
        if (app.blockXfaWrite()) return;
        if (deferAction({kind:"tool",value:value})) return;
        tool=tool===value ? "select" : value;
        selected=null;inlineEditing=false;gesture=null;
    }
    function select(item,page) {
        if (hasDraft) {
            if (!selected || item.id !== selected.id) app.operationStatus=qsTr("Apply or discard the preserved content draft before selecting another object.");
            return;
        }
        selected=item;inlineEditing=false;app.currentPage=page;
    }
    function store(command,page,originalText) {
        owner.setEditDraft("content",{page:page,command:command,originalText:originalText || ""});
    }
    function editText(item,page) {
        if (!item.can_edit_text) {app.operationStatus=item.reason || qsTr("This text cannot be edited.");return;}
        if (hasDraft) {inlineEditing=textDraft;return;}
        selected=item;
        store({ReplaceText:{revision:model.revision,target:item.id,text:item.text,bounds:item.bounds,
            font:"Original",size:item.size,colour:item.colour,alignment:0}},page,item.text);
        inlineEditing=true;
    }
    function insertText(rect,page) {
        if (hasDraft) return;
        selected=null;
        store({InsertText:{revision:model.revision,text:"",bounds:rect,font:"Helvetica",size:12,
            colour:[48,43,37,255],alignment:0}},page,"");
        inlineEditing=true;
    }
    function changeText(value) {
        if (!textDraft || payload.text===value) return;
        const next=Object.assign({},payload,{text:value});
        const command={};command[draftKind]=next;store(command,draft.page,draft.originalText);
    }
    function changeStyle(patch) {
        if (!hasDraft && selected && selected.kind==="text") editText(selected,model.page);
        if (!textDraft) return;
        const command={};command[draftKind]=Object.assign({},payload,patch);
        store(command,draft.page,draft.originalText);
    }
    function discard() {owner.setEditDraft("content",{});inlineEditing=false;gesture=null;transition=null;}
    function submit(command,page,allowRaster) {
        if (pending || app.blockXfaWrite() || owner.pendingCommands>0) return;
        if (!hasDraft) store(command,page,"");
        app.pendingPage=app.currentPage;app.pendingPageSelection=app.selectedPages.slice();
        const ticket={reader:owner,command:command,page:page};
        pending=ticket;
        ticket.id=owner.submit("content_stage",{page:page,command:command,allow_raster:!!allowRaster,
            current_page:app.currentPage,selected_pages:app.selectedPages});
    }
    function commitDraft() {
        if (!canCommit) return;
        submit(draft.command,draft.page,false);
    }
    function applyGeometry(item,bounds) {
        if (hasDraft || !item) return;
        submit({Transform:{revision:model.revision,target:item.id,bounds:bounds,rotation:0}},model.page,false);
    }
    function remove() {
        if (hasDraft || !selected) return;
        submit({Delete:{revision:model.revision,target:selected.id}},model.page,false);
    }
    function crop(rect) {
        if (hasDraft || !selected) return;
        submit({CropImage:{revision:model.revision,target:selected.id,crop:rect}},model.page,false);
    }
    function setLink(bounds,page,uri) {
        if (hasDraft || !bounds) return;
        submit({SetLink:{revision:model.revision,target:selected && selected.kind==="link" ? selected.id : null,
            bounds:bounds,page:page,uri:uri}},model.page,false);
    }
    function chooseImage(bounds,target) {
        if (hasDraft || pending) return;
        imageRequest={reader:owner,revision:model.revision,page:model.page,bounds:bounds,target:target || null};
        imagePicker.open();
    }
    function chooseImageExport() {
        if(hasDraft || pending || owner.pendingCommands>0 || !selected || selected.kind!=="image" || app.blockXfaWrite())return;
        imageExportRequest={reader:owner,revision:model.revision,page:model.page,target:selected.id};
        imageExportPicker.open();
    }
    function exportImageTo(destination) {
        const request=imageExportRequest;imageExportRequest=null;
        if(!request || request.reader!==owner || request.revision!==model.revision || request.page!==model.page || !selected || selected.id!==request.target || hasDraft || owner.pendingCommands>0) {
            app.operationStatus=qsTr("The page changed. Choose the image again before exporting.");return;
        }
        const path=app.session ? app.session.localPath(destination) : "";if(!path.length)return;
        owner.submit("save_content_image",{page:request.page,target:request.target,revision:request.revision,destination:path});
    }
    function redact(rect,page) {
        if (hasDraft || pending || owner.pendingCommands>0) return;
        const command={Redact:{revision:model.revision,bounds:rect,blackout:tool==="blackout"}};
        rasterRequest={reader:owner,command:command,page:page};
        rasterRequest.id=owner.submit("content_redaction_preflight",{page:page,command:command});
    }
    function deferAction(action) {
        if (pending) {transition=action;return true;}
        if (!hasDraft) return false;
        if (draft.error || !canCommit) {
            app.operationStatus=qsTr("Apply or discard the preserved content draft before leaving Edit.");
            return true;
        }
        transition=action;commitDraft();return true;
    }
    function performTransition() {
        const next=transition;transition=null;
        if (!next) return;
        if (next.kind==="row") app.setSecondaryRow(next.value,true);
        else if (next.kind==="tool") arm(next.value);
        else if (next.kind==="tab") app.selectReaderTab(app.readerIndex(next.reader),true);
        else if (next.kind==="reorder") app.reorderReaderTab(next.reader,next.before,true);
        else if (next.kind==="tabClose") app.requestCloseTab(app.readerIndex(next.reader));
        else if (next.kind==="windowClose") app.close();
        else if (next.kind==="overview") app.showOverview(true);
        else if (next.kind==="assistant") app.showAiPanel(next.value);
        else if (next.kind==="search") app.focusSearch();
        else if (next.kind==="textView") app.setTextViewEnabled(next.value);
        else if (next.kind==="save") app.saveDocument(next.value);
        else if (next.kind==="export") app.chooseExport(next.value);
        else if (next.kind==="print") app.printDocument();
        else if (next.kind==="undo") app.undo();
        else if (next.kind==="redo") app.redo();
    }
    Connections {
        target: editing.owner
        function onCommandFinished(id,operation,result,error) {
            if (operation==="content_objects" && !error.length && editing.selected) {
                const items=result.items || [];
                editing.selected=items.find(function(item){return item.id===editing.selected.id;}) || null;
            }
            const raster=editing.rasterRequest;
            if (raster && id===raster.id && operation==="content_redaction_preflight") {
                if (raster.reader!==editing.owner) return;
                if (error.length) {editing.rasterRequest=null;return;}
                if (result.length) {raster.pages=result;rasterConfirmation.open();}
                else {editing.rasterRequest=null;editing.submit(raster.command,raster.page,false);}
            }
            const ticket=editing.pending;
            if (!ticket || ticket.id!==id || operation!=="content_stage" || ticket.reader!==editing.owner) return;
            editing.pending=null;editing.gesture=null;
            if (error.length) {
                editing.transition=null;
                editing.app.operationStatus=qsTr("Content edit failed. Your draft is preserved: %1").arg(error);
                return;
            }
            editing.inlineEditing=false;editing.selected=null;
            const report=result.report || {};
            const pages=report.rasterized_pages || [];
            editing.app.operationStatus=pages.length ? qsTr("Pages %1 are now images; their text is no longer selectable or searchable. Changes are unsaved.").arg(pages.map(function(p){return p+1;}).join(", ")) : qsTr("PDF content updated. Changes are unsaved.");
            editing.reload();
            Qt.callLater(function(){
                if(!editing.hasDraft) editing.performTransition();
                else {editing.transition=null;editing.app.operationStatus=qsTr("New content changes remain in the preserved draft.");}
            });
        }
    }
    Dialog {
        id: rasterConfirmation
        objectName: "contentRasterConfirmation"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(500,editing.app.width-48)
        modal: true
        title: qsTr("Replace Pages with Images?")
        standardButtons: Dialog.Ok | Dialog.Cancel
        Label {
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: qsTr("This redaction requires rasterizing pages %1. Their entire text layer will be lost and will no longer be selectable or searchable. Continue?").arg(editing.rasterRequest ? (editing.rasterRequest.pages || []).map(function(p){return p+1;}).join(", ") : "")
        }
        onAccepted: {
            const request=editing.rasterRequest;editing.rasterRequest=null;
            if (request && request.reader===editing.owner) editing.submit(request.command,request.page,true);
        }
        onRejected: editing.rasterRequest=null
    }
    FileDialog {
        id:imageExportPicker
        objectName:"contentImageExportDialog"
        title:qsTr("Export Image")
        fileMode:FileDialog.SaveFile
        defaultSuffix:"png"
        nameFilters:[qsTr("PNG images (*.png)")]
        onAccepted:editing.exportImageTo(selectedFile)
        onRejected:editing.imageExportRequest=null
    }
    FileDialog {
        id: imagePicker
        objectName: "contentImagePicker"
        title: qsTr("Choose a PNG Image")
        nameFilters: [qsTr("PNG images (*.png)")]
        fileMode: FileDialog.OpenFile
        onAccepted: {
            const request=editing.imageRequest;editing.imageRequest=null;
            if (!request || request.reader!==editing.owner || request.revision!==editing.model.revision) {
                editing.app.operationStatus=qsTr("The document changed. Choose the image again.");return;
            }
            const path=editing.app.session ? editing.app.session.localPath(selectedFile) : "";
            if (!path.length) return;
            const command=request.target ? {ReplaceImage:{revision:request.revision,target:request.target,image_path:path}} :
                {InsertImage:{revision:request.revision,bounds:request.bounds,image_path:path}};
            editing.submit(command,request.page,false);
        }
        onRejected: editing.imageRequest=null
    }
}

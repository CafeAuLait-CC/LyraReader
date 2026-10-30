import QtQuick

Item {
    id: editing
    objectName: "placedTextEditing"
    required property var app
    property var owner: null
    property var generation: null
    property var entry: null
    property string text: ""
    property var rect: null
    property string savedText: ""
    property var savedRect: null
    property string token: ""
    property double request: -1
    property var sent: null
    property bool created: false
    property bool closing: false
    property bool cancelling: false
    property var nextAction: null
    property string error: ""
    property int focusSerial: 0
    property var missingGlyphs: []
    property double coverageRequest: -1
    property string coverageText: ""
    property double creationRequest: -1
    property bool editorRequested: false
    property bool pendingWasCreated: true
    property bool selectAllOnStart: true
    signal layoutRequested()
    readonly property bool active: !!owner && !!entry
    readonly property bool waitingForCreation: !!owner && creationRequest>=0
    readonly property bool current: active && owner===app.currentReader && generation===owner.documentGeneration
    readonly property bool dirty: active && (text!==savedText || JSON.stringify(rect)!==JSON.stringify(savedRect))
    function expectCreation(source,id,selectAll,wasCreated) {
        owner=source;generation=source.documentGeneration;creationRequest=id;
        pendingWasCreated=wasCreated!==false;selectAllOnStart=selectAll!==false;
        editorRequested=true;cancelling=false;closing=false;
    }
    function suppressPendingEditor() {editorRequested=false;}
    function cancelPendingCreation() {editorRequested=false;cancelling=true;closing=true;}
    function openExisting(annotation) {
        owner=app.currentReader;generation=owner.documentGeneration;
        closing=false;cancelling=false;selectAllOnStart=false;
        start(annotation,false);
    }
    function start(annotation,wasCreated) {
        if(owner===app.currentReader)app.selection=null;
        entry=annotation;created=!!wasCreated;
        text=annotation.note || "";rect=Object.assign({},annotation.rect);
        savedText=text;savedRect=Object.assign({},rect);
        error="";nextAction=null;missingGlyphs=[];
        token="";
        request=owner.submit("mark_text_begin",{id:entry.id,created:created});
    }
    function change(value) {
        if (!current || !token.length || closing || cancelling || value===text) return;
        text=value;owner.setNoteDraft(entry.id,text);
        saveTimer.restart();coverageTimer.restart();
    }
    function resizeBox(width,height) {
        if (!current || !token.length || closing || cancelling || !Number.isFinite(width) || !Number.isFinite(height)) return;
        if(text===(entry.note || "")){width=entry.rect.width;height=entry.rect.height;}
        if (Math.abs(rect.width-width)<.05 && Math.abs(rect.height-height)<.05) return;
        rect={x:rect.x,y:rect.y,width:width,height:height};
        owner.setNoteDraft(entry.id,text);saveTimer.restart();
    }
    function flush() {
        saveTimer.stop();
        if (!active || request>=0 || !token.length || !dirty || cancelling) return;
        sent={text:text,rect:Object.assign({},rect)};
        request=owner.submit("mark_text_update",{id:entry.id,edit_token:token,patch:{note:sent.text,rect:sent.rect}});
    }
    function finish(cancel) {
        if (!active) return;
        if(closing && cancelling && !cancel)return;
        if(current && !closing)Qt.inputMethod.commit();
        if(!cancel)layoutRequested();
        saveTimer.stop();closing=true;cancelling=!!cancel;
        if(cancel)nextAction=null;
        if(request>=0)return;
        if (!token.length) {
            request=owner.submit("mark_text_begin",{id:entry.id,created:created});
            return;
        }
        if (!cancelling && dirty) {flush();return;}
        request=owner.submit("mark_text_end",{id:entry.id,edit_token:token,cancel:cancelling});
    }
    function deferAction(action) {
        if (!current) return false;
        nextAction=action;finish(false);return true;
    }
    function abandon() {
        saveTimer.stop();coverageTimer.stop();
        entry=null;owner=null;generation=null;token="";request=-1;sent=null;
        creationRequest=-1;editorRequested=false;
        closing=false;cancelling=false;nextAction=null;error="";missingGlyphs=[];
    }
    Timer {id:saveTimer;interval:500;onTriggered:editing.flush()}
    Timer {
        id:coverageTimer;interval:350
        onTriggered: if (editing.active) {
            editing.coverageText=editing.text;
            editing.coverageRequest=editing.owner.submit("font_coverage",{text:editing.coverageText});
        }
    }
    Connections {
        target: editing.owner
        function onDocumentReset() {editing.abandon();}
        function onCommandFinished(id,op,result,message) {
            if (!editing.owner || editing.generation!==editing.owner.documentGeneration) return;
            if(id===editing.creationRequest) {
                editing.creationRequest=-1;
                if(message.length || (!editing.cancelling && (!editing.editorRequested || editing.owner!==editing.app.currentReader))) {editing.abandon();return;}
                const annotation=(result.annotations || []).find(function(a){return a.id===result.selected_id;});
                if(!annotation || annotation.kind!=="textBox") {editing.abandon();return;}
                editing.start(annotation,editing.pendingWasCreated);
                if(!editing.cancelling)editing.app.operationStatus=qsTr("Edit the text on the page. Control+Return finishes, Escape cancels.");
                return;
            }
            if(!editing.active)return;
            if(id===editing.coverageRequest) {
                if(!message.length && editing.coverageText===editing.text)editing.missingGlyphs=result.missing || [];
                return;
            }
            if(id!==editing.request) {
                const mutation=op.indexOf("mark_")===0 || op.indexOf("marks_")===0 || op.indexOf("bookmark_")===0 || op.indexOf("file_")===0 || op==="ink_erase_commit";
                if(editing.token.length && mutation && !message.length) {
                    const exists=(result.annotations || []).some(function(a){return a.id===editing.entry.id;});
                    // Explicit undo/delete wins. Otherwise preserve unflushed text for
                    // the existing Review flow rather than replay an expired session.
                    if(!exists)editing.owner.clearNoteDraft(editing.entry.id);
                    else if(editing.dirty)editing.app.operationStatus=qsTr("The annotation changed. Review the preserved text draft before saving.");
                    editing.abandon();
                }
                return;
            }
            editing.request=-1;
            if(message.length) {
                editing.error=message;editing.app.operationStatus=message;
                editing.closing=false;editing.cancelling=false;editing.nextAction=null;
                return;
            }
            if(editing.error.length && editing.owner.error===editing.error)editing.owner.dismissError();
            editing.error="";
            if(op==="mark_text_begin") {
                if(!result.text_edit_token) {editing.error=qsTr("The text editor did not receive a valid session. Reopen the document.");return;}
                const canonical=(result.annotations || []).find(function(a){return a.id===editing.entry.id;});
                if(canonical) {
                    // A preceding note flush can finish between the click and this reply.
                    // Begin from the acknowledged mark, preserving an explicit unsaved draft.
                    editing.entry=canonical;editing.savedText=canonical.note || "";
                    editing.text=editing.owner.noteDrafts[canonical.id]!==undefined ? editing.owner.noteDrafts[canonical.id] : editing.savedText;
                    editing.rect=Object.assign({},canonical.rect);editing.savedRect=Object.assign({},canonical.rect);
                }
                editing.token=result.text_edit_token;
                if(!editing.cancelling){++editing.focusSerial;coverageTimer.restart();}
            } else if(op==="mark_text_update") {
                editing.savedText=editing.sent.text;editing.savedRect=editing.sent.rect;editing.sent=null;
            } else if(op==="mark_text_end") {
                const action=editing.nextAction,owner=editing.owner,generation=editing.generation,id=editing.entry.id;
                editing.app.operationStatus=editing.cancelling ? qsTr("Text placement cancelled.") : qsTr("Text edit cached. Save writes it into the PDF.");
                owner.clearNoteDraft(id);
                if(editing.current && editing.app.selectedAnnotation && editing.app.selectedAnnotation.id===id)editing.app.selectedAnnotation=null;
                // Transfer focus before hiding the editor so its text shortcuts
                // cannot suppress the reader's undo action after cancellation.
                if(editing.current)editing.app.pageList.forceActiveFocus();
                editing.abandon();
                if(action)Qt.callLater(function(){if(owner===editing.app.currentReader && owner.documentGeneration===generation)action();});
                return;
            }
            if(editing.closing)editing.finish(editing.cancelling);
            else if(editing.dirty)saveTimer.restart();
        }
    }
}

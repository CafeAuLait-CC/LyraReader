import QtQuick

Item {
    id: workflow
    objectName: "aiPrereadingWorkflow"
    visible: false
    required property var app
    property var pending: null
    readonly property var owner: pending ? pending.reader : null

    function current(ticket) {
        return !!ticket && !!ticket.reader && ticket.reader===app.currentReader
            && app.aiTaskUiAvailable()
            && ticket.generation===ticket.reader.documentGeneration
            && ticket.policy===app.prereadingPolicyValue && ticket.revision===app.prereadingPolicyRevision
            && ticket.review===app.aiReviewRevision && ticket.language===app.defaultAiOutputLanguage
            && ticket.connection===(app.session ? app.session.chatGptAccounts.profileRevision : 0)
            && ticket.valid();
    }
    function begin(reader, kind, valid, resume) {
        if(!reader || reader!==app.currentReader || !app.aiTaskUiAvailable() || !valid())return false;
        if(!app.beginAiPreparation())return false;
        const state=reader.documentReading;
        const gate=app.session.prereadingGate(app.prereadingPolicyValue,state.phase || "idle",!!state.ready,kind);
        if(!gate.valid) {app.operationStatus=gate.message;return false;}
        if(gate.decision==="ready") {cancel();return resume()!==false;}
        if(gate.decision==="wait") {
            app.operationStatus=app.aiTaskBusyMessage(reader);return false;
        }
        cancel();
        pending={reader:reader,generation:reader.documentGeneration,valid:valid,resume:resume,
            policy:app.prereadingPolicyValue,revision:app.prereadingPolicyRevision,review:app.aiReviewRevision,
            language:app.defaultAiOutputLanguage,connection:app.session.chatGptAccounts.profileRevision,
            reading:reader.documentReadingRevision,owned:false,skipping:false};
        app.showPrereadingChoice(reader,gate.decision==="read");
        return false;
    }
    function adopt(reader) {
        if(pending && pending.reader===reader && current(pending)) {
            pending.reading=reader.documentReadingRevision;pending.owned=true;
        }
    }
    function mayStart(reader) {
        return !!pending && pending.reader===reader && current(pending)
            && pending.reading===reader.documentReadingRevision && !pending.skipping;
    }
    function cancel(message) {
        const old=pending;pending=null;
        if(!old)return;
        if(old.reader && old.reader.documentGeneration===old.generation && old.owned
                && old.reader.documentReadingRevision===old.reading) {
            app.abandonPrereadingCredential(old.reader,old.reader.documentReading.token || "");
            old.reader.invalidateDocumentReadingPreview();
        }
        app.hidePrereadingChoice(old.reader);
        if(message)app.operationStatus=message;
    }
    function skip(reader) {
        const ticket=pending;
        if(!ticket || ticket.reader!==reader || !current(ticket))return false;
        ticket.skipping=true;
        reader.skipDocumentReading();
        if(pending===ticket)ticket.reading=reader.documentReadingRevision;
        return true;
    }
    function advance() {
        const ticket=pending;
        if(!ticket)return;
        if(!current(ticket) || ticket.reading!==ticket.reader.documentReadingRevision) {
            cancel(qsTr("The AI task changed. Prepare it again before sending."));return;
        }
        const state=ticket.reader.documentReading;
        if(ticket.skipping && state.phase==="skipped" && !ticket.reader.pendingCommands) {
            pending=null;app.hidePrereadingChoice(ticket.reader);
            // Closing/focus callbacks may have changed or destroyed the original UI.
            Qt.callLater(function(){if(current(ticket) && ticket.reader.documentReadingRevision===ticket.reading)ticket.resume();});
        } else if(state.phase==="starting" || state.phase==="reading") {
            pending=null;
            if(!ticket.reader.aiState.running)ticket.reader.invalidateAiPlan();
            app.hidePrereadingChoice(ticket.reader);
            app.operationStatus=qsTr("Document prereading started. Continue when Lyra AI is ready.");
        } else if(state.ready) {
            pending=null;app.hidePrereadingChoice(ticket.reader);
            app.operationStatus=qsTr("Document prereading is ready. You can continue.");
        }
    }
    Connections {
        target: workflow.owner
        function onDocumentReadingChanged(){Qt.callLater(workflow.advance);}
        function onCommandsChanged(){Qt.callLater(workflow.advance);}
        function onDocumentChanged(){Qt.callLater(workflow.advance);}
        function onAiStateChanged(){Qt.callLater(workflow.advance);}
        function onRegionNoteDraftChanged(){Qt.callLater(workflow.advance);}
    }
    Connections {
        target: workflow.app
        function onCurrentReaderChanged(){workflow.cancel();}
        function onVisibleChanged(){if(workflow.pending && !workflow.current(workflow.pending))workflow.cancel();}
        function onCloseApprovedChanged(){if(workflow.pending && !workflow.current(workflow.pending))workflow.cancel();}
        function onCloseOperationChanged(){if(workflow.pending && !workflow.current(workflow.pending))workflow.cancel();}
        function onClosingTabChanged(){if(workflow.pending && !workflow.current(workflow.pending))workflow.cancel();}
        function onPrereadingPolicyRevisionChanged(){workflow.cancel();}
        function onAiReviewRevisionChanged(){workflow.cancel();}
        function onDefaultAiOutputLanguageChanged(){workflow.cancel();}
        function onAiSettingsChanged(){workflow.cancel();}
    }
    Connections {
        target: workflow.app.session ? workflow.app.session.chatGptAccounts : null
        function onProfileChanged(){if(workflow.pending && !workflow.current(workflow.pending))workflow.cancel();}
    }
    Connections {
        target: workflow.app.currentReader
        function onDocumentReadingChanged(){
            const state=workflow.app.currentReader.documentReading;
            if(state.phase==="ready")workflow.app.operationStatus=qsTr("Document prereading is ready. You can continue.");
            else if(state.phase==="failed")workflow.app.operationStatus=state.message || qsTr("Prereading paused. Retry or continue without reading.");
        }
    }
}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id: popup
    objectName: "aiTermPopup"
    required property var app
    required property var task
    property var ticket: null
    property var closingTicket: null
    property var sendIntent: null
    property string workerId: ""
    property var frozenState: null
    readonly property var reader: ticket ? ticket.reader : null
    readonly property var controller: reader ? reader.readingTerm : null
    readonly property var state: frozenState || (controller ? controller.state : ({}))
    readonly property bool current: !!ticket && !!reader && reader === app.currentReader && ticket.generation === reader.documentGeneration
    readonly property bool ownsWorker: current && !!workerId && !!controller && controller.state.request_id === workerId
    readonly property bool busy: ["preparing", "starting", "running"].indexOf(state.phase) >= 0
    readonly property bool reviewing: !!app.aiTaskReviewTicket && app.aiTaskReviewTicket.reader===reader
        && app.aiTaskReviewTicket.purpose==="term"
    readonly property bool anyVisible: visible || reviewing
    parent: Overlay.overlay
    width: Math.max(120, Math.min(340, parent ? parent.width - 16 : 340))
    height: Math.max(160, Math.min(300, parent ? parent.height - 16 : 300))
    padding: 16; focus: true; modal: false
    closePolicy: Popup.CloseOnEscape | (reviewing ? Popup.NoAutoClose : Popup.CloseOnPressOutside)
    background: Rectangle {radius: 8; color: app.colors.panelBg; border.color: app.colors.separator}
    enter: Transition {NumberAnimation {property: "opacity"; from: 0; to: 1; duration: app.reduceMotion ? 0 : 100}}
    exit: Transition {NumberAnimation {property: "opacity"; from: 1; to: 0; duration: app.reduceMotion ? 0 : 80}}
    function openFor(owner, generation, request, anchor, sourceRow) {
        const record=sourceRow ? sourceRow.recordId : "",snapshot=JSON.stringify(request);
        return app.requestAiTaskFromUi(owner,"term",function(){
            return !!owner && owner===app.currentReader && owner.documentGeneration===generation
                && (!anchor || anchor.visible) && (!sourceRow || sourceRow.recordId===record)
                && JSON.stringify(request)===snapshot;
        },function(){return popup.openPrepared(owner,generation,request,anchor,sourceRow);});
    }
    function openPrepared(owner, generation, request, anchor, sourceRow) {
        if (!owner || owner !== app.currentReader || owner.documentGeneration !== generation || !parent) return false;
        app.cancelAiTaskReview(reader,"term");
        if (ownsWorker) controller.dismiss();
        frozenState = null; workerId = "";
        ticket = {reader: owner, generation: generation, request: request, anchor: anchor, sourceRow: sourceRow,
            record: sourceRow ? sourceRow.recordId : ""};
        const active = ticket;
        closingTicket = null; sendIntent = {owner:active,workflowRevision:app.aiReviewRevision};
        const point = anchor ? anchor.mapToItem(parent, 0, anchor.height) : Qt.point(parent.width / 2, parent.height / 2);
        x = Math.max(8, Math.min(parent.width - width - 8, point.x));
        y = Math.max(8, Math.min(parent.height - height - 8, point.y));
        open();
        if (!controller.prepare(request)) { close(); return false; }
        if (ticket !== active) return false;
        ticket.worker = controller.state.request_id; workerId = ticket.worker;
        Qt.callLater(finishUiRequest);
        return true;
    }
    onOpened: if(sendIntent)Qt.callLater(finishUiRequest)
    function finishUiRequest() {
        const intent=sendIntent;
        if(!intent)return;
        if(intent.owner!==ticket || !current || intent.workflowRevision!==app.aiReviewRevision) {
            sendIntent=null;return;
        }
        if(!opened || busy)return;
        sendIntent=null;
        showReview();
    }
    function showReview() {
        if (!ownsWorker || !opened || state.phase !== "preview" || !state.plan) return;
        app.dispatchAiTaskFromUi(reader,state.plan,"term");
    }
    function followCitation(link) {
        if (current) task.panel.followVerifiedPage(link, state.sent_pages || [], ticket.generation);
    }
    onAboutToHide: {
        closingTicket = ticket;
        frozenState = controller ? controller.state : ({});
        sendIntent=null;app.cancelAiTaskReview(reader,"term");
        if (ownsWorker) {
            app.abandonTermCredential(reader, state.plan);
            // Retire admission immediately; keep the displayed answer during the short fade.
            controller.dismiss();
        }
    }
    onClosed: {
        if (closingTicket !== ticket) return;
        const previous = ticket;
        if (controller && previous && previous.worker && controller.state.request_id === previous.worker) controller.cancel();
        ticket = null; sendIntent = null; workerId = ""; frozenState = null;
        if (previous && previous.reader && previous.anchor && previous.reader === app.currentReader
                && previous.generation === previous.reader.documentGeneration && previous.anchor.visible
                && (!previous.sourceRow || previous.sourceRow.recordId === previous.record))
            previous.anchor.forceActiveFocus(Qt.PopupFocusReason);
    }
    Connections {
        target: popup.app
        function onCurrentReaderChanged() { popup.close(); }
        function onAiSettingsChanged() { popup.close(); }
    }
    Component.onDestruction: {
        if (controller && ticket && ticket.worker && controller.state.request_id === ticket.worker) {
            app.abandonTermCredential(reader, controller.state.plan);
            controller.cancel();
        }
    }
    Connections {
        target: popup.reader
        function onDocumentChanged() { if (!popup.current) popup.close(); }
    }
    Connections {
        target: popup.controller
        function onChanged() {
            if (popup.ticket && popup.workerId && !popup.frozenState && popup.controller.state.request_id !== popup.workerId) popup.close();
            if(popup.sendIntent)Qt.callLater(popup.finishUiRequest);
        }
    }
    contentItem: ColumnLayout {
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            Label {
                objectName: "aiTermTitle"
                text: popup.ticket ? popup.ticket.request.question : ""
                font.pixelSize: 14; font.weight: Font.DemiBold
                color: app.colors.textPrimary; textFormat: Text.PlainText; wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            LyraToolButton {
                theme: app.colors; symbol: "close"; text: qsTr("Close term explanation")
                display: AbstractButton.IconOnly
                onClicked: popup.close()
            }
        }
        AiReadingScrollView {
            id: termScroll
            Layout.fillWidth: true; Layout.fillHeight: true
            ColumnLayout {
                width: termScroll.availableWidth; spacing: 10
                BusyIndicator {running: popup.busy; visible: running; implicitWidth: 24; implicitHeight: 24}
                AiResult {
                    objectName: "aiTermResult"
                    app: popup.app; value: ({output: popup.state.output || "", usage: popup.state.usage || {},
                        responsePlan: popup.state.plan || {}, generation: popup.ticket ? popup.ticket.generation : 0})
                    citationPages: popup.state.sent_pages || []
                    showActions: false; showSources: false; inlineConversation: true; bodySize: 13
                    Layout.fillWidth: true; visible: !!popup.state.output
                    onCitation: function(link, plan) { popup.followCitation(link); }
                }
                Label {
                    objectName: "aiTermStatus"
                    text: popup.state.status || ""
                    visible: !!text && (popup.state.phase !== "done" || !popup.state.output)
                    textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true
                    font.pixelSize: 11; color: popup.state.phase === "failed" ? app.colors.errorFg : app.colors.textSecondary
                }
            }
        }
        ReadingPrimaryButton {
            objectName: "reviewAiTermRequest"
            app: popup.app; text: popup.app.requiresAiTaskReview ? qsTr("Review request…") : qsTr("Send request"); Layout.fillWidth: true
            visible: popup.state.phase === "preview"
            enabled: popup.ownsWorker && popup.opened && !!popup.state.plan
            onClicked: popup.showReview()
        }
    }
}

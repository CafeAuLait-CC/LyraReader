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
    property var reviewTicket: null
    property string workerId: ""
    property var frozenState: null
    readonly property var reader: ticket ? ticket.reader : null
    readonly property var controller: reader ? reader.readingTerm : null
    readonly property var state: frozenState || (controller ? controller.state : ({}))
    readonly property bool current: !!ticket && !!reader && reader === app.currentReader && ticket.generation === reader.documentGeneration
    readonly property bool ownsWorker: current && !!workerId && controller.state.request_id === workerId
    readonly property bool busy: ["preparing", "starting", "running"].indexOf(state.phase) >= 0
    readonly property bool anyVisible: visible || review.visible
    parent: Overlay.overlay
    width: Math.max(120, Math.min(340, parent ? parent.width - 16 : 340))
    height: Math.max(160, Math.min(300, parent ? parent.height - 16 : 300))
    padding: 16; focus: true; modal: false
    closePolicy: Popup.CloseOnEscape | (review.visible ? Popup.NoAutoClose : Popup.CloseOnPressOutside)
    background: Rectangle {radius: 8; color: app.colors.panelBg; border.color: app.colors.separator}
    enter: Transition {NumberAnimation {property: "opacity"; from: 0; to: 1; duration: app.reduceMotion ? 0 : 100}}
    exit: Transition {NumberAnimation {property: "opacity"; from: 1; to: 0; duration: app.reduceMotion ? 0 : 80}}
    function openFor(owner, generation, request, anchor, sourceRow) {
        if (!owner || owner !== app.currentReader || owner.documentGeneration !== generation || !parent) return false;
        review.close();
        if (ownsWorker) controller.dismiss();
        frozenState = null; workerId = "";
        ticket = {reader: owner, generation: generation, request: request, anchor: anchor, sourceRow: sourceRow,
            record: sourceRow ? sourceRow.recordId : ""};
        const active = ticket;
        closingTicket = null; reviewTicket = null;
        const point = anchor ? anchor.mapToItem(parent, 0, anchor.height) : Qt.point(parent.width / 2, parent.height / 2);
        x = Math.max(8, Math.min(parent.width - width - 8, point.x));
        y = Math.max(8, Math.min(parent.height - height - 8, point.y));
        open();
        if (!controller.prepare(request)) { close(); return false; }
        if (ticket !== active) return false;
        ticket.worker = controller.state.request_id; workerId = ticket.worker;
        return true;
    }
    function showReview() {
        if (!ownsWorker || !opened || state.phase !== "preview" || !state.plan) return;
        reviewTicket = {owner: ticket, plan: state.plan};
        review.open();
    }
    function sendReviewed() {
        const approved = reviewTicket;
        if (!opened || !review.opened || !ownsWorker || !approved || approved.owner !== ticket || state.phase !== "preview"
                || !state.plan || state.plan.term_token !== approved.plan.term_token) return;
        app.sendAi(reader, approved.plan, "term");
        review.close();
    }
    function followCitation(link) {
        if (current) task.panel.followVerifiedPage(link, state.sent_pages || [], ticket.generation);
    }
    onAboutToHide: {
        closingTicket = ticket;
        frozenState = controller ? controller.state : ({});
        review.close();
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
        ticket = null; reviewTicket = null; workerId = ""; frozenState = null;
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
            app: popup.app; text: qsTr("Review request…"); Layout.fillWidth: true
            visible: popup.state.phase === "preview"
            enabled: popup.ownsWorker && popup.opened && !!popup.state.plan
            onClicked: popup.showReview()
        }
    }
    Dialog {
        id: review
        objectName: "aiTermReview"
        parent: Overlay.overlay
        title: qsTr("Review term explanation")
        modal: true; focus: true; padding: 16
        closePolicy: Popup.CloseOnEscape
        width: Math.min(620, parent.width - 24); height: Math.min(560, parent.height - 24)
        x: (parent.width - width) / 2; y: (parent.height - height) / 2
        background: Rectangle {radius: 8; color: app.colors.panelBg; border.color: app.colors.separator}
        contentItem: ColumnLayout {
            spacing: 12
            Label {
                text: qsTr("Nothing has been sent. These are the exact request bodies.")
                textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textSecondary
            }
            AiReadingScrollView {
                id: reviewScroll
                Layout.fillWidth: true; Layout.fillHeight: true
                TextArea {
                    objectName: "aiTermRequestBodies"
                    text: popup.reviewTicket ? (popup.reviewTicket.plan.parts || []).map(part => part.wire_body).join("\n\n") : ""
                    width: reviewScroll.availableWidth; readOnly: true; selectByMouse: true; selectByKeyboard: true
                    wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText; font.family: "monospace"; font.pixelSize: 11
                    color: app.colors.textPrimary; background: null
                    Accessible.name: qsTr("Exact term request bodies")
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Button {text: qsTr("Cancel"); onClicked: review.close()}
                ReadingPrimaryButton {
                    objectName: "sendAiTermRequest"
                    app: popup.app; text: qsTr("Send"); Layout.fillWidth: true
                    enabled: popup.ownsWorker && !!popup.reviewTicket && popup.reviewTicket.owner === popup.ticket && popup.state.phase === "preview"
                    onClicked: popup.sendReviewed()
                }
            }
        }
    }
}

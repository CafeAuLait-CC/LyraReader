import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

ApplicationWindow {
    id: review
    objectName: "aiTaskReviewWindow"
    required property var app
    property var ticket: null
    property bool bodyExpanded: false
    property bool restoreParentFocus: false
    property var cursorIntent: null
    onTicketChanged: cursorIntent = null
    readonly property var owner: ticket ? ticket.reader : null
    readonly property var plan: ticket ? ticket.plan : null
    readonly property var parts: plan && plan.parts !== undefined ? plan.parts : []
    readonly property bool current: !!ticket && app.aiTaskReviewIsCurrent(ticket)
    readonly property bool canSend: current && !!owner && owner.pendingCommands === 0
    onCurrentChanged: if (ticket && !current) Qt.callLater(validate)
    visible: false
    flags: Qt.Dialog
    transientParent: app
    title: qsTr("Review AI task · LyraReader")
    color: app.colors.panelBg
    palette: app.palette
    font.pixelSize: 13
    AuxiliaryWindowPolicy { id: policy }

    function open(next) {
        if (!app.aiTaskReviewIsCurrent(next)) return false;
        if (visible && ticket && ticket.reader === next.reader
                && ticket.purpose === next.purpose && app.sameAiReviewPlan(ticket.plan, next.plan)) {
            requestActivate(); return true;
        }
        cancel();
        ticket = next; bodyExpanded = false; requestIndex.currentIndex = 0;
        if (!parts || typeof parts.length !== "number" || parts.length < 1) {
            cancel();
            app.operationStatus = qsTr("The task has no readable request preview. Prepare it again.");
            return false;
        }
        if (!policy.prepare(review, app, {}, 540, 480)) {
            ticket = null;
            app.operationStatus = qsTr("The task review could not find an available display.");
            return false;
        }
        policy.present(app.auxiliaryWindowOwner);
        return true;
    }
    function cancel() {
        policy.cancelPresentation();
        ticket = null;
        if (visible) { restoreParentFocus = active; close(); }
    }
    function validate() { if (ticket && !app.aiTaskReviewIsCurrent(ticket)) cancel(); }
    function requestBodyCursor() {
        cursorIntent = {ticket: ticket, interaction: reviewScroll.interactionEpoch};
        Qt.callLater(revealBodyCursor);
    }
    function revealBodyCursor() {
        const intent = cursorIntent;
        if (!intent) return;
        if (ticket !== intent.ticket || !visible || !bodyExpanded || !wireBody.activeFocus
                || intent.interaction !== reviewScroll.interactionEpoch) {
            cursorIntent = null; return;
        }
        reviewScroll.revealRect(wireBody, wireBody.cursorRectangle);
        intent.interaction = reviewScroll.interactionEpoch;
    }
    function send() {
        if (!canSend) return;
        const approved = ticket;
        // Clear the UI intent before close/focus callbacks. Native start still
        // validates the source and exact plan before any request is sent.
        ticket = null;
        restoreParentFocus = active;
        close();
        if (approved.reader) app.sendAi(approved.reader, approved.plan, approved.purpose, approved.token);
    }
    onClosing: {
        policy.cancelPresentation(); ticket = null; bodyExpanded = false;
        const restore = restoreParentFocus || active;
        restoreParentFocus = false;
        if (restore) policy.returnFocus();
    }
    Connections {
        target: review.owner
        function onAiStateChanged() { review.validate(); }
        function onDocumentChanged() { review.validate(); }
        function onDocumentReadingChanged() { review.validate(); }
    }
    Connections {
        target: review.owner ? review.owner.readingTerm : null
        function onChanged() { review.validate(); }
    }
    Connections {
        target: review.app
        function onCurrentReaderChanged() { review.validate(); }
        function onAiReviewRevisionChanged() { review.validate(); }
    }
    Shortcut { sequence: "Escape"; enabled: review.visible; onActivated: review.cancel() }
    Shortcut { sequence: "Return"; enabled: review.visible && review.canSend; onActivated: review.send() }
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 20; spacing: 12
        Label { text: qsTr("Review AI task"); font.pixelSize: 16; font.weight: Font.DemiBold }
        Label {
            Layout.fillWidth: true; Layout.minimumWidth: 0
            text: review.plan ? review.plan.host + " · " + review.plan.model : ""
            textFormat: Text.PlainText; elide: Text.ElideMiddle
            color: review.app.colors.textSecondary
        }
        Label {
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            text: review.plan && review.plan.source_pages && typeof review.plan.source_pages.length === "number"
                ? qsTr("Source pages: %1 · Requests: %2").arg(review.plan.source_pages.length).arg(review.parts.length)
                : qsTr("The request body includes its exact source scope.")
            color: review.app.colors.textSecondary
        }
        AiReadingScrollView {
            id: reviewScroll
            objectName: "aiReviewBodyScroll"
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: availableWidth
            Connections {
                target: reviewScroll.contentItem
                function onContentHeightChanged() { if (review.cursorIntent) Qt.callLater(review.revealBodyCursor); }
                function onHeightChanged() { if (review.cursorIntent) Qt.callLater(review.revealBodyCursor); }
            }
            ColumnLayout {
                width: reviewScroll.availableWidth
                spacing: 12
                Label {
                    objectName: "aiReviewPreferenceNotice"
                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    visible: !review.app.aiReviewPreferenceKnown
                    text: qsTr("The saved review preference is unrecognized. Review this task before sending; the saved preference is kept.")
                    color: review.app.colors.warningFg
                }
                Button {
                    objectName: "showAiReviewBody"
                    flat: true
                    text: review.bodyExpanded ? qsTr("Hide request body") : qsTr("Show request body")
                    onClicked: review.bodyExpanded = !review.bodyExpanded
                }
                ComboBox {
                    id: requestIndex
                    objectName: "aiReviewRequestIndex"
                    visible: review.bodyExpanded && review.parts.length > 1
                    Layout.fillWidth: true
                    model: review.parts.map((part, index) => qsTr("Request %1").arg(index + 1))
                    onModelChanged: currentIndex = model.length ? 0 : -1
                    Accessible.name: qsTr("Request in this task")
                }
                TextArea {
                    id: wireBody
                    objectName: "aiReviewWireBody"
                    Layout.fillWidth: true
                    visible: review.bodyExpanded
                    text: review.bodyExpanded && review.parts[requestIndex.currentIndex]
                        ? review.parts[requestIndex.currentIndex].wire_body : ""
                    readOnly: true; selectByMouse: true; selectByKeyboard: true
                    textFormat: TextEdit.PlainText; wrapMode: TextEdit.WrapAnywhere
                    font.family: "monospace"; font.pixelSize: 12
                    Accessible.name: qsTr("Exact AI request body")
                    Accessible.editable: false
                    onActiveFocusChanged: {
                        if (activeFocus) review.requestBodyCursor();
                        else review.cursorIntent = null;
                    }
                    onCursorRectangleChanged: if (review.cursorIntent) Qt.callLater(review.revealBodyCursor)
                    Keys.onPressed: function(event) {
                        if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down, Qt.Key_Home,
                             Qt.Key_End, Qt.Key_PageUp, Qt.Key_PageDown].indexOf(event.key) >= 0)
                            review.requestBodyCursor();
                        event.accepted = false;
                    }
                }
            }
        }
        Label {
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            text: qsTr("A long summary may need a final synthesis using the same provider and source scope.")
            font.pixelSize: 11; color: review.app.colors.textSecondary
        }
        RowLayout {
            Layout.fillWidth: true
            Button { text: qsTr("Cancel"); onClicked: review.cancel() }
            Item { Layout.fillWidth: true }
            ReadingPrimaryButton {
                objectName: "sendReviewedAiTask"
                app: review.app; text: qsTr("Send task")
                enabled: review.canSend
                onClicked: review.send()
            }
        }
    }
}

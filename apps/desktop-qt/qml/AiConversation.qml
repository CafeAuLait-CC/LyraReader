import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ScrollView {
    id: conversation
    objectName: "aiConversationHistory"
    required property var app
    required property var viewState
    property bool followTail: true
    property bool positioning: false
    readonly property var owner: app.currentReader
    readonly property bool active: !!viewState.running && viewState.responseView === "chat"
    signal citation(string link, var plan)
    contentWidth: availableWidth
    clip: true
    function followAnswer() {
        if (!visible || !followTail) return;
        Qt.callLater(function() {
            if (!conversation.visible || !conversation.followTail) return;
            conversation.positioning = true;
            conversation.contentItem.contentY = Math.max(0, conversation.contentItem.contentHeight - conversation.contentItem.height);
            conversation.positioning = false;
        });
    }
    onVisibleChanged: if (visible) followAnswer()
    onAvailableHeightChanged: followAnswer()
    onAvailableWidthChanged: followAnswer()
    onOwnerChanged: { followTail = true; followAnswer(); }
    onActiveChanged: if (active) { followTail = true; followAnswer(); }
    onViewStateChanged: followAnswer()
    Keys.onPressed: function(event) {
        if ([Qt.Key_Up, Qt.Key_PageUp, Qt.Key_Home].indexOf(event.key) >= 0) followTail = false;
        event.accepted = false;
    }
    // Wheel events still reach the ScrollView. A deliberate upward gesture stops
    // following before the next streaming chunk changes the content height.
    WheelHandler {
        target: null
        blocking: false
        onWheel: function(event) { if (event.angleDelta.y > 0 || event.pixelDelta.y > 0) conversation.followTail = false; event.accepted = false; }
    }
    Connections {
        target: conversation.contentItem
        function onMovementStarted() { conversation.followTail = false; }
        function onMovementEnded() { conversation.followTail = conversation.contentItem.atYEnd; }
        function onContentYChanged() {
            if (!conversation.positioning && conversation.contentItem.atYEnd) conversation.followTail = true;
        }
        function onContentHeightChanged() { conversation.followAnswer(); }
    }
    ScrollBar.vertical: ScrollBar {
        onPressedChanged: {
            if (pressed) conversation.followTail = false;
            else if (conversation.contentItem.atYEnd) conversation.followTail = true;
        }
    }
    ColumnLayout {
        width: conversation.availableWidth
        spacing: 12
        Repeater {
            model: conversation.viewState.chatTurns || []
            ColumnLayout {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: question.implicitHeight + 16; radius: 6; color: app.colors.accentSoft
                    Label { id: question; anchors.fill: parent; anchors.margins: 8; text: modelData.question; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.colors.textPrimary }
                }
                Label {
                    text: modelData.state === "cancelled" ? qsTr("Cancelled · partial answer") : modelData.state === "failed" ? qsTr("Request failed") : qsTr("Completed")
                    color: app.colors.textSecondary; font.pixelSize: 11
                }
                AiResult {
                    Layout.fillWidth: true; app: conversation.app; answerName: "aiHistoryAnswer" + index; showSources: true
                    value: ({output: modelData.answer, reasoning: modelData.reasoning, generation: modelData.generation, responsePlan: {action: "DocumentChat", sources: modelData.sources || []}})
                    onCitation: function(link, plan) { conversation.citation(link, plan); }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: app.colors.separator }
            }
        }
        ColumnLayout {
            visible: conversation.active
            Layout.fillWidth: true
            Rectangle {
                Layout.fillWidth: true; implicitHeight: activeQuestion.implicitHeight + 16; radius: 6; color: app.colors.accentSoft
                Label { id: activeQuestion; anchors.fill: parent; anchors.margins: 8; text: conversation.viewState.activeQuestion || ""; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.colors.textPrimary }
            }
            AiResult {
                Layout.fillWidth: true; app: conversation.app; answerName: "aiStreamingChatAnswer"; showSources: true
                value: ({output: conversation.viewState.output, reasoning: conversation.viewState.reasoning, responsePlan: conversation.viewState.responsePlan, generation: app.currentReader.documentGeneration})
                onCitation: function(link, plan) { conversation.citation(link, plan); }
            }
        }
        Label {
            visible: !(conversation.viewState.chatTurns || []).length && !conversation.active
            text: qsTr("Ask a question about this document. Preview the passages and request before sending.")
            Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.colors.textSecondary
        }
    }
}

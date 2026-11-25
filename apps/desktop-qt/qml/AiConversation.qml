import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

AiReadingScrollView {
    id: conversation
    objectName: "aiConversationHistory"
    required property var app
    required property var viewState
    property bool followTail: true
    property bool positioning: false
    readonly property var owner: app.currentReader
    readonly property bool active: !!viewState.running && viewState.responseView === "chat"
    signal citation(string link, var plan)
    signal keepNote(string source)
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
    onScrollIntent: function(dx, dy) { if (dy > 0) followTail = false; }
    Connections {
        target: conversation.contentItem
        function onMovementStarted() { conversation.followTail = false; }
        function onMovementEnded() { conversation.followTail = conversation.contentItem.atYEnd; }
        function onContentYChanged() {
            if (!conversation.positioning && conversation.contentItem.atYEnd) conversation.followTail = true;
        }
        function onContentHeightChanged() { conversation.followAnswer(); }
    }
    onVerticalBarPressedChanged: {
        if (verticalBarPressed) followTail = false;
        else if (contentItem && contentItem.atYEnd) followTail = true;
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
                    text: modelData.state === "archived" ? qsTr("Saved exchange")
                          : modelData.state === "cancelled" ? qsTr("Cancelled · partial answer")
                          : modelData.state === "failed" ? qsTr("Request failed")
                          : modelData.state === "partial" ? qsTr("Partial answer") : qsTr("Completed")
                    color: app.colors.textSecondary; font.pixelSize: 11
                }
                AiResult {
                    Layout.fillWidth: true; app: conversation.app; answerName: "aiHistoryAnswer" + index; showSources: true; viewport: conversation.contentItem
                    value: ({output: modelData.answer, reasoning: modelData.reasoning, usage: modelData.usage, generation: modelData.generation, responsePlan: {action: "DocumentChat", sources: modelData.sources || []}})
                    onKeyboardNavigation: function(key) {
                    if ([Qt.Key_Up, Qt.Key_PageUp, Qt.Key_Home].indexOf(key) >= 0) conversation.followTail = false;
                }
                onCitation: function(link, plan) { conversation.citation(link, plan); }
                }
                Button {
                    objectName: "keepAiChatNote" + index
                    text: qsTr("Keep as note")
                    visible: !!modelData.note_source && modelData.state === "finished"
                    enabled: visible && !conversation.owner.readingNoteDraft.id
                    onClicked: conversation.keepNote(modelData.note_source)
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
                Layout.fillWidth: true; app: conversation.app; answerName: "aiStreamingChatAnswer"; showSources: true; viewport: conversation.contentItem
                value: ({output: conversation.viewState.output, reasoning: conversation.viewState.reasoning, usage: conversation.viewState.usage, responsePlan: conversation.viewState.responsePlan, generation: app.currentReader.documentGeneration})
                onKeyboardNavigation: function(key) {
                    if ([Qt.Key_Up, Qt.Key_PageUp, Qt.Key_Home].indexOf(key) >= 0) conversation.followTail = false;
                }
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

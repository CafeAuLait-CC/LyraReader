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
    signal retry()
    property string statusMessage: ""
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
    component QuestionBubble: Rectangle {
        required property string questionText
        required property string labelName
        Layout.alignment: Qt.AlignRight
        Layout.preferredWidth: Math.min(conversation.availableWidth - 18, question.implicitWidth + 20)
        implicitHeight: question.implicitHeight + 20
        radius: 10; color: app.colors.selectedBg
        TextArea {
            id: question
            objectName: parent.labelName
            x: 10; y: 10; width: parent.width - 20
            text: parent.questionText
            textFormat: TextEdit.PlainText; wrapMode: TextEdit.Wrap
            readOnly: true; selectByMouse: true; selectByKeyboard: true
            activeFocusOnTab: false
            padding: 0; background: null; color: app.colors.selectedFg; font.pixelSize: 14
            Accessible.name: qsTr("Question")
        }
    }
    ColumnLayout {
        width: conversation.availableWidth
        spacing: 16
        Repeater {
            model: conversation.viewState.chatTurns || []
            ColumnLayout {
                id: turn
                required property var modelData
                required property int index
                Layout.fillWidth: true; spacing: 10
                QuestionBubble { questionText: turn.modelData.question; labelName: "aiChatQuestion" + turn.index }
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    LyraToolButton { symbol: "lyra-quill"; icon.color: app.colors.accent; implicitWidth: 16; implicitHeight: 16; padding: 0; focusPolicy: Qt.NoFocus; hoverEnabled: false; Accessible.ignored: true; background: null }
                    Label { text: qsTr("Lyra"); color: app.colors.accent; font.pixelSize: 11; font.weight: Font.DemiBold }
                    Item { Layout.fillWidth: true }
                    LyraToolButton {
                        objectName: "keepAiChatNote" + turn.index
                        symbol: "note-add"; text: qsTr("Keep in notes")
                        visible: !!turn.modelData.note_source && turn.modelData.state === "finished"
                        enabled: visible && !conversation.owner.readingNoteDraft.id && !conversation.owner.pendingCommands
                        onClicked: conversation.keepNote(turn.modelData.note_source)
                    }
                    LyraToolButton {
                        objectName: "copyAiChatAnswer" + turn.index
                        symbol: "copy"; text: qsTr("Copy answer")
                        visible: !!turn.modelData.answer
                        onClicked: if (app.session) app.session.copyText(turn.modelData.answer)
                    }
                }
                AiResult {
                    Layout.fillWidth: true; app: conversation.app; answerName: "aiHistoryAnswer" + turn.index
                    showSources: true; inlineConversation: true; bodySize: 14; viewport: conversation.contentItem
                    value: ({output: turn.modelData.answer, reasoning: turn.modelData.reasoning, usage: turn.modelData.usage, generation: turn.modelData.generation,
                             responsePlan: {action: "DocumentChat", sources: turn.modelData.sources || []}})
                    onKeyboardNavigation: function(key) {
                        if ([Qt.Key_Up, Qt.Key_PageUp, Qt.Key_Home].indexOf(key) >= 0) conversation.followTail = false;
                    }
                    onCitation: function(link, plan) { conversation.citation(link, plan); }
                }
                Label {
                    visible: ["cancelled", "failed", "partial", "archived"].indexOf(turn.modelData.state) >= 0
                    text: turn.modelData.state === "archived" ? qsTr("Saved exchange") : turn.modelData.state === "cancelled" ? qsTr("Cancelled · partial answer")
                        : turn.modelData.state === "failed" ? qsTr("Request failed") : qsTr("Partial answer")
                    color: app.colors.textSecondary; font.pixelSize: 11
                }
                RowLayout {
                    visible: ["cancelled", "failed"].indexOf(turn.modelData.state) >= 0
                    Layout.fillWidth: true
                    Button {
                        objectName: "retryAiChatTurn" + turn.index
                        text: qsTr("Retry")
                        enabled: turn.index === (conversation.viewState.chatTurns || []).length - 1 && !conversation.active && !!conversation.viewState.planSent
                            && !!conversation.viewState.plan && !conversation.owner.pendingCommands && turn.modelData.generation === conversation.owner.documentGeneration
                        onClicked: conversation.retry()
                    }
                    Label { Layout.fillWidth: true; text: qsTr("Sends the same previewed question again."); wrapMode: Text.Wrap; color: app.colors.textSecondary; font.pixelSize: 11 }
                }

            }
        }
        ColumnLayout {
            visible: conversation.active
            Layout.fillWidth: true; spacing: 10
            QuestionBubble { questionText: conversation.viewState.activeQuestion || ""; labelName: "aiStreamingChatQuestion" }
            RowLayout {
                spacing: 8
                LyraToolButton { symbol: "lyra-quill"; icon.color: app.colors.accent; implicitWidth: 16; implicitHeight: 16; padding: 0; focusPolicy: Qt.NoFocus; hoverEnabled: false; Accessible.ignored: true; background: null }
                Label { text: qsTr("Lyra"); color: app.colors.accent; font.pixelSize: 11; font.weight: Font.DemiBold }
            }
            AiResult {
                Layout.fillWidth: true; app: conversation.app; answerName: "aiStreamingChatAnswer"
                showSources: true; inlineConversation: true; bodySize: 14; viewport: conversation.contentItem
                value: ({output: conversation.viewState.output, reasoning: conversation.viewState.reasoning, usage: conversation.viewState.usage,
                         responsePlan: conversation.viewState.responsePlan, generation: app.currentReader.documentGeneration})
                onKeyboardNavigation: function(key) {
                    if ([Qt.Key_Up, Qt.Key_PageUp, Qt.Key_Home].indexOf(key) >= 0) conversation.followTail = false;
                }
                onCitation: function(link, plan) { conversation.citation(link, plan); }
            }
            Label { text: conversation.viewState.output ? qsTr("%1 characters received").arg(conversation.viewState.output.length) : qsTr("Waiting for the first token…"); font.pixelSize: 10; color: app.colors.textSecondary }
        }
        Label { visible: !!conversation.statusMessage; text: conversation.statusMessage; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11 }
        ColumnLayout {
            visible: !(conversation.viewState.chatTurns || []).length && !conversation.active
            Layout.fillWidth: true; spacing: 8
            Label { text: qsTr("Ask the whole document"); font.pixelSize: 14; font.weight: Font.DemiBold; color: app.colors.textPrimary; wrapMode: Text.Wrap; Layout.fillWidth: true }
            Label { text: qsTr("Ask a question. Answers link back to passages in this document."); font.pixelSize: 12; color: app.colors.textSecondary; wrapMode: Text.Wrap; Layout.fillWidth: true }
        }
    }
}

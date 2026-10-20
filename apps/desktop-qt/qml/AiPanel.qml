import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "ReaderLogic.js" as Logic

Pane {
    id: aiPanel
    objectName: "aiPanel"
    required property var app
    readonly property var owner: app.currentReader
    readonly property var viewState: owner.aiState
    readonly property var plan: viewState.plan || null
    readonly property bool running: !!viewState.running
    readonly property var input: viewState.input || ({})
    padding: 10
    background: Rectangle {
        color: app.colors.sidebarBg
    }
    function prepare() {
        const settings = app.aiSettings;
        const modes = ["SummarizePage", "SummarizeDocument", "AskSelection", "TranslateSelection"];
        owner.prepareAi({
            action: modes[actionBox.currentIndex],
            current_page: app.currentPage,
            selection: app.selection ? {
                page: app.selection.page,
                start: Math.min(app.selection.start, app.selection.end),
                end: Math.max(app.selection.start, app.selection.end)
            } : null,
            question: question.text.length ? question.text : null,
            language: language.text.length ? language.text : null,
            base_url: settings.baseUrl || "http://localhost:11434/v1",
            model: settings.model || "",
            temperature: null,
            max_tokens: null,
            reasoning_mode: settings.reasoningMode || "default",
            reasoning_encoding: settings.reasoningEncoding || "none"
        });
    }
    function followLink(link) {
        const match = /^p\.(\d+)$/.exec(link);
        if (!match)
            return;
        const page = Number(match[1]) - 1;
        if (page >= 0 && page < owner.pageCount)
            app.navigate(page);
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: 8
        Label {
            text: aiPanel.running ? (aiPanel.viewState.activeModel || "") + " · " + (aiPanel.viewState.activeHost || "") : (app.aiSettings.model || qsTr("Choose an AI model in Settings"))
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            color: app.colors.textSecondary
            font.pixelSize: 11
        }
        ComboBox {
            id: actionBox
            objectName: "aiAction"
            Layout.fillWidth: true
            model: [qsTr("Summarize this page"), qsTr("Summarize document"), qsTr("Ask about selection"), qsTr("Translate selection")]
            currentIndex: aiPanel.input.action || 0
            enabled: !aiPanel.running
            Accessible.name: qsTr("AI action")
            onActivated: aiPanel.owner.setAiInput("action", currentIndex)
        }
        TextArea {
            id: question
            objectName: "aiQuestion"
            text: aiPanel.input.question || ""
            Layout.fillWidth: true
            Layout.preferredHeight: 70
            visible: actionBox.currentIndex === 2
            enabled: !aiPanel.running
            placeholderText: qsTr("Question about selected text")
            wrapMode: TextEdit.Wrap
            Accessible.name: qsTr("Question about selection")
            onTextChanged: if (activeFocus)
                aiPanel.owner.setAiInput("question", text)
        }
        TextField {
            id: language
            visible: actionBox.currentIndex === 3
            enabled: !aiPanel.running
            Layout.fillWidth: true
            placeholderText: qsTr("Target language")
            text: aiPanel.input.language || "中文"
            Accessible.name: qsTr("Translation language")
            onTextEdited: aiPanel.owner.setAiInput("language", text)
        }
        Button {
            objectName: "prepareAiRequest"
            text: qsTr("Preview Request")
            Layout.fillWidth: true
            enabled: !aiPanel.running && aiPanel.owner.pageCount > 0 && aiPanel.owner.pendingCommands === 0
            onClicked: aiPanel.prepare()
        }
        Label {
            text: aiPanel.viewState.status || ""
            visible: text.length > 0
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            color: app.colors.textSecondary
            font.pixelSize: 11
            Accessible.role: Accessible.StaticText
        }
        Label {
            visible: !!aiPanel.plan
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: aiPanel.plan ? (aiPanel.plan.is_local ? qsTr("Local endpoint: %1").arg(aiPanel.plan.host) : qsTr("Remote endpoint: %1").arg(aiPanel.plan.host)) + "\n" + qsTr("%1 request(s), about %2 tokens").arg(aiPanel.plan.parts.length).arg(aiPanel.plan.estimated_tokens) : ""
            color: app.colors.infoFg
            font.pixelSize: 11
        }
        RowLayout {
            visible: !!aiPanel.plan && !aiPanel.running
            Button {
                text: qsTr("Inspect Payload")
                Layout.fillWidth: true
                onClicked: payload.open()
            }
            Button {
                objectName: "sendAiRequest"
                text: qsTr("Send")
                Layout.fillWidth: true
                enabled: aiPanel.owner.pendingCommands === 0
                onClicked: app.sendAi(aiPanel.owner, aiPanel.plan)
            }
        }
        Button {
            objectName: "cancelAiRequest"
            text: qsTr("Cancel")
            visible: aiPanel.running
            Layout.fillWidth: true
            onClicked: aiPanel.owner.cancelAi()
        }
        ToolButton {
            id: reasoningToggle
            objectName: "aiReasoningToggle"
            visible: !!aiPanel.viewState.reasoning
            text: qsTr("Provider reasoning") + (checked ? " ▴" : " ▾")
            checkable: true
            Accessible.name: qsTr("Show provider reasoning separately")
        }
        ScrollView {
            visible: reasoningToggle.visible && reasoningToggle.checked
            Layout.fillWidth: true
            Layout.preferredHeight: 110
            contentWidth: availableWidth
            TextArea {
                objectName: "aiReasoningText"
                text: aiPanel.viewState.reasoning || ""
                readOnly: true
                selectByMouse: true
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                background: null
                font.pixelSize: 11
            }
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            TextArea {
                objectName: "aiAnswerText"
                text: Logic.answerMarkup(aiPanel.viewState.output || "")
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                background: null
                textFormat: TextEdit.RichText
                Accessible.name: qsTr("AI response")
                onLinkActivated: function (link) {
                    aiPanel.followLink(link);
                }
            }
        }
        Label {
            visible: !!aiPanel.viewState.usage && !!aiPanel.viewState.usage.total_tokens
            text: qsTr("Tokens: %1").arg(aiPanel.viewState.usage ? aiPanel.viewState.usage.total_tokens || 0 : 0)
            color: app.colors.textTertiary
            font.pixelSize: 10
        }
        RowLayout {
            Button {
                text: qsTr("Copy")
                enabled: !!aiPanel.viewState.output
                onClicked: if (app.session)
                    app.session.copyText(aiPanel.viewState.output)
            }
            Button {
                objectName: "retryAiRequest"
                text: qsTr("Retry")
                enabled: !!aiPanel.plan && !aiPanel.running && aiPanel.owner.pendingCommands === 0
                onClicked: app.sendAi(aiPanel.owner, aiPanel.plan)
            }
            LyraToolButton {
                symbol: "settings"
                text: qsTr("AI settings")
                onClicked: app.showSettings()
            }
        }
    }
    Dialog {
        id: payload
        title: qsTr("Request preview — nothing sent yet")
        modal: true
        width: Math.min(680, app.width - 60)
        height: Math.min(550, app.height - 60)
        parent: Overlay.overlay
        anchors.centerIn: parent
        standardButtons: Dialog.Close
        ScrollView {
            anchors.fill: parent
            contentWidth: availableWidth
            TextArea {
                text: aiPanel.plan ? JSON.stringify(aiPanel.plan, null, 2) : ""
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.WrapAnywhere
                textFormat: TextEdit.PlainText
                font.family: "monospace"
            }
        }
    }
}

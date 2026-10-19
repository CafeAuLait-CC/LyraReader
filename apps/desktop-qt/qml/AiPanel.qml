import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: ai
    required property var app
    property var plan: null
    property var planReader: null
    property string output: ""
    property string reasoning: ""
    property string status: ""
    property bool running: false
    property var usage: ({})
    padding: 10
    background: Rectangle {
        color: app.colors.sidebarBg
    }
    function prepare() {
        planReader = app.currentReader;
        ai.plan = null;
        ai.status = qsTr("Preparing request locally…");
        const settings = app.aiSettings;
        const modes = ["SummarizePage", "SummarizeDocument", "AskSelection", "TranslateSelection"];
        planReader.submit("ai_preview", {
            request: {
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
            }
        });
    }
    function send(key) {
        if (!ai.plan || !ai.planReader)
            return;
        ai.output = "";
        ai.reasoning = "";
        ai.usage = ({});
        ai.running = true;
        planReader.submit("ai_start", {
            plan: ai.plan,
            api_key: key
        });
        poll.start();
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: 9
        Label {
            text: app.aiSettings.model || qsTr("Choose an AI model in Settings")
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            color: app.colors.textSecondary
            font.pixelSize: 11
        }
        ComboBox {
            id: actionBox
            Layout.fillWidth: true
            model: [qsTr("Summarize this page"), qsTr("Summarize document"), qsTr("Ask about selection"), qsTr("Translate selection")]
        }
        TextArea {
            id: question
            Layout.fillWidth: true
            Layout.preferredHeight: 70
            visible: actionBox.currentIndex === 2
            placeholderText: qsTr("Question about selected text")
            wrapMode: Text.Wrap
        }
        TextField {
            id: language
            visible: actionBox.currentIndex === 3
            Layout.fillWidth: true
            placeholderText: qsTr("Target language")
            text: "中文"
        }
        Button {
            text: qsTr("Preview Request")
            Layout.fillWidth: true
            enabled: !ai.running && app.currentReader.pageCount > 0
            onClicked: ai.prepare()
        }
        Label {
            text: ai.status
            visible: text.length > 0
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            color: app.colors.textSecondary
            font.pixelSize: 11
        }
        Label {
            visible: !!ai.plan
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: ai.plan ? (ai.plan.is_local ? qsTr("Local endpoint: %1").arg(ai.plan.host) : qsTr("Remote endpoint: %1").arg(ai.plan.host)) + "\n" + qsTr("%1 request(s), about %2 tokens").arg(ai.plan.parts.length).arg(ai.plan.estimated_tokens) : ""
            color: app.colors.infoFg
            font.pixelSize: 11
        }
        RowLayout {
            visible: !!ai.plan && !ai.running
            Button {
                text: qsTr("Inspect Payload")
                Layout.fillWidth: true
                onClicked: payload.open()
            }
            Button {
                text: qsTr("Send")
                Layout.fillWidth: true
                onClicked: app.sendAi(ai, ai.plan)
            }
        }
        Button {
            text: qsTr("Cancel")
            visible: ai.running
            Layout.fillWidth: true
            onClicked: if (ai.planReader)
                ai.planReader.submit("ai_cancel")
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            TextArea {
                text: ai.output.replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1").replace(/\[p\.(\d+)\]/g, "[p.$1](p.$1)")
                readOnly: true
                selectByMouse: true
                wrapMode: Text.Wrap
                background: null
                textFormat: TextEdit.MarkdownText
                onLinkActivated: function (link) {
                    const match = /^p\.(\d+)$/.exec(link);
                    if (match)
                        app.navigate(Number(match[1]) - 1);
                }
            }
        }
        Label {
            visible: !!ai.usage.total_tokens
            text: qsTr("Tokens: %1").arg(ai.usage.total_tokens || 0)
            color: app.colors.textTertiary
            font.pixelSize: 10
        }
        RowLayout {
            Button {
                text: qsTr("Copy")
                enabled: ai.output.length > 0
                onClicked: if (app.session)
                    app.session.copyText(ai.output)
            }
            Button {
                text: qsTr("Retry")
                enabled: !!ai.plan && !ai.running
                onClicked: app.sendAi(ai, ai.plan)
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
            TextArea {
                text: ai.plan ? JSON.stringify(ai.plan, null, 2) : ""
                readOnly: true
                selectByMouse: true
                wrapMode: Text.WrapAnywhere
                font.family: "monospace"
            }
        }
    }
    Timer {
        id: poll
        interval: 60
        repeat: true
        onTriggered: if (ai.running && ai.planReader)
            ai.planReader.submit("ai_poll")
        else
            stop()
    }
    Connections {
        target: ai.planReader
        function onCommandFinished(id, op, result, error) {
            if (op === "ai_preview") {
                ai.plan = error.length ? null : result;
                ai.status = error;
            } else if (op === "ai_start" && error.length) {
                ai.running = false;
                ai.status = error;
            } else if (op === "ai_poll" && !error.length) {
                for (const event of result.events) {
                    if (event.Delta)
                        ai.output += event.Delta.text;
                    if (event.ReasoningDelta)
                        ai.reasoning += event.ReasoningDelta.text;
                    if (event.Usage)
                        ai.usage = event.Usage;
                    if (event.Error) {
                        ai.status = event.Error.message;
                        ai.running = false;
                    }
                    if (event.PartStarted)
                        ai.output += (ai.output.length ? "\n\n" : "") + "### " + event.PartStarted.label + "\n\n";
                }
                if (result.finished)
                    ai.running = false;
            }
        }
    }
}

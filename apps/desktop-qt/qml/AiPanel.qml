import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: aiPanel
    objectName: "aiPanel"
    required property var app
    readonly property var owner: app.currentReader
    readonly property var viewState: owner.aiState
    readonly property var input: viewState.input || ({})
    readonly property string workspace: input.view || "summary"
    readonly property int action: workspace === "chat" ? 4 : workspace === "translation" ? 3 : (input.summaryAction === undefined ? 1 : input.summaryAction)
    readonly property string workspaceTitle: workspace === "chat" ? qsTr("Document chat") : workspace === "translation" ? qsTr("Translation") : qsTr("Summary")
    readonly property var plan: viewState.previewView === workspace ? viewState.plan || null : null
    readonly property bool previewReady: !!plan && !viewState.planSent
    readonly property bool running: !!viewState.running
    readonly property var result: viewState.responseView === workspace ? ({output: viewState.output, reasoning: viewState.reasoning, usage: viewState.usage, responsePlan: viewState.responsePlan, generation: owner.documentGeneration}) : ((viewState.results || {})[workspace] || {})
    readonly property string status: viewState.statusView === workspace ? viewState.status || "" : (((viewState.results || {})[workspace] || {}).status || "")
    padding: 10
    background: Rectangle { color: app.colors.sidebarBg }
    function prepare() {
        const settings = app.aiSettings;
        const modes = ["SummarizePage", "SummarizeDocument", "AskSelection", "TranslateSelection", "DocumentChat", "SummarizeSelection"];
        owner.prepareAi({
            action: modes[action],
            document_knowledge: false, document_knowledge_text: null, document_knowledge_pages: [],
            history: [], region: null, current_page: app.currentPage,
            selection: app.selection ? {page: app.selection.page, start: Math.min(app.selection.start, app.selection.end), end: Math.max(app.selection.start, app.selection.end)} : null,
            question: (action === 2 || action === 4) ? input.question || null : null,
            language: action === 3 ? (input.language === undefined ? "English" : input.language) : null,
            base_url: settings.baseUrl || "http://localhost:11434/v1", model: settings.model || "",
            temperature: null, max_tokens: null,
            reasoning_mode: settings.reasoningMode || "default", reasoning_encoding: settings.reasoningEncoding || "none"
        });
    }
    function followLink(link) {
        const plan=aiPanel.result.responsePlan || {};
        followHistoryLink(link,{action:plan.action,sources:plan.sources || [],source_pages:plan.source_pages || [],generation:aiPanel.result.generation});
    }
    function followHistoryLink(link,responsePlan) {
        if(responsePlan.generation!==owner.documentGeneration) {
            app.operationStatus=qsTr("The document changed. This earlier citation is no longer available.");return;
        }
        const match = /^p\.(\d+)$/.exec(link);
        if (!match)
            return;
        if (responsePlan.action === "TranslateSelection") return;
        const page = Number(match[1]) - 1;
        if (responsePlan.action === "DocumentChat") {
            const source = (responsePlan.sources || []).find(s => s.page === page + 1);
            if (!source || page < 0 || page >= owner.pageCount) {
                app.operationStatus = qsTr("This citation cannot be verified from the document passages sent.");
                return;
            }
            const region = (source.rects || [])[0];
            app.navigate(page, region ? region.y_pt : 0);
            return;
        }
        if (page >= 0 && page < owner.pageCount && (responsePlan.source_pages || []).indexOf(page + 1) >= 0)
            app.navigate(page);
        else app.operationStatus = qsTr("This citation cannot be verified from the document passages sent.");
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: 6
        RowLayout {
            Layout.fillWidth: true
            spacing: 2
            Repeater {
                model: [{key: "summary", title: qsTr("Summary")}, {key: "translation", title: qsTr("Translate")}, {key: "chat", title: qsTr("Chat")}]
                LyraToolButton {
                    required property var modelData
                    objectName: "aiWorkspace" + modelData.key
                    text: modelData.title
                    display: AbstractButton.TextOnly
                    selected: aiPanel.workspace === modelData.key
                    Layout.fillWidth: true
                    onClicked: aiPanel.owner.setAiInput("view", modelData.key)
                }
            }
        }
        Label {
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            text: aiPanel.running ? qsTr("Receiving: %1 · %2").arg(aiPanel.viewState.activeModel || "").arg(aiPanel.viewState.activeHost || "") : (app.aiSettings.model || qsTr("Choose an AI model in Settings"))
            color: app.colors.textSecondary; font.pixelSize: 11
        }
        ComboBox {
            objectName: "aiSummaryTarget"
            visible: aiPanel.workspace === "summary"
            Layout.fillWidth: true
            model: [qsTr("Document"), qsTr("Selected text"), qsTr("This page"), qsTr("Question about selection")]
            currentIndex: [1, 5, 0, 2].indexOf(aiPanel.action)
            Accessible.name: qsTr("Summary target")
            onActivated: aiPanel.owner.setAiInput("action", [1, 5, 0, 2][currentIndex])
        }
        TextField {
            objectName: "aiTranslationLanguage"
            visible: aiPanel.workspace === "translation"
            Layout.fillWidth: true
            text: aiPanel.input.language === undefined ? "English" : aiPanel.input.language
            placeholderText: qsTr("Target language")
            Accessible.name: qsTr("Translation language")
            onTextEdited: aiPanel.owner.setAiInput("language", text)
        }
        ScrollView {
            objectName: "aiResponseScroll"
            visible: aiPanel.workspace !== "chat"
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 24
            contentWidth: availableWidth
            AiResult {
                width: parent.width
                app: aiPanel.app; value: aiPanel.result
                onCitation: function(link, responsePlan) { aiPanel.followHistoryLink(link, responsePlan); }
            }
        }
        AiConversation {
            id: conversation
            app: aiPanel.app; viewState: aiPanel.viewState
            visible: aiPanel.workspace === "chat"
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 24
            onCitation: function(link, responsePlan) { aiPanel.followHistoryLink(link, responsePlan); }
        }
        Label {
            visible: aiPanel.workspace === "chat" && !!aiPanel.viewState.conversationLimited
            text: qsTr("Older exchanges were removed to keep the conversation within its display budget.")
            textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11
        }
        ScrollView {
            id: composerScroll
            objectName: "aiComposerScroll"
            visible: aiPanel.action === 2 || aiPanel.workspace === "chat"
            Layout.fillWidth: true; Layout.preferredHeight: 64; Layout.maximumHeight: 64
            contentWidth: availableWidth
            clip: true
            TextArea {
                id: question
                objectName: "aiQuestion"
                width: composerScroll.availableWidth
                text: aiPanel.input.question || ""
                textFormat: TextEdit.PlainText; wrapMode: TextEdit.Wrap
                placeholderText: aiPanel.workspace === "chat" ? qsTr("Ask about this document…") : qsTr("Question about selected text…")
                Accessible.name: aiPanel.workspace === "chat" ? qsTr("Question about document") : qsTr("Question about selection")
                onTextChanged: if (activeFocus) aiPanel.owner.setAiInput("question", text)
                Keys.onPressed: function(event) {
                    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier) && preview.enabled) { aiPanel.prepare(); event.accepted = true; }
                }
            }
        }
        Button {
            id: preview
            objectName: "prepareAiRequest"
            text: aiPanel.workspace === "chat" ? qsTr("Preview Question") : aiPanel.workspace === "translation" ? qsTr("Preview Translation") : aiPanel.action === 2 ? qsTr("Preview Question") : qsTr("Preview Summary")
            Layout.fillWidth: true
            enabled: !aiPanel.running && aiPanel.owner.pageCount > 0 && aiPanel.owner.pendingCommands === 0 && ((aiPanel.action !== 2 && aiPanel.action !== 4) || !!question.text.trim()) && (aiPanel.action !== 3 || aiPanel.input.language === undefined || !!aiPanel.input.language.trim()) && ([2,3,5].indexOf(aiPanel.action) < 0 || !!app.selection)
            onClicked: aiPanel.prepare()
        }
        Label {
            text: aiPanel.status
            visible: text.length > 0
            wrapMode: Text.Wrap; textFormat: Text.PlainText; Layout.fillWidth: true
            color: app.colors.textSecondary; font.pixelSize: 11
            Accessible.role: Accessible.StaticText
        }
        Label {
            visible: aiPanel.previewReady
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            text: aiPanel.plan ? (aiPanel.plan.is_local ? qsTr("Local endpoint: %1").arg(aiPanel.plan.host) : qsTr("Remote endpoint: %1").arg(aiPanel.plan.host)) + "\n" + qsTr("%1 request(s), about %2 tokens").arg(aiPanel.plan.parts.length).arg(aiPanel.plan.estimated_tokens) : ""
            color: app.colors.infoFg; font.pixelSize: 11
        }
        RowLayout {
            visible: aiPanel.previewReady && !aiPanel.running
            Button { text: qsTr("Inspect Payload"); Layout.fillWidth: true; onClicked: payload.open() }
            Button {
                objectName: "sendAiRequest"
                text: qsTr("Send"); Layout.fillWidth: true
                enabled: aiPanel.owner.pendingCommands === 0
                onClicked: app.sendAi(aiPanel.owner, aiPanel.plan)
            }
        }
        Button {
            objectName: "cancelAiRequest"
            visible: aiPanel.running
            text: qsTr("Stop response"); Layout.fillWidth: true
            onClicked: aiPanel.owner.cancelAi()
        }
        RowLayout {
            LyraToolButton {
                symbol: "view"; text: qsTr("Inspect Payload")
                visible: !!aiPanel.plan && !!aiPanel.viewState.planSent
                onClicked: payload.open()
            }
            Button {
                objectName: "retryAiRequest"
                text: qsTr("Retry")
                enabled: !!aiPanel.plan && !aiPanel.running && aiPanel.owner.pendingCommands === 0
                onClicked: app.sendAi(aiPanel.owner, aiPanel.plan)
            }
            Button {
                objectName: "clearAiConversation"
                text: qsTr("Clear chat")
                visible: aiPanel.workspace === "chat"
                enabled: !aiPanel.running && (aiPanel.viewState.chatTurns || []).length > 0
                onClicked: aiPanel.owner.clearAiChat()
            }
        }
    }
    Dialog {
        id: payload
        title: aiPanel.viewState.planSent ? qsTr("Request payload") : qsTr("Request preview — nothing sent yet")
        modal: true
        width: Math.min(680, app.width - 60); height: Math.min(550, app.height - 60)
        parent: Overlay.overlay; anchors.centerIn: parent
        standardButtons: Dialog.Close
        ScrollView {
            anchors.fill: parent; contentWidth: availableWidth
            TextArea {
                objectName: "aiWirePayload"
                text: aiPanel.plan ? aiPanel.plan.parts.map(part => part.wire_body).join("\n\n") : ""
                readOnly: true; selectByMouse: true; wrapMode: TextEdit.WrapAnywhere; textFormat: TextEdit.PlainText; font.family: "monospace"
            }
        }
    }
}

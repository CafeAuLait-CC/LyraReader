import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: aiPanel
    objectName: "aiPanel"
    required property var app
    readonly property bool tabTransferDialogVisible: payload.visible || summaryCatalog.popupVisible
    readonly property var owner: app.currentReader
    readonly property var viewState: owner.aiState
    readonly property var input: viewState.input || ({})
    readonly property string workspace: input.view || "summary"
    readonly property int action: workspace === "chat" ? 4 : workspace === "translation" ? 3 : (input.summaryAction === undefined ? 1 : input.summaryAction)
    readonly property var summaryUnit: owner.summaryUnitContext
    readonly property bool unitMode: workspace === "summary" && !!summaryUnit.id
    readonly property var batchState: owner.summaryBatchState
    readonly property bool batchMode: workspace === "summary" && !!input.summaryBatch
    readonly property bool languageMode: unitMode || batchMode
    readonly property var languageGeneration: batchMode ? batchState.generation : summaryUnit.generation
    readonly property var ownerGeneration: owner.documentGeneration
    onOwnerChanged: if (payload && payload.visible) payload.close()
    onOwnerGenerationChanged: if (payload && payload.visible) payload.close()
    readonly property string workspaceTitle: workspace === "chat" ? qsTr("Document chat") : workspace === "translation" ? qsTr("Translation") : qsTr("Summary")
    readonly property var plan: viewState.previewView === workspace ? viewState.plan || null : null
    readonly property bool previewReady: !!plan && !viewState.planSent
    readonly property bool running: !!viewState.running
    readonly property bool compact: height < 500
    readonly property var result: viewState.responseView === workspace ? Object.assign({output: viewState.output, reasoning: viewState.reasoning, usage: viewState.usage, responsePlan: viewState.responsePlan, generation: owner.documentGeneration}, viewState.unitTitle === undefined ? {} : {unitTitle: viewState.unitTitle, unitLanguage: viewState.unitLanguage}) : ((viewState.results || {})[workspace] || {})
    readonly property string status: viewState.statusView === workspace ? viewState.status || "" : (((viewState.results || {})[workspace] || {}).status || "")
    padding: compact ? 6 : 10
    background: Rectangle { color: app.colors.sidebarBg }
    function baseRequest(requestAction) {
        const settings = app.aiSettings;
        return {
            action: requestAction,
            document_knowledge: false, document_knowledge_text: null, document_knowledge_pages: [],
            history: [], region: null, current_page: app.currentPage,
            selection: app.selection ? {page: app.selection.page, start: Math.min(app.selection.start, app.selection.end), end: Math.max(app.selection.start, app.selection.end)} : null,
            question: (requestAction === "AskSelection" || requestAction === "DocumentChat") ? input.question || null : null,
            language: requestAction === "TranslateSelection" ? (input.language === undefined ? "English" : input.language) : null,
            base_url: settings.baseUrl || "http://localhost:11434/v1", model: settings.model || "",
            temperature: null, max_tokens: null,
            reasoning_mode: settings.reasoningMode || "default", reasoning_encoding: settings.reasoningEncoding || "none"
        };
    }
    function prepareUnit(id) {
        owner.prepareSummaryUnit(id, baseRequest("SummarizeDocument"));
    }
    function prepareBatch(layer, offset, index) {
        owner.prepareSummaryBatch(layer, offset, baseRequest("SummarizeDocument"), owner.documentGeneration, index === undefined ? -1 : index);
    }
    function prepare() {
        if (batchMode) { prepareBatch(batchState.layer, batchState.offset); return; }
        if (unitMode) { prepareUnit(summaryUnit.id); return; }
        const modes = ["SummarizePage", "SummarizeDocument", "AskSelection", "TranslateSelection", "DocumentChat", "SummarizeSelection"];
        if(workspace==="translation" && input.inplace)owner.prepareInplaceTranslation(baseRequest("TranslateSelection"));
        else owner.prepareAi(baseRequest(modes[action]));
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
    Component {
        id: summaryLanguageComponent
        RowLayout {
            id: languageEditor
            objectName: "summaryLanguageEditor"
            property var targetReader: null
            property var expectedGeneration: 0
            function current() {
                return languageLoader.item === languageEditor && targetReader === aiPanel.owner
                    && targetReader && expectedGeneration === targetReader.documentGeneration
                    && aiPanel.languageMode && aiPanel.visible
                    && aiPanel.languageGeneration === expectedGeneration;
            }
            function commitDraft(value) {
                return current() && targetReader.setSummaryLanguageDraft(value, expectedGeneration);
            }
            function applyDraft() { return current() && targetReader.applySummaryLanguage(expectedGeneration); }
            Label { text: qsTr("Language"); color: app.colors.textSecondary }
            TextField {
                id: languageField
                objectName: "aiSummaryLanguage"
                Layout.fillWidth: true; Layout.minimumWidth: 40
                readonly property string modelText: !languageEditor.current() ? "" : (aiPanel.input.summaryLanguageDraft === undefined ? aiPanel.input.summaryLanguage || "" : aiPanel.input.summaryLanguageDraft)
                function syncModel() { if (text !== modelText) text = modelText; }
                onModelTextChanged: syncModel()
                Component.onCompleted: syncModel()
                placeholderText: qsTr("Document language")
                Accessible.name: qsTr("Summary language; empty uses document language")
                onTextEdited: languageEditor.commitDraft(text)
                onAccepted: languageEditor.applyDraft()
            }
            Button {
                objectName: "applySummaryLanguage"
                text: qsTr("Apply")
                enabled: languageEditor.current() && !aiPanel.running
                onClicked: languageEditor.applyDraft()
            }
        }
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: aiPanel.compact ? 3 : 6
        Label {
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            // Short unit drawers reserve space for the answer. Setup and receiving states remain visible.
            visible: !aiPanel.compact || !aiPanel.languageMode || aiPanel.running || !app.aiSettings.model
            text: aiPanel.running ? qsTr("Receiving: %1 · %2").arg(aiPanel.viewState.activeModel || "").arg(aiPanel.viewState.activeHost || "") : (app.aiSettings.model || qsTr("Choose an AI model in Settings"))
            color: app.colors.textSecondary; font.pixelSize: 11
        }
        RowLayout {
            Layout.fillWidth:true
            Button {objectName:"openDocumentReading";text:aiPanel.owner.documentReading.choice_pending ? qsTr("Read document (optional)…") : qsTr("Document Reading…");Layout.fillWidth:true;enabled:!aiPanel.owner.snapshotReadOnly;onClicked:app.openDocumentReading()}
            ToolButton {objectName:"skipDocumentReadingChoice";text:qsTr("Skip");visible:!!aiPanel.owner.documentReading.choice_pending;Accessible.name:qsTr("Continue without document reading");onClicked:aiPanel.owner.dismissDocumentReadingChoice()}
        }
        SummaryCatalog {
            id: summaryCatalog
            objectName: "summaryCatalog"
            app: aiPanel.app
            onPreviewUnit: function(id) { aiPanel.prepareUnit(id); }
            onCachedUnit: function(id) { aiPanel.owner.openCachedSummary(id, app.aiSettings.model || ""); }
            onPreviewBatch: function(reader, generation, layer, offset) {
                if (reader === aiPanel.owner && generation === reader.documentGeneration) aiPanel.prepareBatch(layer, offset);
            }
            visible: aiPanel.workspace === "summary"
            Layout.fillWidth: true
        }
        ComboBox {
            objectName: "aiSummaryTarget"
            visible: aiPanel.workspace === "summary" && !aiPanel.unitMode && !aiPanel.batchMode
            Layout.fillWidth: true
            model: [qsTr("Document"), qsTr("Selected text"), qsTr("This page"), qsTr("Question about selection")]
            currentIndex: [1, 5, 0, 2].indexOf(aiPanel.action)
            Accessible.name: qsTr("Summary target")
            onActivated: aiPanel.owner.setAiInput("action", [1, 5, 0, 2][currentIndex])
        }
        ColumnLayout {
            visible: aiPanel.unitMode
            Layout.fillWidth: true
            spacing: aiPanel.compact ? 3 : 5
            RowLayout {
                Layout.fillWidth: true
                Label {
                    objectName: "aiSummaryUnitTitle"
                    text: aiPanel.summaryUnit.title || (aiPanel.summaryUnit.unit || {}).title || ""
                    textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                    Layout.fillWidth: true; font.bold: true; color: app.colors.textPrimary
                    Accessible.description: text
                }
                ToolButton {
                    objectName: "clearSummaryUnit"
                    text: qsTr("Other summary targets")
                    enabled: !aiPanel.running
                    onClicked: aiPanel.owner.clearSummaryUnit()
                }
            }
            Label {
                objectName: "aiSummaryUnitCoverage"
                text: (aiPanel.summaryUnit.page_span || "") + (aiPanel.summaryUnit.note ? "\n" + aiPanel.summaryUnit.note : "")
                textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
                Accessible.description: text
                Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11
            }
        }
        RowLayout {
            visible: aiPanel.batchMode
            Layout.fillWidth: true
            Label { text: qsTr("Layer batch"); color: app.colors.textPrimary; font.bold: true; Layout.fillWidth: true }
            ToolButton { objectName: "clearSummaryBatch"; text: qsTr("Other summary targets"); enabled: !aiPanel.running; onClicked: aiPanel.owner.clearSummaryBatchView() }
        }
        Label {
            objectName: "summaryBatchLimits"
            readonly property var limits: aiPanel.batchState.limits || ({})
            visible: aiPanel.batchMode && limits.max_requests_per_batch > 0 && limits.max_concurrent_requests > 0
            Layout.fillWidth: true
            text: visible ? qsTr("Up to %1 requests per batch · %2 in flight").arg(limits.max_requests_per_batch).arg(limits.max_concurrent_requests) : ""
            textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 2
            font.pixelSize: 11; color: app.colors.textSecondary
            Accessible.description: aiPanel.batchState.note || ""
            HoverHandler { id: batchLimitsHover }
            ToolTip.visible: batchLimitsHover.hovered && !!aiPanel.batchState.note
            ToolTip.text: aiPanel.batchState.note || ""
        }
        Loader {
                id: languageLoader
                Layout.fillWidth: true
                active: aiPanel.languageMode && aiPanel.visible
                sourceComponent: summaryLanguageComponent
                property var contextOwner: aiPanel.owner
                property var contextGeneration: aiPanel.owner.documentGeneration
                function recreate() { sourceComponent = null; sourceComponent = summaryLanguageComponent; }
                onContextOwnerChanged: recreate()
                onContextGenerationChanged: recreate()
                onLoaded: { item.targetReader = aiPanel.owner; item.expectedGeneration = aiPanel.owner.documentGeneration; }
            }
        CheckBox {
            objectName: "inplaceTranslationMode"
            visible: aiPanel.workspace === "translation"
            text: qsTr("Show translation in place")
            checked: !!aiPanel.input.inplace
            enabled: !aiPanel.running
            onToggled: aiPanel.owner.setAiInput("inplace",checked)
        }
        Label {
            visible: aiPanel.workspace === "translation" && !!aiPanel.input.inplace
            text: qsTr("One request per complete paragraph. Preview before sending. Saved translations and showing the original use no network. Long answers use a bounded page preview; ⋯ retains the full text.")
            wrapMode:Text.Wrap;textFormat:Text.PlainText;Layout.fillWidth:true
            color:app.colors.textSecondary;font.pixelSize:11
        }
        Label {
            visible: aiPanel.workspace === "translation" && !!text
            text: aiPanel.owner.translationState.cache_warning || ""
            wrapMode:Text.Wrap;textFormat:Text.PlainText;Layout.fillWidth:true
            color:app.colors.textSecondary;font.pixelSize:11
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
            id: responseScroll
            objectName: "aiResponseScroll"
            visible: aiPanel.workspace !== "chat" && !aiPanel.batchMode
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 24
            contentWidth: availableWidth
            AiResult {
                width: parent.width
                app: aiPanel.app; value: aiPanel.result; viewport: responseScroll.contentItem
                onCitation: function(link, responsePlan) { aiPanel.followHistoryLink(link, responsePlan); }
            }
        }
        SummaryBatchResults {
            app: aiPanel.app; owner: aiPanel.owner
            visible: aiPanel.batchMode
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 50
            onPreviewRow: function(reader, generation, layer, index) {
                if (reader === aiPanel.owner && generation === reader.documentGeneration) aiPanel.prepareBatch(layer, aiPanel.batchState.offset, index);
            }
            onCitation: function(reader, generation, link, proof) {
                if (reader === aiPanel.owner && generation === reader.documentGeneration) aiPanel.followHistoryLink(link, proof);
            }
        }
        Label {
            visible: aiPanel.batchMode
            text: qsTr("Completed summaries are saved locally when possible. Cache warnings appear on each row; partial results remain temporary.")
            textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
            Accessible.description: text
            Layout.fillWidth: true; font.pixelSize: 11; color: app.colors.textSecondary
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
            visible: (!aiPanel.unitMode && !aiPanel.batchMode && aiPanel.action === 2) || aiPanel.workspace === "chat"
            Layout.fillWidth: true; Layout.preferredHeight: 64; Layout.maximumHeight: 64
            contentWidth: availableWidth
            clip: true
            TextArea {
                id: question
                objectName: "aiQuestion"
                width: composerScroll.availableWidth
                readonly property string modelText: aiPanel.input.question || ""
                property bool applyingModel: false
                function syncModelText() {
                    if(text===modelText)return;
                    applyingModel=true;
                    text=modelText;
                    applyingModel=false;
                }
                onModelTextChanged:syncModelText()
                Component.onCompleted:syncModelText()
                textFormat: TextEdit.PlainText; wrapMode: TextEdit.Wrap
                placeholderText: aiPanel.workspace === "chat" ? qsTr("Ask about this document…") : qsTr("Question about selected text…")
                Accessible.name: aiPanel.workspace === "chat" ? qsTr("Question about document") : qsTr("Question about selection")
                // TextEdit can normalize displayed line separators. Only real edits
                // may replace the model's original text or invalidate its preview.
                onTextChanged: if (activeFocus && !applyingModel) aiPanel.owner.setAiInput("question", text)
                Keys.onPressed: function(event) {
                    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier) && preview.enabled) { aiPanel.prepare(); event.accepted = true; }
                }
            }
        }
        Button {
            id: preview
            objectName: "prepareAiRequest"
            text: aiPanel.batchMode ? qsTr("Preview batch") : aiPanel.workspace === "chat" ? qsTr("Preview Question") : aiPanel.workspace === "translation" ? qsTr("Preview Translation") : (!aiPanel.unitMode && !aiPanel.batchMode && aiPanel.action === 2) ? qsTr("Preview Question") : qsTr("Preview Summary")
            Layout.fillWidth: true
            enabled: !aiPanel.running && aiPanel.owner.pageCount > 0 && aiPanel.owner.pendingCommands === 0 && (aiPanel.batchMode || aiPanel.unitMode || ((aiPanel.action !== 2 && aiPanel.action !== 4) || !!question.text.trim()) && (aiPanel.action !== 3 || aiPanel.input.language === undefined || !!aiPanel.input.language.trim()) && ([2,3,5].indexOf(aiPanel.action) < 0 || !!app.selection))
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
            objectName: "summaryCacheWarning"
            text: qsTr("Summary cache: %1").arg(aiPanel.viewState.cacheWarning || "")
            visible: aiPanel.workspace === "summary" && !!aiPanel.viewState.cacheWarning
            textFormat: Text.PlainText; wrapMode: Text.Wrap
            Layout.fillWidth: true; color: app.colors.textSecondary
            Accessible.description: text
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
            text: aiPanel.viewState.responseView === "summary_batch" ? qsTr("Stop batch") : qsTr("Stop response"); Layout.fillWidth: true
            onClicked: aiPanel.owner.cancelAi()
        }
        Flow {
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: 4
            LyraToolButton {
                symbol: "view"; text: qsTr("Inspect Payload")
                visible: !!aiPanel.plan && !!aiPanel.viewState.planSent
                onClicked: payload.open()
            }
            Button {
                objectName: "retryAiRequest"
                visible: !aiPanel.batchMode
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
            Button {objectName:"aiAuditTrail";text:qsTr("Local audit trail…");onClicked:app.showAuditTrail()}
        }
    }
    Dialog {
        id: payload
        objectName: "aiPayloadDialog"
        title: aiPanel.viewState.planSent ? qsTr("Request payload") : qsTr("Request preview — nothing sent yet")
        modal: true
        width: Math.min(680, app.width - 60); height: Math.min(550, app.height - 60)
        parent: Overlay.overlay; anchors.centerIn: parent
        standardButtons: Dialog.Close
        ColumnLayout {
            anchors.fill: parent
            ComboBox {
                id: payloadRow
                objectName: "summaryBatchPayloadRow"
                visible: !!aiPanel.plan && ["summary_batch","inplace_translation"].indexOf(aiPanel.plan.kind)>=0
                Layout.fillWidth: true
                model: aiPanel.plan ? aiPanel.plan.summary_rows || aiPanel.plan.translation_rows || [] : []
                textRole: "title"
                onModelChanged: currentIndex = 0
                Accessible.name: qsTr("Request in this batch")
            }
            ScrollView {
                Layout.fillWidth: true; Layout.fillHeight: true; contentWidth: availableWidth
                TextArea {
                    objectName: "aiWirePayload"
                    text: {
                        const plan = aiPanel.plan;
                        if (!plan) return "";
                        if (["summary_batch","inplace_translation"].indexOf(plan.kind)<0) return plan.parts.map(part => part.wire_body).join("\n\n");
                        const row = (plan.summary_rows || plan.translation_rows || [])[payloadRow.currentIndex];
                        return row && plan.parts[row.part_index] ? plan.parts[row.part_index].wire_body : "";
                    }
                    readOnly: true; selectByMouse: true; wrapMode: TextEdit.WrapAnywhere; textFormat: TextEdit.PlainText; font.family: "monospace"
                }
            }
        }
    }
}

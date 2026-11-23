import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: aiPanel
    objectName: "aiPanel"
    required property var app
    readonly property bool tabTransferDialogVisible: payload.visible || summaryCatalog.popupVisible || selectionSource.visible || translationHistory.visible || chatHistory.visible || readingNotes.visible
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
    readonly property bool selectedSummary: workspace === "summary" && action === 5 && !unitMode && !batchMode
    readonly property bool wholeSummary: workspace === "summary" && action === 1 && !unitMode && !batchMode
    readonly property bool translateDocument: workspace === "translation" && input.translationScope === "document"
    readonly property bool translateInPlace: workspace === "translation" && !translateDocument && !!input.inplace
    readonly property string summaryDetail: input.summaryDetail || "Standard"
    readonly property var preparedRange: plan && (selectedSummary || plan.kind === "reading_translation")
                                         ? viewState.previewSelection || null : null
    readonly property var selectedSources: preparedRange ? plan.sources || [] : []
    readonly property var liveRange: visible && (selectedSummary || (workspace === "translation" && !translateDocument)) && app.selection
                                     ? sortedRange(app.selection) : null
    readonly property var currentExcerpt: liveExcerpt && liveExcerpt.owner === owner
                                          && liveExcerpt.generation === ownerGeneration
                                          && sameRange(liveExcerpt.range, liveRange) ? liveExcerpt : null
    property var liveExcerpt: null
    property var pendingLocate: null
    onLiveRangeChanged: {
        if (selectionSource && selectionSource.snapshot && !selectionSource.snapshot.prepared) selectionSource.close();
        if (pendingLocate && !pendingLocate.prepared) pendingLocate = null;
        if (liveRange) refreshSelection.restart();
        else { refreshSelection.stop(); liveExcerpt = null; }
    }
    onPlanChanged: {
        if (selectionSource && selectionSource.snapshot && selectionSource.snapshot.prepared) selectionSource.close();
        if (pendingLocate && pendingLocate.prepared) pendingLocate = null;
    }
    onVisibleChanged: if (!visible) {
        if (selectionSource) selectionSource.close();
        if (translationHistory) translationHistory.close();
        if (chatHistory) chatHistory.close();
        if (readingNotes) readingNotes.close();
        pendingLocate = null;
    }
    readonly property var languageGeneration: batchMode ? batchState.generation : summaryUnit.generation
    readonly property var ownerGeneration: owner.documentGeneration
    onOwnerChanged: resetSourceView()
    onOwnerGenerationChanged: resetSourceView()
    readonly property string workspaceTitle: workspace === "chat" ? qsTr("Document chat") : workspace === "translation" ? qsTr("Translation") : qsTr("Summary")
    readonly property var plan: viewState.previewView === workspace ? viewState.plan || null : null
    readonly property bool previewReady: !!plan && !viewState.planSent
    readonly property bool synthesisPreview: previewReady && plan.kind === "summary_synthesis"
    readonly property bool running: !!viewState.running
    readonly property bool compact: height < 500
    readonly property var result: viewState.responseView === workspace ? Object.assign({output: viewState.output, reasoning: viewState.reasoning, usage: viewState.usage, responsePlan: viewState.responsePlan, generation: owner.documentGeneration, translationBlocks: viewState.translationBlocks, translationWarning: viewState.translationWarning, translationHistoryWarning: viewState.translationHistoryWarning, synthesisParts: viewState.synthesisParts, summaryNoteSource: viewState.summaryNoteSource}, viewState.unitTitle === undefined ? {} : {unitTitle: viewState.unitTitle, unitLanguage: viewState.unitLanguage}) : ((viewState.results || {})[workspace] || {})
    readonly property var pairedTranslation: workspace === "translation" && result.responsePlan
                                             && result.responsePlan.kind === "reading_translation"
                                             ? result.translationBlocks || [] : []
    readonly property string status: viewState.statusView === workspace ? viewState.status || "" : (((viewState.results || {})[workspace] || {}).status || "")
    padding: compact ? 6 : 10
    background: Rectangle { color: app.colors.sidebarBg }
    function openSavedNote(id) { readingNotes.browse("", id); }
    function sortedRange(range) {
        return {page: range.page, start: Math.min(range.start, range.end), end: Math.max(range.start, range.end)};
    }
    function sameRange(a, b) {
        return !!a && !!b && a.page === b.page && a.start === b.start && a.end === b.end;
    }
    function resetSourceView() {
        if (payload && payload.visible) payload.close();
        if (selectionSource && selectionSource.visible) selectionSource.close();
        if (translationHistory && translationHistory.visible) translationHistory.close();
        if (chatHistory && chatHistory.visible) chatHistory.close();
        if (readingNotes && readingNotes.visible) readingNotes.close();
        liveExcerpt = null;
        pendingLocate = null;
        if (liveRange) refreshSelection.restart();
    }
    Timer {
        id: refreshSelection
        interval: 85
        onTriggered: {
            const range = aiPanel.liveRange;
            if (!range) return;
            // A drag may cover a whole dense page. Keep the live excerpt bounded
            // and leave the complete request to the explicit preview builder.
            const end = Math.min(range.end, range.start + 2047);
            const excerpt = app.selectedTextResult({page: range.page, start: range.start, end: end});
            aiPanel.liveExcerpt = excerpt.error === undefined ? {owner: aiPanel.owner,
                generation: aiPanel.ownerGeneration, range: range, text: excerpt.text, partial: end < range.end} : null;
        }
    }
    function locate(range, prepared) {
        if (!visible || !range) return;
        const ticket = {owner: owner, generation: ownerGeneration, range: range, prepared: prepared};
        if (owner.textPages[range.page.toString()]) {
            if (!app.revealSelectionSource(owner, ownerGeneration, range))
                app.operationStatus = qsTr("This selection could not be located.");
            return;
        }
        pendingLocate = ticket;
        owner.requestText(range.page);
    }
    Connections {
        target: aiPanel.liveRange || aiPanel.pendingLocate ? aiPanel.owner : null
        function onTextPagesChanged() {
            if (aiPanel.liveRange && !aiPanel.currentExcerpt) refreshSelection.restart();
            const ticket = aiPanel.pendingLocate;
            if (!ticket || !ticket.owner.textPages[ticket.range.page.toString()]) return;
            aiPanel.pendingLocate = null;
            if (aiPanel.visible && ticket.owner === aiPanel.owner && ticket.generation === aiPanel.ownerGeneration
                    && aiPanel.sameRange(ticket.range, ticket.prepared ? aiPanel.preparedRange : aiPanel.liveRange))
                aiPanel.locate(ticket.range, ticket.prepared);
        }
    }
    component SelectionCard: ColumnLayout {
        id: card
        required property string title
        required property string text
        required property var range
        required property bool prepared
        required property string labelName
        spacing: 2
        Layout.fillWidth: true
        Label {
            text: card.title; color: app.colors.textSecondary; font.pixelSize: 11
            Layout.fillWidth: true
        }
        RowLayout {
            Layout.fillWidth: true
            Label {
                id: excerptLabel
                objectName: card.labelName
                Layout.fillWidth: true; Layout.minimumWidth: 0
                textFormat: Text.PlainText; wrapMode: Text.Wrap
                maximumLineCount: 2; elide: Text.ElideRight
                text: card.text
                color: app.colors.textSecondary; font.pixelSize: 13
                Accessible.name: card.title
            }
            ToolButton {
                objectName: card.labelName + "More"
                visible: !!card.range && excerptLabel.truncated
                text: qsTr("More")
                Accessible.name: qsTr("Show %1").arg(card.title)
                onClicked: {
                    selectionSource.snapshot = {prepared: card.prepared, page: card.range.page, title: card.title, text: card.text};
                    selectionSource.open();
                }
            }
            ToolButton {
                objectName: card.labelName + "Locate"
                text: qsTr("Locate")
                enabled: !!card.range
                Accessible.name: qsTr("Locate %1 in document").arg(card.title)
                onClicked: aiPanel.locate(card.range, card.prepared)
            }
        }
    }
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
    function connectChatGpt(request, accounts, enabled) {
        if (!enabled) return true;
        if (!accounts.connected || !accounts.model) {
            app.operationStatus = qsTr("Sign in and choose a ChatGPT model in Settings.");
            return false;
        }
        request.chatgpt_account = accounts.accountId;
        request.base_url = "https://api.openai.com/v1";
        request.model = accounts.model;
        request.reasoning_mode = "default";
        request.reasoning_encoding = "none";
        return true;
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
        const accounts = app.session ? app.session.chatGptAccounts : null;
        if (workspace === "translation") {
            const request = baseRequest("TranslateSelection");
            if (translateDocument) {
                request.action = "SummarizeDocument";
                request.selection = null;
            } else if (accounts && !connectChatGpt(request, accounts, accounts.useForSelection)) return;
            if (translateInPlace) { owner.prepareInplaceTranslation(request); return; }
            owner.prepareAi(request, {}, {kind: "translation", detail: "Standard"});
        }
        else if (selectedSummary || wholeSummary) {
            const request = baseRequest(modes[action]);
            if (wholeSummary) request.selection = null;
            if (selectedSummary && accounts && !connectChatGpt(request, accounts, accounts.useForSelection)) return;
            request.language = input.summaryLanguage || null;
            owner.prepareAi(request, {}, {kind: "summary", detail: summaryDetail,
                force: wholeSummary && !!viewState.cachedWholeSummary});
        }
        else {
            const request = baseRequest(modes[action]);
            if (request.action === "DocumentChat" && accounts && !connectChatGpt(request, accounts, accounts.useForChat)) return;
            owner.prepareAi(request);
        }
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
        ComboBox {
            objectName: "aiSelectedSummaryDetail"
            visible: aiPanel.selectedSummary || aiPanel.wholeSummary
            Layout.fillWidth: true
            model: [qsTr("Brief"), qsTr("Standard"), qsTr("Detailed")]
            readonly property var values: ["Brief", "Standard", "Detailed"]
            currentIndex: values.indexOf(aiPanel.summaryDetail)
            Accessible.name: qsTr("Summary detail")
            onActivated: aiPanel.owner.setAiInput("summaryDetail", values[currentIndex])
        }
        SelectionCard {
            visible: !!aiPanel.currentExcerpt && !!text && !aiPanel.sameRange(range, aiPanel.preparedRange)
            range: aiPanel.liveRange
            prepared: false
            title: aiPanel.currentExcerpt && aiPanel.currentExcerpt.partial ? qsTr("Start of selection") : qsTr("Current selection")
            text: aiPanel.currentExcerpt ? aiPanel.currentExcerpt.text : ""
            labelName: "aiLiveSelection"
        }
        SelectionCard {
            visible: aiPanel.selectedSources.length > 0
            range: aiPanel.preparedRange
            prepared: true
            title: qsTr("Previewed source")
            text: aiPanel.selectedSources.map(source => source.snippet).join("")
            labelName: aiPanel.workspace === "translation" ? "aiSelectedTranslationSource" : "aiSelectedSummarySource"
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
        ComboBox {
            objectName: "aiTranslationScope"
            visible: aiPanel.workspace === "translation"
            enabled: !aiPanel.running
            Layout.fillWidth: true
            model: [qsTr("Selected text"), qsTr("Document")]
            currentIndex: aiPanel.translateDocument ? 1 : 0
            Accessible.name: qsTr("Translation scope")
            onActivated: aiPanel.owner.setAiInput("translationScope", currentIndex === 1 ? "document" : "selection")
        }
        CheckBox {
            objectName: "inplaceTranslationMode"
            visible: aiPanel.workspace === "translation" && !aiPanel.translateDocument
            text: qsTr("Show translation in place")
            checked: !!aiPanel.input.inplace
            enabled: !aiPanel.running
            onToggled: aiPanel.owner.setAiInput("inplace",checked)
        }
        Label {
            visible: aiPanel.translateInPlace
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
        Button {
            objectName: "openAiTranslationHistory"
            visible: aiPanel.workspace === "translation" && !aiPanel.translateInPlace
            enabled: aiPanel.owner.pageCount > 0 && !aiPanel.running && aiPanel.owner.pendingCommands === 0
            text: qsTr("Translation history…")
            onClicked: translationHistory.browse()
        }
        Label {
            visible: aiPanel.workspace === "translation" && !!aiPanel.result.translationHistoryWarning
            text: visible ? qsTr("Could not save the translation to history. %1").arg(aiPanel.result.translationHistoryWarning) : ""
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            color: app.colors.textSecondary
        }
        RowLayout {
            visible: aiPanel.pairedTranslation.length > 0
            Layout.fillWidth: true
            Button {
                text: qsTr("Copy translation")
                onClicked: if (app.session) app.session.copyText(aiPanel.pairedTranslation.map(block => block.translation).join("\n\n"))
            }
            CheckBox {
                id: rawTranslation
                text: qsTr("Response details")
                checked: false
                onVisibleChanged: if (!visible) checked = false
            }
        }
        Label {
            visible: aiPanel.workspace === "translation" && !!aiPanel.result.translationWarning
            text: visible ? aiPanel.result.translationWarning : ""
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            color: app.colors.textSecondary
        }
        ListView {
            id: paragraphList
            objectName: "aiPairedTranslation"
            visible: aiPanel.pairedTranslation.length > 0 && !rawTranslation.checked
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 24
            model: aiPanel.pairedTranslation
            clip: true; spacing: 8
            ScrollBar.vertical: AiReadingScrollBar { id: translationBar }
            delegate: ColumnLayout {
                id: paragraph
                required property var modelData
                x: paragraphList.LayoutMirroring.enabled ? translationBar.gutterWidth : 0
                width: Math.max(0, paragraphList.width - translationBar.gutterWidth)
                spacing: 3
                Label {
                    text: qsTr("Page %1").arg(paragraph.modelData.page)
                    color: app.colors.textSecondary; font.pixelSize: 11
                }
                Label {
                    text: paragraph.modelData.original; textFormat: Text.PlainText; wrapMode: Text.Wrap
                    color: app.colors.textSecondary; Layout.fillWidth: true
                }
                Label {
                    text: paragraph.modelData.translation; textFormat: Text.PlainText; wrapMode: Text.Wrap
                    color: app.colors.textPrimary; Layout.fillWidth: true
                }
                Rectangle { color: app.colors.separator; Layout.fillWidth: true; height: 1 }
            }
        }
        AiReadingScrollView {
            id: responseScroll
            objectName: "aiResponseScroll"
            visible: aiPanel.workspace !== "chat" && !aiPanel.batchMode
                     && (!aiPanel.pairedTranslation.length || rawTranslation.checked)
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 24
            ColumnLayout {
                width: responseScroll.availableWidth
                AiResult {
                    Layout.fillWidth: true
                    app: aiPanel.app; value: aiPanel.result; viewport: responseScroll.contentItem
                    onCitation: function(link, responsePlan) { aiPanel.followHistoryLink(link, responsePlan); }
                }
                ToolButton {
                    id: showPartSummaries
                    objectName: "aiShowPartSummaries"
                    visible: aiPanel.workspace === "summary" && !!aiPanel.result.synthesisParts
                    text: checked ? qsTr("Hide part summaries") : qsTr("Show part summaries")
                    checkable: true
                    onVisibleChanged: if (!visible) checked = false
                }
                Loader {
                    Layout.fillWidth: true
                    active: showPartSummaries.visible && showPartSummaries.checked
                    visible: active
                    sourceComponent: AiResult {
                        app: aiPanel.app
                        value: aiPanel.result.synthesisParts || ({})
                        answerName: "aiPartSummaryText"
                        viewport: responseScroll.contentItem
                        onCitation: function(link, responsePlan) { aiPanel.followHistoryLink(link, responsePlan); }
                    }
                }
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
            onKeepNote: function(source) { readingNotes.browse(source); }
        }
        Label {
            visible: aiPanel.workspace === "chat" && !!aiPanel.viewState.conversationLimited
            text: qsTr("Older exchanges were removed to keep the conversation within its display budget.")
            textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11
        }
        Label {
            visible: aiPanel.workspace === "chat" && !!aiPanel.viewState.chatHistoryWarning
            text: visible ? qsTr("Could not save this exchange locally. %1").arg(aiPanel.viewState.chatHistoryWarning) : ""
            textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true
            color: app.colors.textSecondary
        }
        ColumnLayout {
            id: draftWarning
            visible: aiPanel.workspace === "chat" && !!aiPanel.viewState.chatDraftWarning
            Layout.fillWidth: true
            Label {
                text: draftWarning.visible ? qsTr("The draft is still in this tab. %1").arg(aiPanel.viewState.chatDraftWarning) : ""
                textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true
                color: app.colors.textSecondary
            }
            Flow {
                Layout.fillWidth: true
                spacing: 4
                Button {
                    text: qsTr("Retry saving draft")
                    enabled: aiPanel.owner.chatDraftPending && !aiPanel.owner.chatDraftSaving
                    onClicked: aiPanel.owner.flushAiChatDraft()
                }
                Button {
                    text: qsTr("Discard unsaved changes to draft")
                    enabled: aiPanel.owner.chatDraftPending && !aiPanel.owner.chatDraftSaving
                    onClicked: aiPanel.owner.discardAiChatDraft()
                }
            }
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
                readOnly: aiPanel.workspace === "chat" && (!!aiPanel.viewState.chatReadOnly || aiPanel.owner.documentRevisionPending)
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
            text: aiPanel.batchMode ? qsTr("Preview batch") : aiPanel.workspace === "chat" ? qsTr("Preview Question") : aiPanel.workspace === "translation" ? qsTr("Preview Translation") : (!aiPanel.unitMode && !aiPanel.batchMode && aiPanel.action === 2) ? qsTr("Preview Question") : aiPanel.wholeSummary && aiPanel.viewState.cachedWholeSummary ? qsTr("Preview fresh summary") : qsTr("Preview Summary")
            Layout.fillWidth: true
            enabled: !aiPanel.running && (aiPanel.workspace !== "chat" || !aiPanel.viewState.chatReadOnly)
                     && aiPanel.owner.pageCount > 0 && aiPanel.owner.pendingCommands === 0 && (aiPanel.batchMode || aiPanel.unitMode || ((aiPanel.action !== 2 && aiPanel.action !== 4) || !!question.text.trim()) && (aiPanel.action !== 3 || aiPanel.input.language === undefined || !!aiPanel.input.language.trim()) && ([2,3,5].indexOf(aiPanel.action) < 0 || aiPanel.translateDocument || !!app.selection))
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
            text: {
                const plan = aiPanel.plan;
                if (!plan) return "";
                const connection = plan.chatgpt_account ? qsTr("ChatGPT plan: %1 (%2)").arg(plan.model).arg(plan.host)
                    : (plan.is_local ? qsTr("Local endpoint: %1") : qsTr("Remote endpoint: %1")).arg(plan.host);
                return connection + "\n" + qsTr("%1 request(s), about %2 tokens").arg(plan.parts.length).arg(plan.estimated_tokens);
            }
            color: app.colors.infoFg; font.pixelSize: 11
        }
        RowLayout {
            visible: aiPanel.previewReady && !aiPanel.running
            Button { text: qsTr("Inspect Payload"); Layout.fillWidth: true; onClicked: payload.open() }
            Button {
                objectName: "sendAiRequest"
                text: aiPanel.synthesisPreview ? qsTr("Send synthesis") : qsTr("Send"); Layout.fillWidth: true
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
                visible: !aiPanel.batchMode && !aiPanel.synthesisPreview
                text: qsTr("Retry")
                enabled: !!aiPanel.plan && !aiPanel.running && aiPanel.owner.pendingCommands === 0
                onClicked: app.sendAi(aiPanel.owner, aiPanel.plan)
            }
            Button {
                objectName: "clearAiConversation"
                text: qsTr("New chat")
                visible: aiPanel.workspace === "chat"
                enabled: !aiPanel.running && (!!aiPanel.viewState.chatSession || !!aiPanel.input.chatQuestion)
                onClicked: aiPanel.owner.newAiChat()
            }
            Button {
                objectName: "openAiChatHistory"
                text: qsTr("Past chats…")
                visible: aiPanel.workspace === "chat"
                enabled: !aiPanel.running && aiPanel.owner.pageCount > 0 && aiPanel.owner.pendingCommands === 0
                onClicked: chatHistory.browse()
            }
            Button {objectName:"aiAuditTrail";text:qsTr("Local audit trail…");onClicked:app.showAuditTrail()}
            Button {
                objectName: "keepAiSummaryNote"
                text: qsTr("Keep as note")
                visible: aiPanel.workspace === "summary" && !!aiPanel.result.summaryNoteSource
                enabled: !aiPanel.running && aiPanel.owner.pendingCommands === 0 && !aiPanel.owner.readingNoteDraft.id
                onClicked: readingNotes.browse(aiPanel.result.summaryNoteSource)
            }
            Button {
                objectName: "browseAiReadingNotes"
                text: qsTr("Reading notes…")
                enabled: aiPanel.owner.pageCount > 0 && aiPanel.owner.pendingCommands === 0
                onClicked: readingNotes.browse("")
            }
        }
    }
    AiReadingNotes {
        id: readingNotes
        app: aiPanel.app
        onRequestUpdate: function(noteId) {
            const request = aiPanel.baseRequest("SummarizeDocument");
            request.language = aiPanel.input.summaryLanguage || null;
            aiPanel.owner.prepareAi(request, {}, {kind: "note", detail: "Standard", id: noteId});
        }
    }
    Dialog {
        id: chatHistory
        objectName: "aiChatHistory"
        property var reader: null
        property double generation: 0
        property double command: 0
        property var sessions: []
        property string error: ""
        title: qsTr("Past chats for this PDF")
        modal: true
        anchors.centerIn: Overlay.overlay
        width: Math.max(230, Math.min(460, app.width - 48))
        standardButtons: Dialog.Cancel
        function current() { return reader && reader === aiPanel.owner && generation === aiPanel.ownerGeneration; }
        function browse() {
            reader = aiPanel.owner;
            generation = aiPanel.ownerGeneration;
            open();
            command = reader.submit("ai_chat_sessions", {});
        }
        onClosed: { reader = null; command = 0; sessions = []; error = ""; }
        Connections {
            target: chatHistory.reader
            function onCommandFinished(id, operation, result, error) {
                if (!chatHistory.current() || id !== chatHistory.command || operation !== "ai_chat_sessions") return;
                chatHistory.command = 0;
                chatHistory.error = error;
                if (!error) chatHistory.sessions = result;
            }
        }
        contentItem: ColumnLayout {
            ComboBox {
                id: savedChat
                objectName: "aiSavedChatChoice"
                Layout.fillWidth: true
                model: chatHistory.sessions
                textRole: "title"
                enabled: count > 0
                Accessible.name: qsTr("Saved chats")
            }
            Label {
                text: chatHistory.error || (chatHistory.command ? qsTr("Loading chats…") : !savedChat.count ? qsTr("No saved chats.") : "")
                visible: !!text
                Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap
            }
            Button {
                objectName: "restoreAiChat"
                text: qsTr("Open chat")
                enabled: chatHistory.current() && savedChat.currentIndex >= 0 && !chatHistory.command
                         && aiPanel.owner.pendingCommands === 0 && !aiPanel.running
                onClicked: {
                    if (chatHistory.reader.reopenAiChat(chatHistory.sessions[savedChat.currentIndex].id))
                        chatHistory.close();
                }
            }
        }
    }
    Dialog {
        id: translationHistory
        objectName: "aiTranslationHistory"
        property var reader: null
        property double generation: 0
        property double command: 0
        property var entries: []
        property var entry: null
        property string error: ""
        title: aiPanel.translateDocument ? qsTr("Document translation history") : qsTr("Selection translation history")
        modal: true
        anchors.centerIn: Overlay.overlay
        width: Math.max(230, Math.min(620, app.width - 48))
        height: Math.max(220, Math.min(520, app.height - 64))
        standardButtons: Dialog.Close
        function current() { return reader && reader === aiPanel.owner && generation === aiPanel.ownerGeneration; }
        function browse() {
            reader = aiPanel.owner;
            generation = aiPanel.ownerGeneration;
            translationHistory.open();
            command = reader.submit("ai_translation_history", {selection: !aiPanel.translateDocument});
        }
        function openEntry(index) {
            if (!current() || index < 0 || index >= entries.length) return;
            entry = null; error = "";
            command = reader.submit("ai_translation_history_entry", {id: entries[index].id});
        }
        onClosed: { reader = null; command = 0; entries = []; entry = null; error = ""; }
        Connections {
            target: translationHistory.reader
            function onCommandFinished(id, operation, result, error) {
                if (id !== translationHistory.command || !translationHistory.current()) return;
                translationHistory.command = 0;
                translationHistory.error = error;
                if (error) return;
                if (operation === "ai_translation_history") {
                    translationHistory.entries = result;
                    if (result.length) translationHistory.openEntry(0);
                } else if (operation === "ai_translation_history_entry") {
                    translationHistory.entry = result;
                }
            }
        }
        contentItem: ColumnLayout {
            ComboBox {
                objectName: "aiTranslationHistoryEntry"
                Layout.fillWidth: true
                model: translationHistory.entries
                textRole: "excerpt"
                enabled: count > 0 && !translationHistory.command
                Accessible.name: qsTr("Saved translations")
                delegate: ItemDelegate {
                    required property var modelData
                    width: ListView.view.width
                    text: modelData.excerpt || modelData.language
                    Accessible.description: new Date(modelData.modified).toLocaleString()
                }
                onActivated: translationHistory.openEntry(currentIndex)
            }
            Label {
                Layout.fillWidth: true
                visible: !!text
                text: translationHistory.error || (translationHistory.command ? qsTr("Loading history…") :
                      !translationHistory.entries.length ? qsTr("No saved translations for this source type.") :
                      !translationHistory.entry ? "" :
                      translationHistory.entry.status === "sourceChanged" ? qsTr("This translation belongs to an earlier PDF revision.") :
                      translationHistory.entry.status === "partial" ? qsTr("Incomplete translation. The received text was kept.") :
                      translationHistory.entry.warning || "")
                wrapMode: Text.Wrap; textFormat: Text.PlainText
            }
            AiReadingScrollView {
                id: savedTranslationScroll
                Layout.fillWidth: true; Layout.fillHeight: true
                TextArea {
                    objectName: "aiSavedTranslationText"
                    width: savedTranslationScroll.availableWidth
                    text: {
                        const entry = translationHistory.entry;
                        if (!entry) return "";
                        return entry.blocks && entry.blocks.length
                                ? entry.blocks.map(block => block.original + "\n" + block.translation).join("\n\n")
                                : entry.content;
                    }
                    readOnly: true; selectByMouse: true; selectByKeyboard: true
                    wrapMode: Text.Wrap; textFormat: Text.PlainText
                }
            }
            Button {
                objectName: "previewSavedAiTranslation"
                text: qsTr("Preview retranslation")
                enabled: translationHistory.current() && !translationHistory.command && !!translationHistory.entry
                         && translationHistory.entry.can_replay && !aiPanel.running && aiPanel.owner.pendingCommands === 0
                onClicked: {
                    const id = translationHistory.entry.id;
                    aiPanel.owner.prepareAi(aiPanel.baseRequest("TranslateSelection"), {}, {
                        kind: "translation", detail: "Standard", saved_translation: id
                    });
                    translationHistory.close();
                }
            }
        }
    }
    Dialog {
        id: selectionSource
        objectName: "aiSelectedSummarySourceDialog"
        property var snapshot: null
        title: snapshot ? qsTr("%1 · page %2").arg(snapshot.title).arg(snapshot.page + 1) : ""
        onClosed: snapshot = null
        modal: true
        anchors.centerIn: Overlay.overlay
        width: Math.max(220, Math.min(560, app.width - 48))
        height: Math.max(180, Math.min(360, app.height - 64))
        standardButtons: Dialog.Close
        contentItem: ScrollView {
            id: sourceScroll
            contentWidth: availableWidth
            TextArea {
                width: sourceScroll.availableWidth
                text: selectionSource.snapshot ? selectionSource.snapshot.text : ""
                textFormat: TextEdit.PlainText; wrapMode: TextEdit.Wrap
                readOnly: true; selectByMouse: true; selectByKeyboard: true
            }
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

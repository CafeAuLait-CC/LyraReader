import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

AiReadingScrollView {
    id: task
    memoryReader: task.owner
    memoryKey: "summary"
    memoryReady: scopedStore.current() && scopedStore.loaded && !scopedStore.loading
    objectName: "aiSummaryTaskScroll"
    contentHeight: taskBody.implicitHeight + 36
    required property var app
    required property var panel
    readonly property var store: scopedStore
    readonly property var owner: panel.owner
    readonly property double generation: owner.documentGeneration
    readonly property var range: panel.selectedSummary ? panel.liveRange : null
    readonly property string liveResultId: panel.result.summaryNoteSource || ""
    readonly property bool queryCurrent: store.current() && (panel.selectedSummary
        ? !!range && panel.sameRange(store.scopeSelection, range) : store.scopeSelection === null)
    readonly property var saved: queryCurrent && store.entries.length ? store.entries[0] : null
    readonly property var versions: queryCurrent ? store.entries.slice(1) : []
    readonly property bool liveMatches: {
        const plan = panel.result.responsePlan || {};
        return panel.selectedSummary ? plan.action === "SummarizeSelection" && panel.sameRange((plan.reading_scope || {}).selection, range)
            : plan.action === "SummarizeDocument" && (["reading_summary", "summary_synthesis"].indexOf(plan.kind) >= 0 || !!panel.viewState.cachedWholeSummary);
    }
    readonly property var result: {
        const state = ((panel.viewState.results || {}).summary || {}).state;
        const partial = liveMatches && !!panel.result.output && ["failed", "cancelled", "partial"].indexOf(state) >= 0;
        if (panel.running && panel.viewState.responseView === "summary" || panel.synthesisPreview || partial) return panel.result;
        if (saved) {
            const active = saved.id === liveResultId ? panel.result : ({});
            return {output: saved.content, generation: generation, summaryNoteSource: saved.id,
                reasoning: active.reasoning || "", usage: active.usage || ({}), synthesisParts: active.synthesisParts, summaryHistoryWarning: active.summaryHistoryWarning || "",
                responsePlan: {action: panel.selectedSummary ? "SummarizeSelection" : "SummarizeDocument",
                    source_pages: saved.source_pages || [], model: saved.model}};
        }
        return liveMatches ? panel.result : ({});
    }
    readonly property string resultId: result.summaryNoteSource || ""
    readonly property bool hasResult: !!result.output
    readonly property bool popupVisible: more.visible
    readonly property bool configured: {
        const account = app.session ? app.session.chatGptAccounts : null;
        const useAccount = account && (panel.selectedSummary ? account.useForSelection : account.useForWholeDocument);
        return useAccount ? account.connected && !!String(account.model || "").trim() : !!String(app.aiSettings.model || "").trim();
    }
    AiTaskStore { id: scopedStore; app: task.app; parent: task }
    Connections { target: scopedStore; function onAboutToReplaceEntries() { task.rememberPosition(); } }
    Timer { id: scopeRefresh; interval: 80; onTriggered: task.refreshMetadata() }
    function refreshMetadata() {
        // History is covered by the review dialog. Its deferred read must not
        // change command admission while the reader activates Send.
        if (!visible || panel.reviewTicket || panel.payloadOpen || panel.running) return;
        if (panel.selectedSummary && !range) { store.reset(); return; }
        store.reload("summary", range);
    }
    onRangeChanged: scopeRefresh.restart()
    onOwnerChanged: { more.close(); previous.checked = false; scopeRefresh.restart(); }
    onGenerationChanged: { more.close(); previous.checked = false; scopeRefresh.restart(); }
    function openMore(anchor) { more.parent = anchor; more.popup(0, anchor.height); }
    onLiveResultIdChanged: if (visible && liveResultId) refreshMetadata()
    Connections {
        target: task.panel
        function onPayloadOpenChanged() { if (task.panel.payloadOpen) scopeRefresh.stop(); else scopeRefresh.restart(); }
        function onReviewTicketChanged() { if (!task.panel.reviewTicket) scopeRefresh.restart(); }
        function onRunningChanged() { if (!task.panel.running) scopeRefresh.restart(); }
    }
    onVisibleChanged: {
        if (visible) scopeRefresh.restart();
        else { more.close(); scopeRefresh.stop(); }
    }
    Component.onCompleted: scopeRefresh.restart()
    Menu {
        id: more
        focus: true
        background: Rectangle { color: app.colors.menuBg; radius: 6; border.color: app.colors.separator }
        MenuItem { text: qsTr("Layers and coverage…"); enabled: panel.owner.pageCount > 0 && !panel.owner.loading && !panel.owner.snapshotReadOnly; onTriggered: panel.openSummaryCatalog() }
        MenuItem { text: qsTr("Document Reading…"); enabled: !panel.owner.snapshotReadOnly; onTriggered: app.openDocumentReading() }
        MenuItem { text: qsTr("Request payload…"); enabled: !!panel.plan; onTriggered: panel.inspectPayload() }
        MenuItem { text: qsTr("Local audit trail…"); onTriggered: app.showAuditTrail() }
        MenuItem { text: qsTr("Reading notes…"); onTriggered: app.openReadingNotes() }
    }
    ColumnLayout {
        id: taskBody
        x: 18; y: 18
        width: Math.max(0, task.availableWidth - 36)
        spacing: 18
        LyraReadingSegmentedPicker {
            objectName: "aiSummaryScope"
            app: task.app
            Layout.fillWidth: true; Layout.minimumWidth: 0
            choices: [{title: qsTr("Whole document"), icon: "document"}, {title: qsTr("Selection"), icon: "selection"}]
            currentIndex: task.panel.selectedSummary ? 1 : 0
            enabled: !task.panel.running && !task.panel.owner.loading
            Accessible.name: qsTr("Summary source")
            onActivated: function(index) { task.panel.owner.setAiInput("action", index ? 5 : 1); }
        }
        AiSelectionExcerpt {
            app: task.app
            visible: task.panel.selectedSummary
            range: task.panel.liveRange; prepared: false
            title: range ? qsTr("Selected passage · p. %1").arg(range.page + 1) : qsTr("Selected passage")
            partial: !!task.panel.currentExcerpt && task.panel.currentExcerpt.partial
            text: task.panel.currentExcerpt ? task.panel.currentExcerpt.text : ""
            labelName: "aiLiveSelection"
            onLocateRequested: function(range, prepared) { task.panel.locate(range, prepared); }
        }
        AiSelectionExcerpt {
            app: task.app
            visible: task.panel.previewReady && task.panel.selectedSources.length > 0 && !task.panel.sameRange(task.panel.liveRange, task.panel.preparedRange)
            range: task.panel.preparedRange; prepared: true
            title: qsTr("Previewed source")
            text: task.panel.selectedSources.map(source => source.snippet).join("")
            labelName: "aiSelectedSummarySource"
            onLocateRequested: function(range, prepared) { task.panel.locate(range, prepared); }
        }
        RowLayout {
            visible: task.panel.wholeSummary
            spacing: 8
            LyraToolButton { symbol: "document"; icon.color: app.colors.textSecondary; icon.width: 14; icon.height: 14; implicitWidth: 16; implicitHeight: 18; padding: 0; background: null; focusPolicy: Qt.NoFocus; hoverEnabled: false; Accessible.ignored: true }
            Label {
                objectName: "aiSummaryAllPages"
                text: qsTr("All %1 pages").arg(task.panel.owner.pageCount)
                color: app.colors.textSecondary; font.pixelSize: 12
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Label { text: qsTr("Detail"); font.pixelSize: 12; color: app.colors.textPrimary }
            Item { Layout.fillWidth: true }
            ComboBox {
                objectName: "aiSelectedSummaryDetail"
                Layout.preferredWidth: 98; implicitHeight: 28
                font.pixelSize: 13
                model: [qsTr("Brief"), qsTr("Standard"), qsTr("Detailed")]
                readonly property var values: ["Brief", "Standard", "Detailed"]
                currentIndex: values.indexOf(task.panel.summaryDetail)
                Accessible.name: qsTr("Summary detail")
                enabled: !task.panel.running
                onActivated: task.panel.owner.setAiInput("summaryDetail", values[currentIndex])
            }
        }
        RowLayout {
            visible: task.panel.running
            Layout.fillWidth: true
            BusyIndicator { running: visible; implicitWidth: 18; implicitHeight: 18 }
            Label { text: task.panel.viewState.responseView === "summary" ? qsTr("Summarizing…") : qsTr("Another AI task is running…"); font.pixelSize: 12; color: app.colors.textSecondary; Layout.fillWidth: true }
            Button { objectName: "cancelAiRequest"; text: qsTr("Stop"); onClicked: task.panel.owner.cancelAi() }
        }
        Label {
            objectName: "aiSummaryResultMetadata"
            visible: !task.panel.running && !!task.result.output && (!!task.saved || !!(task.result.responsePlan || {}).model)
            text: task.saved ? (task.saved.language || qsTr("Document language")) + " · " + task.saved.model : (task.result.responsePlan || {}).model || ""
            textFormat: Text.PlainText; wrapMode: Text.Wrap
            Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11
        }
        Label {
            visible: !!task.saved && task.panel.wholeSummary && task.saved.status !== "sourceChanged"
            text: task.saved ? qsTr("Text coverage: %1 of %2 pages").arg(task.saved.source_pages.length).arg(task.panel.owner.pageCount) : ""
            color: app.colors.textSecondary; font.pixelSize: 11
        }
        Label {
            visible: !!task.saved && (task.saved.detail !== task.panel.summaryDetail || task.saved.language !== (task.panel.input.summaryLanguage || ""))
            text: qsTr("Settings changed. Generate again to update this result.")
            textFormat: Text.PlainText; wrapMode: Text.Wrap
            Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 12
        }
        Label {
            visible: !!task.saved && task.saved.status === "sourceChanged"
            text: qsTr("The document has changed. This result keeps its original source snapshot.")
            textFormat: Text.PlainText; wrapMode: Text.Wrap
            Layout.fillWidth: true; color: app.colors.warningFg; font.pixelSize: 12
        }
        AiResult {
            id: answer
            app: task.app; value: task.result; viewport: task.contentItem
            Layout.fillWidth: true; Layout.minimumWidth: 0
            visible: !!task.result.output
            collapsibleSummary: !task.panel.running
            showActions: false
            inlineConversation: true; bodySize: 14
            onCitation: function(link, plan) { task.panel.followHistoryLink(link, plan); }
        }
        ColumnLayout {
            visible: !task.panel.running && !task.result.output
            Layout.fillWidth: true; Layout.topMargin: 12; Layout.bottomMargin: 12
            spacing: 8
            LyraToolButton { symbol: "summary"; icon.color: app.colors.accent; icon.width: 28; icon.height: 28; implicitWidth: 36; implicitHeight: 36; padding: 0; background: null; focusPolicy: Qt.NoFocus; hoverEnabled: false; Accessible.ignored: true }
            Label { text: qsTr("Get the shape of this document"); font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.Wrap; color: app.colors.textPrimary }
            Label { text: qsTr("An overview, key ideas and links back to the source."); font.pixelSize: 14; Layout.fillWidth: true; wrapMode: Text.Wrap; color: app.colors.textSecondary }
        }
        RowLayout {
            visible: !task.panel.running && !!task.result.output
            Layout.fillWidth: true
            LyraToolButton {
                objectName: "aiAnswerTextCopy"; symbol: "copy"; text: qsTr("Copy"); display: AbstractButton.TextBesideIcon
                onClicked: if (app.session) {
                    app.session.copyText(task.result.output);
                    app.showReadingNotice(qsTr("Copied"), task.panel.owner);
                }
            }
            LyraToolButton {
                objectName: "keepAiSummaryNote"
                symbol: "note-add"; text: qsTr("Keep in notes"); display: AbstractButton.TextBesideIcon
                enabled: !!task.resultId && !task.panel.owner.pendingCommands && !task.panel.owner.readingNoteDraft.id
                onClicked: task.panel.keepInNotes(task.resultId)
            }
        }
        Label { objectName: "aiAnswerTextUsage"; visible: !!text; text: answer.usageSummary; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 10 }
        ToolButton { id: previous; visible: task.versions.length > 0; checkable: true; text: qsTr("Previous results") + (checked ? " ▾" : " ▸") }
        Repeater {
            model: previous.checked ? task.versions : []
            AiResult {
                required property var modelData
                app: task.app; Layout.fillWidth: true; viewport: task.contentItem
                value: ({output: modelData.content, generation: task.store.generation, responsePlan: {action: "SummarizeDocument", source_pages: modelData.source_pages || []}})
                answerName: "aiPreviousSummary" + modelData.id
                inlineConversation: true; bodySize: 14
                onCitation: function(link, plan) { task.panel.followHistoryLink(link, plan); }
            }
        }
        ToolButton {
            id: parts
            objectName: "aiShowPartSummaries"
            visible: !!task.result.synthesisParts
            text: checked ? qsTr("Hide part summaries") : qsTr("Show part summaries")
            checkable: true
            onVisibleChanged: if (!visible) checked = false
        }
        Loader {
            Layout.fillWidth: true
            active: task.visible && parts.visible && parts.checked
            visible: active
            sourceComponent: AiResult {
                app: task.app; value: task.result.synthesisParts || ({})
                answerName: "aiPartSummaryText"; viewport: task.contentItem
                onCitation: function(link, plan) { task.panel.followHistoryLink(link, plan); }
            }
        }
        Label { visible: !!text; text: task.panel.status; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11 }
        Label { visible: !!text; text: [task.result.summaryHistoryWarning, task.panel.viewState.cacheWarning, task.store.failure].filter(value => !!value).join("\n"); textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.warningFg; font.pixelSize: 11 }
        Label { visible: !task.configured; text: qsTr("Connect an AI provider in Settings to continue."); textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 12 }
        ReadingPrimaryButton {
            app: task.app
            objectName: "prepareAiRequest"
            Layout.fillWidth: true
            text: task.result.output ? qsTr("Regenerate") : task.panel.selectedSummary ? qsTr("Summarize selection") : qsTr("Summarize document")
            icon.source: task.result.output ? "qrc:/icons/rotate.svg" : "qrc:/icons/ai.svg"
            enabled: !task.panel.running && task.configured && task.panel.owner.pageCount > 0 && !task.panel.owner.pendingCommands && (!task.panel.selectedSummary || !!task.panel.liveRange)
            onClicked: task.panel.prepareFromUi()
        }
        RowLayout {
            visible: task.panel.previewReady && !task.panel.running
            Layout.fillWidth: true
            Button { text: qsTr("Inspect Payload"); Layout.fillWidth: true; onClicked: task.panel.inspectPayload() }
            Button { objectName: "sendAiRequest"; text: task.panel.synthesisPreview ? qsTr("Send synthesis") : qsTr("Send"); Layout.fillWidth: true; enabled: !task.panel.owner.pendingCommands; onClicked: app.sendAi(task.panel.owner, task.panel.plan) }
        }
        RowLayout {
            visible: !!task.panel.owner.documentReading.choice_pending
            Layout.fillWidth: true
            Button { text: qsTr("Read document (optional)…"); Layout.fillWidth: true; onClicked: app.openDocumentReading() }
            ToolButton { text: qsTr("Skip"); onClicked: task.panel.owner.dismissDocumentReadingChoice() }
        }
    }
}

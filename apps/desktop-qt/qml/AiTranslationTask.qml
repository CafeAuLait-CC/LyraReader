import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

Item {
    id: translationTask
    objectName: "aiTranslationTask"
    required property var app
    required property var panel
    readonly property var owner: panel.owner
    readonly property double generation: owner.documentGeneration
    readonly property real leadingInset: 18 + (timeline.LayoutMirroring.enabled ? bar.gutterWidth : 0)
    readonly property real rowWidth: Math.max(0, timeline.width - 36 - bar.gutterWidth)
    readonly property var viewport: timeline
    readonly property bool showOriginal: panel.input.translationShowOriginal !== false
    readonly property bool popupVisible: more.visible || termPopup.anyVisible || (!!timeline.headerItem && timeline.headerItem.languagePicker.popupVisible)
    readonly property bool covered: panel.payloadOpen || !!panel.reviewTicket || panel.running
    readonly property bool configured: {
        if(!app.aiConnectionReady)return false;
        const accounts = app.session ? app.session.chatGptAccounts : null;
        const useAccount = accounts && (panel.translateDocument ? accounts.useForWholeDocument : accounts.useForSelection);
        return useAccount ? accounts.connected && !!String(accounts.model || "").trim() : !!String(app.aiSettings.model || "").trim();
    }
    readonly property bool canReview: configured && !panel.running && !owner.pendingCommands && owner.pageCount > 0
    readonly property bool termConfigured: {
        if(!app.aiConnectionReady)return false;
        const accounts = app.session ? app.session.chatGptAccounts : null;
        return accounts && accounts.useForWholeDocument ? accounts.connected && !!String(accounts.model || "").trim()
            : !!String(app.aiSettings.model || "").trim();
    }
    readonly property bool canExplain: termConfigured && !panel.running && !panel.previewReady && !covered
        && !owner.pendingCommands && !owner.snapshotReadOnly && owner.pageCount > 0
    function explainTerm(term, anchor, sourceRow, snapshot) {
        if (!canExplain || !current() || !sourceRow || !sourceRow.entry || sourceRow.entry.status === "sourceChanged"
                || !snapshot || snapshot.reader !== owner || snapshot.generation !== generation
                || snapshot.record !== sourceRow.recordId || (snapshot.terms || []).indexOf(term) < 0) return false;
        const request = panel.baseRequest("SummarizeDocument");
        request.selection = null; request.question = term;
        request.language = panel.input.language === undefined ? "English" : panel.input.language;
        const accounts = app.session ? app.session.chatGptAccounts : null;
        if (accounts && !panel.connectChatGpt(request, accounts, accounts.useForWholeDocument)) return false;
        return termPopup.openFor(owner, generation, request, anchor, sourceRow);
    }
    function releaseTermRow(row) { if (termPopup && termPopup.ticket && termPopup.ticket.sourceRow === row) termPopup.close(); }
    readonly property bool activeMatches: !!panel.result.responsePlan && panel.result.responsePlan.kind === "reading_translation"
        && (!!(panel.result.responsePlan.reading_scope || {}).selection !== panel.translateDocument)
    readonly property bool showActive: activeMatches && (panel.running || !!panel.result.translationHistoryWarning)
    readonly property var activeEntry: ({content: panel.result.output || "", blocks: panel.pairedTranslation,
        source_pages: (panel.result.responsePlan || {}).source_pages || [], status: panel.running ? "running" : "partial"})
    readonly property int activeCount: showActive && !!panel.result.output ? Math.max(1, panel.pairedTranslation.length) : 0
    property bool initialized: false
    property var boundReader: null
    property double boundGeneration: 0
    property double metadataCommand: 0
    property bool metadataSelection: false
    property bool metadataLoaded: false
    property string failure: ""
    property var records: []
    property var entries: Object.create(null)
    property var entryErrors: Object.create(null)
    property var requested: Object.create(null)
    property var entryCommands: Object.create(null)
    property var queued: []
    property var expanded: Object.create(null)
    property var originalOpen: Object.create(null)
    property var spans: Object.create(null)
    property int activeModelCount: 0
    property var pendingFocus: null
    function withValue(map, key, value) { const result = Object.assign(Object.create(null), map); result[key] = value; return result; }
    function withoutKey(map, key) { const result = Object.assign(Object.create(null), map); delete result[key]; return result; }
    function current() { return boundReader === owner && boundGeneration === generation; }
    function reset() {
        termPopup.close();
        more.close(); visibleEntries.stop(); restoreFocus.stop(); pendingFocus = null;
        metadataCommand = 0; metadataLoaded = false; failure = "";
        boundReader = owner; boundGeneration = generation;
        records = []; entries = Object.create(null); entryErrors = Object.create(null);
        requested = Object.create(null); entryCommands = Object.create(null); queued = [];
        expanded = Object.create(null); originalOpen = Object.create(null); rebuildRows();
        refresh.restart();
    }
    function reload() {
        if (!visible || covered || !owner.pageCount || !current()) return;
        timelineMemory.capturePosition();
        metadataSelection = !panel.translateDocument;
        metadataCommand = owner.submit("ai_translation_history", {selection: metadataSelection});
    }
    function needEntry(id, retry) {
        if (!id || entries[id] || requested[id] || (!retry && entryErrors[id])) return;
        requested = withValue(requested, id, true); queued = queued.concat([id]); entryFlush.restart();
    }
    function flushEntries() {
        if (!visible || covered || !current() || !queued.length) return;
        const ids = queued.slice(0, 16); queued = queued.slice(16);
        const command = owner.submit("ai_translation_history_entries", {ids: ids});
        if (command) entryCommands = withValue(entryCommands, String(command), ids);
        else for (const id of ids) { requested = withValue(requested, id, false); entryErrors = withValue(entryErrors, id, qsTr("The saved result could not be loaded.")); }
        if (queued.length) entryFlush.restart();
    }
    function wakeReads() {
        if (covered || !visible) return;
        refresh.restart(); entryFlush.restart();
        visibleEntries.restart();
    }
    function rebuildRows() {
        rows.clear(); activeModelCount = activeCount;
        const items = [], sizes = Object.create(null);
        for (let i = 0; i < activeModelCount; ++i) items.push({recordId: "", paragraph: i, first: i === 0, last: i === activeModelCount - 1, isActive: true, isExpanded: true});
        for (const record of records) {
            const entry = entries[record.id];
            const count = expanded[record.id] && entry ? Math.max(1, (entry.blocks || []).length) : 1;
            sizes[record.id] = count;
            for (let i = 0; i < count; ++i) items.push({recordId: record.id, paragraph: i, first: i === 0, last: i === count - 1, isActive: false, isExpanded: !!expanded[record.id]});
        }
        spans = sizes;
        if (items.length) rows.append(items);
    }
    function recordIndex(id) {
        let offset = activeModelCount;
        for (const record of records) { if (record.id === id) return offset; offset += spans[record.id] || 1; }
        return -1;
    }
    function revealRecord(id) { const index = recordIndex(id); if (index >= 0) timeline.positionViewAtIndex(index, ListView.Beginning); }
    function expandRecord(id, open) {
        const index = recordIndex(id), entry = entries[id];
        if (index < 0 || !entry) return;
        const before = spans[id] || 1;
        const count = open ? Math.max(1, (entry.blocks || []).length) : 1;
        expanded = withValue(expanded, id, open);
        if (before > 1) rows.remove(index + 1, before - 1);
        rows.setProperty(index, "isExpanded", open); rows.setProperty(index, "last", count === 1);
        const additional = [];
        for (let i = 1; i < count; ++i) additional.push({recordId: id, paragraph: i, first: false, last: i === count - 1, isActive: false, isExpanded: true});
        if (additional.length) rows.insert(index + 1, additional);
        spans = withValue(spans, id, count);
        if (!open) revealRecord(id);
        pendingFocus = {reader: owner, generation: generation, id: id, open: open};
        restoreFocus.restart();
    }
    function setOriginalOpen(key, value) { originalOpen = withValue(originalOpen, key, value); }
    function chooseScope(index) {
        if (!current()) return;
        timelineMemory.resetPosition(owner, generation, index ? "translation-selection" : "translation-document");
        owner.setAiInput("translationScope", index ? "selection" : "document");
        timeline.positionViewAtBeginning();
    }
    function openMore(anchor) { more.openBelow(anchor); }
    // Observe the combined state itself. Dependency change handlers may run
    // before this derived value settles, leaving the final reload suppressed.
    onCoveredChanged: if (initialized) {
        if (covered) { refresh.stop(); entryFlush.stop(); visibleEntries.stop(); restoreFocus.stop(); pendingFocus = null; }
        else wakeReads();
    }
    onOwnerChanged: if (initialized) reset()
    onGenerationChanged: if (initialized) reset()
    onActiveCountChanged: if (initialized) rebuildRows()
    onVisibleChanged: if (initialized) {
        if (visible) wakeReads();
        else { termPopup.close(); more.close(); if (timeline.headerItem) timeline.headerItem.languagePicker.closePopups(); refresh.stop(); entryFlush.stop(); visibleEntries.stop(); restoreFocus.stop(); pendingFocus = null; }
    }
    Component.onCompleted: { initialized = true; reset(); }
    Timer { id: refresh; interval: 80; onTriggered: translationTask.reload() }
    Timer { id: entryFlush; interval: 0; onTriggered: translationTask.flushEntries() }
    // Owned timers disappear with the task Loader. Anonymous callLater closures
    // can retain an invalid QML context after a tab or tool destroys this task.
    Timer {
        id: visibleEntries; interval: 0
        onTriggered: {
            if (!translationTask.current() || translationTask.covered || !translationTask.visible) return;
            for (const child of timeline.contentItem.children)
                if (typeof child.recordId === "string" && child.recordId) translationTask.needEntry(child.recordId);
        }
    }
    Timer {
        id: restoreFocus; interval: 0
        onTriggered: {
            const ticket = translationTask.pendingFocus; translationTask.pendingFocus = null;
            if (!ticket || !translationTask.visible || ticket.reader !== translationTask.owner || ticket.generation !== translationTask.generation) return;
            const item = timeline.itemAtIndex(translationTask.recordIndex(ticket.id));
            if (item) { if (ticket.open) item.focusAnswer(); else item.focusDisclosure(); }
        }
    }
    Connections {
        target: translationTask.panel
        function onTranslateDocumentChanged() { translationTask.metadataLoaded = false; translationTask.failure = ""; translationTask.records = []; translationTask.rebuildRows(); timeline.positionViewAtBeginning(); refresh.restart(); }
    }
    Connections {
        target: translationTask.boundReader
        function onDocumentChanged() { if (!translationTask.metadataLoaded && translationTask.owner.pageCount) refresh.restart(); }
        function onCommandFinished(id, operation, result, error) {
            if (!translationTask.current()) return;
            if (operation === "ai_translation_history" && id === translationTask.metadataCommand) {
                timelineMemory.capturePosition();
                translationTask.metadataCommand = 0;
                if (translationTask.metadataSelection !== !translationTask.panel.translateDocument) return;
                translationTask.metadataLoaded = true; translationTask.failure = error;
                if (!error) { translationTask.records = result; translationTask.rebuildRows(); }
            } else if (operation === "ai_translation_history_entries" && translationTask.entryCommands[String(id)]) {
                timelineMemory.capturePosition();
                const ids = translationTask.entryCommands[String(id)];
                translationTask.entryCommands = translationTask.withoutKey(translationTask.entryCommands, String(id));
                const values = Object.assign(Object.create(null), translationTask.entries);
                for (const key of ids) {
                    translationTask.requested = translationTask.withoutKey(translationTask.requested, key);
                    const entry = error ? null : result.find(value => value.id === key);
                    if (entry) { values[key] = entry; translationTask.entryErrors = translationTask.withoutKey(translationTask.entryErrors, key); }
                    else translationTask.entryErrors = translationTask.withValue(translationTask.entryErrors, key, error || qsTr("The saved result identity changed. Reload it to continue."));
                }
                translationTask.entries = values;
                for (const key of ids) if (translationTask.expanded[key] && values[key]) translationTask.expandRecord(key, true);
            }
        }
    }
    ListModel { id: rows }
    ListView {
        id: timeline
        objectName: "aiTranslationTimeline"
        anchors.fill: parent
        model: rows; clip: true; spacing: 0
        ReadingScrollMemory {
            id: timelineMemory
            reader: translationTask.owner
            key: translationTask.panel.translateDocument ? "translation-document" : "translation-selection"
            viewport: timeline
            active: translationTask.visible
            ready: translationTask.current() && translationTask.metadataLoaded && !translationTask.metadataCommand
                && !translationTask.queued.length && !Object.keys(translationTask.entryCommands).length
        }
        PanelWheelHandler { viewport: timeline; onScrollIntent: timelineMemory.userIntent(); onScrollApplied: timelineMemory.completeUserScroll() }
        Connections { target: bar; function onPressedChanged() { if (bar.pressed) timelineMemory.userIntent(); } }
        ScrollBar.vertical: AiReadingScrollBar { id: bar }
        header: Item {
            readonly property var languagePicker: language
            width: timeline.width
            height: headerBody.implicitHeight + 36
            ColumnLayout {
                id: headerBody
                x: 18 + (timeline.LayoutMirroring.enabled ? bar.gutterWidth : 0); y: 18
                width: Math.max(0, parent.width - 36 - bar.gutterWidth)
                spacing: 14
                LyraReadingSegmentedPicker {
                    objectName: "aiTranslationScope"; app: translationTask.app
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    choices: [{title: qsTr("Whole document"), icon: "document"}, {title: qsTr("Selection"), icon: "selection"}]
                    currentIndex: translationTask.panel.translateDocument ? 0 : 1
                    enabled: !translationTask.panel.running && !translationTask.owner.loading
                    Accessible.name: qsTr("Translation source")
                    onActivated: function(index) { translationTask.chooseScope(index); }
                }
                AiSelectionExcerpt {
                    app: translationTask.app; visible: !translationTask.panel.translateDocument
                    Layout.topMargin: 4
                    range: translationTask.panel.liveRange; prepared: false
                    title: range ? qsTr("Selected passage · p. %1").arg(range.page + 1) : qsTr("Selected passage")
                    text: translationTask.panel.currentExcerpt ? translationTask.panel.currentExcerpt.text : ""
                    partial: !!translationTask.panel.currentExcerpt && translationTask.panel.currentExcerpt.partial
                    labelName: "aiLiveSelection"
                    onLocateRequested: function(range, prepared) { translationTask.panel.locate(range, prepared); }
                }
                AiSelectionExcerpt {
                    app: translationTask.app
                    visible: translationTask.panel.previewReady && translationTask.panel.selectedSources.length > 0 && !translationTask.panel.sameRange(translationTask.panel.liveRange, translationTask.panel.preparedRange)
                    range: translationTask.panel.preparedRange; prepared: true; title: qsTr("Previewed source")
                    text: translationTask.panel.selectedSources.map(source => source.snippet).join(""); labelName: "aiSelectedTranslationSource"
                    onLocateRequested: function(range, prepared) { translationTask.panel.locate(range, prepared); }
                }
                RowLayout {
                    Layout.fillWidth: true; spacing: 12
                    ReadingPrimaryButton {
                        app: translationTask.app; objectName: "prepareAiRequest"
                        text: qsTr("Translate"); icon.source: "qrc:/icons/translation-panel.svg"
                        Layout.fillWidth: true; Layout.minimumWidth: 0
                        enabled: translationTask.canReview && !translationTask.failure && (translationTask.panel.translateDocument || !!translationTask.panel.liveRange)
                        onClicked: translationTask.panel.prepareFromUi()
                    }
                    Label { text: qsTr("TO"); color: app.colors.textSecondary; font.pixelSize: 12 }
                    AiTranslationLanguagePicker {
                        id: language
                        app: translationTask.app; owner: translationTask.owner
                        language: translationTask.panel.input.language === undefined ? "English" : translationTask.panel.input.language
                        enabled: !translationTask.panel.running
                        onLanguageSelected: function(value) { translationTask.owner.setAiInput("language", value); }
                    }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: app.colors.separator }
                RowLayout {
                    Layout.fillWidth: true
                    Label { text: qsTr("Translations"); color: app.colors.textSecondary; font.pixelSize: 14; Layout.fillWidth: true; Layout.minimumWidth: 0; elide: Text.ElideRight }
                    CheckBox {
                        id: originalToggle
                        objectName: "aiTranslationShowOriginal"
                        text: qsTr("Show original"); font.pixelSize: 13
                        padding: 0; topPadding: 3; bottomPadding: 3; spacing: 8
                        checked: translationTask.showOriginal
                        indicator: Rectangle {
                            objectName: "aiTranslationOriginalIndicator"
                            implicitWidth: 14; implicitHeight: 14
                            x: originalToggle.mirrored ? originalToggle.width - width : 0
                            y: (originalToggle.height - height) / 2
                            radius: 2
                            color: originalToggle.checked ? (originalToggle.hovered && originalToggle.enabled ? app.colors.accentHover : app.colors.accent) : app.colors.fieldBg
                            border.width: originalToggle.checked ? 0 : 1
                            border.color: app.colors.controlBorder
                            Label { anchors.centerIn: parent; text: "\u2713"; visible: originalToggle.checked; color: app.colors.accentFg; font.pixelSize: 12; font.bold: true }
                        }
                        contentItem: Label {
                            text: originalToggle.text; textFormat: Text.PlainText; font: originalToggle.font
                            leftPadding: originalToggle.mirrored ? 0 : 22
                            rightPadding: originalToggle.mirrored ? 22 : 0
                            color: originalToggle.enabled ? app.colors.textSecondary : app.colors.textDisabled
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle { radius: 3; color: "transparent"; border.width: originalToggle.visualFocus ? 2 : 0; border.color: app.colors.focusRing }
                        opacity: enabled ? 1 : .45
                        onToggled: translationTask.owner.setAiInput("translationShowOriginal", checked)
                    }
                }
                RowLayout {
                    visible: translationTask.panel.running || !!translationTask.panel.reviewTicket
                    Layout.fillWidth: true
                    BusyIndicator { running: visible; implicitWidth: 18; implicitHeight: 18 }
                    Label { text: translationTask.panel.running ? qsTr("Translating…") : qsTr("Preparing source…"); color: app.colors.textSecondary; font.pixelSize: 12; Layout.fillWidth: true }
                    Button { objectName: "cancelAiRequest"; text: qsTr("Stop"); onClicked: { translationTask.panel.reviewTicket = null; if (translationTask.panel.running) translationTask.owner.cancelAi(); else translationTask.owner.invalidateAiPlan(); } }
                }
                Label {
                    visible: translationTask.metadataLoaded && !translationTask.records.length && !translationTask.showActive && !translationTask.panel.running
                    text: qsTr("A continuous translation with the original source close at hand.")
                    Layout.fillWidth: true; Layout.topMargin: 12; Layout.bottomMargin: 12
                    textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.colors.textSecondary; font.pixelSize: 14
                }
            }
        }
        delegate: AiTranslationRow {
            app: translationTask.app; task: translationTask
            width: timeline.width
        }
        footer: ColumnLayout {
            x: 18 + (timeline.LayoutMirroring.enabled ? bar.gutterWidth : 0)
            width: Math.max(0, timeline.width - 36 - bar.gutterWidth)
            spacing: 12
            Label { visible: !!text; text: translationTask.failure; Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.colors.warningFg; font.pixelSize: 12 }
            Label { visible: !!text; text: translationTask.panel.result.translationHistoryWarning || translationTask.panel.result.translationWarning || ""; Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.colors.warningFg; font.pixelSize: 12 }
            Label { visible: !!text; text: translationTask.panel.status; Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.colors.textSecondary; font.pixelSize: 12 }
            Label { visible: !translationTask.configured; text: qsTr("Connect an AI provider in Settings to continue."); Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.colors.textSecondary; font.pixelSize: 12 }
            RowLayout {
                visible: translationTask.panel.previewReady && !translationTask.panel.running
                Layout.fillWidth: true
                Button { text: qsTr("Inspect Payload"); Layout.fillWidth: true; onClicked: translationTask.panel.inspectPayload() }
                Button { objectName: "sendAiRequest"; text: qsTr("Send"); Layout.fillWidth: true; enabled: !translationTask.owner.pendingCommands; onClicked: app.sendAi(translationTask.owner, translationTask.panel.plan) }
            }
            Item { height: 18; width: 1 }
        }
    }
    LyraMenu {
        id: more
        focus: true

        LyraMenuItem { objectName: "openAiTranslationHistory"; text: qsTr("Translation history…"); enabled: !translationTask.panel.running && !translationTask.owner.pendingCommands; onTriggered: translationTask.panel.openTranslationHistory() }
        LyraMenuItem { text: qsTr("Translate in place…"); enabled: !translationTask.panel.running; onTriggered: { const reader = translationTask.owner; reader.setAiInput("translationScope", "selection"); reader.setAiInput("inplace", true); } }
        LyraMenuItem { text: qsTr("Copy latest translation"); enabled: !!translationTask.panel.result.output; onTriggered: if (app.session) app.session.copyText(translationTask.panel.pairedTranslation.length ? translationTask.panel.pairedTranslation.map(block => block.translation).join("\n\n") : translationTask.panel.result.output) }
        LyraMenuItem { text: qsTr("Request payload…"); enabled: !!translationTask.panel.plan; onTriggered: translationTask.panel.inspectPayload() }
        LyraMenuItem { text: qsTr("Document Reading…"); enabled: !translationTask.owner.snapshotReadOnly; onTriggered: app.openDocumentReading() }
        LyraMenuItem { text: qsTr("Local audit trail…"); onTriggered: app.showAuditTrail() }
    }
    AiTermPopup {id: termPopup; app: translationTask.app; task: translationTask}
}

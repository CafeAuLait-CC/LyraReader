import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

Pane {
    id: notes
    objectName: "aiReadingNotesContent"
    required property var app
    property var reader: null
    property double generation: 0
    property double command: 0
    property var entries: []
    property var note: null
    property var noteOwner: null
    property double noteGeneration: 0
    property string preferred: ""
    property string failure: ""
    property bool editing: false
    property bool seeding: false
    property var editBaseline: ({})
    property string reviewId: ""
    property var updateIntent: null
    onNoteChanged: if (updateIntent) Qt.callLater(finishUiUpdate)
    onReviewPlanChanged: if (updateIntent) Qt.callLater(finishUiUpdate)
    onVisibleChanged: if (!visible && updateIntent) endPreview()
    property bool suggestionExpanded: false
    property var regionContext: ({})
    property double regionContextCommand: 0
    property var continuationContext: null
    property double continuationCommand: 0
    property var sourceFocusTicket: null
    property var thoughtsFailureTicket: null
    property bool syncWaiting: false
    property string syncKeepSource: ""
    property bool importedRefreshWanted: false
    property double importedListCommand: 0
    property double importedDetailCommand: 0
    property var importedDetailTicket: null
    readonly property string selectedNoteId: note ? note.id : ""
    readonly property var sourceEntry: note ? entries.find(entry => entry.id === note.id) || note : ({})
    onSelectedNoteIdChanged: {
        suggestionExpanded = false; thoughtsFailureTicket = null;
        sourceDisclosure.expanded = false; conversationDisclosure.expanded = false;
        continuationContext = null; sourceFocusTicket = null;
    }
    readonly property var sourceContext: note ? note.source || ({}) : ({})
    readonly property var regionEntry: sourceContext.region_id && !regionContext.error && !regionContext.writes_blocked
        ? (regionContext.entries || []).find(entry => entry.id === sourceContext.region_id && !entry.location_invalidated) || null : null
    readonly property bool canUpdateDiscussion: !!regionEntry && regionEntry.completed_turn_count > sourceContext.covered_turns
    readonly property bool reviewing: reviewId.length > 0
    readonly property var reviewState: reader ? reader.aiState : ({})
    readonly property var reviewPlan: reviewing && reviewState.previewView === "note"
        && reviewState.plan && reviewState.plan.note_id === reviewId ? reviewState.plan : null
    readonly property bool reviewRunning: reviewing && reviewState.responseView === "note" && !!reviewState.running
    readonly property bool dirty: !!(reader && note && reader.readingNoteDraft.id === note.id)
    readonly property bool automaticDraftPending: !!(reader && reader.readingNoteAutomatic && reader.readingNoteDraft.id)
    readonly property bool noteWriteReady: current() && !command && !reader.pendingCommands && !reader.hasUnsavedReadingNotes
    background: Rectangle { color: app.colors.panelBg }
    property bool inlineMode: false
    component NoteAction: LyraToolButton {
        theme: notes.app.colors
        display: AbstractButton.TextOnly
        implicitHeight: 24
        padding: 4
        font.pixelSize: 13; font.weight: Font.Normal
    }
    signal closeRequested()
    function close() { closeRequested(); }
    function copyAll() {
        if (!current() || !app.session) return;
        const draft = reader.readingNoteAutomatic ? reader.readingNoteDraft : ({});
        app.session.copyText(entries.map(entry => "# " + entry.title + "\n\n" + entry.content + "\n\n"
            + (draft.id === entry.id ? draft.thoughts : entry.thoughts)).join("\n\n---\n\n"));
        app.showReadingNotice(qsTr("Copied"), reader);
    }
    function copyUnsavedThoughts() {
        if (!current() || !reader.readingNoteAutomatic || !reader.readingNoteDraft.id || !app.session) return;
        app.session.copyText(reader.readingNoteDraft.thoughts);
        app.showReadingNotice(qsTr("Copied"), reader);
    }
    function discardThoughts(id) {
        if (!current() || command || editing || reviewing || reader.readingNoteSaving
                || !reader.readingNoteAutomatic || reader.readingNoteDraft.id !== id) return;
        finishInput();
        inlineThoughts.leaveInput();
        reader.discardReadingNoteDraft();
        // Another process may have changed or removed the saved record. Do not
        // label our old view as saved, or recreate the abandoned text on reset.
        loadNote(id);
    }
    function sourceLabel(entry) {
        if (entry.origin_kind === "summary" && entry.origin_scope === "document") return qsTr("Summary · Whole document");
        const kind = String(entry.source_id || "").startsWith("interleaf:") ? qsTr("Interleaf")
            : entry.origin_kind === "summary" ? qsTr("Summary") : entry.origin_kind === "message" ? qsTr("Chat") : qsTr("Reading note");
        const pages = (entry.source_pages || []).map(page => qsTr("p. %1").arg(page)).join(", ");
        return kind + (pages.length ? " · " + pages : entry.status === "sourceChanged" ? " · " + qsTr("Earlier PDF revision") : "");
    }
    function mergeNoteMetadata(value) {
        const row = Object.assign({}, value);
        // Only the currently opened detail owns its original answer snapshot.
        // Visiting notes must not accumulate a second history in the list rows.
        delete row.source;
        entries = entries.map(entry => entry.id === row.id ? Object.assign({}, entry, row) : entry);
    }
    signal requestUpdate(string noteId)

    function displayNote(value) {
        const changed = !note || note.id !== value.id;
        noteOwner = reader; noteGeneration = generation; note = value;
        if (changed) {
            regionContext = ({}); regionContextCommand = 0;
            if (sourceContext.region_id) regionContextCommand = reader.submit("region_list", {});
        }
    }
    function finishInput() {
        inlineThoughts.finishInput();
        if (editing && current() && (editTitle.activeFocus || editContent.activeFocus || editThoughts.activeFocus)) {
            Qt.inputMethod.commit();
        }
    }
    function revealEditInput(item, focusItem) {
        const owner = reader, epoch = generation, id = selectedNoteId;
        const interaction = editDetails.interactionEpoch;
        Qt.callLater(function() {
            if (notes.current() && notes.reader === owner && notes.generation === epoch && notes.selectedNoteId === id && notes.editing
                    && focusItem.activeFocus && editDetails.interactionEpoch === interaction)
                editDetails.revealItem(item);
        });
    }
    function revealSourceAction(item) {
        sourceFocusTicket = {owner: reader, generation: generation, id: selectedNoteId, item: item,
            interaction: contents.interactionEpoch, initial: true};
        Qt.callLater(tryRevealSourceAction);
    }
    function tryRevealSourceAction() {
        const ticket = sourceFocusTicket;
        if (!ticket) return;
        if (!current() || reader !== ticket.owner || generation !== ticket.generation || selectedNoteId !== ticket.id
                || editing || reviewing || !ticket.item || !ticket.item.activeFocus || contents.interactionEpoch !== ticket.interaction)
            { sourceFocusTicket = null; return; }
        // Native control metrics and a lazy answer can settle after the parent
        // layout's first polish. Keep the focused action visible as they finish.
        noteFlow.ensurePolished();
        const f = contents.contentItem, item = ticket.item;
        const y = item.mapToItem(f, 0, 0).y;
        if (ticket.initial || y < -.5 || y + item.height > f.height + .5) contents.revealItem(item);
        if (sourceFocusTicket !== ticket) return;
        ticket.interaction = contents.interactionEpoch; ticket.initial = false;
    }
    function revealThoughtsFailure() {
        thoughtsFailureTicket = {owner: reader, generation: generation, id: selectedNoteId,
            interaction: contents.interactionEpoch, attempts: 0};
    }
    function tryRevealThoughtsFailure() {
        const ticket = thoughtsFailureTicket;
        if (!ticket) return;
        if (!current() || reader !== ticket.owner || generation !== ticket.generation || selectedNoteId !== ticket.id
                || editing || !thoughtsErrorActions.visible || contents.interactionEpoch !== ticket.interaction
                || ticket.attempts++ >= 4) { thoughtsFailureTicket = null; return; }
        // A GPU frame already in flight may swap before the newly visible rows
        // have been laid out. Wait for their ordered, measured geometry too.
        if (thoughtsErrorActions.height <= 0 || thoughtsFailure.height < thoughtsFailure.implicitHeight - .5
                || thoughtsFailure.y < inlineThoughts.y + inlineThoughts.height
                || thoughtsErrorActions.y < thoughtsFailure.y + thoughtsFailure.height) return;
        contents.revealItem(thoughtsErrorActions);
        ticket.interaction = contents.interactionEpoch;
        const f = contents.contentItem;
        const y = thoughtsErrorActions.mapToItem(f, 0, 0).y;
        if (y >= -.5 && y + thoughtsErrorActions.height <= f.height + .5) thoughtsFailureTicket = null;
    }
    function current() {
        return reader && reader === app.currentReader && generation === reader.documentGeneration;
    }
    function followCitation(link, plan) {
        if (!current() || plan.generation !== generation || !note) return;
        const match = /^p\.(\d+)$/.exec(link);
        if (!match) return;
        const page = Number(match[1]);
        if ((note.source_pages || []).indexOf(page) < 0 || page < 1 || page > reader.pageCount) return;
        app.navigate(page - 1);
    }
    function locateSource(page) {
        if (!current() || !note || (note.source_pages || []).indexOf(page) < 0) return;
        finishInput();
        app.locateReadingSource(page - 1, sourceContext.excerpt || "");
    }
    function continueConversation() {
        if (!noteWriteReady || editing || reviewing || continuationCommand || reviewState.running) return;
        finishInput();
        const owner = reader, epoch = generation, id = selectedNoteId;
        if (regionEntry) {
            continuationContext = {owner: owner, generation: epoch, note: id, region: regionEntry.id};
            continuationCommand = owner.reopenAiRegion(regionEntry.id, regionContext.revision);
            if (!continuationCommand) {
                continuationContext = null;
                failure = qsTr("Save the current region or reading-note draft before continuing this conversation.");
            }
        } else if (sourceContext.chat_id) {
            if (!owner.reopenAiChat(sourceContext.chat_id)) {
                failure = qsTr("The document is busy. Try opening this conversation again."); return;
            }
            close();
            if (owner === app.currentReader && epoch === owner.documentGeneration) app.openAiWorkspace("chat");
        }
    }
    function finishContinue() {
        const ticket = continuationContext; continuationContext = null;
        if (!ticket || !current() || reader !== ticket.owner || generation !== ticket.generation || selectedNoteId !== ticket.note
                || editing || reviewing || reader.hasUnsavedReadingNotes) return;
        if (reader.aiRegion.history_id !== ticket.region) {
            failure = qsTr("The saved discussion changed. Open the note again before continuing."); return;
        }
        close(); app.showAiPanel(false); app.openRegionTool();
    }
    function browse(source, noteId = "") {
        reader = app.currentReader;
        generation = reader.documentGeneration;
        preferred = noteId;
        const draft = reader.readingNoteDraft;
        if (draft.id) {
            preferred = draft.id;
            refresh();
        } else {
            syncWaiting = true; syncKeepSource = source || "";
            if (!reader.requestReadingNotesSync()) finishSyncBrowse();
        }
    }
    function finishSyncBrowse() {
        if (!syncWaiting || !current()) return;
        syncWaiting = false;
        const source = syncKeepSource; syncKeepSource = "";
        if (source) command = reader.submit("ai_reading_keep", {id: source});
        else refresh();
    }
    function refreshImportedNotes() {
        if (!importedRefreshWanted || !current() || syncWaiting || command || importedListCommand || importedDetailCommand
                || editing || reviewing || reader.pendingCommands || reader.hasUnsavedReadingNotes || inlineThoughts.inputComposing) return;
        importedRefreshWanted = false;
        importedListCommand = reader.submit("ai_reading_notes", {query: search.text,
            recent: notes.inlineMode ? ordering.currentIndex === 1 : order.currentIndex === 0});
    }
    function rememberPosition() {
        if (current()) { listMemory.capturePosition(); contents.rememberPosition(); }
    }
    function refresh() {
        if (!current() || editing || reviewing) return;
        rememberPosition();
        preferred = preferred || (note ? note.id : "");
        note = null;
        failure = "";
        command = reader.submit("ai_reading_notes", {query: search.text, recent: notes.inlineMode ? ordering.currentIndex === 1 : order.currentIndex === 0});
    }
    function read(index) {
        if (!current() || editing || reviewing || index < 0 || index >= entries.length) return;
        loadNote(entries[index].id);
    }
    function loadNote(id) {
        if (!current() || editing || reviewing || command || !id) return;
        rememberPosition();
        note = null;
        failure = "";
        command = reader.submit("ai_reading_note", {id: id});
    }
    function backToList() {
        if (!current() || editing || reviewing || command) return;
        rememberPosition();
        note = null;
        preferred = "";
        refresh();
    }
    function beginEditing() {
        if (!current() || !note || command || reviewing || reader.documentRevisionPending || reader.readingNoteSaving
                || (reader.readingNoteDraft.id && reader.readingNoteDraft.id !== note.id)) return;
        finishInput();
        reader.pauseReadingNoteAutosave();
        debounce.stop();
        seeding = true;
        const draft = reader.readingNoteDraft;
        editTitle.text = note.title;
        editContent.text = note.content;
        editThoughts.text = note.thoughts;
        // TextEdit can normalize line endings on display. Untouched fields retain
        // their saved bytes, and returning to the displayed editBaseline clears a delta.
        editBaseline = {title: editTitle.text, content: editContent.text, thoughts: editThoughts.text};
        if (draft.id === note.id) {
            editTitle.text = draft.title ?? editBaseline.title;
            editContent.text = draft.content ?? editBaseline.content;
            editThoughts.text = draft.thoughts ?? editBaseline.thoughts;
        }
        editing = true;
        seeding = false;
        editTitle.forceActiveFocus();
    }
    function change(field, value) {
        if (!editing || seeding || !current() || !note) return;
        let draft = reader.readingNoteDraft;
        if (draft.id !== note.id) draft = {id: note.id, expected_modified: note.modified};
        if (value === editBaseline[field]) {
            if (reader.readingNoteSaving) draft[field] = note[field];
            else delete draft[field];
        }
        else draft[field] = value;
        if (Object.keys(draft).length === 2) reader.discardReadingNoteDraft();
        else if (!reader.setReadingNoteDraft(draft)) failure = qsTr("This document changed. The current editor text is still visible.");
    }
    function cancelEditing() {
        if (!current() || command) return;
        reader.discardReadingNoteDraft();
        editing = false;
        failure = "";
        refresh();
    }
    function save() {
        if (!current() || command || !dirty) return;
        failure = "";
        command = reader.saveReadingNoteDraft();
    }
    function beginUpdate() {
        if(!reader || !note)return;
        const owner=reader,generation=notes.generation,id=note.id,modified=note.modified;
        app.requestAiTaskFromUi(owner,"note",function(){return notes.reader===owner && notes.generation===generation
            && !!notes.note && notes.note.id===id && notes.note.modified===modified;},function(){notes.beginUpdateReady();});
    }
    function beginUpdateReady() {
        finishInput();
        if (!noteWriteReady || !note || !canUpdateDiscussion || note.suggestion || editing || reviewing || reviewState.running) return;
        debounce.stop();
        failure = "";
        reviewId = note.id;
        const previous = reader.aiPreviewRevision;
        updateIntent = {reader:reader,generation:generation,id:note.id,modified:note.modified,
            source:JSON.stringify(note.source || {}),turns:regionEntry.completed_turn_count,
            workflow:app.aiReviewRevision,language:app.defaultAiOutputLanguage,revision:"",dispatched:false};
        requestUpdate(reviewId);
        if (reviewState.previewView !== "note" || reader.aiPreviewNoteId !== reviewId
                || !reader.aiPreviewRevision || reader.aiPreviewRevision === previous) {
            updateIntent = null; reviewId = "";
            return;
        }
        updateIntent.revision = reader.aiPreviewRevision;
        Qt.callLater(finishUiUpdate);
    }
    function updateIsCurrent(intent) {
        return !!intent && current() && intent.reader === reader && intent.generation === generation
            && !!note && note.id === intent.id && note.modified === intent.modified && !note.suggestion
            && JSON.stringify(note.source || {}) === intent.source && !!regionEntry
            && regionEntry.completed_turn_count === intent.turns && !editing && !dirty
            && !reader.hasUnsavedReadingNotes && !reader.readingNoteSaving
            && intent.workflow === app.aiReviewRevision && intent.language === app.defaultAiOutputLanguage
            && reviewState.previewView === "note" && reader.aiPreviewNoteId === intent.id
            && reader.aiPreviewRevision === intent.revision;
    }
    function finishUiUpdate() {
        const intent = updateIntent;
        if (!intent || !intent.revision) return;
        if (!updateIsCurrent(intent)) { endPreview(); return; }
        if (intent.dispatched || reader.pendingCommands || !reviewPlan) return;
        intent.dispatched = true;
        if (!app.dispatchAiTaskFromUi(reader,reviewPlan,"note-update",intent.revision)) endPreview();
    }
    function checkUiUpdate() {
        if (updateIntent && updateIntent.revision && !updateIsCurrent(updateIntent)) endPreview();
    }
    function endPreview() {
        const intent = updateIntent;
        // Clear ownership before closing the review window: its cancellation signal is synchronous.
        updateIntent = null;
        if (intent) {
            app.abandonNoteUpdateCredential(intent.reader,intent.revision);
            const ticket = app.aiTaskReviewTicket;
            if (ticket && ticket.reader === intent.reader && ticket.purpose === "note-update" && ticket.token === intent.revision)
                app.cancelAiTaskReview(intent.reader,"note-update");
        }
        const owner = intent ? intent.reader : reader;
        const state = owner ? owner.aiState : ({});
        if (owner && reviewing && !(state.responseView === "note" && state.running)
                && state.previewView === "note" && !state.planSent
                && (intent ? owner.documentGeneration === intent.generation && owner.aiPreviewNoteId === intent.id
                    && owner.aiPreviewRevision === intent.revision : !!reviewPlan)) owner.invalidateAiPlan();
        reviewId = "";
    }
    function resolveSuggestion(apply) {
        if (!noteWriteReady || !note || !note.suggestion || editing || reviewing) return;
        command = reader.submit("ai_reading_note_review", {review: {id: note.id,
            expected_modified: note.modified, expected_suggestion: note.suggestion.revision, apply: apply}});
    }
    function finishUpdate() {
        if (!current() || !reviewing || reviewRunning) return;
        const result = reviewState.noteSuggestion;
        if (result && result.available && result.id === reviewId && !command) {
            updateIntent = null;
            reviewId = "";
            command = reader.submit("ai_reading_note", {id: result.id});
        }
    }
    function reset() {
        finishInput();
        endPreview();
        thoughtsFailureTicket = null;
        sourceFocusTicket = null;
        regionContext = ({}); regionContextCommand = 0;
        continuationContext = null; continuationCommand = 0;
        syncWaiting = false; syncKeepSource = ""; importedRefreshWanted = false;
        importedListCommand = 0; importedDetailCommand = 0; importedDetailTicket = null;
        debounce.stop();
        reviewId = "";
        editing = false;
        reader = null; command = 0; entries = []; note = null; noteOwner = null; noteGeneration = 0; preferred = ""; failure = "";
        search.text = "";
    }
    Connections {
        target: notes.app
        function onAiTaskReviewCancelled(ticket) {
            const intent = notes.updateIntent;
            if (intent && ticket.reader === intent.reader && ticket.purpose === "note-update" && ticket.token === intent.revision)
                notes.endPreview();
        }
        function onAiReviewRevisionChanged() { notes.checkUiUpdate(); }
        function onDefaultAiOutputLanguageChanged() { notes.checkUiUpdate(); }
    }
    Connections {
        target: notes.reader
        function onReadingNotesSynced(result, error) {
            if (!notes.current()) return;
            if (notes.syncWaiting) notes.finishSyncBrowse();
            else if (!error && result.changed) {
                notes.importedRefreshWanted = true;
                Qt.callLater(notes.refreshImportedNotes);
            }
        }
        function onCommandsChanged() { if (notes.importedRefreshWanted) Qt.callLater(notes.refreshImportedNotes); if(notes.updateIntent)Qt.callLater(notes.finishUiUpdate); }
        function onRegionNoteDraftChanged() { notes.checkUiUpdate(); if (notes.importedRefreshWanted) Qt.callLater(notes.refreshImportedNotes); if(notes.updateIntent)Qt.callLater(notes.finishUiUpdate); }
        function onRegionHistoryChanged() {
            if (notes.current() && notes.sourceContext.region_id) notes.regionContext = notes.reader.regionHistory;
            if(notes.updateIntent)Qt.callLater(notes.finishUiUpdate);
        }
        function onAiStateChanged() { if(notes.updateIntent)Qt.callLater(notes.finishUiUpdate); if (notes.reviewing) Qt.callLater(notes.finishUpdate); }
        function onReadingNoteAutosaveFinished(noteId, result, error) {
            if (!notes.current() || error) return;
            notes.mergeNoteMetadata(result);
            if (!notes.editing && notes.note && notes.note.id === noteId) notes.displayNote(result);
            else if (!notes.note && !notes.editing && !notes.reviewing && !notes.command) notes.refresh();
        }
        function onCommandFinished(id, operation, result, error) {
            if (!notes.current()) return;
            if (id === notes.importedListCommand) {
                notes.importedListCommand = 0;
                if (error) { notes.failure = error; return; }
                notes.entries = result;
                if (notes.note && !notes.editing && !notes.reviewing && !notes.command && !notes.dirty && !inlineThoughts.inputComposing) {
                    notes.importedDetailTicket = {id: notes.note.id, modified: notes.note.modified};
                    notes.importedDetailCommand = notes.reader.submit("ai_reading_note", {id: notes.note.id});
                }
                return;
            }
            if (id === notes.importedDetailCommand) {
                notes.importedDetailCommand = 0;
                const ticket = notes.importedDetailTicket; notes.importedDetailTicket = null;
                if (error) { notes.failure = error; return; }
                if (ticket && notes.note && notes.note.id === ticket.id && notes.note.modified === ticket.modified
                        && !notes.editing && !notes.reviewing && !notes.command && !notes.dirty && !inlineThoughts.inputComposing) {
                    notes.mergeNoteMetadata(result); notes.displayNote(result);
                } else notes.importedRefreshWanted = true;
                return;
            }
            if (id === notes.regionContextCommand) {
                notes.regionContextCommand = 0;
                if (error) notes.failure = error;
                else notes.regionContext = result;
                return;
            }
            if (id === notes.continuationCommand) {
                notes.continuationCommand = 0;
                if (error) { notes.continuationContext = null; notes.failure = error; }
                else Qt.callLater(notes.finishContinue);
                return;
            }
            if (id !== notes.command || !notes.current()) return;
            notes.rememberPosition();
            notes.command = 0;
            notes.failure = error;
            if (error) return;
            if (operation === "ai_reading_keep") {
                notes.preferred = result.id;
                notes.refresh();
            } else if (operation === "ai_reading_notes") {
                notes.entries = result;
                const wanted = result.findIndex(entry => entry.id === notes.preferred);
                picker.currentIndex = wanted >= 0 ? wanted : !notes.inlineMode && result.length ? 0 : -1;
                notes.preferred = "";
                notes.read(picker.currentIndex);
            } else if (operation === "ai_reading_note") {
                notes.mergeNoteMetadata(result);
                notes.displayNote(result);
                if (notes.reader.readingNoteDraft.id === result.id && !notes.reader.readingNoteAutomatic) notes.beginEditing();
                else if ((notes.reviewState.running && notes.reviewState.responseView === "note"
                        && notes.reviewState.responsePlan.note_id === result.id)
                    || (notes.reviewState.previewView === "note" && !notes.reviewState.planSent
                        && notes.reviewState.plan && notes.reviewState.plan.note_id === result.id))
                    notes.reviewId = result.id;
            } else if (operation === "ai_reading_note_update") {
                notes.displayNote(result);
                notes.editing = false;
                if (notes.dirty) notes.beginEditing();
                else {
                    app.showReadingNotice(qsTr("Reading note saved"), notes.reader);
                    notes.refresh();
                }
            } else if (operation === "ai_reading_note_review") {
                notes.displayNote(result);
            }
        }
    }
    Connections {
        target: notes.thoughtsFailureTicket ? notes.app : null
        function onFrameSwapped() { Qt.callLater(notes.tryRevealThoughtsFailure); }
    }
    Connections {
        target: notes.sourceFocusTicket ? contents.contentItem : null
        function onContentHeightChanged() { Qt.callLater(notes.tryRevealSourceAction); }
        function onHeightChanged() { Qt.callLater(notes.tryRevealSourceAction); }
    }
    Connections {
        target: notes.sourceFocusTicket ? notes.sourceFocusTicket.item : null
        function onActiveFocusChanged() { Qt.callLater(notes.tryRevealSourceAction); }
        function onHeightChanged() { Qt.callLater(notes.tryRevealSourceAction); }
        function onYChanged() { Qt.callLater(notes.tryRevealSourceAction); }
    }
    Timer { id: debounce; interval: 220; onTriggered: notes.refresh() }

    contentItem: ColumnLayout {
        spacing: notes.inlineMode ? 12 : 6
        RowLayout {
            Layout.fillWidth: true
            visible: !notes.inlineMode || (!notes.note && !notes.editing && !notes.reviewing)
            enabled: !notes.editing && !notes.reviewing
            TextField {
                id: search
                objectName: "aiReadingNoteSearch"
                Layout.fillWidth: true
                placeholderText: qsTr("Search reading notes")
                font.pixelSize: 13
                implicitHeight: 29
                leftPadding: 8; rightPadding: 8; topPadding: 4; bottomPadding: 4
                background: Rectangle {
                    radius: 5; color: app.colors.fieldBg
                    border.color: search.activeFocus ? app.colors.focusRing : app.colors.controlBorder
                    border.width: search.activeFocus ? 2 : 1
                }
                Accessible.name: placeholderText
                onTextEdited: debounce.restart()
                onAccepted: { debounce.stop(); notes.refresh(); }
            }
            ComboBox {
                id: order
                visible: !notes.inlineMode
                model: [qsTr("Recent"), qsTr("Page order")]
                Accessible.name: qsTr("Sort notes")
                onActivated: notes.refresh()
            }
        }
        LyraReadingSegmentedPicker {
            id: ordering
            objectName: "aiReadingNoteOrder"
            app: notes.app
            Layout.fillWidth: true
            visible: notes.inlineMode && !notes.note && !notes.editing && !notes.reviewing
            choices: [{title: qsTr("Page order"), icon: "outline"}, {title: qsTr("Recent"), icon: "history"}]
            Accessible.name: qsTr("Reading note order")
            onActivated: function(index) { currentIndex = index; notes.refresh(); }
        }
        ComboBox {
            id: picker
            visible: !notes.inlineMode
            objectName: "aiSavedReadingNote"
            Layout.fillWidth: true
            model: notes.entries
            textRole: "title"
            enabled: count > 0 && !notes.command && !notes.editing && !notes.reviewing
            Accessible.name: qsTr("Saved notes")
            onActivated: notes.read(currentIndex)
        }
        Label {
            Layout.fillWidth: true
            visible: !!text && (!notes.inlineMode || !!notes.failure || !!notes.command || !!notes.note || notes.automaticDraftPending)
            text: notes.failure || (notes.reviewing ? notes.reviewState.status || ""
                : notes.command ? (notes.editing ? qsTr("Saving reading note…") : qsTr("Loading reading notes…"))
                : !notes.note && notes.automaticDraftPending ? notes.reader.readingNoteSaveError
                    || (notes.reader.regionPersistencePending ? qsTr("Saving thoughts…") : qsTr("Unsaved thoughts"))
                : !notes.entries.length ? qsTr("No matching notes.")
                : "")
            wrapMode: Text.Wrap; textFormat: Text.PlainText; color: app.colors.textSecondary
        }
        RowLayout {
            Layout.fillWidth: true
            visible: notes.current() && !!notes.reader.readingNotesSyncWarning
            Label {
                objectName: "aiReadingNotesImportWarning"
                Layout.fillWidth: true
                text: notes.current() ? notes.reader.readingNotesSyncWarning : ""
                wrapMode: Text.Wrap; textFormat: Text.PlainText; color: app.colors.textSecondary
            }
            NoteAction {
                objectName: "retryAiReadingNotesImport"
                text: qsTr("Retry")
                Accessible.name: qsTr("Retry importing saved notes")
                enabled: notes.noteWriteReady && !notes.editing && !notes.reviewing
                onClicked: if (enabled) notes.reader.requestReadingNotesSync()
            }
        }
        Flow {
            visible: notes.current() && !!notes.reader.readingNoteDraft.id && notes.reader.readingNoteAutomatic
                && (!notes.note || notes.note.id !== notes.reader.readingNoteDraft.id)
                && (!!notes.reader.readingNoteSaveError || !!notes.failure || !notes.reader.regionPersistencePending)
            Layout.fillWidth: true; spacing: 4
            LyraToolButton {
                enabled: !notes.command && !notes.editing && !notes.reviewing
                text: qsTr("Open unsaved thoughts"); display: AbstractButton.TextOnly
                onClicked: {
                    notes.preferred = notes.reader.readingNoteDraft.id;
                    search.text = ""; debounce.stop(); notes.refresh();
                }
            }
            LyraToolButton {
                objectName: "copyDetachedReadingThoughts"
                text: qsTr("Copy unsaved thoughts"); display: AbstractButton.TextOnly
                onClicked: notes.copyUnsavedThoughts()
            }
            LyraToolButton {
                objectName: "discardDetachedReadingThoughts"
                text: qsTr("Discard unsaved thoughts"); display: AbstractButton.TextOnly
                enabled: notes.current() && !notes.command && !notes.reader.readingNoteSaving && !notes.editing && !notes.reviewing
                onClicked: notes.discardThoughts(notes.reader.readingNoteDraft.id)
            }
        }
        ColumnLayout {
            visible: notes.inlineMode && !notes.note && !notes.editing && !notes.reviewing && !notes.command && !notes.failure && !notes.entries.length
            Layout.fillWidth: true; Layout.fillHeight: true
            spacing: 8
            Item { Layout.fillHeight: true }
            Label { text: search.text.length ? qsTr("No matching notes") : qsTr("Keep the ideas you discover"); Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 14; font.weight: Font.DemiBold; color: app.colors.textPrimary }
            Label { text: search.text.length ? qsTr("Try another search or clear the search field.") : qsTr("Save a summary, a Chat answer, or finish an Interleaf discussion."); Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 12; color: app.colors.textSecondary }
            Item { Layout.fillHeight: true }
        }
        ListView {
            id: noteList
            objectName: "aiReadingNoteList"
            visible: notes.inlineMode && !notes.note && !notes.editing && !notes.reviewing && notes.entries.length > 0
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true
            model: notes.entries
            boundsBehavior: Flickable.StopAtBounds
            ReadingScrollMemory {
                id: listMemory
                reader: notes.reader; key: "notes"; viewport: noteList
                active: noteList.visible; ready: notes.current() && !notes.command
            }
            PanelWheelHandler { viewport: noteList; onScrollIntent: listMemory.userIntent(); onScrollApplied: listMemory.completeUserScroll() }
            Connections { target: noteBar; function onPressedChanged() { if (noteBar.pressed) listMemory.userIntent(); } }
            ScrollBar.vertical: AiReadingScrollBar { id: noteBar }
            delegate: Button {
                id: entryButton
                required property var modelData
                required property int index
                objectName: "aiReadingNoteRow" + index
                readonly property string sourceDescription: notes.sourceLabel(modelData)
                width: Math.max(0, noteList.width - noteBar.gutterWidth)
                padding: 0; topPadding: 14; bottomPadding: 14
                enabled: !notes.command
                Accessible.name: notes.sourceLabel(modelData) + ": " + modelData.title
                onClicked: notes.read(index)
                background: Rectangle {
                    color: entryButton.down ? app.colors.pressedBg : entryButton.hovered ? app.colors.hoverBg : "transparent"
                    border.width: entryButton.visualFocus ? 2 : 0; border.color: app.colors.focusRing
                }
                contentItem: ColumnLayout {
                    spacing: 6
                    Label { text: notes.sourceLabel(entryButton.modelData); textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: 11; color: app.colors.textSecondary }
                    Label { text: entryButton.modelData.title; textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight; Layout.fillWidth: true; font.pixelSize: 14; font.weight: Font.DemiBold; color: app.colors.textPrimary }
                    Label { text: entryButton.modelData.content; textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight; Layout.fillWidth: true; font.pixelSize: 12; color: app.colors.textSecondary }
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: app.colors.separator }
            }
        }
        AiReadingScrollView {
            id: contents
            memoryReader: notes.reader
            memoryKey: notes.note ? "note-" + notes.note.id : ""
            memoryReady: notes.current() && !notes.command
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: !notes.editing && (!notes.reviewing || !!notes.updateIntent) && !!notes.note
            objectName: "aiReadingNoteDetailScroll"
            ColumnLayout {
                id: noteFlow
                objectName: "aiReadingNoteDetailFlow"
                width: contents.availableWidth
                spacing: 18
                RowLayout {
                    Layout.fillWidth: true
                    LyraToolButton {
                        objectName: "backToReadingNotes"
                        symbol: "back"; text: qsTr("All notes"); display: AbstractButton.TextBesideIcon
                        enabled: !notes.command
                        onClicked: notes.backToList()
                    }
                    Item { Layout.fillWidth: true }
                    Label {
                        text: notes.dirty ? notes.reader.readingNoteSaving ? qsTr("Saving…") : qsTr("Unsaved") : qsTr("Saved")
                        font.pixelSize: 11; color: app.colors.textSecondary
                    }
                }
                TextArea {
                    objectName: "aiReadingNoteTitle"
                    text: notes.note ? notes.note.title : ""
                    textFormat: TextEdit.PlainText; wrapMode: Text.Wrap
                    readOnly: true; selectByMouse: true; selectByKeyboard: true
                    Accessible.name: qsTr("Saved note title")
                    Layout.fillWidth: true; font.pixelSize: 16; font.weight: Font.DemiBold
                    padding: 0; color: app.colors.textPrimary
                    background: null
                }
                Label {
                    objectName: "aiReadingNoteSourceLabel"
                    text: notes.sourceLabel(notes.sourceEntry)
                    textFormat: Text.PlainText; wrapMode: Text.Wrap
                    Layout.fillWidth: true; font.pixelSize: 11; color: app.colors.textSecondary
                }
                NoteAction {
                    objectName: "editAiReadingNote"
                    text: qsTr("Edit note")
                    enabled: notes.current() && !notes.command && !notes.reviewing && !notes.reader.documentRevisionPending && !notes.reader.readingNoteSaving
                        && (!notes.reader.readingNoteDraft.id || notes.reader.readingNoteDraft.id === notes.selectedNoteId)
                    onClicked: notes.beginEditing()
                }
                NoteAction {
                    objectName: "previewAiReadingNoteUpdate"
                    visible: !!(notes.note && notes.canUpdateDiscussion && !notes.note.suggestion)
                    text: qsTr("Update from conversation")
                    Accessible.description: qsTr("Review the exact request before sending.")
                    enabled: notes.noteWriteReady && !notes.reviewing && !notes.reviewState.running
                    onClicked: notes.beginUpdate()
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: !!(notes.note && notes.note.suggestion)
                    spacing: 8
                    Button {
                        id: suggestionHeader
                        Layout.fillWidth: true; Layout.minimumWidth: 0
                        objectName: "expandAiReadingNoteSuggestion"
                        padding: 0
                        implicitHeight: Math.max(30, implicitContentHeight)
                        Accessible.name: qsTr("Conversation updated · review new ideas")
                        Accessible.description: notes.suggestionExpanded ? qsTr("Expanded") : qsTr("Collapsed")
                        contentItem: RowLayout {
                            spacing: 7
                            Label { text: notes.suggestionExpanded ? "⌄" : "›"; font.pixelSize: 10; color: app.colors.textSecondary }
                            Label {
                                text: suggestionHeader.Accessible.name
                                Layout.fillWidth: true; Layout.minimumWidth: 0
                                textFormat: Text.PlainText; wrapMode: Text.Wrap
                                font.pixelSize: 13; font.weight: Font.DemiBold; color: app.colors.textPrimary
                            }
                        }
                        background: Rectangle { color: "transparent"; radius: 3; border.width: suggestionHeader.visualFocus ? 2 : 0; border.color: app.colors.focusRing }
                        onClicked: notes.suggestionExpanded = !notes.suggestionExpanded
                    }
                    TextArea {
                        objectName: "aiReadingNoteSuggestion"
                        visible: notes.suggestionExpanded
                        Layout.fillWidth: true
                        text: notes.note && notes.note.suggestion ? notes.note.suggestion.content : ""
                        readOnly: true; selectByMouse: true; selectByKeyboard: true
                        textFormat: TextEdit.PlainText; wrapMode: Text.Wrap
                        Accessible.name: qsTr("Suggested key ideas")
                        color: app.colors.textPrimary
                        padding: 12
                        background: Rectangle { radius: 8; color: app.colors.fieldBg }
                    }
                    Flow {
                        visible: notes.suggestionExpanded
                        Layout.fillWidth: true; spacing: 4
                        NoteAction {
                            objectName: "applyAiReadingNoteSuggestion"
                            text: qsTr("Apply suggestion")
                            enabled: notes.noteWriteReady
                            onClicked: notes.resolveSuggestion(true)
                        }
                        NoteAction {
                            objectName: "dismissAiReadingNoteSuggestion"
                            text: qsTr("Keep current note")
                            enabled: notes.noteWriteReady
                            onClicked: notes.resolveSuggestion(false)
                        }
                    }
                }
                Label {
                    objectName: "aiReadingNoteIdeasHeading"
                    text: qsTr("Key ideas"); font.pixelSize: 13; font.weight: Font.DemiBold
                    color: app.colors.textPrimary
                }
                AiResult {
                    Layout.fillWidth: true
                    app: notes.app
                    answerName: "aiReadingNoteContent"
                    answerAccessibleName: qsTr("Saved reading note")
                    value: ({output: notes.note ? notes.note.content : "", generation: notes.generation,
                        responsePlan: {source_pages: notes.note ? notes.note.source_pages : []}})
                    showActions: false; inlineConversation: true
                    viewport: contents.contentItem
                    onCitation: function(link, plan) { notes.followCitation(link, plan); }
                }
                Label {
                    text: qsTr("My thoughts"); font.pixelSize: 13; font.weight: Font.DemiBold
                    color: app.colors.textPrimary
                }
                AiReadingThoughts {
                    id: inlineThoughts
                    objectName: "aiReadingThoughts"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 112
                    app: notes.app; reader: notes.noteOwner; generation: notes.noteGeneration; note: notes.note
                    wheelParent: contents
                    onInputComposingChanged: if (!inputComposing && notes.importedRefreshWanted) Qt.callLater(notes.refreshImportedNotes)
                    allowInput: notes.current() && !notes.command && !notes.reader.documentRevisionPending
                        && (!notes.reader.readingNoteDraft.id || (notes.reader.readingNoteDraft.id === notes.selectedNoteId && notes.reader.readingNoteAutomatic))
                }
                Label {
                    id: thoughtsFailure
                    Layout.fillWidth: true
                    visible: !!text
                    text: inlineThoughts.failure || (notes.dirty && notes.reader.readingNoteAutomatic ? notes.reader.readingNoteSaveError : "")
                    wrapMode: Text.Wrap; textFormat: Text.PlainText; color: app.colors.warningFg
                }
                Flow {
                    id: thoughtsErrorActions
                    Layout.fillWidth: true; spacing: 4
                    visible: notes.dirty && notes.reader.readingNoteAutomatic && !!notes.reader.readingNoteSaveError
                    onVisibleChanged: {
                        if (visible) notes.revealThoughtsFailure();
                        else notes.thoughtsFailureTicket = null;
                    }
                    NoteAction {
                        objectName: "retryAiReadingThoughts"
                        text: qsTr("Save thoughts again")
                        enabled: notes.current() && !notes.reader.readingNoteSaving && !notes.reader.documentRevisionPending
                        onClicked: { notes.finishInput(); notes.reader.saveReadingNoteDraft(); }
                    }
                    NoteAction {
                        objectName: "discardAiReadingThoughts"
                        text: qsTr("Discard unsaved thoughts")
                        enabled: notes.current() && !notes.reader.readingNoteSaving
                        onClicked: notes.discardThoughts(notes.selectedNoteId)
                    }
                }
                Label {
                    visible: !!(notes.note && notes.note.status === "sourceChanged")
                    Layout.fillWidth: true
                    text: qsTr("The source document has changed. The saved knowledge and source snapshot are preserved.")
                    textFormat: Text.PlainText; wrapMode: Text.Wrap
                    font.pixelSize: 11; color: app.colors.warningFg
                }
                ColumnLayout {
                    visible: !notes.sourceContext.whole_document && !!notes.sourceContext.excerpt
                    Layout.fillWidth: true; spacing: 8
                    AiReadingDisclosure {
                        id: sourceDisclosure
                        objectName: "expandAiReadingNoteSource"
                        app: notes.app; text: qsTr("Source")
                        Layout.fillWidth: true
                        onActiveFocusChanged: if (activeFocus) notes.revealSourceAction(sourceDisclosure)
                    }
                    TextArea {
                        id: savedExcerpt
                        objectName: "aiReadingNoteExcerpt"
                        visible: sourceDisclosure.expanded
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(implicitHeight, excerptMetrics.lineSpacing * 8)
                        text: notes.sourceContext.excerpt || ""
                        textFormat: TextEdit.PlainText; wrapMode: Text.Wrap
                        readOnly: true; selectByMouse: true; selectByKeyboard: true
                        font.pixelSize: 11; padding: 0; clip: true
                        color: app.colors.textSecondary; background: null
                        Accessible.name: qsTr("Saved source excerpt")
                        FontMetrics { id: excerptMetrics; font: savedExcerpt.font }
                    }
                }
                AiHorizontalReadingView {
                    id: sourcePages
                    objectName: "aiReadingNoteSourceActions"
                    viewName: "aiReadingNoteSources"
                    app: notes.app; surfaceVisible: false; showIndicator: false
                    renderer: ({viewport: contents.contentItem, scrollParent: function(dy) { contents.applyReadingWheel(0, dy); }})
                    measuredWidth: sourceButtons.implicitWidth; measuredHeight: sourceButtons.implicitHeight
                    visible: !!notes.sourceContext.whole_document || !!(notes.note && (notes.note.source_pages || []).length)
                    Layout.fillWidth: true
                    RowLayout {
                        id: sourceButtons
                        spacing: 4
                        NoteAction {
                            id: locateWholeDocument
                            objectName: "locateAiReadingWholeDocument"
                            visible: !!notes.sourceContext.whole_document
                            text: qsTr("Locate whole document")
                            enabled: notes.current() && !!notes.sourceContext.can_locate_document
                            onActiveFocusChanged: if (activeFocus) notes.revealSourceAction(locateWholeDocument)
                            onClicked: if (enabled) app.navigate(0)
                        }
                        Repeater {
                            model: notes.sourceContext.whole_document ? [] : notes.note ? notes.note.source_pages || [] : []
                            NoteAction {
                                id: sourcePage
                                required property int modelData
                                objectName: "aiReadingNoteSourcePage" + modelData
                                display: AbstractButton.TextOnly
                                text: qsTr("p. %1").arg(modelData)
                                enabled: notes.current()
                                onActiveFocusChanged: if (activeFocus) {
                                    const x = mapToItem(sourcePages.contentItem, 0, 0).x;
                                    if (x < sourcePages.contentX) sourcePages.contentX = x;
                                    else if (x + width > sourcePages.contentX + sourcePages.width)
                                        sourcePages.contentX = x + width - sourcePages.width;
                                    notes.revealSourceAction(sourcePage);
                                }
                                onClicked: notes.locateSource(modelData)
                            }
                        }
                    }
                }
                ColumnLayout {
                    visible: !!notes.sourceContext.question
                    Layout.fillWidth: true; spacing: 8
                    AiReadingDisclosure {
                        id: conversationDisclosure
                        objectName: "expandAiReadingNoteConversation"
                        app: notes.app; text: qsTr("View conversation")
                        Layout.fillWidth: true
                        onActiveFocusChanged: if (activeFocus) notes.revealSourceAction(conversationDisclosure)
                    }
                    TextArea {
                        objectName: "aiReadingNoteOriginalQuestion"
                        visible: conversationDisclosure.expanded
                        Layout.fillWidth: true
                        text: notes.sourceContext.question || ""
                        textFormat: TextEdit.PlainText; wrapMode: Text.Wrap
                        readOnly: true; selectByMouse: true; selectByKeyboard: true
                        font.pixelSize: 13; padding: 0; color: app.colors.textPrimary; background: null
                    }
                    Loader {
                        Layout.fillWidth: true
                        active: conversationDisclosure.expanded && !!notes.sourceContext.answer
                        visible: active
                        sourceComponent: AiResult {
                            Layout.fillWidth: true
                            app: notes.app; answerName: "aiReadingNoteOriginalAnswer"
                            answerAccessibleName: qsTr("Original conversation answer")
                            value: ({output: notes.sourceContext.answer ? notes.sourceContext.answer.content : "", generation: notes.generation,
                                responsePlan: {source_pages: notes.sourceContext.answer ? notes.sourceContext.answer.source_pages : []}})
                            showActions: false; inlineConversation: true; viewport: contents.contentItem
                            onCitation: function(link, plan) {
                                if (!notes.current() || plan.generation !== notes.generation) return;
                                const match = /^p\.(\d+)$/.exec(link);
                                if (match && notes.sourceContext.answer && notes.sourceContext.answer.source_pages.indexOf(Number(match[1])) >= 0)
                                    app.navigate(Number(match[1]) - 1);
                            }
                        }
                    }
                }
                NoteAction {
                    id: continueNote
                    objectName: "continueAiReadingNoteConversation"
                    visible: !!notes.regionEntry || !!notes.sourceContext.chat_id
                    text: notes.regionEntry ? qsTr("Continue at source") : qsTr("Continue conversation")
                    enabled: notes.noteWriteReady && !notes.continuationCommand && !notes.reviewState.running
                    onActiveFocusChanged: if (activeFocus) notes.revealSourceAction(continueNote)
                    onClicked: notes.continueConversation()
                }
                Label {
                    Layout.fillWidth: true
                    visible: !!notes.sourceContext.region_id && (!!notes.regionContext.error || !!notes.regionContext.writes_blocked)
                    text: notes.regionContext.error || qsTr("Saved discussions are protected. Resolve the history warning before continuing.")
                    textFormat: Text.PlainText; wrapMode: Text.Wrap; font.pixelSize: 11; color: app.colors.warningFg
                }
            }
        }
        Label {
            visible: notes.reviewing && !notes.updateIntent && !!notes.reviewPlan
            Layout.fillWidth: true
            text: notes.reviewPlan ? qsTr("Endpoint: %1 · %2 request(s)").arg(notes.reviewPlan.host).arg(notes.reviewPlan.parts.length) : ""
            wrapMode: Text.Wrap; textFormat: Text.PlainText
            color: app.colors.infoFg
        }
        AiReadingScrollView {
            id: reviewedRequest
            visible: notes.reviewing && !notes.updateIntent && !!notes.reviewPlan
            Layout.fillWidth: true; Layout.fillHeight: true
            TextArea {
                objectName:"aiReadingNoteWire"
                width: reviewedRequest.availableWidth
                text: notes.reviewPlan ? notes.reviewPlan.parts.map(part => part.wire_body).join("\n\n") : ""
                readOnly: true; selectByMouse: true; selectByKeyboard: true
                textFormat: TextEdit.PlainText; wrapMode: Text.WrapAnywhere
                Accessible.name: qsTr("Exact request to update reading note")
            }
        }
        AiReadingScrollView {
            id: editDetails
            objectName: "aiReadingNoteEditScroll"
            memoryReader: notes.reader; memoryKey: notes.note ? "note-edit-" + notes.note.id : ""
            memoryReady: notes.current() && !notes.command
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: notes.editing; enabled: !notes.command
            ColumnLayout {
                id: editFlow
                objectName: "aiReadingNoteEditFlow"
                width: editDetails.availableWidth; spacing: 18
                TextField {
                    id: editTitle
                    objectName: "aiReadingNoteTitleEditor"
                    Layout.fillWidth: true
                    placeholderText: qsTr("Title"); Accessible.name: placeholderText
                    onTextEdited: notes.change("title", text)
                    onActiveFocusChanged: if (activeFocus) notes.revealEditInput(editTitle, editTitle)
                }
                Label { text: qsTr("Key ideas"); font.pixelSize: 13; font.weight: Font.DemiBold; color: app.colors.textPrimary }
                AiReadingScrollView {
                    id: keyIdeas
                    Layout.fillWidth: true; Layout.preferredHeight: 220
                    wheelParent: editDetails
                    TextArea {
                        id: editContent
                        objectName: "aiReadingNoteContentEditor"
                        width: keyIdeas.availableWidth; height: Math.max(keyIdeas.availableHeight, implicitHeight)
                        placeholderText: qsTr("Key ideas"); Accessible.name: placeholderText
                        textFormat: TextEdit.PlainText; wrapMode: Text.Wrap
                        padding: 6
                        background: Rectangle { radius: 8; color: app.colors.fieldBg }
                        onTextChanged: if (activeFocus) notes.change("content", text)
                        onActiveFocusChanged: if (activeFocus) notes.revealEditInput(keyIdeas, editContent)
                    }
                }
                Label { text: qsTr("My thoughts"); font.pixelSize: 13; font.weight: Font.DemiBold; color: app.colors.textPrimary }
                AiReadingScrollView {
                    id: thoughts
                    Layout.fillWidth: true; Layout.preferredHeight: 112
                    wheelParent: editDetails
                    TextArea {
                        id: editThoughts
                        objectName: "aiReadingNoteThoughtsEditor"
                        width: thoughts.availableWidth; height: Math.max(thoughts.availableHeight, implicitHeight)
                        placeholderText: qsTr("My thoughts"); Accessible.name: placeholderText
                        textFormat: TextEdit.PlainText; wrapMode: Text.Wrap
                        padding: 10
                        background: Rectangle { radius: 8; color: app.colors.noteBg }
                        onTextChanged: if (activeFocus) notes.change("thoughts", text)
                        onActiveFocusChanged: if (activeFocus) notes.revealEditInput(thoughts, editThoughts)
                    }
                }
                RowLayout {
                    id: editActions
                    objectName: "aiReadingNoteEditActions"
                    Layout.fillWidth: true; spacing: 4
                    ReadingPrimaryButton {
                        app: notes.app
                        Layout.fillWidth: true
                        font.pixelSize: 12; font.weight: Font.Medium
                        id: saveEditNote
                        objectName: "saveAiReadingNote"
                        text: qsTr("Save changes")
                        enabled: !notes.command && notes.dirty
                        onClicked: { notes.finishInput(); notes.save(); }
                        onActiveFocusChanged: if (activeFocus) notes.revealEditInput(editActions, saveEditNote)
                    }
                    NoteAction {
                        id: cancelEditNote
                        text: qsTr("Cancel")
                        Accessible.name: qsTr("Cancel editing note")
                        enabled: !notes.command
                        onClicked: notes.cancelEditing()
                        onActiveFocusChanged: if (activeFocus) notes.revealEditInput(editActions, cancelEditNote)
                    }
                }
            }
        }
        RowLayout {
            visible: notes.reviewing
            Layout.alignment: Qt.AlignRight
            Button {
                text: qsTr("Back to note")
                visible: !notes.reviewRunning
                onClicked: notes.endPreview()
            }
            Button {
                objectName: "sendAiReadingNoteUpdate"
                text: notes.reviewPlan && notes.reviewPlan.consolidation ? qsTr("Send note synthesis") : qsTr("Send")
                visible: !notes.updateIntent && !!notes.reviewPlan && !notes.reviewState.planSent
                enabled: notes.current() && !notes.reader.pendingCommands && !notes.reviewState.running
                onClicked: app.sendAi(notes.reader, notes.reviewPlan)
            }
            Button {
                text: qsTr("Stop")
                visible: notes.reviewRunning
                onClicked: notes.reader.cancelAi()
            }
        }
        LyraToolButton {
            objectName: "openInterleafDiscussions"
            visible: notes.inlineMode && !notes.note && !notes.editing && !notes.reviewing
            symbol: "interleaf"; text: qsTr("Interleaf discussions…"); display: AbstractButton.TextBesideIcon
            onClicked: app.openRegionNotes()
        }
    }
}

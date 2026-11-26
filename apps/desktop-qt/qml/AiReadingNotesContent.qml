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
    property bool suggestionExpanded: false
    property var thoughtsFailureTicket: null
    readonly property string selectedNoteId: note ? note.id : ""
    readonly property var sourceEntry: note ? entries.find(entry => entry.id === note.id) || note : ({})
    onSelectedNoteIdChanged: { suggestionExpanded = false; thoughtsFailureTicket = null; }
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
    signal requestUpdate(string noteId)

    function displayNote(value) {
        noteOwner = reader; noteGeneration = generation; note = value;
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
    function browse(source, noteId = "") {
        reader = app.currentReader;
        generation = reader.documentGeneration;
        preferred = noteId;
        const draft = reader.readingNoteDraft;
        if (draft.id) {
            preferred = draft.id;
            refresh();
        } else if (source) command = reader.submit("ai_reading_keep", {id: source});
        else refresh();
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
        if (!current() || !note || command || reader.documentRevisionPending || reader.readingNoteSaving
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
        if (!noteWriteReady || !note || !note.discussion_available || note.suggestion || editing || reviewState.running) return;
        debounce.stop();
        failure = "";
        reviewId = note.id;
        requestUpdate(reviewId);
    }
    function endPreview() {
        if (reader && reviewing && !reviewRunning && reviewState.previewView === "note" && !reviewState.planSent)
            reader.invalidateAiPlan();
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
            reviewId = "";
            command = reader.submit("ai_reading_note", {id: result.id});
        }
    }
    function reset() {
        finishInput();
        thoughtsFailureTicket = null;
        debounce.stop();
        reviewId = "";
        editing = false;
        reader = null; command = 0; entries = []; note = null; noteOwner = null; noteGeneration = 0; preferred = ""; failure = "";
        search.text = "";
    }
    Connections {
        target: notes.reader
        function onAiStateChanged() { if (notes.reviewing) Qt.callLater(notes.finishUpdate); }
        function onReadingNoteAutosaveFinished(noteId, result, error) {
            if (!notes.current() || error) return;
            notes.entries = notes.entries.map(entry => entry.id === noteId ? Object.assign({}, entry, result) : entry);
            if (!notes.editing && notes.note && notes.note.id === noteId) notes.displayNote(result);
            else if (!notes.note && !notes.editing && !notes.reviewing && !notes.command) notes.refresh();
        }
        function onCommandFinished(id, operation, result, error) {
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
                notes.entries = notes.entries.map(entry => entry.id === result.id ? Object.assign({}, entry, result) : entry);
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
            visible: !notes.editing && !notes.reviewing && !!notes.note
            objectName: "aiReadingNoteDetailScroll"
            ColumnLayout {
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
                Button {
                    objectName: "editAiReadingNote"
                    text: qsTr("Edit note")
                    enabled: notes.current() && !notes.command && !notes.reader.documentRevisionPending && !notes.reader.readingNoteSaving
                        && (!notes.reader.readingNoteDraft.id || notes.reader.readingNoteDraft.id === notes.selectedNoteId)
                    onClicked: notes.beginEditing()
                }
                Button {
                    objectName: "previewAiReadingNoteUpdate"
                    visible: !!(notes.note && notes.note.discussion_available && !notes.note.suggestion)
                    text: qsTr("Preview update from discussion")
                    enabled: notes.noteWriteReady && !notes.reviewState.running
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
                        Button {
                            objectName: "applyAiReadingNoteSuggestion"
                            text: qsTr("Apply suggestion")
                            enabled: notes.noteWriteReady
                            onClicked: notes.resolveSuggestion(true)
                        }
                        Button {
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
                    Button {
                        objectName: "retryAiReadingThoughts"
                        text: qsTr("Save thoughts again")
                        enabled: notes.current() && !notes.reader.readingNoteSaving && !notes.reader.documentRevisionPending
                        onClicked: { notes.finishInput(); notes.reader.saveReadingNoteDraft(); }
                    }
                    Button {
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
                Flow {
                    objectName: "aiReadingNoteSourceActions"
                    Layout.fillWidth: true; spacing: 4
                    ComboBox {
                        id: sources
                        objectName: "aiReadingNotePages"
                        model: (notes.note ? notes.note.source_pages : []).map(page => qsTr("Page %1").arg(page))
                        visible: count > 0
                        Accessible.name: qsTr("Source page")
                    }
                    Button {
                        text: qsTr("Go to source")
                        visible: sources.count > 0
                        enabled: notes.current() && sources.currentIndex >= 0
                        onClicked: {
                            const page = notes.note.source_pages[sources.currentIndex] - 1;
                            if (notes.current() && page >= 0 && page < notes.reader.pageCount) {
                                app.navigate(page);
                                notes.close();
                            }
                        }
                    }
                }
            }
        }
        Label {
            visible: notes.reviewing && !!notes.reviewPlan
            Layout.fillWidth: true
            text: notes.reviewPlan ? qsTr("Endpoint: %1 · %2 request(s)").arg(notes.reviewPlan.host).arg(notes.reviewPlan.parts.length) : ""
            wrapMode: Text.Wrap; textFormat: Text.PlainText
            color: app.colors.infoFg
        }
        AiReadingScrollView {
            id: reviewedRequest
            visible: notes.reviewing && !!notes.reviewPlan
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
                Flow {
                    id: editActions
                    objectName: "aiReadingNoteEditActions"
                    Layout.fillWidth: true; spacing: 4
                    Button {
                        id: saveEditNote
                        objectName: "saveAiReadingNote"
                        text: qsTr("Save changes")
                        enabled: !notes.command && notes.dirty
                        onClicked: { notes.finishInput(); notes.save(); }
                        onActiveFocusChanged: if (activeFocus) notes.revealEditInput(editActions, saveEditNote)
                    }
                    Button {
                        id: cancelEditNote
                        text: qsTr("Cancel editing")
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
                visible: !!notes.reviewPlan && !notes.reviewState.planSent
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

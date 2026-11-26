import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: notes
    objectName: "aiReadingNotesContent"
    required property var app
    property var reader: null
    property double generation: 0
    property double command: 0
    property var entries: []
    property var note: null
    property string preferred: ""
    property string failure: ""
    property bool editing: false
    property bool seeding: false
    property var editBaseline: ({})
    property string reviewId: ""
    readonly property bool reviewing: reviewId.length > 0
    readonly property var reviewState: reader ? reader.aiState : ({})
    readonly property var reviewPlan: reviewing && reviewState.previewView === "note"
        && reviewState.plan && reviewState.plan.note_id === reviewId ? reviewState.plan : null
    readonly property bool reviewRunning: reviewing && reviewState.responseView === "note" && !!reviewState.running
    readonly property bool dirty: !!(reader && note && reader.readingNoteDraft.id === note.id)
    background: Rectangle { color: app.colors.panelBg }
    property bool inlineMode: false
    signal closeRequested()
    function close() { closeRequested(); }
    function copyAll() {
        if (app.session) app.session.copyText(entries.map(entry => "# " + entry.title + "\n\n" + entry.content + "\n\n" + entry.thoughts).join("\n\n---\n\n"));
    }
    function sourceLabel(entry) {
        if (entry.origin_kind === "summary" && entry.origin_scope === "document") return qsTr("Summary · Whole document");
        const kind = String(entry.source_id || "").startsWith("interleaf:") ? qsTr("Interleaf")
            : entry.origin_kind === "summary" ? qsTr("Summary") : entry.origin_kind === "message" ? qsTr("Chat") : qsTr("Reading note");
        const pages = (entry.source_pages || []).map(page => qsTr("p. %1").arg(page)).join(", ");
        return kind + (pages.length ? " · " + pages : entry.status === "sourceChanged" ? " · " + qsTr("Earlier PDF revision") : "");
    }
    signal requestUpdate(string noteId)

    function current() {
        return reader && reader === app.currentReader && generation === reader.documentGeneration;
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
    function refresh() {
        if (!current() || editing || reviewing) return;
        preferred = preferred || (note ? note.id : "");
        note = null;
        failure = "";
        command = reader.submit("ai_reading_notes", {query: search.text, recent: notes.inlineMode ? ordering.currentIndex === 1 : order.currentIndex === 0});
    }
    function read(index) {
        if (!current() || editing || reviewing || index < 0 || index >= entries.length) return;
        note = null;
        failure = "";
        command = reader.submit("ai_reading_note", {id: entries[index].id});
    }
    function beginEditing() {
        if (!current() || !note || command || reader.documentRevisionPending) return;
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
        if (value === editBaseline[field]) delete draft[field];
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
        if (!current() || !note || !note.discussion_available || note.suggestion || editing || command || reviewState.running) return;
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
        if (!current() || !note || !note.suggestion || editing || reviewing || command) return;
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
        debounce.stop();
        reviewId = "";
        editing = false;
        reader = null; command = 0; entries = []; note = null; preferred = ""; failure = "";
        search.text = "";
    }
    Connections {
        target: notes.reader
        function onAiStateChanged() { if (notes.reviewing) Qt.callLater(notes.finishUpdate); }
        function onCommandFinished(id, operation, result, error) {
            if (id !== notes.command || !notes.current()) return;
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
                notes.note = result;
                if (notes.reader.readingNoteDraft.id === result.id) notes.beginEditing();
                else if ((notes.reviewState.running && notes.reviewState.responseView === "note"
                        && notes.reviewState.responsePlan.note_id === result.id)
                    || (notes.reviewState.previewView === "note" && !notes.reviewState.planSent
                        && notes.reviewState.plan && notes.reviewState.plan.note_id === result.id))
                    notes.reviewId = result.id;
            } else if (operation === "ai_reading_note_update") {
                notes.note = result;
                notes.editing = false;
                if (notes.dirty) notes.beginEditing();
                else notes.refresh();
            } else if (operation === "ai_reading_note_review") {
                notes.note = result;
            }
        }
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
        LyraToolButton {
            objectName: "backToReadingNotes"
            visible: notes.inlineMode && !!notes.note && !notes.editing && !notes.reviewing
            symbol: "back"; text: qsTr("All notes"); display: AbstractButton.TextBesideIcon
            onClicked: { notes.note = null; notes.preferred = ""; notes.refresh(); }
        }
        Label {
            visible: notes.inlineMode && !!notes.note && !notes.editing && !notes.reviewing
            text: notes.note ? notes.note.title : ""
            textFormat: Text.PlainText; wrapMode: Text.Wrap
            Layout.fillWidth: true; font.pixelSize: 16; font.weight: Font.DemiBold
            color: app.colors.textPrimary
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
            visible: !!text && (!notes.inlineMode || !!notes.failure || !!notes.command || !!notes.note)
            text: notes.failure || (notes.reviewing ? notes.reviewState.status || ""
                : notes.command ? (notes.editing ? qsTr("Saving reading note…") : qsTr("Loading reading notes…"))
                : !notes.entries.length ? qsTr("No matching notes.")
                : notes.note && notes.note.status === "sourceChanged" ? qsTr("Note from an earlier PDF revision.") : "")
            wrapMode: Text.Wrap; textFormat: Text.PlainText; color: app.colors.textSecondary
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
            PanelWheelHandler { viewport: noteList }
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
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: !notes.editing && !notes.reviewing && !!notes.note
            Column {
                width: contents.availableWidth
                TextArea {
                    objectName: "aiReadingNoteContent"
                    width: parent.width
                    text: notes.note ? notes.note.content : ""
                    readOnly: true; selectByMouse: true; selectByKeyboard: true
                    textFormat: TextEdit.PlainText; wrapMode: Text.Wrap
                    Accessible.name: qsTr("Saved reading note")
                    color: app.colors.textPrimary
                }
                Label {
                    visible: notes.note && !!notes.note.suggestion
                    text: qsTr("Suggested key ideas")
                    font.bold: true
                    color: app.colors.textSecondary
                }
                TextArea {
                    objectName: "aiReadingNoteSuggestion"
                    visible: !!text
                    width: parent.width
                    text: notes.note && notes.note.suggestion ? notes.note.suggestion.content : ""
                    readOnly: true; selectByMouse: true; selectByKeyboard: true
                    textFormat: TextEdit.PlainText; wrapMode: Text.Wrap
                    Accessible.name: qsTr("Suggested key ideas")
                    color: app.colors.textPrimary
                }
                Label {
                    visible: notes.note && !!notes.note.thoughts
                    text: qsTr("My thoughts")
                    color: app.colors.textSecondary
                }
                TextArea {
                    visible: !!text
                    width: parent.width
                    text: notes.note ? notes.note.thoughts : ""
                    readOnly: true; selectByMouse: true; selectByKeyboard: true
                    textFormat: TextEdit.PlainText; wrapMode: Text.Wrap
                    Accessible.name: qsTr("My thoughts")
                    color: app.colors.textPrimary
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
        ColumnLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: notes.editing
            enabled: !notes.command
            TextField {
                id: editTitle
                objectName: "aiReadingNoteTitleEditor"
                Layout.fillWidth: true
                placeholderText: qsTr("Title")
                Accessible.name: placeholderText
                onTextEdited: notes.change("title", text)
            }
            AiReadingScrollView {
                id: keyIdeas
                Layout.fillWidth: true; Layout.fillHeight: true
                TextArea {
                    id: editContent
                    objectName: "aiReadingNoteContentEditor"
                    width: keyIdeas.availableWidth
                    placeholderText: qsTr("Key ideas")
                    Accessible.name: placeholderText
                    textFormat: TextEdit.PlainText
                    wrapMode: Text.Wrap
                    onTextChanged: if (activeFocus) notes.change("content", text)
                }
            }
            AiReadingScrollView {
                id: thoughts
                Layout.fillWidth: true; Layout.fillHeight: true
                TextArea {
                    id: editThoughts
                    objectName: "aiReadingNoteThoughtsEditor"
                    width: thoughts.availableWidth
                    placeholderText: qsTr("My thoughts")
                    Accessible.name: placeholderText
                    textFormat: TextEdit.PlainText
                    wrapMode: Text.Wrap
                    onTextChanged: if (activeFocus) notes.change("thoughts", text)
                }
            }
        }
        RowLayout {
            visible: !notes.editing && !notes.reviewing && !!notes.note
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
            Item { Layout.fillWidth: true }
            Button {
                objectName: "editAiReadingNote"
                text: qsTr("Edit note")
                enabled: notes.current() && !notes.command && !notes.reader.documentRevisionPending
                onClicked: notes.beginEditing()
            }
        }
        Flow {
            Layout.fillWidth: true
            visible: !notes.editing && !notes.reviewing && !!notes.note
            spacing: 4
            Button {
                objectName: "previewAiReadingNoteUpdate"
                visible: !!(notes.note && notes.note.discussion_available && !notes.note.suggestion)
                text: qsTr("Preview update from discussion")
                enabled: notes.current() && !notes.command && !notes.reviewState.running
                onClicked: notes.beginUpdate()
            }
            Button {
                objectName: "applyAiReadingNoteSuggestion"
                visible: !!(notes.note && notes.note.suggestion)
                text: qsTr("Use suggested key ideas")
                enabled: !notes.command
                onClicked: notes.resolveSuggestion(true)
            }
            Button {
                objectName: "dismissAiReadingNoteSuggestion"
                visible: !!(notes.note && notes.note.suggestion)
                text: qsTr("Dismiss suggestion")
                enabled: !notes.command
                onClicked: notes.resolveSuggestion(false)
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
        RowLayout {
            visible: notes.editing
            Layout.alignment: Qt.AlignRight
            Button {
                text: qsTr("Cancel editing")
                enabled: !notes.command
                onClicked: notes.cancelEditing()
            }
            Button {
                objectName: "saveAiReadingNote"
                text: qsTr("Save changes")
                enabled: !notes.command && notes.dirty
                onClicked: notes.save()
            }
        }
    }
}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id: notes
    objectName: "aiReadingNotes"
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
    property var baseline: ({})
    readonly property bool dirty: !!(reader && note && reader.readingNoteDraft.id === note.id)
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.max(240, Math.min(620, app.width - 48))
    height: Math.max(220, Math.min(520, app.height - 64))
    modal: true
    title: qsTr("Reading notes")
    standardButtons: Dialog.Close

    function current() {
        return reader && reader === app.currentReader && generation === reader.documentGeneration;
    }
    function browse(source) {
        reader = app.currentReader;
        generation = reader.documentGeneration;
        open();
        const draft = reader.readingNoteDraft;
        if (draft.id) {
            preferred = draft.id;
            refresh();
        } else if (source) command = reader.submit("ai_reading_keep", {id: source});
        else refresh();
    }
    function refresh() {
        if (!current() || editing) return;
        preferred = preferred || (note ? note.id : "");
        note = null;
        failure = "";
        command = reader.submit("ai_reading_notes", {query: search.text, recent: order.currentIndex === 0});
    }
    function read(index) {
        if (!current() || editing || index < 0 || index >= entries.length) return;
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
        // their saved bytes, and returning to the displayed baseline clears a delta.
        baseline = {title: editTitle.text, content: editContent.text, thoughts: editThoughts.text};
        if (draft.id === note.id) {
            editTitle.text = draft.title ?? baseline.title;
            editContent.text = draft.content ?? baseline.content;
            editThoughts.text = draft.thoughts ?? baseline.thoughts;
        }
        editing = true;
        seeding = false;
        editTitle.forceActiveFocus();
    }
    function change(field, value) {
        if (!editing || seeding || !current() || !note) return;
        let draft = reader.readingNoteDraft;
        if (draft.id !== note.id) draft = {id: note.id, expected_modified: note.modified};
        if (value === baseline[field]) delete draft[field];
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
    onClosed: {
        debounce.stop();
        editing = false;
        reader = null; command = 0; entries = []; note = null; preferred = ""; failure = "";
        search.text = "";
    }
    Connections {
        target: notes.reader
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
                picker.currentIndex = wanted >= 0 ? wanted : result.length ? 0 : -1;
                notes.preferred = "";
                notes.read(picker.currentIndex);
            } else if (operation === "ai_reading_note") {
                notes.note = result;
                if (notes.reader.readingNoteDraft.id === result.id) notes.beginEditing();
            } else if (operation === "ai_reading_note_update") {
                notes.note = result;
                notes.editing = false;
                if (notes.dirty) notes.beginEditing();
                else notes.refresh();
            }
        }
    }
    Timer { id: debounce; interval: 220; onTriggered: notes.refresh() }

    contentItem: ColumnLayout {
        RowLayout {
            Layout.fillWidth: true
            enabled: !notes.editing
            TextField {
                id: search
                objectName: "aiReadingNoteSearch"
                Layout.fillWidth: true
                placeholderText: qsTr("Search notes")
                Accessible.name: placeholderText
                onTextEdited: debounce.restart()
                onAccepted: { debounce.stop(); notes.refresh(); }
            }
            ComboBox {
                id: order
                model: [qsTr("Recent"), qsTr("Page order")]
                Accessible.name: qsTr("Sort notes")
                onActivated: notes.refresh()
            }
        }
        ComboBox {
            id: picker
            objectName: "aiSavedReadingNote"
            Layout.fillWidth: true
            model: notes.entries
            textRole: "title"
            enabled: count > 0 && !notes.command && !notes.editing
            Accessible.name: qsTr("Saved notes")
            onActivated: notes.read(currentIndex)
        }
        Label {
            Layout.fillWidth: true
            visible: !!text
            text: notes.failure || (notes.command ? (notes.editing ? qsTr("Saving reading note…") : qsTr("Loading reading notes…"))
                : !notes.entries.length ? qsTr("No matching notes.")
                : notes.note && notes.note.status === "sourceChanged" ? qsTr("Note from an earlier PDF revision.") : "")
            wrapMode: Text.Wrap; textFormat: Text.PlainText; color: app.colors.textSecondary
        }
        AiReadingScrollView {
            id: contents
            Layout.fillWidth: true; Layout.fillHeight: true
            visible: !notes.editing
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
            visible: !notes.editing && !!notes.note
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

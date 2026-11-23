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
    function browse(summary) {
        reader = app.currentReader;
        generation = reader.documentGeneration;
        open();
        if (summary) command = reader.submit("ai_reading_keep_summary", {id: summary});
        else refresh();
    }
    function refresh() {
        if (!current()) return;
        preferred = preferred || (note ? note.id : "");
        note = null;
        failure = "";
        command = reader.submit("ai_reading_notes", {query: search.text});
    }
    function read(index) {
        if (!current() || index < 0 || index >= entries.length) return;
        note = null;
        failure = "";
        command = reader.submit("ai_reading_note", {id: entries[index].id});
    }
    onClosed: {
        debounce.stop();
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
            if (operation === "ai_reading_keep_summary") {
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
            }
        }
    }
    Timer { id: debounce; interval: 220; onTriggered: notes.refresh() }

    contentItem: ColumnLayout {
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
            id: picker
            objectName: "aiSavedReadingNote"
            Layout.fillWidth: true
            model: notes.entries
            textRole: "title"
            enabled: count > 0 && !notes.command
            Accessible.name: qsTr("Saved notes")
            onActivated: notes.read(currentIndex)
        }
        Label {
            Layout.fillWidth: true
            visible: !!text
            text: notes.failure || (notes.command ? qsTr("Loading reading notes…")
                : !notes.entries.length ? qsTr("No matching notes.")
                : notes.note && notes.note.status === "sourceChanged" ? qsTr("Note from an earlier PDF revision.") : "")
            wrapMode: Text.Wrap; textFormat: Text.PlainText; color: app.colors.textSecondary
        }
        AiReadingScrollView {
            id: contents
            Layout.fillWidth: true; Layout.fillHeight: true
            TextArea {
                objectName: "aiReadingNoteContent"
                width: contents.availableWidth
                text: notes.note ? notes.note.content : ""
                readOnly: true; selectByMouse: true; selectByKeyboard: true
                textFormat: TextEdit.PlainText; wrapMode: Text.Wrap
                Accessible.name: qsTr("Saved reading note")
                color: app.colors.textPrimary
            }
        }
        RowLayout {
            visible: sources.count > 0
            ComboBox {
                id: sources
                objectName: "aiReadingNotePages"
                model: (notes.note ? notes.note.source_pages : []).map(page => qsTr("Page %1").arg(page))
                Accessible.name: qsTr("Source page")
            }
            Button {
                text: qsTr("Go to source")
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

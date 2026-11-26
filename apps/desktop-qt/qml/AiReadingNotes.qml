import QtQuick
import QtQuick.Controls

Dialog {
    id: popup
    objectName: "aiReadingNotes"
    required property var app
    property alias reader: editor.reader
    property alias generation: editor.generation
    property alias command: editor.command
    property alias entries: editor.entries
    property alias note: editor.note
    property alias editing: editor.editing
    readonly property bool dirty: editor.dirty
    signal requestUpdate(string noteId)
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.max(240, Math.min(620, app.width - 48))
    height: Math.max(220, Math.min(520, app.height - 64))
    modal: true
    title: qsTr("Reading notes")
    standardButtons: Dialog.Close
    function browse(source, noteId = "") { open(); editor.browse(source, noteId); }
    function refresh() { editor.refresh(); }
    function change(field, value) { editor.change(field, value); }
    onClosed: editor.reset()
    contentItem: AiReadingNotesContent {
        id: editor
        app: popup.app
        padding: 0
        onCloseRequested: popup.close()
        onRequestUpdate: function(noteId) { popup.requestUpdate(noteId); }
    }
}

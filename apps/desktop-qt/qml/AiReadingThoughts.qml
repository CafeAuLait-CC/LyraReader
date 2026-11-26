import QtQuick
import QtQuick.Controls

Rectangle {
    id: editor
    required property var app
    property var reader: null
    property double generation: 0
    property var note: null
    property bool allowInput: false
    property var wheelParent: null
    property string failure: ""
    property var editOwner: null
    property double editGeneration: 0
    property string editId: ""
    property string editVersion: ""
    property string savedText: ""
    property string displayedBaseline: ""
    property bool seeding: false
    property bool syncing: false
    property bool initialized: false
    readonly property bool ownsInput: !!editOwner && editGeneration === editOwner.documentGeneration && !!editId
    implicitHeight: 112
    color: app.colors.noteBg; radius: 8

    function displayed(value) {
        return editOwner.nativeReadingEditorText(value);
    }
    function record() {
        if (seeding || !ownsInput) return;
        const draft = editOwner.readingNoteDraft;
        // The full editor takes over this same draft only after finishInput().
        // Hiding the old inline field must not take it back during focus transfer.
        if (draft.id === editId && !editOwner.readingNoteAutomatic) return;
        if (input.text === displayedBaseline && !editOwner.readingNoteSaving && !editOwner.readingNoteSaveError) {
            if (draft.id === editId && editOwner.readingNoteAutomatic) editOwner.discardReadingNoteDraft();
            failure = "";
            return;
        }
        const value = input.text === displayedBaseline ? savedText : input.text;
        if (!editOwner.setReadingNoteThoughts(editId, editVersion, value))
            failure = qsTr("Finish the existing note edit before changing these thoughts. Your input is still visible.");
        else failure = "";
    }
    function finishInput() {
        if (!initialized || !ownsInput || !input.activeFocus) return;
        Qt.inputMethod.commit();
        record();
    }
    function leaveInput() { input.focus = false; }
    function revealInput() {
        const parentView = wheelParent;
        if (parentView && input.activeFocus && ownsInput) parentView.revealItem(editor);
    }
    function sync() {
        if (!initialized || syncing) return;
        syncing = true;
        const id = note ? String(note.id) : "";
        const changed = editOwner !== reader || editGeneration !== generation || editId !== id;
        if (changed) { finishInput(); input.focus = false; }
        editOwner = reader; editGeneration = generation; editId = id;
        if (!ownsInput) { syncing = false; return; }
        editVersion = String(note.modified);
        if (changed || savedText !== note.thoughts) {
            savedText = note.thoughts;
            displayedBaseline = displayed(savedText);
        }
        if (changed || (!input.activeFocus && !input.inputMethodComposing)) {
            const draft = editOwner.readingNoteDraft;
            const desired = draft.id === editId && editOwner.readingNoteAutomatic ? draft.thoughts : savedText;
            seeding = true;
            // Mac recreates its native input for a new note identity. Clear the
            // old composition and undo history even when both notes have equal text.
            if (changed) input.clear();
            if (input.text !== displayed(desired)) input.text = desired;
            seeding = false;
        }
        syncing = false;
    }
    onReaderChanged: sync()
    onGenerationChanged: sync()
    onNoteChanged: sync()
    onVisibleChanged: if (!visible) finishInput()
    Component.onCompleted: { initialized = true; sync(); }
    Component.onDestruction: { finishInput(); initialized = false; }
    Connections {
        target: editor.editOwner
        function onRegionNoteDraftChanged() { editor.sync(); }
    }
    AiReadingScrollView {
        id: viewport
        wheelParent: editor.wheelParent
        objectName: "aiReadingThoughtsScroll"
        anchors.fill: parent
        clip: true
        TextArea {
            id: input
            objectName: "aiReadingNoteInlineThoughts"
            width: viewport.availableWidth
            height: Math.max(viewport.availableHeight, implicitHeight)
            padding: 10
            font.pixelSize: 13
            placeholderText: qsTr("Add your own thoughts…")
            Accessible.name: placeholderText
            textFormat: TextEdit.PlainText; wrapMode: Text.Wrap
            readOnly: !editor.allowInput
            selectByMouse: true; selectByKeyboard: true
            color: app.colors.textPrimary
            selectionColor: app.colors.selectedBg; selectedTextColor: app.colors.selectedFg
            background: null
            onTextChanged: editor.record()
            onActiveFocusChanged: {
                if (!activeFocus) editor.sync();
                else {
                    const owner = editor.editOwner, generation = editor.editGeneration, id = editor.editId;
                    const parentView = editor.wheelParent, interaction = parentView ? parentView.interactionEpoch : -1;
                    Qt.callLater(function() {
                        if (editor.editOwner === owner && editor.editGeneration === generation && editor.editId === id
                                && editor.wheelParent === parentView && parentView && parentView.interactionEpoch === interaction)
                            editor.revealInput();
                    });
                }
            }
        }
    }
}

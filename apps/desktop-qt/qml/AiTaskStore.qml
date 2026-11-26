import QtQuick

Item {
    id: store
    required property var app
    visible: false
    readonly property var owner: app.currentReader
    readonly property double ownerGeneration: owner.documentGeneration
    property var reader: null
    property double generation: 0
    property double command: 0
    property var entries: []
    property string failure: ""
    property string kind: "summary"
    property var scopeSelection: undefined
    property bool loaded: false
    signal aboutToReplaceEntries()
    readonly property bool loading: command !== 0
    function reset() { loaded = false; reader = null; command = 0; entries = []; failure = ""; scopeSelection = undefined; }
    function current() { return reader && reader === owner && generation === ownerGeneration; }
    function reload(taskKind, selection) {
        if (!owner.pageCount) return;
        if (current()) aboutToReplaceEntries();
        loaded = false;
        reader = owner; generation = ownerGeneration; kind = taskKind;
        failure = ""; entries = []; scopeSelection = selection;
        const request = {kind: taskKind};
        if (selection !== undefined) request.selection = selection;
        command = reader.submit("ai_reading_tasks", request);
    }
    onOwnerChanged: reset()
    onOwnerGenerationChanged: reset()
    Connections {
        target: store.reader
        function onCommandFinished(id, operation, result, error) {
            if (!store.current() || id !== store.command || operation !== "ai_reading_tasks") return;
            store.aboutToReplaceEntries();
            store.command = 0; store.failure = error;
            if (!error) store.entries = result;
            store.loaded = true;
        }
    }
}

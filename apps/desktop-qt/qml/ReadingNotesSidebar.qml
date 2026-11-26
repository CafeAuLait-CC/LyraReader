import QtQuick

AiReadingNotesContent {
    id: sidebar
    objectName: "readingNotesSidebar"
    inlineMode: true
    padding: 18
    visible: app.aiPanelVisible && app.aiPanelMode === "notes" && app.currentReader.pageCount > 0
    readonly property var currentOwner: app.currentReader
    readonly property double currentGeneration: currentOwner.documentGeneration

    function activate() {
        if (visible && currentOwner.pageCount > 0) browse("");
    }
    onVisibleChanged: {
        if (visible) Qt.callLater(activate);
        else reset();
    }
    onCurrentOwnerChanged: { reset(); Qt.callLater(activate); }
    onCurrentGenerationChanged: { reset(); Qt.callLater(activate); }
    Component.onCompleted: activate()
    onCloseRequested: { reset(); activate(); }
    Keys.onShortcutOverride: function(event) {
        if (event.key === Qt.Key_Escape) event.accepted = true;
    }
    Keys.onEscapePressed: function(event) { app.showAiPanel(false); event.accepted = true; }
}

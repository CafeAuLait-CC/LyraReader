import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: history
    objectName: "aiChatHistory"
    required property var app
    property var reader: null
    property double generation: 0
    property double command: 0
    property var sessions: []
    property string failure: ""
    property bool opened: false
    visible: opened
    padding: 8
    background: Rectangle { color: app.colors.fieldBg }
    implicitHeight: Math.min(180, Math.max(40, sessionList.contentHeight + 16))
    function current() { return reader && reader === app.currentReader && generation === reader.documentGeneration; }
    function close() { opened = false; reader = null; command = 0; sessions = []; failure = ""; }
    function browse() {
        if (opened) { close(); return; }
        reader = app.currentReader; generation = reader.documentGeneration; failure = "";
        opened = true;
        command = reader.submit("ai_chat_sessions", {});
    }
    function restore(index) {
        if (!current() || command || reader.pendingCommands || reader.aiState.running || index < 0 || index >= sessions.length) return;
        if (reader.reopenAiChat(sessions[index].id)) close();
    }
    Connections {
        target: history.reader
        function onCommandFinished(id, operation, result, error) {
            if (!history.current() || id !== history.command || operation !== "ai_chat_sessions") return;
            history.command = 0; history.failure = error;
            if (!error) history.sessions = result;
        }
    }
    ListView {
        id: sessionList
        objectName: "aiChatSessions"
        anchors.fill: parent
        clip: true
        model: history.sessions
        PanelWheelHandler { viewport: sessionList }
        ScrollBar.vertical: AiReadingScrollBar { id: historyBar }
        delegate: Button {
            id: session
            required property var modelData
            required property int index
            readonly property string conversationId: modelData.id
            objectName: "aiSavedChatRow" + index
            width: Math.max(0, sessionList.width - historyBar.gutterWidth)
            padding: 8
            enabled: !history.command && !app.currentReader.aiState.running
            Accessible.name: modelData.title
            contentItem: Label { text: session.modelData.title; textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; color: app.colors.textPrimary; font.pixelSize: 12 }
            background: Rectangle {
                radius: 5
                color: session.down ? app.colors.pressedBg : session.hovered ? app.colors.hoverBg : "transparent"
                border.width: session.visualFocus ? 2 : 0; border.color: app.colors.focusRing
            }
            onClicked: history.restore(index)
        }
    }
    Label {
        anchors.fill: parent
        visible: !!text
        text: history.failure || (history.command ? qsTr("Loading chats…") : !history.sessions.length ? qsTr("No saved chats.") : "")
        textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.colors.textSecondary
    }
}

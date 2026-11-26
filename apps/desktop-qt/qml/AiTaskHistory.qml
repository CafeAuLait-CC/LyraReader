import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: history
    objectName: "aiTaskHistory"
    required property var app
    required property var store
    property var selected: null
    signal closed()
    signal keepNote(string id)
    signal citation(string link, var plan)
    padding: 8
    background: Rectangle { color: app.colors.panelBg }
    onVisibleChanged: if (!visible) selected = null
    ColumnLayout {
        anchors.fill: parent; spacing: 16
        LyraToolButton {
            objectName: "backToCurrentAiTask"
            symbol: "back"; text: qsTr("Current task"); display: AbstractButton.TextBesideIcon
            onClicked: history.closed()
        }
        Label {
            Layout.fillWidth: true; visible: !!text
            text: history.store.failure || (history.store.loading ? qsTr("Loading saved task results…") : !history.store.entries.length ? qsTr("No saved task results") : "")
            textFormat: Text.PlainText; wrapMode: Text.Wrap; color: app.colors.textSecondary
        }
        ListView {
            id: records
            objectName: "aiTaskHistoryList"
            visible: !history.selected
            Layout.fillWidth: true; Layout.fillHeight: true
            clip: true; model: history.store.entries
            PanelWheelHandler { viewport: records }
            ScrollBar.vertical: AiReadingScrollBar { id: historyBar }
            delegate: Button {
                id: record
                required property var modelData
                required property int index
                objectName: "aiTaskHistoryRow" + index
                width: Math.max(0, records.width - historyBar.gutterWidth)
                leftPadding: 0; rightPadding: 0; topPadding: 10; bottomPadding: 10
                enabled: !history.store.loading
                onClicked: history.selected = modelData
                Accessible.name: modelData.title
                background: Rectangle {
                    color: record.down ? app.colors.pressedBg : record.hovered ? app.colors.hoverBg : "transparent"
                    border.width: record.visualFocus ? 2 : 0; border.color: app.colors.focusRing
                }
                contentItem: ColumnLayout {
                    spacing: 5
                    Label { text: record.modelData.title; font.pixelSize: 14; font.weight: Font.DemiBold; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textPrimary }
                    Label { text: (record.modelData.language || qsTr("Document language")) + " · " + record.modelData.detail; font.pixelSize: 11; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textSecondary }
                    Label { text: record.modelData.content; font.pixelSize: 12; textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight; Layout.fillWidth: true; color: app.colors.textSecondary }
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: app.colors.separator }
            }
        }
        AiReadingScrollView {
            id: detail
            visible: !!history.selected
            Layout.fillWidth: true; Layout.fillHeight: true
            ColumnLayout {
                width: detail.availableWidth; spacing: 16
                LyraToolButton { symbol: "back"; text: qsTr("All task results"); display: AbstractButton.TextBesideIcon; onClicked: history.selected = null }
                Label { text: history.selected ? history.selected.title : ""; font.pixelSize: 14; font.weight: Font.DemiBold; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textPrimary }
                Label { text: history.selected ? (history.selected.language || qsTr("Document language")) + " · " + history.selected.detail + " · " + history.selected.model : ""; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11 }
                Label { visible: !!history.selected && history.selected.status === "sourceChanged"; text: qsTr("The source document has changed. This result retains its original source snapshot."); textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.warningFg }
                AiResult {
                    app: history.app; Layout.fillWidth: true; viewport: detail.contentItem
                    value: history.selected ? {output:history.selected.content, generation:history.store.generation, responsePlan:{action:"SummarizeDocument", source_pages:history.selected.source_pages || []}} : ({})
                    answerName: "aiSavedTaskContent"
                    onCitation: function(link, plan) { history.citation(link, plan); }
                }
                LyraToolButton {
                    objectName: "keepSavedAiTask"
                    symbol: "note"; text: qsTr("Keep in notes"); display: AbstractButton.TextBesideIcon
                    enabled: history.store.current() && !!history.selected && history.selected.status === "finished" && !app.currentReader.readingNoteDraft.id
                    onClicked: history.keepNote(history.selected.id)
                }
                ToolButton { id: savedSource; text: qsTr("Saved source"); checkable: true; checked: false }
                TextArea { visible: savedSource.checked; text: history.selected ? history.selected.excerpt : ""; Layout.fillWidth: true; readOnly: true; selectByMouse: true; selectByKeyboard: true; textFormat: TextEdit.PlainText; wrapMode: TextEdit.Wrap; background: null; color: app.colors.textSecondary }
            }
        }
    }
}

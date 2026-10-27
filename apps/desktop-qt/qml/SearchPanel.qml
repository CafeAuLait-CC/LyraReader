import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: panel
    required property var app
    property alias field: query
    padding: 10
    background: Rectangle {
        color: app.colors.panelBg
    }
    ColumnLayout {
        anchors.fill: parent
        RowLayout {
            Label {
                textFormat: Text.PlainText
                text: qsTr("Search")
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            LyraToolButton {
                symbol: "close"
                text: qsTr("Close search")
                onClicked: app.searchVisible = false
            }
        }
        TextField {
            id:query
            objectName:"panelSearchField"
            Layout.fillWidth: true
            Accessible.name: qsTr("Search document")
            placeholderText: qsTr("Search document")
            text: app.searchQuery
            onTextEdited: {
                app.searchQuery = text;
                app.searchDebounce.restart();
            }
            onAccepted: app.runSearch()
        }
        RowLayout {
            Label {
                textFormat: Text.PlainText
                text: qsTr("%1 results").arg(app.searchResults.length)
                color: app.colors.textSecondary
                Layout.fillWidth: true
            }
            LyraToolButton {
                symbol: "back"
                text: qsTr("Previous result")
                enabled: app.searchResults.length > 0
                onClicked: app.stepSearch(-1)
            }
            LyraToolButton {
                symbol: "next"
                text: qsTr("Next result")
                enabled: app.searchResults.length > 0
                onClicked: app.stepSearch(1)
            }
        }
        ListView {
            id: results
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: app.searchResults
            currentIndex: app.searchIndex
            ScrollBar.vertical: ScrollBar {}
            delegate: ItemDelegate {
                activeFocusOnTab: true
                required property var modelData
                required property int index
                width: results.width
                height: Math.max(75, snippet.implicitHeight + 35)
                highlighted: index === app.searchIndex
                Accessible.name: qsTr("Page %1: %2").arg(modelData.page + 1).arg(modelData.snippet)
                Accessible.selectable: true
                Accessible.selected: highlighted
                Accessible.onPressAction: if (enabled && visible)
                    clicked()
                contentItem: ColumnLayout {
                    Label {
                        textFormat: Text.PlainText
                        text: qsTr("Page %1").arg(modelData.page + 1)
                        color: app.colors.accent
                        font.pixelSize: 11
                    }
                    Label {
                        id: snippet
                        textFormat: Text.PlainText
                        text: modelData.snippet
                        wrapMode: Text.Wrap
                        maximumLineCount: 4
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        font.pixelSize: 12
                    }
                }
                onClicked: {
                    app.searchIndex = index;
                    app.navigate(modelData.page);
                }
            }
        }
    }
}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: card
    required property var app
    signal locateRequested(var range, bool prepared)
    required property string title
    required property string text
    required property var range
    required property bool prepared
    required property string labelName
    property bool partial: false
    property bool expanded: false
    property string fullText: ""
    onTextChanged: { expanded = false; fullText = ""; }
    onRangeChanged: { expanded = false; fullText = ""; }
    Layout.fillWidth: true; Layout.minimumWidth: 0
    padding: 12
    background: Rectangle { radius: 8; color: "transparent"; border.color: app.colors.separator }
    contentItem: ColumnLayout {
        spacing: 8
        RowLayout {
            Layout.fillWidth: true; Layout.minimumWidth: 0
            Label { text: card.title; color: app.colors.textPrimary; font.pixelSize: 12; Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap }
            ToolButton {
                objectName: card.labelName + "Locate"
                text: qsTr("Locate"); palette.buttonText: app.colors.accent
                enabled: !!card.range
                Accessible.name: qsTr("Locate %1 in document").arg(card.title)
                onClicked: card.locateRequested(card.range, card.prepared)
            }
        }
        RowLayout {
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: 10
            Rectangle { width: 2; Layout.fillHeight: true; color: app.colors.separator }
            ColumnLayout {
                Layout.fillWidth: true; Layout.minimumWidth: 0
                spacing: 2
                Label {
                    id: excerptLabel
                    objectName: card.labelName
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    textFormat: Text.PlainText; wrapMode: Text.Wrap
                    maximumLineCount: card.expanded ? 2147483647 : 3
                    elide: card.expanded ? Text.ElideNone : Text.ElideRight
                    text: card.fullText || card.text || qsTr("Select a passage in the document.")
                    color: app.colors.textSecondary; font.pixelSize: 13
                    Accessible.name: card.title
                }
                ToolButton {
                    objectName: card.labelName + "More"
                    visible: card.expanded || excerptLabel.truncated || card.partial
                    text: card.expanded ? qsTr("Less") : qsTr("More")
                    palette.buttonText: app.colors.accent
                    Accessible.name: card.expanded ? qsTr("Collapse selected passage") : qsTr("Expand selected passage")
                    onClicked: {
                        if (!card.expanded && card.partial && !card.prepared && card.range) {
                            const excerpt = app.selectedTextResult(card.range);
                            if (excerpt.error !== undefined) { app.operationStatus = excerpt.error; return; }
                            card.fullText = excerpt.text;
                        }
                        card.expanded = !card.expanded;
                    }
                }
            }
        }
    }
}

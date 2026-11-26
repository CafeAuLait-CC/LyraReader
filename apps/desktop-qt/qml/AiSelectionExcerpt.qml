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
    function toggleExcerpt() {
        if (!expanded && partial && !prepared && range) {
            const excerpt = app.selectedTextResult(range);
            if (excerpt.error !== undefined) { app.operationStatus = excerpt.error; return; }
            fullText = excerpt.text;
        }
        expanded = !expanded;
    }
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
                TranslationInlinePreview {
                    id: excerptPreview
                    app: card.app; textArea: excerptDisplay; naturalHeight: excerptLabel.implicitHeight
                    collapsed: !card.expanded; maximumLines: 3
                    additionalContent: card.partial && !card.fullText
                    actionName: card.labelName + "More"; fallback: footer
                    Layout.fillWidth: true; Layout.minimumWidth: 0
                    onActivated: card.toggleExcerpt()
                    Control {
                        id: excerptLabel
                        objectName: card.labelName
                        // Keep canonical source bytes outside TextEdit's display-only
                        // newline normalization, as the former static label did.
                        readonly property string text: card.fullText || card.text || qsTr("Select a passage in the document.")
                        width: parent.width
                        padding: 0; background: null; focusPolicy: Qt.NoFocus
                        font.pixelSize: 13
                        Accessible.role: Accessible.StaticText
                        Accessible.name: card.title; Accessible.description: text
                        contentItem: TextArea {
                            id: excerptDisplay
                            text: excerptLabel.text; font: excerptLabel.font
                            padding: 0; background: null
                            readOnly: true; selectByMouse: false; selectByKeyboard: false
                            focusPolicy: Qt.NoFocus
                            textFormat: TextEdit.PlainText; wrapMode: TextEdit.Wrap
                            color: app.colors.textSecondary
                            Accessible.ignored: true
                        }
                    }
                }
                ToolButton {
                    id: footer
                    objectName: excerptPreview.footerNeeded ? card.labelName + "More" : ""
                    visible: excerptPreview.footerNeeded
                    text: card.expanded ? qsTr("Less") : qsTr("More")
                    palette.buttonText: app.colors.accent
                    Accessible.name: card.expanded ? qsTr("Collapse selected passage") : qsTr("Expand selected passage")
                    onClicked: card.toggleExcerpt()
                }
            }
        }
    }
}

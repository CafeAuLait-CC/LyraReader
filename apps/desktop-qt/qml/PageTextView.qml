import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: view
    required property var app
    readonly property var owner: app.currentReader
    readonly property int page: app.currentPage
    readonly property var extracted: owner.textPages[page.toString()]
    property int textSize: 16
    property alias focusTarget: pageText
    function zoomBy(factor) {
        textSize = Math.max(12, Math.min(40, Math.round(textSize * factor)));
    }
    padding: 12
    background: Rectangle {
        color: app.colors.panelBg
    }
    function refresh(focus) {
        if (!visible || page < 0 || page >= owner.pageCount)
            return;
        owner.requestText(page);
        if (focus)
            Qt.callLater(function () {
                if (view.visible)
                    pageText.forceActiveFocus();
            });
    }
    onVisibleChanged: refresh(visible)
    onPageChanged: refresh(false)
    onOwnerChanged: refresh(false)
    Shortcut {
        sequence: "Alt+PageDown"
        enabled: view.visible && view.page + 1 < view.owner.pageCount
        onActivated: app.navigate(view.page + 1)
    }
    Shortcut {
        sequence: "Alt+PageUp"
        enabled: view.visible && view.page > 0
        onActivated: app.navigate(view.page - 1)
    }
    Connections {
        target: view.owner
        function onDocumentChanged() {
            view.refresh(false);
        }
    }
    ColumnLayout {
        anchors.fill: parent
        RowLayout {
            Layout.fillWidth: true
            LyraToolButton {
                symbol: "back"
                text: qsTr("Previous page")
                enabled: view.page > 0
                onClicked: app.navigate(view.page - 1)
            }
            Label {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: qsTr("Page %1 of %2 · Text").arg(view.page + 1).arg(view.owner.pageCount)
                elide: Text.ElideRight
                font.weight: Font.DemiBold
            }
            LyraToolButton {
                symbol: "next"
                text: qsTr("Next page")
                enabled: view.page + 1 < view.owner.pageCount
                onClicked: app.navigate(view.page + 1)
            }
            LyraToolButton {
                symbol: "minus"
                text: qsTr("Decrease text size")
                enabled: view.textSize > 12
                onClicked: view.textSize -= 2
            }
            LyraToolButton {
                symbol: "plus"
                text: qsTr("Increase text size")
                enabled: view.textSize < 40
                onClicked: view.textSize += 2
            }
            LyraToolButton {
                symbol: "close"
                text: qsTr("Return to page view (Ctrl+Shift+R)")
                onClicked: app.setTextViewEnabled(false)
            }
        }
        Label {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: qsTr("Extracted text. Use page view for the original layout, figures and annotations. Alt+PageUp / Alt+PageDown changes pages.")
            wrapMode: Text.Wrap
            color: app.colors.textSecondary
            font.pixelSize: 12
        }
        BusyIndicator {
            Layout.alignment: Qt.AlignHCenter
            visible: !view.extracted && !view.owner.error.length
            running: visible
        }
        Label {
            textFormat: Text.PlainText
            visible: !!view.extracted && !view.extracted.text.length
            text: qsTr("No text was found on this page.")
            color: app.colors.textSecondary
        }
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            TextArea {
                id: pageText
                objectName: "accessiblePageText"
                text: view.extracted ? view.extracted.text : ""
                textFormat: TextEdit.PlainText
                readOnly: true
                selectByKeyboard: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                color: app.colors.textPrimary
                font.pixelSize: view.textSize
                padding: 12
                background: Rectangle {
                    color: app.colors.raisedBg
                    border.width: pageText.activeFocus ? 2 : 1
                    border.color: pageText.activeFocus ? app.colors.focusRing : app.colors.border
                    radius: 4
                }
                Accessible.name: qsTr("Page %1 text").arg(view.page + 1)
                Accessible.description: qsTr("Read-only page text. Select with the keyboard and copy with Control+C. Page view preserves the original layout.")
                Accessible.editable: false
                Accessible.readOnly: true
                Keys.onPressed: function (event) {
                    if (!(event.modifiers & Qt.AltModifier))
                        return;
                    if (event.key === Qt.Key_PageDown && view.page + 1 < view.owner.pageCount) {
                        app.navigate(view.page + 1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageUp && view.page > 0) {
                        app.navigate(view.page - 1);
                        event.accepted = true;
                    }
                }
            }
        }
    }
}

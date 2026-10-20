import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window

Popup {
    id: panel
    objectName: "referencePreviewPanel"
    required property var app
    required property var controller
    readonly property var preview: controller ? controller.model : ({})
    readonly property bool textPreview: preview.kind === "reference" || preview.kind === "section"
    property real preferredWidth: 520
    property real preferredHeight: 420
    property bool adjusted: false
    parent: Overlay.overlay
    width: Math.min(preferredWidth, app.width - 24)
    height: Math.min(preferredHeight, app.height - 36)
    padding: 0
    modal: false
    dim: false
    closePolicy: Popup.NoAutoClose
    background: Rectangle {
        color: app.colors.raisedBg
        border.color: app.colors.border
        radius: 9
    }
    function positionNearAnchor() {
        if (!controller)
            return;
        const anchor = controller.anchor;
        x = Math.max(12, Math.min(app.width - width - 12, anchor.x));
        const below = anchor.y + anchor.height + 8;
        y = Math.max(12, Math.min(app.height - height - 12, below + height < app.height - 12 ? below : anchor.y - height - 8));
    }
    Connections {
        target: panel.controller
        function onChanged() {
            if (!controller.visible) {
                panel.close();
                return;
            }
            if (!panel.visible) {
                adjusted = false;
                preferredWidth = 520;
                preferredHeight = panel.textPreview ? 360 : 480;
                panel.positionNearAnchor();
                panel.open();
            }
        }
    }
    onWidthChanged: if (visible)
        x = Math.max(12, Math.min(x, app.width - width - 12))
    onHeightChanged: if (visible)
        y = Math.max(12, Math.min(y, app.height - height - 12))
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Rectangle {
            id: titlebar
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            color: "transparent"
            DragHandler {
                target: null
                property real startX: 0
                property real startY: 0
                onActiveChanged: if (active) {
                    startX = panel.x;
                    startY = panel.y;
                    panel.adjusted = true;
                }
                onActiveTranslationChanged: if (active) {
                    panel.x = Math.max(12, Math.min(app.width - panel.width - 12, startX + activeTranslation.x));
                    panel.y = Math.max(12, Math.min(app.height - panel.height - 12, startY + activeTranslation.y));
                }
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 8
                spacing: 6
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    Label {
                        text: panel.preview.title || ""
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        color: app.colors.textPrimary
                        font.weight: Font.DemiBold
                    }
                    Label {
                        text: qsTr("From page %1 · %2").arg((panel.preview.from_page || 0) + 1).arg(panel.preview.kind || "")
                        font.pixelSize: 10
                        color: app.colors.textTertiary
                    }
                }
                LyraToolButton {
                    theme: app.colors
                    symbol: "pin"
                    text: controller && controller.pinned ? qsTr("Unpin preview") : qsTr("Pin preview")
                    selected: controller ? controller.pinned : false
                    onClicked: controller.togglePin()
                }
                LyraToolButton {
                    theme: app.colors
                    symbol: "close"
                    text: qsTr("Close preview (Esc)")
                    onClicked: controller.close()
                }
            }
        }
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: app.colors.separator
        }
        ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            ColumnLayout {
                width: scroll.availableWidth
                spacing: 12
                Item {
                    height: 2
                }
                Label {
                    visible: panel.preview.kind === "section"
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    text: panel.preview.section_title || panel.preview.section_reference || qsTr("Section")
                    font.pixelSize: 18
                    font.weight: Font.DemiBold
                    color: app.colors.textPrimary
                    wrapMode: Text.Wrap
                }
                Label {
                    visible: panel.preview.kind === "section"
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    text: panel.preview.section_title ? panel.preview.section_reference || "" : qsTr("No heading was found in this document’s outline. The title comes from the printed reference.")
                    color: app.colors.textSecondary
                    wrapMode: Text.Wrap
                }
                Label {
                    visible: panel.preview.kind === "reference" && !!panel.preview.ambiguous
                    text: panel.preview.resolution_reason || ""
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    wrapMode: Text.Wrap
                    font.pixelSize: 11
                    color: app.colors.textSecondary
                }
                Repeater {
                    model: panel.preview.kind === "reference" ? panel.preview.entries || [] : []
                    ColumnLayout {
                        id: referenceEntry
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        Layout.leftMargin: 16
                        Layout.rightMargin: 16
                        spacing: 4
                        Button {
                            text: qsTr("[%1] · page %2").arg(referenceEntry.modelData.label).arg(referenceEntry.modelData.page + 1)
                            flat: true
                            onClicked: controller.showEntry(referenceEntry.index)
                        }
                        TextArea {
                            text: referenceEntry.modelData.text || ""
                            Layout.fillWidth: true
                            readOnly: true
                            selectByMouse: true
                            wrapMode: Text.Wrap
                            color: app.colors.textPrimary
                            background: null
                            font.pixelSize: 12
                            padding: 0
                            Accessible.name: qsTr("Reference %1").arg(referenceEntry.modelData.label)
                        }
                        Button {
                            text: qsTr("Copy reference text")
                            flat: true
                            onClicked: if (app.session)
                                app.session.copyText(referenceEntry.modelData.text)
                        }
                    }
                }
                Repeater {
                    model: !panel.textPreview && controller ? controller.imageSegments(Math.max(40, scroll.availableWidth - 24), Screen.devicePixelRatio, app.paperAppearance) : []
                    ColumnLayout {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        Layout.leftMargin: 12
                        Layout.rightMargin: 12
                        Image {
                            id: crop
                            objectName: index === 0 ? "referencePreviewImage" : "referencePreviewImage" + index
                            Layout.fillWidth: true
                            Layout.preferredHeight: width * modelData.aspect
                            source: modelData.url
                            asynchronous: true
                            cache: false
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                            BusyIndicator {
                                anchors.centerIn: parent
                                running: crop.status === Image.Loading
                                visible: running
                            }
                        }
                        Label {
                            visible: crop.status === Image.Error
                            text: qsTr("This preview could not be rendered.")
                            color: app.colors.errorFg
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }
                Label {
                    visible: !!panel.preview.caption
                    text: panel.preview.caption || ""
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    wrapMode: Text.Wrap
                    color: app.colors.textSecondary
                }
                Item {
                    height: 8
                }
            }
        }
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: app.colors.separator
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 8
            spacing: 4
            Button {
                text: qsTr("Go to page %1").arg((panel.preview.page || 0) + 1)
                onClicked: controller.jump()
            }
            LyraToolButton {
                theme: app.colors
                symbol: "folder"
                text: qsTr("Open in a new window")
                onClicked: controller.openWindow()
            }
            LyraToolButton {
                theme: app.colors
                symbol: "pages"
                text: qsTr("Show full page")
                onClicked: controller.showFullPage()
            }
            LyraToolButton {
                theme: app.colors
                symbol: "outline"
                text: qsTr("Return to reference text")
                visible: !panel.textPreview
                onClicked: controller.showText()
            }
            Item {
                Layout.fillWidth: true
            }
            Button {
                text: qsTr("BibTeX")
                visible: panel.preview.kind === "reference"
                enabled: !!app.bibtex
                onClicked: if (app.session)
                    app.session.copyText(app.bibtex)
            }
            LyraToolButton {
                theme: app.colors
                symbol: "back"
                text: qsTr("Back to reading position")
                enabled: app.canGoBack
                onClicked: app.goBack()
            }
        }
    }
    Item {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: 16
        height: 16
        HoverHandler {
            cursorShape: Qt.SizeFDiagCursor
        }
        DragHandler {
            target: null
            property real startWidth: 0
            property real startHeight: 0
            onActiveChanged: if (active) {
                startWidth = panel.width;
                startHeight = panel.height;
                panel.adjusted = true;
            }
            onActiveTranslationChanged: if (active) {
                panel.preferredWidth = Math.max(320, Math.min(app.width - panel.x - 12, startWidth + activeTranslation.x));
                panel.preferredHeight = Math.max(220, Math.min(app.height - panel.y - 12, startHeight + activeTranslation.y));
            }
        }
    }
}

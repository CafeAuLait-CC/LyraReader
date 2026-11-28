import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import LyraReader 1.0

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
    property bool manuallySized: false
    property string contentKey: ""
    // Layout rounds its assigned width to logical pixels. Keep the source's fractional width
    // while still reserving the card insets and any visible scroll indicator.
    readonly property real liveImageWidth: Math.max(40, availableWidth - 44 - Math.max(0, scroll.width - scroll.availableWidth))
    property real rasterWidth: 496
    readonly property real naturalHeight: previewBody.implicitHeight + titlebar.height + 20 + 8
    function updateRasterWidth() {
        if (Number.isFinite(liveImageWidth) && liveImageWidth > 0 && Math.abs(liveImageWidth-rasterWidth) > 1)
            rasterWidth = liveImageWidth;
    }
    onLiveImageWidthChanged: updateRasterWidth()
    parent: Overlay.overlay
    width: Math.min(preferredWidth, app.width * .8, app.width - 24)
    height: Math.min(Math.max(120, manuallySized ? preferredHeight : textPreview ? naturalHeight : 480), app.height * .8, app.height - 36)
    padding: 0
    modal: false
    dim: false
    closePolicy: Popup.NoAutoClose
    background: Rectangle {
        color: app.colors.raisedBg
        border.color: app.colors.border
        radius: 12
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
            const key = JSON.stringify(controller.model);
            if (key !== panel.contentKey) {
                panel.contentKey = key;
                panel.manuallySized = false;
            }
            if (!panel.visible) {
                adjusted = false;
                manuallySized = false;
                preferredWidth = 520;
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
        anchors.margins: 10
        spacing: 8
        Item {
            id: titlebar
            objectName: "previewControls"
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            Layout.preferredHeight: header.implicitHeight
            activeFocusOnTab: true
            Accessible.role: Accessible.Pane
            Accessible.name: qsTr("Preview controls")
            Accessible.description: qsTr("Press Shift+F10 for additional preview actions.")
            Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && event.modifiers & Qt.ShiftModifier)) {
                    previewActions.openBelow(titlebar);
                    event.accepted = true;
                }
            }
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
            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: previewActions.openBelow(titlebar)
            }
            ColumnLayout {
                id: header
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 4
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Button {
                        objectName: "previewBack"
                        text: qsTr("Back")
                        icon.source: "qrc:/icons/back.svg"
                        icon.width: 12
                        icon.height: 12
                        font.pixelSize: 12
                        implicitHeight: 26
                        implicitWidth: implicitContentWidth + 12
                        enabled: app.canGoBack
                        onClicked: app.goBack()
                    }
                    Label {
                        textFormat: Text.PlainText
                        text: panel.preview.title || ""
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        elide: Text.ElideRight
                        color: app.colors.textPrimary
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                    }
                    LyraToolButton {
                        objectName: "previewClose"
                        theme: app.colors
                        symbol: "close"
                        text: qsTr("Close preview (Esc)")
                        implicitWidth: 26
                        implicitHeight: 26
                        onClicked: controller.close()
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Label {
                        textFormat: Text.PlainText
                        text: qsTr("From page %1 ·").arg((panel.preview.from_page || 0) + 1)
                        font.pixelSize: 11
                        color: app.colors.textSecondary
                    }
                    Button {
                        objectName: "previewPageLink"
                        text: qsTr("page %1").arg((panel.preview.page || 0) + 1)
                        flat: true
                        font.pixelSize: 11
                        implicitHeight: 24
                        implicitWidth: implicitContentWidth + 4
                        padding: 0
                        palette.buttonText: app.colors.accent
                        onClicked: controller.jump()
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                        objectName: "previewBibtex"
                        text: qsTr("BibTeX")
                        font.pixelSize: 11
                        implicitHeight: 24
                        implicitWidth: implicitContentWidth + 12
                        visible: panel.preview.kind === "reference"
                        enabled: !!app.bibtex
                        onClicked: if (app.session) app.session.copyText(app.bibtex)
                    }
                    Button {
                        objectName: "previewGoToPage"
                        text: qsTr("Go to page")
                        font.pixelSize: 11
                        implicitHeight: 24
                        implicitWidth: implicitContentWidth + 12
                        onClicked: controller.jump()
                    }
                }
            }
        }
        ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            ColumnLayout {
                id: previewBody
                width: scroll.availableWidth
                spacing: 12
                Label {
                    textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    visible: panel.preview.kind === "section"
                    Layout.fillWidth: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    text: panel.preview.section_title ? panel.preview.section_reference || "" : qsTr("No heading was found in this document’s outline. The title comes from the printed reference.")
                    color: app.colors.textSecondary
                    wrapMode: Text.Wrap
                }
                Label {
                    textFormat: Text.PlainText
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
                    RowLayout {
                        id: referenceEntry
                        required property var modelData
                        required property int index
                        readonly property bool hasPage: Number.isInteger(modelData.page) && modelData.page >= 0
                        Layout.fillWidth: true
                        spacing: 6
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4
                            Button {
                                Layout.fillWidth: true
                                padding: 0
                                text: referenceEntry.modelData.heading || qsTr("Reference")
                                enabled: referenceEntry.hasPage
                                contentItem: Label {
                                    objectName: "referenceEntryHeading" + referenceEntry.index
                                    textFormat: Text.PlainText
                                    text: parent.text
                                    color: referenceEntry.hasPage ? app.colors.accent : app.colors.textPrimary
                                    wrapMode: Text.Wrap
                                    font.pixelSize: 14
                                    font.weight: Font.DemiBold
                                }
                                background: Rectangle {
                                    radius: 3
                                    color: parent.down ? app.colors.pressedBg : parent.hovered ? app.colors.hoverBg : "transparent"
                                    border.width: parent.visualFocus ? 2 : 0
                                    border.color: app.colors.focusRing
                                }
                                onClicked: controller.showEntry(referenceEntry.index)
                            }
                            TextArea {
                                objectName: "referenceEntryText" + referenceEntry.index
                                textFormat: TextEdit.PlainText
                                text: referenceEntry.modelData.text || ""
                                Layout.fillWidth: true
                                readOnly: true
                                selectByMouse: true
                                selectByKeyboard: true
                                wrapMode: Text.Wrap
                                color: app.colors.textSecondary
                                background: null
                                font.pixelSize: 12
                                font.weight: Font.Normal
                                padding: 0
                                leftPadding: 0
                                rightPadding: 0
                                topPadding: 0
                                bottomPadding: 0
                                Accessible.name: qsTr("Reference %1").arg(referenceEntry.modelData.label)
                            }
                        }
                        LyraToolButton {
                            id: entryCopy
                            objectName: "referenceEntryCopy" + referenceEntry.index
                            Layout.alignment: Qt.AlignTop
                            theme: app.colors
                            symbol: "copy"
                            implicitWidth: 26
                            implicitHeight: 26
                            icon.width: 14
                            icon.height: 14
                            padding: 6
                            text: qsTr("Copy reference")
                            onClicked: copyMenu.openBelow(entryCopy)
                            LyraMenu {
                                id: copyMenu
                                theme: app.colors
                                objectName: "referenceEntryCopyMenu" + referenceEntry.index
                                LyraMenuItem {
                                    objectName: "referenceCopyText" + referenceEntry.index
                                    text: qsTr("Copy Entry Text")
                                    onTriggered: if (app.session) app.session.copyText(referenceEntry.modelData.text)
                                }
                                LyraMenuItem {
                                    objectName: "referenceCopyBibtex" + referenceEntry.index
                                    text: qsTr("Copy BibTeX")
                                    enabled: !!app.bibtex
                                    onTriggered: if (app.session) app.session.copyText(app.bibtex)
                                }
                            }
                        }
                    }
                }

                Repeater {
                    // Read the model explicitly: an invokable cannot expose its
                    // private C++ model reads to the QML dependency tracker.
                    model: panel.visible && !panel.textPreview && controller && controller.visible && panel.preview.page !== undefined ? controller.imageSegments(panel.rasterWidth, Screen.devicePixelRatio, "original") : []
                    ColumnLayout {
                        id: regionEntry
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        Layout.leftMargin: 12
                        Layout.rightMargin: 12
                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: panel.liveImageWidth * modelData.aspect
                            PdfCrop {
                            id: crop
                            objectName: index === 0 ? "referencePreviewImage" : "referencePreviewImage" + index
                            width: panel.liveImageWidth
                            height: width * modelData.aspect
                            source: modelData.url
                            Accessible.role: Accessible.Graphic
                            Accessible.name: qsTr("Preview of page %1").arg(modelData.page + 1)
                            Accessible.description: panel.preview.caption || qsTr("Use Text to read reference information.")
                            resourceActive: panel.visible && regionEntry.y + crop.y + crop.height > scroll.contentItem.contentY && regionEntry.y + crop.y < scroll.contentItem.contentY + scroll.availableHeight
                            // Scientific regions follow the interface theme, while full pages
                            // retain the selected reading profile. Source URLs remain original.
                            paperAppearance: panel.preview.kind === "figure" ? (app.colors.dark ? "dark-figure" : "original") : app.paperAppearance
                            BusyIndicator {
                                anchors.centerIn: parent
                                running: crop.status === Image.Loading
                                visible: running
                            }
                            }
                        }
                        Label {
                            textFormat: Text.PlainText
                            visible: crop.status === Image.Error
                            text: qsTr("This preview could not be rendered.")
                            color: app.colors.errorFg
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }
                Label {
                    textFormat: Text.PlainText
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
    }
    // Platform-specific capabilities remain available without occupying the Mac citation-card
    // header rows. The same menu is reachable by right-click and the standard keyboard key.
    LyraMenu {
        id: previewActions
        theme: app.colors
        objectName: "previewAdditionalActions"
        LyraMenuItem {
            text: controller && controller.pinned ? qsTr("Unpin preview") : qsTr("Pin preview")
            checkable: true
            checked: controller ? controller.pinned : false
            onTriggered: controller.togglePin()
        }
        LyraMenuItem {
            text: qsTr("Open in a new window")
            onTriggered: controller.openWindow()
        }
        LyraMenuItem {
            text: qsTr("Show full page")
            onTriggered: controller.showFullPage()
        }
        LyraMenuItem {
            text: qsTr("Return to reference text")
            enabled: !panel.textPreview
            onTriggered: controller.showText()
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
                panel.manuallySized = true;
            }
            onActiveTranslationChanged: if (active) {
                panel.preferredWidth = Math.max(320, Math.min(app.width - panel.x - 12, startWidth + activeTranslation.x));
                panel.preferredHeight = Math.max(120, Math.min(app.height * .8, app.height - panel.y - 12, startHeight + activeTranslation.y));
            }
        }
    }
}

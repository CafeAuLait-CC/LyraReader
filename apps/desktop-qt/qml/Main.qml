import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import LyraReader 1.0

ApplicationWindow {
    id: root
    objectName: "readerWindow"
    visible: true
    width: 1200
    height: 820
    minimumWidth: 640
    minimumHeight: 440
    title: reader.title === "LyraReader" ? "LyraReader" : reader.title + " — LyraReader"
    color: theme.windowBg
    // Palette specification defaults to light; the user can opt into dark or system.
    property string appearance: "light"
    SystemPalette { id: systemPalette }
    LyraReaderTheme {
        id: theme
        objectName: "lyraReaderTheme"
        dark: root.appearance === "dark" || (root.appearance === "system" && systemPalette.window.hslLightness < 0.5)
    }
    palette.window: theme.windowBg
    palette.windowText: theme.textPrimary
    palette.base: theme.fieldBg
    palette.alternateBase: theme.panelBg
    palette.text: theme.textPrimary
    palette.button: theme.toolbarBg
    palette.buttonText: theme.textPrimary
    palette.highlight: theme.selectedBg
    palette.highlightedText: theme.selectedFg
    palette.accent: theme.accent
    palette.link: theme.accent
    palette.placeholderText: theme.textPlaceholder
    palette.mid: theme.controlBorder
    palette.dark: theme.border
    palette.light: theme.raisedBg
    palette.toolTipBase: theme.raisedBg
    palette.toolTipText: theme.textPrimary
    palette.disabled.text: theme.textDisabled
    palette.disabled.buttonText: theme.textDisabled
    palette.disabled.windowText: theme.textDisabled
    palette.inactive.highlight: theme.inactiveSelectionBg
    palette.inactive.highlightedText: theme.inactiveSelectionFg
    property real zoom: 1
    property bool fitting: true
    property bool sidebarVisible: true
    property int currentPage: 0

    function navigate(page) {
        if (reader.pageCount === 0) return
        page = Math.max(0, Math.min(reader.pageCount - 1, page))
        pageList.positionViewAtIndex(page, ListView.Beginning)
        root.currentPage = page
    }
    function changeZoom(value, anchorX, anchorY) {
        const old = root.zoom
        const next = Math.max(0.1, Math.min(4, value))
        const oldLeft = (pageList.contentWidth - reader.documentWidth * old) / 2
        const x = reader.zoomOffset(pageList.contentX, anchorX - oldLeft, old, next)
        const y = reader.zoomOffset(pageList.contentY, anchorY, old, next)
        root.zoom = next
        Qt.callLater(function() {
            const newLeft = (pageList.contentWidth - reader.documentWidth * next) / 2
            pageList.contentX = Math.max(0, Math.min(pageList.contentWidth - pageList.width, x + newLeft))
            pageList.contentY = Math.max(-pageList.topMargin,
                Math.min(Math.max(-pageList.topMargin, pageList.contentHeight - pageList.height + pageList.bottomMargin), y))
        })
    }
    function zoomBy(factor) {
        root.fitting = false
        changeZoom(zoom * factor, pageList.width / 2, pageList.height / 2)
    }
    function fitWidth() {
        if (reader.pageCount > 0) changeZoom(reader.fitWidth(pageList.width), pageList.width / 2, 0)
        root.fitting = true
    }
    function updateCurrentPage() {
        const page = pageList.indexAt(pageList.contentX + pageList.width / 2,
            pageList.contentY + Math.min(pageList.height / 3, 180))
        if (page >= 0) root.currentPage = page
    }

    Action { id: openAction; text: qsTr("Open PDF…"); shortcut: StandardKey.Open; onTriggered: fileDialog.open() }
    Action { id: quitAction; text: qsTr("Quit"); shortcut: StandardKey.Quit; onTriggered: Qt.quit() }
    Action { id: zoomIn; text: qsTr("Zoom In"); shortcut: StandardKey.ZoomIn; enabled: reader.pageCount > 0; onTriggered: root.zoomBy(1.2) }
    Action { id: zoomOut; text: qsTr("Zoom Out"); shortcut: StandardKey.ZoomOut; enabled: reader.pageCount > 0; onTriggered: root.zoomBy(1 / 1.2) }
    Action { id: fitAction; text: qsTr("Fit Width"); shortcut: "Ctrl+1"; enabled: reader.pageCount > 0; onTriggered: root.fitWidth() }
    Action { id: actualAction; text: qsTr("Actual Size"); shortcut: "Ctrl+0"; enabled: reader.pageCount > 0; onTriggered: { root.fitting = false; root.changeZoom(1, pageList.width/2, pageList.height/2) } }
    Shortcut { sequence: "PageDown"; onActivated: root.navigate(root.currentPage + 1) }
    Shortcut { sequence: "PageUp"; onActivated: root.navigate(root.currentPage - 1) }
    Shortcut { sequence: "Ctrl+Home"; onActivated: root.navigate(0) }
    Shortcut { sequence: "Ctrl+End"; onActivated: root.navigate(reader.pageCount - 1) }
    Shortcut { sequence: "Ctrl+L"; onActivated: { pageNumber.forceActiveFocus(); pageNumber.selectAll() } }
    Shortcut { sequence: "Ctrl+B"; onActivated: root.sidebarVisible = !root.sidebarVisible }
    Shortcut { sequence: "F11"; onActivated: root.visibility = root.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen }

    menuBar: MenuBar {
        background: Rectangle { color: theme.titlebarBg }
        Menu {
            title: qsTr("&File")
            MenuItem { action: openAction }
            MenuSeparator {}
            MenuItem { action: quitAction }
        }
        Menu {
            title: qsTr("&View")
            MenuItem { action: zoomIn }
            MenuItem { action: zoomOut }
            MenuItem { action: fitAction }
            MenuItem { action: actualAction }
            MenuSeparator {}
            MenuItem { text: qsTr("Pages Sidebar"); checkable: true; checked: root.sidebarVisible; onTriggered: root.sidebarVisible = checked }
            MenuSeparator {}
            Menu {
                title: qsTr("Appearance")
                ActionGroup { id: appearanceGroup }
                MenuItem { action: Action { text: qsTr("Light"); checkable: true; checked: root.appearance === "light"; ActionGroup.group: appearanceGroup; onTriggered: root.appearance = "light" } }
                MenuItem { action: Action { text: qsTr("Dark"); checkable: true; checked: root.appearance === "dark"; ActionGroup.group: appearanceGroup; onTriggered: root.appearance = "dark" } }
                MenuItem { action: Action { text: qsTr("Follow System"); checkable: true; checked: root.appearance === "system"; ActionGroup.group: appearanceGroup; onTriggered: root.appearance = "system" } }
            }
        }
    }
    header: ToolBar {
        padding: 10
        background: Rectangle { color: theme.toolbarBg }
        RowLayout {
            anchors.fill: parent
            spacing: 8
            ToolButton {
                text: "☰"
                Accessible.name: qsTr("Toggle pages sidebar")
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Pages sidebar (Ctrl+B)")
                checkable: true
                checked: root.sidebarVisible
                onClicked: root.sidebarVisible = !root.sidebarVisible
            }
            Rectangle {
                implicitWidth: 30; implicitHeight: 30; radius: 9; color: theme.selectedBg
                Label { anchors.centerIn: parent; text: "L"; color: theme.selectedFg; font.pixelSize: 19; font.weight: Font.DemiBold }
            }
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                Label { text: reader.pageCount > 0 ? reader.title : "LyraReader"; elide: Text.ElideMiddle; Layout.fillWidth: true; font.weight: Font.DemiBold }
                Label { text: reader.loading ? qsTr("Opening document…") : reader.pageCount > 0 ? qsTr("%1 pages").arg(reader.pageCount) : qsTr("A little space to read"); font.pixelSize: 11; color: theme.textSecondary }
            }
            ToolButton { action: openAction; display: AbstractButton.TextOnly }
            ToolSeparator { visible: reader.pageCount > 0 }
            ToolButton { visible: reader.pageCount > 0; text: "−"; Accessible.name: zoomOut.text; onClicked: zoomOut.trigger(); font.pixelSize: 20 }
            ToolButton {
                visible: reader.pageCount > 0
                text: Math.round(root.zoom * 100) + "%"
                Accessible.name: qsTr("Zoom. Click to fit width")
                onClicked: root.fitWidth()
            }
            ToolButton { visible: reader.pageCount > 0; text: "+"; Accessible.name: zoomIn.text; onClicked: zoomIn.trigger(); font.pixelSize: 20 }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Frame {
            visible: reader.error.length > 0 && !reader.passwordRequired
            Layout.fillWidth: true
            background: Rectangle { color: theme.errorBg }
            RowLayout {
                anchors.fill: parent
                Label { text: qsTr("Error: %1").arg(reader.error); color: theme.errorFg; wrapMode: Text.Wrap; Layout.fillWidth: true; Accessible.role: Accessible.AlertMessage }
                ToolButton { text: qsTr("Dismiss"); onClicked: reader.dismissError() }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0
            Pane {
                visible: root.sidebarVisible && reader.pageCount > 0
                Layout.preferredWidth: root.width < 850 ? 150 : 214
                Layout.fillHeight: true
                padding: 0
                background: Rectangle { color: theme.sidebarBg }
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0
                    Label { text: qsTr("PAGES"); font.pixelSize: 11; font.letterSpacing: 1.5; color: theme.textTertiary; Layout.margins: 18 }
                    ListView {
                        id: sidebar
                        objectName: "pagesSidebar"
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: reader.pageCount
                        currentIndex: root.currentPage
                        boundsBehavior: Flickable.StopAtBounds
                        onHeightChanged: if (contentHeight <= height) positionViewAtBeginning()
                        onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
                        ScrollBar.vertical: ScrollBar {}
                        delegate: ItemDelegate {
                            id: pageEntry
                            required property int index
                            width: ListView.view.width
                            height: 54
                            highlighted: root.currentPage === index
                            background: Rectangle {
                                color: pageEntry.highlighted
                                    ? (root.active ? theme.selectedBg : theme.inactiveSelectionBg)
                                    : pageEntry.down ? theme.pressedBg : pageEntry.hovered ? theme.hoverBg : theme.sidebarBg
                                border.width: pageEntry.visualFocus ? 2 : 0
                                border.color: theme.focusRing
                            }
                            contentItem: RowLayout {
                                spacing: 12
                                Rectangle {
                                    implicitWidth: 25; implicitHeight: 33; radius: 2
                                    color: theme.raisedBg; border.color: theme.pageEdge
                                    Label { anchors.centerIn: parent; text: index + 1; font.pixelSize: 9; color: theme.textTertiary }
                                }
                                Label { text: qsTr("Page %1").arg(index + 1); Layout.fillWidth: true; color: root.currentPage === index ? (root.active ? theme.selectedFg : theme.inactiveSelectionFg) : theme.textPrimary }
                            }
                            onClicked: root.navigate(index)
                        }
                    }
                }
            }
            Rectangle { visible: root.sidebarVisible && reader.pageCount > 0; Layout.preferredWidth: 1; Layout.fillHeight: true; color: theme.separator }
            Item {
                id: readingArea
                Layout.fillWidth: true
                Layout.fillHeight: true
                Rectangle { anchors.fill: parent; color: reader.pageCount > 0 ? theme.canvasBg : theme.emptyBg }
                ListView {
                    id: pageList
                    objectName: "pageList"
                    anchors.fill: parent
                    visible: reader.pageCount > 0
                    clip: true
                    model: reader.pages
                    contentWidth: Math.max(width, reader.documentWidth * root.zoom + 64)
                    topMargin: 24
                    bottomMargin: 24
                    cacheBuffer: height / 2
                    reuseItems: false
                    boundsBehavior: Flickable.StopAtBounds
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    ScrollBar.vertical: ScrollBar { minimumSize: 0.04 }
                    ScrollBar.horizontal: ScrollBar {}
                    onContentYChanged: root.updateCurrentPage()
                    onWidthChanged: if (root.fitting) resizeTimer.restart()
                    delegate: Item {
                        required property var modelData
                        width: pageList.contentWidth
                        height: (modelData.height + 12) * root.zoom
                        Rectangle {
                            id: sheet
                            width: modelData.width * root.zoom
                            height: modelData.height * root.zoom
                            x: (parent.width - width) / 2
                            color: "white"
                            PdfPage {
                                id: pdfPage
                                objectName: "pdfPage" + modelData.index
                                anchors.fill: parent
                                controller: reader
                                pageIndex: modelData.index
                                rasterScale: root.zoom
                                Accessible.role: Accessible.Graphic
                                Accessible.name: qsTr("PDF page %1").arg(modelData.index + 1)
                            }
                            BusyIndicator { anchors.centerIn: parent; running: !pdfPage.loaded; visible: running; width: 34; height: 34 }
                        }
                    }
                    WheelHandler {
                        acceptedModifiers: Qt.ControlModifier
                        onWheel: function(event) {
                            root.fitting = false
                            const delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y
                            root.changeZoom(root.zoom * Math.pow(1.0015, delta), event.x, event.y)
                            event.accepted = true
                        }
                    }
                    PinchHandler {
                        target: null
                        property real previousScale: 1
                        onActiveChanged: previousScale = 1
                        onActiveScaleChanged: {
                            if (active) {
                                root.fitting = false
                                root.changeZoom(root.zoom * activeScale / previousScale, centroid.position.x, centroid.position.y)
                                previousScale = activeScale
                            }
                        }
                    }
                }
                ColumnLayout {
                    anchors.centerIn: parent
                    visible: reader.pageCount === 0
                    spacing: 16
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        implicitWidth: 62; implicitHeight: 74; radius: 6
                        color: theme.raisedBg; border.color: theme.pageEdge
                        Label { anchors.centerIn: parent; text: "L"; color: theme.accent; font.pixelSize: 32; font.weight: Font.Light }
                    }
                    Label { Layout.alignment: Qt.AlignHCenter; text: reader.loading ? qsTr("Opening your document") : qsTr("Make room for a good paper."); font.pixelSize: 23; font.weight: Font.Light }
                    Label { Layout.alignment: Qt.AlignHCenter; text: qsTr("Drop a PDF here, or open one to begin."); color: theme.textSecondary }
                    Button {
                        id: primaryOpen
                        Layout.alignment: Qt.AlignHCenter
                        action: openAction
                        visible: !reader.loading
                        palette.buttonText: theme.onAccent
                        contentItem: Text {
                            text: primaryOpen.text
                            font: primaryOpen.font
                            color: theme.onAccent
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            implicitWidth: 130; implicitHeight: 36; radius: 4
                            color: primaryOpen.down ? theme.accentPressed : primaryOpen.hovered ? theme.accentHover : theme.accent
                            border.width: primaryOpen.visualFocus ? 2 : 0
                            border.color: theme.focusRing
                        }
                    }
                    BusyIndicator { Layout.alignment: Qt.AlignHCenter; running: reader.loading; visible: running }
                }
                DropArea {
                    anchors.fill: parent
                    onDropped: function(drop) {
                        if (drop.hasUrls && drop.urls.length > 0) {
                            reader.openFile(drop.urls[0])
                            drop.accepted = true
                        }
                    }
                }
            }
        }
    }
    footer: ToolBar {
        visible: reader.pageCount > 0
        padding: 5
        background: Rectangle { color: theme.statusbarBg }
        RowLayout {
            anchors.fill: parent
            ToolButton { text: "‹"; font.pixelSize: 22; enabled: root.currentPage > 0; Accessible.name: qsTr("Previous page"); onClicked: root.navigate(root.currentPage - 1) }
            TextField {
                id: pageNumber
                objectName: "pageNumber"
                text: (root.currentPage + 1).toString()
                Layout.preferredWidth: 52
                horizontalAlignment: Text.AlignHCenter
                validator: IntValidator { bottom: 1; top: Math.max(1, reader.pageCount) }
                Accessible.name: qsTr("Go to page")
                onAccepted: { root.navigate(Number(text) - 1); pageList.forceActiveFocus() }
            }
            Label { text: "/ " + reader.pageCount; color: theme.textTertiary }
            ToolButton { text: "›"; font.pixelSize: 22; enabled: root.currentPage < reader.pageCount - 1; Accessible.name: qsTr("Next page"); onClicked: root.navigate(root.currentPage + 1) }
            Item { Layout.fillWidth: true }
            ToolButton { action: fitAction }
            Label { text: qsTr("Ctrl + scroll to zoom"); color: theme.textTertiary; font.pixelSize: 11; visible: root.width > 850; Layout.rightMargin: 12 }
        }
    }
    FileDialog {
        id: fileDialog
        title: qsTr("Open a PDF")
        nameFilters: [qsTr("PDF documents (*.pdf)"), qsTr("All files (*)")]
        onAccepted: reader.openFile(selectedFile)
    }
    Dialog {
        id: passwordDialog
        anchors.centerIn: parent
        title: qsTr("Password required")
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        ColumnLayout {
            Label { text: qsTr("Enter the password for this PDF.") }
            TextField { id: passwordField; echoMode: TextInput.Password; Accessible.name: qsTr("PDF password"); onAccepted: passwordDialog.accept() }
        }
        onOpened: passwordField.forceActiveFocus()
        onAccepted: { reader.retryPassword(passwordField.text); passwordField.clear() }
        onRejected: passwordField.clear()
    }
    Timer { id: resizeTimer; interval: 0; onTriggered: if (root.fitting) root.fitWidth() }
    Connections {
        target: reader
        function onDocumentChanged() {
            if (reader.pageCount > 0) Qt.callLater(function() {
                root.fitWidth()
                root.navigate(0)
                sidebar.positionViewAtBeginning()
            })
        }
        function onPasswordRequiredChanged() { if (reader.passwordRequired) passwordDialog.open() }
    }
}

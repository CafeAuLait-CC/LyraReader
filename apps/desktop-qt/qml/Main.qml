import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtQuick.Window
import Lyra 1.0

ApplicationWindow {
    id: root
    objectName: "readerWindow"
    visible: true
    width: 1200
    height: 820
    minimumWidth: 640
    minimumHeight: 440
    title: reader.title === "Lyra" ? "Lyra" : reader.title + " — Lyra"
    color: palette.window
    property real zoom: 1
    property bool fitting: true
    property bool sidebarVisible: true
    property int currentPage: 0
    readonly property color accent: "#d16a3a"

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
        }
    }
    header: ToolBar {
        padding: 10
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
                implicitWidth: 30; implicitHeight: 30; radius: 9; color: root.accent
                Label { anchors.centerIn: parent; text: "L"; color: "white"; font.pixelSize: 19; font.weight: Font.DemiBold }
            }
            ColumnLayout {
                spacing: 1
                Layout.fillWidth: true
                Label { text: reader.pageCount > 0 ? reader.title : "Lyra"; elide: Text.ElideMiddle; Layout.fillWidth: true; font.weight: Font.DemiBold }
                Label { text: reader.loading ? qsTr("Opening document…") : reader.pageCount > 0 ? qsTr("%1 pages").arg(reader.pageCount) : qsTr("A little space to read"); font.pixelSize: 11; opacity: 0.6 }
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
            RowLayout {
                anchors.fill: parent
                Label { text: reader.error; wrapMode: Text.Wrap; Layout.fillWidth: true; Accessible.role: Accessible.AlertMessage }
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
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0
                    Label { text: qsTr("PAGES"); font.pixelSize: 11; font.letterSpacing: 1.5; opacity: 0.6; Layout.margins: 18 }
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
                            required property int index
                            width: ListView.view.width
                            height: 54
                            highlighted: root.currentPage === index
                            contentItem: RowLayout {
                                spacing: 12
                                Rectangle {
                                    implicitWidth: 25; implicitHeight: 33; radius: 2
                                    color: palette.base; border.color: palette.mid
                                    Label { anchors.centerIn: parent; text: index + 1; font.pixelSize: 9; opacity: 0.65 }
                                }
                                Label { text: qsTr("Page %1").arg(index + 1); Layout.fillWidth: true }
                            }
                            onClicked: root.navigate(index)
                        }
                    }
                }
            }
            Rectangle { visible: root.sidebarVisible && reader.pageCount > 0; Layout.preferredWidth: 1; Layout.fillHeight: true; color: palette.mid; opacity: 0.3 }
            Item {
                id: readingArea
                Layout.fillWidth: true
                Layout.fillHeight: true
                Rectangle { anchors.fill: parent; color: palette.dark; opacity: 0.09 }
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
                        color: palette.base; border.color: palette.mid
                        Label { anchors.centerIn: parent; text: "L"; color: root.accent; font.pixelSize: 32; font.weight: Font.Light }
                    }
                    Label { Layout.alignment: Qt.AlignHCenter; text: reader.loading ? qsTr("Opening your document") : qsTr("Make room for a good paper."); font.pixelSize: 23; font.weight: Font.Light }
                    Label { Layout.alignment: Qt.AlignHCenter; text: qsTr("Drop a PDF here, or open one to begin."); opacity: 0.6 }
                    Button { Layout.alignment: Qt.AlignHCenter; action: openAction; highlighted: true; visible: !reader.loading }
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
            Label { text: "/ " + reader.pageCount; opacity: 0.6 }
            ToolButton { text: "›"; font.pixelSize: 22; enabled: root.currentPage < reader.pageCount - 1; Accessible.name: qsTr("Next page"); onClicked: root.navigate(root.currentPage + 1) }
            Item { Layout.fillWidth: true }
            ToolButton { action: fitAction }
            Label { text: qsTr("Ctrl + scroll to zoom"); opacity: 0.5; font.pixelSize: 11; visible: root.width > 850; Layout.rightMargin: 12 }
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

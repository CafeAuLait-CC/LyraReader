import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

Item {
    id: overview
    required property var app
    property int draggingPage: -1
    property int dropIndex: -1
    property alias focusTarget: grid
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        ToolBar {
            Layout.fillWidth: true
            background: Rectangle {
                color: app.colors.panelBg
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 5
                LyraToolButton {
                    symbol: "plus"
                    text: qsTr("Insert Blank Page")
                    enabled: app.canModifyPdf
                    onClicked: app.pageOperation({
                        InsertBlank: {
                            index: Math.min(app.currentReader.pageCount, app.currentPage + 1)
                        }
                    })
                }
                LyraToolButton {
                    symbol: "rotate"
                    text: qsTr("Rotate Selected Pages")
                    enabled: app.canModifyPdf && app.selectedPages.length > 0
                    onClicked: app.pageOperation({
                        Rotate: {
                            pages: app.selectedPages,
                            quarter_turns: 1
                        }
                    })
                }
                LyraToolButton {
                    symbol: "export"
                    text: qsTr("Extract Selected Pages…")
                    enabled: app.canModifyPdf && app.selectedPages.length > 0
                    onClicked: app.chooseExport("extract")
                }
                LyraToolButton {
                    symbol: "delete"
                    text: qsTr("Delete Selected Pages")
                    enabled: app.canModifyPdf && app.selectedPages.length > 0 && app.selectedPages.length < app.currentReader.pageCount
                    onClicked: app.confirmPageDeletion()
                }
                LyraToolButton {
                    symbol: "back"
                    text: qsTr("Move Pages Earlier")
                    enabled: app.canModifyPdf && app.selectedPages.length > 0 && Math.min.apply(null, app.selectedPages) > 0
                    onClicked: app.movePages(Math.min.apply(null, app.selectedPages) - 1)
                }
                LyraToolButton {
                    symbol: "next"
                    text: qsTr("Move Pages Later")
                    enabled: app.canModifyPdf && app.selectedPages.length > 0
                    onClicked: app.movePages(Math.min(app.currentReader.pageCount, Math.max.apply(null, app.selectedPages) + 2))
                }
                Label {
                    textFormat: Text.PlainText
                    text: qsTr("%1 selected").arg(app.selectedPages.length)
                    color: app.colors.textSecondary
                    font.pixelSize: 11
                }
                Item {
                    Layout.fillWidth: true
                }
                Button {
                    text: qsTr("Apply to Original…")
                    enabled: app.canModifyPdf && !app.originalReadOnly
                    visible: app.pageEditsPending
                    onClicked: app.confirmReplace("pages")
                }
                Button {
                    text: qsTr("Discard…")
                    visible: app.pageEditsPending
                    onClicked: app.confirmDiscardPages()
                }
                LyraToolButton {
                    symbol: "close"
                    text: qsTr("Close Page Overview")
                    onClicked: app.overviewVisible = false
                }
            }
        }
        Label {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            Layout.margins: 10
            wrapMode: Text.Wrap
            text: app.xfaReadOnly ? app.readOnlyReason : app.originalReadOnly ? qsTr("Signed PDF: export changes to a new copy. The signed original cannot be replaced.") : app.pageEditsPending ? qsTr("Page changes are staged. The original PDF stays unchanged until Apply. Undo restores pages and their marks.") : qsTr("Space selects; Ctrl+Space toggles; Shift+Space selects a range. Enter opens a page. Drag to reorder.")
            color: app.colors.textSecondary
            font.pixelSize: 11
        }
        GridView {
            id: grid
            objectName: "pageOverview"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            cellWidth: 190
            cellHeight: 245
            leftMargin: Math.max(8, (width - Math.floor(width / cellWidth) * cellWidth) / 2)
            model: app.currentReader.pages
            keyNavigationEnabled: true
            function syncPage() {
                if (visible && count > 0) {
                    currentIndex = Math.max(0, Math.min(app.currentPage, count - 1));
                    positionViewAtIndex(currentIndex, GridView.Contain);
                }
            }
            onVisibleChanged: syncPage()
            onCountChanged: Qt.callLater(syncPage)
            Connections {
                target: app
                function onCurrentPageChanged() {
                    grid.syncPage();
                }
            }
            ScrollBar.vertical: ScrollBar {}
            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                objectName: "overviewPage" + index
                width: grid.cellWidth
                height: grid.cellHeight
                focus: GridView.isCurrentItem
                activeFocusOnTab: GridView.isCurrentItem
                function choosePage(modifiers) {
                    grid.currentIndex = index;
                    app.selectPage(index, modifiers);
                }
                Accessible.role: Accessible.ListItem
                Accessible.name: qsTr("Overview page %1").arg(index + 1)
                Accessible.description: qsTr("Space selects this page; Enter opens it. Control or Shift extends the selection.")
                Accessible.selectable: true
                Accessible.selected: app.selectedPages.indexOf(index) >= 0
                Accessible.onPressAction: choosePage(Qt.NoModifier)
                Keys.onSpacePressed: function (event) {
                    choosePage(event.modifiers);
                }
                Keys.onReturnPressed: {
                    app.navigate(index);
                    app.overviewVisible = false;
                }
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 8
                    radius: 5
                    color: app.selectedPages.indexOf(cell.index) >= 0 ? app.colors.selectedBg : hover.hovered ? app.colors.hoverBg : "transparent"
                    border.width: overview.dropIndex === cell.index || cell.activeFocus ? 2 : 0
                    border.color: cell.activeFocus ? app.colors.focusRing : app.colors.accentBorder
                    Column {
                        anchors.centerIn: parent
                        spacing: 8
                        Rectangle {
                            readonly property real thumbnailScale: Math.min(145 / cell.modelData.width, 190 / cell.modelData.height)
                            width: cell.modelData.width * thumbnailScale
                            height: cell.modelData.height * thumbnailScale
                            color: app.currentReader.paperBackground(app.paperAppearance)
                            border.color: app.colors.pageEdge
                            PdfPage {
                                resourceActive: cell.y + cell.height > grid.contentY && cell.y < grid.contentY + grid.height
                                anchors.fill: parent
                                anchors.margins: 1
                                paperAppearance: app.paperAppearance
                                controller: app.currentReader
                                pageIndex: cell.index
                                rasterScale: Math.min(143 / cell.modelData.width, 188 / cell.modelData.height)
                                embeddedAnnotations: true
                            }
                            AnnotationsLayer {
                                anchors.fill: parent
                                app: overview.app
                                page: cell.index
                                zoom: Math.min(parent.width / cell.modelData.width, parent.height / cell.modelData.height)
                                ownOnly: true
                            }
                        }
                        Label {
                            textFormat: Text.PlainText
                            width: 145
                            horizontalAlignment: Text.AlignHCenter
                            text: qsTr("Page %1").arg(cell.index + 1)
                            color: app.colors.textPrimary
                            font.pixelSize: 12
                        }
                    }
                    HoverHandler {
                        id: hover
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: function (mouse) {
                            cell.forceActiveFocus();
                            cell.choosePage(mouse.modifiers);
                        }
                        onDoubleClicked: {
                            app.navigate(cell.index);
                            app.overviewVisible = false;
                        }
                    }
                    DragHandler {
                        id: drag
                        enabled: app.canModifyPdf
                        target: null
                        onActiveChanged: {
                            if (active) {
                                overview.draggingPage = cell.index;
                                if (app.selectedPages.indexOf(cell.index) < 0)
                                    app.selectedPages = [cell.index];
                            } else if (overview.draggingPage >= 0) {
                                if (overview.dropIndex >= 0)
                                    app.movePages(overview.dropIndex);
                                overview.draggingPage = -1;
                                overview.dropIndex = -1;
                            }
                        }
                        onCentroidChanged: if (active) {
                            const p = grid.mapFromItem(null, centroid.scenePosition.x, centroid.scenePosition.y);
                            const index = grid.indexAt(p.x + grid.contentX, p.y + grid.contentY);
                            overview.dropIndex = index < 0 ? app.currentReader.pageCount : index;
                        }
                    }
                }
            }
        }
    }
}

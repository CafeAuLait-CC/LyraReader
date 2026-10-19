import QtQuick
import QtQuick.Controls
import LyraReader 1.0
import "ReaderLogic.js" as Logic

Item {
    id: canvas
    required property var app
    property alias view: pageList
    readonly property var rows: Logic.rows(app.currentReader.pages, app.pageGap)
    function navigate(page, y) {
        const placement = app.currentReader.pages[page];
        if (!placement)
            return;
        const target = (placement.top + (y || 0)) * app.zoom;
        pageList.contentY = Math.max(-pageList.topMargin, Math.min(target, Math.max(-pageList.topMargin, pageList.contentHeight - pageList.height + pageList.bottomMargin)));
    }
    function pageAtOffset() {
        const y = (pageList.contentY + Math.min(pageList.height / 3, 180)) / app.zoom;
        let page = 0;
        for (const p of app.currentReader.pages) {
            if (p.top > y)
                break;
            if (p.top + p.height >= y)
                return p.index;
            page = p.index;
        }
        return page;
    }
    ListView {
        id: pageList
        objectName: "pageList"
        anchors.fill: parent
        visible: app.currentReader.pageCount > 0
        model: canvas.rows
        clip: true
        contentWidth: Math.max(width, app.currentReader.documentWidth * app.zoom + 64)
        topMargin: 24
        bottomMargin: 24
        cacheBuffer: height / 2
        reuseItems: false
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.AutoFlickIfNeeded
        ScrollBar.vertical: ScrollBar {
            minimumSize: 0.04
        }
        ScrollBar.horizontal: ScrollBar {}
        onContentYChanged: {
            app.updateCurrentPage();
            app.schedulePositionSave();
        }
        onWidthChanged: if (app.fitting)
            app.fitResize()
        delegate: Item {
            required property var modelData
            width: pageList.contentWidth
            height: modelData.height * app.zoom
            Repeater {
                model: parent.modelData.pages
                delegate: Rectangle {
                    id: sheet
                    required property var modelData
                    width: modelData.width * app.zoom
                    height: modelData.height * app.zoom
                    x: (pageList.contentWidth - app.currentReader.documentWidth * app.zoom) / 2 + modelData.left * app.zoom
                    color: "white"
                    PdfPage {
                        id: pdfPage
                        objectName: "pdfPage" + sheet.modelData.index
                        anchors.fill: parent
                        paperAppearance: app.paperAppearance
                        controller: app.currentReader
                        pageIndex: sheet.modelData.index
                        rasterScale: app.zoom
                        Accessible.role: Accessible.Graphic
                        Accessible.name: qsTr("PDF page %1").arg(sheet.modelData.index + 1)
                    }
                    AnnotationsLayer {
                        anchors.fill: parent
                        app: canvas.app
                        page: sheet.modelData.index
                    }
                    PageInteraction {
                        anchors.fill: parent
                        app: canvas.app
                        page: sheet.modelData.index
                    }
                    BusyIndicator {
                        anchors.centerIn: parent
                        running: !pdfPage.loaded
                        visible: running
                        width: 34
                        height: 34
                    }
                }
            }
        }
        WheelHandler {
            acceptedModifiers: Qt.ControlModifier
            onWheel: function (event) {
                app.fitting = false;
                const delta = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y;
                app.changeZoom(app.zoom * Math.pow(1.0015, delta), event.x, event.y);
                event.accepted = true;
            }
        }
        PinchHandler {
            target: null
            property real previousScale: 1
            onActiveChanged: previousScale = 1
            onActiveScaleChanged: if (active) {
                app.fitting = false;
                app.changeZoom(app.zoom * activeScale / previousScale, centroid.position.x, centroid.position.y);
                previousScale = activeScale;
            }
        }
    }
}

import QtQuick
import QtQuick.Controls
import LyraReader 1.0
import "ReaderLogic.js" as Logic

Item {
    id: canvas
    required property var app
    property alias view: pageList
    readonly property var rows: Logic.rows(app.currentReader.pages, app.pageGap)
    property bool positioning: false
    readonly property var pageRows: {
        const result = {};
        for (let row = 0; row < rows.length; ++row)
            for (const page of rows[row].pages)
                result[page.index] = row;
        return result;
    }
    function clampY(value) {
        const first = pageList.originY - pageList.topMargin;
        return Math.max(first, Math.min(value, Math.max(first, pageList.originY + pageList.contentHeight - pageList.height + pageList.bottomMargin)));
    }
    // ListView may move its origin when earlier, uninstantiated rows change size.
    // Capture the actual row rather than interpreting contentY as a document offset.
    function viewportAnchor(viewY) {
        if (!rows.length)
            return null;
        const point = pageList.contentY + (viewY || 0);
        let row = pageList.indexAt(pageList.contentX + pageList.width / 2, point);
        if (row < 0)
            row = point < pageList.originY ? 0 : rows.length - 1;
        const item = pageList.itemAtIndex(row);
        if (!item)
            return {
                page: app.currentPage,
                y: 0
            };
        return {
            page: rows[row].pages[0].index,
            y: (point - item.y) / app.zoom
        };
    }
    function positionAnchor(anchor, viewY) {
        const row = pageRows[anchor.page];
        if (row === undefined)
            return;
        pageList.forceLayout();
        if (!pageList.itemAtIndex(row)) {
            pageList.positionViewAtIndex(row, ListView.Beginning);
            pageList.forceLayout();
        }
        const item = pageList.itemAtIndex(row);
        if (item)
            pageList.contentY = clampY(item.y + anchor.y * app.zoom - (viewY || 0));
    }
    function navigate(page, y) {
        positioning = true;
        positionAnchor({
            page: page,
            y: y || 0
        }, 0);
        positioning = false;
    }
    function restoreDocumentOffset(offset) {
        const y = offset / app.zoom;
        let row = 0;
        while (row + 1 < rows.length && rows[row + 1].top <= y)
            ++row;
        if (rows.length)
            navigate(rows[row].pages[0].index, y - rows[row].top);
    }
    function documentOffset(anchor) {
        const row = anchor ? pageRows[anchor.page] : undefined;
        return row === undefined ? 0 : (rows[row].top + anchor.y) * app.zoom;
    }
    function pageOffset(page) {
        const item = pageList.itemAtIndex(pageRows[page]);
        return item ? Math.max(0, (pageList.contentY - item.y) / app.zoom) : 0;
    }
    function documentX() {
        return (pageList.contentX - (pageList.contentWidth - app.currentReader.documentWidth * app.zoom) / 2) / app.zoom;
    }
    function restoreDocumentX(value) {
        const left = (pageList.contentWidth - app.currentReader.documentWidth * app.zoom) / 2;
        pageList.contentX = Math.max(0, Math.min(pageList.contentWidth - pageList.width, value * app.zoom + left));
    }
    function revealPage(page) {
        const placement = app.currentReader.pages[page];
        if (!placement)
            return;
        const left = (pageList.contentWidth - app.currentReader.documentWidth * app.zoom) / 2 + placement.left * app.zoom;
        if (left >= pageList.contentX + pageList.width || left + placement.width * app.zoom <= pageList.contentX)
            pageList.contentX = Math.max(0, Math.min(pageList.contentWidth - pageList.width, left - 24));
    }
    function changeZoom(value, anchorX, anchorY) {
        const anchor = viewportAnchor(anchorY);
        const old = app.zoom;
        const oldLeft = (pageList.contentWidth - app.currentReader.documentWidth * old) / 2;
        const pointX = (pageList.contentX + anchorX - oldLeft) / old;
        positioning = true;
        app.zoom = Math.max(0.1, Math.min(4, value));
        pageList.forceLayout();
        if (anchor)
            positionAnchor(anchor, anchorY);
        const newLeft = (pageList.contentWidth - app.currentReader.documentWidth * app.zoom) / 2;
        pageList.contentX = Math.max(0, Math.min(pageList.contentWidth - pageList.width, pointX * app.zoom + newLeft - anchorX));
        positioning = false;
        app.updateCurrentPage();
        app.schedulePositionSave();
    }
    function pageAtOffset() {
        const anchor = viewportAnchor(Math.min(pageList.height / 3, 180));
        if (!anchor)
            return 0;
        const row = rows[pageRows[anchor.page]];
        if (!row)
            return Math.min(app.currentPage, app.currentReader.pageCount - 1);
        for (const page of row.pages)
            if (page.height >= anchor.y)
                return page.index;
        return row.pages[row.pages.length - 1].index;
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
            id: rowItem
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
                        tilesEnabled: true
                        visibleRegion: Qt.rect((pageList.contentX - rowItem.x - sheet.x) / app.zoom, (pageList.contentY - rowItem.y - sheet.y) / app.zoom, pageList.width / app.zoom, pageList.height / app.zoom)
                        Accessible.role: Accessible.Graphic
                        Accessible.name: qsTr("PDF page %1").arg(sheet.modelData.index + 1)
                    }
                    AnnotationsLayer {
                        anchors.fill: parent
                        app: canvas.app
                        page: sheet.modelData.index
                        visibleRegion: pdfPage.visibleRegion
                    }
                    RedactionLayer {
                        anchors.fill: parent
                        app: canvas.app
                        page: sheet.modelData.index
                    }
                    PageInteraction {
                        anchors.fill: parent
                        app: canvas.app
                        page: sheet.modelData.index
                    }
                    FormOverlay {
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

import QtQuick
import QtQuick.Controls
import LyraReader 1.0

Item {
    id: canvas
    required property var app
    property alias view: pageList
    // Rust owns row grouping, unequal facing heights and the last-row gap. The shell only
    // attaches the corresponding existing page objects for its visual Repeater.
    readonly property var rows: app.currentReader.layoutRows.map(function(row) {
        return {top:row.top,bottom:row.bottom,height:row.height,
            pages:app.currentReader.pages.slice(row.first,row.first+row.count)};
    })
    property bool positioning: false
    property int placementEpoch: 0
    property real observedHeight: 0
    property bool pendingHeightChange: false
    property var resizeReader: null
    property int resizeEpoch: -1
    property var resizeRevision: null
    clip: true
    readonly property var pageRows: {
        const result = {};
        for (let row = 0; row < rows.length; ++row)
            for (const page of rows[row].pages)
                result[page.index] = row;
        return result;
    }
    // Keep the native editor outside virtualized page delegates. A layout snapshot may
    // replace those delegates while the user is typing; its QTextDocument must survive.
    function pageFrame(page, epoch) {
        const row=pageRows[page];
        const item=row===undefined ? null : pageList.itemAtIndex(row);
        if(!item)return null;
        for(let index=0;index<item.pageSheets.count;++index) {
            const sheet=item.pageSheets.itemAt(index);
            if(sheet && sheet.modelData.index===page)
                return {x:item.x+sheet.x-pageList.contentX,y:item.y+sheet.y-pageList.contentY,
                    width:sheet.width,height:sheet.height,paperMap:sheet.paperMap};
        }
        return null;
    }
    // Use actual instantiated sheets, including virtualized row origins and facing-page
    // offsets. One captured pointer can sweep across a gap into another visible page.
    function eraserSegments(sourcePage, from, to) {
        let source = null;
        const sheets = [];
        for (const row of pageList.contentItem.children) {
            if (row.objectName !== "pdfCanvasRow")
                continue;
            for (let i = 0; i < row.pageSheets.count; ++i) {
                const sheet = row.pageSheets.itemAt(i);
                if (!sheet) continue;
                sheets.push(sheet);
                if (sheet.modelData.index === sourcePage) source = sheet;
            }
        }
        if (!source) return {error:qsTr("The page moved. Try the eraser again.")};
        const segments=[];
        for(const sheet of sheets) {
            if(!sheet.paperMap)return {error:qsTr("The page moved. Try the eraser again.")};
            const a = source.mapToItem(sheet, from.x * app.zoom, from.y * app.zoom);
            const b = source.mapToItem(sheet, to.x * app.zoom, to.y * app.zoom);
            const mapped=sheet.paperMap.paperEraserSegments(Qt.point(a.x/app.zoom,a.y/app.zoom),Qt.point(b.x/app.zoom,b.y/app.zoom));
            if(mapped.error)return {error:mapped.error};
            for(const line of mapped.segments)segments.push({page:sheet.modelData.index,from:line.from,to:line.to});
        }
        return {segments:segments};
    }
    function clampY(value) {
        const first = pageList.originY;
        const clamped = app.currentReader.clampScroll(value-first,pageList.contentHeight,pageList.height);
        // An incomplete ListView layout has no scroll range yet; preserve its offset.
        return Number.isFinite(clamped) ? first+clamped : pageList.contentY;
    }
    function viewportChanged() {
        const heightChanged=observedHeight>0 && Math.abs(pageList.height-observedHeight)>.5;
        observedHeight=pageList.height;
        if(!app || app.positionRestoring || !app.currentReader || app.currentReader.loading || !rows.length
                || app.textViewVisible || app.overviewVisible) return;
        if(resizeReader!==app.currentReader || resizeEpoch!==app.positionRestoreEpoch)pendingHeightChange=false;
        pendingHeightChange=pendingHeightChange || heightChanged;
        resizeReader=app.currentReader;resizeEpoch=app.positionRestoreEpoch;
        resizeRevision=app.currentReader.data.document_revision;
        viewportSettle.restart();
    }
    function settleViewport() {
        const changed=pendingHeightChange;pendingHeightChange=false;
        if(resizeReader!==app.currentReader || resizeEpoch!==app.positionRestoreEpoch || app.positionRestoring
                || resizeRevision!==app.currentReader.data.document_revision || app.currentReader.loading
                || app.textViewVisible || app.overviewVisible || !rows.length)return;
        pageList.forceLayout();
        if(changed) {
            const page=app.currentReader.pages[0];
            // A fractional pinch percentage rounds down only at the integer policy boundary;
            // a returned integer still strictly exceeds the actual current percentage.
            const target=app.currentReader.viewportFitPercent(Math.floor(app.zoomPercent),page.height,pageList.height,app.calibrationFactor);
            if(target>0 && app.applyFit("page")) {
                app.operationStatus=qsTr("Fit page · %1%").arg(app.zoomPercent);
                return;
            }
        }
        pageList.contentY=clampY(pageList.contentY);
        const x=app.currentReader.clampScroll(pageList.contentX,pageList.contentWidth,pageList.width);
        if(Number.isFinite(x))pageList.contentX=x;
        app.updateCurrentPage();app.schedulePositionSave();
    }
    Timer {id:viewportSettle;interval:0;onTriggered:canvas.settleViewport()}
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
        app.zoom = Math.max(0.25 * app.calibrationFactor, Math.min(4 * app.calibrationFactor, value));
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
        // The document starts at the viewport top and ends at its bottom scroll limit.
        topMargin: 0
        bottomMargin: 0
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
        onWidthChanged: canvas.viewportChanged()
        onHeightChanged: canvas.viewportChanged()
        delegate: Item {
            id: rowItem
            objectName: "pdfCanvasRow"
            property alias pageSheets: sheetRepeater
            required property var modelData
            width: pageList.contentWidth
            height: modelData.height * app.zoom
            Repeater {
                id: sheetRepeater
                onItemAdded: function(index,item){++canvas.placementEpoch;}
                model: parent.modelData.pages
                delegate: Rectangle {
                    id: sheet
                    property alias paperMap: pdfPage
                    required property var modelData
                    width: modelData.width * app.zoom
                    height: modelData.height * app.zoom
                    x: (pageList.contentWidth - app.currentReader.documentWidth * app.zoom) / 2 + modelData.left * app.zoom
                    color: app.currentReader.paperBackground(app.paperAppearance)
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
                        paperMap: pdfPage
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
                        paperMap: pdfPage
                    }
                    FormOverlay {
                        anchors.fill: parent
                        app: canvas.app
                        page: sheet.modelData.index
                        paperMap: pdfPage
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
    PlacedTextLayer {
        app: canvas.app
        page: canvas.app.placedTextEditor && canvas.app.placedTextEditor.entry ? canvas.app.placedTextEditor.entry.page : -1
        readonly property var paperFrame: canvas.pageFrame(page,canvas.placementEpoch)
        paperMap: paperFrame ? paperFrame.paperMap : null
        // A temporarily absent delegate parks the editor outside the clipped viewport;
        // it does not destroy the editor, its focus, selection or native undo history.
        x: paperFrame ? paperFrame.x : -width-1
        y: paperFrame ? paperFrame.y : -height-1
        width: paperFrame ? paperFrame.width : canvas.width
        height: paperFrame ? paperFrame.height : canvas.height
        z: 1
    }
    ContentTextLayer {
        app: canvas.app
        page: canvas.app.contentEditor.textDraft ? canvas.app.contentEditor.draft.page : -1
        readonly property var paperFrame: canvas.pageFrame(page,canvas.placementEpoch)
        paperMap: paperFrame ? paperFrame.paperMap : null
        x: paperFrame ? paperFrame.x : -width-1
        y: paperFrame ? paperFrame.y : -height-1
        width: paperFrame ? paperFrame.width : canvas.width
        height: paperFrame ? paperFrame.height : canvas.height
        z: 2
    }

}

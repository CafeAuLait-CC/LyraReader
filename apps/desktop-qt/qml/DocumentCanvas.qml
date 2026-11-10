import QtQuick
import QtQuick.Controls
import LyraReader 1.0

Item {
    id: canvas
    objectName:"documentCanvas"
    required property var app
    property alias view: pageList
    // Rust owns row grouping, unequal facing heights and the last-row gap. The shell only
    // attaches the corresponding existing page objects for its visual Repeater.
    readonly property var rows: app.currentReader.layoutRows.map(function(row) {
        return {top:row.top,bottom:row.bottom,height:row.height,
            pages:app.currentReader.pages.slice(row.first,row.first+row.count)};
    })
    readonly property var paperState:app.currentReader.aiRegionPaper
    readonly property bool paperActive:!!paperState.rows && !paperState.error
    readonly property bool paperPlanning:!!paperState.loading
    readonly property real paperProgress:paperActive && app.regionPaper.owner===app.currentReader
            && app.regionPaper.opened ? app.regionPaper.revealProgress : 1
    readonly property bool paperMotionActive:paperActive && app.regionPaper.owner===app.currentReader
            && app.regionPaper.motionActive
    // Animate between the two Rust-produced endpoint layouts. This is a native view
    // interpolation, not another row grouping or paper-placement implementation.
    function paperMetric(source,target){return source+(target-source)*paperProgress;}
    property int interactionEpoch:0
    // Conversation text stays in view pixels. This pointer anchor exists only until
    // the asynchronous gap replan settles; persisted reading anchors stay in PDF space.
    property var pendingPaperZoom:null
    onPaperActiveChanged:if(!paperActive)pendingPaperZoom=null
    function restorePaperViewAnchor(anchor) {
        if(!anchor || anchor.owner!==app.currentReader || !paperActive
                || anchor.id!==paperState.id || anchor.interaction!==interactionEpoch)return false;
        pageList.forceLayout();
        const frame=regionCardFrame(anchor.owner);
        if(!frame)return false;
        const prior=positioning;positioning=true;
        pageList.contentY=clampY(pageList.contentY+frame.y+anchor.offsetY-anchor.viewY);
        positioning=prior;
        return true;
    }
    function finishPaperZoom(owner) {
        const anchor=pendingPaperZoom;
        if(!anchor || anchor.owner!==owner)return false;
        pendingPaperZoom=null;
        return restorePaperViewAnchor(anchor);
    }
    function displayRowTop(index){return paperActive ? paperMetric(rows[index].top,paperState.rows[index].top) : rows[index].top;}
    function regionCardFrame(owner,epoch) {
        if(!owner || owner!==app.currentReader || !paperActive)return null;
        const index=paperState.card_row;const item=pageList.itemAtIndex(index);
        const page=owner.pages[paperState.card.page];
        if(!item || !page)return null;
        const width=Math.min(Math.max(320,page.width*app.zoom-24),Math.max(240,Math.min(canvas.width-24,760)));
        const centre=(pageList.contentWidth-owner.documentWidth*app.zoom)/2+(page.left+page.width/2)*app.zoom-pageList.contentX;
        return {x:Math.min(Math.max(12,centre-width/2),Math.max(12,canvas.width-width-12)),
            y:item.y+(paperState.gap_top-displayRowTop(index))*app.zoom-pageList.contentY,
            width:width,height:paperState.card.gap_pt*app.zoom*paperProgress,page:paperState.card.page};
    }
    function showRegionCard(owner) {
        if(owner!==app.currentReader || !paperActive)return;
        positioning=true;
        if(!pageList.itemAtIndex(paperState.card_row))pageList.positionViewAtIndex(paperState.card_row,ListView.Beginning);
        pageList.forceLayout();
        const frame=regionCardFrame(owner);
        if(frame && frame.y<0)pageList.contentY=clampY(pageList.contentY+frame.y);
        else if(frame && frame.y+frame.height>height)
            pageList.contentY=clampY(pageList.contentY+frame.y+frame.height-height);
        positioning=false;app.updateCurrentPage();
    }
    property bool positioning: false
    property int placementEpoch: 0
    function refreshPlacement(){++placementEpoch;}
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
        const display=displayRowTop(row)+(point-item.y)/app.zoom;
        const source=paperActive ? app.currentReader.unshiftedPaperScroll(display,paperProgress) : display;
        if(!Number.isFinite(source))return null;
        return {page:rows[row].pages[0].index,y:source-rows[row].top};
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
    function restoreViewportAnchor(anchor,viewY) {
        if(!anchor)return;
        const row=pageRows[anchor.page];if(row===undefined)return;
        const source=rows[row].top+anchor.y;
        const display=paperActive ? app.currentReader.shiftedPaperScroll(source,paperProgress) : source;
        if(!Number.isFinite(display))return;
        const prior=positioning;positioning=true;
        positionAnchor({page:anchor.page,y:display-displayRowTop(row)},viewY || 0);
        positioning=prior;
    }
    function navigate(page, y) {
        ++interactionEpoch;positioning=true;
        const row=pageRows[page];
        if(row===undefined){positioning=false;return;}
        pageList.positionViewAtIndex(row,ListView.Beginning);pageList.forceLayout();
        const frame=pageFrame(page,placementEpoch);
        let target=y || 0;
        if(frame && frame.paperMap) {
            const mapped=frame.paperMap.paperAxisY(target,true,frame.paperMap.paperGeometryRevision);
            if(mapped.error || !mapped.hit){positioning=false;return;}
            target=mapped.y;
        }
        positionAnchor({page:page,y:target},0);
        positioning=false;
    }
    function restoreDocumentOffset(offset) {
        const y = offset / app.zoom;
        let row = 0;
        while (row + 1 < rows.length && rows[row + 1].top <= y)
            ++row;
        if (rows.length)
            restoreViewportAnchor({page:rows[row].pages[0].index,y:y-rows[row].top},0);
    }
    function documentOffset(anchor) {
        const row = anchor ? pageRows[anchor.page] : undefined;
        return row === undefined ? 0 : (rows[row].top + anchor.y) * app.zoom;
    }
    function pageOffset(page) {
        const item = pageList.itemAtIndex(pageRows[page]);
        if(!item)return 0;
        const local=(pageList.contentY-item.y)/app.zoom;
        const frame=pageFrame(page,placementEpoch);const card=regionCardFrame(app.currentReader);
        if(card && card.page===page && card.y<=0 && card.y+card.height>0)
            return app.currentReader.unshiftedPaperScroll(displayRowTop(pageRows[page])+local,paperProgress)-rows[pageRows[page]].top;
        if(frame && frame.paperMap) {
            const point=frame.paperMap.paperAxisY(local,false,frame.paperMap.paperGeometryRevision);
            if(point.hit)return Math.max(0,point.y);
        }
        return Math.max(0,local);
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
        ++interactionEpoch;
        const cardFrame=regionCardFrame(app.currentReader);
        const card=app.regionPaper;
        pendingPaperZoom=cardFrame && card && card.opened && anchorX>=cardFrame.x
                && anchorX<cardFrame.x+cardFrame.width && anchorY>=cardFrame.y
                && anchorY<cardFrame.y+card.height ? {owner:app.currentReader,id:paperState.id,
                    interaction:interactionEpoch,viewY:anchorY,offsetY:anchorY-cardFrame.y} : null;
        const anchor = viewportAnchor(anchorY);
        const old = app.zoom;
        const oldLeft = (pageList.contentWidth - app.currentReader.documentWidth * old) / 2;
        const pointX = (pageList.contentX + anchorX - oldLeft) / old;
        positioning = true;
        app.zoom = Math.max(0.25 * app.calibrationFactor, Math.min(4 * app.calibrationFactor, value));
        pageList.forceLayout();
        if (!restorePaperViewAnchor(pendingPaperZoom) && anchor)
            restoreViewportAnchor(anchor, anchorY);
        if(app.zoom===old)pendingPaperZoom=null;
        const newLeft = (pageList.contentWidth - app.currentReader.documentWidth * app.zoom) / 2;
        pageList.contentX = Math.max(0, Math.min(pageList.contentWidth - pageList.width, pointX * app.zoom + newLeft - anchorX));
        positioning = false;
        app.updateCurrentPage();
        app.schedulePositionSave();
    }
    function pageAtOffset() {
        const sample=Math.min(pageList.height/3,180);const card=regionCardFrame(app.currentReader);
        if(card && sample>=card.y && sample<card.y+card.height)return card.page;
        const anchor = viewportAnchor(sample);
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
        onMovementStarted:++canvas.interactionEpoch
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
            required property int index
            // Repeater completion precedes ListView's row registration. Refresh once
            // that registration has settled so overlays can find a recreated row.
            Component.onCompleted:Qt.callLater(canvas.refreshPlacement)
            readonly property var displayGeometry:canvas.paperActive ? canvas.paperState.rows[index] : modelData
            width: pageList.contentWidth
            height: (canvas.paperActive ? canvas.paperMetric(modelData.height,displayGeometry.height) : modelData.height) * app.zoom
            Repeater {
                id: sheetRepeater
                onItemAdded: function(index,item){++canvas.placementEpoch;}
                model: parent.modelData.pages
                delegate: Rectangle {
                    id: sheet
                    property alias paperMap: pdfPage
                    required property var modelData
                    readonly property var displayGeometry:canvas.paperActive ? canvas.paperState.pages[modelData.index] : modelData
                    function syncPaper() {
                        if(!pdfPage || pdfPage.pageIndex!==modelData.index)return;
                        const card=canvas.paperState.card;
                        if(canvas.paperActive && card.page===modelData.index && Number.isFinite(card.split_pt) && card.gap_pt>0)
                            pdfPage.configurePaper(modelData.height,card.split_pt,card.gap_pt*canvas.paperProgress);
                        else pdfPage.clearPaperGeometry();
                    }
                    function sourceViewport() {
                        const viewport=Qt.rect((pageList.contentX-rowItem.x-sheet.x)/app.zoom,(pageList.contentY-rowItem.y-sheet.y)/app.zoom,pageList.width/app.zoom,pageList.height/app.zoom);
                        if(!canvas.paperActive)return viewport;
                        const mapped=pdfPage.paperViewport(viewport,pdfPage.paperGeometryRevision);
                        return mapped.hit ? mapped.rect : Qt.rect(0,0,0,0);
                    }
                    onDisplayGeometryChanged:syncPaper()
                    Connections {target:canvas;function onPaperProgressChanged(){sheet.syncPaper();}}
                    Component.onCompleted:syncPaper()
                    width: modelData.width * app.zoom
                    height: (canvas.paperActive ? canvas.paperMetric(modelData.height,displayGeometry.height) : modelData.height) * app.zoom
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
                        rasterDemandPaused:canvas.paperMotionActive
                        visibleRegion:sheet.sourceViewport()
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
                        visible: running && (!canvas.paperActive || (pdfPage.visibleRegion.width>0 && pdfPage.visibleRegion.height>0))
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

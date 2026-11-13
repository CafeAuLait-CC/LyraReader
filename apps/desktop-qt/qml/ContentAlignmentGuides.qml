import QtQuick

// Native pointer chrome. Source bounds and document mutations stay in the shared engine.
Item {
    id: guides
    required property var app
    required property var editor
    required property int page
    property var paperMap: null
    // This bounds optional pointer chrome, not the document object model.
    readonly property int maximumItems: 4096
    property bool active: false
    property var owner: null
    property var generation: null
    property string revision: ""
    property string selectionId: ""
    property var paper: null
    property var paperRevision: null
    property real viewScale: 0
    property point scroll
    property size viewport
    property var xTargets: []
    property var yTargets: []
    property var verticalValues: []
    property var horizontalValues: []
    readonly property bool hasGuides: verticalValues.length > 0 || horizontalValues.length > 0
    signal invalidated()
    clip: true

    function same(a,b) {
        if(a.length!==b.length)return false;
        for(let i=0;i<a.length;++i)if(a[i]!==b[i])return false;
        return true;
    }
    function showLines(xs,ys) {
        if(!same(verticalValues,xs))verticalValues=xs;
        if(!same(horizontalValues,ys))horizontalValues=ys;
    }
    function clear() {
        active=false;owner=null;generation=null;revision="";selectionId="";paper=null;paperRevision=null;
        xTargets=[];yTargets=[];showLines([],[]);
    }
    function cancel() {const wasActive=active;clear();if(wasActive)invalidated();}
    function current() {
        return active && owner===app.currentReader && !owner.loading && page>=0 && page<owner.pages.length && generation===owner.documentGeneration
            && revision===editor.model.revision && editor.model.page===page && !!editor.selected
            && selectionId===editor.selected.id && editor.tool==="select" && app.secondaryRow==="edit"
            && viewScale===app.zoom && scroll.x===app.pageList.contentX && scroll.y===app.pageList.contentY
            && viewport.width===app.documentCanvas.width && viewport.height===app.documentCanvas.height
            && paper===paperMap && (paperRevision===null ? !paperMap || !paperMap.paperGeometryActive
                : !!paperMap && paperMap.paperGeometryActive && paperMap.paperGeometryRevision===paperRevision);
    }
    function unique(values) {
        values.sort(function(a,b){return a-b;});
        return values.filter(function(value,index){return !index || value!==values[index-1];});
    }
    function prepare(items) {
        clear();
        if(!editor.selected || !items || !editor.model.revision || editor.model.page!==page)return false;
        if(items.length>maximumItems) {
            app.operationStatus=qsTr("Alignment guides are unavailable on this dense page. You can still move the object.");
            return false;
        }
        const size=app.currentReader.pages[page],xs=[],ys=[];
        if(!size || !Number.isFinite(size.width) || !Number.isFinite(size.height) || size.width<=0 || size.height<=0 || !Number.isFinite(app.zoom) || app.zoom<=0)return false;
        let invalid=0;
        for(const item of items) {
            if(!item || typeof item!=="object"){++invalid;continue;}
            if(item.id===editor.selected.id)continue;
            const r=item.bounds;
            if(!r || !Number.isFinite(r.x) || !Number.isFinite(r.y) || !Number.isFinite(r.width)
                    || !Number.isFinite(r.height) || !Number.isFinite(r.x+r.width) || !Number.isFinite(r.y+r.height) || r.width<0 || r.height<0){++invalid;continue;}
            if(r.width===0 || r.height===0)continue;
            for(const x of [r.x,r.x+r.width/2,r.x+r.width])if(x>=0 && x<=size.width)xs.push(x);
            for(const y of [r.y,r.y+r.height/2,r.y+r.height])if(y>=0 && y<=size.height)ys.push(y);
        }
        if(invalid)app.operationStatus=qsTr("Some alignment targets are unavailable.");
        xTargets=unique(xs);yTargets=unique(ys);owner=app.currentReader;generation=owner.documentGeneration;
        revision=editor.model.revision;selectionId=editor.selected.id;viewScale=app.zoom;
        scroll=Qt.point(app.pageList.contentX,app.pageList.contentY);
        viewport=Qt.size(app.documentCanvas.width,app.documentCanvas.height);
        paper=paperMap;paperRevision=paperMap && paperMap.paperGeometryActive ? paperMap.paperGeometryRevision : null;
        active=true;return true;
    }
    function lowerBound(values,value) {
        let lo=0,hi=values.length;
        while(lo<hi){const mid=(lo+hi)>>1;if(values[mid]<value)lo=mid+1;else hi=mid;}
        return lo;
    }
    function viewY(source) {
        if(paperRevision===null)return source*viewScale;
        const mapped=paper.paperAxisY(source,true,paperRevision);
        if(mapped.error || !mapped.hit){if(mapped.error)app.operationStatus=mapped.error;cancel();return null;}
        return mapped.y*viewScale;
    }
    // Source order remains monotonic through the shared paper mapper. Only
    // neighbouring axes need mapping; no document query or raster runs here.
    function nearest(values,edges,vertical) {
        let best=null;
        for(const edge of edges) {
            const position=vertical ? viewY(edge) : edge*viewScale;
            if(position===null)return null;
            const index=lowerBound(values,edge);
            for(const candidate of [index-1,index]) {
                if(candidate<0 || candidate>=values.length)continue;
                const value=values[candidate],target=vertical ? viewY(value) : value*viewScale;
                if(target===null)return null;
                const distance=Math.abs(target-position);
                if(distance<4 && (!best || distance<best.distance || (distance===best.distance && value<best.value)))
                    best={value:value,delta:value-edge,distance:distance};
            }
        }
        return best;
    }
    function aligned(values,edges) {
        const result=[];
        for(const edge of edges){const i=lowerBound(values,edge-1e-7);if(i<values.length && Math.abs(values[i]-edge)<1e-7 && result.indexOf(values[i])<0)result.push(values[i]);}
        return result;
    }
    function adjust(rect) {
        if(!active)return rect;
        if(!current()){cancel();return null;}
        const x=nearest(xTargets,[rect.x,rect.x+rect.width/2,rect.x+rect.width],false);
        const y=nearest(yTargets,[rect.y,rect.y+rect.height/2,rect.y+rect.height],true);
        if(!active)return null;
        const size=owner.pages[page];
        const result={x:Math.max(0,Math.min(size.width-rect.width,rect.x+(x?x.delta:0))),
            y:Math.max(0,Math.min(size.height-rect.height,rect.y+(y?y.delta:0))),width:rect.width,height:rect.height};
        showLines(aligned(xTargets,[result.x,result.x+result.width/2,result.x+result.width]),
            aligned(yTargets,[result.y,result.y+result.height/2,result.y+result.height]));
        return result;
    }
    function verticalSegments() {
        const result=[];if(!active || !current())return result;
        const size=owner.pages[page];
        for(const x of verticalValues) {
            if(paperRevision===null)result.push({x:x*viewScale,y:0,height:size.height*viewScale});
            else {
                const region=paper.paperRegion(Qt.rect(x-.5/viewScale,0,1/viewScale,size.height),paperRevision);
                if(region.error){app.operationStatus=region.error;continue;}
                for(const piece of region.pieces || [])result.push({x:x*viewScale,y:piece.y*viewScale,height:piece.height*viewScale});
            }
        }
        return result;
    }
    Repeater {
        model:guides.verticalSegments()
        Rectangle {
            required property var modelData
            x:modelData.x-1.5;y:modelData.y;width:3;height:modelData.height
            color:app.colors.documentPaper
            Rectangle {x:1;width:1;height:parent.height;color:app.colors.documentInk}
        }
    }
    Repeater {
        model:guides.active ? guides.horizontalValues : []
        Rectangle {
            required property real modelData
            readonly property var position:guides.viewY(modelData)
            visible:position!==null
            x:0;y:position===null ? 0 : position-1.5;width:guides.width;height:3
            color:app.colors.documentPaper
            Rectangle {y:1;height:1;width:parent.width;color:app.colors.documentInk}
        }
    }
    Connections {target:guides.app;function onCurrentReaderChanged(){guides.cancel();}function onZoomChanged(){guides.cancel();}function onSecondaryRowChanged(){guides.cancel();}function onCancelContentGesture(){guides.cancel();}}
    Connections {target:guides.app.pageList;function onContentXChanged(){guides.cancel();}function onContentYChanged(){guides.cancel();}}
    Connections {target:guides.app.documentCanvas;function onWidthChanged(){guides.cancel();}function onHeightChanged(){guides.cancel();}}
    Connections {target:guides.owner;function onDocumentChanged(){guides.cancel();}}
    Connections {target:guides.editor;function onModelChanged(){guides.cancel();}function onSelectedChanged(){guides.cancel();}function onToolChanged(){guides.cancel();}}
    Connections {target:guides.paperMap;function onPaperGeometryChanged(){guides.cancel();}}
    onPaperMapChanged:cancel()
    onVisibleChanged:if(!visible)cancel()
}

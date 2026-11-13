import QtQuick
import QtQuick.Controls
import LyraReader 1.0

Item {
    id: layer
    objectName:"contentPageLayer"+page
    required property var app
    required property int page
    property var paperMap: null
    readonly property bool paperActive: !!paperMap && paperMap.paperGeometryActive
    readonly property var editor: app.contentEditor
    readonly property var selected: editor.selected
    readonly property bool ready: editor.model.page===page && editor.model.revision.length>0
    readonly property var shown: editor.gesture || (selected && ready ? selected.bounds : null)
    property var hoverItem:null
    property var hoverOwner:null
    property var hoverGeneration:null
    property string hoverRevision:""
    property real hoverZoom:0
    readonly property var hovered:visible && app.secondaryRow==="edit" && editor.tool==="select" && pointer.containsMouse && ready
        && hoverOwner===app.currentReader && hoverGeneration===app.currentReader.documentGeneration
        && hoverRevision===editor.model.revision && hoverZoom===app.zoom ? hoverItem : null
    readonly property bool showsHover:!!hovered && (!selected || selected.id!==hovered.id)
    function clearHover(){hoverItem=null;hoverOwner=null;hoverGeneration=null;hoverRevision="";}
    onVisibleChanged:if(!visible){clearHover();if(pointer)pointer.cancelGesture();}
    onPaperMapChanged:if(pointer)pointer.cancelGesture()
    onReadyChanged:if(!ready && pointer)pointer.cancelGesture()
    Connections {
        target:layer.app
        function onCancelContentGesture(){pointer.cancelGesture();}
    }
    Connections {target:layer.editor;function onToolChanged(){layer.clearHover();} function onModelChanged(){layer.clearHover();}}
    Connections {target:layer.app;function onCurrentReaderChanged(){layer.clearHover();} function onZoomChanged(){layer.clearHover();}}
    Connections {target:layer.app.pageList;function onContentYChanged(){layer.clearHover();} function onContentXChanged(){layer.clearHover();}}
    Rectangle {
        objectName:"contentHoverFrame"+layer.page
        visible:layer.showsHover && !layer.paperActive
        x:layer.hovered ? layer.hovered.bounds.x*app.zoom : 0;y:layer.hovered ? layer.hovered.bounds.y*app.zoom : 0
        width:layer.hovered ? layer.hovered.bounds.width*app.zoom : 0;height:layer.hovered ? layer.hovered.bounds.height*app.zoom : 0
        color:"transparent";border.width:1;border.color:app.colors.focusRing
    }
    PdfAnnotations {
        objectName:"paperContentHoverFrame"+layer.page
        anchors.fill:parent;visible:layer.paperActive && layer.showsHover
        paperMap:layer.paperMap;zoom:app.zoom
        annotations:visible ? [{id:"ui-content-hover",kind:"square",rect:layer.hovered.bounds,color:app.colors.focusRing,strokeWidth:1/app.zoom}] : []
    }
    Rectangle {
        visible: !!layer.shown && !layer.paperActive
        x: layer.shown ? layer.shown.x*app.zoom : 0
        y: layer.shown ? layer.shown.y*app.zoom : 0
        width: layer.shown ? layer.shown.width*app.zoom : 0
        height: layer.shown ? layer.shown.height*app.zoom : 0
        color: "transparent"
        border.width: 2
        border.color: app.colors.focusRing
    }
    PdfAnnotations {
        objectName: "paperContentFrame"+layer.page
        anchors.fill: parent
        visible: layer.paperActive && !!layer.shown
        paperMap: layer.paperMap
        zoom: app.zoom
        annotations: visible ? [{id:"ui-content-frame",kind:"square",rect:layer.shown,color:app.colors.focusRing,strokeWidth:2/app.zoom}] : []
    }
    ContentAlignmentGuides {
        id:alignment
        objectName:"contentAlignmentGuides"+layer.page
        anchors.fill:parent;z:1
        app:layer.app;editor:layer.editor;page:layer.page;paperMap:layer.paperMap
        onInvalidated:pointer.cancelGesture()
    }
    Connections {target:layer.paperMap;function onPaperGeometryChanged(){if(pointer.began && !pointer.currentGesture())pointer.cancelGesture();}}
    Connections {target:layer.app;function onZoomChanged(){pointer.cancelGesture();}function onCurrentReaderChanged(){pointer.cancelGesture();}function onSecondaryRowChanged(){if(layer.app.secondaryRow!=="edit")pointer.cancelGesture();}}
    Connections {target:layer.app.pageList;function onContentXChanged(){if(pointer.began)pointer.cancelGesture();}function onContentYChanged(){if(pointer.began)pointer.cancelGesture();}}
    Connections {target:layer.app.documentCanvas;function onWidthChanged(){pointer.cancelGesture();}function onHeightChanged(){pointer.cancelGesture();}}
    Connections {target:layer.editor;function onModelChanged(){if(pointer.began && (pointer.pressRevision!==layer.editor.model.revision || layer.editor.model.page!==layer.page))pointer.cancelGesture();}function onToolChanged(){pointer.cancelGesture();}function onHasDraftChanged(){if(pointer.began && layer.editor.hasDraft)pointer.cancelGesture();}function onSelectedChanged(){if(pointer.began && pointer.hit && (!layer.editor.selected || pointer.hit.id!==layer.editor.selected.id))pointer.cancelGesture();}}
    Connections {target:pointer.pressOwner;function onDocumentChanged(){if(pointer.began && (pointer.pressOwner.loading || !pointer.currentGesture()))pointer.cancelGesture();}}
    MouseArea {
        id:pointer
        anchors.fill: parent
        objectName: "contentPointer"+layer.page
        enabled: !app.contentEditor.pending
        hoverEnabled:editor.tool==="select"
        cursorShape:editor.tool!=="select" ? Qt.CrossCursor : dragging && !!editor.gesture ? Qt.ClosedHandCursor : layer.hovered && selected && layer.hovered.id===selected.id ? Qt.OpenHandCursor : Qt.ArrowCursor
        function updateHover(mouse) {
            if(pressed || editor.tool!=="select" || !layer.ready){layer.clearHover();return;}
            const p=position(mouse);
            layer.hoverItem=p ? at(p.x,p.y) : null;layer.hoverOwner=app.currentReader;
            layer.hoverGeneration=app.currentReader.documentGeneration;layer.hoverRevision=editor.model.revision;layer.hoverZoom=app.zoom;
        }
        onEntered:updateHover({x:mouseX,y:mouseY})
        onExited:layer.clearHover()
        acceptedButtons: Qt.LeftButton
        preventStealing: pressed
        activeFocusOnTab: true
        Accessible.role: Accessible.Canvas
        Accessible.name: qsTr("Edit PDF content on page %1").arg(layer.page+1)
        property point start
        property var hit: null
        property bool dragging: false
        property bool began: false
        property string pressRevision: ""
        property string pressTool:""
        property real pressZoom:0
        property point pressScroll
        property size pressViewport
        property var pressOwner: null
        property var pressGeneration: null
        property var pressPaper: null
        property var pressPaperRevision: null
        property bool pressFreeMove: false
        property var ownGesture: null
        function currentGesture() {return !!pressOwner && pressOwner===app.currentReader && pressGeneration===app.currentReader.documentGeneration && pressTool===editor.tool && app.secondaryRow==="edit" && pressZoom===app.zoom && pressScroll.x===app.pageList.contentX && pressScroll.y===app.pageList.contentY && pressViewport.width===app.documentCanvas.width && pressViewport.height===app.documentCanvas.height && pressPaper===layer.paperMap
            && (pressPaperRevision===null ? !layer.paperActive : layer.paperActive && layer.paperMap.paperGeometryRevision===pressPaperRevision);}
        function showGesture(rect) {ownGesture=rect;editor.gesture=rect;}
        function cancelGesture() {
            const wasActive=began || dragging,patch=ownGesture;
            began=false;dragging=false;ownGesture=null;hit=null;
            if(patch && editor.gesture===patch)editor.gesture=null;
            alignment.clear();
            if(app.documentCanvas.contentPointerOwner===pointer)app.documentCanvas.contentPointerOwner=null;
            if(wasActive)app.documentCanvas.dragPreview.cancel();
        }
        function position(mouse) {
            if(layer.paperActive) {
                if(layer.paperMap.controller!==app.currentReader)return null;
                const mapped=layer.paperMap.paperPoint(Qt.point(mouse.x/app.zoom,mouse.y/app.zoom));
                if(mapped.error)app.operationStatus=mapped.error;
                return mapped.hit ? Qt.point(mapped.x,mapped.y) : null;
            }
            return Qt.point(mouse.x/app.zoom,mouse.y/app.zoom);
        }
        function at(x,y) {
            if (!layer.ready) return null;
            let closest=null,area=Infinity;
            for(const item of editor.model.items) {
                const r=item.bounds,size=r.width*r.height;
                if(x>=r.x && x<=r.x+r.width && y>=r.y && y<=r.y+r.height && size<area){closest=item;area=size;}
            }
            return closest;
        }
        function area(x,y) {
            const size=app.currentReader.pages[layer.page];
            const left=Math.max(0,Math.min(start.x,x)),top=Math.max(0,Math.min(start.y,y));
            return {x:left,y:top,width:Math.max(1,Math.min(size.width,Math.max(start.x,x))-left),
                height:Math.max(1,Math.min(size.height,Math.max(start.y,y))-top)};
        }
        onPressed: function(mouse) {
            cancelGesture();layer.clearHover();app.documentCanvas.dragPreview.cancel();
            // Suspending parent flicking can quantize its scroll position. Re-map
            // the original press through stable canvas coordinates before capture.
            const scene=mapToItem(app.documentCanvas,mouse.x,mouse.y);
            app.documentCanvas.contentPointerOwner=pointer;
            const local=mapFromItem(app.documentCanvas,scene.x,scene.y);
            const p=position(local);if(!p){cancelGesture();return;}
            forceActiveFocus();
            app.currentPage=layer.page;
            pressOwner=app.currentReader;pressGeneration=app.currentReader.documentGeneration;
            began=layer.ready;pressRevision=editor.model.revision;pressTool=editor.tool;pressZoom=app.zoom;pressScroll=Qt.point(app.pageList.contentX,app.pageList.contentY);pressViewport=Qt.size(app.documentCanvas.width,app.documentCanvas.height);
            pressPaper=layer.paperMap;pressPaperRevision=layer.paperActive ? layer.paperMap.paperGeometryRevision : null;
            pressFreeMove=!!(mouse.modifiers & Qt.ShiftModifier);
            if (!layer.ready) {cancelGesture();editor.reload();return;}
            start=p;hit=at(start.x,start.y);
        }
        onPositionChanged: function(mouse) {
            if(!pressed){updateHover(mouse);return;}
            if (!pressed || !began || !layer.ready || editor.hasDraft || !currentGesture() || pressRevision!==editor.model.revision) return;
            const p=position(mouse);if(!p)return;
            const x=p.x,y=p.y;
            if (Math.abs(x-start.x)+Math.abs(y-start.y)<3) return;
            const first=!dragging;dragging=true;
            if (["erase","blackout","link"].indexOf(editor.tool)>=0) showGesture(area(x,y));
            else if (hit && selected && hit.id===selected.id) {
                const size=app.currentReader.pages[layer.page],r=hit.bounds;
                if(first && editor.tool==="select" && hit.kind!=="link")app.documentCanvas.dragPreview.prepare(layer.page,hit.id,editor.model.revision,Qt.rect(r.x,r.y,r.width,r.height));
                if(first && !pressFreeMove)alignment.prepare(editor.model.items);
                let rect={x:Math.max(0,Math.min(size.width-r.width,r.x+x-start.x)),
                    y:Math.max(0,Math.min(size.height-r.height,r.y+y-start.y)),width:r.width,height:r.height};
                if(pressFreeMove || (mouse.modifiers & Qt.ShiftModifier))alignment.showLines([],[]);
                else {rect=alignment.adjust(rect);if(!rect)return;}
                showGesture(rect);
                if(app.documentCanvas.dragPreview.active)app.documentCanvas.dragPreview.offset=Qt.point(editor.gesture.x-r.x,editor.gesture.y-r.y);
            }
        }
        onReleased: function(mouse) {
            if (!began || !layer.ready || !currentGesture() || pressRevision!==editor.model.revision){cancelGesture();return;}
            const moved=dragging;began=false;dragging=false;alignment.clear();ownGesture=null;
            const p=position(mouse);
            if(!p){editor.gesture=null;cancelGesture();app.documentCanvas.dragPreview.cancel();return;}
            const x=p.x,y=p.y;
            if (moved && ["erase","blackout"].indexOf(editor.tool)>=0) editor.redact(area(x,y),layer.page);
            else if (moved && editor.tool==="link") {editor.selected=null;editor.gesture=area(x,y);}
            else if (moved && editor.gesture && hit) {const bounds=editor.gesture;editor.gesture=null;editor.applyGeometry(hit,bounds);if(editor.pending)app.documentCanvas.dragPreview.hold(editor.pending.id);else app.documentCanvas.dragPreview.cancel();}
            else if (hit) editor.select(hit,layer.page);
            else if (editor.tool==="text") {
                const size=app.currentReader.pages[layer.page];
                editor.insertText({x:Math.max(0,Math.min(x,size.width-180)),y:Math.max(0,Math.min(y,size.height-50)),width:Math.min(180,size.width),height:Math.min(50,size.height)},layer.page);
            } else if (editor.tool==="image") {
                const size=app.currentReader.pages[layer.page];
                editor.chooseImage({x:Math.max(0,Math.min(x,size.width-150)),y:Math.max(0,Math.min(y,size.height-100)),width:Math.min(150,size.width),height:Math.min(100,size.height)},null);
            } else editor.selected=null;
            if(!moved)app.documentCanvas.dragPreview.cancel();
            if(app.documentCanvas.contentPointerOwner===pointer)app.documentCanvas.contentPointerOwner=null;
        }
        onDoubleClicked: function(mouse) {const p=position(mouse);if(!p)return;const item=at(p.x,p.y);if(item && item.kind==="text")editor.editText(item,layer.page);}
        onCanceled:cancelGesture()
        Keys.onEscapePressed: {
            cancelGesture();app.documentCanvas.dragPreview.cancel();
            if (editor.inlineEditing) {editor.discard();return;}
            editor.gesture=null;editor.selected=null;editor.tool="select";
        }
        Keys.onReturnPressed:if(editor.tool==="select" && selected && selected.kind==="text")editor.editText(selected,layer.page)
        Keys.onPressed:function(event){if(event.key===Qt.Key_F2 && editor.tool==="select" && selected && selected.kind==="text"){editor.editText(selected,layer.page);event.accepted=true;}}
        Keys.onDeletePressed: editor.remove()
    }
    ContentResizeHandles {
        anchors.fill:parent;z:2
        app:layer.app;page:layer.page;editor:layer.editor;paperMap:layer.paperMap;focusTarget:pointer
    }

}

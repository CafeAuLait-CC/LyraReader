import QtQuick

// Native gesture chrome only. The existing typed Transform owns PDF geometry,
// validation, revision checks, undo, recovery and Save.
Item {
    id: handles
    objectName:"contentResizeHandles"+page
    required property var app
    required property int page
    required property var editor
    property var paperMap: null
    property var focusTarget: null
    readonly property var shown: editor.gesture || (editor.selected ? editor.selected.bounds : null)
    visible: app.canModifyPdf && app.secondaryRow==="edit" && editor.tool==="select"
        && editor.model.page===page && !!editor.selected
        && (editor.selected.kind==="text" || editor.selected.kind==="image")
        && !editor.hasDraft && !editor.pending
    property var base: null
    property var patch: null
    property var editOwner: null
    property var editGeneration: null
    property var editPaper: null
    property var editPaperRevision: null
    property string editRevision: ""
    property real editZoom: 0
    property point editScroll
    property size editViewport
    property int corner: -1

    function current() {
        return !!base && editOwner===app.currentReader && editGeneration===editOwner.documentGeneration
            && editRevision===editor.model.revision && editor.model.page===page
            && paperMap===editPaper && (editPaperRevision===null
                ? (!paperMap || !paperMap.paperGeometryActive)
                : !!paperMap && paperMap.paperGeometryActive && paperMap.paperGeometryRevision===editPaperRevision)
            && !!editor.selected && base.id===editor.selected.id && editor.tool==="select"
            && app.secondaryRow==="edit" && editZoom===app.zoom
            && editScroll.x===app.pageList.contentX && editScroll.y===app.pageList.contentY
            && editViewport.width===app.documentCanvas.width && editViewport.height===app.documentCanvas.height;
    }
    function begin(index) {
        cancel();
        if(!visible || editor.owner.pendingCommands)return false;
        app.documentCanvas.dragPreview.cancel();
        base=editor.selected;corner=index;editOwner=app.currentReader;
        editGeneration=editOwner.documentGeneration;editRevision=editor.model.revision;
        editPaper=paperMap;editPaperRevision=paperMap && paperMap.paperGeometryActive ? paperMap.paperGeometryRevision : null;
        editZoom=app.zoom;editScroll=Qt.point(app.pageList.contentX,app.pageList.contentY);
        editViewport=Qt.size(app.documentCanvas.width,app.documentCanvas.height);
        return true;
    }
    function point(x,y) {
        if(!current())return null;
        if(paperMap && paperMap.paperGeometryActive) {
            if(paperMap.controller!==editOwner)return null;
            const p=paperMap.paperPoint(Qt.point(x/app.zoom,y/app.zoom));
            if(p.error)app.operationStatus=p.error;
            return p.hit ? Qt.point(p.x,p.y) : null;
        }
        return Qt.point(x/app.zoom,y/app.zoom);
    }
    function resizeAt(x,y) {
        const p=point(x,y);if(!p)return;
        const size=editOwner.pages[page],r=base.bounds,minimum=2/app.zoom;
        const px=Math.max(0,Math.min(size.width,p.x)),py=Math.max(0,Math.min(size.height,p.y));
        const left=corner===0 || corner===2,top=corner<2;
        const x1=left ? Math.min(px,r.x+r.width-minimum) : r.x;
        const x2=left ? r.x+r.width : Math.max(px,r.x+minimum);
        const y1=top ? Math.min(py,r.y+r.height-minimum) : r.y;
        const y2=top ? r.y+r.height : Math.max(py,r.y+minimum);
        patch={x:x1,y:y1,width:x2-x1,height:y2-y1};editor.gesture=patch;
    }
    function finish(x,y) {
        const valid=!!point(x,y),item=base,bounds=patch;
        cancel();
        if(valid && bounds && item && (Math.abs(bounds.x-item.bounds.x)>.001
            || Math.abs(bounds.y-item.bounds.y)>.001 || Math.abs(bounds.width-item.bounds.width)>.001
            || Math.abs(bounds.height-item.bounds.height)>.001))editor.applyGeometry(item,bounds);
        if(valid && focusTarget)focusTarget.forceActiveFocus();
    }
    function cancel() {
        if(patch && editor.gesture===patch)editor.gesture=null;
        base=null;patch=null;editOwner=null;editGeneration=null;editPaper=null;editPaperRevision=null;editRevision="";corner=-1;
    }
    onVisibleChanged:if(!visible)cancel()
    onPaperMapChanged:if(base)cancel()
    Connections {target:handles.paperMap;function onPaperGeometryChanged(){if(handles.base && !handles.current())handles.cancel();}}
    Connections {
        target:handles.app
        function onCancelContentGesture(){handles.cancel();}
        function onZoomChanged(){handles.cancel();}
        function onCurrentReaderChanged(){handles.cancel();}
        function onSecondaryRowChanged(){if(handles.app.secondaryRow!=="edit")handles.cancel();}
    }
    Connections {target:handles.app.pageList;function onContentXChanged(){handles.cancel();}function onContentYChanged(){handles.cancel();}}
    Connections {target:handles.app.documentCanvas;function onWidthChanged(){handles.cancel();}function onHeightChanged(){handles.cancel();}}
    Connections {target:handles.editor;function onModelChanged(){if(handles.base && !handles.current())handles.cancel();}function onSelectedChanged(){if(handles.base && !handles.current())handles.cancel();}function onToolChanged(){handles.cancel();}}
    Connections {target:handles.editor.owner;function onDocumentChanged(){if(handles.base && (!handles.current() || handles.editOwner.loading))handles.cancel();}}
    Repeater {
        model:handles.visible ? 4 : 0
        Rectangle {
            id:grip
            required property int index
            objectName:"contentResizeHandle"+index
            readonly property var position:handles.shown ? Qt.point(handles.shown.x+(index%2 ? handles.shown.width : 0),handles.shown.y+(index>=2 ? handles.shown.height : 0)) : Qt.point(0,0)
            readonly property var displayY:handles.paperMap && handles.paperMap.controller!==handles.app.currentReader ? {hit:false}
                : handles.paperMap && handles.paperMap.paperGeometryActive
                    ? handles.paperMap.paperAxisY(position.y,true,handles.paperMap.paperGeometryRevision) : {hit:true,y:position.y}
            onDisplayYChanged:if(displayY.error)handles.app.operationStatus=displayY.error
            visible:displayY.hit===true
            x:position.x*handles.app.zoom-width/2;y:displayY.hit ? displayY.y*handles.app.zoom-height/2 : 0
            width:10;height:10;radius:5
            color:handles.app.colors.raisedBg;border.color:handles.app.colors.focusRing;border.width:1.5
            Accessible.role:Accessible.Button
            Accessible.name:qsTr("PDF content resize corner %1").arg(index+1)
            MouseArea {
                anchors.fill:parent;anchors.margins:-4
                preventStealing:pressed
                cursorShape:grip.index===0 || grip.index===3 ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
                onPressed:{forceActiveFocus();handles.begin(grip.index);}
                onPositionChanged:function(mouse){if(pressed){const p=mapToItem(handles,mouse.x,mouse.y);handles.resizeAt(p.x,p.y);}}
                onReleased:function(mouse){const p=mapToItem(handles,mouse.x,mouse.y);handles.finish(p.x,p.y);}
                onCanceled:handles.cancel()
                Keys.onEscapePressed:handles.cancel()
            }
        }
    }
}

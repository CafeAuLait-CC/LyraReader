import QtQuick
import QtQuick.Controls
import LyraReader 1.0

Item {
    id: layer
    required property var app
    required property int page
    property var paperMap: null
    readonly property bool paperActive: !!paperMap && paperMap.paperGeometryActive
    readonly property var editor: app.contentEditor
    readonly property var selected: editor.selected
    readonly property bool ready: editor.model.page===page && editor.model.revision.length>0
    readonly property var shown: editor.gesture || (selected && ready ? selected.bounds : null)
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
    MouseArea {
        anchors.fill: parent
        objectName: "contentPointer"+layer.page
        enabled: !app.contentEditor.pending
        cursorShape: editor.tool==="select" ? Qt.ArrowCursor : Qt.CrossCursor
        acceptedButtons: Qt.LeftButton
        activeFocusOnTab: true
        Accessible.role: Accessible.Canvas
        Accessible.name: qsTr("Edit PDF content on page %1").arg(layer.page+1)
        property point start
        property var hit: null
        property bool dragging: false
        property bool began: false
        property string pressRevision: ""
        property var pressOwner: null
        property var pressGeneration: null
        function currentGesture() {return !!pressOwner && pressOwner===app.currentReader && pressGeneration===app.currentReader.documentGeneration;}
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
            const hits=editor.model.items.filter(function(item){const r=item.bounds;
                return x>=r.x && x<=r.x+r.width && y>=r.y && y<=r.y+r.height;});
            hits.sort(function(a,b){return a.bounds.width*a.bounds.height-b.bounds.width*b.bounds.height;});
            return hits[0] || null;
        }
        function area(x,y) {
            const size=app.currentReader.pages[layer.page];
            const left=Math.max(0,Math.min(start.x,x)),top=Math.max(0,Math.min(start.y,y));
            return {x:left,y:top,width:Math.max(1,Math.min(size.width,Math.max(start.x,x))-left),
                height:Math.max(1,Math.min(size.height,Math.max(start.y,y))-top)};
        }
        onPressed: function(mouse) {
            began=false;dragging=false;
            const p=position(mouse);if(!p)return;
            forceActiveFocus();
            app.currentPage=layer.page;
            pressOwner=app.currentReader;pressGeneration=app.currentReader.documentGeneration;
            began=layer.ready;pressRevision=editor.model.revision;
            if (!layer.ready) {editor.reload();return;}
            start=p;hit=at(start.x,start.y);
        }
        onPositionChanged: function(mouse) {
            if (!pressed || !began || !layer.ready || editor.hasDraft || !currentGesture() || pressRevision!==editor.model.revision) return;
            const p=position(mouse);if(!p)return;
            const x=p.x,y=p.y;
            if (Math.abs(x-start.x)+Math.abs(y-start.y)<3) return;
            dragging=true;
            if (["erase","blackout","link"].indexOf(editor.tool)>=0) editor.gesture=area(x,y);
            else if (hit && selected && hit.id===selected.id) {
                const size=app.currentReader.pages[layer.page],r=hit.bounds;
                editor.gesture={x:Math.max(0,Math.min(size.width-r.width,r.x+x-start.x)),
                    y:Math.max(0,Math.min(size.height-r.height,r.y+y-start.y)),width:r.width,height:r.height};
            }
        }
        onReleased: function(mouse) {
            if (!began || !layer.ready || !currentGesture() || pressRevision!==editor.model.revision) return;
            began=false;
            const p=position(mouse);
            if(!p){editor.gesture=null;dragging=false;hit=null;return;}
            const x=p.x,y=p.y;
            if (dragging && ["erase","blackout"].indexOf(editor.tool)>=0) editor.redact(area(x,y),layer.page);
            else if (dragging && editor.tool==="link") {editor.selected=null;editor.gesture=area(x,y);}
            else if (dragging && editor.gesture && hit) {const bounds=editor.gesture;editor.gesture=null;editor.applyGeometry(hit,bounds);}
            else if (hit) editor.select(hit,layer.page);
            else if (editor.tool==="text") {
                const size=app.currentReader.pages[layer.page];
                editor.insertText({x:Math.max(0,Math.min(x,size.width-180)),y:Math.max(0,Math.min(y,size.height-50)),width:Math.min(180,size.width),height:Math.min(50,size.height)},layer.page);
            } else if (editor.tool==="image") {
                const size=app.currentReader.pages[layer.page];
                editor.chooseImage({x:Math.max(0,Math.min(x,size.width-150)),y:Math.max(0,Math.min(y,size.height-100)),width:Math.min(150,size.width),height:Math.min(100,size.height)},null);
            } else editor.selected=null;
        }
        onDoubleClicked: function(mouse) {const p=position(mouse);if(!p)return;const item=at(p.x,p.y);if(item && item.kind==="text")editor.editText(item,layer.page);}
        onCanceled: {if(currentGesture())editor.gesture=null;dragging=false;began=false;}
        Keys.onEscapePressed: {
            began=false;dragging=false;
            if (editor.inlineEditing) {editor.discard();return;}
            editor.gesture=null;editor.selected=null;editor.tool="select";
        }
        Keys.onDeletePressed: editor.remove()
    }
}

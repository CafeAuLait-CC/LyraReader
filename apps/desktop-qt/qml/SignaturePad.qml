import QtQuick

Canvas {
    id:pad
    required property var colors
    required property var rules
    property var strokes:[]
    property var current:[]
    property int pointCount:0
    property bool limitReached:false
    // Bound native pad redraw latency independently of the document codec's larger limits.
    readonly property int pointLimit:rules ? Math.min(8192,rules.max_ink_points) : 0
    readonly property int pathLimit:rules ? Math.min(128,rules.max_ink_paths) : 0
    readonly property var signature:normalise(strokes)
    activeFocusOnTab:true
    Accessible.role:Accessible.Canvas
    Accessible.name:qsTr("Signature drawing pad")
    Accessible.description:qsTr("Draw with the pointer. Delete clears the pad. A typed signature is also available in the inspector.")
    Keys.onDeletePressed:clear()
    function clear() {strokes=[];current=[];pointCount=0;limitReached=false;requestPaint();}
    function point(x,y) {return {x:Math.max(0,Math.min(width,x)),y:Math.max(0,Math.min(height,y))};}
    function append(x,y) {
        if(!current.length)return;
        const p=point(x,y),last=current[current.length-1];
        if(Math.hypot(p.x-last.x,p.y-last.y)<1)return;
        if(pointCount+current.length>=pointLimit){limitReached=true;return;}
        current.push(p);requestPaint();
    }
    function normalise(paths) {
        if(!paths.length)return null;
        let minX=Infinity,minY=Infinity,maxX=-Infinity,maxY=-Infinity;
        paths.forEach(function(path){path.forEach(function(p){minX=Math.min(minX,p.x);minY=Math.min(minY,p.y);maxX=Math.max(maxX,p.x);maxY=Math.max(maxY,p.y);});});
        const w=Math.max(1,maxX-minX),h=Math.max(1,maxY-minY);
        return {aspect:Math.max(.3,Math.min(6,w/h)),strokes:paths.map(function(path){return path.map(function(p){return {x:(p.x-minX)/w,y:(p.y-minY)/h};});})};
    }
    onPaint: {
        const ctx=getContext("2d");ctx.clearRect(0,0,width,height);
        ctx.fillStyle=colors.documentPaper;ctx.fillRect(0,0,width,height);
        ctx.strokeStyle=colors.documentInk;ctx.lineWidth=2.5;ctx.lineCap="round";ctx.lineJoin="round";
        strokes.concat([current]).forEach(function(path){if(path.length<2)return;ctx.beginPath();ctx.moveTo(path[0].x,path[0].y);for(let i=1;i<path.length;++i)ctx.lineTo(path[i].x,path[i].y);ctx.stroke();});
    }
    Rectangle {anchors.fill:parent;color:"transparent";border.width:pad.activeFocus ? 2 : 1;border.color:pad.activeFocus ? pad.colors.focusRing : pad.colors.controlBorder;radius:4}
    MouseArea {
        objectName:"signaturePadPointer"
        anchors.fill:parent;cursorShape:Qt.CrossCursor
        onPressed:function(mouse){pad.forceActiveFocus();if(pad.strokes.length>=pad.pathLimit || pad.pointCount>=pad.pointLimit){pad.limitReached=true;return;}pad.current=[pad.point(mouse.x,mouse.y)];}
        onPositionChanged:function(mouse){if(pressed)pad.append(mouse.x,mouse.y);}
        onReleased:function(mouse){if(pad.current.length>=2){pad.append(mouse.x,mouse.y);pad.pointCount+=pad.current.length;pad.strokes=pad.strokes.concat([pad.current]);}pad.current=[];pad.requestPaint();}
        onCanceled:{pad.current=[];pad.requestPaint();}
    }
}

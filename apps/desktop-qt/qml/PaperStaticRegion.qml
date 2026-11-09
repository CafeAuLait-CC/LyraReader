import QtQuick

// Only non-interactive paint belongs here. Focused text/form controls keep their single
// native instance. Fixed clip slots preserve source layout and glyph objects during reveal.
Item {
    // Avoid Item.layer name resolution inside the nested Repeater/Loader.
    id: staticRegion
    required property var app
    required property var paperMap
    required property Component paint
    property rect sourceRect: Qt.rect(0,0,0,0)
    property real zoom: app.zoom
    property string accessibleName: ""
    signal pressed()
    readonly property bool mapped: !!paperMap && paperMap.paperGeometryActive
    readonly property bool bounded: mapped && [sourceRect.x,sourceRect.y,sourceRect.width,sourceRect.height,
        sourceRect.x+sourceRect.width,sourceRect.y+sourceRect.height].every(function(v){return Number.isFinite(v) && Math.abs(v)<=paperMap.paperSceneLimit;})
    onBoundedChanged: if(mapped && !bounded)app.operationStatus=qsTr("The annotation is outside the scene coordinate range.")
    PaperRegion {
        id: geometry
        app: staticRegion.app
        paperMap: staticRegion.bounded ? staticRegion.paperMap : null
        sourceRect: staticRegion.bounded ? staticRegion.sourceRect : Qt.rect(0,0,0,0)
    }
    x: geometry.bounds.x*zoom
    y: geometry.bounds.y*zoom
    width: geometry.bounds.width*zoom
    height: geometry.bounds.height*zoom
    visible: mapped && bounded && geometry.hit
    Accessible.role: Accessible.Graphic
    Accessible.name: accessibleName
    Accessible.onPressAction: staticRegion.pressed()
    Repeater {
        model: 2
        Item {
            id: piece
            required property int index
            readonly property var pieces: geometry.packet.pieces===undefined ? [] : geometry.packet.pieces
            readonly property var target: index<pieces.length ? pieces[index] : null
            readonly property var original: {
                if(!target || !staticRegion.visible)return {hit:false};
                const epoch=staticRegion.paperMap.paperGeometryRevision;
                if(epoch!==geometry.revision)return {hit:false};
                // The strict inverse shares the raster's tiny-gap rule. An extrapolatable
                // reading anchor is deliberately a different contract.
                return staticRegion.paperMap.paperPoint(Qt.point(target.x,target.y));
            }
            readonly property bool present: !!target && original.hit===true
            x: present ? (target.x-geometry.bounds.x)*staticRegion.zoom : 0
            y: present ? (target.y-geometry.bounds.y)*staticRegion.zoom : 0
            width: present ? target.width*staticRegion.zoom : 0
            height: present ? target.height*staticRegion.zoom : 0
            clip: true
            Loader {
                objectName: "paperFragmentPaint"+piece.index
                active: piece.present && staticRegion.visible
                sourceComponent: staticRegion.paint
                x: piece.present ? (staticRegion.sourceRect.x-piece.original.x)*staticRegion.zoom : 0
                y: piece.present ? (staticRegion.sourceRect.y-piece.original.y)*staticRegion.zoom : 0
                width: piece.present ? staticRegion.sourceRect.width*staticRegion.zoom : 0
                height: piece.present ? staticRegion.sourceRect.height*staticRegion.zoom : 0
            }
        }
    }
}

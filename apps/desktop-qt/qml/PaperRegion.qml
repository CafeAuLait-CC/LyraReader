import QtQuick

// Pure display geometry for an existing native control. The control and its text document
// keep one owner while the page moves; these bounds must never be saved as source geometry.
QtObject {
    required property var app
    property var paperMap: null
    property rect sourceRect: Qt.rect(0,0,0,0)
    readonly property var revision: paperMap ? paperMap.paperGeometryRevision : 0
    readonly property var packet: {
        if(paperMap && paperMap.controller!==app.currentReader)return {hit:false};
        // Read the epoch at the query, rather than depending on the update order of two
        // separate bindings. A normal gap update must not publish a stale-layout error.
        if(paperMap && paperMap.paperGeometryActive)
            return paperMap.paperRegion(sourceRect,paperMap.paperGeometryRevision);
        return {hit:sourceRect.width>0 && sourceRect.height>0,bounds:sourceRect,pieces:[sourceRect]};
    }
    readonly property bool hit: packet.hit===true
    readonly property rect bounds: hit ? Qt.rect(packet.bounds.x,packet.bounds.y,packet.bounds.width,packet.bounds.height) : Qt.rect(0,0,0,0)
    readonly property string error: packet.error===undefined ? "" : String(packet.error)
    onErrorChanged: if(error.length && app)app.operationStatus=error
}

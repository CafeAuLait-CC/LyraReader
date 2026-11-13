import QtQuick
import QtQuick.Window

// The same 24-point folded paper is used for sticky notes and inline comments.
// Only this small native canvas is repainted; PDF pixels and page raster jobs stay untouched.
Item {
    id: badge
    required property var colors
    property bool nightPaper: false
    property bool inlineComment: false
    property color highlight: "transparent"
    property bool active: false
    readonly property bool hovered: hover.hovered
    readonly property var ink: colors.noteIconColors(active ? 2 : hovered ? 1 : 0, nightPaper, inlineComment ? highlight : null)
    // Power-of-two buckets match the native artwork cache. Even a malformed or deeply
    // zoomed annotation uses at most 192x192 canvas coordinates here. Qt's own
    // backing resources are separate from the PDF image/texture payload ledgers.
    readonly property int rasterScale: Math.pow(2, Math.ceil(Math.log(Math.max(1,
        Math.min(8, Math.min(width, height) / 24 * Screen.devicePixelRatio))) / Math.LN2))
    HoverHandler { id: hover }
    Canvas {
        id: paint
        objectName: "noteBadgeCanvas"
        anchors.centerIn: parent
        width: 24 * badge.rasterScale
        height: width
        scale: Math.min(parent.width, parent.height) / width
        canvasSize: Qt.size(width, height)
        renderTarget: Canvas.Image
        onCanvasSizeChanged: requestPaint()
        Connections { target: badge; function onInkChanged() { paint.requestPaint() } function onInlineCommentChanged() { paint.requestPaint() } }
        onPaint: {
            const c = getContext("2d");
            c.reset(); c.clearRect(0, 0, canvasSize.width, canvasSize.height);
            c.scale(badge.rasterScale, badge.rasterScale);
            function outline() {
                c.beginPath(); c.moveTo(6.5, 3.75); c.lineTo(17.5, 3.75);
                c.bezierCurveTo(19.019, 3.75, 20.25, 4.981, 20.25, 6.5);
                c.lineTo(20.25, 14.75); c.lineTo(14.75, 20.25); c.lineTo(6.5, 20.25);
                c.bezierCurveTo(4.981, 20.25, 3.75, 19.019, 3.75, 17.5);
                c.lineTo(3.75, 6.5); c.bezierCurveTo(3.75, 4.981, 4.981, 3.75, 6.5, 3.75); c.closePath();
            }
            function fold() {
                c.beginPath(); c.moveTo(20.25, 14.75); c.lineTo(17, 14.75);
                c.bezierCurveTo(15.757, 14.75, 14.75, 15.757, 14.75, 17); c.lineTo(14.75, 20.25);
            }
            outline(); c.fillStyle = badge.ink.paper; c.fill();
            fold(); c.fillStyle = badge.ink.fold; c.fill();
            c.strokeStyle = badge.ink.ink; c.lineWidth = 1.35; c.lineCap = "round"; c.lineJoin = "round";
            outline(); c.stroke(); fold(); c.stroke();
            if (badge.inlineComment) {
                c.fillStyle = badge.ink.ink;
                for (const x of [7.5, 11, 14.5]) { c.beginPath(); c.arc(x + .875, 9.875, .875, 0, Math.PI * 2); c.fill(); }
            } else {
                for (const line of [[7.5, 8.25, 16.25], [7.5, 11.75, 13.5]]) {
                    c.beginPath(); c.moveTo(line[0], line[1]); c.lineTo(line[2], line[1]); c.stroke();
                }
            }
        }
    }
}

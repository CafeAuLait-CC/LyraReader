import QtQuick

Item {
    id: tear
    required property int page
    required property real split
    required property real gap
    required property real zoom
    required property var colors
    visible: gap > 0 && width > 0
    Accessible.ignored: true
    readonly property real depth: Math.min(1.6, gap / 5)
    readonly property int toothCount: Math.min(4096, Math.max(2, Math.ceil(width / Math.max(5, Math.min(12, 7 * zoom)))))
    Repeater {
        model: 2
        Canvas {
            id: edge
            required property int index
            y: tear.split + (index ? tear.gap : 0)
            width: Math.min(4096, tear.width)
            height: 2
            // Opening the gap only moves/scales the same thin artwork.
            transform: Scale { xScale: tear.width / Math.max(1, edge.width); yScale: (edge.index ? -1 : 1) * tear.depth / 1.6 }
            property int count: tear.toothCount
            property int phase: tear.page * 13
            property color paper: Qt.alpha(tear.colors.pageEdge, .18)
            property color ink: Qt.alpha(tear.colors.accent, .48)
            onCountChanged: requestPaint()
            onPhaseChanged: requestPaint()
            onPaperChanged: requestPaint()
            onInkChanged: requestPaint()
            onPaint: {
                const brush = getContext("2d");
                brush.clearRect(0, 0, width, height);
                brush.beginPath();
                brush.moveTo(0, 0);
                for (let i = 1; i < count; ++i)
                    brush.lineTo(width * i / count, 1.6 * (.25 + .075 * ((i * 37 + phase) % 11)));
                brush.lineTo(width, 0);
                brush.closePath();
                brush.fillStyle = paper;
                brush.fill();
                brush.lineWidth = .65;
                brush.strokeStyle = ink;
                brush.stroke();
            }
        }
    }
}

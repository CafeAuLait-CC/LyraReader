import QtQuick

Rectangle {
    id: surface
    required property var colors
    required property bool parchment
    color: parchment ? colors.panelBg : colors.raisedBg
    radius: parchment ? 5 : 10
    border.color: parchment ? Qt.alpha(colors.accentBorder, .28) : colors.border
    gradient: parchment ? paperWash : null
    Gradient {
        id: paperWash
        GradientStop { position: 0; color: Qt.tint(surface.color, Qt.alpha(surface.colors.accentSoft, .75)) }
        GradientStop { position: .55; color: Qt.tint(surface.color, Qt.alpha(surface.colors.raisedBg, .25)) }
        GradientStop { position: 1; color: Qt.tint(surface.color, Qt.alpha(surface.colors.accentSoft, .45)) }
    }
    Canvas {
        id: fibres
        objectName: "aiRegionPaperFibres"
        anchors.fill: parent
        anchors.margins: 5
        visible: surface.parchment
        Accessible.ignored: true
        property color tint: Qt.alpha(surface.colors.accentBorder, .055)
        onTintChanged: requestPaint()
        onPaint: {
            if (!visible) return;
            const brush = getContext("2d");
            brush.clearRect(0, 0, width, height);
            brush.strokeStyle = tint;
            brush.lineWidth = .5;
            brush.beginPath();
            for (let i = 0; i < 180; ++i) {
                const x = (137 * i + 29) % 997 / 997 * width;
                const y = (263 * i + 71) % 991 / 991 * height;
                brush.moveTo(x, y);
                brush.lineTo(x + 2 + i % 4, y + .4);
            }
            brush.stroke();
        }
    }
    Canvas {
        id: fold
        objectName: "aiRegionPaperFold"
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 1
        width: 14
        height: 14
        visible: surface.parchment
        Accessible.ignored: true
        property color paper: surface.colors.accentSoft
        property color edge: Qt.alpha(surface.colors.accentBorder, .3)
        onPaperChanged: requestPaint()
        onEdgeChanged: requestPaint()
        onPaint: {
            const brush = getContext("2d");
            brush.clearRect(0, 0, width, height);
            brush.beginPath();
            brush.moveTo(0, 14);
            brush.lineTo(14, 0);
            brush.lineTo(14, 11);
            brush.quadraticCurveTo(14, 14, 11, 14);
            brush.closePath();
            brush.fillStyle = paper;
            brush.fill();
            brush.beginPath();
            brush.moveTo(0, 14);
            brush.quadraticCurveTo(10, 11, 14, 0);
            brush.lineWidth = .7;
            brush.strokeStyle = edge;
            brush.stroke();
        }
    }
}

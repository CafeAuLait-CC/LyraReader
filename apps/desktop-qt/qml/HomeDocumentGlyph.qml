import QtQuick
import QtQuick.Shapes

Item {
    id: glyph
    required property color ink
    property color badgeInk: "white"
    property bool badge: true
    implicitWidth: 48
    implicitHeight: 52
    Accessible.ignored: true
    Item {
        width: 24; height: 26
        scale: Math.min(glyph.width / width, glyph.height / height)
        anchors.centerIn: parent
        Shape {
            anchors.fill: parent
            ShapePath {
                strokeColor: glyph.ink; strokeWidth: 1.35
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                PathSvg { path: glyph.badge ? "M8 2 H14 L22 10 V22 Q22 24 20 24 H12 M6 15 V4 Q6 2 8 2 M14 2 V9 Q14 10 15 10 H22" : "M8 2 H14 L22 10 V22 Q22 24 20 24 H8 Q6 24 6 22 V4 Q6 2 8 2 M14 2 V9 Q14 10 15 10 H22" }
            }
            ShapePath {
                strokeColor: glyph.ink; strokeWidth: 1.1; fillColor: "transparent"
                PathSvg { path: glyph.badge ? "" : "M10 14 H18 M10 17 H18 M10 20 H16" }
            }
        }
        Rectangle {
            visible: glyph.badge
            x: 0; y: 16; width: 11; height: 11; radius: 5.5
            color: glyph.ink
            Rectangle { anchors.centerIn: parent; width: 6; height: 1.2; radius: .6; color: glyph.badgeInk }
            Rectangle { anchors.centerIn: parent; width: 1.2; height: 6; radius: .6; color: glyph.badgeInk }
        }
    }
}

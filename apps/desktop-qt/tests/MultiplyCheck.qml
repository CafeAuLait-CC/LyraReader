import QtQuick
import QtQuick.Window
import LyraReader 1.0

Window {
    property real pulse: 0
    visible: true
    width: 320
    height: 140
    color: "white"
    Rectangle {
        x: 80
        y: 10
        width: 40
        height: 80
        color: "black"
    }
    PdfAnnotations {
        width: 240
        height: 100
        zoom: 1
        annotations: [
            {
                id: "pixel-check",
                kind: "highlight",
                color: "#FFFF0080",
                blend: "multiply",
                visible: true,
                quads: [
                    {
                        x: 10,
                        y: 10,
                        width: 200,
                        height: 80
                    }
                ]
            }
        ]
    }
    Rectangle {
        x: 224 + parent.pulse
        y: 50
        width: 8
        height: 8
        color: "red"
    }
}

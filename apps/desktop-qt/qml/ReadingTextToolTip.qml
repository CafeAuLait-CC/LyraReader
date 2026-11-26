import QtQuick
import QtQuick.Controls
import LyraReader 1.0

Item {
    id: root
    required property var app
    required property var area
    anchors.fill: parent
    readonly property string displayedText: area ? area.text : ""
    readonly property string hint: {
        const revision = displayedText;
        if (!area || !pointer.hovered) return "";
        return geometry.toolTip(area.textDocument, area.positionAt(pointer.point.position.x, pointer.point.position.y));
    }
    ReadingTextGeometry {id: geometry}
    // Observes hover without taking a mouse/touch grab or replacing TextArea selection.
    HoverHandler {id: pointer}
    ToolTip {
        objectName: "readingMathToolTip"
        visible: root.visible && pointer.hovered && !!root.hint
        delay: 500
        text: root.hint
        width: Math.min(340, Math.max(120, root.app.width - 24))
        x: Math.max(0, Math.min(root.width - width, pointer.point.position.x))
        y: pointer.point.position.y + 16
        contentItem: Text {
            text: root.hint; textFormat: Text.PlainText; wrapMode: Text.Wrap
            font.pixelSize: 11; color: root.app.colors.textPrimary
        }
        background: Rectangle {radius: 4; color: root.app.colors.raisedBg; border.color: root.app.colors.controlBorder}
    }
}

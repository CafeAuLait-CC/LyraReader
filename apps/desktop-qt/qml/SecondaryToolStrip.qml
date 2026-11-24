import QtQuick
import QtQuick.Controls

Flickable {
    id: viewport
    default property alias tools: strip.data
    readonly property int edgePadding: 14
    readonly property bool compact: {
        let requiredWidth = 2 * edgePadding;
        let count = 0;
        for (const child of strip.children) {
            if (!child.visible || child instanceof Repeater)
                continue;
            requiredWidth += child.fitLabel ? child.labelledWidth : child.width;
            ++count;
        }
        return requiredWidth + Math.max(0, count - 1) * strip.spacing > width;
    }
    property alias spacing: strip.spacing
    contentWidth: Math.max(width, strip.width + 2 * edgePadding)
    contentHeight: height
    flickableDirection: Flickable.HorizontalFlick
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentWidth > width
    clip: true
    onContentWidthChanged: if (!interactive) contentX = 0

    property Item stripItem: Row {
        id: strip
        parent: viewport.contentItem
        x: Math.max(viewport.edgePadding, (viewport.width - width) / 2)
        y: (viewport.height - height) / 2
        spacing: 2
    }
    Connections {
        target: viewport.Window.window
        function onActiveFocusItemChanged() {
            const focus = viewport.Window.window.activeFocusItem;
            let control = focus;
            while (control && control.parent !== strip)
                control = control.parent;
            if (!control || !viewport.visible || !viewport.interactive)
                return;
            const left = strip.x + control.x;
            const right = left + control.width;
            if (left < viewport.contentX)
                viewport.contentX = left;
            else if (right > viewport.contentX + viewport.width)
                viewport.contentX = right - viewport.width;
        }
    }
}

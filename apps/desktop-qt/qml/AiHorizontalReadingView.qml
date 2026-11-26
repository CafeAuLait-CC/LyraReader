import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Flickable {
    id: view
    required property var app
    property var renderer: null
    property string viewName: ""
    property real measuredWidth: 0
    property real measuredHeight: 0
    property real surfaceWidth: width
    property bool outlined: false
    readonly property var indicator: bar
    objectName: viewName + "HorizontalViewport"
    Layout.minimumWidth: 0
    implicitHeight: measuredHeight + (bar.visible ? bar.implicitHeight + 2 : 0)
    contentWidth: Math.max(width, measuredWidth)
    contentHeight: height
    clip: true; interactive: false; boundsBehavior: Flickable.StopAtBounds
    onContentWidthChanged: contentX = Math.max(0, Math.min(Math.max(0, contentWidth - width), contentX))
    function pan(dx) { contentX = Math.max(0, Math.min(Math.max(0, contentWidth - width), contentX - dx)); }
    function revealCursor(area) {
        const cursor = area.cursorRectangle;
        const rect = area.mapToItem(contentItem, cursor.x, cursor.y, cursor.width, cursor.height);
        if (!Number.isFinite(rect.x) || !Number.isFinite(rect.width) || width <= 0) return;
        let next = contentX;
        if (rect.x <= area.leftPadding + area.font.pixelSize) next = 0;
        else if (rect.x < next + 2) next = rect.x - 2;
        else if (rect.x + rect.width > next + width - 2) next = rect.x + rect.width - width + 2;
        next = Math.max(0, Math.min(Math.max(0, contentWidth - width), next));
        if (next !== contentX) { contentX = next; cursorIndicator.restart(); }
    }
    Rectangle {
        objectName: view.viewName + "Surface"
        parent: view; width: view.surfaceWidth; height: view.height; z: -1
        radius: 4; color: app.colors.raisedBg
        border.width: view.outlined ? 0.5 : 0; border.color: app.colors.separator
    }
    ReadingWheelHandler {
        id: horizontalWheel
        zoomEnabled: false; horizontalOnly: true
        onScrollRequested: function(dx, dy) { view.pan(dx); }
    }
    ReadingWheelHandler {
        id: shiftedWheel
        zoomEnabled: false; horizontalOnly: true; orientation: Qt.Vertical
        acceptedModifiers: Qt.ShiftModifier
        onScrollRequested: function(dx, dy) { view.pan(dx); }
    }
    ReadingWheelHandler {
        zoomEnabled: false; acceptedModifiers: Qt.NoModifier
        scrollEnabled: !!view.renderer && !!view.renderer.viewport
        onScrollRequested: function(dx, dy) { view.renderer.scrollParent(dy); }
    }
    Timer { id: cursorIndicator; interval: 750 }
    ScrollBar.horizontal: AiReadingScrollBar {
        id: bar
        objectName: view.viewName + "HorizontalBar"
        active: hovered || pressed || horizontalWheel.active || shiftedWheel.active || cursorIndicator.running
    }
}

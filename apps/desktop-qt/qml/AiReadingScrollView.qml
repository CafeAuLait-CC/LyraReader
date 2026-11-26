import QtQuick
import QtQuick.Controls
import LyraReader 1.0

ScrollView {
    id: view
    property var memoryReader: null
    property string memoryKey: ""
    property bool memoryReady: true
    property var wheelParent: null
    property int interactionEpoch: 0
    function rememberPosition() { scrollMemory.capturePosition(); }
    function applyReadingWheel(dx, dy) { panelWheel.scrollRequested(dx, dy); }
    function revealItem(item) {
        const f = contentItem;
        if (!visible || !f || !item) return;
        const y = item.mapToItem(f, 0, 0).y;
        const delta = y < 0 ? -y : y + item.height > f.height ? f.height - y - item.height : 0;
        // Focus is an explicit navigation intent even when the item already fits.
        // Keep a queued memory restore from moving the focused control away.
        applyReadingWheel(0, delta);
    }
    ReadingScrollMemory {
        id: scrollMemory
        reader: view.memoryReader; key: view.memoryKey
        viewport: view.contentItem; active: view.visible; ready: view.memoryReady
    }
    Connections {
        target: view
        function onScrollIntent() { scrollMemory.userIntent(); }
        function onVerticalBarPressedChanged() { if (view.verticalBarPressed) scrollMemory.userIntent(); }
    }
    signal scrollIntent(real dx, real dy)
    PanelWheelHandler {
        id: panelWheel
        viewport: view.contentItem
        onScrollIntent: function(dx, dy) {
            view.interactionEpoch++;
            view.scrollIntent(dx, dy);
            const f = view.contentItem;
            if (!f || !view.wheelParent || view.wheelParent === view || !dy) return;
            const top = f.originY - f.topMargin;
            const bottom = Math.max(top, f.originY + f.contentHeight - f.height + f.bottomMargin);
            if ((dy > 0 && f.contentY <= top + .5) || (dy < 0 && f.contentY >= bottom - .5))
                view.wheelParent.applyReadingWheel(dx, dy);
        }
        onScrollApplied: scrollMemory.completeUserScroll()
    }
    readonly property bool verticalBarPressed: verticalBar.pressed
    readonly property real gutterWidth: verticalBar.gutterWidth
    leftPadding: mirrored ? gutterWidth : 0
    rightPadding: mirrored ? 0 : gutterWidth
    contentWidth: availableWidth
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
    ScrollBar.vertical: AiReadingScrollBar {
        id: verticalBar
        objectName: "aiReadingScrollBar"
        parent: view
        x: view.mirrored ? 0 : view.width - width
        y: view.topPadding
        height: view.availableHeight
    }
}

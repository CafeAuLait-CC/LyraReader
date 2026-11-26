import QtQuick
import QtQuick.Controls
import LyraReader 1.0

ScrollView {
    id: view
    property var memoryReader: null
    property string memoryKey: ""
    property bool memoryReady: true
    function rememberPosition() { scrollMemory.capturePosition(); }
    function applyReadingWheel(dx, dy) { panelWheel.scrollRequested(dx, dy); }
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
        onScrollIntent: function(dx, dy) { view.scrollIntent(dx, dy); }
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

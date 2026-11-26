import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

Item {
    id: preview
    objectName: actionName + "Preview"
    default property alias body: clipped.data
    required property var app
    required property var textArea
    required property real naturalHeight
    property bool collapsed: true
    property bool additionalContent: false
    property bool actionEnabled: true
    property real limit: 180
    property int maximumLines: 0
    property string actionName: ""
    property var fallback: null
    property var metrics: ({measured: false})
    readonly property bool hasMore: additionalContent || (metrics.measured && metrics.hidden) || naturalHeight > limit + .5
    readonly property bool actionVisible: actionEnabled && (!collapsed || hasMore)
    readonly property bool inlineAction: actionVisible && !!metrics.inline
    readonly property bool footerNeeded: actionVisible && !inlineAction
    readonly property real visibleHeight: !collapsed ? naturalHeight
        : metrics.measured && (maximumLines > 0 || hasMore && metrics.inline) ? Math.min(naturalHeight, metrics.bottom) : Math.min(naturalHeight, limit)
    implicitHeight: visibleHeight
    signal activated()
    function focusAction() {
        if (inlineAction) action.forceActiveFocus(Qt.TabFocusReason);
        else if (footerNeeded && fallback) fallback.forceActiveFocus(Qt.TabFocusReason);
    }
    function measure() {
        if (!textArea || !textArea.textDocument || width <= 0) { metrics = {measured: false}; return; }
        const measured = geometry.tail(textArea.textDocument, collapsed ? limit : Math.max(1, naturalHeight + 1),
            collapsed ? maximumLines : 0, suffix.implicitWidth, Math.max(0, textArea.width - textArea.leftPadding - textArea.rightPadding));
        if (measured.measured) {
            const origin = textArea.mapToItem(preview, textArea.leftPadding, textArea.topPadding);
            if (measured.inline) { measured.x += origin.x; measured.mask_x += origin.x; }
            measured.top += origin.y; measured.bottom += origin.y; measured.baseline += origin.y;
        }
        metrics = measured;
    }
    onTextAreaChanged: refresh.restart()
    onWidthChanged: refresh.restart()
    onNaturalHeightChanged: refresh.restart()
    onCollapsedChanged: refresh.restart()
    onMaximumLinesChanged: refresh.restart()
    onLimitChanged: refresh.restart()
    Component.onCompleted: refresh.restart()
    ReadingTextGeometry { id: geometry }
    Timer { id: refresh; interval: 0; onTriggered: preview.measure() }
    Connections {
        target: preview.textArea
        function onTextChanged() { refresh.restart(); }
        function onContentHeightChanged() { refresh.restart(); }
        function onWidthChanged() { refresh.restart(); }
        function onFontChanged() { refresh.restart(); }
    }
    Item { id: clipped; width: parent.width; height: preview.visibleHeight; clip: true }
    Item {
        visible: preview.inlineAction
        anchors.fill: parent
        clip: true
        Rectangle {
            x: preview.metrics.mask_x || 0; y: preview.metrics.top || 0
            width: preview.metrics.mask_width || 0
            height: Math.max(0, preview.visibleHeight - y)
            color: preview.app.colors.panelBg
        }
        RowLayout {
            id: suffix
            x: preview.metrics.x || 0
            y: preview.metrics.measured ? preview.metrics.baseline - action.baselineOffset : 0
            spacing: 3
            onImplicitWidthChanged: refresh.restart()
            Label { visible: preview.collapsed; text: "…"; font.pixelSize: 11; color: preview.app.colors.textSecondary; Layout.alignment: Qt.AlignBaseline }
            ToolButton {
                id: action
                objectName: preview.inlineAction ? preview.actionName : ""
                text: preview.collapsed ? qsTr("More") : qsTr("Less")
                font.pixelSize: 11
                padding: 0; leftPadding: 0; rightPadding: 0; topPadding: 0; bottomPadding: 0
                implicitHeight: contentItem.implicitHeight
                Layout.alignment: Qt.AlignBaseline
                palette.buttonText: preview.app.colors.accent
                Accessible.description: preview.collapsed ? qsTr("Collapsed") : qsTr("Expanded")
                background: Rectangle { color: "transparent"; border.width: action.visualFocus ? 2 : 0; border.color: preview.app.colors.focusRing; radius: 2 }
                onClicked: preview.activated()
                HoverHandler { cursorShape: Qt.PointingHandCursor }
            }
        }
    }
}

import QtQuick.Controls

ScrollView {
    id: view
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

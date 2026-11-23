import QtQuick.Controls

ScrollBar {
    // Reserve the native control's width even when there is nothing to scroll.
    readonly property real gutterWidth: implicitWidth + 4
    policy: ScrollBar.AsNeeded
    visible: size > 0 && size < 1
}

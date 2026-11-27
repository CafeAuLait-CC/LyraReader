import QtQuick
import QtQuick.Controls

TextField {
    id: control
    required property var app
    font.pixelSize: 12
    leftPadding: 9; rightPadding: 9
    topPadding: 7; bottomPadding: 7
    color: enabled ? app.colors.textPrimary : app.colors.textDisabled
    selectionColor: app.colors.selectedBg
    selectedTextColor: app.colors.selectedFg
    placeholderTextColor: app.colors.textPlaceholder
    background: Rectangle {
        radius: 5
        color: app.colors.fieldBg
        border.width: control.activeFocus ? 2 : 1
        border.color: control.activeFocus ? app.colors.focusRing : app.colors.controlBorder
    }
}

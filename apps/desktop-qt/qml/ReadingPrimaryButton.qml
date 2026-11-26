import QtQuick
import QtQuick.Controls

Button {
    id: control
    required property var app
    implicitHeight: 32
    font.pixelSize: 13
    font.weight: Font.DemiBold
    leftPadding: 12; rightPadding: 12; topPadding: 6; bottomPadding: 6
    palette.buttonText: enabled ? app.colors.accentFg : app.colors.textDisabled
    icon.width: 16; icon.height: 16
    icon.color: enabled ? app.colors.accentFg : app.colors.textDisabled
    background: Rectangle {
        radius: 6
        color: !control.enabled ? "transparent" : control.down ? app.colors.accentPressed : control.hovered ? app.colors.accentHover : app.colors.accent
        border.width: control.visualFocus ? 2 : 1
        border.color: control.visualFocus ? app.colors.focusRing : control.enabled ? app.colors.accentBorder : app.colors.border
    }
}

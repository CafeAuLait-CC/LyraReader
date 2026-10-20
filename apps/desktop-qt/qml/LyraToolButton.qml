import QtQuick
import QtQuick.Controls

ToolButton {
    id: control
    property string symbol: ""
    property bool selected: false
    property var theme: ApplicationWindow.window ? ApplicationWindow.window.colors : null
    implicitWidth: display === AbstractButton.IconOnly ? 32 : implicitContentWidth + 18
    implicitHeight: 32
    padding: 7
    display: AbstractButton.IconOnly
    icon.source: symbol.length ? "qrc:/icons/" + symbol + ".svg" : ""
    icon.width: 18
    icon.height: 18
    icon.color: !theme ? "transparent" : !enabled ? theme.textDisabled : selected ? theme.selectedFg : theme.iconPrimary
    palette.buttonText: !theme ? "transparent" : selected ? theme.selectedFg : theme.textPrimary
    background: Rectangle {
        radius: 5
        color: !control.theme ? "transparent" : control.selected ? control.theme.selectedBg : control.down ? control.theme.pressedBg : control.hovered ? control.theme.hoverBg : "transparent"
        border.width: control.visualFocus ? 2 : 0
        border.color: control.theme ? control.theme.focusRing : "transparent"
    }
    Accessible.name: text
    ToolTip.visible: hovered && text.length > 0
    ToolTip.text: text
    ToolTip.delay: 500
}

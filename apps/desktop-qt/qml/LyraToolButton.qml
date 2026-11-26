import QtQuick
import QtQuick.Controls

ToolButton {
    id: control
    property string symbol: ""
    property bool selected: false
    property bool fitLabel: false
    property bool mainLabel: false
    readonly property real labelledWidth: labelProbe.item ? Math.ceil(labelProbe.item.implicitWidth) + 1 : 34
    property var theme: ApplicationWindow.window ? ApplicationWindow.window.colors : null
    implicitWidth: display === AbstractButton.IconOnly ? (fitLabel ? 34 : 32) : fitLabel ? labelledWidth : implicitContentWidth + 18
    implicitHeight: 32
    hoverEnabled: true
    padding: 7
    display: AbstractButton.IconOnly
    Binding { target: control; property: "font.pixelSize"; value: control.mainLabel ? 14 : 12; when: control.fitLabel || control.mainLabel }
    Binding { target: control; property: "font.weight"; value: control.mainLabel ? Font.Medium : Font.Normal; when: control.fitLabel || control.mainLabel }
    Binding { target: control; property: "spacing"; value: 5; when: control.fitLabel }
    Loader {
        id: labelProbe
        active: control.fitLabel
        visible: false
        // The current native style measures its own icon, font, spacing and
        // mnemonic text even when the live button is in its icon-only state.
        sourceComponent: ToolButton {
            text: control.text
            icon: control.icon
            font: control.font
            spacing: control.spacing
            padding: control.padding
            display: AbstractButton.TextBesideIcon
        }
    }
    icon.source: symbol.length ? "qrc:/icons/" + symbol + ".svg" : ""
    icon.width: 18
    icon.height: 18
    icon.color: !theme ? "transparent" : !enabled ? theme.textDisabled : selected ? theme.selectedFg : theme.iconPrimary
    palette.buttonText: !theme ? "transparent" : !enabled ? theme.textDisabled : selected ? theme.selectedFg : theme.textPrimary
    background: Rectangle {
        radius: 6
        color: !control.theme ? "transparent" : control.down ? control.theme.pressedBg : control.selected ? control.theme.selectedBg : control.hovered && control.enabled ? control.theme.hoverBg : "transparent"
        border.width: control.visualFocus ? 2 : 0
        border.color: control.theme ? control.theme.focusRing : "transparent"
    }
    Accessible.name: text
    Accessible.selected: selected
    ToolTip.visible: hovered && text.length > 0
    ToolTip.text: text
    ToolTip.delay: 500
}

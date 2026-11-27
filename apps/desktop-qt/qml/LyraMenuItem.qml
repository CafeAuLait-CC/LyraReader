import QtQuick
import QtQuick.Controls.Basic as Basic

Basic.MenuItem {
    id: command
    property var theme: menu ? menu.theme : null
    readonly property bool checkColumn: menu ? menu.hasCheckmarks : false
    readonly property color foreground: !theme ? "transparent" : !enabled ? theme.textDisabled
        : highlighted ? theme.menuSelectedFg : theme.textPrimary
    implicitWidth: Math.max(150, implicitContentWidth + leftPadding + rightPadding + 8)
    implicitHeight: 30
    topPadding: 0
    bottomPadding: 0
    // A 14px symbol is centered in the Mac's 18px leading slot.
    leftPadding: icon.source.toString().length || icon.name.length ? 10 : 34
    rightPadding: 8 + (checkColumn ? 20 : 0)
    spacing: 10
    font.pixelSize: 12
    font.weight: Font.Normal
    icon.source: "qrc:/icons/document.svg"
    icon.width: 14
    icon.height: 14
    icon.color: !theme ? "transparent" : !enabled ? theme.textDisabled : theme.iconPrimary
    palette.windowText: foreground
    palette.buttonText: foreground
    palette.disabled.windowText: theme ? theme.textDisabled : "transparent"
    Accessible.role: Accessible.MenuItem
    Accessible.name: text
    Accessible.checkable: checkable
    Accessible.checked: checked
    indicator: null
    Text {
        objectName: "lyraMenuTrailingCheck"
        parent: command
        x: command.width - 20
        y: (command.height - height) / 2
        width: 12; height: 12
        visible: command.checked
        Accessible.ignored: true
        text: "\u2713"
        font.pixelSize: 10
        font.weight: Font.DemiBold
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        color: command.foreground
    }
    background: Rectangle {
        radius: 5
        color: command.enabled && command.highlighted && command.theme ? command.theme.menuSelectedBg : "transparent"
    }
}

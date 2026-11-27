import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Basic as Controls

Rectangle {
    id: chip
    required property var app
    property bool original: false
    property bool clipped: false
    property string contextDescription: ""
    property alias primaryButton: primary
    property alias disclosureButton: disclose
    signal toggleRequested()
    signal disclosureRequested()
    objectName: "translationChip"
    implicitHeight: 22
    // Measure requested controls, not effective visibility inherited from the
    // placement. The canvas needs this size before deciding whether to show it.
    implicitWidth: Math.max(48, 28 + Math.ceil(measure.implicitWidth) + (clipped && !original ? 18 : 0))
    width: implicitWidth
    height: implicitHeight
    radius: 5
    color: hover.hovered ? app.colors.hoverBg : original ? app.colors.raisedBg : app.colors.accentSoft
    border.width: 1
    border.color: Qt.rgba(app.colors.accent.r, app.colors.accent.g, app.colors.accent.b, hover.hovered ? 0.8 : 0.5)

    function focusControl(preferDisclosure) {
        if (preferDisclosure && disclose.visible) disclose.forceActiveFocus(Qt.TabFocusReason);
        else primary.forceActiveFocus(Qt.TabFocusReason);
    }
    HoverHandler { id: hover }
    // Rounded corners and the spacing between buttons belong to this control,
    // rather than the covered translation or original PDF underneath it.
    MouseArea { anchors.fill:parent;acceptedButtons:Qt.LeftButton | Qt.RightButton }
    Text {
        id: measure
        visible: false
        Accessible.ignored: true
        text: primary.text
        font: primary.font
    }
    Controls.ToolButton {
        id: primary
        objectName: "translationPrimary"
        x: 7
        y: 1
        width: Math.ceil(measure.implicitWidth) + 16
        height: 20
        padding: 0
        spacing: 3
        hoverEnabled: true
        display: AbstractButton.TextBesideIcon
        text: chip.original ? qsTr("Translate") : qsTr("Show original")
        font.pixelSize: 10
        font.weight: Font.Medium
        icon.source: chip.original ? "qrc:/icons/translation.svg" : "qrc:/icons/undo.svg"
        icon.width: 12
        icon.height: 12
        icon.color: chip.app.colors.accent
        palette.buttonText: chip.app.colors.accent
        background: Rectangle {
            color: "transparent"
            radius: 3
            border.width: primary.visualFocus ? 2 : 0
            border.color: chip.app.colors.focusRing
        }
        Accessible.name: chip.original ? qsTr("Show the cached translation") : qsTr("Show original text")
        Accessible.description: chip.contextDescription
        ToolTip.visible: hovered
        ToolTip.text: Accessible.name
        ToolTip.delay: 500
        onClicked: chip.toggleRequested()
    }
    Controls.ToolButton {
        id: disclose
        objectName: "translationDisclosure"
        x: primary.x + primary.width + 3
        y: 1
        width: 16
        height: 20
        padding: 0
        hoverEnabled: true
        visible: chip.clipped && !chip.original
        text: "⋯"
        font.pixelSize: 11
        font.weight: Font.DemiBold
        palette.buttonText: chip.app.colors.accent
        background: Rectangle {
            color: "transparent"
            radius: 3
            border.width: disclose.visualFocus ? 2 : 0
            border.color: chip.app.colors.focusRing
        }
        Accessible.name: qsTr("Show full translation")
        Accessible.description: chip.contextDescription
        ToolTip.visible: hovered
        ToolTip.text: qsTr("Show the full translation that did not fit")
        ToolTip.delay: 500
        onClicked: chip.disclosureRequested()
    }
}

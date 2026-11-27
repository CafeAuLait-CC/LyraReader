import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Basic as Controls

Rectangle {
    id: chip
    required property var app
    property bool original: false
    property bool clipped: false
    property string contextDescription: ""
    property string phase: ""
    property string errorMessage: ""
    property bool cancelPending: false
    property bool retryAllowed: true
    readonly property string stage: phase.length ? phase : original ? "original" : "translated"
    readonly property bool translating: stage==="translating"
    property alias primaryButton: primary
    property alias disclosureButton: disclose
    property alias cancelButton: cancel
    signal toggleRequested()
    signal disclosureRequested()
    signal cancelRequested()
    signal retryRequested()
    objectName: "translationChip"
    implicitHeight: 22
    // Measure requested controls, not effective visibility inherited from the
    // placement. The canvas needs this size before deciding whether to show it.
    implicitWidth: Math.max(48, 28 + Math.ceil(measure.implicitWidth) + (translating || (clipped && stage==="translated") ? 18 : 0))
    width: implicitWidth
    height: implicitHeight
    radius: 5
    color: hover.hovered ? app.colors.hoverBg : stage==="translated" ? app.colors.accentSoft : app.colors.raisedBg
    border.width: 1
    border.color: Qt.rgba(app.colors.accent.r, app.colors.accent.g, app.colors.accent.b, hover.hovered ? 0.8 : 0.5)

    function focusControl(preferDisclosure) {
        if (preferDisclosure && disclose.visible) disclose.forceActiveFocus(Qt.TabFocusReason);
        else if (translating && cancel.visible) cancel.forceActiveFocus(Qt.TabFocusReason);
        else primary.forceActiveFocus(Qt.TabFocusReason);
    }
    ToolTip.visible:hover.hovered && stage==="failed"
    ToolTip.text:primary.Accessible.description
    ToolTip.delay:500
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
        text: chip.translating ? qsTr("Translating…") : chip.stage==="failed" ? qsTr("Retry translation")
            : chip.stage==="original" ? qsTr("Translate") : qsTr("Show original")
        enabled: !chip.translating && (chip.stage!=="failed" || chip.retryAllowed)
        font.pixelSize: 10
        font.weight: Font.Medium
        icon.source: chip.stage==="translated" ? "qrc:/icons/undo.svg" : "qrc:/icons/translation.svg"
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
        Accessible.name: chip.translating ? qsTr("Translating") : chip.stage==="failed" ? qsTr("Retry translation")
            : chip.stage==="original" ? qsTr("Show the cached translation") : qsTr("Show original text")
        Accessible.description: chip.stage==="failed" ? [chip.contextDescription,chip.errorMessage,
            chip.retryAllowed ? qsTr("Preview the retry before sending.") : qsTr("Wait for the current translations to finish before previewing a retry.")].filter(function(text){return text.length;}).join(" ") : chip.contextDescription
        ToolTip.visible: hovered && chip.stage!=="failed"
        ToolTip.text: chip.stage==="failed" ? Accessible.description : Accessible.name
        ToolTip.delay: 500
        onClicked: if(chip.stage==="failed")chip.retryRequested();else chip.toggleRequested()
    }
    Controls.ToolButton {
        id: cancel
        objectName:"translationCancel"
        x:primary.x+primary.width+3;y:1;width:16;height:20;padding:0
        visible:chip.translating
        enabled:!chip.cancelPending
        text:"×";font.pixelSize:11;font.weight:Font.DemiBold
        hoverEnabled:true
        palette.buttonText:chip.app.colors.accent
        background:Rectangle {color:"transparent";radius:3;border.width:cancel.visualFocus?2:0;border.color:chip.app.colors.focusRing}
        Accessible.name:qsTr("Cancel translation")
        Accessible.description:chip.contextDescription
        ToolTip.visible:hovered
        ToolTip.text:qsTr("Cancel this translation")
        ToolTip.delay:500
        onClicked:chip.cancelRequested()
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
        visible: chip.clipped && chip.stage==="translated"
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

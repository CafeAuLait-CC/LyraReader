import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import "ReaderLogic.js" as Logic

ToolBar {
    id: tools
    required property var app
    enabled: app.canModifyPdf
    implicitHeight: 46
    background: Rectangle {
        color: app.colors.panelBg
        border.width: 1
        border.color: app.colors.separator
    }
    Flickable {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        contentWidth: row.implicitWidth
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        RowLayout {
            id: row
            height: parent.height
            spacing: 3
            Repeater {
                model: [
                    {
                        kind: "highlight",
                        icon: "annotations",
                        name: qsTr("Highlight")
                    },
                    {
                        kind: "underline",
                        icon: "underline",
                        name: qsTr("Underline")
                    },
                    {
                        kind: "strikeout",
                        icon: "strikeout",
                        name: qsTr("Strikethrough")
                    },
                    {
                        kind: "ink",
                        icon: "pen",
                        name: qsTr("Pen")
                    },
                    {
                        kind: "square",
                        icon: "square",
                        name: qsTr("Rectangle")
                    },
                    {
                        kind: "circle",
                        icon: "circle",
                        name: qsTr("Ellipse")
                    },
                    {
                        kind: "line",
                        icon: "line",
                        name: qsTr("Line")
                    },
                    {
                        kind: "arrow",
                        icon: "arrow",
                        name: qsTr("Arrow")
                    },
                    {
                        kind: "stickyNote",
                        icon: "note",
                        name: qsTr("Sticky Note")
                    },
                    {
                        kind: "textBox",
                        icon: "free-text",
                        name: qsTr("Text Box")
                    },
                    {
                        kind: "eraser",
                        icon: "eraser",
                        name: qsTr("Erase parts of ink strokes")
                    }
                ]
                LyraToolButton {
                    required property var modelData
                    symbol: modelData.icon
                    text: modelData.name
                    selected: app.annotationTool === modelData.kind
                    onClicked: app.setAnnotationTool(modelData.kind)
                }
            }
            ToolSeparator {}
            Repeater {
                model: ["#E8BC55", "#EFA77D", "#90B79A", "#7DADD6", "#AB9ACB", "#D99A9B"]
                ToolButton {
                    required property string modelData
                    implicitWidth: 26
                    implicitHeight: 30
                    Accessible.name: qsTr("Annotation colour %1").arg(modelData)
                    background: Rectangle {
                        anchors.centerIn: parent
                        width: 19
                        height: 19
                        radius: 10
                        color: modelData
                        border.width: app.brushColor === modelData ? 2 : 1
                        border.color: app.brushColor === modelData ? app.colors.focusRing : app.colors.controlBorder
                    }
                    onClicked: app.brushColor = modelData
                }
            }
            ToolButton {
                text: "…"
                Accessible.name: qsTr("Custom annotation colour")
                onClicked: customColor.open()
            }
            SpinBox {
                from: 1
                to: 16
                value: app.brushWidth
                implicitWidth: 78
                implicitHeight: 30
                onValueModified: app.brushWidth = value
                Accessible.name: qsTr("Stroke width")
            }
            LyraToolButton {
                symbol: "undo"
                text: qsTr("Undo (Ctrl+Z)")
                enabled: !!app.markState.can_undo || !!app.markState.can_page_undo
                onClicked: app.undo()
            }
            LyraToolButton {
                symbol: "redo"
                text: qsTr("Redo (Ctrl+Shift+Z)")
                enabled: !!app.markState.can_redo || !!app.markState.can_page_redo
                onClicked: app.redo()
            }
            LyraToolButton {
                symbol: "close"
                text: qsTr("Close annotation tools")
                onClicked: {
                    app.annotationTool = "select";
                    app.annotationToolsVisible = false;
                }
            }
        }
    }
    ColorDialog {
        id: customColor
        title: qsTr("Annotation colour")
        options: ColorDialog.ShowAlphaChannel
        selectedColor: app.brushColor
        onAccepted: {
            app.brushColor = "#" + Logic.hex(selectedColor.r * 255) + Logic.hex(selectedColor.g * 255) + Logic.hex(selectedColor.b * 255);
            app.brushOpacity = selectedColor.a;
        }
    }
}

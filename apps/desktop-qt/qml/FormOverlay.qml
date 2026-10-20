import QtQuick
import QtQuick.Controls

Item {
    id: formOverlay
    required property var app
    required property int page
    visible: app.formToolActive
    readonly property var widgets: {
        const fields = app.currentReader.data.forms ? app.currentReader.data.forms.fields : [];
        const result = [];
        for (const field of fields)
            for (let i = 0; i < field.widgets.length; ++i)
                if (field.widgets[i].page === page)
                    result.push({
                        field: field,
                        box: field.widgets[i],
                        index: i
                    });
        return result;
    }
    Repeater {
        model: formOverlay.visible ? formOverlay.widgets : []
        Item {
            id: widget
            required property var modelData
            readonly property var field: modelData.field
            readonly property var draft: app.formValues[field.id] || null
            readonly property string textValue: draft && draft.text !== null && draft.text !== undefined ? draft.text : field.value || ""
            readonly property int selectedIndex: draft && draft.selected !== null && draft.selected !== undefined ? draft.selected : field.selected.length ? field.selected[0] : -1
            readonly property bool checkedValue: draft && draft.checked !== null && draft.checked !== undefined ? draft.checked : field.checked
            x: modelData.box.x_pt * app.zoom
            y: modelData.box.y_pt * app.zoom
            width: modelData.box.width_pt * app.zoom
            height: modelData.box.height_pt * app.zoom
            enabled: field.editable && app.currentReader.pendingCommands === 0
            Rectangle {
                anchors.fill: parent
                color: app.colors.fieldBg
                border.color: widget.draft ? app.colors.accentBorder : app.colors.controlBorder
                radius: 2
                opacity: .94
            }
            TextField {
                objectName: "formText_" + widget.field.id + "_" + widget.modelData.index
                anchors.fill: parent
                visible: widget.field.kind === "text" && !widget.field.multiline
                text: widget.textValue
                maximumLength: widget.field.max_length || 32767
                font.pixelSize: Math.max(9, Math.round(widget.field.font_size_pt * app.zoom))
                Accessible.name: widget.field.name + (widget.field.required ? qsTr(" (required)") : "")
                selectByMouse: true
                onTextEdited: app.updateFormValue(widget.field.id, {
                    text: text,
                    checked: null,
                    selected: null
                })
            }
            ScrollView {
                anchors.fill: parent
                visible: widget.field.kind === "text" && widget.field.multiline
                contentWidth: availableWidth
                TextArea {
                    objectName: "formMultiline_" + widget.field.id + "_" + widget.modelData.index
                    text: widget.textValue
                    font.pixelSize: Math.max(9, Math.round(widget.field.font_size_pt * app.zoom))
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.PlainText
                    selectByMouse: true
                    Accessible.name: widget.field.name
                    onTextChanged: if (activeFocus && text !== widget.textValue)
                        app.updateFormValue(widget.field.id, {
                            text: text,
                            checked: null,
                            selected: null
                        })
                }
            }
            CheckBox {
                objectName: "formCheck_" + widget.field.id + "_" + widget.modelData.index
                visible: widget.field.kind === "checkBox"
                anchors.fill: parent
                padding: 0
                checked: widget.checkedValue
                Accessible.name: widget.field.name
                indicator: Rectangle {
                    anchors.centerIn: parent
                    width: Math.max(1, Math.min(widget.width, widget.height) - 4)
                    height: width
                    radius: 2
                    color: app.colors.fieldBg
                    border.color: app.colors.accentBorder
                    Label {
                        anchors.centerIn: parent
                        text: "✓"
                        visible: parent.parent.checked
                        font.pixelSize: Math.max(8, Math.round(parent.height * .8))
                        color: app.colors.textPrimary
                    }
                }
                onToggled: app.updateFormValue(widget.field.id, {
                    text: null,
                    checked: checked,
                    selected: null
                })
            }
            RadioButton {
                objectName: "formRadio_" + widget.field.id + "_" + widget.modelData.index
                visible: widget.field.kind === "radio"
                anchors.fill: parent
                padding: 0
                autoExclusive: false
                checked: widget.selectedIndex === widget.modelData.index
                Accessible.name: widget.field.name + ": " + (widget.field.options[widget.modelData.index] ? widget.field.options[widget.modelData.index].label : widget.modelData.index + 1)
                indicator: Rectangle {
                    anchors.centerIn: parent
                    width: Math.max(1, Math.min(widget.width, widget.height) - 4)
                    height: width
                    radius: width / 2
                    color: app.colors.fieldBg
                    border.color: app.colors.accentBorder
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width * .5
                        height: width
                        radius: width / 2
                        color: app.colors.accent
                        visible: parent.parent.checked
                    }
                }
                onClicked: app.updateFormValue(widget.field.id, {
                    text: null,
                    checked: null,
                    selected: widget.modelData.index
                })
            }
            ComboBox {
                objectName: "formChoice_" + widget.field.id + "_" + widget.modelData.index
                anchors.fill: parent
                visible: widget.field.kind === "comboBox" || widget.field.kind === "listBox"
                model: widget.field.options
                textRole: "label"
                currentIndex: widget.selectedIndex
                font.pixelSize: Math.max(9, Math.round(widget.field.font_size_pt * app.zoom))
                Accessible.name: widget.field.name
                onActivated: app.updateFormValue(widget.field.id, {
                    text: null,
                    checked: null,
                    selected: currentIndex
                })
            }
            Label {
                anchors.fill: parent
                visible: widget.field.kind === "signature"
                text: qsTr("Signature field · read only")
                wrapMode: Text.Wrap
                color: app.colors.textSecondary
                font.pixelSize: 10
            }
            ToolTip.visible: hover.hovered
            ToolTip.text: widget.field.name + (widget.field.editable ? "" : qsTr(" · read only"))
            HoverHandler {
                id: hover
            }
        }
    }
}

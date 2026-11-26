import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "SummaryPresentation.js" as Presentation

ColumnLayout {
    id: summary
    objectName: "aiSummarySections"
    required property var app
    required property var value
    required property var renderer
    property string answerName: "aiAnswerText"
    property Flickable viewport: null
    readonly property string sourceText: value.output || ""
    readonly property var parsed: Presentation.sections(sourceText)
    property var expanded: ({})
    signal citation(string link, var plan)
    signal keyboardNavigation(int key)
    onSourceTextChanged: expanded = ({})
    Layout.minimumWidth: 0
    spacing: 16
    Repeater {
        model: summary.parsed.groups
        ColumnLayout {
            id: section
            required property var modelData
            required property int index
            readonly property bool open: summary.expanded[index] === undefined
                ? index < 2 || Presentation.headingText(modelData.title).toLowerCase().indexOf("key ideas") >= 0
                : summary.expanded[index]
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: modelData.title && modelData.blocks.length && open ? 8 : 0
            Label {
                visible: !!section.modelData.title && !section.modelData.blocks.length
                Layout.fillWidth: true; Layout.minimumWidth: 0
                text: Presentation.headingText(section.modelData.title)
                textFormat: Text.PlainText; wrapMode: Text.Wrap
                font.pixelSize: 13; font.weight: Font.DemiBold; color: app.colors.textPrimary
            }
            Button {
                id: heading
                objectName: "aiSummaryHeading" + section.index
                visible: !!section.modelData.title && section.modelData.blocks.length > 0
                Layout.fillWidth: true; Layout.minimumWidth: 0
                implicitHeight: Math.max(30, implicitContentHeight)
                padding: 0
                Accessible.name: Presentation.headingText(section.modelData.title)
                Accessible.description: !enabled ? "" : section.open ? qsTr("Expanded") : qsTr("Collapsed")
                contentItem: RowLayout {
                    spacing: 7
                    Label {
                        visible: heading.enabled
                        text: section.open ? "⌄" : "›"
                        font.pixelSize: 10; font.weight: Font.DemiBold; color: app.colors.textSecondary
                    }
                    Label {
                        text: Presentation.headingText(section.modelData.title)
                        textFormat: Text.PlainText; wrapMode: Text.Wrap
                        Layout.fillWidth: true; Layout.minimumWidth: 0
                        color: app.colors.textPrimary; font.pixelSize: 13; font.weight: Font.DemiBold
                        font.underline: heading.hovered && heading.enabled
                    }
                }
                background: Rectangle { color: "transparent"; radius: 3; border.width: heading.visualFocus ? 2 : 0; border.color: app.colors.focusRing }
                onClicked: {
                    const next = Object.assign({}, summary.expanded); next[section.index] = !section.open; summary.expanded = next;
                }
            }
            Loader {
                Layout.fillWidth: true; Layout.minimumWidth: 0
                active: !section.modelData.title || section.open
                visible: active
                sourceComponent: ColumnLayout {
                    spacing: 8
                    Repeater {
                        model: section.modelData.blocks
                        Loader {
                            id: block
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true; Layout.minimumWidth: 0
                            sourceComponent: modelData.kind === "code" ? literal : prose
                            Component {
                                id: literal
                                TextArea {
                                    id: codeArea
                                    objectName: "aiSummaryCode" + section.index + "_" + block.index
                                    text: block.modelData.text
                                    textFormat: TextEdit.PlainText; wrapMode: TextEdit.WrapAnywhere
                                    readOnly: true; selectByMouse: true; selectByKeyboard: true
                                    font.family: "monospace"; font.pixelSize: 12
                                    color: app.colors.textPrimary
                                    Keys.onPressed: function(event) { summary.renderer.cursorKey(codeArea, event); }
                                    background: Rectangle { color: app.colors.fieldBg; radius: 5 }
                                }
                            }
                            Component {
                                id: prose
                                ColumnLayout {
                                spacing: 4
                                TextArea {
                                    id: proseArea
                                    Layout.fillWidth: true; Layout.minimumWidth: 0
                                    objectName: section.index === 0 && block.index === 0 ? summary.answerName : summary.answerName + "Section" + section.index + "_" + block.index
                                    readonly property var rendered: summary.renderer.renderFor(block.modelData.text)
                                    text: rendered.text
                                    textFormat: rendered.plain ? TextEdit.PlainText : TextEdit.RichText; wrapMode: TextEdit.Wrap
                                    readOnly: true; selectByMouse: true; selectByKeyboard: true
                                    padding: 0; background: null; font.pixelSize: 14; color: app.colors.textPrimary
                                    Accessible.name: qsTr("AI response section")
                                    Keys.onPressed: function(event) { summary.renderer.cursorKey(proseArea, event); }
                                    onLinkActivated: function(link) {
                                        summary.renderer.activateLink(link);
                                    }
                                }
                                Label {
                                    text: proseArea.rendered.warning || ""
                                    visible: text.length > 0
                                    textFormat: Text.PlainText; wrapMode: Text.Wrap
                                    Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11
                                }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    Label {
        visible: summary.parsed.limited
        text: qsTr("Additional content is shown as plain text. Copy keeps the complete original answer.")
        textFormat: Text.PlainText; wrapMode: Text.Wrap
        Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11
    }
}

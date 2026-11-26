import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: document
    required property var app
    required property var renderer
    property var blocks: []
    property string answerName: "aiAnswerText"
    readonly property var textControl: rows.count && rows.itemAt(0) && rows.itemAt(0).item
        ? rows.itemAt(0).item.textControl : null
    Layout.minimumWidth: 0
    spacing: 0
    Repeater {
        id: rows
        // Stable indices keep a streaming code block's native focus/selection
        // owner alive while its text grows. Parsing and budgets live in C++.
        model: document.blocks.length
        Loader {
            id: row
            required property int index
            readonly property var block: document.blocks[index] || ({})
            readonly property string textName: index === 0 ? document.answerName : document.answerName + "Block" + index
            Layout.fillWidth: true; Layout.minimumWidth: 0
            Layout.bottomMargin: block.kind === "code" || block.kind === "table" ? 8 : 0
            sourceComponent: block.kind === "code" ? code : block.kind === "table" ? table : block.kind === "quote" ? quote : prose
            Component {
                id: table
                AiTableBlock {
                    app: document.app; renderer: document.renderer
                    rows: row.block.rows || []; columns: row.block.columns || 1; textName: row.textName
                }
            }
            Component {
                id: code
                AiCodeBlock {
                    app: document.app; renderer: document.renderer
                    sourceText: row.block.text || ""; language: row.block.language || ""; textName: row.textName
                }
            }
            Component {
                id: prose
                TextArea {
                    id: area
                    Component.onCompleted: if (typeof document.renderer.configureReadingMenu === "function") document.renderer.configureReadingMenu(area)
                    readonly property var textControl: area
                    objectName: row.textName
                    text: row.block.text || ""; textFormat: TextEdit.RichText
                    wrapMode: TextEdit.Wrap; readOnly: true; selectByMouse: true; selectByKeyboard: true
                    padding: 0; background: null; color: app.colors.textPrimary
                    Accessible.name: qsTr("AI response section")
                    Keys.onPressed: function(event) { document.renderer.cursorKey(area, event); }
                    onLinkActivated: function(link) { document.renderer.activateLink(link); }
                }
            }
            Component {
                id: quote
                RowLayout {
                    readonly property var textControl: nested.item ? nested.item.textControl : null
                    spacing: 10
                    Rectangle { width: 2; Layout.fillHeight: true; color: app.colors.separator }
                    Loader {
                        id: nested
                        Layout.fillWidth: true; Layout.minimumWidth: 0
                        // Dynamic recursion follows only the formatter's bounded
                        // quote tree; no provider-controlled component or URL.
                        Component.onCompleted: setSource("AiMarkdownBlocks.qml", {
                            app: document.app, renderer: document.renderer,
                            blocks: Qt.binding(function() { return row.block.children || []; }),
                            answerName: Qt.binding(function() { return row.textName; })
                        })
                    }
                }
            }
        }
    }
}

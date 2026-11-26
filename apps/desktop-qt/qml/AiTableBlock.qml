import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

AiHorizontalReadingView {
    id: table
    property var rows: []
    property int columns: 1
    property string textName: ""
    viewName: textName + "Table"
    outlined: true
    // Keep normal tables at their native preferred width. Once minimum cell
    // widths cannot fit, provide a horizontal viewport instead of clipping.
    readonly property real minimumGridWidth: columns * 24 + Math.max(0, columns - 1) * 14
    measuredWidth: minimumGridWidth + 16 > width
        ? Math.max(minimumGridWidth + 16, Math.min(grid.implicitWidth + 16, columns * 240 + Math.max(0, columns - 1) * 14 + 16))
        : minimumGridWidth + 16
    measuredHeight: grid.implicitHeight + 16
    surfaceWidth: Math.min(width, grid.width + 16)
    readonly property var textControl: rowItems.count && rowItems.itemAt(0) && rowItems.itemAt(0).count
        ? rowItems.itemAt(0).itemAt(0) : null
    Accessible.role: Accessible.Grouping
    Accessible.name: qsTr("Table: %1 rows, %2 columns").arg(rows.length).arg(columns)
    function reveal(area, owner, generation, source) {
        if (!area || !area.activeFocus || !visible || !owner || app.currentReader !== owner
                || owner.documentGeneration !== generation || area.text !== source) return;
        revealCursor(area);
    }
    GridLayout {
        id: grid
        objectName: table.textName + "TableGrid"
        x: 8; y: 8
        columns: table.columns
        width: table.minimumGridWidth + 16 > table.width ? table.contentWidth - 16
            : Math.max(table.minimumGridWidth, Math.min(Math.max(0, table.width - 16), implicitWidth))
        columnSpacing: 14; rowSpacing: 5
        Repeater {
            id: rowItems
            model: table.rows.length
            Repeater {
                id: row
                required property int index
                readonly property int rowIndex: index
                model: table.columns
                TextArea {
                    id: cell
                    Component.onCompleted: if (table.renderer && typeof table.renderer.configureReadingMenu === "function") table.renderer.configureReadingMenu(cell)
                    required property int index
                    readonly property var cellData: (table.rows[row.rowIndex] || [])[index] || ({})
                    objectName: row.rowIndex === 0 && index === 0 ? table.textName
                        : table.textName + "Cell" + row.rowIndex + "_" + index
                    Layout.row: row.rowIndex === 0 ? 0 : row.rowIndex + 1
                    Layout.column: index
                    Layout.fillWidth: true; Layout.minimumWidth: 24
                    // Measure with the same native document/font but without a
                    // constrained width. Otherwise wrapped implicit widths can
                    // feed back into GridLayout and collapse every column.
                    Layout.preferredWidth: Math.max(24, Math.ceil(preferredWidth))
                    // Keep Qt's native control allowance as well as glyph
                    // width; the Grid's integer slots must round it upward.
                    readonly property real preferredWidth: natural.implicitWidth
                    text: cellData.text || ""
                    textFormat: TextEdit.RichText; wrapMode: TextEdit.Wrap
                    horizontalAlignment: cellData.alignment === "right" ? TextEdit.AlignRight
                        : cellData.alignment === "center" ? TextEdit.AlignHCenter : TextEdit.AlignLeft
                    readOnly: true; selectByMouse: true; selectByKeyboard: true
                    padding: 0; background: null
                    font.pixelSize: 12; font.weight: row.rowIndex === 0 ? Font.DemiBold : Font.Normal
                    color: app.colors.textPrimary
                    Accessible.name: row.rowIndex === 0 ? qsTr("Table heading %1").arg(index + 1)
                        : qsTr("Table row %1, column %2").arg(row.rowIndex + 1).arg(index + 1)
                    Keys.onPressed: function(event) {
                        if (table.renderer) table.renderer.cursorKey(cell, event);
                        if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down, Qt.Key_Home,
                             Qt.Key_End, Qt.Key_PageUp, Qt.Key_PageDown].indexOf(event.key) >= 0) {
                            const owner = app.currentReader;
                            Qt.callLater(table.reveal, cell, owner, owner ? owner.documentGeneration : 0, cell.text);
                        }
                        event.accepted = false;
                    }
                    onLinkActivated: function(link) { if (table.renderer) table.renderer.activateLink(link); }
                    TextArea {
                        id: natural
                        objectName: "aiTableIntrinsicMeasure"
                        visible: false; activeFocusOnTab: false
                        text: cell.text; textFormat: TextEdit.RichText; wrapMode: TextEdit.NoWrap
                        font: cell.font; readOnly: true; selectByMouse: false; selectByKeyboard: false
                        padding: 0; background: null
                    }
                }
            }
        }
        Item {
            visible: table.rows.length > 0
            Layout.row: 1; Layout.column: 0; Layout.columnSpan: table.columns
            // GridLayout rounds its slots to logical pixels. Keep the actual
            // half-point rule inside that slot rather than thickening it.
            Layout.fillWidth: true; implicitHeight: 1
            Rectangle {
                objectName: table.textName + "TableHeaderRule"
                width: parent.width; height: 0.5; anchors.verticalCenter: parent.verticalCenter
                antialiasing: true; color: app.colors.separator
            }
        }
    }
}

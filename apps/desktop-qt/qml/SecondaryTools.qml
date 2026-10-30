import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id:rows
    required property var app
    property alias fillTools:fill
    implicitHeight:46
    AnnotationTools {objectName:"annotationToolRow";anchors.fill:parent;app:rows.app;visible:app.secondaryRow==="annotate"}
    FillSignTools {id:fill;objectName:"fillSignToolRow";anchors.fill:parent;app:rows.app;visible:app.secondaryRow==="fill"}
    Rectangle {anchors.fill:parent;color:app.colors.panelBg;visible:["edit","export","lyra"].indexOf(app.secondaryRow)>=0}
    RowLayout {
        objectName:"editToolRow"
        anchors.centerIn:parent;spacing:6
        visible:app.secondaryRow==="edit"
        LyraToolButton {objectName:"editTextTool";symbol:"free-text";text:qsTr("Text");display:AbstractButton.TextBesideIcon;selected:app.contentEditor.tool==="text";enabled:app.canModifyPdf;onClicked:app.contentEditor.arm("text")}
        LyraToolButton {symbol:"view";text:qsTr("Image");display:AbstractButton.TextBesideIcon;selected:app.contentEditor.tool==="image";enabled:app.canModifyPdf;onClicked:app.contentEditor.arm("image")}
        LyraToolButton {symbol:"arrow";text:qsTr("Link");display:AbstractButton.TextBesideIcon;selected:app.contentEditor.tool==="link";enabled:app.canModifyPdf;onClicked:app.contentEditor.arm("link")}
        LyraToolButton {
            id:redactButton
            objectName:"editRedactTool"
            symbol:"redact";text:qsTr("Redact");display:AbstractButton.TextBesideIcon
            selected:["erase","blackout"].indexOf(app.contentEditor.tool)>=0;enabled:app.canModifyPdf
            onClicked:redactMenu.popup(0,height)
            Menu {
                id:redactMenu
                MenuItem {objectName:"contentBlackoutAction";text:qsTr("Blackout");onTriggered:app.contentEditor.arm("blackout")}
                MenuItem {objectName:"contentEraseAction";text:qsTr("Erase");onTriggered:app.contentEditor.arm("erase")}
            }
        }
        ToolSeparator {}
        LyraToolButton {symbol:"pages";text:qsTr("Page operations");enabled:app.canModifyPdf;onClicked:app.showOverview()}
        LyraToolButton {symbol:"undo";text:qsTr("Undo");enabled:!!app.markState.can_page_undo || !!app.markState.can_undo;onClicked:app.undo()}
        LyraToolButton {symbol:"redo";text:qsTr("Redo");enabled:!!app.markState.can_page_redo || !!app.markState.can_redo;onClicked:app.redo()}
    }
    ExportTools {objectName:"exportToolRow";anchors.fill:parent;app:rows.app;visible:app.secondaryRow==="export"}
    RowLayout {
        objectName:"lyraToolRow"
        anchors.centerIn:parent;spacing:6
        visible:app.secondaryRow==="lyra"
        Repeater {
            model:[{key:"summary",title:qsTr("Summary")},{key:"translation",title:qsTr("Translate")},{key:"chat",title:qsTr("Chat")}]
            LyraToolButton {
                required property var modelData
                objectName:"lyraWorkspace"+modelData.key
                symbol:"ai";text:modelData.title;display:AbstractButton.TextBesideIcon
                selected:app.aiPanelVisible && ((app.currentReader.aiState.input || {}).view || "summary")===modelData.key
                onClicked:app.openAiWorkspace(modelData.key)
            }
        }
    }
    Rectangle {anchors.bottom:parent.bottom;width:parent.width;height:1;color:app.colors.separator}
}

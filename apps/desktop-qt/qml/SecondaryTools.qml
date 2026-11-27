import QtQuick
import QtQuick.Controls

Item {
    id:rows
    required property var app
    property alias fillTools:fill
    readonly property NumberAnimation revealAnimation: heightReveal
    readonly property string requestedRow: app.currentReader.pageCount > 0 && !app.overviewVisible && !app.textViewVisible ? app.secondaryRow : ""
    property string presentedRow: ""
    onRequestedRowChanged: if (requestedRow.length) presentedRow = requestedRow
    Component.onCompleted: presentedRow = requestedRow
    readonly property int rowHeight: 46
    height: requestedRow.length ? rowHeight : 0
    visible: requestedRow.length > 0 || height > 0
    enabled: requestedRow.length > 0
    Accessible.ignored: !enabled
    clip: true
    Behavior on height {
        enabled: !rows.app.reduceMotion
        NumberAnimation {
            id: heightReveal
            objectName: "secondaryRowRevealMotion"
            duration: 180
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0, 0, .58, 1, 1, 1]
        }
    }
    // Reveal above the reader without changing its viewport or the adjoining panels.
    Item {
        id: reveal
        width:parent.width
        height:rows.rowHeight
        y:rows.height-height
        Rectangle {anchors.fill:parent;color:app.colors.panelBg}
        MouseArea {anchors.fill:parent;acceptedButtons:Qt.AllButtons;hoverEnabled:true}
        AnnotationTools {objectName:"annotationToolRow";anchors.fill:parent;app:rows.app;visible:rows.presentedRow==="annotate"}
        FillSignTools {id:fill;objectName:"fillSignToolRow";anchors.fill:parent;app:rows.app;visible:rows.presentedRow==="fill"}
        SecondaryToolStrip {
            id:editStrip
            objectName:"editToolRow"
            anchors.fill:parent
            visible:rows.presentedRow==="edit"
            LyraToolButton {objectName:"editTextTool";symbol:"free-text";text:qsTr("Text");fitLabel:true;display:editStrip.compact ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon;selected:app.contentEditor.tool==="text";enabled:app.canModifyPdf;onClicked:app.contentEditor.arm("text")}
            LyraToolButton {symbol:"view";text:qsTr("Image");fitLabel:true;display:editStrip.compact ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon;selected:app.contentEditor.tool==="image";enabled:app.canModifyPdf;onClicked:app.contentEditor.arm("image")}
            LyraToolButton {symbol:"arrow";text:qsTr("Link");fitLabel:true;display:editStrip.compact ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon;selected:app.contentEditor.tool==="link";enabled:app.canModifyPdf;onClicked:app.contentEditor.arm("link")}
            LyraToolButton {
                id:redactButton
                objectName:"editRedactTool"
                symbol:"redact";text:qsTr("Redact");fitLabel:true
                display:editStrip.compact ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
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
        ExportTools {objectName:"exportToolRow";anchors.fill:parent;app:rows.app;visible:rows.presentedRow==="export"}
        SecondaryToolStrip {
            id:lyraStrip
            objectName:"lyraToolRow"
            anchors.fill:parent
            visible:rows.presentedRow==="lyra"
            LyraToolButton {
                objectName:"lyraRegionTool"
                readonly property string caption: qsTr("Interleaf")
                symbol:"interleaf";fitLabel:true
                display:lyraStrip.compact ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
                text:caption.replace(/&/g,"&&")
                Accessible.name:qsTr("Interleaf · Select & Ask")
                ToolTip.text:qsTr("Select & Ask")
                selected:app.regionSelecting
                enabled:app.currentReader.pageCount>0 && !app.currentReader.loading && (!!app.currentReader.aiRegion.image_png || !app.currentReader.aiState.running)
                onClicked:app.openRegionTool()
            }
            Repeater {
                model:[{key:"summary",title:qsTr("Summary")},{key:"translation",title:qsTr("Translate")},{key:"chat",title:qsTr("Chat")}]
                LyraToolButton {
                    required property var modelData
                    objectName:"lyraWorkspace"+modelData.key
                    symbol:modelData.key === "translation" ? "translation" : modelData.key; text:modelData.title;fitLabel:true
                    display:lyraStrip.compact ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
                    selected:app.aiPanelVisible && app.aiPanelMode==="assistant" && ((app.currentReader.aiState.input || {}).view || "summary")===modelData.key
                    onClicked:app.toggleAiWorkspace(modelData.key)
                }
            }
            LyraToolButton {objectName:"lyraReadingNotes";symbol:"note";text:qsTr("Reading notes");Accessible.name:qsTr("Reading notes");fitLabel:true;display:lyraStrip.compact ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon;selected:app.aiPanelVisible && app.aiPanelMode==="notes";enabled:app.currentReader.pageCount>0;onClicked:app.toggleAiWorkspace("notes")}
        }
        Rectangle {anchors.bottom:parent.bottom;width:parent.width;height:1;color:app.colors.separator}
    }
}

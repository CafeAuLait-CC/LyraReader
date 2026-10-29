import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ToolBar {
    id: tools
    required property var app
    implicitHeight: 46
    property var requestedOwner: null
    property var requestedGeneration: null
    readonly property var commands: [
        {id:"save",title:qsTr("Save"),name:qsTr("Save"),icon:"export"},
        {id:"saveAs",title:qsTr("Save As…"),name:qsTr("Save As…"),icon:"pages"},
        {id:"annotated",title:qsTr("Annotated…"),name:qsTr("Save Annotated Copy…"),icon:"pen"},
        {id:"flattened",title:qsTr("Flattened…"),name:qsTr("Export as Flattened Copy…"),icon:"overview"},
        {id:"filledForm",title:qsTr("Filled Form…"),name:qsTr("Save Filled Form Copy…"),icon:"form"},
        {id:"formValues",title:qsTr("Form Values…"),name:qsTr("Write Form Values to Original…"),icon:"free-text"},
        {id:"annotations",title:qsTr("Annotations…"),name:qsTr("Export Annotations…"),icon:"annotations"},
        {id:"print",title:qsTr("Print…"),name:qsTr("Print…"),icon:"print"}
    ]
    background: Rectangle {color:app.colors.panelBg}
    function refresh() {
        const owner=app.currentReader;
        if(!visible || !owner.pageCount || (requestedOwner===owner && requestedGeneration===owner.documentGeneration))return;
        requestedOwner=owner;requestedGeneration=owner.documentGeneration;
        if(!owner.data.document_info)owner.submit("document_info");
        if(!owner.data.forms)owner.submit("forms");
    }
    onVisibleChanged: if(visible){requestedOwner=null;refresh();}
    Connections {target:app;function onCurrentReaderChanged(){tools.refresh();}}
    Connections {target:app.currentReader;function onDocumentChanged(){tools.refresh();}}
    RowLayout {
        anchors.centerIn:parent
        spacing:6
        Repeater {
            model:tools.commands
            LyraToolButton {
                required property var modelData
                objectName:"exportCommand"+modelData.id
                symbol:modelData.icon;text:modelData.title
                display:app.width<1000 ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
                enabled:app.exportActionReason(modelData.id).length===0
                Accessible.name:modelData.name
                ToolTip.text:app.exportActionReason(modelData.id) || modelData.name
                onClicked:app.performExportAction(modelData.id)
            }
        }
    }
}

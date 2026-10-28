import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ToolBar {
    id: tools
    required property var app
    implicitHeight:46
    background:Rectangle {color:app.colors.panelBg}
    RowLayout {
        anchors.centerIn:parent
        spacing:6
        Repeater {
            model:[{kind:"text",name:qsTr("Text"),icon:"free-text"},
                {kind:"signature",name:qsTr("Signature"),icon:"signature"},
                {kind:"date",name:qsTr("Date"),icon:"note"},
                {kind:"check",name:qsTr("Checkmark"),icon:"pen"},
                {kind:"cross",name:qsTr("Cross"),icon:"close"},
                {kind:"stamp",name:qsTr("Stamp"),icon:"stamp"},
                {kind:"image",name:qsTr("Image"),icon:"view"}]
            LyraToolButton {
                id:button
                required property var modelData
                objectName:modelData.kind==="stamp" ? "stampToolButton" : modelData.kind==="signature" ? "signatureToolButton" : "fillTool"+modelData.kind
                symbol:modelData.icon;text:modelData.name;selected:app.fillTool===modelData.kind
                display:app.width<1000 ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
                enabled:app.canModifyPdf
                onClicked: {
                    app.setFillTool(modelData.kind);
                    if (modelData.kind==="stamp" && app.fillTool==="stamp") {stampMenu.parent=button;stampMenu.popup(0,button.height);}
                    else if (modelData.kind==="image" && app.fillTool==="image") chooseImage("image");
                }
            }
        }
    }
    function chooseImage(kind) {imagePicker.owner=app.currentReader;imagePicker.kind=kind;imagePicker.open();}
    function chooseTypedSignature() {if(app.blockXfaWrite() || app.fillTool!=="signature")return;typedSignature.owner=app.currentReader;typedSignature.open();}
    TypedSignatureDialog {id:typedSignature;app:tools.app}
    Menu {
        id:stampMenu
        Repeater {
            model:[{style:"approved",name:qsTr("Approved")},{style:"reviewed",name:qsTr("Reviewed")},
                {style:"draft",name:qsTr("Draft")},{style:"confidential",name:qsTr("Confidential")},{style:"date",name:qsTr("Date")}]
            MenuItem {required property var modelData;text:modelData.name;objectName:"stampStyle"+modelData.style;onTriggered:app.armStamp(modelData.style)}
        }
    }
    FileDialog {
        id:imagePicker
        objectName:"signatureImagePicker"
        property var owner:null
        property string kind:"signature"
        title:kind==="signature" ? qsTr("Choose a Signature Image") : qsTr("Choose an Image")
        nameFilters:[qsTr("Images (*.png *.jpg *.jpeg)")]
        fileMode:FileDialog.OpenFile
        onAccepted: {
            if(owner===app.currentReader && app.armSignature(selectedFile))app.fillTool=kind;
            else if(owner!==app.currentReader)app.operationStatus=qsTr("The document changed. Choose the image again.");
            owner=null;
        }
        onRejected:owner=null
    }
}

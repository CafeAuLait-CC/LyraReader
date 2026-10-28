import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

Pane {
    id:inspector
    required property var app
    padding:12
    background:Rectangle {color:app.colors.sidebarBg;border.color:app.colors.separator}
    ScrollView {
      id:scroll
      anchors.fill:parent
      clip:true
      contentWidth:availableWidth
      ColumnLayout {
        width:scroll.availableWidth
        RowLayout {
            Label {text:qsTr("Fill & Sign");font.bold:true;Layout.fillWidth:true}
            LyraToolButton {symbol:"close";text:qsTr("Clear Fill & Sign tool");onClicked:app.clearFillTool()}
        }
        Label {
            text:qsTr("Click on a page to place the armed tool. Escape cancels. Save writes the result into the PDF.")
            Layout.fillWidth:true;wrapMode:Text.Wrap;color:app.colors.textSecondary
        }
        TextArea {
            visible:["text","date"].indexOf(app.fillTool)>=0
            Layout.fillWidth:true;Layout.preferredHeight:100;textFormat:TextEdit.PlainText
            text:app.fillText;wrapMode:TextEdit.Wrap
            onTextChanged:if(activeFocus)app.fillText=text
            Accessible.name:qsTr("Text to place on the page")
        }
        SpinBox {visible:["text","date"].indexOf(app.fillTool)>=0;from:8;to:96;value:app.fillFontSize;editable:true;onValueModified:app.fillFontSize=value;Accessible.name:qsTr("Fill and Sign text size")}
        Button {visible:["text","date","check","cross"].indexOf(app.fillTool)>=0;text:qsTr("Colour…");onClicked:colour.open()}
        Button {
            objectName:"typeSignatureButton"
            visible:app.fillTool==="signature"
            text:qsTr("Type a Signature…");onClicked:app.fillTools.chooseTypedSignature()
        }
        Button {
            visible:["signature","image"].indexOf(app.fillTool)>=0
            text:qsTr("Choose Image…");onClicked:app.fillTools.chooseImage(app.fillTool)
        }
        Label {visible:app.fillTool==="image";text:qsTr("Picture size");color:app.colors.textPrimary}
        ComboBox {
            objectName:"fillPictureSize"
            visible:app.fillTool==="image"
            Layout.fillWidth:true
            textRole:"name"
            model:[{value:"small",name:qsTr("Small")},{value:"medium",name:qsTr("Medium")},{value:"large",name:qsTr("Large")}]
            currentIndex:app.fillImageSize==="small" ? 0 : app.fillImageSize==="large" ? 2 : 1
            onActivated:function(index){app.fillImageSize=model[index].value;}
            Accessible.name:qsTr("Picture placement size")
        }
        Rectangle {
            visible:!!app.pendingSignatureImage
            Layout.fillWidth:true;Layout.preferredHeight:100
            color:app.colors.documentPaper;border.color:app.colors.pageEdge;radius:4
            Image {
                objectName:"fillPicturePreview"
                anchors.fill:parent;anchors.margins:8;fillMode:Image.PreserveAspectFit
                source:app.pendingSignatureImage ? "data:image/png;base64,"+app.pendingSignatureImage.image : ""
                sourceSize.width:400;sourceSize.height:200
                Accessible.name:qsTr("Placement image preview")
            }
        }
        Label {text:qsTr("Form fields");font.bold:true;Layout.topMargin:12}
        Button {text:qsTr("Edit Form Fields…");enabled:!!app.currentReader.data.forms && app.currentReader.data.forms.fields.length>0;onClicked:app.toggleForms()}
        Button {text:qsTr("Save Filled Copy…");enabled:app.canModifyPdf && Object.keys(app.formValues).length>0;onClicked:app.chooseExport("forms")}
        Item {Layout.fillHeight:true}
      }
    }
    ColorDialog {id:colour;title:qsTr("Fill and Sign colour");selectedColor:app.fillColor;options:ColorDialog.ShowAlphaChannel;onAccepted:app.fillColor=selectedColor}
}

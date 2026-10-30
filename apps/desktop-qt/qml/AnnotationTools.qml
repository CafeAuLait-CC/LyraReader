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
    leftPadding:0;rightPadding:0;topPadding:0;bottomPadding:0
    background: Rectangle {color:app.colors.panelBg}
    component ToolToggle: LyraToolButton {
        required property string kind
        objectName:"annotateTool"+kind
        width:34;height:32
        selected:tools.app.annotationTool===kind
        onClicked:tools.app.setAnnotationTool(kind)
    }
    Row {
        x:14;y:7;spacing:0
        Row {
            objectName:"annotateGroupMarkup"
            spacing:2
            ToolToggle {kind:"highlight";symbol:"annotations";text:qsTr("Highlight")}
            ToolToggle {kind:"underline";symbol:"underline";text:qsTr("Underline")}
            ToolToggle {kind:"strikeout";symbol:"strikeout";text:qsTr("Strikethrough")}
        }
        Item {width:34;height:32}
        Row {
            objectName:"annotateGroupPointer"
            spacing:2
            ToolToggle {kind:"ink";symbol:"pen";text:qsTr("Pen")}
            ToolToggle {kind:"eraser";symbol:"eraser";text:qsTr("Erase parts of ink strokes")}
            ToolToggle {kind:"textBox";symbol:"free-text";text:qsTr("Text Box")}
            LyraToolButton {
                objectName:"annotateShapes";symbol:"square";text:qsTr("Shapes");width:34;height:32
                selected:["line","arrow","square","circle"].indexOf(app.annotationTool)>=0
                onClicked:shapes.popup(0,height)
                Menu {
                    id:shapes
                    Repeater {
                        model:[{kind:"line",name:qsTr("Line")},{kind:"arrow",name:qsTr("Arrow")},{kind:"square",name:qsTr("Rectangle")},{kind:"circle",name:qsTr("Ellipse")}]
                        MenuItem {required property var modelData;objectName:"annotateShape"+modelData.kind;text:modelData.name;checkable:true;checked:app.annotationTool===modelData.kind;onTriggered:app.setAnnotationTool(modelData.kind)}
                    }
                }
            }
        }
        Item {width:34;height:32}
        Row {
            objectName:"annotateGroupPlacement"
            spacing:2
            ToolToggle {kind:"stickyNote";symbol:"note";text:qsTr("Sticky Note")}
            LyraToolButton {
                objectName:"annotateStamp";symbol:"stamp";text:qsTr("Stamp");width:34;height:32
                selected:app.annotationTool==="stamp"
                onClicked:stamps.popup(0,height)
                Menu {
                    id:stamps
                    Repeater {
                        model:[{style:"approved",name:qsTr("Approved")},{style:"reviewed",name:qsTr("Reviewed")},{style:"draft",name:qsTr("Draft")},{style:"confidential",name:qsTr("Confidential")},{style:"date",name:qsTr("Date")}]
                        MenuItem {required property var modelData;objectName:"annotateStamp"+modelData.style;text:modelData.name;checkable:true;checked:app.annotationTool==="stamp" && app.pendingStampStyle===modelData.style;onTriggered:app.armStampForRow(modelData.style,"annotate")}
                    }
                }
            }
            LyraToolButton {
                objectName:"annotateSignature";symbol:"signature";text:qsTr("Signature");width:34;height:32
                selected:app.annotationTool==="signature"
                onClicked:signatures.popup(0,height)
                Menu {
                    id:signatures
                    MenuItem {objectName:"annotateImageSignature";text:qsTr("Place Image Signature…");onTriggered:tools.chooseSignature()}
                    MenuSeparator {}
                    MenuItem {objectName:"annotateDrawSignature";text:qsTr("Draw with the Pen");checkable:true;checked:app.annotationTool==="ink";onTriggered:app.setAnnotationTool("ink")}
                }
            }
        }
        Item {width:8;height:32}
        ToolButton {
            id:colourButton
            objectName:"annotateColour";width:32;height:32
            Accessible.name:qsTr("Annotation colour and stroke options")
            ToolTip.visible:hovered;ToolTip.text:Accessible.name
            contentItem:Item {Rectangle {anchors.centerIn:parent;width:17;height:17;radius:9;color:app.brushColor;border.width:1;border.color:app.colors.controlBorder}}
            onClicked:colours.popup(0,height)
            Menu {
                id:colours
                Repeater {
                    model:[{color:"#E8BC55",name:qsTr("Amber")},{color:"#EFA77D",name:qsTr("Peach")},{color:"#90B79A",name:qsTr("Sage")},{color:"#7DADD6",name:qsTr("Sky")},{color:"#AB9ACB",name:qsTr("Lavender")},{color:"#D99A9B",name:qsTr("Rose")}]
                    MenuItem {required property var modelData;text:modelData.name;checkable:true;checked:app.brushColor===modelData.color;onTriggered:app.brushColor=modelData.color}
                }
                MenuSeparator {}
                MenuItem {text:qsTr("Custom Colour…");onTriggered:customColor.open()}
                MenuItem {objectName:"annotateStrokeOptions";text:qsTr("Stroke Width and Opacity…");onTriggered:strokeOptions.open()}
            }
        }
    }
    function chooseSignature() {
        imagePicker.owner=app.currentReader;imagePicker.generation=app.currentReader.documentGeneration;imagePicker.open();
    }
    FileDialog {
        id:imagePicker
        objectName:"annotateSignatureImagePicker"
        property var owner:null
        property var generation:null
        title:qsTr("Choose a Signature Image")
        nameFilters:[qsTr("Images (*.png *.jpg *.jpeg)")]
        fileMode:FileDialog.OpenFile
        onAccepted: {
            if(owner && owner===app.currentReader && !owner.loading && generation===owner.documentGeneration && app.secondaryRow==="annotate")
                app.armImageDataForRow(owner.signatureImage(selectedFile),false,"annotate");
            else app.operationStatus=qsTr("The document changed. Choose the signature again.");
            owner=null;
        }
        onRejected:owner=null
    }
    Dialog {
        id:strokeOptions
        title:qsTr("Annotation Stroke Options")
        parent:Overlay.overlay;anchors.centerIn:parent
        width:Math.min(340,app.width-32)
        standardButtons:Dialog.Close
        ColumnLayout {
            anchors.fill:parent
            Label {text:qsTr("Stroke width (pt)")}
            SpinBox {objectName:"annotationBrushWidth";from:1;to:16;value:app.brushWidth;editable:true;onValueModified:app.brushWidth=value;Accessible.name:qsTr("Stroke width in points")}
            Label {text:qsTr("Markup opacity")}
            Slider {objectName:"annotationBrushOpacity";Layout.fillWidth:true;from:0;to:1;stepSize:.01;value:app.brushOpacity;onMoved:app.brushOpacity=value;Accessible.name:qsTr("Markup opacity")}
        }
    }
    ColorDialog {
        id:customColor
        title:qsTr("Annotation colour")
        options:ColorDialog.ShowAlphaChannel
        selectedColor:Logic.color({color:app.brushColor+Logic.hex(app.brushOpacity*255)})
        onAccepted: {
            app.brushColor="#"+Logic.hex(selectedColor.r*255)+Logic.hex(selectedColor.g*255)+Logic.hex(selectedColor.b*255);
            app.brushOpacity=selectedColor.a;
        }
    }
}

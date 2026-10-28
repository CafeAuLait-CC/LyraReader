import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id:dialog
    objectName:"drawnSignatureDialog"
    required property var app
    property var owner:null
    property var ownerGeneration:null
    property var ownerMutation:null
    readonly property bool contextMatches:!!owner && owner===app.currentReader && !owner.loading && owner.documentGeneration===ownerGeneration && owner.editRevision===ownerMutation
    readonly property bool canPlace:contextMatches && !!pad.signature && app.canModifyPdf
    title:qsTr("Draw a Signature")
    modal:true;focus:true
    anchors.centerIn:Overlay.overlay
    width:Math.min(520,app.width-32)
    height:Math.min(implicitHeight,app.height-32)
    padding:16
    background:Rectangle {color:app.colors.raisedBg;border.color:app.colors.controlBorder;radius:6}
    function prepare(reader){owner=reader;ownerGeneration=reader.documentGeneration;ownerMutation=reader.editRevision;pad.clear();}
    onOpened:pad.forceActiveFocus()
    onClosed:Qt.callLater(function(){if(!dialog.visible){pad.clear();dialog.owner=null;}})
    onAccepted:{if(canPlace)app.armDrawnSignature(pad.signature);else app.operationStatus=qsTr("The document changed. Draw the signature again.");}
    contentItem:ScrollView {
        id:scroll
        clip:true;contentWidth:availableWidth;implicitHeight:body.implicitHeight
        ColumnLayout {
            id:body
            width:scroll.availableWidth;spacing:10
            Label {Layout.fillWidth:true;wrapMode:Text.Wrap;text:qsTr("Draw with the pointer. The strokes become one vector ink annotation. This is a visual signature, not a digital signature that can detect later changes.");color:app.colors.textSecondary}
            SignaturePad {id:pad;objectName:"signaturePad";Layout.fillWidth:true;Layout.preferredHeight:170;colors:app.colors;rules:dialog.owner ? dialog.owner.data.annotation_rules : null}
            Button {objectName:"clearDrawnSignature";text:qsTr("Clear");onClicked:pad.clear()}
            Label {Layout.fillWidth:true;wrapMode:Text.Wrap;color:app.colors.warningFg;visible:text.length>0;text:!dialog.contextMatches ? qsTr("The document changed. Reopen the signature dialog.") : pad.limitReached ? qsTr("The drawing pad limit was reached. Place these strokes or clear the pad to start again.") : ""}
        }
    }
    footer:DialogButtonBox {
        Button {objectName:"placeDrawnSignature";text:qsTr("Place");enabled:dialog.canPlace;DialogButtonBox.buttonRole:DialogButtonBox.AcceptRole}
        Button {text:qsTr("Cancel");DialogButtonBox.buttonRole:DialogButtonBox.RejectRole}
        onAccepted:dialog.accept()
        onRejected:dialog.reject()
    }
}

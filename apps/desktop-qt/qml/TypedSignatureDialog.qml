import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Dialog {
    id:dialog
    objectName:"typedSignatureDialog"
    required property var app
    property var owner:null
    property string ownerUrl:""
    property var ownerRevision:null
    property var ownerMutation:null
    property var ownerGeneration:null
    property var rendered:null
    readonly property bool contextMatches:!!owner && owner===app.currentReader && !owner.loading && owner.documentGeneration===ownerGeneration && String(owner.fileUrl)===ownerUrl && owner.data.document_revision===ownerRevision && owner.editRevision===ownerMutation
    readonly property bool canPlace:contextMatches && !!rendered && !!rendered.image && app.canModifyPdf
    title:qsTr("Type a Signature")
    modal:true;focus:true
    anchors.centerIn:Overlay.overlay
    width:Math.min(520,app.width-32)
    height:Math.min(implicitHeight,app.height-32)
    padding:16
    background:Rectangle {color:app.colors.raisedBg;border.color:app.colors.controlBorder;radius:6}
    function prepare(reader) {owner=reader;ownerUrl=String(reader.fileUrl);ownerRevision=reader.data.document_revision;ownerMutation=reader.editRevision;ownerGeneration=reader.documentGeneration;rendered=null;}
    onOpened: {name.text="";fontChoice.currentIndex=0;name.forceActiveFocus();refresh.restart();}
    onClosed: {refresh.stop();Qt.callLater(function(){if(!dialog.visible){dialog.rendered=null;dialog.owner=null;}});}
    onAccepted: {
        if(canPlace)app.armSignatureData(rendered);
        else app.operationStatus=qsTr("The document changed. Choose the signature again.");
    }
    contentItem:ScrollView {
      id:scroll
      clip:true;contentWidth:availableWidth
      implicitHeight:signatureContent.implicitHeight
      ColumnLayout {
        id:signatureContent
        width:scroll.availableWidth
        spacing:10
        Label {text:qsTr("This places a visual signature, not a digital signature that can detect later changes.");Layout.fillWidth:true;wrapMode:Text.Wrap;color:app.colors.textSecondary}
        Label {text:qsTr("Name")}
        TextField {id:name;objectName:"typedSignatureName";Layout.fillWidth:true;maximumLength:256;placeholderText:qsTr("Your name");Accessible.name:qsTr("Signature name");onTextChanged:{dialog.rendered=null;refresh.restart();}onAccepted:if(dialog.canPlace)dialog.accept()}
        Label {text:qsTr("Font")}
        ComboBox {id:fontChoice;objectName:"typedSignatureFont";Layout.fillWidth:true;model:app.currentReader.signatureFonts();Accessible.name:qsTr("Signature font");onCurrentTextChanged:{dialog.rendered=null;refresh.restart();}}
        Rectangle {
            Layout.fillWidth:true;Layout.preferredHeight:130
            color:app.colors.documentPaper;border.color:app.colors.pageEdge;radius:4
            Image {anchors.fill:parent;anchors.margins:10;fillMode:Image.PreserveAspectFit;source:dialog.rendered && dialog.rendered.image ? "data:image/png;base64,"+dialog.rendered.image : "";Accessible.role:Accessible.Graphic;Accessible.name:qsTr("Typed signature preview")}
        }
        Label {Layout.fillWidth:true;wrapMode:Text.Wrap;color:app.colors.warningFg;visible:text.length>0;text:!dialog.contextMatches ? qsTr("The document changed. Reopen the signature dialog.") : dialog.rendered && dialog.rendered.error ? dialog.rendered.error : ""}
      }
    }
    footer:DialogButtonBox {
        Button {objectName:"placeTypedSignature";text:qsTr("Place");enabled:dialog.canPlace;DialogButtonBox.buttonRole:DialogButtonBox.AcceptRole}
        Button {objectName:"cancelTypedSignature";text:qsTr("Cancel");DialogButtonBox.buttonRole:DialogButtonBox.RejectRole}
        onAccepted:dialog.accept()
        onRejected:dialog.reject()
    }
    Timer {id:refresh;interval:100;onTriggered:if(dialog.opened && dialog.owner)dialog.rendered=dialog.owner.typedSignatureImage(name.text,fontChoice.currentText)}
}

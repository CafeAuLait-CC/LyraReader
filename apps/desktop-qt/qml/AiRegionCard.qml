import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

Popup {
    id:card
    objectName:"aiRegionCard"
    required property var app
    property var owner:null
    readonly property var attachment:owner ? owner.aiRegion : ({})
    readonly property var state:owner ? owner.aiState : ({})
    readonly property bool running:!!state.running
    readonly property var plan:state.previewView==="region" ? state.plan || null : null
    readonly property bool previewReady:!!plan && !state.planSent
    onPreviewReadyChanged:if(!previewReady && payload && payload.visible)payload.close()
    readonly property var result:state.responseView==="region" ? ({output:state.output,reasoning:state.reasoning,usage:state.usage,responsePlan:state.responsePlan,generation:owner.documentGeneration}) : ((state.results || {}).region || {})
    parent:Overlay.overlay
    x:(app.width-width)/2;y:Math.max(12,(app.height-height)/2)
    width:Math.min(560,app.width-24);height:Math.min(result.output || result.reasoning ? 740 : 560,app.height-48)
    padding:12;focus:true;modal:false
    closePolicy:Popup.CloseOnEscape
    background:Rectangle {color:card.app.colors.panelBg;border.color:card.app.colors.separator;radius:8}
    onAboutToShow:owner=app.currentReader
    onClosed:{payload.close();if(owner && app.currentReader===owner)app.focusReadingView();}
    function prepare(){if(owner===app.currentReader)owner.prepareAiRegion(app.aiSettings);}
    function follow(link,plan) {
        if(owner!==app.currentReader || plan.generation!==owner.documentGeneration)return;
        const match=/^p\.(\d+)$/.exec(link);
        if(match && (plan.source_pages || []).indexOf(Number(match[1]))>=0){app.navigate(Number(match[1])-1);close();}
    }
    contentItem:ColumnLayout {
        spacing:8
        RowLayout {
            Label {text:qsTr("Ask about this area");font.bold:true;Layout.fillWidth:true}
            ToolButton {objectName:"closeAiRegionCard";text:qsTr("Close");onClicked:card.close()}
        }
        BusyIndicator {running:!!card.attachment.loading;visible:running;Layout.alignment:Qt.AlignHCenter}
        ScrollView {
            Layout.fillWidth:true;Layout.fillHeight:true;contentWidth:availableWidth;clip:true
            ColumnLayout {
                width:parent.width;spacing:8
                Label {text:card.attachment.error || "";textFormat:Text.PlainText;visible:text.length>0;wrapMode:Text.Wrap;Layout.fillWidth:true;color:card.app.colors.warningFg}
                Item {
                    visible:!!card.attachment.image_png
                    Layout.fillWidth:true;Layout.preferredHeight:Math.min(180,width*(card.attachment.image_height_px || 1)/(card.attachment.image_width_px || 1))
                    PdfCrop {
                        objectName:"aiRegionImage"
                        anchors.centerIn:parent
                        width:Math.min(parent.width,parent.height*(card.attachment.image_width_px || 1)/(card.attachment.image_height_px || 1))
                        height:width*(card.attachment.image_height_px || 1)/(card.attachment.image_width_px || 1)
                        source:card.owner ? card.owner.aiRegionImage : ""
                        Accessible.role:Accessible.Graphic
                        Accessible.name:qsTr("Captured region from page %1").arg((card.attachment.page || 0)+1)
                        Accessible.description:qsTr("Original colour preview. Use Captured text to read the available text layer.")
                    }
                }
                Label {
                    visible:!!card.attachment.image_png;Layout.fillWidth:true;wrapMode:Text.Wrap
                    text:qsTr("Page %1 · %2 × %3 px · original colours").arg((card.attachment.page || 0)+1).arg(card.attachment.image_width_px || 0).arg(card.attachment.image_height_px || 0)
                    color:card.app.colors.textSecondary;font.pixelSize:11
                }
                Label {visible:!!card.attachment.text_warning;Layout.fillWidth:true;wrapMode:Text.Wrap;text:card.attachment.text_warning || "";textFormat:Text.PlainText;color:card.app.colors.warningFg}
                Label {visible:!!card.attachment.text_truncated;Layout.fillWidth:true;wrapMode:Text.Wrap;text:qsTr("The region text was limited to 12,000 characters.");color:card.app.colors.textSecondary}
                ToolButton {id:showText;visible:!!card.attachment.text;text:qsTr("Captured text");checkable:true}
                TextArea {objectName:"aiRegionText";visible:showText.visible && showText.checked;text:card.attachment.text || "";readOnly:true;selectByMouse:true;wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText;Layout.fillWidth:true}
                Label {
                    visible:!!card.attachment.image_png;Layout.fillWidth:true;wrapMode:Text.Wrap
                    text:card.app.aiSettings.imageInput ? qsTr("Image input is enabled. The captured PNG above will be included.") : qsTr("Text only. To send the captured PNG, enable region images for this model in Settings.")
                    color:card.app.colors.textSecondary;font.pixelSize:11
                }
                AiResult {app:card.app;value:card.result;answerName:"aiRegionAnswer";Layout.fillWidth:true;onCitation:function(link,plan){card.follow(link,plan);}}
            }
        }
        ScrollView {
            id:composer
            visible:!!card.attachment.image_png
            Layout.fillWidth:true;Layout.preferredHeight:80;Layout.maximumHeight:80;contentWidth:availableWidth;clip:true
            TextArea {
                objectName:"aiRegionQuestion"
                width:composer.availableWidth;text:card.attachment.question || ""
                readOnly:card.running
                wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText
                placeholderText:qsTr("Question about this area…");Accessible.name:qsTr("Question about area")
                onTextChanged:if(activeFocus && card.owner)card.owner.setAiRegionQuestion(text)
            }
        }
        Label {
            text:card.running && card.state.responseView!=="region" ? qsTr("Another assistant request is running in this tab.") : card.state.statusView==="region" ? card.state.status || "" : ""
            textFormat:Text.PlainText
            visible:text.length>0;wrapMode:Text.Wrap;Layout.fillWidth:true;font.pixelSize:11;color:card.app.colors.textSecondary
        }
        Label {
            visible:card.previewReady;Layout.fillWidth:true;wrapMode:Text.Wrap
            text:card.plan ? qsTr("Destination: %1 · %2 request(s). Nothing is sent before Send.").arg(card.plan.host).arg(card.plan.parts.length) : ""
            color:card.app.colors.infoFg;font.pixelSize:11
        }
        RowLayout {
            Layout.fillWidth:true
            Button {objectName:"prepareAiRegion";text:qsTr("Preview Question");enabled:!!card.attachment.image_png && !!(card.attachment.question || "").trim() && !card.running && card.owner && card.owner.pendingCommands===0;onClicked:card.prepare()}
            Button {objectName:"inspectAiRegion";text:qsTr("Inspect payload");enabled:card.previewReady;onClicked:payload.open()}
            Button {objectName:"sendAiRegion";text:qsTr("Send");enabled:card.previewReady && !card.running && card.owner && card.owner.pendingCommands===0;onClicked:card.app.sendAi(card.owner,card.plan)}
        }
        RowLayout {
            Button {objectName:"newAiRegion";text:qsTr("New area");enabled:!card.running && !card.attachment.loading;onClicked:card.app.armRegion()}
            Button {objectName:"stopAiRegion";visible:card.running && card.state.responseView==="region";text:qsTr("Stop response");onClicked:card.owner.cancelAi()}
            Button {objectName:"clearAiRegion";text:qsTr("Clear area");enabled:!card.running;onClicked:{card.owner.clearAiRegion();card.close();}}
        }
    }
    Dialog {
        id:payload;objectName:"aiRegionPayload"
        property var snapshot:null
        property string displayedBody:""
        onAboutToShow:{snapshot=card.plan;displayedBody=snapshot ? snapshot.parts.map(p=>p.wire_body.replace(/data:image\/png;base64,[A-Za-z0-9+/=]+/g,"[Captured PNG bytes]")).join("\n\n") : "";}
        onClosed:{snapshot=null;displayedBody="";}
        parent:Overlay.overlay;x:(card.app.width-width)/2;y:(card.app.height-height)/2
        width:Math.min(620,card.app.width-32);height:Math.min(560,card.app.height-60);modal:true;title:qsTr("Request payload")
        standardButtons:Dialog.Close
        ColumnLayout {
            anchors.fill:parent
            Label {Layout.fillWidth:true;wrapMode:Text.Wrap;text:qsTr("PNG bytes are hidden in this text view. The image above is the attachment; Copy payload includes the complete bytes.")}
            ScrollView {
                Layout.fillWidth:true;Layout.fillHeight:true;contentWidth:availableWidth
                TextArea {objectName:"aiRegionDisplayedPayload";width:parent.width;readOnly:true;selectByMouse:true;textFormat:TextEdit.PlainText;wrapMode:TextEdit.Wrap;text:payload.displayedBody}
            }
            Button {text:qsTr("Copy payload");enabled:!!payload.snapshot;onClicked:if(card.app.session)card.app.session.copyText(payload.snapshot.parts.map(p=>p.wire_body).join("\n\n"))}
        }
    }
}

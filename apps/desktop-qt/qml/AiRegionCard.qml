import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

Item {
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
    parent:app.documentCanvas
    property bool opened:false
    visible:opened
    z:6
    property int ownerGeneration:-1
    property bool needsReveal:false
    readonly property var paper:owner ? owner.aiRegionPaper : ({})
    readonly property var frame:app.documentCanvas ? app.documentCanvas.regionCardFrame(owner,app.documentCanvas.placementEpoch) : null
    readonly property bool located:!!paper.rows
    x:frame ? frame.x : 12
    y:frame ? frame.y : located ? -height-1 : Math.max(12,((app.documentCanvas ? app.documentCanvas.height : app.height)-height)/2)
    width:frame ? frame.width : Math.min(560,(app.documentCanvas ? app.documentCanvas.width : app.width)-24)
    readonly property real fullHeight:Math.max(44,Math.min(result.output || result.reasoning ? 740 : 560,(app.documentCanvas ? app.documentCanvas.height : app.height)-24))
    property real revealProgress:1
    property bool closing:false
    readonly property bool motionActive:opened && (needsReveal || reveal.running || closing)
    readonly property bool canAnimate:!app.reduceMotion && app.visible
    onCanAnimateChanged:if(!canAnimate && motionActive)completeMotion(app.visible)
    property var motionAnchor:null
    property real motionGapBottom:NaN
    property int motionInteraction:-1
    height:fullHeight*revealProgress
    clip:true;focus:true
    NumberAnimation {
        id:reveal;objectName:"paperRevealMotion";target:card;property:"revealProgress";duration:220;easing.type:Easing.InOutCubic
        onFinished:card.completeMotion(true)
    }
    function completeMotion(revealCard) {
        const wasClosing=closing;reveal.stop();revealProgress=wasClosing ? 0 : 1;
        if(wasClosing){closeCard(true);return;}
        needsReveal=false;
        if(revealCard && owner===app.currentReader && ownerGeneration===owner.documentGeneration) {
            app.documentCanvas.showRegionCard(owner);
            if(questionEditor.visible)questionEditor.forceActiveFocus();
        }
    }
    function closeAnimated() {
        if(!opened || closing)return;
        if(owner)owner.flushAiRegionNote();
        if(!canAnimate || !located){close();return;}
        reveal.stop();closing=true;needsReveal=false;
        motionAnchor=app.documentCanvas.viewportAnchor(0);motionInteraction=app.documentCanvas.interactionEpoch;
        const frame=app.documentCanvas.regionCardFrame(owner);
        motionGapBottom=frame && frame.y<0 && frame.y+frame.height>0 ? frame.y+frame.height : NaN;
        payload.close();reveal.to=0;reveal.start();
    }
    onRevealProgressChanged: {
        // Bindings must publish the interpolated row sizes before clamping its scroll.
        Qt.callLater(card.applyMotionFrame);
    }
    function applyMotionFrame() {
        if(!opened || owner!==app.currentReader || !located)return;
        app.documentCanvas.view.forceLayout();
        if(motionInteraction!==app.documentCanvas.interactionEpoch)return;
        if(needsReveal)app.documentCanvas.showRegionCard(owner);
        else if(closing && Number.isFinite(motionGapBottom)) {
            const frame=app.documentCanvas.regionCardFrame(owner);
            if(frame)app.documentCanvas.restorePaperViewAnchor({owner:owner,id:paper.id,
                interaction:motionInteraction,offsetY:0,viewY:Math.min(0,motionGapBottom-frame.height)});
        } else if(closing && motionAnchor)app.documentCanvas.restoreViewportAnchor(motionAnchor,0);
    }
    signal closed()
    function open() {
        if(opened && owner!==app.currentReader)closeCard(false);
        const wasOpened=opened;
        reveal.stop();closing=false;
        app.overviewVisible=false;app.textViewVisible=false;
        owner=app.currentReader;ownerGeneration=owner.documentGeneration;
        const immediateError=!!owner.aiRegion.error;
        revealProgress=wasOpened || !canAnimate || immediateError ? 1 : 0;
        opened=true;needsReveal=!immediateError;forceActiveFocus();requestPaper();
        if(paper.rows && !paper.loading) {
            layoutApply.restart();
        }
    }
    function close(){closeCard(true);}
    function closeCard(preserve) {
        if(!opened)return;
        const current=owner===app.currentReader && ownerGeneration===owner.documentGeneration;
        const anchor=preserve && current ? app.documentCanvas.viewportAnchor(0) : null;
        opened=false;needsReveal=false;closing=false;reveal.stop();layoutSettle.stop();layoutApply.stop();payload.close();discardChanges.close();
        if(owner){if(preserve)owner.flushAiRegionNote();owner.clearAiRegionPaper();}
        if(anchor && current)app.documentCanvas.restoreViewportAnchor(anchor,0);
        if(current)app.focusReadingView();
        closed();
    }
    property var pendingAnchor:null
    property int pendingInteraction:-1
    property bool pendingFocused:false
    Timer {id:layoutSettle;interval:0;onTriggered:card.configurePaperNow();}
    function requestPaper(){if(opened)layoutSettle.restart();}
    function configurePaperNow() {
        if(!opened || owner!==app.currentReader || owner.pendingCommands)return;
        if(!attachment.image_png){if(!attachment.loading && !attachment.error)closeCard(false);return;}
        const config=owner.layoutConfiguration;
        if(!config.mode || !Number.isFinite(config.gap))return;
        pendingAnchor=needsReveal ? null : app.documentCanvas.viewportAnchor(0);
        pendingInteraction=app.documentCanvas.interactionEpoch;
        const frame=app.documentCanvas.regionCardFrame(owner);
        // Retained keyboard focus must not drag an explicit page navigation back to
        // an offscreen conversation when a delayed zoom/content replan completes.
        pendingFocused=focusedWithin() && !!frame && frame.y<app.documentCanvas.height
                && frame.y+height>0;
        owner.configureAiRegionPaper(config.mode,config.gap,fullHeight/app.zoom);
    }
    Timer {id:layoutApply;interval:0;onTriggered:card.settlePaper();}
    function focusedWithin() {
        let item=app.activeFocusItem;
        while(item){if(item===card)return true;item=item.parent;}
        return false;
    }
    function settlePaper() {
        if(!opened || owner!==app.currentReader || !paper.rows || paper.loading)return;
        const keptZoom=app.documentCanvas.finishPaperZoom(owner);
        if(!keptZoom && !needsReveal && pendingAnchor && pendingInteraction===app.documentCanvas.interactionEpoch)
            app.documentCanvas.restoreViewportAnchor(pendingAnchor,0);
        if(needsReveal) {
            if(reveal.running)return;
            motionInteraction=app.documentCanvas.interactionEpoch;
            if(canAnimate && revealProgress<1){reveal.to=1;reveal.start();}
            else completeMotion(true);
        } else if(!keptZoom && pendingFocused && pendingInteraction===app.documentCanvas.interactionEpoch && focusedWithin())
            app.documentCanvas.showRegionCard(owner);
        app.schedulePositionSave();
    }
    onAttachmentChanged: {
        if(opened && owner && owner.documentGeneration!==ownerGeneration)closeCard(false);
        else if(opened && attachment.error){reveal.stop();closing=false;needsReveal=false;revealProgress=1;}
        else requestPaper();
    }
    onFullHeightChanged:requestPaper()
    onPaperChanged:if(opened && paper.error){reveal.stop();closing=false;needsReveal=false;revealProgress=1;}
    Connections {
        target:card.owner
        function onAiRegionPaperChanged(){layoutApply.restart();}
        function onCommandsChanged(){card.requestPaper();}
    }
    Connections {
        target:card.app
        function onZoomChanged(){card.requestPaper();}
    }
    Connections {
        target:card.app.documentCanvas
        function onInteractionEpochChanged(){if(reveal.running)card.completeMotion(false);}
    }
    Keys.onShortcutOverride:function(event){if(event.key===Qt.Key_Escape)event.accepted=true;}
    Keys.onEscapePressed:function(event){closeAnimated();event.accepted=true;}
    function prepare(){if(owner===app.currentReader)owner.prepareAiRegion(app.aiSettings);}
    function follow(link,plan) {
        if(owner!==app.currentReader || plan.generation!==owner.documentGeneration)return;
        const match=/^p\.(\d+)$/.exec(link);
        if(match && (plan.source_pages || []).indexOf(Number(match[1]))>=0){app.navigate(Number(match[1])-1);close();}
    }
    Pane {
        objectName:"aiRegionBody"
        width:card.width;height:card.fullHeight;padding:12
        opacity:.65+.35*card.revealProgress
        enabled:!card.closing
        background:Rectangle {color:card.app.colors.panelBg;border.color:card.app.colors.separator;radius:8}
    contentItem:ColumnLayout {
        spacing:8
        RowLayout {
            Label {text:qsTr("Ask about this area");font.bold:true;Layout.fillWidth:true}
            ToolButton {objectName:"closeAiRegionCard";text:qsTr("Close");onClicked:card.closeAnimated()}
        }
        Label {visible:!!card.attachment.restored;text:qsTr("Saved conversation · %1 completed turns. Preview includes the recent context.").arg(card.attachment.completed_turn_count || 0);wrapMode:Text.Wrap;Layout.fillWidth:true;color:card.app.colors.textSecondary}
        BusyIndicator {running:!!card.attachment.loading;visible:running;Layout.alignment:Qt.AlignHCenter}
        ScrollView {
            id: resultScroll
            Layout.fillWidth:true;Layout.fillHeight:true;contentWidth:availableWidth;clip:true
            ColumnLayout {
                width:parent.width;spacing:8
                Label {text:card.attachment.error || card.paper.error || "";textFormat:Text.PlainText;visible:text.length>0;wrapMode:Text.Wrap;Layout.fillWidth:true;color:card.app.colors.warningFg}
                Item {
                    visible:!!card.attachment.image_png
                    Layout.fillWidth:true;Layout.preferredHeight:Math.min(180,width*(card.attachment.image_height_px || 1)/(card.attachment.image_width_px || 1))
                    PdfCrop {
                        objectName:"aiRegionImage"
                        anchors.centerIn:parent
                        width:Math.min(parent.width,parent.height*(card.attachment.image_width_px || 1)/(card.attachment.image_height_px || 1))
                        height:width*(card.attachment.image_height_px || 1)/(card.attachment.image_width_px || 1)
                        source:card.owner ? card.owner.aiRegionImage : ""
                        // Decode the initial capture once, then defer budget-driven
                        // redecodes until paper geometry has stopped moving.
                        rasterDemandPaused:card.motionActive && status===1
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
                AiResult {app:card.app;viewport:resultScroll.contentItem;value:card.result;answerName:"aiRegionAnswer";Layout.fillWidth:true;onCitation:function(link,plan){card.follow(link,plan);}}
            }
        }
        ScrollView {
            id:composer
            visible:!!card.attachment.image_png
            Layout.fillWidth:true;Layout.preferredHeight:80;Layout.maximumHeight:80;contentWidth:availableWidth;clip:true
            TextArea {
                id:questionEditor;objectName:"aiRegionQuestion"
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
            visible:card.owner && !!card.owner.documentReading.choice_pending
            Layout.fillWidth:true
            Button {text:qsTr("Read document (optional)…");Layout.fillWidth:true;onClicked:card.app.openDocumentReading()}
            ToolButton {text:qsTr("Skip");Accessible.name:qsTr("Continue without document reading");onClicked:card.owner.dismissDocumentReadingChoice()}
        }
        RowLayout {
            Layout.fillWidth:true
            Button {objectName:"prepareAiRegion";text:qsTr("Preview Question");enabled:!!card.attachment.image_png && !!(card.attachment.question || "").trim() && !card.running && card.owner && card.owner.pendingCommands===0;onClicked:card.prepare()}
            Button {objectName:"inspectAiRegion";text:qsTr("Inspect payload");enabled:card.previewReady;onClicked:payload.open()}
            Button {objectName:"sendAiRegion";text:qsTr("Send");enabled:card.previewReady && !card.running && card.owner && card.owner.pendingCommands===0;onClicked:card.app.sendAi(card.owner,card.plan)}
        }
        Label {
            objectName:"aiRegionPersistenceStatus"
            Layout.fillWidth:true;wrapMode:Text.Wrap;font.pixelSize:11;color:card.app.colors.textSecondary
            text:card.attachment.saved ? qsTr("Saved in Reading notes on this device.") : card.owner && card.owner.regionPersistenceError ? qsTr("This conversation has not been saved. Retry saving to keep the latest changes.") : qsTr("Saving this area and its conversation to Reading notes on this device…")
        }
        Label {text:card.owner ? card.owner.regionHistory.error || "" : "";visible:text.length>0;wrapMode:Text.Wrap;Layout.fillWidth:true;color:card.app.colors.warningFg;textFormat:Text.PlainText}
        Button {objectName:"saveAiRegionNote";text:qsTr("Save to Reading notes");enabled:!!card.attachment.image_png && !card.running && card.owner && !card.owner.pendingCommands;onClicked:card.owner.saveAiRegionNote()}
        Button {objectName:"discardFailedAiRegion";text:qsTr("Discard unsaved changes…");visible:!!card.attachment.image_png && card.owner && !!card.owner.regionPersistenceError;enabled:card.owner && !card.running && !card.owner.pendingCommands;onClicked:discardChanges.open()}
        RowLayout {
            Button {objectName:"newAiRegion";text:qsTr("New area");enabled:!card.running && !card.attachment.loading;onClicked:card.app.armRegion()}
            Button {objectName:"stopAiRegion";visible:card.running && card.state.responseView==="region";text:qsTr("Stop response");onClicked:card.owner.cancelAi()}
            Button {objectName:"clearAiRegion";text:qsTr("Clear area");enabled:!card.running;onClicked:card.owner.clearAiRegion()}
        }
    }
    }
    Dialog {
        id:discardChanges;objectName:"discardAiRegionConfirmation";title:qsTr("Discard unsaved conversation changes?");modal:true
        parent:Overlay.overlay;x:(card.app.width-width)/2;y:(card.app.height-height)/2
        standardButtons:Dialog.Cancel|Dialog.Discard
        property var targetOwner:null
        property var targetContext:null
        onAboutToShow:{targetOwner=card.owner;targetContext=targetOwner ? targetOwner.regionDiscardContext() : null;}
        onDiscarded:{
            if(!targetOwner || targetOwner!==card.owner || targetOwner!==card.app.currentReader || !targetOwner.discardAiRegionChanges(targetContext || {}))
                card.app.operationStatus=qsTr("The conversation changed. Review the latest changes before discarding them.");
        }
        onClosed:{targetOwner=null;targetContext=null;}
        Label {text:qsTr("The latest unsaved capture, question and answer will be discarded. Previously saved Reading notes and the PDF remain unchanged.");width:Math.min(360,card.app.width-64);wrapMode:Text.Wrap}
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

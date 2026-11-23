import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

Item {
    id:card
    objectName:"aiRegionCard"
    required property var app
    readonly property bool parchment:app.regionConversationStyle!=="window"
    readonly property color dividerColor:parchment ? Qt.rgba(app.colors.accentBorder.r,app.colors.accentBorder.g,app.colors.accentBorder.b,.18) : app.colors.separator
    property var owner:null
    readonly property var attachment:owner ? owner.aiRegion : ({})
    readonly property var state:owner ? owner.aiState : ({})
    readonly property bool running:!!state.running
    readonly property bool notePreview:state.previewView==="region_note"
    readonly property bool noteRunning:running && state.responseView==="region_note"
    readonly property var candidate:state.regionNoteCandidate && state.regionNoteCandidate.id===attachment.history_id
        ? state.regionNoteCandidate : null
    readonly property var knowledgeResult:({
        output:candidate ? candidate.content : noteRunning ? state.output || "" : attachment.knowledge_note || "",
        reasoning:noteRunning ? state.reasoning : "",generation:owner ? owner.documentGeneration : 0
    })
    readonly property var plan:state.previewView==="region" || notePreview ? state.plan || null : null
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
    readonly property real heightLimit:Math.max(44,Math.min(740,(app.documentCanvas ? app.documentCanvas.height : app.height)-24))
    readonly property real fullHeight:Math.min(heightLimit,Math.max(44,
        Math.ceil(body.implicitHeight + Math.max(0,transcript.implicitHeight-resultScroll.Layout.preferredHeight))))
    readonly property bool streamGrowing:opened && running && (state.responseView==="region" || noteRunning)
    readonly property real plannedHeight:streamGrowing ? heightLimit : fullHeight
    readonly property real allocatedHeight:located && paper.card ? paper.card.gap_pt*app.zoom : fullHeight
    readonly property real paperProgress:allocatedHeight>0
        ? revealProgress*Math.min(1,fullHeight/allocatedHeight) : 0
    readonly property bool compact:heightLimit<400
    readonly property bool veryCompact:heightLimit<280
    property int streamInteraction:-1
    property size streamViewport:Qt.size(0,0)
    property real streamZoom:0
    readonly property bool streamKeepsDemand:streamGrowing && app.documentCanvas
        && streamInteraction===app.documentCanvas.interactionEpoch && streamZoom===app.zoom
        && streamViewport.width===app.documentCanvas.width && streamViewport.height===app.documentCanvas.height
    onStreamGrowingChanged:if(streamGrowing && app.documentCanvas) {
        streamInteraction=app.documentCanvas.interactionEpoch;
        streamZoom=app.zoom;
        streamViewport=Qt.size(app.documentCanvas.width,app.documentCanvas.height);
    }
    property real revealProgress:1
    property bool closing:false
    readonly property bool motionActive:opened && (needsReveal || reveal.running || closing)
    readonly property bool canAnimate:!app.reduceMotion && app.visible
    onCanAnimateChanged:if(!canAnimate && motionActive)completeMotion(app.visible)
    property var motionAnchor:null
    property real motionGapBottom:NaN
    property int motionInteraction:-1
    height:Math.min(fullHeight,allocatedHeight)*revealProgress
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
        // While streaming, one maximum-gap plan covers every measured transcript size.
        // Canvas interpolates that existing endpoint; no per-token document plan is needed.
        owner.configureAiRegionPaper(config.mode,config.gap,plannedHeight/app.zoom);
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
    onPlannedHeightChanged:requestPaper()
    onFullHeightChanged:if(streamKeepsDemand)Qt.callLater(card.followGrowth)
    function followGrowth() {
        if(!streamKeepsDemand || owner!==app.currentReader || !located || !focusedWithin())return;
        const visibleFrame=app.documentCanvas.regionCardFrame(owner);
        if(visibleFrame && visibleFrame.y<app.documentCanvas.height && visibleFrame.y+height>0)
            app.documentCanvas.showRegionCard(owner);
    }
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
    function revealAuxiliaryFocus() {
        const item=app.activeFocusItem;
        if(!opened || !item || owner!==app.currentReader)return;
        let ancestor=item;
        while(ancestor && ancestor!==details)ancestor=ancestor.parent;
        if(!ancestor)return;
        const target=resultScroll.contentItem;
        if(!target || typeof target.contentY!=="number" || !target.contentItem)return;
        const rect=item.mapToItem(target.contentItem,0,0,item.width,item.height);
        let next=target.contentY;
        if(rect.y<next)next=rect.y;
        else if(rect.y+rect.height>next+target.height)next=rect.y+rect.height-target.height;
        target.contentY=Math.max(0,Math.min(Math.max(0,target.contentHeight-target.height),next));
    }
    Connections {
        target:card.app
        function onActiveFocusItemChanged(){Qt.callLater(card.revealAuxiliaryFocus);}
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
        id:body
        objectName:"aiRegionBody"
        width:card.width;height:card.fullHeight;padding:card.veryCompact ? 4 : card.compact ? 8 : 12
        opacity:.65+.35*card.revealProgress
        enabled:!card.closing
        background:Rectangle {
            objectName:"aiRegionCardSurface"
            color:card.parchment ? card.app.colors.panelBg : card.app.colors.raisedBg
            border.color:card.parchment ? card.dividerColor : card.app.colors.border
            radius:card.parchment ? 5 : 10
        }
    contentItem:ColumnLayout {
        spacing:card.veryCompact ? 1 : card.compact ? 4 : 8
        RowLayout {
            Label {text:qsTr("Ask about this area");font.bold:true;Layout.fillWidth:true}
            ToolButton {objectName:"closeAiRegionCard";text:qsTr("Close");onClicked:card.closeAnimated()}
        }
        Rectangle {Layout.fillWidth:true;Layout.preferredHeight:1;color:card.dividerColor}
        BusyIndicator {running:!!card.attachment.loading;visible:running;Layout.alignment:Qt.AlignHCenter}
        AiReadingScrollView {
            id: resultScroll;objectName:"aiRegionTranscript"
            Layout.minimumHeight:card.veryCompact ? 48 : 64
            Layout.preferredHeight:64
            Layout.fillWidth:true;Layout.fillHeight:true;contentWidth:availableWidth;clip:true
            ColumnLayout {
                id:transcript
                objectName:"aiRegionTranscriptContent"
                width:resultScroll.availableWidth;spacing:8
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
                Label {
                    visible:!!card.knowledgeResult.output
                    text:card.candidate ? qsTr("Generated knowledge note · unsaved") : qsTr("Knowledge note")
                    font.bold:true;Layout.fillWidth:true;wrapMode:Text.Wrap
                }
                AiResult {
                    app:card.app;viewport:resultScroll.contentItem;value:card.knowledgeResult
                    answerName:"aiRegionKnowledge";Layout.fillWidth:true;visible:!!card.knowledgeResult.output
                }
                ColumnLayout {
                    id:details;objectName:"aiRegionDetails";Layout.fillWidth:true
                    spacing:card.compact ? 4 : 8
                    Label {visible:!!card.attachment.restored;text:qsTr("Saved conversation · %1 completed turns. Preview includes the recent context.").arg(card.attachment.completed_turn_count || 0);wrapMode:Text.Wrap;Layout.fillWidth:true;color:card.app.colors.textSecondary}
                    RowLayout {
                        visible:card.owner && !!card.owner.documentReading.choice_pending
                        Layout.fillWidth:true
                        Button {text:qsTr("Read document (optional)…");Layout.fillWidth:true;onClicked:card.app.openDocumentReading()}
                        ToolButton {text:qsTr("Skip");Accessible.name:qsTr("Continue without document reading");onClicked:card.owner.dismissDocumentReadingChoice()}
                    }
                    Button {objectName:"saveAiRegionNote";text:qsTr("Save to Reading notes");enabled:!!card.attachment.image_png && !card.running && card.owner && !card.owner.pendingCommands;onClicked:card.owner.saveAiRegionNote()}
                    Button {
                        objectName:"prepareAiRegionKnowledge"
                        text:qsTr("Preview knowledge note")
                        visible:!!card.attachment.completed_turn_count && !card.candidate
                        enabled:!!card.owner && card.attachment.saved && !card.running && !card.owner.pendingCommands && !card.owner.hasUnsavedReadingNotes
                        onClicked:card.owner.prepareAiRegion(card.app.aiSettings,true)
                    }
                    RowLayout {
                        visible:!!card.candidate;Layout.fillWidth:true
                        Button {
                            objectName:"saveAiRegionKnowledge"
                            text:qsTr("Save generated note")
                            enabled:!!card.owner && !card.running && !card.owner.pendingCommands && !card.owner.hasUnsavedReadingNotes
                            onClicked:card.owner.saveGeneratedRegionNote()
                        }
                        Button {text:qsTr("Dismiss");enabled:!!card.owner && !card.owner.pendingCommands;onClicked:card.owner.dismissGeneratedRegionNote()}
                    }
                    Button {objectName:"discardFailedAiRegion";text:qsTr("Discard unsaved changes…");visible:!!card.attachment.image_png && card.owner && !!card.owner.regionPersistenceError;enabled:card.owner && !card.running && !card.owner.pendingCommands;onClicked:discardChanges.open()}
                    RowLayout {
                        Button {objectName:"newAiRegion";text:qsTr("New area");enabled:!card.running && !card.attachment.loading;onClicked:card.app.armRegion()}
                        Button {objectName:"clearAiRegion";text:qsTr("Clear area");enabled:!card.running;onClicked:card.owner.clearAiRegion()}
                    }
                }
            }
        }
        Rectangle {Layout.fillWidth:true;Layout.preferredHeight:1;color:card.dividerColor}
        ScrollView {
            id:composer
            visible:!!card.attachment.image_png
            Layout.fillWidth:true;Layout.preferredHeight:Math.min(80,Math.max(card.veryCompact ? 36 : 48,card.heightLimit*.18));Layout.maximumHeight:Layout.preferredHeight;contentWidth:availableWidth;clip:true
            TextArea {
                id:questionEditor;objectName:"aiRegionQuestion"
                width:composer.availableWidth;text:card.attachment.question || ""
                readOnly:card.running
                wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText
                placeholderText:qsTr("Question about this area…");Accessible.name:qsTr("Question about area")
                color:card.app.colors.textPrimary;placeholderTextColor:card.app.colors.textPlaceholder
                selectionColor:card.app.colors.textSelectionBg;selectedTextColor:card.app.colors.textSelectionFg
                padding:9
                background:Rectangle {
                    objectName:"aiRegionQuestionSurface"
                    color:card.parchment ? Qt.rgba(card.app.colors.raisedBg.r,card.app.colors.raisedBg.g,card.app.colors.raisedBg.b,.45) : card.app.colors.fieldBg
                    radius:card.parchment ? 3 : 7
                    border.width:card.parchment ? 0 : 1
                    border.color:questionEditor.activeFocus ? card.app.colors.focusRing : card.app.colors.controlBorder
                    Rectangle {
                        visible:card.parchment;anchors.left:parent.left;anchors.right:parent.right;anchors.bottom:parent.bottom
                        height:questionEditor.activeFocus ? 1.5 : .7
                        color:questionEditor.activeFocus ? card.app.colors.focusRing : card.app.colors.controlBorder
                    }
                }
                onTextChanged:if(activeFocus && card.owner)card.owner.setAiRegionQuestion(text)
            }
        }
        Label {
            objectName:"aiRegionRequestStatus"
            text:card.running && card.state.responseView!=="region" && !card.noteRunning ? qsTr("Another assistant request is running in this tab.")
                : card.state.statusView==="region" || card.state.statusView==="region_note" ? card.state.status || "" : ""
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
            Button {
                objectName:"sendAiRegion"
                text:card.notePreview ? card.plan && card.plan.consolidation ? qsTr("Send note synthesis") : qsTr("Send note request") : qsTr("Send")
                visible:!card.running || (card.state.responseView!=="region" && !card.noteRunning)
                enabled:card.previewReady && !card.running && card.owner && card.owner.pendingCommands===0
                onClicked:card.app.sendAi(card.owner,card.plan)
            }
            Button {objectName:"stopAiRegion";visible:card.running && (card.state.responseView==="region" || card.noteRunning);text:qsTr("Stop response");onClicked:card.owner.cancelAi()}
        }
        Label {
            objectName:"aiRegionPersistenceStatus"
            Layout.fillWidth:true;wrapMode:Text.Wrap;font.pixelSize:11;color:card.app.colors.textSecondary
            text:card.attachment.saved ? qsTr("Saved in Reading notes on this device.") : card.owner && card.owner.regionPersistenceError ? qsTr("This conversation has not been saved. Retry saving to keep the latest changes.") : qsTr("Saving this area and its conversation to Reading notes on this device…")
        }
        Label {text:card.owner ? card.owner.regionHistory.error || "" : "";visible:text.length>0;wrapMode:Text.Wrap;Layout.fillWidth:true;color:card.app.colors.warningFg;textFormat:Text.PlainText}
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

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
    property bool showingNote: false
    property var owner:null
    readonly property var attachment:owner ? owner.aiRegion : ({})
    readonly property var state:owner ? owner.aiState : ({})
    readonly property var chatGptAccounts:app.session ? app.session.chatGptAccounts : null
    readonly property bool chatGptAvailable:!!chatGptAccounts && chatGptAccounts.connected && !!chatGptAccounts.model
    readonly property bool running:!!state.running
    readonly property bool regionRunning:running && (state.responseView==="region" || noteRunning)
    readonly property bool hasNote:!!knowledgeResult.output || noteRunning
    readonly property var savedRegion:owner ? (owner.regionHistory.entries || []).find(entry=>entry.id===attachment.history_id) : null
    readonly property string captureLabel:qsTr("Page %1 · Region %2").arg((attachment.page || 0)+1).arg(savedRegion ? savedRegion.number || 1 : 1)
    readonly property bool canPrepare:!!attachment.image_png && !!(attachment.question || "").trim()
        && !running && !!owner && owner.pendingCommands===0
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
    readonly property bool activeTurn: running && state.responseView==="region"
    readonly property var result:activeTurn ? ({
        question:state.activeQuestion,output:state.output,reasoning:state.reasoning,
        responsePlan:state.responsePlan,generation:owner.documentGeneration
    }) : ((state.results || {}).region || {})
    readonly property var previousTurns:owner ? owner.aiRegionPreviousTurns : []
    readonly property bool hasConversation:!!result.question || previousTurns.length>0
    property int shownPreviousTurns:8
    property bool followTail:true
    onActiveTurnChanged:if(activeTurn){followTail=true;followTranscript();}
    function followTranscript() {
        if(!opened || !followTail || showingNote)return;
        Qt.callLater(function() {
            if(card.opened && card.followTail && !card.showingNote)
                resultScroll.contentItem.contentY=Math.max(0,resultScroll.contentItem.contentHeight-resultScroll.contentItem.height);
        });
    }
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
    readonly property real viewportHeight:app.documentCanvas ? app.documentCanvas.height : app.height
    readonly property real heightLimit:Math.max(44,Math.min(420,viewportHeight-24,Math.max(240,viewportHeight*.55)))
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
        payload.close();capturePreview.close();actions.close();reveal.to=0;reveal.start();
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
        if(!wasOpened)showingNote=!!owner.aiRegion.knowledge_note;
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
        opened=false;needsReveal=false;closing=false;reveal.stop();layoutSettle.stop();layoutApply.stop();payload.close();discardChanges.close();capturePreview.close();actions.close();
        shownPreviousTurns=8;followTail=true;
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
    function prepare(){if(owner===app.currentReader){showingNote=false;owner.prepareAiRegion(app.aiSettings);}}
    function submitQuestion() {
        if (previewReady && !running && owner && !owner.pendingCommands)
            app.sendAi(owner,plan);
        else if (canPrepare)
            prepare();
    }
    function prepareWithChatGpt() {
        if (owner!==app.currentReader || !chatGptAvailable || chatGptAccounts.busy) return;
        owner.prepareAiRegion({baseUrl:"https://api.openai.com/v1", model:chatGptAccounts.model,
            imageInput:true, chatgptAccount:chatGptAccounts.accountId});
    }
    function follow(link,plan) {
        if(owner!==app.currentReader || plan.generation!==owner.documentGeneration)return;
        const match=/^p\.(\d+)$/.exec(link);
        if(match && (plan.source_pages || []).indexOf(Number(match[1]))>=0){app.navigate(Number(match[1])-1);close();}
    }
    component Exchange: ColumnLayout {
        id:exchange
        required property var turn
        required property string answerName
        property bool live: false
        spacing:9
        TextMetrics {
            id: questionMetrics
            font: questionBubble.font
            text: questionBubble.text
        }
        TextArea {
            id: questionBubble
            objectName:exchange.answerName+"Question"
            Layout.alignment:Qt.AlignRight
            Layout.preferredWidth:Math.min(exchange.width*.82,
                Math.ceil(questionMetrics.advanceWidth)+leftPadding+rightPadding)
            visible:!!exchange.turn.question
            text:exchange.turn.question || ""
            textFormat:TextEdit.PlainText;wrapMode:TextEdit.Wrap
            readOnly:true;selectByMouse:true;selectByKeyboard:true
            font.pixelSize:13
            leftPadding:10;rightPadding:10;topPadding:7;bottomPadding:7
            color:card.app.colors.textPrimary
            Accessible.name:qsTr("Question")
            background:Rectangle {
                radius:4;color:Qt.alpha(card.app.colors.accentSoft,.65)
                Rectangle {width:2;height:parent.height;color:Qt.alpha(card.app.colors.accentBorder,.45)}
            }
        }
        AiResult {
            app:card.app;viewport:resultScroll.contentItem;value:exchange.turn
            answerName:exchange.answerName;inlineConversation:true
            Layout.fillWidth:true;visible:!!exchange.turn.output
            onKeyboardNavigation:function(key) {if(key===Qt.Key_Up || key===Qt.Key_PageUp || key===Qt.Key_Home)card.followTail=false;}
            onCitation:function(link,plan){card.follow(link,plan);}
        }
        Label {
            visible:text.length>0
            Layout.fillWidth:true;textFormat:Text.PlainText;wrapMode:Text.Wrap
            text:exchange.turn.state==="cancelled" ? qsTr("Stopped · partial answer kept")
                : exchange.turn.state==="failed" ? exchange.turn.status || qsTr("Request failed")
                : exchange.live && card.activeTurn && !exchange.turn.output ? qsTr("Thinking…") : ""
            font.pixelSize:11;color:exchange.turn.state==="failed" ? card.app.colors.errorFg : card.app.colors.textSecondary
        }
    }
    Pane {
        id:body
        objectName:"aiRegionBody"
        width:card.width;height:card.fullHeight
        padding:card.width<400 ? 8 : 18
        topPadding:14;bottomPadding:16
        opacity:.65+.35*card.revealProgress
        enabled:!card.closing
        background:Item {
            RegionPaperSurface {
                anchors.fill:parent;anchors.topMargin:8;anchors.bottomMargin:8
                objectName:"aiRegionCardSurface"
                colors:card.app.colors
                parchment:card.parchment
            }
        }
    contentItem:ColumnLayout {
        spacing:card.veryCompact ? 1 : card.compact ? 4 : 8
        RowLayout {
            spacing:7
            LyraToolButton {
                Layout.preferredWidth:21;Layout.preferredHeight:21
                enabled:false;padding:0;background:null
                icon.source:"qrc:/icons/lyra-quill.svg"
                icon.width:21;icon.height:21;icon.color:card.app.colors.accent
                Accessible.ignored:true
            }
            LyraToolButton {
                id: captureButton
                objectName:"viewAiRegionCapture"
                text:card.attachment.image_png ? card.captureLabel+" ⌄" : qsTr("Region question")
                display:AbstractButton.TextOnly
                font.bold:true;font.pixelSize:13
                enabled:!!card.attachment.image_png
                Accessible.name:qsTr("View selected region · %1").arg(card.captureLabel)
                onClicked:capturePreview.open()
            }
            Label {
                Layout.fillWidth:true
                text:card.showingNote ? qsTr("Reading note") : card.regionRunning ? qsTr("Responding…") : ""
                elide:Text.ElideRight;font.pixelSize:12;color:card.app.colors.textSecondary
            }
            LyraToolButton {
                objectName:"aiRegionActions";symbol:"more";text:qsTr("Conversation actions")
                onClicked:actions.popup(0,height)
                Menu {
                    id: actions
                    objectName:"aiRegionActionMenu"
                    MenuItem {text:card.showingNote ? qsTr("Show Conversation") : qsTr("Show Reading Note");enabled:card.hasNote;onTriggered:card.showingNote=!card.showingNote}
                    MenuItem {
                        objectName:"prepareAiRegionKnowledge"
                        text:qsTr("Finish & Make Note…")
                        enabled:!!card.attachment.completed_turn_count && !card.candidate && !!card.owner && !!card.attachment.saved && !card.running && !card.owner.pendingCommands && !card.owner.hasUnsavedReadingNotes
                        onTriggered:{card.showingNote=true;card.owner.prepareAiRegion(card.app.aiSettings,true);}
                    }
                    MenuItem {objectName:"saveAiRegionNote";text:qsTr("Save to Reading Notes");enabled:!!card.attachment.image_png && !card.running && card.owner && !card.owner.pendingCommands;onTriggered:card.owner.saveAiRegionNote()}
                    MenuItem {text:qsTr("Request Details");enabled:card.previewReady;onTriggered:payload.open()}
                    MenuItem {objectName:"prepareAiRegionWithChatGpt";text:qsTr("Preview with ChatGPT plan");visible:card.chatGptAvailable;height:visible ? implicitHeight : 0;enabled:card.canPrepare && !card.chatGptAccounts.busy;onTriggered:card.prepareWithChatGpt()}
                    MenuItem {text:qsTr("All Reading Notes");onTriggered:card.app.openReadingNotes()}
                    MenuItem {text:qsTr("Open in AI Panel");enabled:!!card.attachment.saved && !!card.attachment.history_id;onTriggered:card.app.openSavedReadingNote(card.attachment.history_id)}
                    MenuItem {text:qsTr("Read document (optional)…");enabled:!!card.owner && !!card.owner.documentReading.choice_pending;onTriggered:card.app.openDocumentReading()}
                    MenuSeparator {}
                    MenuItem {text:qsTr("New area");enabled:!card.running && !card.attachment.loading;onTriggered:card.app.armRegion()}
                    MenuItem {text:qsTr("Clear area");enabled:!card.running && !!card.owner;onTriggered:card.owner.clearAiRegion()}
                }
            }
            LyraToolButton {
                objectName:"closeAiRegionCard"
                display:AbstractButton.TextOnly
                text:"⌃"
                Accessible.name:qsTr("Collapse and keep conversation")
                ToolTip.text:Accessible.name
                onClicked:card.closeAnimated()
            }
        }
        Rectangle {Layout.fillWidth:true;Layout.preferredHeight:1;color:card.dividerColor}
        BusyIndicator {running:!!card.attachment.loading;visible:running;Layout.alignment:Qt.AlignHCenter}
        AiReadingScrollView {
            id: resultScroll;objectName:"aiRegionTranscript"
            Layout.minimumHeight:card.veryCompact ? 48 : 64
            Layout.preferredHeight:64
            Layout.fillWidth:true;Layout.fillHeight:true;contentWidth:availableWidth;clip:true
            contentHeight:transcript.implicitHeight
            onScrollIntent:function(dx,dy) {if(dy>0)card.followTail=false;}
            onVerticalBarPressedChanged: if(verticalBarPressed)card.followTail=false;
            Connections {
                target:resultScroll.contentItem
                function onMovementStarted(){card.followTail=false;}
                function onContentYChanged(){if(resultScroll.contentItem.atYEnd)card.followTail=true;}
                function onContentHeightChanged(){card.followTranscript();}
            }
            ColumnLayout {
                id:transcript
                objectName:"aiRegionTranscriptContent"
                width:resultScroll.availableWidth;spacing:12
                Label {text:card.attachment.error || card.paper.error || "";textFormat:Text.PlainText;visible:text.length>0;wrapMode:Text.Wrap;Layout.fillWidth:true;color:card.app.colors.warningFg}
                Button {
                    text:qsTr("Show earlier messages")
                    visible:!card.showingNote && card.previousTurns.length>card.shownPreviousTurns
                    onClicked:{card.followTail=false;card.shownPreviousTurns+=8;}
                }
                Repeater {
                    model:card.previousTurns.slice(-card.shownPreviousTurns)
                    Exchange {
                        required property var modelData
                        required property int index
                        turn:modelData;answerName:"aiRegionEarlierAnswer"+index
                        visible:!card.showingNote;Layout.fillWidth:true
                    }
                }
                Exchange {turn:card.result;answerName:"aiRegionAnswer";live:true;visible:!card.showingNote && card.hasConversation;Layout.fillWidth:true}
                Label {
                    visible:card.showingNote && !!card.candidate
                    text:qsTr("Generated knowledge note · unsaved")
                    font.bold:true;Layout.fillWidth:true;wrapMode:Text.Wrap
                }
                AiResult {
                    app:card.app;viewport:resultScroll.contentItem;value:card.knowledgeResult
                    answerName:"aiRegionKnowledge";Layout.fillWidth:true;visible:card.showingNote && card.hasNote
                }
                ColumnLayout {
                    id:details;objectName:"aiRegionDetails";Layout.fillWidth:true
                    spacing:card.compact ? 4 : 8
                    RowLayout {
                        visible:!card.hasConversation && card.owner && !!card.owner.documentReading.choice_pending
                        Layout.fillWidth:true
                        Button {text:qsTr("Read document (optional)…");Layout.fillWidth:true;onClicked:card.app.openDocumentReading()}
                        ToolButton {text:qsTr("Skip");Accessible.name:qsTr("Continue without document reading");onClicked:card.owner.dismissDocumentReadingChoice()}
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
                }
            }
        }
        Rectangle {Layout.fillWidth:true;Layout.preferredHeight:1;color:card.dividerColor}
        RowLayout {
            Layout.fillWidth:true
            visible:!!card.attachment.image_png
            spacing:6
        ScrollView {
            id:composer
            visible:!!card.attachment.image_png
            Layout.fillWidth:true;Layout.preferredHeight:Math.min(66,Math.max(34,questionEditor.implicitHeight));Layout.maximumHeight:Layout.preferredHeight;contentWidth:availableWidth;clip:true
            TextArea {
                id:questionEditor;objectName:"aiRegionQuestion"
                width:composer.availableWidth;text:card.attachment.question || ""
                readOnly:card.running
                wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText
                placeholderText:card.attachment.completed_turn_count || card.result.state==="finished"
                    ? qsTr("Ask a follow-up…") : qsTr("Ask about this region…")
                Accessible.name:qsTr("Question about area")
                color:card.app.colors.textPrimary;placeholderTextColor:card.app.colors.textPlaceholder
                selectionColor:card.app.colors.textSelectionBg;selectedTextColor:card.app.colors.textSelectionFg
                font.pixelSize:13;padding:8
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
                Keys.onReturnPressed:function(event) {
                    if(event.modifiers & Qt.ControlModifier){card.submitQuestion();event.accepted=true;}
                    else event.accepted=false;
                }
            }
        }
            LyraToolButton {
                objectName:"prepareAiRegion";symbol:"arrow";text:qsTr("Preview Question")
                visible:!card.previewReady && !card.regionRunning;enabled:card.canPrepare
                contentItem.rotation:-45
                background:Rectangle {
                    radius:7;color:parent.hovered && parent.enabled ? card.app.colors.hoverBg : "transparent"
                    border.width:parent.visualFocus ? 2 : 1
                    border.color:parent.visualFocus ? card.app.colors.focusRing : card.app.colors.controlBorder
                }
                onClicked:card.prepare()
            }
            LyraToolButton {
                objectName:"inspectAiRegion";symbol:"info";text:qsTr("Inspect payload")
                visible:card.previewReady && !card.regionRunning
                onClicked:payload.open()
            }
            LyraToolButton {
                objectName:"sendAiRegion";symbol:"arrow"
                text:card.notePreview ? card.plan && card.plan.consolidation ? qsTr("Send note synthesis") : qsTr("Send note request") : qsTr("Send")
                visible:card.previewReady && !card.regionRunning
                enabled:card.previewReady && !card.running && card.owner && card.owner.pendingCommands===0
                icon.color:enabled ? card.app.colors.accentFg : card.app.colors.textDisabled
                contentItem.rotation:-45
                background:Rectangle {
                    radius:7
                    color:parent.enabled ? (parent.down ? card.app.colors.accentPressed : card.app.colors.accent) : card.app.colors.panelBg
                    border.width:parent.visualFocus ? 2 : 0
                    border.color:card.app.colors.focusRing
                }
                onClicked:card.submitQuestion()
            }
            LyraToolButton {
                objectName:"stopAiRegion";symbol:"square";text:qsTr("Stop response")
                visible:card.regionRunning;onClicked:card.owner.cancelAi()
            }
        }
        Label {
            objectName:"aiRegionRequestStatus"
            text:card.running && card.state.responseView!=="region" && !card.noteRunning ? qsTr("Another assistant request is running in this tab.")
                : card.state.statusView==="region" || card.state.statusView==="region_note" ? card.state.status || "" : ""
            textFormat:Text.PlainText
            visible:text.length>0 && (card.running || card.previewReady || !card.result.output)
            wrapMode:Text.Wrap;Layout.fillWidth:true;font.pixelSize:11;color:card.app.colors.textSecondary
        }
        Label {
            visible:card.previewReady;Layout.fillWidth:true;wrapMode:Text.Wrap
            text:card.plan ? (card.plan.chatgpt_account
                ? qsTr("ChatGPT plan: %1 (%2)").arg(card.plan.model).arg(card.plan.host)
                : qsTr("Destination: %1").arg(card.plan.host)) + qsTr(" · %1 request(s). Nothing is sent before Send.").arg(card.plan.parts.length) : ""
            color:card.app.colors.infoFg;font.pixelSize:11
        }
        Label {
            objectName:"aiRegionPersistenceStatus"
            Layout.fillWidth:true;wrapMode:Text.Wrap;font.pixelSize:11;color:card.app.colors.textSecondary
            visible:!!card.owner && !!card.owner.regionPersistenceError
            text:card.attachment.saved ? qsTr("Saved in Reading notes on this device.") : card.owner && card.owner.regionPersistenceError ? qsTr("This conversation has not been saved. Retry saving to keep the latest changes.") : qsTr("Saving this area and its conversation to Reading notes on this device…")
        }
        Label {text:card.owner ? card.owner.regionHistory.error || "" : "";visible:text.length>0;wrapMode:Text.Wrap;Layout.fillWidth:true;color:card.app.colors.warningFg;textFormat:Text.PlainText}
    }
    }
    Popup {
        id:capturePreview
        objectName:"aiRegionCapturePreview"
        parent:Overlay.overlay
        readonly property point anchor:captureButton.mapToItem(parent,0,captureButton.height+4)
        width:Math.min(380,card.app.width-24)
        height:Math.min(330,card.app.height-24)
        x:Math.max(12,Math.min(anchor.x,card.app.width-width-12))
        y:Math.max(12,Math.min(anchor.y,card.app.height-height-12))
        focus:true
        padding:12
        closePolicy:Popup.CloseOnEscape|Popup.CloseOnPressOutside
        background:Rectangle {color:card.app.colors.raisedBg;radius:7;border.color:card.app.colors.border}
        contentItem:ScrollView {
            id:captureScroll
            objectName:"aiRegionCaptureScroll"
            clip:true;contentWidth:availableWidth
            ColumnLayout {
                width:captureScroll.availableWidth;spacing:8
                Item {
                    visible:!!card.attachment.image_png
                    Layout.fillWidth:true;Layout.preferredHeight:Math.min(180,captureScroll.availableWidth*(card.attachment.image_height_px || 1)/(card.attachment.image_width_px || 1))
                    PdfCrop {
                        objectName:"aiRegionImage"
                        anchors.horizontalCenter:parent.horizontalCenter
                        anchors.top:parent.top
                        // Fit the painted crop without feeding the viewport size back into paper height.
                        readonly property real heightBudget:Math.min(parent.height,Math.max(32,captureScroll.availableHeight-66))
                        width:Math.min(parent.width,heightBudget*(card.attachment.image_width_px || 1)/(card.attachment.image_height_px || 1))
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
                    text: {
                        if (card.plan && card.plan.chatgpt_account)
                            return qsTr("The ChatGPT plan preview includes the captured PNG.");
                        if (card.app.aiSettings.imageInput)
                            return qsTr("Image input is enabled. The captured PNG will be included.");
                        if (card.chatGptAvailable)
                            return qsTr("The API-key preview is text only. The ChatGPT plan preview includes the PNG.");
                        return qsTr("Text only. To send the captured PNG, enable region images for this model in Settings.");
                    }
                    color:card.app.colors.textSecondary;font.pixelSize:11
                }
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

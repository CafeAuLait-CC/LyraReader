import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id:reading
    objectName:"documentReadingPopup"
    required property var app
    property var owner:null
    property bool gateMode:false
    property bool automatic:false
    property bool preparePending:false
    property bool autoDispatched:false
    readonly property var state:owner ? owner.documentReading : ({})
    readonly property var plan:state.plan || null
    readonly property bool busy:["preparing","starting","reading","stopping"].indexOf(state.phase)>=0
    parent:Overlay.overlay
    x:(app.width-width)/2;y:(app.height-height)/2
    width:Math.min(480,app.width-24);height:Math.min(plan || busy || state.phase==="failed" ? 620 : 360,app.height-48)
    padding:14;modal:false;focus:true;closePolicy:Popup.CloseOnEscape
    background:Rectangle {color:reading.app.colors.panelBg;border.color:reading.app.colors.separator;radius:8}
    onAboutToShow:{owner=app.currentReader;owner.dismissDocumentReadingChoice();}
    onAboutToHide:{app.cancelAiTaskReview(owner,"document-reading");if(gateMode)app.cancelPrereadingIntent();}
    onClosed:{payload.close();if(!visible){gateMode=false;automatic=false;preparePending=false;}if(owner===app.currentReader)app.focusReadingView();}
    onOpened:Qt.callLater(continueGate)
    Connections {target:reading.app;function onCurrentReaderChanged(){if(reading.visible)reading.close();}}
    readonly property var accounts: app.session ? app.session.chatGptAccounts : null
    readonly property bool chatGptAvailable: !!accounts && accounts.connected && !!accounts.model
    function openForGate(reader,readAutomatically) {
        owner=reader;gateMode=true;automatic=readAutomatically;autoDispatched=false;
        preparePending=!state.ready && state.phase!=="failed";
        open();Qt.callLater(continueGate);
    }
    function continueGate() {
        if(!visible || !opened || !gateMode || !owner || owner!==app.currentReader)return;
        if(preparePending && !busy && !owner.pendingCommands) {preparePending=false;prepare();}
        if(automatic && !autoDispatched && state.phase==="preview" && !owner.pendingCommands) {
            autoDispatched=true;startReading();
        }
    }
    function startReading() {
        if(gateMode && !app.prereadingMayStart(owner)){app.cancelPrereadingIntent();return;}
        app.dispatchAiTaskFromUi(owner,plan,"document-reading",state.token);
    }
    function continueWithout() {
        if(gateMode && app.skipPrereadingIntent(owner))return;
        if(owner)owner.skipDocumentReading();close();
    }
    Connections {
        target:reading.owner
        function onCommandsChanged(){Qt.callLater(reading.continueGate);}
        function onDocumentReadingChanged(){Qt.callLater(reading.continueGate);}
    }
    function prepare() { prepareForConnection(!!accounts && (accounts.connectionMode==="chatGPT"
        || (gateMode && accounts.connectionMode==="legacy" && accounts.useForWholeDocument))); }
    function prepareForConnection(useChatGpt) {
        if(!app.beginAiPreparation())return;
        if(accounts && (accounts.connectionMode==="apiKey" && useChatGpt
                || accounts.connectionMode==="chatGPT" && !useChatGpt))return;
        if(useChatGpt && !chatGptAvailable) {app.operationStatus=qsTr("Sign in and choose a ChatGPT model in Settings.");return;}
        if(useChatGpt && accounts.busy) {app.operationStatus=qsTr("Wait for the ChatGPT connection operation to finish.");return;}
        if(gateMode && state.phase==="failed") {
            // Retry is a new explicit action. Reuse the portable idle-policy
            // decision rather than silently retrying when a failure arrives.
            const retry=app.session.prereadingGate(app.prereadingPolicyValue,"idle",false,"question");
            if(!retry.valid){app.operationStatus=retry.message;return;}
            automatic=retry.decision==="read";
        }
        const settings=app.aiSettings;
        const request={action:"SummarizeDocument",document_knowledge:true,document_knowledge_text:null,document_knowledge_pages:[],
            current_page:0,selection:null,question:null,language:app.defaultAiOutputLanguage || null,history:[],region:null,
            base_url:settings.baseUrl || "http://localhost:11434/v1",model:settings.model || "",
            temperature:Object.prototype.hasOwnProperty.call(settings,"temperature") ? settings.temperature : null,
            max_tokens:Object.prototype.hasOwnProperty.call(settings,"maxTokens") ? settings.maxTokens : null,
            reasoning_mode:settings.reasoningMode || "default",reasoning_encoding:settings.reasoningEncoding || "none"};
        if (useChatGpt) {
            request.chatgpt_account=accounts.accountId;
            request.model=accounts.model;
            request.temperature=null;request.max_tokens=null;
            request.reasoning_mode="default";request.reasoning_encoding="none";
        }
        autoDispatched=false;
        const revision=owner.documentReadingRevision;
        owner.prepareDocumentReading(request);
        if(gateMode && owner && owner.documentReadingRevision!==revision)app.adoptPrereadingPreview(owner);
    }
    contentItem:ColumnLayout {
        spacing:10
        RowLayout {
            Label {text:qsTr("Get to know this document");font.bold:true;wrapMode:Text.Wrap;Layout.fillWidth:true}
            ToolButton {objectName:"closeDocumentReading";text:qsTr("Close");onClicked:reading.close()}
        }
        ScrollView {
            Layout.fillWidth:true;Layout.fillHeight:true;contentWidth:availableWidth;clip:true
            ColumnLayout {
                width:parent.width;spacing:10
                Label {
                    Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText
                    text:qsTr("Lyra can read the document once and save its understanding locally. You can keep reading the PDF while it works. Other AI requests wait until prereading finishes, or you can continue without it.")
                }
                Label {
                    Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText;color:reading.app.colors.textSecondary
                    text:qsTr("Only completed reading is used by new request previews. Existing previews stay unchanged. Translation of selected text does not use this context.")
                }
                Label {
                    visible:!!reading.plan;Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText
                    text:reading.plan ? qsTr("%1 pages · %2 · %3").arg(reading.plan.page_count).arg(reading.plan.model).arg(reading.plan.host) : ""
                }
                Label {
                    visible:!!reading.plan;Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText;color:reading.app.colors.infoFg
                    text:reading.plan ? qsTr("All extracted document text is sent in %1 request(s). For multiple parts, one additional request combines the answers automatically. The PDF file is not uploaded. Review before sending follows your reading workflow settings.").arg(reading.plan.parts.length) : ""
                }
                ProgressBar {visible:reading.state.phase==="reading";Layout.fillWidth:true;from:0;to:Math.max(1,reading.state.total || 1);value:reading.state.completed || 0}
                Label {
                    objectName:"documentReadingStatus"
                    Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText;color:reading.app.colors.textSecondary
                    text:reading.state.phase==="reading" ? ((reading.state.merge_payloads || []).length ? qsTr("Connecting the ideas…") : qsTr("Reading %1 of %2 parts").arg(reading.state.completed || 0).arg(reading.state.total || 0)) : reading.state.phase==="preparing" ? qsTr("Preparing the reading preview locally…") : reading.state.message || (reading.state.ready ? qsTr("Document reading is ready. New questions can use it.") : qsTr("You can continue without reading the document."))
                    Accessible.role:Accessible.StaticText
                }
                Label {visible:!!reading.state.cache_warning;Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText;color:reading.app.colors.warningFg;text:reading.state.cache_warning || ""}
            }
        }
        Button {objectName:"previewDocumentReading";text:reading.state.phase==="failed" ? (reading.gateMode ? qsTr("Retry prereading") : qsTr("Retry: Preview Reading")) : qsTr("Preview Document Reading");Layout.fillWidth:true;visible:!reading.state.ready;enabled:reading.app.aiConnectionReady && !!reading.owner && reading.owner.pageCount>0 && !reading.owner.loading && !reading.busy && reading.owner.pendingCommands===0;onClicked:reading.prepare()}
        Button {
            objectName:"previewChatGptDocumentReading"
            text:qsTr("Preview Reading with ChatGPT plan")
            Layout.fillWidth:true
            visible:!reading.state.ready && reading.chatGptAvailable && reading.accounts.connectionMode==="legacy"
            enabled:!!reading.owner && reading.owner.pageCount>0 && !reading.owner.loading
                && !reading.busy && reading.owner.pendingCommands===0 && !!reading.accounts && !reading.accounts.busy
            onClicked:reading.prepareForConnection(true)
        }
        Button {objectName:"inspectDocumentReading";text:qsTr("Inspect Payload");Layout.fillWidth:true;visible:!!reading.plan;onClicked:payload.open()}
        Button {objectName:"startDocumentReading";text:qsTr("Read in Background");Layout.fillWidth:true;visible:reading.state.phase==="preview";enabled:!!reading.owner && !reading.owner.pendingCommands;onClicked:reading.startReading()}
        Button {objectName:"skipDocumentReading";text:qsTr("Continue Without Reading");Layout.fillWidth:true;visible:!reading.state.ready && reading.state.phase!=="reading" && reading.state.phase!=="starting";onClicked:reading.continueWithout()}
        Button {objectName:"stopDocumentReading";text:qsTr("Stop Reading");Layout.fillWidth:true;visible:reading.busy;enabled:reading.state.phase!=="stopping";onClicked:reading.owner.stopDocumentReading()}
    }
    Dialog {
        id:payload;objectName:"documentReadingPayload"
        property string body:""
        parent:Overlay.overlay;x:(reading.app.width-width)/2;y:(reading.app.height-height)/2
        width:Math.min(640,reading.app.width-32);height:Math.min(560,reading.app.height-60);modal:true;title:qsTr("Document reading payload")
        standardButtons:Dialog.Close
        onAboutToShow:body=(reading.plan ? reading.plan.parts.map(p=>p.wire_body) : []).concat(reading.state.merge_payloads || []).join("\n\n")
        onClosed:body=""
        ScrollView {anchors.fill:parent;contentWidth:availableWidth;TextArea {objectName:"documentReadingPayloadText";Accessible.name:qsTr("Document reading request body");width:parent.width;text:payload.body;readOnly:true;selectByMouse:true;selectByKeyboard:true;textFormat:TextEdit.PlainText;wrapMode:TextEdit.Wrap}}
    }
}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Popup {
    id:reading
    objectName:"documentReadingPopup"
    required property var app
    property var owner:null
    readonly property var state:owner ? owner.documentReading : ({})
    readonly property var plan:state.plan || null
    readonly property bool busy:["preparing","starting","reading","stopping"].indexOf(state.phase)>=0
    parent:Overlay.overlay
    x:(app.width-width)/2;y:(app.height-height)/2
    width:Math.min(480,app.width-24);height:Math.min(plan || busy || state.phase==="failed" ? 620 : 360,app.height-48)
    padding:14;modal:false;focus:true;closePolicy:Popup.CloseOnEscape
    background:Rectangle {color:reading.app.colors.panelBg;border.color:reading.app.colors.separator;radius:8}
    onAboutToShow:{owner=app.currentReader;owner.dismissDocumentReadingChoice();}
    onClosed:{payload.close();if(owner===app.currentReader)app.focusReadingView();}
    Connections {target:reading.app;function onCurrentReaderChanged(){if(reading.visible)reading.close();}}
    function prepare() {
        const settings=app.aiSettings;
        owner.prepareDocumentReading({action:"SummarizeDocument",document_knowledge:true,document_knowledge_text:null,document_knowledge_pages:[],
            current_page:0,selection:null,question:null,language:null,history:[],region:null,
            base_url:settings.baseUrl || "http://localhost:11434/v1",model:settings.model || "",temperature:null,max_tokens:null,
            reasoning_mode:settings.reasoningMode || "default",reasoning_encoding:settings.reasoningEncoding || "none"});
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
                    text:qsTr("Lyra can read the document once and save its understanding locally. This is optional. You can ask questions immediately while reading runs in the background.")
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
                    text:reading.plan ? qsTr("All extracted document text is sent in %1 request(s). For multiple parts, one additional request combines the answers automatically. The PDF file is not uploaded. Nothing is sent before Read in Background.").arg(reading.plan.parts.length) : ""
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
        Button {objectName:"previewDocumentReading";text:reading.state.phase==="failed" ? qsTr("Retry: Preview Reading") : qsTr("Preview Document Reading");Layout.fillWidth:true;visible:!reading.state.ready;enabled:!!reading.owner && reading.owner.pageCount>0 && !reading.owner.loading && !reading.busy && reading.owner.pendingCommands===0;onClicked:reading.prepare()}
        Button {objectName:"inspectDocumentReading";text:qsTr("Inspect Payload");Layout.fillWidth:true;visible:!!reading.plan;onClicked:payload.open()}
        Button {objectName:"startDocumentReading";text:qsTr("Read in Background");Layout.fillWidth:true;visible:reading.state.phase==="preview";enabled:!!reading.owner && !reading.owner.pendingCommands;onClicked:reading.app.sendAi(reading.owner,reading.plan,"document-reading",reading.state.token)}
        Button {objectName:"skipDocumentReading";text:qsTr("Continue Without Reading");Layout.fillWidth:true;visible:!reading.state.ready && reading.state.phase!=="reading" && reading.state.phase!=="starting";onClicked:{if(reading.owner)reading.owner.stopDocumentReading();reading.close();}}
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
        ScrollView {anchors.fill:parent;contentWidth:availableWidth;TextArea {objectName:"documentReadingPayloadText";width:parent.width;text:payload.body;readOnly:true;selectByMouse:true;textFormat:TextEdit.PlainText;wrapMode:TextEdit.Wrap}}
    }
}

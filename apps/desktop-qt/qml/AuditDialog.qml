import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

Dialog {
    id:audit
    objectName:"auditDialog"
    required property var host
    required property var colors
    property var session:null
    readonly property var rows:controller.state.records || []
    readonly property bool busy:controller.busy
    readonly property string error:controller.error
    parent:Overlay.overlay
    x:(host.width-width)/2;y:(host.height-height)/2
    width:Math.min(600,host.width-24);height:Math.min(660,host.height-32)
    title:qsTr("Local audit trail");modal:true;focus:true;standardButtons:Dialog.Close
    background:Rectangle {color:audit.colors.panelBg;border.color:audit.colors.separator;radius:8}
    AuditController {id:controller;objectName:"auditController"}
    onAboutToShow:controller.reload()
    onClosed:confirmation.close()
    function cancelTop(){if(confirmation.visible)confirmation.reject();else audit.reject();}
    function actionName(key) {
        const names={summarise:qsTr("Summary"),selection_question:qsTr("Selection question"),translation:qsTr("Translation"),document_chat:qsTr("Document chat"),region_question:qsTr("Region question"),summary_layer:qsTr("Layered summary")};
        return names[key] || qsTr("Unknown action");
    }
    function outcomeName(key){return key==="sent" ? qsTr("Completed") : key==="failed" ? qsTr("Failed") : key==="cancelled" ? qsTr("Stopped") : qsTr("Pending or interrupted");}
    function durationText(value){return value>9007199254740991 ? qsTr("About %1 ms").arg(value) : qsTr("%1 ms").arg(value);}
    function codeName(key) {
        const names={http_error:qsTr("HTTP error"),unauthorized:qsTr("Authorization"),rate_limited:qsTr("Rate limited"),offline:qsTr("Offline"),local_server:qsTr("Local server"),unreachable:qsTr("Unreachable"),timeout:qsTr("Timeout"),protocol:qsTr("Protocol"),settings:qsTr("Settings"),other:qsTr("Other")};
        return key ? names[key] || qsTr("Unknown result") : "";
    }
    contentItem:ColumnLayout {
        spacing:8
        Label {Layout.fillWidth:true;wrapMode:Text.Wrap;text:qsTr("Stored only on this device. Each entry records an audited HTTP attempt, including retries: time, action, local/remote endpoint category, result and duration.");color:audit.colors.textSecondary}
        Label {Layout.fillWidth:true;wrapMode:Text.Wrap;text:qsTr("No document text, questions, answers, filenames, paths, host/model names, image bytes or credentials are stored here. Viewing or clearing this trail sends nothing.");color:audit.colors.textSecondary}
        Label {objectName:"auditError";text:audit.error;visible:text.length>0;Layout.fillWidth:true;wrapMode:Text.Wrap;color:audit.colors.warningFg;textFormat:Text.PlainText}
        RowLayout {
            Layout.fillWidth:true
            Button {objectName:"refreshAuditTrail";text:qsTr("Refresh");enabled:!audit.busy;onClicked:controller.reload()}
            Button {objectName:"copyAuditTrail";text:qsTr("Copy metadata");enabled:!audit.busy && !audit.error && audit.rows.length>0 && !!audit.session;onClicked:audit.session.copyText(controller.metadata())}
            Button {objectName:"clearAuditTrail";text:qsTr("Clear…");enabled:!audit.busy && !audit.error && audit.rows.length>0;onClicked:confirmation.open()}
        }
        BusyIndicator {running:audit.busy;visible:running;Layout.alignment:Qt.AlignHCenter}
        Label {text:qsTr("Loaded snapshot: %1 entries").arg(audit.rows.length);Layout.fillWidth:true;wrapMode:Text.Wrap;color:audit.colors.textSecondary}
        Label {objectName:"auditEmpty";visible:!audit.busy && !audit.error && !audit.rows.length;text:qsTr("No requests recorded yet.");Layout.fillWidth:true;wrapMode:Text.Wrap}
        ListView {
            objectName:"auditRecords"
            Layout.fillWidth:true;Layout.fillHeight:true;clip:true;spacing:5;model:audit.rows
            ScrollBar.vertical:ScrollBar{}
            delegate:Item {
                required property var modelData
                width:ListView.view.width;height:entry.implicitHeight+10
                ColumnLayout {
                    id:entry;anchors.left:parent.left;anchors.right:parent.right;anchors.margins:4;spacing:3
                    Label {text:modelData.time_label+" · "+audit.actionName(modelData.action);Layout.fillWidth:true;wrapMode:Text.Wrap;font.bold:true}
                    Label {text:audit.outcomeName(modelData.outcome)+" · "+(modelData.local ? qsTr("Local endpoint") : qsTr("Remote endpoint"))+" · "+audit.durationText(modelData.duration_ms);Layout.fillWidth:true;wrapMode:Text.Wrap;color:modelData.outcome==="failed" ? audit.colors.warningFg : audit.colors.textSecondary}
                    Label {visible:!!modelData.code;text:audit.codeName(modelData.code)+(modelData.http_status ? " · "+modelData.http_status : "");Layout.fillWidth:true;wrapMode:Text.Wrap;color:audit.colors.textSecondary}
                    Label {text:qsTr("Request %1").arg(modelData.id);Layout.fillWidth:true;wrapMode:Text.Wrap;font.pixelSize:10;color:audit.colors.textSecondary}
                    Rectangle {Layout.fillWidth:true;height:1;color:audit.colors.separator}
                }
            }
        }
        Label {text:qsTr("Newest %1 entries or %2 KiB are kept; older entries are removed.").arg(controller.state.max_records || 500).arg((controller.state.max_bytes || 262144)/1024);Layout.fillWidth:true;wrapMode:Text.Wrap;color:audit.colors.textSecondary;font.pixelSize:11}
        ToolButton {id:inventory;objectName:"auditInventoryToggle";text:qsTr("What AI requests send");checkable:true}
        ScrollView {
            visible:inventory.checked;Layout.fillWidth:true;Layout.preferredHeight:120;contentWidth:availableWidth;clip:true
            Label {width:parent.width;wrapMode:Text.Wrap;color:audit.colors.textSecondary;text:qsTr("The explicit request preview shows the context, instructions, model and generation settings sent to the selected endpoint. Depending on the action, context includes selected/page text, retrieved passages or eligible prior conversation. Region images are included only when enabled for the selected model. The PDF file and embedded attachments are not uploaded. Local audit metadata is never added to a request.")}
        }
    }
    Dialog {
        id:confirmation;objectName:"clearAuditConfirmation"
        property string fingerprint:""
        property int count:0
        parent:Overlay.overlay;x:(audit.host.width-width)/2;y:(audit.host.height-height)/2
        width:Math.min(390,audit.host.width-40);title:qsTr("Clear the local audit trail?");modal:true;focus:true;closePolicy:Popup.CloseOnEscape
        implicitHeight:Math.min(260,audit.host.height-48)
        standardButtons:Dialog.Cancel|Dialog.Ok
        onAboutToShow:{fingerprint=controller.state.fingerprint || "";count=audit.rows.length;}
        onAccepted:controller.clear(fingerprint)
        onClosed:{fingerprint="";count=0;}
        contentItem:ScrollView {
            contentWidth:availableWidth;clip:true
            Text {width:parent.width;font:confirmation.font;color:audit.colors.textPrimary;textFormat:Text.PlainText;text:qsTr("Permanently remove these %1 local metadata entries? This cannot be undone. Nothing is sent anywhere. If the trail changes, refresh and review it again.").arg(confirmation.count);wrapMode:Text.Wrap}
        }
    }
}

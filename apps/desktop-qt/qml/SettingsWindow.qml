import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

ApplicationWindow {
    id: settings
    property string initialAppearance: ""
    property string initialPaper: ""
    property bool appearanceEdited: false
    property bool paperPresetEdited: false
    property string initialRegionStyle: ""
    property bool regionStyleEdited: false
    property bool initialReduceMotion: false
    property int initialGap: 0
    property var initialAiDraft: ({})
    property var initialReasoningMode: "default"
    property var initialReasoningEncoding: "none"
    readonly property var reasoningValues: ["default", "off", "low", "high", "max"]
    readonly property var encodingValues: ["none", "thinking", "reasoning_effort", "output_config", "reasoning.effort"]
    readonly property bool providerSettingsVisible:!accounts || accounts.connectionMode!=="chatGPT"
    readonly property bool reasoningEdited:(reasoning.currentIndex>=0 && reasoningValues[reasoning.currentIndex]!==initialReasoningMode)
        || (encoding.currentIndex>=0 && encodingValues[encoding.currentIndex]!==initialReasoningEncoding)
    readonly property var reasoningInspection:inspectReasoningDraft()
    readonly property bool reasoningConflict:hasReasoningConflict()
    readonly property string reasoningIssue:reasoningInspection.valid && reasoningConflict
        ? qsTr("Reasoning settings changed in another window. Cancel and reopen Settings before saving.")
        : reasoningInspection.valid ? "" : reasoningInspection.message
    readonly property bool reasoningBlocksSave:providerSettingsVisible && reasoningEdited && (!reasoningInspection.valid || reasoningConflict)
    property bool auditOnOpen: false
    objectName:"settingsWindow"
    required property var app
    readonly property var accounts: app.session ? app.session.chatGptAccounts : null
    property string connectionError: ""
    readonly property var colors:app.colors
    title:qsTr("Settings · LyraReader")
    visible:false
    flags:Qt.Dialog
    transientParent:app
    color:app.colors.windowBg
    font.pixelSize: 13
    palette:app.palette
    AuxiliaryWindowPolicy {id:policy}
    function open() {
        connectionError="";
        if(accounts && !accounts.refreshConnection())connectionError=accounts.status;
        if(visible){requestActivate();return;}
        initialAppearance=app.appearance;initialPaper=app.paperAppearance;
        appearanceEdited=false;paperPresetEdited=false;
        initialRegionStyle=app.regionConversationStyle;regionStyleEdited=false;
        regionStyle.currentIndex=app.regionConversationStyleIndex(initialRegionStyle);
        appearance.currentIndex=["light","dark","system"].indexOf(app.appearance);
        reduceMotion.checked=app.reduceMotion;
        paper.currentIndex=app.readingPresetIndex(app.paperAppearance);
        gap.value=app.pageGap;baseUrl.text=app.aiSettings.baseUrl || "http://localhost:11434/v1";
        modelName.text=app.aiSettings.model || "";
        imageInput.checked=!!app.aiSettings.imageInput;
        initialReasoningMode=Object.prototype.hasOwnProperty.call(app.aiSettings,"reasoningMode") ? app.aiSettings.reasoningMode : "default";
        initialReasoningEncoding=Object.prototype.hasOwnProperty.call(app.aiSettings,"reasoningEncoding") ? app.aiSettings.reasoningEncoding : "none";
        reasoning.currentIndex=reasoningValues.indexOf(initialReasoningMode);
        encoding.currentIndex=encodingValues.indexOf(initialReasoningEncoding);
        initialReduceMotion=reduceMotion.checked;initialGap=gap.value;initialAiDraft=aiDraft();
        apiKey.clear();
        const saved=app.session ? app.session.preference("auxiliarySettingsGeometry",{}) : ({});
        if(!policy.prepare(settings,app,saved,560,650)){auditOnOpen=false;app.operationStatus=qsTr("The Settings window could not find an available display.");return;}
        policy.present(app.auxiliaryWindowOwner);
    }
    function openAudit() {
        if(visible) {
            requestActivate();
            auditDialog.open();
        } else {
            auditOnOpen=true;
            open();
        }
    }
    onVisibleChanged: {
        if(visible && auditOnOpen) {
            auditOnOpen=false;
            auditDialog.open();
        }
    }
    function aiDraft() {
        return {baseUrl:baseUrl.text,model:modelName.text,
            reasoningMode:reasoning.currentIndex>=0 ? reasoningValues[reasoning.currentIndex] : initialReasoningMode,
            reasoningEncoding:encoding.currentIndex>=0 ? encodingValues[encoding.currentIndex] : initialReasoningEncoding,
            imageInput:imageInput.checked};
    }
    function inspectReasoningDraft() {
        if(reasoning.currentIndex<0 || encoding.currentIndex<0)
            return {valid:false,message:qsTr("The saved reasoning control is unrecognized. Choose supported values to change it.")};
        if(!app.session)return {valid:false,message:qsTr("The reasoning settings could not be inspected.")};
        return app.session.inspectReasoning(reasoningValues[reasoning.currentIndex],encodingValues[encoding.currentIndex]);
    }
    function hasReasoningConflict() {
        if(!reasoningEdited)return false;
        const saved=app.aiSettings || {};
        const currentMode=Object.prototype.hasOwnProperty.call(saved,"reasoningMode") ? saved.reasoningMode : "default";
        const currentEncoding=Object.prototype.hasOwnProperty.call(saved,"reasoningEncoding") ? saved.reasoningEncoding : "none";
        // These two fields describe one wire parameter. A newer unedited half
        // must not silently change the parameter explained by this form.
        const mode=reasoning.currentIndex>=0 ? reasoningValues[reasoning.currentIndex] : initialReasoningMode;
        const field=encoding.currentIndex>=0 ? encodingValues[encoding.currentIndex] : initialReasoningEncoding;
        return (mode===initialReasoningMode && currentMode!==initialReasoningMode)
            || (field===initialReasoningEncoding && currentEncoding!==initialReasoningEncoding);
    }
    function save() {
        if(reasoningBlocksSave)return;
        const selectedPaper=app.readingPresets[paper.currentIndex];
        const selectedAppearance=["light","dark","system"][appearance.currentIndex];
        if(selectedPaper && (paperPresetEdited || selectedPaper.id!==initialPaper)
                && !app.applyReadingPreset(selectedPaper.id))return;
        if(selectedAppearance && (appearanceEdited || selectedAppearance!==initialAppearance))
            app.appearance=selectedAppearance;
        const selectedRegionStyle=app.regionConversationStyles[regionStyle.currentIndex];
        if(selectedRegionStyle && (regionStyleEdited || selectedRegionStyle.id!==initialRegionStyle)
                && !app.applyRegionConversationStyle(selectedRegionStyle.id))return;
        if(reduceMotion.checked!==initialReduceMotion)app.reduceMotion=reduceMotion.checked;
        if(gap.value!==initialGap && gap.value!==app.pageGap) {
            app.pageGap=gap.value;
            app.setPageLayout(app.layoutMode);
        }
        const draft=aiDraft(),nextAi=Object.assign({},app.aiSettings || {});
        let aiChanged=false;
        for(const key of Object.keys(draft)) {
            if(draft[key]!==initialAiDraft[key] && draft[key]!==nextAi[key]) {
                nextAi[key]=draft[key];aiChanged=true;
            }
        }
        // An appearance-only save must retain prepared requests and unknown fields.
        // An explicit credential change still retires pending credential reads/plans.
        const providerVisible=!accounts || accounts.connectionMode!=="chatGPT";
        if(providerVisible && (aiChanged || apiKey.text.length)) {
            app.aiSettings=nextAi;
            if(app.session)app.session.setPreference("ai",app.aiSettings);
        }
        if (providerVisible && apiKey.text.length)
            app.saveAiCredential(baseUrl.text, apiKey.text);
        apiKey.clear();
        close();
    }
    Connections {
        target: settings.accounts
        function onConnectionModeChanged() {settings.connectionError="";if(settings.accounts.connectionMode==="chatGPT")apiKey.clear();}
    }
    function revealFocusedControl() {
        const item=activeFocusItem;
        Qt.callLater(function() {
            if(!settings.visible || !item || !item.visible || settings.activeFocusItem!==item)return;
            let ancestor=item;
            while(ancestor && ancestor!==settingsScroll.contentItem)ancestor=ancestor.parent;
            if(ancestor)settingsScroll.revealItem(item);
        });
    }
    onActiveFocusItemChanged:revealFocusedControl()
    onClosing: {
        policy.cancelPresentation();
        auditOnOpen=false;
        if(app.session)app.session.setPreference("auxiliarySettingsGeometry",policy.geometry());
        auditDialog.close();apiKey.clear();policy.returnFocus();
    }
    Shortcut {sequence:"Escape";onActivated:{if(auditDialog.visible)auditDialog.cancelTop();else settings.close();}}
    AuditDialog {id:auditDialog;host:settings;colors:settings.colors;session:settings.app.session}
    ColumnLayout {
        anchors.fill:parent
        anchors.margins:16
        AiReadingScrollView {
            id: settingsScroll
            objectName: "settingsScroll"
            Layout.fillWidth:true
            Layout.fillHeight:true
            contentWidth: availableWidth
            onAvailableHeightChanged:settings.revealFocusedControl()
            onAvailableWidthChanged:settings.revealFocusedControl()
            Connections {target:settingsScroll.contentItem;function onContentHeightChanged(){settings.revealFocusedControl();}}
            ColumnLayout {
                width: settingsScroll.availableWidth
                spacing: 12
                Label {
                    textFormat: Text.PlainText
                    text: qsTr("Reading")
                    font.weight: Font.DemiBold
                }
                ComboBox {
                    id: appearance
                    objectName:"settingsAppearance"
                    Layout.fillWidth: true
                    model: [qsTr("Light"), qsTr("Dark"), qsTr("Follow System")]
                    currentIndex: ["light", "dark", "system"].indexOf(app.appearance)
                    Accessible.name: qsTr("Interface appearance")
                    displayText: currentIndex<0 ? qsTr("Unrecognized saved appearance") : currentText
                    Accessible.description: displayText
                    onActivated: settings.appearanceEdited=true
                }
                CheckBox {
                    id:reduceMotion;objectName:"settingsReduceMotion"
                    text:qsTr("Reduce motion");Layout.fillWidth:true
                }
                ComboBox {
                    id: paper
                    objectName:"settingsPaper"
                    Layout.fillWidth: true
                    model: app.readingPresets
                    textRole: "title"
                    currentIndex: app.readingPresetIndex(app.paperAppearance)
                    Accessible.name: qsTr("Paper appearance preset")
                    displayText: currentIndex<0 ? qsTr("Unrecognized saved paper appearance") : currentText
                    Accessible.description: displayText
                    onActivated: function(index) {
                        settings.paperPresetEdited=true;settings.appearanceEdited=false;
                        const preset=app.readingPresets[index];
                        if(preset)appearance.currentIndex=["light","dark","system"].indexOf(preset.appearance);
                    }
                }
                Label {
                    Layout.fillWidth:true
                    wrapMode:Text.Wrap
                    text:qsTr("Presets choose a matching interface theme; you can adjust Appearance independently.")
                    color:settings.colors.textSecondary
                    font.pixelSize:11
                }
                Label {text:qsTr("Region conversations")}
                ComboBox {
                    id:regionStyle;objectName:"settingsRegionConversationStyle"
                    Layout.fillWidth:true
                    model:app.regionConversationStyles;textRole:"title"
                    currentIndex:app.regionConversationStyleIndex(app.regionConversationStyle)
                    displayText:currentIndex<0 ? qsTr("Unrecognized saved conversation style") : currentText
                    Accessible.name:qsTr("Region conversation style")
                    Accessible.description:displayText
                    onActivated:settings.regionStyleEdited=true
                }
                Label {
                    Layout.fillWidth:true;wrapMode:Text.Wrap;font.pixelSize:11;color:settings.colors.textSecondary
                    text:qsTr("Choose the look of conversations within the page. Your conversation stays the same.")
                }
                RowLayout {
                    Label {
                        textFormat: Text.PlainText
                        text: qsTr("Page gap (pt)")
                        Layout.fillWidth: true
                    }
                    SpinBox {
                        id: gap
                        objectName:"settingsPageGap"
                        Accessible.name:qsTr("Page gap in points")
                        from: 0
                        to: 100
                        value: app.pageGap
                    }
                }
                Label {
                    textFormat: Text.PlainText
                    text: qsTr("AI Assistant")
                    font.weight: Font.DemiBold
                    Layout.topMargin: 12
                }
                Button {objectName:"openAuditTrail";text:qsTr("Local audit trail…");onClicked:auditDialog.open()}
                Label {text:qsTr("Use AI with");textFormat:Text.PlainText}
                LyraReadingSegmentedPicker {
                    objectName: "settingsAiConnectionMode"
                    app: settings.app
                    Layout.fillWidth: true
                    choices: [{title:qsTr("API key")},{title:qsTr("ChatGPT plan")}]
                    currentIndex: !settings.accounts || settings.accounts.connectionMode==="apiKey" ? 0
                        : settings.accounts.connectionMode==="chatGPT" ? 1 : -1
                    activateSelected: true
                    enabled: !!settings.accounts
                    onActivated: function(index) {
                        settings.connectionError="";
                        if(!settings.accounts.selectConnectionMode(index===0?"apiKey":"chatGPT"))
                            settings.connectionError=settings.accounts.status;
                    }
                }
                Label {
                    objectName: "settingsAiConnectionNotice"
                    text: settings.connectionError || (settings.accounts ? settings.accounts.connectionModeNote : "")
                    visible: !!text
                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                    color: settings.connectionError || (settings.accounts && !settings.accounts.connectionReady)
                        ? settings.colors.errorFg : settings.colors.textSecondary
                    font.pixelSize: 11
                }
                Label {
                    text: qsTr("Connection and account choices apply immediately.")
                    textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true
                    color: settings.colors.textSecondary; font.pixelSize: 11
                }
                ColumnLayout {
                    id: providerSettings
                    objectName: "settingsApiProvider"
                    visible: !settings.accounts || settings.accounts.connectionMode!=="chatGPT"
                    Layout.fillWidth: true; spacing: 12
                    Label {text:qsTr("Provider (OpenAI-compatible)");font.weight:Font.DemiBold;textFormat:Text.PlainText}
                    TextField {
                        id: baseUrl
                        objectName:"settingsBaseUrl"
                        Layout.fillWidth: true
                        placeholderText: qsTr("Base URL, e.g. http://localhost:11434/v1")
                        text: app.aiSettings.baseUrl || "http://localhost:11434/v1"
                        Accessible.name: qsTr("AI base URL")
                    }
                    TextField {
                        id: modelName
                        objectName: "settingsAiModel"
                        Layout.fillWidth: true
                        placeholderText: qsTr("Model name")
                        text: app.aiSettings.model || ""
                        Accessible.name: qsTr("AI model")
                    }
                    CheckBox {
                        id:imageInput
                        objectName:"settingsAiImageInput"
                        text:qsTr("This model accepts region images")
                        checked:!!app.aiSettings.imageInput
                        Layout.fillWidth:true
                    }
                    Label {text:qsTr("Reasoning control");font.weight:Font.DemiBold}
                    RowLayout {
                        Layout.fillWidth:true
                        Label {text:qsTr("Reasoning");textFormat:Text.PlainText}
                        ComboBox {
                            id:reasoning
                            objectName:"settingsReasoningMode"
                            Layout.fillWidth:true;Layout.minimumWidth:0
                            model:[qsTr("Provider default (send nothing)"),qsTr("Off"),qsTr("Low effort"),qsTr("High effort"),qsTr("Max effort")]
                            currentIndex:-1
                            displayText:currentIndex<0 ? qsTr("Unrecognized saved reasoning control") : currentText
                            Accessible.name:qsTr("AI reasoning")
                            Accessible.description:displayText
                        }
                    }
                    RowLayout {
                        Layout.fillWidth:true
                        Label {text:qsTr("Encoding");textFormat:Text.PlainText}
                        ComboBox {
                            id:encoding
                            objectName:"settingsReasoningEncoding"
                            Layout.fillWidth:true;Layout.minimumWidth:0
                            model:[qsTr("None"),"thinking","reasoning_effort","output_config","reasoning.effort"]
                            currentIndex:-1
                            displayText:currentIndex<0 ? qsTr("Unrecognized saved reasoning encoding") : currentText
                            Accessible.name:qsTr("AI reasoning encoding")
                            Accessible.description:displayText+(settings.reasoningIssue.length ? ". "+settings.reasoningIssue : "")
                        }
                    }
                    Label {
                        objectName:"settingsReasoningInspection"
                        Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText
                        font.pixelSize:11
                        color:settings.reasoningIssue.length ? settings.colors.errorFg : settings.colors.textSecondary
                        text:settings.reasoningIssue.length ? settings.reasoningIssue
                            : settings.reasoningInspection.field ? qsTr("Reasoning JSON field: %1. Value: %2").arg(settings.reasoningInspection.field).arg(JSON.stringify(settings.reasoningInspection.value))
                            : qsTr("No reasoning JSON field is sent.")
                        Accessible.name:text
                    }
                    TextField {
                        id: apiKey
                        objectName:"settingsApiKey"
                        Layout.fillWidth: true
                        placeholderText: qsTr("API key — saved only in the system keychain")
                        echoMode: TextInput.Password
                        Accessible.name: qsTr("AI API key")
                    }
                    Label {
                        textFormat: Text.PlainText
                        text: qsTr("Remote requests send the previewed document text only after Send. Keys use the system keychain; no plaintext fallback.")
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                        color: app.colors.textSecondary
                        font.pixelSize: 11
                    }
                    Button {
                        text: qsTr("Remove Saved Key")
                        onClicked: app.removeAiCredential(baseUrl.text)
                    }
                }
                ColumnLayout {
                    id: chatGptSettings
                    objectName: "settingsChatGptProvider"
                    readonly property var accounts: app.session ? app.session.chatGptAccounts : null
                    readonly property var selected: accounts ?
                        accounts.accounts.find(entry => entry.id === accounts.accountId) : null
                    visible: !!accounts && accounts.connectionMode!=="apiKey"
                    Layout.topMargin: 12
                    Layout.fillWidth: true
                    Label {
                        text: qsTr("ChatGPT plan")
                        font.weight: Font.DemiBold
                        textFormat: Text.PlainText
                    }
                    ComboBox {
                        Layout.fillWidth: true
                        visible: count > 0
                        model: chatGptSettings.accounts ? chatGptSettings.accounts.accounts : []
                        textRole: "label"
                        valueRole: "id"
                        currentIndex: chatGptSettings.accounts ? indexOfValue(chatGptSettings.accounts.accountId) : -1
                        enabled: !!chatGptSettings.accounts && !chatGptSettings.accounts.busy
                        Accessible.name: qsTr("ChatGPT account")
                        onActivated: chatGptSettings.accounts.selectAccount(currentValue)
                    }
                    Label {
                        visible: text.length > 0
                        Layout.fillWidth: true
                        text: chatGptSettings.selected ? chatGptSettings.selected.email || "" : ""
                        textFormat: Text.PlainText
                        elide: Text.ElideMiddle
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Button {
                            objectName: "continueWithChatGpt"
                            text: qsTr("Continue with ChatGPT")
                            enabled: !!chatGptSettings.accounts && !chatGptSettings.accounts.busy
                            onClicked: chatGptSettings.accounts.beginSignIn(false)
                        }
                        Button {
                            text: qsTr("Add Account")
                            visible: !!chatGptSettings.selected
                            enabled: !!chatGptSettings.accounts && !chatGptSettings.accounts.busy
                            onClicked: chatGptSettings.accounts.beginSignIn(true)
                        }
                    }
                    Button {
                        text: qsTr("Cancel Sign-In")
                        visible: !!chatGptSettings.accounts && chatGptSettings.accounts.signingIn
                        onClicked: chatGptSettings.accounts.cancelSignIn()
                    }
                    ComboBox {
                        Layout.fillWidth: true
                        model: chatGptSettings.accounts ? chatGptSettings.accounts.models : []
                        textRole: "name"
                        valueRole: "id"
                        currentIndex: chatGptSettings.accounts ? indexOfValue(chatGptSettings.accounts.model) : -1
                        visible: count > 0
                        enabled: !!chatGptSettings.accounts && !chatGptSettings.accounts.busy
                        Accessible.name: qsTr("ChatGPT model")
                        onActivated: chatGptSettings.accounts.selectModel(currentValue)
                    }
                    Button {
                        objectName: "reloadChatGptModels"
                        Layout.fillWidth: true
                        text: qsTr("Reload models")
                        visible: !!chatGptSettings.accounts && chatGptSettings.accounts.connected
                        enabled: !!chatGptSettings.accounts && !chatGptSettings.accounts.busy
                        onClicked: chatGptSettings.accounts.reloadModels()
                    }
                    RowLayout {
                        Button {
                            text: qsTr("Sign Out")
                            visible: !!chatGptSettings.accounts && chatGptSettings.accounts.connected
                            enabled: !!chatGptSettings.accounts && !chatGptSettings.accounts.busy
                            onClicked: chatGptSettings.accounts.signOut()
                        }
                        Button {
                            text: qsTr("Manage Usage")
                            onClicked: Qt.openUrlExternally("https://chatgpt.com/settings/usage")
                        }
                    }
                    Label {
                        visible: text.length > 0
                        text: chatGptSettings.accounts ? chatGptSettings.accounts.status : ""
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                    }
                }
            }
        }

        DialogButtonBox {
            id:settingsButtons
            Layout.fillWidth:true
            standardButtons:DialogButtonBox.Save | DialogButtonBox.Cancel
            Component.onCompleted: {
                const saveButton=standardButton(DialogButtonBox.Save);
                if(saveButton) {
                    saveButton.enabled=Qt.binding(function(){return !settings.reasoningBlocksSave;});
                    saveButton.palette.buttonText=Qt.binding(function(){return saveButton.enabled ? settings.colors.textPrimary : settings.colors.textDisabled;});
                }
            }
            onAccepted:settings.save()
            onRejected:settings.close()
        }
    }
}

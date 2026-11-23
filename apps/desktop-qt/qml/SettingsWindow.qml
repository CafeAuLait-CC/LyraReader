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
    objectName:"settingsWindow"
    required property var app
    readonly property var colors:app.colors
    title:qsTr("Settings · LyraReader")
    visible:false
    flags:Qt.Dialog
    transientParent:app
    color:app.colors.windowBg
    palette:app.palette
    AuxiliaryWindowPolicy {id:policy}
    function open() {
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
        reasoning.currentIndex=Math.max(0,reasoning.model.indexOf(app.aiSettings.reasoningMode || "default"));
        encoding.currentIndex=Math.max(0,encoding.model.indexOf(app.aiSettings.reasoningEncoding || "none"));
        initialReduceMotion=reduceMotion.checked;initialGap=gap.value;initialAiDraft=aiDraft();
        apiKey.clear();
        const saved=app.session ? app.session.preference("auxiliarySettingsGeometry",{}) : ({});
        if(!policy.prepare(settings,app,saved,560,650)){app.operationStatus=qsTr("The Settings window could not find an available display.");return;}
        show();requestActivate();
    }
    function openAudit(){open();if(visible)auditDialog.open();}
    function aiDraft() {
        return {baseUrl:baseUrl.text,model:modelName.text,reasoningMode:reasoning.currentText,
            reasoningEncoding:encoding.currentText,imageInput:imageInput.checked};
    }
    function save() {
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
        if(aiChanged || apiKey.text.length) {
            app.aiSettings=nextAi;
            if(app.session)app.session.setPreference("ai",app.aiSettings);
        }
        if (apiKey.text.length)
            app.saveAiCredential(baseUrl.text, apiKey.text);
        apiKey.clear();
        close();
    }
    onClosing: {
        if(app.session)app.session.setPreference("auxiliarySettingsGeometry",policy.geometry());
        auditDialog.close();apiKey.clear();policy.returnFocus();
    }
    Shortcut {sequence:"Escape";onActivated:{if(auditDialog.visible)auditDialog.cancelTop();else settings.close();}}
    AuditDialog {id:auditDialog;host:settings;colors:settings.colors;session:settings.app.session}
    ColumnLayout {
        anchors.fill:parent
        anchors.margins:16
        ScrollView {
            Layout.fillWidth:true
            Layout.fillHeight:true
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
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
                    Layout.fillWidth: true
                    placeholderText: qsTr("Model name")
                    text: app.aiSettings.model || ""
                    Accessible.name: qsTr("AI model")
                }
                ComboBox {
                    id: reasoning
                    Layout.fillWidth: true
                    model: ["default", "off", "low", "high", "max"]
                    currentIndex: Math.max(0, model.indexOf(app.aiSettings.reasoningMode || "default"))
                }
                CheckBox {
                    id:imageInput
                    objectName:"settingsAiImageInput"
                    text:qsTr("This model accepts region images")
                    checked:!!app.aiSettings.imageInput
                    Layout.fillWidth:true
                }
                ComboBox {
                    id: encoding
                    Layout.fillWidth: true
                    model: ["none", "thinking", "reasoning_effort", "output_config", "reasoning.effort"]
                    currentIndex: Math.max(0, model.indexOf(app.aiSettings.reasoningEncoding || "none"))
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
                Button {objectName:"openAuditTrail";text:qsTr("Local audit trail…");onClicked:auditDialog.open()}
                Button {
                    text: qsTr("Remove Saved Key")
                    onClicked: app.removeAiCredential(baseUrl.text)
                }
                ColumnLayout {
                    id: chatGptSettings
                    readonly property var accounts: app.session ? app.session.chatGptAccounts : null
                    readonly property var selected: accounts ?
                        accounts.accounts.find(entry => entry.id === accounts.accountId) : null
                    visible: !!accounts
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
                    CheckBox {
                        Layout.fillWidth: true
                        text: qsTr("Use ChatGPT plan for document chat")
                        checked: !!chatGptSettings.accounts && chatGptSettings.accounts.useForChat
                        enabled: !!chatGptSettings.accounts && !chatGptSettings.accounts.busy &&
                            (checked || (chatGptSettings.accounts.connected && !!chatGptSettings.accounts.model))
                        onToggled: chatGptSettings.accounts.useForChat = checked
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
            Layout.fillWidth:true
            standardButtons:DialogButtonBox.Save | DialogButtonBox.Cancel
            onAccepted:settings.save()
            onRejected:settings.close()
        }
    }
}

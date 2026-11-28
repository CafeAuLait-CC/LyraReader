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
    property bool initialHasTemperature:false
    property bool initialHasMaxTokens:false
    property var initialTemperature:null
    property var initialMaxTokens:null
    property bool temperatureEdited:false
    property bool maxTokensEdited:false
    property var initialOutputLanguage:""
    property bool outputLanguageEdited:false
    property string outputLanguageSaveError:""
    property var initialReviewBeforeSending:true
    property bool reviewBeforeSendingEdited:false
    property var initialPrereadingPolicy:"ask"
    property bool prereadingPolicyEdited:false
    readonly property var prereadingPolicies:["ask","always","never"]
    function loadPrereadingDraft() {
        initialPrereadingPolicy=app.session ? app.session.aiPrereadingPolicy : "ask";
        prereadingPolicy.currentIndex=prereadingPolicies.indexOf(initialPrereadingPolicy);
    }
    readonly property bool unknownReviewBeforeSending:typeof initialReviewBeforeSending!=="boolean" && !reviewBeforeSendingEdited
    readonly property bool unknownOutputLanguage:typeof initialOutputLanguage!=="string" && !outputLanguageEdited
    readonly property var generationSeeds:app.session ? app.session.generationDefaults() : ({valid:false})
    readonly property bool generationSeedsReady:!!generationSeeds.valid && validTemperature(generationSeeds.temperature) && validMaxTokens(generationSeeds.max_tokens)
    readonly property bool unknownTemperature:initialHasTemperature && initialTemperature!==null && !validTemperature(initialTemperature) && !temperatureEdited
    readonly property bool unknownMaxTokens:initialHasMaxTokens && initialMaxTokens!==null && !validMaxTokens(initialMaxTokens) && !maxTokensEdited
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
    readonly property var connectionTest:app.session ? app.session.connectionTest : null
    readonly property var connectionTestState:connectionTest ? connectionTest.state : ({})
    component ConnectionTestButton:Button {
        id:probeButton
        required property var colors
        palette.buttonText:enabled ? colors.textPrimary : colors.textDisabled
        background:Rectangle {
            implicitWidth:80;implicitHeight:26;radius:4
            color:!probeButton.enabled ? probeButton.colors.fieldBg : probeButton.down ? probeButton.colors.pressedBg
                : probeButton.hovered ? probeButton.colors.hoverBg : probeButton.colors.fieldBg
            border.width:probeButton.visualFocus ? 2 : 1
            border.color:!probeButton.enabled ? probeButton.colors.textDisabled
                : probeButton.visualFocus ? probeButton.colors.focusRing : probeButton.colors.controlBorder
        }
    }
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
        if(connectionTest)connectionTest.cancel();
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
        loadGenerationDraft();
        initialReduceMotion=reduceMotion.checked;initialGap=gap.value;initialAiDraft=aiDraft();
        initialOutputLanguage=app.session ? app.session.aiOutputLanguage : "";
        outputLanguage.text=typeof initialOutputLanguage==="string" ? initialOutputLanguage : "";
        outputLanguageEdited=false;outputLanguageSaveError="";
        initialReviewBeforeSending=app.session ? app.session.aiReviewBeforeSending : true;
        reviewBeforeSending.checkState=typeof initialReviewBeforeSending==="boolean"
            ? (initialReviewBeforeSending ? Qt.Checked : Qt.Unchecked) : Qt.PartiallyChecked;
        reviewBeforeSendingEdited=false;
        loadPrereadingDraft();prereadingPolicyEdited=false;
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
        const draft={baseUrl:baseUrl.text,model:modelName.text,
            reasoningMode:reasoning.currentIndex>=0 ? reasoningValues[reasoning.currentIndex] : initialReasoningMode,
            reasoningEncoding:encoding.currentIndex>=0 ? encodingValues[encoding.currentIndex] : initialReasoningEncoding,
            imageInput:imageInput.checked};
        if(initialHasTemperature || temperatureEdited)draft.temperature=temperatureEdited ? (temperatureEnabled.checked ? temperature.value : null) : initialTemperature;
        if(initialHasMaxTokens || maxTokensEdited)draft.maxTokens=maxTokensEdited ? (tokensEnabled.checked ? maxTokens.value : null) : initialMaxTokens;
        return draft;
    }
    function validTemperature(value) {return typeof value==="number" && isFinite(value) && value>=0 && value<=2;}
    function validMaxTokens(value) {return typeof value==="number" && isFinite(value) && Math.floor(value)===value && value>=64 && value<=8192;}
    function loadGenerationDraft() {
        initialHasTemperature=Object.prototype.hasOwnProperty.call(app.aiSettings,"temperature");
        initialHasMaxTokens=Object.prototype.hasOwnProperty.call(app.aiSettings,"maxTokens");
        initialTemperature=initialHasTemperature ? app.aiSettings.temperature : null;
        initialMaxTokens=initialHasMaxTokens ? app.aiSettings.maxTokens : null;
        temperatureEnabled.checked=initialHasTemperature && initialTemperature!==null;
        tokensEnabled.checked=initialHasMaxTokens && initialMaxTokens!==null;
        // Seeds position the disabled editor; they do not replace saved values
        // or become request options until the reader explicitly edits a control.
        temperature.value=validTemperature(initialTemperature) ? initialTemperature : generationSeedsReady ? generationSeeds.temperature : temperature.from;
        maxTokens.value=validMaxTokens(initialMaxTokens) ? initialMaxTokens : generationSeedsReady ? generationSeeds.max_tokens : maxTokens.from;
        temperatureEdited=false;maxTokensEdited=false;
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
        const languageChanged=outputLanguageEdited
            && (typeof initialOutputLanguage!=="string" || outputLanguage.text!==initialOutputLanguage);
        const reviewChanged=reviewBeforeSendingEdited
            && (typeof initialReviewBeforeSending!=="boolean" || reviewBeforeSending.checked!==initialReviewBeforeSending);
        const workflow={};
        if(languageChanged)workflow.outputLanguage=outputLanguage.text;
        if(reviewChanged)workflow.reviewBeforeSending=reviewBeforeSending.checked;
        if(prereadingPolicyEdited && prereadingPolicy.currentIndex>=0
                && prereadingPolicies[prereadingPolicy.currentIndex]!==initialPrereadingPolicy)
            workflow.prereadingPolicy=prereadingPolicies[prereadingPolicy.currentIndex];
        if(Object.keys(workflow).length && (!app.session || !app.session.setAiReadingWorkflow(workflow))) {
            outputLanguageSaveError=languageChanged && (initialOutputLanguage===undefined || initialOutputLanguage===null)
                ? qsTr("The saved output language could not be read and was kept. Recover the saved preference before replacing it.")
                : reviewChanged && (initialReviewBeforeSending===undefined || initialReviewBeforeSending===null)
                    ? qsTr("The saved review preference could not be read and was kept. Recover it before replacing it.")
                    : qsTr("The reading workflow could not be saved. The stored values were kept; try again when saving is available.");
            return;
        }
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
        function onConnectionModeChanged() {if(settings.connectionTest)settings.connectionTest.cancel();settings.connectionError="";if(settings.accounts.connectionMode==="chatGPT")apiKey.clear();}
    }
    Connections {target:settings.app;function onAiSettingsChanged(){if(settings.connectionTest)settings.connectionTest.cancel();}}
    Connections {
        target:settings.app.session
        function onAiReviewBeforeSendingChanged() {
            if(settings.reviewBeforeSendingEdited)return;
            settings.initialReviewBeforeSending=settings.app.session.aiReviewBeforeSending;
            reviewBeforeSending.checkState=typeof settings.initialReviewBeforeSending==="boolean"
                ? (settings.initialReviewBeforeSending ? Qt.Checked : Qt.Unchecked) : Qt.PartiallyChecked;
        }
        function onAiPrereadingPolicyChanged() {
            if(!settings.prereadingPolicyEdited)settings.loadPrereadingDraft();
        }
        function onAiOutputLanguageChanged() {
            // A Wayland open intent can still be waiting for its parent's first frame.
            if(settings.outputLanguageEdited)return;
            settings.initialOutputLanguage=settings.app.session.aiOutputLanguage;
            outputLanguage.text=typeof settings.initialOutputLanguage==="string" ? settings.initialOutputLanguage : "";
        }
    }
    function connectionTestStatus() {
        const state=connectionTestState,phase=state.phase;
        if(connectionTest && connectionTest.busy)return state.model ? qsTr("Testing %1…").arg(state.model) : qsTr("Testing the connection…");
        if(phase==="success")return qsTr("Connected to %1 in %2 ms.").replace(/%([12])/g,function(_,index){return index==="1" ? String(state.model) : String(state.elapsed_ms);});
        if(phase!=="failed")return "";
        const hint=state.failure==="Offline" ? qsTr("Check your network connection and try again.")
            : state.failure==="LocalServer" ? qsTr("Start the local server and confirm its address.") : "";
        return (state.message || qsTr("The connection test failed."))+(hint.length ? "\n"+hint : "");
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
        if(connectionTest)connectionTest.cancel();
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
                LyraCheckBox {
                    colors:settings.colors
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
                Label {text:qsTr("Reading workflow");font.weight:Font.DemiBold;textFormat:Text.PlainText;Layout.topMargin:8}
                Label {text:qsTr("Document prereading");textFormat:Text.PlainText}
                ComboBox {
                    id:prereadingPolicy;objectName:"settingsAiPrereadingPolicy"
                    Layout.fillWidth:true
                    model:[qsTr("Ask before reading"),qsTr("Always read first"),qsTr("Never read first")]
                    displayText:currentIndex>=0 ? currentText : qsTr("Unrecognized saved preference")
                    Accessible.name:qsTr("Document prereading")
                    Accessible.description:displayText+". "+qsTr("During prereading, other AI requests wait. Ordinary PDF reading remains available.")
                    onActivated:{settings.prereadingPolicyEdited=true;settings.outputLanguageSaveError="";}
                }
                Label {
                    Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText;font.pixelSize:11
                    color:prereadingPolicy.currentIndex<0 ? settings.colors.warningFg : settings.colors.textSecondary
                    text:prereadingPolicy.currentIndex<0
                        ? qsTr("The saved prereading preference is unrecognized and is kept until you choose a value.")
                        : qsTr("During prereading, other AI requests wait. Ordinary PDF reading remains available. Applies when you save.")
                }
                LyraCheckBox {
                    id:reviewBeforeSending
                    objectName:"settingsAiReviewBeforeSending"
                    colors:settings.colors
                    text:qsTr("Review before sending")
                    tristate:settings.unknownReviewBeforeSending
                    Accessible.description:settings.unknownReviewBeforeSending
                        ? qsTr("Unrecognized saved review preference. Choose a value to replace it.")
                        : checked ? qsTr("Review tasks in a separate window before sending.")
                            : qsTr("Generate and Ask send their prepared task directly.")
                    onClicked:{settings.reviewBeforeSendingEdited=true;settings.outputLanguageSaveError="";}
                }
                Label {
                    Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText
                    text:settings.unknownReviewBeforeSending
                        ? qsTr("The saved review preference is unrecognized and is kept until you choose a value. Tasks require review in the meantime.")
                        : qsTr("Review sidebar tasks and Interleaf questions in a separate window. When off, Generate or Ask sends directly. Applies when you save.")
                    font.pixelSize:11;color:settings.unknownReviewBeforeSending ? settings.colors.warningFg : settings.colors.textSecondary
                }
                Label {text:qsTr("Output language (blank uses document language)");textFormat:Text.PlainText;wrapMode:Text.Wrap;Layout.fillWidth:true}
                ReadingTextField {
                    id:outputLanguage
                    objectName:"settingsOutputLanguage"
                    app:settings.app
                    font.pixelSize:13;topPadding:5;bottomPadding:5
                    Layout.fillWidth:true
                    placeholderText:settings.unknownOutputLanguage ? qsTr("Unrecognized saved language") : qsTr("Document language")
                    Accessible.name:qsTr("Default AI output language")
                    onTextEdited:{settings.outputLanguageEdited=true;settings.outputLanguageSaveError="";}
                }
                Label {
                    text:qsTr("Applies when you save. Existing translation targets are kept.")
                    textFormat:Text.PlainText;wrapMode:Text.Wrap;Layout.fillWidth:true
                    font.pixelSize:11;color:settings.colors.textSecondary
                }
                Label {
                    objectName:"settingsOutputLanguageIssue"
                    Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText;font.pixelSize:11
                    visible:settings.unknownOutputLanguage
                    color:settings.colors.errorFg
                    text:qsTr("The saved output language is unrecognized. Enter a language, or clear the field, to replace it. Other settings keep the saved value.")
                }
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
                    ReadingTextField {
                        id: baseUrl
                        app:settings.app
                        font.pixelSize:13;topPadding:5;bottomPadding:5
                        objectName:"settingsBaseUrl"
                        Layout.fillWidth: true
                        placeholderText: qsTr("Base URL, e.g. http://localhost:11434/v1")
                        text: app.aiSettings.baseUrl || "http://localhost:11434/v1"
                        Accessible.name: qsTr("AI base URL")
                        onTextEdited:if(settings.connectionTest)settings.connectionTest.cancel()
                    }
                    ReadingTextField {
                        id: modelName
                        app:settings.app
                        font.pixelSize:13;topPadding:5;bottomPadding:5
                        objectName: "settingsAiModel"
                        Layout.fillWidth: true
                        placeholderText: qsTr("Model name")
                        text: app.aiSettings.model || ""
                        Accessible.name: qsTr("AI model")
                        onTextEdited:if(settings.connectionTest)settings.connectionTest.cancel()
                    }
                    RowLayout {
                        Layout.fillWidth:true
                        ConnectionTestButton {
                            colors:settings.colors
                            objectName:"testAiConnection";text:qsTr("Test Connection")
                            enabled:!!settings.connectionTest && !settings.connectionTest.busy
                            onClicked:settings.connectionTest.start(baseUrl.text,modelName.text,apiKey.text)
                        }
                        BusyIndicator {Layout.preferredWidth:22;Layout.preferredHeight:22;running:!!settings.connectionTest && settings.connectionTest.busy;visible:running}
                        ConnectionTestButton {
                            colors:settings.colors
                            objectName:"cancelAiConnectionTest";text:qsTr("Cancel")
                            Accessible.name:qsTr("Cancel connection test")
                            visible:!!settings.connectionTest && settings.connectionTest.busy
                            onClicked:settings.connectionTest.cancel()
                        }
                        Item {Layout.fillWidth:true}
                    }
                    TextArea {
                        objectName:"aiConnectionTestStatus"
                        Layout.fillWidth:true;implicitHeight:contentHeight+topPadding+bottomPadding
                        visible:text.length>0;text:settings.connectionTestStatus()
                        readOnly:true;selectByMouse:true;selectByKeyboard:true;wrapMode:TextEdit.Wrap;textFormat:TextEdit.PlainText
                        background:null;leftPadding:0;rightPadding:0;topPadding:0;bottomPadding:0;font.pixelSize:11
                        color:settings.connectionTestState.phase==="failed" ? settings.colors.errorFg : settings.colors.textSecondary
                        selectionColor:settings.colors.selectedBg;selectedTextColor:settings.colors.selectedFg
                        Accessible.name:qsTr("Connection test status");Accessible.description:text
                    }
                    Label {
                        Layout.fillWidth:true;wrapMode:Text.Wrap;font.pixelSize:11;color:settings.colors.textSecondary
                        text:qsTr("Test sends only a fixed ‘ping’ to the address and model above, without document content.")
                    }
                    LyraCheckBox {
                        colors:settings.colors
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
                    Label {text:qsTr("Generation");font.weight:Font.DemiBold}
                    Label {
                        visible:!settings.generationSeedsReady;Layout.fillWidth:true;wrapMode:Text.Wrap
                        text:qsTr("The generation controls could not load their defaults.");color:settings.colors.errorFg
                    }
                    RowLayout {
                        Layout.fillWidth:true
                        LyraCheckBox {
                            colors:settings.colors
                            id:temperatureEnabled;objectName:"settingsUseTemperature";text:qsTr("Temperature")
                            enabled:settings.generationSeedsReady;Accessible.name:qsTr("Use custom temperature")
                            onToggled:settings.temperatureEdited=true
                        }
                        Item {Layout.fillWidth:true}
                        Label {
                            id:temperatureValue
                            text:!temperatureEnabled.checked ? qsTr("Provider default") : settings.unknownTemperature ? qsTr("Unrecognized saved value") : Number(temperature.value.toFixed(4)).toString()
                            color:settings.colors.textSecondary;textFormat:Text.PlainText
                        }
                    }
                    Slider {
                        id:temperature;objectName:"settingsTemperature";Layout.fillWidth:true
                        from:0;to:2;stepSize:0.1;snapMode:Slider.SnapOnRelease
                        enabled:temperatureEnabled.checked && settings.generationSeedsReady
                        onMoved:settings.temperatureEdited=true
                        Accessible.name:qsTr("Temperature value");Accessible.description:temperatureValue.text
                    }
                    Label {
                        visible:settings.unknownTemperature;Layout.fillWidth:true;wrapMode:Text.Wrap;font.pixelSize:11;color:settings.colors.errorFg
                        text:qsTr("The saved temperature is not supported here. Adjust it to replace it, or clear the checkbox to use the provider default.")
                    }
                    RowLayout {
                        Layout.fillWidth:true
                        LyraCheckBox {
                            colors:settings.colors
                            id:tokensEnabled;objectName:"settingsUseMaxTokens";text:qsTr("Max tokens")
                            Layout.fillWidth:true;enabled:settings.generationSeedsReady
                            Accessible.name:qsTr("Use custom maximum output tokens");onToggled:settings.maxTokensEdited=true
                        }
                        SpinBox {
                            id:maxTokens;objectName:"settingsMaxTokens";from:64;to:8192;stepSize:64;editable:true
                            enabled:tokensEnabled.checked && settings.generationSeedsReady
                            Accessible.name:qsTr("Maximum output tokens")
                            Accessible.description:!tokensEnabled.checked ? qsTr("Provider default") : settings.unknownMaxTokens ? qsTr("Unrecognized saved value") : displayText
                            onValueModified:settings.maxTokensEdited=true
                        }
                    }
                    Label {
                        visible:!tokensEnabled.checked || settings.unknownMaxTokens;Layout.fillWidth:true;wrapMode:Text.Wrap;font.pixelSize:11
                        color:settings.unknownMaxTokens ? settings.colors.errorFg : settings.colors.textSecondary
                        text:settings.unknownMaxTokens ? qsTr("The saved token limit is not supported here. Adjust it to replace it, or clear the checkbox to use the provider default.") : qsTr("Provider default")
                    }
                    Label {
                        Layout.fillWidth:true;wrapMode:Text.Wrap;font.pixelSize:11;color:settings.colors.textSecondary
                        text:qsTr("Unchecked options use the provider default. Custom values are sent as temperature and max_tokens; the provider may ignore or cap them.")
                    }
                    ReadingTextField {
                        id: apiKey
                        app:settings.app
                        font.pixelSize:13;topPadding:5;bottomPadding:5
                        objectName:"settingsApiKey"
                        Layout.fillWidth: true
                        placeholderText: qsTr("API key — saved only in the system keychain")
                        echoMode: TextInput.Password
                        Accessible.name: qsTr("AI API key")
                        onTextEdited:if(settings.connectionTest)settings.connectionTest.cancel()
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

        Label {
            objectName:"settingsWorkflowSaveIssue"
            Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText
            visible:settings.outputLanguageSaveError.length>0
            text:settings.outputLanguageSaveError
            color:settings.colors.errorFg
            Accessible.role:Accessible.AlertMessage
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

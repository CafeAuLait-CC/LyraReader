import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

ApplicationWindow {
    id: settings
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
        appearance.currentIndex=["light","dark","system"].indexOf(app.appearance);
        paper.currentIndex=["original","warm","night"].indexOf(app.paperAppearance);
        gap.value=app.pageGap;baseUrl.text=app.aiSettings.baseUrl || "http://localhost:11434/v1";
        modelName.text=app.aiSettings.model || "";
        reasoning.currentIndex=Math.max(0,reasoning.model.indexOf(app.aiSettings.reasoningMode || "default"));
        encoding.currentIndex=Math.max(0,encoding.model.indexOf(app.aiSettings.reasoningEncoding || "none"));
        apiKey.clear();
        const saved=app.session ? app.session.preference("auxiliarySettingsGeometry",{}) : ({});
        if(!policy.prepare(settings,app,saved,560,650)){app.operationStatus=qsTr("The Settings window could not find an available display.");return;}
        show();requestActivate();
    }
    function save() {
        app.appearance = ["light", "dark", "system"][appearance.currentIndex];
        app.paperAppearance = ["original", "warm", "night"][paper.currentIndex];
        app.pageGap = gap.value;
        app.setPageLayout(app.layoutMode);
        app.aiSettings = {
                baseUrl: baseUrl.text,
                model: modelName.text,
                reasoningMode: reasoning.currentText,
                reasoningEncoding: encoding.currentText
        };
        if (app.session) {
            app.session.setPreference("ai", app.aiSettings);
            app.session.setPreference("paper", app.paperAppearance);
        }
        if (apiKey.text.length)
            app.saveAiCredential(baseUrl.text, apiKey.text);
        apiKey.clear();
        close();
    }
    onClosing: {
        if(app.session)app.session.setPreference("auxiliarySettingsGeometry",policy.geometry());
        apiKey.clear();policy.returnFocus();
    }
    Shortcut {sequence:"Escape";onActivated:settings.close()}
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
                }
                ComboBox {
                    id: paper
                    objectName:"settingsPaper"
                    Layout.fillWidth: true
                    model: [qsTr("Original Colours"), qsTr("Warm Paper"), qsTr("Night Reading")]
                    currentIndex: ["original", "warm", "night"].indexOf(app.paperAppearance)
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
                Button {
                    text: qsTr("Remove Saved Key")
                    onClicked: app.removeAiCredential(baseUrl.text)
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

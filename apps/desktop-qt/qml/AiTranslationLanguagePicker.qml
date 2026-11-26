import QtQuick
import QtQuick.Controls

ComboBox {
    id: control
    objectName: "aiTranslationLanguage"
    required property var app
    required property var owner
    property string language: "English"
    readonly property double generation: owner.documentGeneration
    readonly property bool popupVisible: popup.visible || custom.visible
    signal languageSelected(string value)
    readonly property var known: [
        {value: "English", title: qsTr("English"), code: "EN"},
        {value: "Simplified Chinese", title: qsTr("Simplified Chinese"), code: "SC"},
        {value: "Traditional Chinese", title: qsTr("Traditional Chinese"), code: "TC"},
        {value: "Japanese", title: qsTr("Japanese"), code: "JP"},
        {value: "Korean", title: qsTr("Korean"), code: "KR"},
        {value: "French", title: qsTr("French"), code: "FR"},
        {value: "Spanish", title: qsTr("Spanish"), code: "ES"},
        {value: "German", title: qsTr("German"), code: "DE"}
    ]
    readonly property var choices: {
        const existing = known.some(choice => choice.value === language) ? [] : [{value: language, title: language || qsTr("Custom language"), code: codeFor(language)}];
        return existing.concat(known).concat([{custom: true, title: qsTr("Other language…"), code: "…"}]);
    }
    function codeFor(value) {
        const exact = known.find(choice => choice.value === value);
        if (exact) return exact.code;
        if (!value.trim().length) return "…";
        // Locale interpretation affects this label only. It never rewrites a
        // saved language or the value passed to the reviewed Rust request.
        const name = Qt.locale(value).name.split("_");
        const codes = {en: "EN", ja: "JP", ko: "KR", fr: "FR", es: "ES", de: "DE"};
        if (name[0] === "zh") return ["TW", "HK", "MO"].indexOf(name[name.length - 1]) >= 0 ? "TC" : "SC";
        return codes[name[0]] || "…";
    }
    function synchronize() { currentIndex = choices.findIndex(choice => !choice.custom && choice.value === language); }
    onLanguageChanged: synchronize()
    onChoicesChanged: synchronize()
    Component.onCompleted: synchronize()
    implicitWidth: 80; implicitHeight: 28
    font.pixelSize: 13; font.weight: Font.Medium
    model: choices
    textRole: "title"
    displayText: codeFor(language)
    Accessible.name: qsTr("Translate to")
    Accessible.description: language
    palette.buttonText: enabled ? app.colors.textPrimary : app.colors.textDisabled
    background: Rectangle {
        radius: 6; color: control.app.colors.fieldBg
        border.width: control.visualFocus ? 2 : 1
        border.color: control.visualFocus ? control.app.colors.focusRing : control.app.colors.controlBorder
    }
    popup.width: Math.max(control.width, Math.min(240, control.app.width - 32))
    popup.x: control.mirrored ? 0 : control.width - popup.width
    popup.margins: 8
    popup.background: Rectangle { radius: 6; color: control.app.colors.menuBg; border.color: control.app.colors.separator }
    delegate: ItemDelegate {
        id: choiceItem
        required property int index
        required property var modelData
        objectName: "aiTranslationLanguageChoice" + index
        width: control.popup.width
        text: modelData.title
        highlighted: control.highlightedIndex === index
        contentItem: Label {
            text: choiceItem.text; textFormat: Text.PlainText
            font.pixelSize: 13
            color: choiceItem.highlighted ? control.app.colors.selectedFg : control.app.colors.textPrimary
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle { radius: 4; color: choiceItem.highlighted ? control.app.colors.selectedBg : "transparent" }
    }
    onActivated: function(index) {
        const choice = choices[index];
        if (choice.custom) { synchronize(); editCustom(); }
        else languageSelected(choice.value);
    }
    function editCustom() {
        custom.ticket = {owner: owner, generation: owner.documentGeneration, language: language};
        customText.text = language;
        custom.open();
    }
    function closePopups() { popup.close(); custom.close(); }
    onOwnerChanged: if (custom) closePopups()
    onGenerationChanged: if (custom) closePopups()
    onVisibleChanged: if (!visible && custom) closePopups()
    Dialog {
        id: custom
        objectName: "aiCustomTranslationLanguage"
        property var ticket: null
        parent: Overlay.overlay; anchors.centerIn: parent
        title: qsTr("Translation language")
        width: Math.max(220, Math.min(360, control.app.width - 48))
        modal: true
        standardButtons: Dialog.Save | Dialog.Cancel
        function refreshSave() {
            const button = standardButton(Dialog.Save);
            if (button) button.enabled = !!customText.text.trim().length;
        }
        onOpened: { refreshSave(); customText.forceActiveFocus(Qt.TabFocusReason); }
        onAccepted: {
            if (!ticket || ticket.owner !== control.owner || ticket.generation !== control.owner.documentGeneration || ticket.language !== control.language) {
                control.app.operationStatus = qsTr("The document or language changed. Open the language editor again.");
            } else if (customText.text.trim().length) {
                control.languageSelected(customText.text);
            }
        }
        onClosed: ticket = null
        TextField {
            id: customText
            objectName: "aiCustomTranslationLanguageText"
            width: parent.width
            placeholderText: qsTr("Target language")
            Accessible.name: qsTr("Translation language")
            onTextChanged: if (custom.visible) custom.refreshSave()
            onAccepted: if (text.trim().length) custom.accept()
        }
    }
}

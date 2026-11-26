import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

ColumnLayout {
    id: result
    Layout.minimumWidth: 0
    required property var app
    required property var value
    property string answerName: "aiAnswerText"
    property string answerAccessibleName: qsTr("AI response")
    property bool showSources: false
    property bool inlineConversation: false
    property int bodySize: 13
    property bool collapsibleSummary: false
    property bool showActions: true
    property bool plainText: sent.kind === "reading_translation"
    property var citationPages: undefined
    readonly property var textControl: !collapsibleSummary ? answerLoader.item : null
    property Flickable viewport: null
    signal keyboardNavigation(int key)
    function revealCursor(area, owner, generation, target) {
        if (!area || !area.activeFocus || !target || target !== viewport
                || app.currentReader !== owner || (owner && owner.documentGeneration !== generation)
                || target.height <= 0) return;
        const cursor = area.cursorRectangle;
        const rect = area.mapToItem(target.contentItem, cursor.x, cursor.y, cursor.width, cursor.height);
        if (!Number.isFinite(rect.y) || !Number.isFinite(rect.height)) return;
        let next = target.contentY;
        if (rect.y < next + 2) next = rect.y - 2;
        else if (rect.y + rect.height > next + target.height - 2) next = rect.y + rect.height - target.height + 2;
        target.contentY = Math.max(0, Math.min(Math.max(0, target.contentHeight - target.height), next));
    }
    function cursorKey(area, event) {
        if ([Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down, Qt.Key_Home,
             Qt.Key_End, Qt.Key_PageUp, Qt.Key_PageDown].indexOf(event.key) >= 0) {
            const owner = app.currentReader;
            const generation = owner ? owner.documentGeneration : 0;
            const target = viewport;
            keyboardNavigation(event.key);
            // Let TextArea move/select first, then reveal its cursor in the enclosing viewport.
            // Model updates alone do not scroll; a queued key cannot move another document.
            Qt.callLater(revealCursor, area, owner, generation, target);
        }
        event.accepted = false;
    }
    signal citation(string link, var plan)
    spacing: 4
    readonly property var sent: value.responsePlan || ({})
    readonly property string outputText: value.output || ""
    readonly property string usageSummary: {
        const usage = result.value.usage || {};
        const total = usage.total_tokens;
        const cached = usage.cached_tokens;
        if (Number.isFinite(total))
            return Number.isFinite(cached)
                ? qsTr("Tokens: %1 (%2 cached input)").arg(total).arg(cached)
                : qsTr("Tokens: %1").arg(total);
        return Number.isFinite(cached) ? qsTr("Cached input tokens: %1").arg(cached) : "";
    }
    ReadingMarkdown { id: markdown }
    function renderFor(text) {
        if (plainText) return {plain: true, text: text};
        const pages = citationPages !== undefined ? citationPages : sent.action === "TranslateSelection" ? []
            : sent.action === "DocumentChat" ? (sent.sources || []).map(source => source.page) : sent.source_pages || [];
        return markdown.render(text, app.currentReader, pages || [],
            app.currentReader ? app.currentReader.pageCount : 0, bodySize, {
                accent: app.colors.accent, separator: app.colors.separator,
                raisedBg: app.colors.raisedBg, textSecondary: app.colors.textSecondary,
                warningFg: app.colors.warningFg
            });
    }
    function activateLink(link) {
        // Only explicit activation opens external links; images/HTML never load resources.
        if (/^(https?:|mailto:)/i.test(link)) { Qt.openUrlExternally(link); return; }
        result.citation(link, {action: sent.action, sources: sent.sources || [],
            source_pages: sent.source_pages || [], generation: value.generation});
    }
    function focusAnswer() {
        if (!collapsibleSummary && answerLoader.item) answerLoader.item.forceActiveFocus(Qt.TabFocusReason);
    }
    Label {
        objectName: result.answerName + "UnitTitle"
        visible: !!result.value.unitTitle
        text: result.value.unitTitle ? qsTr("Answer for: %1").arg(result.value.unitTitle) : ""
        textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
        Accessible.description: text
        Layout.fillWidth: true; font.bold: true; color: app.colors.textPrimary
    }
    Label {
        objectName: result.answerName + "Language"
        visible: !!result.value.unitTitle && typeof result.value.unitLanguage === "string"
        text: visible ? qsTr("Requested language: %1").arg(result.value.unitLanguage || qsTr("Document language")) : ""
        textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
        Accessible.description: text
        Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11
    }
    Loader {
        id: answerLoader
        Layout.fillWidth: true; Layout.minimumWidth: 0
        sourceComponent: result.collapsibleSummary ? sections : answer
    }
    Component {
        id: sections
        AiSummarySections {
            app: result.app; value: result.value; renderer: result
            answerName: result.answerName; viewport: result.viewport
            onCitation: function(link, plan) { result.citation(link, plan); }
        }
    }
    Component {
        id: answer
    TextArea {
        id: answerArea
        objectName: result.answerName
        Layout.fillWidth: true
        readonly property var rendered: result.renderFor(result.outputText)
        text: rendered.text
        readOnly: true; selectByMouse: true; selectByKeyboard: true; wrapMode: TextEdit.Wrap; background: null
        textFormat: rendered.plain ? TextEdit.PlainText : TextEdit.RichText
        Binding { target: answerArea; property: "padding"; value: 0; when: result.inlineConversation }
        Binding { target: answerArea; property: "font.pixelSize"; value: result.bodySize; when: result.inlineConversation }
        Accessible.name: result.answerAccessibleName
        Keys.onPressed: function(event) { result.cursorKey(answerArea, event); }
        onLinkActivated: function(link) { result.activateLink(link); }
    }
    }
    Label {
        objectName: result.answerName + "FormatWarning"
        text: !result.collapsibleSummary && answerLoader.item && answerLoader.item.rendered
            ? answerLoader.item.rendered.warning || "" : ""
        visible: text.length > 0
        Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap
        color: app.colors.textSecondary; font.pixelSize: 11
    }
    ToolButton {
        id: sources
        objectName: result.answerName + "Sources"
        visible: result.showSources && (result.sent.sources || []).length > 0
        text: qsTr("Sources · %1").arg(Array.from(new Set((result.sent.sources || []).map(source => "p." + source.page))).join(", ")) + (checked ? " ▾" : " ▸")
        checkable: true
        Accessible.name: qsTr("Show passages actually sent with this answer")
    }
    ColumnLayout {
        visible: sources.visible && sources.checked
        Layout.fillWidth: true
        Repeater {
            model: result.sent.sources || []
            Button {
                id: sourceChip
                required property var modelData
                Layout.fillWidth: true
                padding: 5
                Accessible.name: qsTr("Source page %1").arg(modelData.page)
                Accessible.description: qsTr("Jump to the page and briefly highlight the passage sent with this answer.")
                contentItem: RowLayout {
                    spacing: 6
                    Rectangle {
                        radius: height / 2
                        color: Qt.rgba(app.colors.accent.r, app.colors.accent.g, app.colors.accent.b, 0.12)
                        Layout.alignment: Qt.AlignTop
                        implicitWidth: pageLabel.implicitWidth + 10; implicitHeight: pageLabel.implicitHeight + 2
                        Label { id: pageLabel; anchors.centerIn: parent; text: "p." + sourceChip.modelData.page; color: app.colors.accent; font.pixelSize: 11; font.weight: Font.DemiBold }
                    }
                    Label {
                        text: sourceChip.modelData.snippet || qsTr("Passage sent from page %1").arg(sourceChip.modelData.page)
                        textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true
                        color: app.colors.textSecondary; font.pixelSize: 11
                    }
                }
                background: Rectangle {
                    radius: 5; color: sourceChip.down ? app.colors.pressedBg : sourceChip.hovered ? app.colors.hoverBg : app.colors.fieldBg
                    border.width: sourceChip.visualFocus ? 2 : 0; border.color: app.colors.focusRing
                }
                onClicked: result.citation("p." + modelData.page, {action: result.sent.action, sources: result.sent.sources, source_pages: result.sent.source_pages, generation: result.value.generation})
            }
        }
    }
    ToolButton {
        id: reasoning
        objectName: result.answerName === "aiAnswerText" ? "aiReasoningToggle" : result.answerName + "ReasoningToggle"
        visible: !!result.value.reasoning
        text: qsTr("Provider reasoning") + (checked ? " ▴" : " ▾")
        checkable: true
        Accessible.name: qsTr("Show provider reasoning separately")
    }
    TextArea {
        id: reasoningArea
        objectName: result.answerName === "aiAnswerText" ? "aiReasoningText" : result.answerName + "Reasoning"
        visible: reasoning.visible && reasoning.checked
        Layout.fillWidth: true
        text: result.value.reasoning || ""
        readOnly: true; selectByMouse: true; selectByKeyboard: true; textFormat: TextEdit.PlainText; wrapMode: TextEdit.Wrap; background: null
        font.pixelSize: 11
        Keys.onPressed: function(event) { result.cursorKey(reasoningArea, event); }
    }
    RowLayout {
        visible: !!result.value.output && result.showActions
        Button { objectName: result.showActions ? result.answerName + "Copy" : ""; visible: !result.inlineConversation; text: qsTr("Copy answer"); onClicked: if (app.session) app.session.copyText(result.value.output) }
        Label {
            objectName: result.showActions ? result.answerName + "Usage" : ""
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            visible: text.length > 0
            text: result.usageSummary
            color: app.colors.textSecondary; font.pixelSize: 10
        }
    }
}

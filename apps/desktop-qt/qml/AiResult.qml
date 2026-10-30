import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "ReaderLogic.js" as Logic

ColumnLayout {
    id: result
    required property var app
    required property var value
    property string answerName: "aiAnswerText"
    property bool showSources: false
    signal citation(string link, var plan)
    spacing: 4
    readonly property var sent: value.responsePlan || ({})
    ToolButton {
        id: sources
        objectName: result.answerName + "Sources"
        visible: result.showSources && (result.sent.sources || []).length > 0
        text: qsTr("Sources (%1)").arg((result.sent.sources || []).length) + (checked ? " ▴" : " ▾")
        checkable: true
        Accessible.name: qsTr("Show passages actually sent with this answer")
    }
    ColumnLayout {
        visible: sources.visible && sources.checked
        Layout.fillWidth: true
        Repeater {
            model: result.sent.sources || []
            ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                Button {
                    text: qsTr("Page %1").arg(modelData.page)
                    onClicked: result.citation("p." + modelData.page, {action: result.sent.action, sources: result.sent.sources, source_pages: result.sent.source_pages, generation: result.value.generation})
                }
                Label { text: modelData.snippet || ""; textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true; color: app.colors.textSecondary; font.pixelSize: 11 }
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
        objectName: result.answerName === "aiAnswerText" ? "aiReasoningText" : result.answerName + "Reasoning"
        visible: reasoning.visible && reasoning.checked
        Layout.fillWidth: true
        text: result.value.reasoning || ""
        readOnly: true; selectByMouse: true; textFormat: TextEdit.PlainText; wrapMode: TextEdit.Wrap; background: null
        font.pixelSize: 11
    }
    TextArea {
        objectName: result.answerName
        Layout.fillWidth: true
        text: Logic.answerMarkup(result.value.output || "", result.sent.action === "TranslateSelection" ? false : result.sent.action === "DocumentChat" ? (result.sent.sources || []).map(source => source.page) : (result.sent.source_pages || []))
        readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; background: null; textFormat: TextEdit.RichText
        Accessible.name: qsTr("AI response")
        onLinkActivated: function(link) { result.citation(link, {action: result.sent.action, sources: result.sent.sources || [], source_pages: result.sent.source_pages || [], generation: result.value.generation}); }
    }
    RowLayout {
        visible: !!result.value.output
        Button { text: qsTr("Copy answer"); onClicked: if (app.session) app.session.copyText(result.value.output) }
        Label {
            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
            text: result.value.usage && result.value.usage.total_tokens ? qsTr("Tokens: %1").arg(result.value.usage.total_tokens) : ""
            color: app.colors.textSecondary; font.pixelSize: 10
        }
    }
}

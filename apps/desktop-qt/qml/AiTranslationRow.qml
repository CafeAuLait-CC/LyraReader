import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQml.Models

Item {
    id: row
    required property var app
    required property var task
    required property int index
    required property string recordId
    required property int paragraph
    required property bool first
    required property bool last
    required property bool isActive
    required property bool isExpanded
    objectName: "aiSavedTranslationRow" + index
    implicitHeight: content.implicitHeight + 12
    readonly property var entry: isActive ? task.activeEntry : task.entries[recordId] || null
    readonly property var blocks: entry ? entry.blocks || [] : []
    readonly property var block: blocks[paragraph] || null
    readonly property string original: block ? block.original : ""
    readonly property string answer: block ? block.translation : entry ? entry.content || "" : ""
    readonly property var verifiedPages: {
        const pages = entry ? entry.source_pages || [] : [];
        return block ? (pages.indexOf(block.page) >= 0 ? [block.page] : []) : pages;
    }
    readonly property int page: block ? block.page : 0
    readonly property string originalKey: recordId + ":" + paragraph
    readonly property bool originalExpanded: isActive || task.originalOpen[originalKey] === true
    readonly property bool collapsed: !isActive && !isExpanded
    function focusDisclosure() { answerPreview.focusAction(); }
    function focusAnswer() { answerView.focusAnswer(); }
    ContextMenu.menu: termsMenu
    Component.onCompleted: if (!isActive) task.needEntry(recordId)
    onRecordIdChanged: {
        if (task && typeof task.releaseTermRow === "function") task.releaseTermRow(row);
        if (!isActive) task.needEntry(recordId);
    }
    Component.onDestruction: if (task && typeof task.releaseTermRow === "function") task.releaseTermRow(row)
    ColumnLayout {
        id: content
        x: row.task.leadingInset; y: 6; width: row.task.rowWidth
        spacing: 8
        Label {
            visible: row.first && !!row.entry && row.entry.status === "sourceChanged"
            text: qsTr("The document has changed. This result keeps its original source snapshot.")
            textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true
            color: app.colors.warningFg; font.pixelSize: 12
        }
        Label {
            visible: row.first && !!row.entry && row.entry.status === "partial"
            text: qsTr("Partial result · stopped or interrupted")
            textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true
            color: app.colors.textSecondary; font.pixelSize: 12
        }
        Label {
            visible: row.first && !!row.entry && !!row.entry.warning
            text: row.entry ? row.entry.warning || "" : ""
            textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true
            color: app.colors.warningFg; font.pixelSize: 12
        }
        Label {
            visible: !row.entry
            text: row.task.entryErrors[row.recordId] || qsTr("Loading saved translation…")
            textFormat: Text.PlainText; wrapMode: Text.Wrap; Layout.fillWidth: true
            color: row.task.entryErrors[row.recordId] ? app.colors.warningFg : app.colors.textSecondary
            font.pixelSize: 12
        }
        ToolButton {
            visible: !row.entry && !!row.task.entryErrors[row.recordId]
            text: qsTr("Reload saved result")
            onClicked: row.task.needEntry(row.recordId, true)
        }
        ColumnLayout {
            visible: row.task.showOriginal && !!row.original
            Layout.fillWidth: true; Layout.minimumWidth: 0
            spacing: 2
            TranslationInlinePreview {
                id: originalPreview
                app: row.app; textArea: originalText; naturalHeight: originalText.contentHeight
                collapsed: !row.originalExpanded; maximumLines: 3
                actionEnabled: !row.isActive
                actionName: "aiTranslationOriginalMore" + row.index
                fallback: originalDisclosure
                Layout.fillWidth: true
                onActivated: { const closing = row.originalExpanded; row.task.setOriginalOpen(row.originalKey, !closing); if (closing) row.task.revealRecord(row.recordId); }
                TextArea {
                    id: originalText
                    objectName: "aiTranslationOriginal" + row.index
                    width: parent.width
                    text: row.original; textFormat: TextEdit.PlainText
                    readOnly: true; selectByMouse: true; selectByKeyboard: true
                    wrapMode: TextEdit.Wrap; padding: 0; background: null
                    color: app.colors.textSecondary; font.pixelSize: 14
                    Accessible.name: qsTr("Original passage")
                    ContextMenu.menu: termsMenu
                    Keys.onShortcutOverride: function(event) {
                        if(event.key===Qt.Key_Menu || (event.key===Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier)))event.accepted=true;
                    }
                    Keys.onPressed: function(event) {
                        if(event.key===Qt.Key_Menu || (event.key===Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
                            termsMenu.parent=originalText;
                            termsMenu.popup(0,Math.max(0,Math.min(originalPreview.visibleHeight,originalText.cursorRectangle.y+originalText.cursorRectangle.height)));
                            event.accepted=true;return;
                        }
                        if ([Qt.Key_Up, Qt.Key_Down, Qt.Key_Left, Qt.Key_Right, Qt.Key_Home, Qt.Key_End, Qt.Key_PageUp, Qt.Key_PageDown].indexOf(event.key) >= 0 && !row.originalExpanded)
                            row.task.setOriginalOpen(row.originalKey, true);
                        event.accepted = false;
                    }
                }
            }
            ToolButton {
                id: originalDisclosure
                objectName: originalPreview.footerNeeded ? "aiTranslationOriginalMore" + row.index : ""
                visible: originalPreview.footerNeeded
                text: row.originalExpanded ? qsTr("Less") : qsTr("More")
                palette.buttonText: app.colors.accent
                onClicked: { const closing = row.originalExpanded; row.task.setOriginalOpen(row.originalKey, !closing); if (closing) row.task.revealRecord(row.recordId); }
            }
        }
        TranslationInlinePreview {
            id: answerPreview
            app: row.app; textArea: answerView.textControl; naturalHeight: answerView.implicitHeight
            collapsed: row.collapsed; additionalContent: row.blocks.length > 1
            actionEnabled: !row.isActive && row.last
            actionName: "aiTranslationMore" + row.index; fallback: disclosure
            Layout.fillWidth: true; Layout.minimumWidth: 0
            visible: !!row.answer
            onActivated: row.task.expandRecord(row.recordId, !row.isExpanded)
            AiResult {
                id: answerView
                width: parent.width
                app: row.app
                value: ({output: row.answer, generation: row.task.generation, responsePlan: {source_pages: row.verifiedPages}})
                answerName: "aiTranslationAnswer" + row.index
                plainText: false; citationPages: row.verifiedPages
                inlineConversation: true; bodySize: 14
                showActions: false; showSources: false
                readingMenu: termsMenu
                viewport: row.task.viewport
                onCitation: function(link, plan) { row.task.panel.followVerifiedPage(link, row.verifiedPages, row.task.generation); }
                onKeyboardNavigation: if (row.collapsed) row.task.expandRecord(row.recordId, true)
            }
        }
        RowLayout {
            visible: !!row.entry
            Layout.fillWidth: true
            ToolButton {
                objectName: "aiTranslationPage" + row.index
                visible: row.page > 0
                text: qsTr("p. %1").arg(row.page)
                palette.buttonText: app.colors.accent
                enabled: row.verifiedPages.indexOf(row.page) >= 0
                onClicked: row.task.panel.followVerifiedPage("p." + row.page, row.verifiedPages, row.task.generation)
            }
            Item { Layout.fillWidth: true }
            ToolButton {
                id: disclosure
                objectName: answerPreview.footerNeeded ? "aiTranslationMore" + row.index : ""
                visible: answerPreview.footerNeeded
                text: row.isExpanded ? qsTr("Less") : qsTr("More")
                palette.buttonText: app.colors.accent
                onClicked: row.task.expandRecord(row.recordId, !row.isExpanded)
            }
            LyraToolButton {
                objectName: "aiTranslationRetry" + row.index
                visible: !row.isActive && row.last
                symbol: "rotate"; text: qsTr("Retry"); display: AbstractButton.TextBesideIcon
                palette.buttonText: app.colors.accent; icon.color: app.colors.accent
                enabled: !row.isActive && !!row.entry && row.entry.can_replay && row.task.canReview
                onClicked: row.task.panel.replaySavedTranslation(row.entry, true)
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: app.colors.separator }
    }
    LyraMenu {
        id: termsMenu
        objectName: "aiTranslationTermsMenu" + row.index
        property var snapshot: null
        onAboutToShow: snapshot = {reader: row.task.owner, generation: row.task.generation,
            record: row.recordId, terms: row.entry ? (row.entry.terms || []).slice() : []}
        focus: true

        LyraMenuItem {
            text: qsTr("Copy")
            enabled: !!termsMenu.parent && typeof termsMenu.parent.copy === "function" && !!termsMenu.parent.selectedText
            onTriggered: termsMenu.parent.copy()
        }
        LyraMenuItem {
            text: qsTr("Select all")
            enabled: !!termsMenu.parent && typeof termsMenu.parent.selectAll === "function"
            onTriggered: termsMenu.parent.selectAll()
        }
        LyraMenuSeparator {}
        Instantiator {
            model: termsMenu.snapshot ? termsMenu.snapshot.terms : []
            delegate: LyraMenuItem {
                required property int index
                required property string modelData
                objectName: "explainAiTranslationTerm" + index
                text: qsTr("Explain “%1”").arg(modelData)
                enabled: row.task.canExplain && !!row.entry && row.entry.status !== "sourceChanged"
                    && !!termsMenu.snapshot && termsMenu.snapshot.reader === row.task.owner
                    && termsMenu.snapshot.generation === row.task.generation && termsMenu.snapshot.record === row.recordId
                onTriggered: row.task.explainTerm(modelData, termsMenu.parent || row, row, termsMenu.snapshot)
            }
            onObjectAdded: function(index, object) { termsMenu.insertItem(index + 3, object); }
            onObjectRemoved: function(index, object) { termsMenu.removeItem(object); }
        }
    }
}

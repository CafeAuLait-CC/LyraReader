import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    required property var app
    readonly property var owner: app.currentReader
    signal previewUnit(string id)
    property var popupOwner: null
    readonly property var state: popupOwner ? popupOwner.summaryCatalog : ({})
    readonly property bool popupVisible: detail.visible
    implicitHeight: 32
    implicitWidth: 200
    onOwnerChanged: if (detail && detail.visible) detail.close()
    onVisibleChanged: if (!visible && detail && detail.visible) detail.close()
    function openSource(row) {
        if (!popupOwner || popupOwner !== owner || state.generation !== owner.documentGeneration
                || row.link_page === null || row.link_page < 0 || row.link_page >= owner.pageCount) return;
        const expectedOwner = popupOwner;
        const generation = state.generation;
        detail.close();
        if (owner !== expectedOwner || !owner || owner.documentGeneration !== generation) return;
        app.navigate(row.link_page);
    }
    function previewSummary(row) {
        if (!popupOwner || popupOwner !== owner || state.generation !== owner.documentGeneration) return;
        const expectedOwner = popupOwner;
        const generation = state.generation;
        detail.close();
        if (owner !== expectedOwner || !owner || owner.documentGeneration !== generation) return;
        previewUnit(row.id);
    }
    LyraToolButton {
        id: entry
        objectName: "openSummaryCatalog"
        anchors.fill: parent
        text: qsTr("Layers and coverage…")
        display: AbstractButton.TextOnly
        selected: detail.visible
        enabled: owner.pageCount > 0 && !owner.loading && !owner.snapshotReadOnly
        Accessible.description: qsTr("Browse summary source pages and inspect text coverage locally")
        onClicked: {
            if (detail.visible) { detail.close(); return; }
            root.popupOwner = root.owner;
            root.popupOwner.setSummaryExpanded(true);
            detail.open();
        }
    }
    Connections {
        target: root.popupOwner
        function onSummaryCatalogChanged() {
            if (!root.state.expanded && detail.visible) detail.close();
        }
    }
    Dialog {
        id: detail
        objectName: "summaryCatalogDialog"
        title: qsTr("Summary layers and coverage")
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(460, root.app.width - 24)
        height: Math.min(610, root.app.height - 32)
        modal: false
        focus: true
        standardButtons: Dialog.Close
        onClosed: {
            if (root.popupOwner) root.popupOwner.setSummaryExpanded(false);
        }
        ColumnLayout {
            anchors.fill: parent
            spacing: 8
            Label {
                text: qsTr("Coverage checks and previews use this PDF locally. Send is a separate action.")
                textFormat: Text.PlainText; wrapMode: Text.Wrap
                Layout.fillWidth: true; color: root.app.colors.textSecondary
            }
            RowLayout {
                Layout.fillWidth: true
                ComboBox {
                    objectName: "summaryCatalogLayer"
                    Layout.fillWidth: true
                    model: [qsTr("Abstract"), qsTr("Sections"), qsTr("Pages")]
                    currentIndex: ["Abstract", "Section", "Page"].indexOf(root.state.layer || "Abstract")
                    Accessible.name: qsTr("Summary layer")
                    onActivated: if (root.popupOwner) root.popupOwner.loadSummaryCatalog(["Abstract", "Section", "Page"][currentIndex], 0)
                }
                ToolButton {
                    objectName: "refreshSummaryCatalog"
                    text: qsTr("Refresh")
                    enabled: !root.state.loading && !root.state.inspecting
                    onClicked: root.popupOwner.loadSummaryCatalog(root.state.layer || "Abstract", root.state.offset || 0)
                }
            }
            Label {
                visible: !!root.state.error
                text: root.state.error || ""
                textFormat: Text.PlainText; wrapMode: Text.Wrap
                Layout.fillWidth: true; color: root.app.colors.textPrimary
            }
            ProgressBar {
                Layout.fillWidth: true; visible: !!root.state.loading || !!root.state.inspecting
                indeterminate: visible
                Accessible.name: qsTr("Checking summary coverage")
            }
            ListView {
                id: rows
                objectName: "summaryCatalogRows"
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true; spacing: 8
                model: root.state.rows || []
                ScrollBar.vertical: ScrollBar { id: scrollbar }
                delegate: ColumnLayout {
                    id: row
                    required property var modelData
                    readonly property var coverage: (root.state.coverage || {})[modelData.id] || ({})
                    readonly property var fingerprint: coverage.fingerprint || null
                    readonly property bool checking: root.state.inspecting === modelData.id
                    width: rows.width - (scrollbar.visible ? scrollbar.width + 4 : 0)
                    spacing: 3
                    Label {
                        objectName: "summaryCatalogRowTitle"
                        text: row.modelData.unit.kind === "Abstract" ? qsTr("Abstract") : row.modelData.unit.title
                        textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight
                        Accessible.description: text
                        font.bold: true; Layout.fillWidth: true; color: root.app.colors.textPrimary
                    }
                    Label {
                        text: row.coverage.page_span || row.modelData.page_span
                        textFormat: Text.PlainText; wrapMode: Text.Wrap
                        Layout.fillWidth: true; color: root.app.colors.textSecondary
                    }
                    Label {
                        objectName: "summaryCatalogCoverage"
                        text: row.checking ? qsTr("Checking…") : row.coverage.error ? row.coverage.error
                              : row.fingerprint ? (row.fingerprint.characters ? qsTr("%1 text characters available").arg(row.fingerprint.characters) : qsTr("No extractable text"))
                              : qsTr("Coverage not checked")
                        textFormat: Text.PlainText; wrapMode: Text.Wrap
                        Layout.fillWidth: true; color: root.app.colors.textSecondary
                    }
                    Label {
                        visible: !!row.fingerprint && !!row.fingerprint.note
                        text: row.fingerprint ? row.fingerprint.note || "" : ""
                        textFormat: Text.PlainText; wrapMode: Text.Wrap
                        Layout.fillWidth: true; color: root.app.colors.textSecondary
                    }
                    GridLayout {
                        Layout.fillWidth: true
                        columns: row.width >= 400 ? 3 : 2
                        Button {
                            objectName: "inspectSummaryCatalogRow"
                            property string unitId: row.modelData.id
                            text: row.coverage.error ? qsTr("Retry coverage check") : qsTr("Check coverage")
                            enabled: !root.state.loading && !root.state.inspecting
                            onClicked: root.popupOwner.inspectSummaryUnit(unitId)
                            Accessible.description: qsTr("Inspect this unit's text locally without sending a request")
                        }
                        Button {
                            objectName: "previewSummaryCatalogRow"
                            property string unitId: row.modelData.id
                            text: qsTr("Preview summary")
                            enabled: !root.state.loading && !root.state.inspecting && !root.popupOwner.aiState.running
                            onClicked: root.previewSummary(row.modelData)
                            Accessible.description: qsTr("Prepare one request locally; Send remains a separate action")
                        }
                        ToolButton {
                            objectName: "openSummaryCatalogSource"
                            property int sourcePage: row.modelData.link_page === null ? -1 : row.modelData.link_page
                            text: qsTr("Open source")
                            visible: sourcePage >= 0
                            onClicked: root.openSource(row.modelData)
                        }
                    }
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.app.colors.border }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                ToolButton {
                    objectName: "summaryCatalogPrevious"
                    text: qsTr("Previous")
                    enabled: !root.state.loading && !root.state.inspecting && root.state.offset > 0
                    onClicked: root.popupOwner.loadSummaryCatalog(root.state.layer, Math.max(0, root.state.offset - root.state.limits.max_requests_per_batch))
                }
                Label {
                    objectName: "summaryCatalogPageRange"
                    Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter
                    text: root.state.total ? qsTr("%1–%2 of %3").arg(root.state.offset + 1).arg(root.state.offset + (root.state.rows || []).length).arg(root.state.total) : ""
                    textFormat: Text.PlainText; color: root.app.colors.textSecondary
                }
                ToolButton {
                    objectName: "summaryCatalogNext"
                    text: qsTr("Next")
                    enabled: !root.state.loading && !root.state.inspecting && root.state.next_offset !== undefined && root.state.next_offset !== null
                    onClicked: root.popupOwner.loadSummaryCatalog(root.state.layer, root.state.next_offset)
                }
            }
        }
    }
}

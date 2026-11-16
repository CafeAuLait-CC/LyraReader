import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ListView {
    id: root
    objectName: "summaryBatchRows"
    required property var app
    required property var owner
    readonly property var state: owner.summaryBatchState
    property var modelOwner: null
    property var modelGeneration: null
    signal previewRow(var reader, var generation, string layer, int index)
    signal citation(var reader, var generation, string link, var proof)
    clip: true; spacing: 10
    model: order
    ScrollBar.vertical: ScrollBar {}
    ListModel { id: order }
    function syncOrder() {
        if (!owner || !order) return;
        const ids = state.ids || [];
        let same = modelOwner === owner && modelGeneration === owner.documentGeneration && order.count === ids.length;
        if (same) for (let i = 0; i < ids.length; ++i) if (order.get(i).unitId !== ids[i]) { same = false; break; }
        if (same) return;
        order.clear(); modelOwner = owner; modelGeneration = owner.documentGeneration;
        for (const id of ids) order.append({unitId: id});
    }
    onOwnerChanged: syncOrder()
    onStateChanged: syncOrder()
    Component.onCompleted: syncOrder()
    Connections { target: root.owner; function onAiStateChanged() { root.syncOrder(); } }
    delegate: ColumnLayout {
        id: row
        required property string unitId
        readonly property var entry: (root.state.rows || {})[unitId] || ({})
        property var expectedOwner: null
        property var expectedGeneration: null
        property string expectedId: ""
        function current() { return expectedOwner && expectedOwner === root.owner && expectedGeneration === expectedOwner.documentGeneration && expectedId === unitId && entry.generation === expectedGeneration; }
        Component.onCompleted: { expectedOwner = root.owner; expectedGeneration = root.owner.documentGeneration; expectedId = unitId; }
        objectName: "summaryBatchRow_" + unitId
        width: root.width
        spacing: 3
        Label {
            Layout.fillWidth: true; font.bold: true; color: app.colors.textPrimary
            text: row.entry.title || ""; textFormat: Text.PlainText; wrapMode: Text.Wrap
            maximumLineCount: 2; elide: Text.ElideRight; Accessible.description: text
        }
        Label {
            Layout.fillWidth: true; color: app.colors.textSecondary
            text: row.entry.page_span || ""; textFormat: Text.PlainText; wrapMode: Text.Wrap
        }
        Label {
            visible: !!row.entry.note
            Layout.fillWidth: true; color: app.colors.textSecondary
            text: row.entry.note || ""; textFormat: Text.PlainText; wrapMode: Text.Wrap
            maximumLineCount: 3; elide: Text.ElideRight; Accessible.description: text
        }
        Label {
            objectName: "summaryBatchStatus_" + row.unitId
            text: row.entry.state === "ready" ? ((row.entry.result || {}).cached ? qsTr("Saved locally") : qsTr("Complete")) : row.entry.state === "sending" ? qsTr("Receiving…") : row.entry.state === "queued" ? qsTr("Queued") : row.entry.state === "cancelled" ? qsTr("Cancelled") : row.entry.state === "failed" ? qsTr("Failed") : qsTr("Previewed; not sent")
            color: row.entry.state === "failed" ? app.colors.errorFg : app.colors.textSecondary
            textFormat: Text.PlainText; Accessible.description: text
        }
        Label {
            visible: !!row.entry.error; text: row.entry.error || ""
            Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap; maximumLineCount: 3; elide: Text.ElideRight
            color: app.colors.errorFg; Accessible.description: text
        }
        Label {
            objectName: "summaryBatchCacheWarning_" + row.unitId
            visible: !!row.entry.cache_warning; text: qsTr("Summary cache: %1").arg(row.entry.cache_warning || "")
            Layout.fillWidth: true; textFormat: Text.PlainText; wrapMode: Text.Wrap
            color: app.colors.textSecondary; Accessible.description: text
        }
        RowLayout {
            Layout.fillWidth: true
            ToolButton {
                objectName: "summaryBatchSource_" + row.unitId
                text: qsTr("Open source")
                visible: row.entry.link_page !== null && row.entry.link_page !== undefined
                onClicked: if (row.current() && row.entry.link_page >= 0 && row.entry.link_page < row.expectedOwner.pageCount) app.navigate(row.entry.link_page)
            }
            Button {
                objectName: "summaryBatchRetry_" + row.unitId
                text: qsTr("Preview this row again")
                enabled: !root.owner.aiState.running && root.owner.pendingCommands === 0 && (root.state.committedIds || []).indexOf(row.unitId) >= 0
                onClicked: if (row.current()) root.previewRow(row.expectedOwner, row.expectedGeneration, row.entry.layer, row.entry.index)
            }
        }
        AiResult {
            Layout.fillWidth: true
            app: root.app; value: row.entry.result || ({}); viewport: root
            answerName: "summaryBatchAnswer_" + row.unitId
            visible: !!value.output || !!value.reasoning
            onCitation: function(link, proof) { if (row.current()) root.citation(row.expectedOwner, row.expectedGeneration, link, proof); }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: app.colors.border }
    }
}

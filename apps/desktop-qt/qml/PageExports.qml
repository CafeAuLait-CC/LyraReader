import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

Dialog {
    id: exportsDialog
    objectName: "pageExports"
    required property var app
    property var owner: null
    property bool merging: false
    property var additions: []
    property var plan: null
    property double planRequest: -1
    property bool planning: false
    property string error: ""
    property url outputDirectory: ""
    readonly property bool busy: owner ? owner.pendingCommands > 0 : false
    readonly property string blockedReason: !owner ? "" : owner.hasEditDrafts ? qsTr("Save or clear pending form edits and redaction marks first.") : owner.data.marks && owner.data.marks.pending_deletions > 0 ? qsTr("Write pending file annotation deletions to a PDF first.") : !merging && owner.data.marks && owner.data.marks.preserved > 0 ? qsTr("Unknown sidecar entries cannot be remapped safely into split files.") : ""
    readonly property bool canWrite: !!owner && !!app.session && !blockedReason.length && !busy && (merging ? additions.length > 0 : !!plan && plan.parts.length > 0 && !plan.conflicts.length && !error.length && !planning)
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(720, app.width - 32)
    height: Math.min(650, app.height - 32)
    modal: true
    standardButtons: Dialog.Cancel
    title: merging ? qsTr("Merge PDF Documents") : qsTr("Split PDF into New Files")
    function show(merge) {
        owner = app.currentReader;
        if (!owner || !owner.pageCount)
            return;
        merging = merge;
        additions = [];
        plan = null;
        error = "";
        planning = false;
        outputDirectory = "";
        ranges.text = owner.pageCount > 1 ? "1-" + Math.ceil(owner.pageCount / 2) + ", " + (Math.ceil(owner.pageCount / 2) + 1) + "-" + owner.pageCount : "1";
        if (owner.pageCount === 2)
            ranges.text = "1, 2";
        every.value = 1;
        splitMode.currentIndex = 0;
        open();
        if (!merge)
            requestPlan();
    }
    function move(index, delta) {
        const next = additions.slice(), target = index + delta;
        if (target < 0 || target >= next.length)
            return;
        const old = next[index];
        next[index] = next[target];
        next[target] = old;
        additions = next;
    }
    function requestPlan() {
        if (merging || !owner || !visible)
            return;
        plan = null;
        error = "";
        planning = true;
        planRequest = owner.submit("split_plan", {
            mode: splitMode.currentIndex === 0 ? "ranges" : "chunks",
            ranges: ranges.text,
            every: every.value,
            directory: app.session ? app.session.localPath(outputDirectory) : ""
        });
    }
    function saveMergeTo(url) {
        if (!owner || !additions.length || owner.hasEditDrafts || !app.session)
            return;
        const others = additions.map(function (file) {
            return app.session.localPath(file);
        });
        owner.submit("save_merge", {
            others: others,
            destination: app.session.localPath(url)
        });
        close();
    }
    function saveSplit() {
        if (!canWrite || merging)
            return;
        owner.submit("save_split", {
            parts: plan.parts
        });
        close();
    }
    Connections {
        target: exportsDialog.owner
        function onCommandFinished(id, op, result, error) {
            if (id !== exportsDialog.planRequest || op !== "split_plan")
                return;
            exportsDialog.planning = false;
            exportsDialog.error = error;
            exportsDialog.plan = error.length ? null : result;
        }
    }
    Connections {
        target: app
        function onCurrentReaderChanged() {
            exportsDialog.close();
            exportsDialog.owner = null;
        }
    }
    Timer {
        id: planTimer
        interval: 250
        onTriggered: exportsDialog.requestPlan()
    }
    FileDialog {
        id: appendPicker
        fileMode: FileDialog.OpenFiles
        title: qsTr("Choose PDFs to Append")
        nameFilters: [qsTr("PDF documents (*.pdf)")]
        onAccepted: {
            const next = exportsDialog.additions.slice();
            for (const file of selectedFiles)
                if (!next.some(function (existing) {
                    return existing.toString() === file.toString();
                }))
                    next.push(file);
            exportsDialog.additions = next;
        }
    }
    FileDialog {
        id: mergeDestination
        fileMode: FileDialog.SaveFile
        title: qsTr("Save Merged PDF with a New Name")
        nameFilters: [qsTr("PDF documents (*.pdf)")]
        onAccepted: exportsDialog.saveMergeTo(selectedFile)
    }
    FolderDialog {
        id: folderPicker
        title: qsTr("Choose Split Output Folder")
        onAccepted: {
            exportsDialog.outputDirectory = selectedFolder;
            exportsDialog.requestPlan();
        }
    }
    ColumnLayout {
        anchors.fill: parent
        Label {
            textFormat: Text.PlainText
            text: exportsDialog.merging ? qsTr("The open document comes first. PDFs below are appended in order. The first outline is kept; appended outlines are not imported. Embedded annotations travel with their pages.") : qsTr("Type disjoint page ranges using the page numbers shown by the reader, or split every N pages. Existing PDFs or annotation sidecars stop the split before writing.")
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        Label {
            textFormat: Text.PlainText
            text: qsTr("LyraReader annotations are carried in adjacent sidecars. Other documents' sidecars are not imported. The open document is unchanged.")
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            color: app.colors.textSecondary
        }
        Label {
            textFormat: Text.PlainText
            visible: exportsDialog.blockedReason.length > 0
            text: exportsDialog.blockedReason
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            color: app.colors.warningFg
        }
        RowLayout {
            visible: exportsDialog.merging
            Layout.fillWidth: true
            Label {
                textFormat: Text.PlainText
                text: qsTr("First: %1").arg(exportsDialog.owner ? exportsDialog.owner.title : "")
                Layout.fillWidth: true
                elide: Text.ElideMiddle
            }
            Button {
                text: qsTr("Add PDFs…")
                onClicked: appendPicker.open()
            }
        }
        ListView {
            visible: exportsDialog.merging
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: exportsDialog.additions
            clip: true
            ScrollBar.vertical: ScrollBar {}
            delegate: RowLayout {
                required property var modelData
                required property int index
                width: ListView.view.width
                Label {
                    textFormat: Text.PlainText
                    text: (index + 2) + ". " + decodeURIComponent(modelData.toString().split('/').pop())
                    Layout.fillWidth: true
                    elide: Text.ElideMiddle
                }
                Button {
                    text: "↑"
                    enabled: index > 0
                    Accessible.name: qsTr("Move PDF up")
                    onClicked: exportsDialog.move(index, -1)
                }
                Button {
                    text: "↓"
                    enabled: index < exportsDialog.additions.length - 1
                    Accessible.name: qsTr("Move PDF down")
                    onClicked: exportsDialog.move(index, 1)
                }
                Button {
                    text: qsTr("Remove")
                    onClicked: {
                        const next = exportsDialog.additions.slice();
                        next.splice(index, 1);
                        exportsDialog.additions = next;
                    }
                }
            }
        }
        RowLayout {
            visible: !exportsDialog.merging
            Layout.fillWidth: true
            ComboBox {
                id: splitMode
                model: [qsTr("Page ranges"), qsTr("Every N pages")]
                onActivated: exportsDialog.requestPlan()
                Accessible.name: qsTr("Split method")
            }
            TextField {
                id: ranges
                objectName: "splitRanges"
                visible: splitMode.currentIndex === 0
                Layout.fillWidth: true
                placeholderText: qsTr("1-5, 6-10")
                onTextEdited: planTimer.restart()
                Accessible.name: qsTr("Split page ranges")
            }
            SpinBox {
                id: every
                objectName: "splitEvery"
                visible: splitMode.currentIndex === 1
                from: 1
                to: exportsDialog.owner ? exportsDialog.owner.pageCount : 1
                editable: true
                onValueModified: exportsDialog.requestPlan()
                Accessible.name: qsTr("Pages per output")
            }
        }
        RowLayout {
            visible: !exportsDialog.merging
            Layout.fillWidth: true
            Label {
                textFormat: Text.PlainText
                text: exportsDialog.outputDirectory.toString() || qsTr("Output beside the source PDF")
                Layout.fillWidth: true
                elide: Text.ElideMiddle
            }
            Button {
                text: qsTr("Choose Folder…")
                onClicked: folderPicker.open()
            }
        }
        BusyIndicator {
            visible: exportsDialog.planning
            running: visible
            Layout.alignment: Qt.AlignHCenter
        }
        Label {
            textFormat: Text.PlainText
            visible: exportsDialog.error.length > 0
            text: exportsDialog.error
            color: app.colors.errorFg
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
        Label {
            textFormat: Text.PlainText
            visible: !!exportsDialog.plan && exportsDialog.plan.conflicts.length > 0
            text: qsTr("One or more output files or sidecars already exist. Choose another folder.")
            color: app.colors.errorFg
            Layout.fillWidth: true
            wrapMode: Text.Wrap
        }
        ListView {
            objectName: "splitOutputList"
            visible: !exportsDialog.merging
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: exportsDialog.plan ? exportsDialog.plan.parts : []
            ScrollBar.vertical: ScrollBar {}
            delegate: Label {
                required property var modelData
                width: ListView.view.width
                padding: 8
                text: qsTr("%1 pages → %2").arg(modelData.pages.length).arg(modelData.destination_path)
                wrapMode: Text.WrapAnywhere
                color: app.colors.textSecondary
            }
        }
        Label {
            textFormat: Text.PlainText
            visible: !exportsDialog.merging
            text: qsTr("Each output is verified independently. If a later write fails, earlier completed files remain and the error reports them.")
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            color: app.colors.textTertiary
            font.pixelSize: 11
        }
        Button {
            objectName: "applyPageExport"
            text: exportsDialog.merging ? qsTr("Choose New Merged File…") : qsTr("Write Split PDFs")
            enabled: exportsDialog.canWrite
            Layout.alignment: Qt.AlignRight
            onClicked: if (exportsDialog.merging)
                mergeDestination.open()
            else
                exportsDialog.saveSplit()
        }
    }
}

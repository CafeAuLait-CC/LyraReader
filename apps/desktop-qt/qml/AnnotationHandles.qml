import QtQuick
import QtQuick.Controls
import "ReaderLogic.js" as Logic

Item {
    id: handles
    required property var app
    required property int page
    readonly property var selected: app.selectedAnnotation
    readonly property var shown: app.annotationDraft && selected && app.annotationDraft.id === selected.id ? app.annotationDraft : selected
    readonly property bool line: shown && (shown.kind === "line" || shown.kind === "arrow")
    visible: !!selected && selected.page === page && Logic.editableGeometry(selected) && app.annotationTool === "select"
    property var base: null
    property var patch: null
    property bool changed: false
    function begin() {
        base = selected;
        changed = false;
        patch = null;
        app.pendingDraftRequestId = -1;
    }
    function resizeAt(index, x, y) {
        if (!base || !selected || base.id !== selected.id)
            return;
        const size = app.currentReader.pages[page];
        const p = {
            x: Math.max(0, Math.min(size.width, x / app.zoom)),
            y: Math.max(0, Math.min(size.height, y / app.zoom))
        };
        let target;
        if (line) {
            patch = index === 0 ? {
                lineStart: p,
                lineEnd: base.lineEnd
            } : {
                lineStart: base.lineStart,
                lineEnd: p
            };
            target = {
                x: Math.min(patch.lineStart.x, patch.lineEnd.x),
                y: Math.min(patch.lineStart.y, patch.lineEnd.y),
                width: Math.max(.1, Math.abs(patch.lineStart.x - patch.lineEnd.x)),
                height: Math.max(.1, Math.abs(patch.lineStart.y - patch.lineEnd.y))
            };
        } else {
            const r = base.rect;
            const left = index === 0 || index === 2, top = index < 2;
            const x1 = left ? Math.min(p.x, r.x + r.width - 2) : r.x;
            const y1 = top ? Math.min(p.y, r.y + r.height - 2) : r.y;
            const x2 = left ? r.x + r.width : Math.max(p.x, r.x + 2);
            const y2 = top ? r.y + r.height : Math.max(p.y, r.y + 2);
            target = {
                x: x1,
                y: y1,
                width: x2 - x1,
                height: y2 - y1
            };
            patch = Logic.geometryPatch(base, target);
        }
        changed = true;
        app.annotationDraft = Object.assign({}, base, patch, {
            rect: target
        });
    }
    function finish() {
        if (changed && app.annotationDraft && base && selected && base.id === selected.id)
            app.commitAnnotationGeometry(base.id, patch);
        base = null;
        patch = null;
    }
    function cancel() {
        app.annotationDraft = null;
        base = null;
        patch = null;
    }
    Repeater {
        model: handles.visible ? (handles.line ? 2 : 4) : 0
        Rectangle {
            id: grip
            required property int index
            objectName: "annotationHandle" + index
            readonly property var position: !handles.shown || !handles.shown.rect ? ({
                    x: 0,
                    y: 0
                }) : handles.line ? (index === 0 ? handles.shown.lineStart : handles.shown.lineEnd) : ({
                    x: handles.shown.rect.x + (index % 2 ? handles.shown.rect.width : 0),
                    y: handles.shown.rect.y + (index >= 2 ? handles.shown.rect.height : 0)
                })
            x: position.x * app.zoom - width / 2
            y: position.y * app.zoom - height / 2
            width: 10
            height: 10
            radius: handles.line ? 5 : 2
            color: app.colors.raisedBg
            border.color: app.colors.focusRing
            border.width: 1.5
            Accessible.role: Accessible.Button
            Accessible.name: handles.line ? qsTr("Line endpoint %1").arg(index + 1) : qsTr("Annotation resize corner %1").arg(index + 1)
            MouseArea {
                anchors.fill: parent
                anchors.margins: -5
                preventStealing: pressed
                cursorShape: handles.line ? Qt.CrossCursor : (grip.index === 0 || grip.index === 3 ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor)
                onPressed: {
                    forceActiveFocus();
                    handles.begin();
                }
                onPositionChanged: function (mouse) {
                    if (!pressed)
                        return;
                    const point = mapToItem(handles, mouse.x, mouse.y);
                    handles.resizeAt(grip.index, point.x, point.y);
                }
                onReleased: handles.finish()
                onCanceled: handles.cancel()
                Keys.onEscapePressed: handles.cancel()
            }
        }
    }
}

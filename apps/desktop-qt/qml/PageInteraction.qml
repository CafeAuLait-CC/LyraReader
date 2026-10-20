import QtQuick
import QtQuick.Controls
import "ReaderLogic.js" as Logic

Item {
    id: annotationLayer
    required property var app
    required property int page
    readonly property var textPage: app.currentReader.textPages[page.toString()] || {
        chars: [],
        text: ""
    }
    readonly property var selectedRects: app.selection && app.selection.page === page ? Logic.quads(textPage.chars, app.selection.start, app.selection.end) : []
    readonly property var searchRects: app.activeSearchHit && app.activeSearchHit.page === page ? Logic.quads(textPage.chars, app.activeSearchHit.start, app.activeSearchHit.end - 1) : []
    Component.onCompleted: app.currentReader.requestText(page)
    Repeater {
        model: annotationLayer.searchRects
        Rectangle {
            required property var modelData
            x: modelData.x * app.zoom
            y: modelData.y * app.zoom
            width: modelData.width * app.zoom
            height: modelData.height * app.zoom
            color: app.colors.searchCurrentBg
            opacity: 0.55
            border.width: 1
            border.color: app.colors.accentBorder
        }
    }
    Repeater {
        model: annotationLayer.selectedRects
        Rectangle {
            required property var modelData
            x: modelData.x * app.zoom
            y: modelData.y * app.zoom
            width: modelData.width * app.zoom
            height: modelData.height * app.zoom
            color: app.colors.textSelectionBg
            opacity: 0.55
        }
    }
    MouseArea {
        id: pointer
        objectName: "pdfPointer"
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: app.annotationTool === "select" || ["highlight", "underline", "strikeout"].indexOf(app.annotationTool) >= 0 ? Qt.IBeamCursor : Qt.CrossCursor
        hoverEnabled: true
        property int start: -1
        property real pressX: 0
        property real pressY: 0
        property bool dragged: false
        property string gestureTool: "select"
        property var points: []
        property var previousPoint: null
        property var editBase: null
        property var keyBase: null
        property var keyOwner: null
        activeFocusOnTab: true
        Accessible.role: Accessible.Canvas
        Accessible.name: qsTr("Page %1").arg(page + 1)
        Accessible.description: qsTr("Select an annotation, then use arrow keys to move it, Control and arrow keys to resize, or Shift for ten-point steps. Escape cancels.")
        function finishKeyboardEdit() {
            if (!keyBase)
                return;
            const base = keyBase;
            keyBase = null;
            if (keyOwner === app.currentReader && app.selectedAnnotation && app.selectedAnnotation.id === base.id && app.annotationDraft && app.annotationDraft.id === base.id)
                app.commitAnnotationGeometry(base.id, Logic.geometryPatch(base, app.annotationDraft.rect));
            keyOwner = null;
        }
        onActiveFocusChanged: if (!activeFocus)
            finishKeyboardEdit()
        Keys.onPressed: function (event) {
            const arrows = [Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down];
            if (arrows.indexOf(event.key) < 0 || event.modifiers & (Qt.AltModifier | Qt.MetaModifier) || app.annotationTool !== "select")
                return;
            const selected = app.selectedAnnotation;
            if (!selected || selected.page !== page || !Logic.editableGeometry(selected))
                return;
            event.accepted = true;
            if (!keyBase) {
                if (app.currentReader.pendingCommands > 0)
                    return;
                keyBase = selected;
                keyOwner = app.currentReader;
                app.pendingDraftRequestId = -1;
            }
            if (keyOwner !== app.currentReader || selected.id !== keyBase.id)
                return;
            const previous = app.annotationDraft && app.annotationDraft.id === keyBase.id ? app.annotationDraft.rect : keyBase.rect;
            const step = event.modifiers & Qt.ShiftModifier ? 10 : 1;
            const dx = event.key === Qt.Key_Left ? -step : event.key === Qt.Key_Right ? step : 0;
            const dy = event.key === Qt.Key_Up ? -step : event.key === Qt.Key_Down ? step : 0;
            const size = app.currentReader.pages[page];
            const target = event.modifiers & Qt.ControlModifier ? {
                x: previous.x,
                y: previous.y,
                width: Math.min(size.width - previous.x, Math.max(2, previous.width + dx)),
                height: Math.min(size.height - previous.y, Math.max(2, previous.height + dy))
            } : Logic.translatedRect(previous, dx, dy, size);
            app.annotationDraft = Object.assign({}, keyBase, Logic.geometryPatch(keyBase, target), {
                rect: target
            });
        }
        Keys.onReleased: function (event) {
            if (keyBase && [Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down].indexOf(event.key) >= 0) {
                event.accepted = true;
                if (!event.isAutoRepeat)
                    finishKeyboardEdit();
            }
        }
        preventStealing: pressed
        function position(mouse) {
            const size = app.currentReader.pages[page];
            return {
                x: Math.max(0, Math.min(size.width, mouse.x / app.zoom)),
                y: Math.max(0, Math.min(size.height, mouse.y / app.zoom))
            };
        }
        function draw(p) {
            const first = {
                x: pressX / app.zoom,
                y: pressY / app.zoom
            };
            const entry = {
                kind: gestureTool,
                page: page,
                version: 1,
                color: app.brushColor + "ff",
                note: "",
                strokeWidth: app.brushWidth
            };
            if (gestureTool === "ink") {
                const last = points[points.length - 1];
                if (!last || Math.hypot(last.x - p.x, last.y - p.y) > .4)
                    points.push(p);
                if (points.length > 12000)
                    points = points.filter(function (v, i) {
                        return i % 2 === 0;
                    });
                entry.paths = [points.slice()];
            } else if (gestureTool === "line" || gestureTool === "arrow") {
                entry.lineStart = first;
                entry.lineEnd = p;
            } else
                entry.rect = {
                    x: Math.min(first.x, p.x),
                    y: Math.min(first.y, p.y),
                    width: Math.abs(first.x - p.x),
                    height: Math.abs(first.y - p.y)
                };
            if (gestureTool === "redact")
                app.redactionDraft = {
                    page: page,
                    rect: entry.rect
                };
            else
                app.annotationDraft = entry;
        }
        onPressed: function (mouse) {
            if (mouse.button === Qt.RightButton) {
                app.showSelectionMenu(annotationLayer, page, mouse.x, mouse.y);
                return;
            }
            forceActiveFocus();
            pressX = mouse.x;
            pressY = mouse.y;
            dragged = false;
            gestureTool = app.annotationTool;
            points = [];
            app.pendingDraftRequestId = -1;
            const p = position(mouse);
            previousPoint = p;
            if (gestureTool === "redact" && !app.canRedact) {
                gestureTool = "canceled";
                return;
            }
            editBase = null;
            if (gestureTool === "select") {
                const hit = app.annotationAt(page, p.x, p.y, false);
                if (Logic.editableGeometry(hit)) {
                    editBase = hit;
                    app.selectAnnotation(hit, false);
                    app.selection = null;
                    gestureTool = "move";
                    return;
                }
            }
            if (["ink", "square", "circle", "line", "arrow", "redact"].indexOf(gestureTool) >= 0) {
                app.selection = null;
                points = [p];
                draw(p);
                return;
            }
            if (gestureTool === "eraser") {
                app.selection = null;
                app.eraseDraft = [];
                app.eraseAlong(page, p, p);
                return;
            }
            start = Logic.nearestCharacter(annotationLayer.textPage.chars, p.x, p.y);
            if (start >= 0)
                app.selection = {
                    page: page,
                    start: start,
                    end: start
                };
        }
        Keys.onEscapePressed: {
            gestureTool = "canceled";
            editBase = null;
            keyBase = null;
            keyOwner = null;
            app.annotationDraft = null;
            app.redactionDraft = null;
            app.selectedAnnotation = null;
            app.selection = null;
        }
        onPositionChanged: function (mouse) {
            if (gestureTool === "canceled")
                return;
            const p = position(mouse);
            if (!(pressedButtons & Qt.LeftButton))
                return;
            if (Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) > 3)
                dragged = true;
            if (gestureTool === "move") {
                if (!app.selectedAnnotation || app.selectedAnnotation.id !== editBase.id)
                    return;
                const target = Logic.translatedRect(editBase.rect, p.x - pressX / app.zoom, p.y - pressY / app.zoom, app.currentReader.pages[page]);
                app.annotationDraft = Object.assign({}, editBase, Logic.geometryPatch(editBase, target), {
                    rect: target
                });
                return;
            }
            if (["ink", "square", "circle", "line", "arrow", "redact"].indexOf(gestureTool) >= 0) {
                draw(p);
                return;
            }
            if (gestureTool === "eraser") {
                app.eraseAlong(page, previousPoint, p);
                previousPoint = p;
                return;
            }
            const end = Logic.nearestCharacter(annotationLayer.textPage.chars, p.x, p.y);
            if (start >= 0 && end >= 0)
                app.selection = {
                    page: page,
                    start: start,
                    end: end
                };
        }
        onReleased: function (mouse) {
            if (mouse.button !== Qt.LeftButton || gestureTool === "canceled")
                return;
            if (gestureTool === "move") {
                if (dragged && app.annotationDraft)
                    app.commitAnnotationGeometry(editBase.id, Logic.geometryPatch(editBase, app.annotationDraft.rect));
                else
                    app.annotationDraft = null;
                return;
            }
            if (["ink", "square", "circle", "line", "arrow", "redact"].indexOf(gestureTool) >= 0) {
                if (!dragged) {
                    app.annotationDraft = null;
                    app.redactionDraft = null;
                    return;
                }
                if (gestureTool === "redact") {
                    if (app.redactionDraft)
                        app.addRedaction(page, app.redactionDraft.rect);
                    app.redactionDraft = null;
                    return;
                }
                const entry = app.annotationDraft;
                if (entry && (gestureTool !== "ink" || points.length > 1))
                    app.pendingDraftRequestId = app.currentReader.submit("mark_create", {
                        entry: entry
                    });
                return;
            }
            if (gestureTool === "eraser") {
                app.commitErase();
                return;
            }
            if (!dragged) {
                const scene = annotationLayer.mapToItem(null, mouse.x, mouse.y);
                app.pageClicked(page, mouse.x / app.zoom, mouse.y / app.zoom, scene.x, scene.y);
            } else
                app.selectionFinished();
        }
        onCanceled: {
            app.annotationDraft = null;
            app.redactionDraft = null;
            app.eraseDraft = [];
        }
        onDoubleClicked: function (mouse) {
            const hit = app.annotationAt(page, mouse.x / app.zoom, mouse.y / app.zoom, false);
            if (hit) {
                app.selectAnnotation(hit);
                return;
            }
            const chars = annotationLayer.textPage.chars;
            const at = Logic.nearestCharacter(chars, mouse.x / app.zoom, mouse.y / app.zoom);
            if (at < 0)
                return;
            let first = at, last = at;
            const word = function (i) {
                return i >= 0 && i < chars.length && !/\s/.test(String.fromCodePoint(chars[i].unicode || 32));
            };
            while (word(first - 1))
                --first;
            while (word(last + 1))
                ++last;
            app.selection = {
                page: page,
                start: first,
                end: last
            };
            app.selectionFinished();
        }
    }
    AnnotationHandles {
        focusTarget: pointer
        anchors.fill: parent
        app: annotationLayer.app
        page: annotationLayer.page
    }
}

import QtQuick
import QtQuick.Controls
import "ReaderLogic.js" as Logic

Item {
    id: layer
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
        model: layer.searchRects
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
        model: layer.selectedRects
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
            app.annotationDraft = entry;
        }
        onPressed: function (mouse) {
            if (mouse.button === Qt.RightButton) {
                app.showSelectionMenu(layer, page, mouse.x, mouse.y);
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
            if (["ink", "square", "circle", "line", "arrow"].indexOf(gestureTool) >= 0) {
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
            start = Logic.nearestCharacter(layer.textPage.chars, p.x, p.y);
            if (start >= 0)
                app.selection = {
                    page: page,
                    start: start,
                    end: start
                };
        }
        onPositionChanged: function (mouse) {
            const p = position(mouse);
            if (!(pressedButtons & Qt.LeftButton))
                return;
            if (Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) > 3)
                dragged = true;
            if (["ink", "square", "circle", "line", "arrow"].indexOf(gestureTool) >= 0) {
                draw(p);
                return;
            }
            if (gestureTool === "eraser") {
                app.eraseAlong(page, previousPoint, p);
                previousPoint = p;
                return;
            }
            const end = Logic.nearestCharacter(layer.textPage.chars, p.x, p.y);
            if (start >= 0 && end >= 0)
                app.selection = {
                    page: page,
                    start: start,
                    end: end
                };
        }
        onReleased: function (mouse) {
            if (mouse.button !== Qt.LeftButton)
                return;
            if (["ink", "square", "circle", "line", "arrow"].indexOf(gestureTool) >= 0) {
                if (!dragged) {
                    app.annotationDraft = null;
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
            if (!dragged)
                app.pageClicked(page, mouse.x / app.zoom, mouse.y / app.zoom);
            else
                app.selectionFinished();
        }
        onCanceled: {
            app.annotationDraft = null;
            app.eraseDraft = [];
        }
        onDoubleClicked: function (mouse) {
            const hit = app.annotationAt(page, mouse.x / app.zoom, mouse.y / app.zoom, false);
            if (hit) {
                app.selectAnnotation(hit);
                return;
            }
            const chars = layer.textPage.chars;
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
}

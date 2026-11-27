import QtQuick
import QtQuick.Controls

Item {
    id: flag
    required property var app
    required property int page
    required property Item viewport
    property var placementRevision: null
    property var creation: null
    readonly property var bookmark: app.bookmarks.find(function(value) { return value.page === page; }) || null
    readonly property rect viewportFrame: {
        // mapToItem has no change notification for ancestors. The canvas supplies
        // its actual row placement, scroll and paper-motion dependencies.
        const revision = placementRevision;
        const point = mapToItem(viewport, 0, 0);
        return Qt.rect(point.x, point.y, width, height);
    }
    readonly property bool inViewport: viewportFrame.x < viewport.width && viewportFrame.x + width > 0
        && viewportFrame.y < viewport.height && viewportFrame.y + height > 0
    readonly property bool contextCurrent: app.currentReader && !app.currentReader.loading
        && !app.currentReader.documentRevisionPending && page < app.currentReader.pageCount
    objectName: "pageBookmarkHover" + page
    width: 60
    height: 56
    visible: contextCurrent && inViewport

    function creationCurrent(context) {
        return context && visible && contextCurrent && context.owner === app.currentReader
            && context.generation === context.owner.documentGeneration
            && context.interaction === viewport.interactionEpoch
            && Math.abs(context.x - viewportFrame.x) < 0.5
            && Math.abs(context.y - viewportFrame.y) < 0.5;
    }
    function activate() {
        if (!visible || !contextCurrent || creation) return;
        if (bookmark) {
            app.editPageBookmarkAt(bookmark, app.bookmarks.indexOf(bookmark), button);
            return;
        }
        const owner = app.currentReader;
        const context = {owner: owner, generation: owner.documentGeneration,
            interaction: viewport.interactionEpoch, x: viewportFrame.x, y: viewportFrame.y,
            ids: app.bookmarks.map(function(value) { return value.id; }), request: -1};
        context.request = owner.submit("bookmark_create", {page: page, yPt: 0});
        creation = context;
    }
    Connections {
        target: flag.app
        function onCurrentReaderChanged() { flag.creation = null; }
    }
    Connections {
        target: flag.creation ? flag.creation.owner : null
        function onDocumentChanged() {
            if (flag.creation && !flag.creationCurrent(flag.creation)) flag.creation = null;
        }
        function onCommandFinished(id, operation, result, error) {
            const context = flag.creation;
            if (!context || id !== context.request || operation !== "bookmark_create") return;
            const current = flag.creationCurrent(context);
            flag.creation = null;
            if (!current) return;
            if (error.length) { flag.app.operationStatus = error; return; }
            // bookmark_create appends in the shared manual order. Use this exact
            // command's snapshot, never a later mutable Reader query.
            const values = result.bookmarks || [];
            const created = values.length === context.ids.length + 1 ? values[values.length - 1] : null;
            if (!created || typeof created.id !== "string" || !created.id.length
                    || created.page !== flag.page || context.ids.indexOf(created.id) >= 0
                    || !context.ids.every(function(value, index) { return values[index].id === value; })) {
                flag.app.operationStatus = qsTr("The bookmark was created. Open it again to edit its name.");
                return;
            }
            flag.app.editPageBookmarkAt(created, values.length - 1, button);
        }
    }
    HoverHandler { id: hover }
    ToolButton {
        id: button
        objectName: "pageBookmarkButton" + flag.page
        x: 28
        width: 22
        height: 36
        padding: 0
        display: AbstractButton.IconOnly
        hoverEnabled: true
        visible: !!flag.bookmark || hover.hovered
        activeFocusOnTab: visible && flag.inViewport
        enabled: flag.contextCurrent && !flag.creation
        text: flag.bookmark ? qsTr("Edit bookmark on page %1").arg(flag.page + 1)
                            : qsTr("Bookmark page %1").arg(flag.page + 1)
        icon.source: "qrc:/icons/page-bookmark.svg"
        icon.width: 22
        icon.height: 36
        icon.color: Qt.rgba(flag.app.colors.accent.r, flag.app.colors.accent.g,
                           flag.app.colors.accent.b, flag.bookmark ? 1 : 0.45)
        background: Rectangle {
            color: "transparent"
            radius: 2
            border.width: button.visualFocus ? 2 : 0
            border.color: flag.app.colors.focusRing
        }
        Accessible.name: text
        ToolTip.visible: hovered
        ToolTip.text: text
        ToolTip.delay: 500
        onClicked: flag.activate()
    }
}

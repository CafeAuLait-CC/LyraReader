import QtQuick

ReadingWheelHandler {
    id: handler
    required property Flickable viewport
    parent: viewport
    enabled: !!viewport
    zoomEnabled: false
    signal scrollIntent(real dx, real dy)
    onScrollRequested: function(dx, dy) {
        viewport.cancelFlick();
        handler.scrollIntent(dx, dy);
        const left = viewport.originX - viewport.leftMargin;
        const top = viewport.originY - viewport.topMargin;
        const right = Math.max(left, viewport.originX + viewport.contentWidth - viewport.width + viewport.rightMargin);
        const bottom = Math.max(top, viewport.originY + viewport.contentHeight - viewport.height + viewport.bottomMargin);
        viewport.contentX = Math.max(left, Math.min(right, viewport.contentX - dx));
        const y = Math.max(top, Math.min(bottom, viewport.contentY - dy));
        // Virtual lists estimate unseen delegate heights. Let their own edge
        // positioning resolve the final row rather than retaining that estimate.
        if (dy < 0 && y >= bottom && typeof viewport.positionViewAtEnd === "function") {
            viewport.positionViewAtEnd();
            viewport.forceLayout();
            viewport.contentY = Math.max(viewport.originY - viewport.topMargin,
                viewport.originY + viewport.contentHeight - viewport.height + viewport.bottomMargin);
        } else
            viewport.contentY = y;
    }
}

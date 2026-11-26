import QtQuick

WheelHandler {
    id: handler
    property bool scrollEnabled: true
    property bool zoomEnabled: true
    property bool horizontalOnly: false
    orientation: horizontalOnly ? Qt.Horizontal : Qt.Vertical
    signal scrollRequested(real dx, real dy)
    signal zoomRequested(real factor, real x, real y)
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: function(event) {
        const precise = event.pixelDelta.x !== 0 || event.pixelDelta.y !== 0;
        if (event.modifiers & Qt.ControlModifier) {
            if (!handler.zoomEnabled) {
                event.accepted = false;
                return;
            }
            const delta = precise ? event.pixelDelta.y : event.angleDelta.y;
            handler.zoomRequested(Math.pow(1.0015, delta), event.x, event.y);
        } else if (handler.scrollEnabled) {
            // macOS WheelMotion uses 25 screen points per system line. Qt gives
            // 120 angle units per detent and the platform's lines-per-detent hint.
            const unit = 25 * Qt.styleHints.wheelScrollLines / 120;
            let dx = precise ? event.pixelDelta.x : event.angleDelta.x * unit;
            let dy = precise ? event.pixelDelta.y : event.angleDelta.y * unit;
            if ((event.modifiers & Qt.ShiftModifier) && dx === 0) {
                dx = dy;
                dy = 0;
            }
            if (handler.horizontalOnly) {
                if (dx === 0) { event.accepted = false; return; }
                dy = 0;
            }
            handler.scrollRequested(dx, dy);
        } else {
            event.accepted = false;
            return;
        }
        event.accepted = true;
    }
}

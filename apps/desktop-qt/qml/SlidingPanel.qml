import QtQuick
import QtQuick.Layouts

Item {
    id: drawer
    default property alias content: body.data
    property bool expanded: false
    property bool leading: false
    property bool reduceMotion: false
    property real panelWidth: 250
    property real progress: 0
    // Deterministic geometry seam, matching the Mac transition checks. The app
    // leaves this at -1; a check can pin an intermediate frame without vsync.
    property real progressOverride: -1
    readonly property real reveal: progressOverride >= 0 ? Math.max(0, Math.min(1, progressOverride)) : progress
    readonly property bool moving: slide.running || (progressOverride > 0 && progressOverride < 1)
    property bool initialized: false
    implicitWidth: panelWidth * reveal
    Layout.minimumWidth: 0
    Layout.preferredWidth: implicitWidth
    Layout.maximumWidth: implicitWidth
    Layout.fillHeight: true
    clip: true
    visible: expanded || reveal > 0
    Accessible.ignored: !expanded

    function move() {
        if (!initialized) return;
        slide.stop();
        const target = expanded ? 1 : 0;
        if (reduceMotion || progressOverride >= 0 || Math.abs(progress - target) < .000001) {
            progress = target;
        } else {
            slide.to = target;
            slide.start();
        }
    }
    onExpandedChanged: move()
    onReduceMotionChanged: move()
    onProgressOverrideChanged: move()
    Component.onCompleted: { progress = expanded ? 1 : 0; initialized = true; }

    property Item contentHost: FocusScope {
        id: body
        parent: drawer
        width: drawer.panelWidth
        height: drawer.height
        // Left content slides behind the leading edge; right content stays at
        // the clipped column's leading edge as that column enters from the right.
        x: drawer.leading ? drawer.width - width : 0
        enabled: drawer.expanded
    }
    property NumberAnimation animation: NumberAnimation {
        id: slide
        target: drawer
        property: "progress"
        duration: 220
        easing.type: Easing.OutCubic
    }
}

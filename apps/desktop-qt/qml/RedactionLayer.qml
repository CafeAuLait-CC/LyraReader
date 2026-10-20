import QtQuick
import QtQuick.Controls

Item {
    id: redactions
    required property var app
    required property int page
    Repeater {
        model: app.pendingRedactions.filter(function (area) {
            return area.page === redactions.page;
        })
        Rectangle {
            required property var modelData
            x: modelData.x_pt * app.zoom
            y: modelData.y_pt * app.zoom
            width: modelData.width_pt * app.zoom
            height: modelData.height_pt * app.zoom
            color: app.colors.warningBg
            opacity: .55
            border.color: app.colors.errorFg
            border.width: 1.5
            Accessible.name: qsTr("Pending redaction; content has not been removed")
        }
    }
    Rectangle {
        visible: !!app.redactionDraft && app.redactionDraft.page === redactions.page
        x: app.redactionDraft ? app.redactionDraft.rect.x * app.zoom : 0
        y: app.redactionDraft ? app.redactionDraft.rect.y * app.zoom : 0
        width: app.redactionDraft ? app.redactionDraft.rect.width * app.zoom : 0
        height: app.redactionDraft ? app.redactionDraft.rect.height * app.zoom : 0
        color: "transparent"
        border.color: app.colors.errorFg
        border.width: 2
    }
}

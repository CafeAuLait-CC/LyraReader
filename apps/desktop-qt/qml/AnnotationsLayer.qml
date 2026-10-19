import QtQuick
import QtQuick.Controls
import LyraReader 1.0
import "ReaderLogic.js" as Logic

Item {
    id: layer
    required property var app
    required property int page
    property real zoom: app.zoom
    property bool ownOnly: false
    readonly property var marks: {
        const values = app.annotations.filter(function (a) {
            return a.page === page && a.visible && (!ownOnly || !a.foreign) && app.eraseDraft.indexOf(a.id) < 0;
        });
        return values;
    }
    clip: true
    PdfAnnotations {
        anchors.fill: parent
        annotations: layer.marks
        zoom: layer.zoom
        paperAppearance: app.paperAppearance
        selectedId: ownOnly ? "" : (app.selectedAnnotation ? app.selectedAnnotation.id : "")
    }
    PdfAnnotations {
        anchors.fill: parent
        annotations: app.annotationDraft && app.annotationDraft.page === layer.page ? [app.annotationDraft] : []
        zoom: layer.zoom
        paperAppearance: app.paperAppearance
    }
    Repeater {
        model: layer.marks.filter(function (a) {
            return a.kind === "stickyNote" || a.kind === "textBox";
        })
        Item {
            required property var modelData
            x: modelData.rect.x * layer.zoom
            y: modelData.rect.y * layer.zoom
            width: modelData.rect.width * layer.zoom
            height: modelData.rect.height * layer.zoom
            Rectangle {
                visible: modelData.kind === "stickyNote"
                anchors.fill: parent
                radius: Math.min(3, parent.width / 6)
                color: app.colors.noteBg
                border.color: app.colors.noteFg
                Label {
                    anchors.centerIn: parent
                    text: "✎"
                    font.pixelSize: Math.max(6, Math.min(18, parent.height * .7))
                    color: app.colors.noteFg
                }
            }
            Text {
                anchors.fill: parent
                visible: modelData.kind === "textBox"
                text: modelData.note || ""
                textFormat: Text.PlainText
                color: Logic.displayColor(Logic.color(modelData), app.paperAppearance)
                font.pixelSize: Math.max(1, (modelData.fontSize || 14) * layer.zoom)
                font.family: app.annotationFont
                wrapMode: Text.Wrap
                clip: true
                horizontalAlignment: modelData.textAlignment === "center" ? Text.AlignHCenter : modelData.textAlignment === "right" ? Text.AlignRight : Text.AlignLeft
            }
        }
    }
}

import QtQuick
import QtQuick.Controls
import LyraReader 1.0
import "ReaderLogic.js" as Logic

Item {
    id: annotationLayer
    required property var app
    required property int page
    property real zoom: app.zoom
    property bool ownOnly: false
    property rect visibleRegion: Qt.rect(0, 0, width / zoom, height / zoom)
    readonly property var marks: {
        const values = app.annotations.filter(function (a) {
            return a.page === page && a.visible && (!ownOnly || !a.foreign) && app.eraseDraft.indexOf(a.id) < 0;
        });
        return values.map(function (a) {
            return app.annotationDraft && app.annotationDraft.id === a.id ? app.annotationDraft : a;
        }).concat(app.erasePreview.filter(function (a) { return a.page === page; }));
    }
    clip: true
    PdfAnnotations {
        anchors.fill: parent
        annotations: annotationLayer.marks
        zoom: annotationLayer.zoom
        paperAppearance: app.paperAppearance
        selectedId: ownOnly ? "" : (app.selectedAnnotation ? app.selectedAnnotation.id : "")
    }
    PdfAnnotations {
        anchors.fill: parent
        annotations: app.annotationDraft && !app.annotationDraft.id && app.annotationDraft.page === annotationLayer.page ? [app.annotationDraft] : []
        zoom: annotationLayer.zoom
        paperAppearance: app.paperAppearance
    }
    Repeater {
        model: app.annotations.filter(function (a) {
            return a.page === page && a.visible && (!ownOnly || !a.foreign) && (a.kind === "stamp" || a.kind === "signature");
        })
        Item {
            required property var modelData
            readonly property var artwork: app.annotationDraft && app.annotationDraft.id === modelData.id ? app.annotationDraft : modelData
            objectName: "artwork" + artwork.id
            x: artwork.rect.x * annotationLayer.zoom
            y: artwork.rect.y * annotationLayer.zoom
            width: artwork.rect.width * annotationLayer.zoom
            height: artwork.rect.height * annotationLayer.zoom
            readonly property color ink: Logic.displayColor(Logic.color(artwork), app.paperAppearance)
            visible: artwork.rect.x < annotationLayer.visibleRegion.x + annotationLayer.visibleRegion.width && artwork.rect.x + artwork.rect.width > annotationLayer.visibleRegion.x && artwork.rect.y < annotationLayer.visibleRegion.y + annotationLayer.visibleRegion.height && artwork.rect.y + artwork.rect.height > annotationLayer.visibleRegion.y
            Accessible.role: Accessible.Graphic
            Accessible.name: artwork.kind === "stamp" ? qsTr("%1 stamp on page %2").arg(artwork.note).arg(page + 1) : qsTr("Signature image on page %1").arg(page + 1)
            Accessible.selectable: true
            Accessible.selected: !!app.selectedAnnotation && app.selectedAnnotation.id === artwork.id
            Accessible.onPressAction: if (visible)
                app.selectAnnotation(artwork, false)
            Rectangle {
                anchors.fill: parent
                visible: artwork.kind === "stamp"
                color: "transparent"
                border.color: parent.ink
                border.width: Math.min(2, Math.max(.75, artwork.rect.height * .035)) * annotationLayer.zoom
                Text {
                    Accessible.ignored: true
                    anchors.fill: parent
                    anchors.margins: (Math.min(2, Math.max(.75, artwork.rect.height * .035)) + 3) * annotationLayer.zoom
                    text: String(artwork.note || "").trim().replace(/\s+/g, " ")
                    textFormat: Text.PlainText
                    color: parent.border.color
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    font.family: app.annotationFont
                    font.pixelSize: Math.max(1, Math.round(artwork.rect.height * .56 * annotationLayer.zoom))
                    fontSizeMode: Text.Fit
                    minimumPixelSize: 1
                    wrapMode: Text.NoWrap
                    clip: true
                }
            }
            PdfCrop {
                id: signatureCrop
                objectName: "signatureArt" + artwork.id
                anchors.fill: parent
                visible: artwork.kind === "signature"
                resourceActive: parent.visible && visible
                // Geometry drafts must not rebuild a potentially large data URL.
                source: modelData.image ? "data:image/png;base64," + modelData.image : ""
                paperAppearance: app.paperAppearance
                opacity: Logic.color(artwork).a
            }
            Text {
                anchors.fill: parent
                visible: artwork.kind === "signature" && signatureCrop.status === 3
                text: qsTr("Image could not be decoded")
                textFormat: Text.PlainText
                color: app.colors.textSecondary
                wrapMode: Text.Wrap
                font.pixelSize: Math.max(8, 11 * annotationLayer.zoom)
            }
        }
    }
    Repeater {
        model: annotationLayer.marks.filter(function (a) {
            return a.kind === "stickyNote" || a.kind === "textBox";
        })
        Item {
            required property var modelData
            x: modelData.rect.x * annotationLayer.zoom
            y: modelData.rect.y * annotationLayer.zoom
            width: modelData.rect.width * annotationLayer.zoom
            height: modelData.rect.height * annotationLayer.zoom
            Rectangle {
                visible: modelData.kind === "stickyNote"
                anchors.fill: parent
                radius: Math.min(3, parent.width / 6)
                color: app.colors.noteBg
                border.color: app.colors.noteFg
                Label {
                    textFormat: Text.PlainText
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
                font.pixelSize: Math.max(1, Math.round((modelData.fontSize || 14) * annotationLayer.zoom))
                font.family: app.annotationFont
                wrapMode: Text.Wrap
                clip: true
                horizontalAlignment: modelData.textAlignment === "center" ? Text.AlignHCenter : modelData.textAlignment === "right" ? Text.AlignRight : Text.AlignLeft
            }
        }
    }
}

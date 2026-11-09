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
    property var paperMap: null
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
        paperMap: annotationLayer.paperMap
    }
    PdfAnnotations {
        anchors.fill: parent
        annotations: app.annotationDraft && !app.annotationDraft.id && app.annotationDraft.page === annotationLayer.page ? [app.annotationDraft] : []
        zoom: annotationLayer.zoom
        paperAppearance: app.paperAppearance
        paperMap: annotationLayer.paperMap
    }
    Repeater {
        model: app.annotations.filter(function (a) {
            return a.page === page && a.visible && (!ownOnly || !a.foreign) && (a.kind === "stamp" || a.kind === "signature");
        })
        Item {
            id: artworkDelegate
            required property var modelData
            readonly property var artwork: app.annotationDraft && app.annotationDraft.id === modelData.id ? app.annotationDraft : modelData
            readonly property bool torn: !!annotationLayer.paperMap && annotationLayer.paperMap.paperGeometryActive
            PaperRegion {
                id: artworkGeometry
                app: annotationLayer.app
                paperMap: annotationLayer.paperMap
                sourceRect: Qt.rect(artwork.rect.x,artwork.rect.y,artwork.rect.width,artwork.rect.height)
            }
            objectName: "artwork" + artwork.id
            x: displayBounds.x * annotationLayer.zoom
            y: displayBounds.y * annotationLayer.zoom
            width: displayBounds.width * annotationLayer.zoom
            height: displayBounds.height * annotationLayer.zoom
            readonly property color ink: Logic.displayColor(Logic.color(artwork), app.paperAppearance)
            readonly property rect displayBounds: artworkGeometry.bounds
            visible: artworkGeometry.hit && displayBounds.x < annotationLayer.visibleRegion.x + annotationLayer.visibleRegion.width && displayBounds.x + displayBounds.width > annotationLayer.visibleRegion.x && displayBounds.y < annotationLayer.visibleRegion.y + annotationLayer.visibleRegion.height && displayBounds.y + displayBounds.height > annotationLayer.visibleRegion.y
            Accessible.role: Accessible.Graphic
            Accessible.name: artwork.kind === "stamp" ? qsTr("%1 stamp on page %2").arg(artwork.note).arg(page + 1) : qsTr("Signature image on page %1").arg(page + 1)
            Accessible.selectable: true
            Accessible.selected: !!app.selectedAnnotation && app.selectedAnnotation.id === artwork.id
            Accessible.onPressAction: if (visible)
                app.selectAnnotation(artwork, false)
            Component {
                id: stampPaint
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.color: artworkDelegate.ink
                    border.width: Math.min(2, Math.max(.75, artworkDelegate.artwork.rect.height * .035)) * annotationLayer.zoom
                    Text {
                        objectName: "staticStampText"
                        Accessible.ignored: true
                        anchors.fill: parent
                        anchors.margins: (Math.min(2, Math.max(.75, artworkDelegate.artwork.rect.height * .035)) + 3) * annotationLayer.zoom
                        text: String(artworkDelegate.artwork.note || "").trim().replace(/\s+/g, " ")
                        textFormat: Text.PlainText
                        color: parent.border.color
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        font.family: app.annotationFont
                        font.pixelSize: Math.max(1, Math.round(artworkDelegate.artwork.rect.height * .56 * annotationLayer.zoom))
                        fontSizeMode: Text.Fit
                        minimumPixelSize: 1
                        wrapMode: Text.NoWrap
                        clip: true
                    }
                }
            }
            Loader {
                anchors.fill: parent
                active: artworkDelegate.artwork.kind==="stamp" && !artworkDelegate.torn
                sourceComponent: stampPaint
            }
            PaperStaticRegion {
                objectName: "staticArtwork"+artworkDelegate.artwork.id
                x: 0
                y: 0
                app: annotationLayer.app
                paperMap: artworkDelegate.artwork.kind==="stamp" ? annotationLayer.paperMap : null
                sourceRect: Qt.rect(artworkDelegate.artwork.rect.x,artworkDelegate.artwork.rect.y,artworkDelegate.artwork.rect.width,artworkDelegate.artwork.rect.height)
                zoom: annotationLayer.zoom
                paint: stampPaint
                // The parent remains the one accessible/selectable artwork owner.
                Accessible.ignored: true
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
                paperMap: annotationLayer.paperMap
                paperRect: Qt.rect(artwork.rect.x,artwork.rect.y,artwork.rect.width,artwork.rect.height)
                paperZoom: annotationLayer.zoom
                paperOrigin: Qt.point(artworkDelegate.displayBounds.x,artworkDelegate.displayBounds.y)
                opacity: Logic.color(artwork).a
            }
            Text {
                anchors.fill: parent
                visible: artwork.kind === "signature" && (signatureCrop.status === 3 || signatureCrop.paperGeometryError.length>0)
                text: signatureCrop.paperGeometryError.length ? signatureCrop.paperGeometryError : qsTr("Image could not be decoded")
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
            id: noteDelegate
            required property var modelData
            readonly property bool torn: !!annotationLayer.paperMap && annotationLayer.paperMap.paperGeometryActive
            x: torn ? 0 : modelData.rect.x * annotationLayer.zoom
            y: torn ? 0 : modelData.rect.y * annotationLayer.zoom
            width: torn ? annotationLayer.width : modelData.rect.width * annotationLayer.zoom
            height: torn ? annotationLayer.height : modelData.rect.height * annotationLayer.zoom
            Component {
                id: notePaint
                Item {
                    Rectangle {
                        visible: noteDelegate.modelData.kind === "stickyNote"
                        anchors.fill: parent
                        radius: Math.min(3, parent.width / 6)
                        color: app.colors.noteBg
                        border.color: app.colors.noteFg
                        Label {
                            Accessible.ignored: noteDelegate.torn
                            textFormat: Text.PlainText
                            anchors.centerIn: parent
                            text: "✎"
                            font.pixelSize: Math.max(6, Math.min(18, parent.height * .7))
                            color: app.colors.noteFg
                        }
                    }
                    Text {
                        objectName: "staticNoteText"
                        Accessible.ignored: noteDelegate.torn
                        anchors.fill: parent
                        visible: noteDelegate.modelData.kind === "textBox" && !(!annotationLayer.ownOnly && app.placedTextEditor && app.placedTextEditor.current && app.placedTextEditor.entry && app.placedTextEditor.entry.id===noteDelegate.modelData.id)
                        text: noteDelegate.modelData.note || ""
                        textFormat: Text.PlainText
                        color: Logic.displayColor(Logic.color(noteDelegate.modelData), app.paperAppearance)
                        font.pixelSize: Math.max(1, Math.round((noteDelegate.modelData.fontSize || 14) * annotationLayer.zoom))
                        font.family: app.annotationFont
                        wrapMode: Text.Wrap
                        clip: true
                        horizontalAlignment: noteDelegate.modelData.textAlignment === "center" ? Text.AlignHCenter : noteDelegate.modelData.textAlignment === "right" ? Text.AlignRight : Text.AlignLeft
                    }
                }
            }
            Loader {
                anchors.fill: parent
                active: !noteDelegate.torn
                sourceComponent: notePaint
            }
            PaperStaticRegion {
                objectName: "staticAnnotation"+noteDelegate.modelData.id
                app: annotationLayer.app
                paperMap: annotationLayer.paperMap
                sourceRect: Qt.rect(noteDelegate.modelData.rect.x,noteDelegate.modelData.rect.y,noteDelegate.modelData.rect.width,noteDelegate.modelData.rect.height)
                zoom: annotationLayer.zoom
                paint: notePaint
                accessibleName: noteDelegate.modelData.kind==="stickyNote" ? qsTr("Sticky note on page %1: %2").arg(annotationLayer.page+1).arg(noteDelegate.modelData.note || "") : qsTr("Text annotation on page %1: %2").arg(annotationLayer.page+1).arg(noteDelegate.modelData.note || "")
                onPressed: app.selectAnnotation(noteDelegate.modelData,false)
            }
        }
    }
}

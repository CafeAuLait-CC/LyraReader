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
    property bool inlineNotes: false
    property var paperMap: null
    property rect visibleRegion: Qt.rect(0, 0, width / zoom, height / zoom)
    function inViewport(rect) {
        return rect && [rect.x,rect.y,rect.width,rect.height,rect.x+rect.width,rect.y+rect.height].every(Number.isFinite)
            && rect.width>0 && rect.height>0 && rect.x<visibleRegion.x+visibleRegion.width
            && rect.x+rect.width>visibleRegion.x && rect.y<visibleRegion.y+visibleRegion.height
            && rect.y+rect.height>visibleRegion.y;
    }
    readonly property var marks: {
        const values = app.annotations.filter(function (a) {
            return a.page === page && a.visible && (!ownOnly || !a.foreign) && app.eraseDraft.indexOf(a.id) < 0;
        });
        return values.map(function (a) {
            return app.annotationDraft && app.annotationDraft.id === a.id ? app.annotationDraft : a;
        }).concat(app.erasePreview.filter(function (a) { return a.page === page; }));
    }
    readonly property var markerOwner: app.currentReader
    readonly property var markerTextPage: markerOwner.textPages[page.toString()]
    readonly property var markerInputs: {
        if(!inlineNotes)return [];
        const editor=app.placedTextEditor;
        const values=marks.filter(function(a){return ["highlight","underline","strikeout"].indexOf(a.kind)>=0 && !a.is_reply && (String(a.note || a.contents || "").trim().length || (editor && editor.current && editor.noteOnly && editor.entry && editor.entry.id===a.id));});
        return values.filter(function(a){return a.foreign;}).concat(values.filter(function(a){return !a.foreign;}))
            .map(function(a){return {id:a.id,boxes:a.quads || []};});
    }
    readonly property string markerKey: JSON.stringify(markerInputs)
    property var noteMarkers: []
    property double markerRequest: -1
    property var markerGeneration: null
    property string requestedMarkerKey: ""
    property int markerPublishedPage: -1
    function invalidateMarkers() {
        if(markerPublishedPage>=0 && markerPublishedPage!==page)app.forgetNoteMarkers(annotationLayer,markerPublishedPage);
        markerPublishedPage=inlineNotes ? page : -1;
        markerRequest=-1;noteMarkers=[];
        if(inlineNotes)app.publishNoteMarkers(annotationLayer,page,markerOwner,markerOwner.documentGeneration,[]);
        markerTimer.restart();
    }
    function updateMarkers() {
        if(!inlineNotes)return;
        noteMarkers=[];app.publishNoteMarkers(annotationLayer,page,markerOwner,markerOwner.documentGeneration,[]);
        markerGeneration=markerOwner.documentGeneration;
        if(!markerInputs.length){markerRequest=-1;return;}
        requestedMarkerKey=markerKey;
        markerRequest=markerOwner.requestNoteMarkers(page,markerInputs);
    }
    onMarkerKeyChanged: invalidateMarkers()
    onMarkerTextPageChanged: invalidateMarkers()
    onMarkerOwnerChanged: invalidateMarkers()
    onPageChanged: invalidateMarkers()
    Component.onCompleted: markerTimer.restart()
    Component.onDestruction: if(app && markerPublishedPage>=0)app.forgetNoteMarkers(annotationLayer,markerPublishedPage)
    Timer {id:markerTimer;interval:0;onTriggered:annotationLayer.updateMarkers()}
    Connections {
        target:annotationLayer.markerOwner
        function onNoteMarkersReady(request,page,markers,error) {
            if(request!==annotationLayer.markerRequest || page!==annotationLayer.page || annotationLayer.requestedMarkerKey!==annotationLayer.markerKey || annotationLayer.markerGeneration!==annotationLayer.markerOwner.documentGeneration)return;
            if(error.length){annotationLayer.app.operationStatus=error;return;}
            annotationLayer.noteMarkers=markers;
            annotationLayer.app.publishNoteMarkers(annotationLayer,page,annotationLayer.markerOwner,annotationLayer.markerGeneration,markers);
        }
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
        model: annotationLayer.noteMarkers
        Item {
            id:inlineDelegate
            required property var modelData
            readonly property var annotation:annotationLayer.marks.find(function(a){return a.id===modelData.id;}) || null
            readonly property bool torn:!!annotationLayer.paperMap && annotationLayer.paperMap.paperGeometryActive
            visible:!!annotation && annotationLayer.inViewport(modelData.rect)
            x:torn ? 0 : modelData.rect.x*annotationLayer.zoom
            y:torn ? 0 : modelData.rect.y*annotationLayer.zoom
            width:torn ? annotationLayer.width : modelData.rect.width*annotationLayer.zoom
            height:torn ? annotationLayer.height : modelData.rect.height*annotationLayer.zoom
            Component {
                id:inlinePaint
                NoteBadge {
                    objectName:"inlineNoteBadge_"+inlineDelegate.modelData.id
                    colors:annotationLayer.app.colors
                    nightPaper:annotationLayer.app.paperAppearance==="night"
                    inlineComment:true
                    highlight:inlineDelegate.annotation ? Logic.color(inlineDelegate.annotation) : Qt.rgba(0,0,0,0)
                    active:!!app.selectedAnnotation && app.selectedAnnotation.id===inlineDelegate.modelData.id
                    Accessible.role:Accessible.Button
                    Accessible.name:qsTr("Read comment on page %1: %2").arg(annotationLayer.page+1).arg(inlineDelegate.annotation ? inlineDelegate.annotation.note : "")
                    Accessible.ignored:inlineDelegate.torn
                    Accessible.onPressAction:if(inlineDelegate.annotation)app.openInlineNote(inlineDelegate.annotation)
                }
            }
            Loader {anchors.fill:parent;active:!inlineDelegate.torn && inlineDelegate.visible;sourceComponent:inlinePaint}
            PaperStaticRegion {
                app:annotationLayer.app;paperMap:annotationLayer.paperMap
                sourceRect:Qt.rect(inlineDelegate.modelData.rect.x,inlineDelegate.modelData.rect.y,24,24)
                zoom:annotationLayer.zoom;paint:inlineDelegate.visible ? inlinePaint : null
                accessibleName:qsTr("Read comment on page %1: %2").arg(annotationLayer.page+1).arg(inlineDelegate.annotation ? inlineDelegate.annotation.note : "")
                onPressed:if(inlineDelegate.annotation)app.openInlineNote(inlineDelegate.annotation)
            }
        }
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
            visible:annotationLayer.inViewport(modelData.rect)
            readonly property bool torn: !!annotationLayer.paperMap && annotationLayer.paperMap.paperGeometryActive
            x: torn ? 0 : modelData.rect.x * annotationLayer.zoom
            y: torn ? 0 : modelData.rect.y * annotationLayer.zoom
            width: torn ? annotationLayer.width : modelData.rect.width * annotationLayer.zoom
            height: torn ? annotationLayer.height : modelData.rect.height * annotationLayer.zoom
            Component {
                id: notePaint
                Item {
                    NoteBadge {
                        objectName: "foldedNoteBadge_" + noteDelegate.modelData.id
                        visible: noteDelegate.modelData.kind === "stickyNote"
                        anchors.fill: parent
                        colors: annotationLayer.app.colors
                        nightPaper: annotationLayer.app.paperAppearance === "night"
                        active: !!app.selectedAnnotation && app.selectedAnnotation.id === noteDelegate.modelData.id
                        Accessible.ignored: noteDelegate.torn
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
                active: !noteDelegate.torn && noteDelegate.visible
                sourceComponent: notePaint
            }
            PaperStaticRegion {
                objectName: "staticAnnotation"+noteDelegate.modelData.id
                app: annotationLayer.app
                paperMap: annotationLayer.paperMap
                sourceRect: Qt.rect(noteDelegate.modelData.rect.x,noteDelegate.modelData.rect.y,noteDelegate.modelData.rect.width,noteDelegate.modelData.rect.height)
                zoom: annotationLayer.zoom
                paint: noteDelegate.visible ? notePaint : null
                accessibleName: noteDelegate.modelData.kind==="stickyNote" ? qsTr("Sticky note on page %1: %2").arg(annotationLayer.page+1).arg(noteDelegate.modelData.note || "") : qsTr("Text annotation on page %1: %2").arg(annotationLayer.page+1).arg(noteDelegate.modelData.note || "")
                onPressed: app.selectAnnotation(noteDelegate.modelData,false)
            }
        }
    }
}

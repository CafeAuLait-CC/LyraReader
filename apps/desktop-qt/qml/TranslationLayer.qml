import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: translationLayer
    objectName:"translationLayer"+page
    clip:true
    required property var app
    required property int page
    required property var paperMap
    readonly property var owner: app.currentReader
    readonly property var generation: owner.documentGeneration
    readonly property bool loading: owner.loading
    readonly property var entries: owner.translationOverlays.filter(function(e){return e.target.page===translationLayer.page;})
    function restore() { if(!loading)owner.inspectTranslations(page); }
    function closeDisclosure() {
        if(disclosure)disclosure.close();
        disclosedText="";disclosedLanguage="";disclosedModel="";
    }
    function toggleOriginal(id) {
        const expectedOwner=owner,expectedGeneration=generation;
        owner.toggleTranslation(id);
        // Rebuilding the value-model destroys the menu's button. Restore its
        // keyboard focus only within this same, still-active reading window.
        Qt.callLater(function() {
            if(owner!==expectedOwner || generation!==expectedGeneration || !app.active)return;
            for(let i=0;i<passages.count;++i) {
                const item=passages.itemAt(i);
                if(item && item.modelData.id===id){item.menuButton.forceActiveFocus();return;}
            }
        });
    }
    Component.onCompleted: restore()
    onOwnerChanged: {closeDisclosure();restore();}
    onPageChanged: {closeDisclosure();restore();}
    onGenerationChanged: {closeDisclosure();restore();}
    onLoadingChanged: restore()
    Repeater {
        id:passages
        model: translationLayer.entries
        Item {
            id: overlay
            required property var modelData
            property alias menuButton:chip
            readonly property var target: modelData.target
            readonly property var r: target.rect
            readonly property rect source: Qt.rect(r.x_pt,r.y_pt,r.width_pt,r.height_pt)
            readonly property color paper: {
                const loaded=translationLayer.paperMap.loaded;
                const refined=translationLayer.paperMap.refined;
                const mode=translationLayer.paperMap.paperAppearance;
                return loaded ? translationLayer.paperMap.translationPaperColor(source) : "transparent";
            }
            readonly property bool inViewport: {
                const v=translationLayer.paperMap.visibleRegion;
                return source.x<v.x+v.width && v.x<source.x+source.width && source.y<v.y+v.height && v.y<source.y+source.height;
            }
            readonly property bool original: !!modelData.original
            readonly property bool paintReady: translationLayer.paperMap.loaded && paper.a>0
            readonly property real textSize: Math.max(7,Math.min(18,target.source_font_pt))*app.zoom
            readonly property string paintText: {
                if(modelData.text.length<=8192)return modelData.text;
                let end=8192;
                const last=modelData.text.charCodeAt(end-1);
                if(last>=0xd800 && last<=0xdbff)--end;
                return modelData.text.slice(0,end)+"…";
            }
            anchors.fill: parent
            Component {
                id: passagePaint
                Rectangle {
                    color: overlay.paper
                    clip: true
                    Accessible.ignored:true
                    Text {
                        objectName: "inplaceTranslationText"
                        Accessible.ignored:true
                        anchors.fill: parent
                        anchors.leftMargin: 2*app.zoom; anchors.rightMargin: 2*app.zoom
                        anchors.topMargin: app.zoom; anchors.bottomMargin: app.zoom
                        text: overlay.paintText; textFormat: Text.PlainText
                        color: translationLayer.paperMap.translationInkColor(overlay.paper)
                        font.pixelSize: overlay.textSize
                        fontSizeMode: Text.Fit
                        minimumPixelSize: Math.max(1,Math.ceil(7*app.zoom))
                        wrapMode: Text.Wrap; elide: Text.ElideRight
                        maximumLineCount: Math.max(1,Math.floor(height/Math.max(1,7*app.zoom)))
                    }
                }
            }
            PaperStaticRegion {
                app:translationLayer.app;paperMap:translationLayer.paperMap;sourceRect:overlay.source
                paintActive:overlay.inViewport && !overlay.original && overlay.paintReady
                visible: !overlay.original && overlay.paintReady && translationLayer.paperMap.paperGeometryActive && mapped && bounded && geometryHit
                // Preserve the base component's hit/visibility contract through an explicit query.
                readonly property bool geometryHit: translationLayer.paperMap.paperRegion(overlay.source,translationLayer.paperMap.paperGeometryRevision).hit===true
                paint:passagePaint
                accessibleName: qsTr("Translated passage. Use its menu for the full text or original.")
            }
            Loader {
                active: overlay.inViewport && !translationLayer.paperMap.paperGeometryActive && !overlay.original && overlay.paintReady
                x:overlay.source.x*app.zoom;y:overlay.source.y*app.zoom
                width:overlay.source.width*app.zoom;height:overlay.source.height*app.zoom
                sourceComponent:passagePaint
            }
            PaperRegion {id: geometry;app:translationLayer.app;paperMap:translationLayer.paperMap;sourceRect:overlay.source}
            readonly property var chipRegion: {
                const viewport=translationLayer.paperMap.visibleRegion;
                const revision=translationLayer.paperMap.paperGeometryRevision;
                let best=null,bestArea=0;
                for(const piece of geometry.packet.pieces || []) {
                    const p=translationLayer.paperMap.paperGeometryActive ? translationLayer.paperMap.paperPoint(Qt.point(piece.x,piece.y)) : {hit:true,x:piece.x,y:piece.y};
                    if(!p.hit)continue;
                    const left=Math.max(p.x,viewport.x),top=Math.max(p.y,viewport.y);
                    const right=Math.min(p.x+piece.width,viewport.x+viewport.width),bottom=Math.min(p.y+piece.height,viewport.y+viewport.height);
                    const area=Math.max(0,right-left)*Math.max(0,bottom-top);
                    if(area>bestArea){bestArea=area;best={x:piece.x+(left-p.x),y:piece.y+(top-p.y),width:right-left,height:bottom-top};}
                }
                if(!best)return null;
                const pageInfo=translationLayer.owner.pages[translationLayer.page];
                if(!pageInfo)return null;
                const whole=Qt.rect(0,0,pageInfo.width,pageInfo.height);
                const segments=translationLayer.paperMap.paperGeometryActive ? translationLayer.paperMap.paperRegion(whole,revision).pieces || [] : [whole];
                for(const segment of segments) {
                    if(best.y<segment.y || best.y>=segment.y+segment.height)continue;
                    const origin=translationLayer.paperMap.paperGeometryActive ? translationLayer.paperMap.paperPoint(Qt.point(segment.x,segment.y)) : {hit:true,x:segment.x,y:segment.y};
                    if(!origin.hit)continue;
                    const top=Math.max(origin.y,viewport.y),bottom=Math.min(origin.y+segment.height,viewport.y+viewport.height);
                    if((bottom-top)*app.zoom<22)return null;
                    best.chipX=Math.max(0,(best.x+best.width)*app.zoom-24);
                    best.chipY=Math.max((segment.y+top-origin.y)*app.zoom,Math.min(best.y*app.zoom,(segment.y+bottom-origin.y)*app.zoom-22));
                    return best;
                }
                return null;
            }
            Button {
                id: chip
                objectName: "translationDisclosure"
                visible: !!overlay.chipRegion
                x: visible ? overlay.chipRegion.chipX : 0
                y: visible ? overlay.chipRegion.chipY : 0
                width:24;height:22;padding:0
                text:"⋯";font.pixelSize:16
                Accessible.name:qsTr("Translation for page %1: %2").arg(translationLayer.page+1).arg(Array.from(overlay.target.source_text.slice(0,162)).slice(0,80).join(""))
                Accessible.description:qsTr("%1 using %2. Open the menu for full text or the original.").arg(overlay.modelData.language || "").arg(overlay.modelData.model || "")
                ToolTip.visible:hovered;ToolTip.text:qsTr("Full translation or original")
                onClicked:menu.popup()
                Menu {
                    id:menu
                    objectName:"translationMenu"
                    MenuItem {
                        objectName:"translationToggleOriginal"
                        text: overlay.original ? qsTr("Show saved translation") : qsTr("Show original")
                        onTriggered:translationLayer.toggleOriginal(overlay.modelData.id)
                    }
                    MenuItem {objectName:"translationShowFull";text:qsTr("Full translation…");onTriggered:{translationLayer.disclosedText=overlay.modelData.text;translationLayer.disclosedLanguage=overlay.modelData.language || "";translationLayer.disclosedModel=overlay.modelData.model || "";disclosure.open();}}
                }
            }

        }
    }
    property string disclosedText: ""
    property string disclosedLanguage: ""
    property string disclosedModel: ""
            Dialog {
                id:disclosure
                objectName:"translationFullText"
                parent:Overlay.overlay;anchors.centerIn:parent
                width:Math.min(640,app.width-40);height:Math.min(480,app.height-40)
                title:qsTr("Full translation");modal:true;standardButtons:Dialog.Close
                ColumnLayout {
                    anchors.fill:parent
                    Label {text:translationLayer.disclosedLanguage+" · "+translationLayer.disclosedModel;textFormat:Text.PlainText;Layout.fillWidth:true;elide:Text.ElideRight;color:app.colors.textSecondary}
                    ScrollView {
                    Layout.fillWidth:true;Layout.fillHeight:true;contentWidth:availableWidth
                    TextArea {objectName:"translationDisclosureText";width:parent.width;text:translationLayer.disclosedText;textFormat:TextEdit.PlainText;readOnly:true;selectByMouse:true;wrapMode:TextEdit.Wrap}
                    }
                }
            }
}

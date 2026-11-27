import QtQuick
import QtQuick.Controls
import "TranslationPlacement.js" as Placement

Item {
    id: translationLayer
    objectName:"translationLayer"+page
    // A block's control can sit beside the sheet; the canvas viewport owns clipping.
    clip:false
    required property var app
    required property int page
    required property var paperMap
    readonly property var owner: app.currentReader
    readonly property var generation: owner.documentGeneration
    readonly property bool loading: owner.loading
    readonly property bool sourceCurrent: !!paperMap && paperMap.controller===owner && !loading
    readonly property var entries: {
        const rows=((owner.translationState || {}).rows || []).filter(function(row) {
            return row.target.page===translationLayer.page && (row.state==="sending" || row.state==="failed");
        });
        function overlaps(a,b) {
            if(a.page!==b.page)return false;
            const x=a.rect,y=b.rect;
            return (a.start<=b.end && b.start<=a.end)
                || (x.x_pt<y.x_pt+y.width_pt && y.x_pt<x.x_pt+x.width_pt
                    && x.y_pt<y.y_pt+y.height_pt && y.y_pt<x.y_pt+x.height_pt);
        }
        // A pending/failed replacement suppresses its older cover, as on Mac.
        // The retained cache is unchanged and becomes visible again after cancellation.
        const result=owner.translationOverlays.filter(function(entry) {
            return entry.target.page===translationLayer.page && !rows.some(function(row){return overlaps(row.target,entry.target);});
        });
        for(const row of rows)result.push({id:row.id,target:row.target,text:"",language:row.language,model:row.model,
            original:true,phase:row.state==="sending"?"translating":"failed",error:row.error || ""});
        return result.sort(function(a,b){return a.target.start-b.target.start || a.target.rect.y_pt-b.target.rect.y_pt || a.id.localeCompare(b.id);});
    }
    readonly property var entryIndex: {
        const result=Object.create(null);
        for(const entry of entries)result[entry.id]=entry;
        return result;
    }
    property var modelOwner: null
    property var modelGeneration: null
    property int modelPage: -1
    ListModel { id: order }
    function syncOrder() {
        if(!order || !owner)return;
        if(modelOwner!==owner || modelGeneration!==generation || modelPage!==page) {
            order.clear();modelOwner=owner;modelGeneration=generation;modelPage=page;
        }
        // Keep native text controls alive when another response advances or completes.
        // This follows the keyed insert/move pattern used by recent document cards.
        const desired=entries.map(function(entry){return entry.id;});
        for(let i=order.count-1;i>=0;--i)if(desired.indexOf(order.get(i).passageId)<0) {
            const item=passages ? passages.itemAt(i) : null;
            if(item && item.ownsFocus() && app.active && sourceCurrent)app.focusReadingView();
            order.remove(i);
        }
        for(let i=0;i<desired.length;++i) {
            let found=i;
            while(found<order.count && order.get(found).passageId!==desired[i])++found;
            if(found===order.count)order.insert(i,{passageId:desired[i]});
            else if(found!==i)order.move(found,i,1);
        }
    }
    readonly property rect displayViewport: {
        const source=paperMap.visibleRegion;
        const view=app.pageList;
        if(!view)return Qt.rect(source.x*app.zoom,source.y*app.zoom,source.width*app.zoom,source.height*app.zoom);
        // Track scrolling explicitly: mapToItem itself is not a notifying property.
        const scrollX=view.contentX,scrollY=view.contentY;
        const origin=mapToItem(view,0,0);
        return Qt.rect(-origin.x,-origin.y,view.width,view.height);
    }
    function restore() { if(!loading)owner.inspectTranslations(page); }
    function closeDisclosure() {
        disclosedContext=null;
        if(disclosure)disclosure.close();
        disclosedText="";disclosedSource="";disclosedTitle="";disclosedAnchor=null;
    }
    function restoreChipFocus(context) {
        // A value-model change can retire the button that owned the disclosure.
        Qt.callLater(function() {
            if(!context || owner!==context.reader || generation!==context.generation || !app.active)return;
            const window=translationLayer.Window.window;
            if(window && window.activeFocusItem && window.activeFocusItem.objectName==="inplaceTranslationText")return;
            for(let i=0;i<passages.count;++i) {
                const item=passages.itemAt(i);
                if(item && item.modelData.id===context.id && item.chipControl.visible) {
                    item.chipControl.focusControl(context.disclosure===true);return;
                }
            }
        });
    }
    function toggleOriginal(id) {
        const context={reader:owner,generation:generation,id:id};
        owner.toggleTranslation(id);
        restoreChipFocus(context);
    }
    function showFull(entry, anchor) {
        if(!sourceCurrent || !entry || !entry.text.length || !anchor)return;
        disclosedContext={reader:owner,generation:generation,id:entry.id,disclosure:true};
        disclosedText=entry.text;disclosedSource=entry.target.source_text;
        disclosedTitle=entry.target.is_block ? qsTr("Full translation") : qsTr("Full translation of the selection");
        disclosedAnchor=anchor;
        disclosure.open();
    }
    Component.onCompleted: {syncOrder();restore();}
    onOwnerChanged: {closeDisclosure();syncOrder();restore();}
    onPageChanged: {closeDisclosure();syncOrder();restore();}
    onGenerationChanged: {closeDisclosure();syncOrder();restore();}
    onLoadingChanged: restore()
    onSourceCurrentChanged: if(!sourceCurrent)closeDisclosure()
    onEntriesChanged: {
        syncOrder();
        const context=disclosedContext;
        if(context && !entries.some(function(entry){return entry.id===context.id;}))closeDisclosure();
    }
    Repeater {
        id:passages
        model: order
        Item {
            id: overlay
            required property string passageId
            objectName:"translationEntry_"+passageId
            readonly property bool present: !!translationLayer.entryIndex[passageId]
            // A removed delegate can settle its bindings before Qt destroys it.
            // This inert view record is never rendered or written to a document/cache.
            readonly property var retiredRecord: ({id:"",text:"",original:true,phase:"retired",language:"",model:"",
                target:{page:translationLayer.page,start:0,end:0,source_text:"",source_font_pt:7,is_block:false,
                    rect:{x_pt:0,y_pt:0,width_pt:0,height_pt:0}}})
            readonly property var modelData: translationLayer.entryIndex[passageId] || retiredRecord
            readonly property string phase: modelData.phase || (modelData.original ? "original" : "translated")
            function ownsFocus() {
                const window=translationLayer.Window.window;
                let item=window ? window.activeFocusItem : null;
                while(item){if(item===overlay)return true;item=item.parent;}
                return false;
            }
            property alias chipControl:chip
            readonly property var target: modelData.target
            readonly property var r: target.rect
            readonly property rect source: Qt.rect(r.x_pt,r.y_pt,r.width_pt,r.height_pt)
            readonly property color paper: {
                const loaded=translationLayer.paperMap.loaded;
                const refined=translationLayer.paperMap.refined;
                const mode=translationLayer.paperMap.paperAppearance;
                return present && translationLayer.sourceCurrent && loaded ? translationLayer.paperMap.translationPaperColor(source) : "transparent";
            }
            readonly property bool inViewport: {
                const v=translationLayer.paperMap.visibleRegion;
                return source.x<v.x+v.width && v.x<source.x+source.width && source.y<v.y+v.height && v.y<source.y+source.height;
            }
            readonly property bool original: phase!=="translated"
            readonly property bool paintReady: present && translationLayer.sourceCurrent && translationLayer.paperMap.loaded && paper.a>0
            readonly property bool clipped: modelData.text.length > 8192
                || fitProbe.contentHeight > fitProbe.height + 0.01
                || fitProbe.contentWidth > fitProbe.width + 0.01
            Text {
                id: fitProbe
                visible: false
                Accessible.ignored: true
                // Fit in source-page points, as on Mac. Display scaling must not
                // turn the same completed translation into a clipped one.
                width: Math.max(1,overlay.source.width-4)
                height: Math.max(1,overlay.source.height-2)
                text: overlay.paintText; textFormat: Text.PlainText
                font.pixelSize: overlay.textSize
                fontSizeMode: Text.Fit
                minimumPixelSize: 7
                wrapMode: Text.Wrap
            }
            readonly property real textSize: Math.max(7,Math.min(18,target.source_font_pt))
            readonly property string paintText: {
                if(modelData.text.length<=8192)return modelData.text;
                let end=8192;
                const last=modelData.text.charCodeAt(end-1);
                if(last>=0xd800 && last<=0xdbff)--end;
                return modelData.text.slice(0,end)+"…";
            }
            anchors.fill: parent
            TranslationTextRegion {
                app:translationLayer.app;paperMap:translationLayer.paperMap;sourceRect:overlay.source
                showing:overlay.inViewport && !overlay.original && overlay.paintReady
                translatedText:overlay.modelData.text
                displayText:overlay.paintText
                fontSize:fitProbe.fontInfo.pixelSize
                paper:overlay.paper
            }
            PaperRegion {id: geometry;app:translationLayer.app;paperMap:translationLayer.paperMap;sourceRect:overlay.source}
            readonly property var chipRegion: {
                const zoom=app.zoom;
                const pieces=(geometry.packet.pieces || []).map(function(piece) {
                    return {x:piece.x*zoom,y:piece.y*zoom,width:piece.width*zoom,height:piece.height*zoom};
                });
                const pageInfo=translationLayer.owner.pages[translationLayer.page];
                if(!pageInfo || !geometry.hit)return null;
                const whole=Qt.rect(0,0,pageInfo.width,pageInfo.height);
                const segments=translationLayer.paperMap.paperGeometryActive
                    ? translationLayer.paperMap.paperRegion(whole,translationLayer.paperMap.paperGeometryRevision).pieces || [] : [];
                let gap=null;
                if(segments.length===2) {
                    const first=segments[0],last=segments[1];
                    gap={x:first.x*zoom,y:(first.y+first.height)*zoom,width:first.width*zoom,
                        height:(last.y-first.y-first.height)*zoom};
                }
                return Placement.place(pieces,translationLayer.displayViewport,{width:chip.width,height:chip.height},gap);
            }
            Rectangle {
                // Clear the entire inside control rectangle, including its rounded
                // corners, with the sampled paper color. No glyph can show through.
                objectName:"translationChipTextExclusion"
                visible:chip.visible && overlay.chipRegion.inside && !overlay.original && overlay.paintReady
                x:chip.x;y:chip.y;width:chip.width;height:chip.height
                color:overlay.paper
                Accessible.ignored:true
            }
            TranslationChip {
                id: chip
                app: translationLayer.app
                visible: overlay.present && translationLayer.sourceCurrent && !!overlay.chipRegion
                readonly property string placement: overlay.chipRegion ? overlay.chipRegion.position : ""
                x: visible ? overlay.chipRegion.x : 0
                y: visible ? overlay.chipRegion.y : 0
                original: overlay.original
                phase: overlay.phase
                errorMessage: overlay.modelData.error || ""
                cancelPending: (translationLayer.owner.translationCancellingRows || []).indexOf(overlay.passageId)>=0
                retryAllowed: !((translationLayer.owner.aiState || {}).running) && !translationLayer.owner.pendingCommands
                clipped: overlay.clipped
                contextDescription: qsTr("Page %1 · %2 using %3. %4").arg(translationLayer.page+1)
                    .arg(overlay.modelData.language || "").arg(overlay.modelData.model || "")
                    .arg(Array.from(overlay.target.source_text.slice(0,162)).slice(0,80).join(""))
                onToggleRequested: translationLayer.toggleOriginal(overlay.modelData.id)
                onDisclosureRequested: translationLayer.showFull(overlay.modelData,chip)
                onCancelRequested: if(translationLayer.sourceCurrent && overlay.present)translationLayer.owner.cancelTranslation(overlay.passageId)
                onRetryRequested: if(translationLayer.sourceCurrent && overlay.present)translationLayer.app.previewTranslationRetry(translationLayer.owner,translationLayer.generation,overlay.passageId)
            }

        }
    }
    property var disclosedContext: null
    property var disclosedAnchor: null
    property string disclosedText: ""
    property string disclosedSource: ""
    property string disclosedTitle: ""
    Dialog {
        id: disclosure
        objectName: "translationFullText"
        parent: Overlay.overlay
        width: Math.min(440,app.width-16)
        height: Math.min(260,app.height-16)
        padding: 12
        margins: 8
        modal: false
        focus: true
        standardButtons: Dialog.NoButton
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onAboutToShow: {
            const anchor=translationLayer.disclosedAnchor;
            const point=anchor ? anchor.mapToItem(parent,0,anchor.height) : Qt.point((parent.width-width)/2,(parent.height-height)/2);
            if(anchor && point.y+height>parent.height-8) {
                const above=anchor.mapToItem(parent,0,0).y-height;
                if(above>=8)point.y=above;
            }
            x=Math.max(8,Math.min(parent.width-width-8,point.x));
            y=Math.max(8,Math.min(parent.height-height-8,point.y));
        }
        onOpened: translatedBody.forceActiveFocus(Qt.TabFocusReason)
        onClosed: {
            const context=translationLayer.disclosedContext;
            translationLayer.disclosedContext=null;
            translationLayer.disclosedText="";translationLayer.disclosedSource="";
            translationLayer.disclosedTitle="";translationLayer.disclosedAnchor=null;
            translationLayer.restoreChipFocus(context);
        }
        background: Rectangle {color:app.colors.menuBg;radius:8;border.width:1;border.color:app.colors.controlBorder}
        contentItem: AiReadingScrollView {
            id: disclosureScroll
            contentWidth: availableWidth
            Column {
                width: disclosureScroll.availableWidth
                spacing: 8
                Label {
                    width:parent.width;text:translationLayer.disclosedTitle;textFormat:Text.PlainText
                    font.pixelSize:12;font.weight:Font.DemiBold;color:app.colors.textPrimary;wrapMode:Text.Wrap
                }
                Label {
                    width:parent.width;text:qsTr("The full translation, including the part the fitted overlay clipped:");textFormat:Text.PlainText
                    font.pixelSize:11;color:app.colors.textSecondary;wrapMode:Text.Wrap
                }
                TextArea {
                    id: translatedBody
                    objectName:"translationDisclosureText"
                    width:parent.width;text:translationLayer.disclosedText;textFormat:TextEdit.PlainText
                    font.pixelSize:12;color:app.colors.textPrimary;padding:0;background:null
                    readOnly:true;selectByMouse:true;selectByKeyboard:true;wrapMode:TextEdit.Wrap
                    Accessible.name:qsTr("Full translation")
                }
                Label {text:qsTr("Source");font.pixelSize:11;font.weight:Font.DemiBold;color:app.colors.textSecondary}
                TextArea {
                    objectName:"translationDisclosureSource"
                    width:parent.width;text:translationLayer.disclosedSource;textFormat:TextEdit.PlainText
                    font.pixelSize:11;color:app.colors.textSecondary;padding:0;background:null
                    readOnly:true;selectByMouse:true;selectByKeyboard:true;wrapMode:TextEdit.Wrap
                    Accessible.name:qsTr("Translation source")
                }
            }
        }
    }
}

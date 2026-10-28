import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0

ApplicationWindow {
    id: preview
    objectName:"pdfPreviewWindow"
    required property var app
    property var previewReader:null
    readonly property var colors:app.colors
    property int requestedPage:0
    property var targetRegion:({})
    property int page:0
    property real zoom:1
    property bool fitting:true
    property bool textMode:false
    property bool initialized:false
    property bool shuttingDown:false
    property int navigationEpoch:0
    property var pendingPoint:null
    readonly property var pageSize:previewReader && page<previewReader.pages.length ? previewReader.pages[page] : null
    visible:false
    flags:Qt.Dialog
    transientParent:app
    color:app.colors.windowBg
    palette:app.palette
    title:qsTr("PDF Preview — %1").arg(previewReader ? previewReader.title : "LyraReader")
    AuxiliaryWindowPolicy {id:policy}
    DisplayCalibration {id:calibration;window:preview}
    function open() {
        const saved=app.session ? app.session.preference("auxiliaryPdfGeometry",{}) : ({});
        if(!policy.prepare(preview,app,saved,760,700))return false;
        pendingPoint={page:requestedPage,x:targetRegion.x_pt || 0,y:targetRegion.y_pt || 0};
        show();requestActivate();placePending();return true;
    }
    function navigate(index,y) {
        if(!previewReader || !previewReader.pageCount || shuttingDown)return;
        pendingPoint={page:Math.max(0,Math.min(previewReader.pageCount-1,index)),x:0,y:y || 0};
        placePending();
    }
    function placePending() {
        if(!visible || shuttingDown || !pendingPoint || !previewReader || !previewReader.pageCount || view.width<100 || view.height<100)return;
        const point=pendingPoint;pendingPoint=null;
        page=Math.max(0,Math.min(previewReader.pageCount-1,point.page));initialized=true;
        if(fitting)zoom=Math.max(.05,Math.min(16,(view.width-32)/pageSize.width));
        const epoch=++navigationEpoch;
        Qt.callLater(function(){if(shuttingDown || epoch!==navigationEpoch)return;
            view.contentX=Math.max(0,Math.min(Math.max(0,view.contentWidth-view.width),pdf.x+point.x*zoom-16));
            view.contentY=Math.max(0,Math.min(Math.max(0,view.contentHeight-view.height),pdf.y+point.y*zoom-16));});
        if(textMode)previewReader.requestText(page);
    }
    function changeZoom(value,anchorX,anchorY) {
        if(!pageSize || !previewReader || shuttingDown)return;
        value=Math.max(.05,Math.min(16,value));
        const nextX=previewReader.zoomOffset(view.contentX-pdf.x,anchorX,zoom,value);
        const nextY=previewReader.zoomOffset(view.contentY-pdf.y,anchorY,zoom,value);
        zoom=value;const epoch=++navigationEpoch;
        Qt.callLater(function(){if(shuttingDown || epoch!==navigationEpoch)return;
            view.contentX=Math.max(0,Math.min(Math.max(0,view.contentWidth-view.width),nextX+pdf.x));
            view.contentY=Math.max(0,Math.min(Math.max(0,view.contentHeight-view.height),nextY+pdf.y));});
    }
    function zoomBy(factor) {fitting=false;changeZoom(zoom*factor,view.width/2,view.height/2);}
    function fitWidth() {if(!pageSize)return;fitting=true;changeZoom((view.width-32)/pageSize.width,view.width/2,0);}
    function actualSize() {fitting=false;changeZoom(calibration.factor,view.width/2,view.height/2);}
    function copyPageText() {const data=previewReader ? previewReader.textPages[String(page)] : null;if(data && app.session)app.session.copyText(data.text);}
    function readText() {textMode=!textMode;if(textMode && previewReader)previewReader.requestText(page);}
    onClosing: {
        shuttingDown=true;++navigationEpoch;
        if(app && app.session)app.session.setPreference("auxiliaryPdfGeometry",policy.geometry());
        if(previewReader)previewReader.closeSnapshot();
        policy.returnFocus();destroy();
    }
    Connections {
        target:preview.previewReader
        function onOpenFinished(success){if(success)preview.placePending();}
    }
    header:ToolBar {
        implicitHeight:46
        background:Rectangle {color:preview.colors.toolbarBg}
        RowLayout {
            anchors.fill:parent;anchors.margins:6;spacing:4
            LyraToolButton {symbol:"back";text:qsTr("Previous page");enabled:preview.page>0;onClicked:preview.navigate(preview.page-1,0)}
            SpinBox {objectName:"previewPageNumber";from:1;to:preview.previewReader ? Math.max(1,preview.previewReader.pageCount) : 1;value:preview.page+1;editable:true;enabled:!!preview.pageSize;implicitWidth:90;onValueModified:preview.navigate(value-1,0);Accessible.name:qsTr("Preview page")}
            Label {visible:preview.width>=560;text:preview.previewReader ? "/ %1".arg(preview.previewReader.pageCount) : ""}
            LyraToolButton {symbol:"next";text:qsTr("Next page");enabled:!!preview.previewReader && preview.page+1<preview.previewReader.pageCount;onClicked:preview.navigate(preview.page+1,0)}
            Item {Layout.fillWidth:true}
            LyraToolButton {symbol:"minus";text:qsTr("Zoom out");enabled:!!preview.pageSize;onClicked:preview.zoomBy(1/1.2)}
            Button {visible:preview.width>=560;text:qsTr("%1%").arg(Math.round(preview.zoom/calibration.factor*100));enabled:!!preview.pageSize;onClicked:preview.actualSize();Accessible.name:qsTr("Actual Size")}
            LyraToolButton {symbol:"plus";text:qsTr("Zoom in");enabled:!!preview.pageSize;onClicked:preview.zoomBy(1.2)}
            LyraToolButton {visible:preview.width>=560;symbol:"view";text:qsTr("Fit width");enabled:!!preview.pageSize;onClicked:preview.fitWidth()}
            LyraToolButton {visible:preview.width>=560;symbol:"outline";text:qsTr("Read page text");selected:preview.textMode;enabled:!!preview.pageSize;onClicked:preview.readText()}
            LyraToolButton {
                id:more
                objectName:"previewMoreButton"
                symbol:"more";text:qsTr("Preview actions")
                onClicked:actions.popup(0,height)
                Menu {
                    id:actions
                    MenuItem {text:qsTr("Fit width");enabled:!!preview.pageSize;onTriggered:preview.fitWidth()}
                    MenuItem {text:calibration.fallbackReason.length ? qsTr("100% (uncalibrated)") : qsTr("Actual Size");enabled:!!preview.pageSize;onTriggered:preview.actualSize()}
                    MenuItem {text:qsTr("Read page text");checkable:true;checked:preview.textMode;enabled:!!preview.pageSize;onTriggered:preview.readText()}
                    MenuItem {text:qsTr("Copy page text");enabled:!!preview.previewReader && !!preview.previewReader.textPages[String(preview.page)];onTriggered:preview.copyPageText()}
                    MenuSeparator {}
                    MenuItem {text:qsTr("Close preview");onTriggered:preview.close()}
                }
            }
        }
    }
    Flickable {
        id:view
        objectName:"pdfPreviewViewport"
        anchors.fill:parent
        visible:!preview.textMode
        clip:true
        boundsBehavior:Flickable.StopAtBounds
        contentWidth:Math.max(width,pdf.width+32)
        contentHeight:Math.max(height,pdf.height+32)
        onWidthChanged:{if(preview.pendingPoint)preview.placePending();else if(preview.fitting && preview.initialized)preview.fitWidth();}
        onHeightChanged:if(preview.pendingPoint)preview.placePending()
        Rectangle {parent:view;color:preview.colors.canvasBg;anchors.fill:parent;z:-1}
        Rectangle {x:pdf.x;y:pdf.y;width:pdf.width;height:pdf.height;z:-0.5;color:preview.previewReader ? preview.previewReader.paperBackground(preview.app.paperAppearance) : preview.colors.documentPaper}
        PdfPage {
            id:pdf
            objectName:"pdfPreviewPage"
            controller:preview.previewReader
            pageIndex:preview.pageSize ? preview.page : -1
            width:preview.pageSize ? preview.pageSize.width*preview.zoom : 0
            height:preview.pageSize ? preview.pageSize.height*preview.zoom : 0
            x:(view.contentWidth-width)/2;y:(view.contentHeight-height)/2
            rasterScale:preview.zoom
            tilesEnabled:true
            visibleRegion:Qt.rect(Math.max(0,(view.contentX-x)/preview.zoom),Math.max(0,(view.contentY-y)/preview.zoom),view.width/preview.zoom,view.height/preview.zoom)
            resourceActive:preview.visible && !preview.shuttingDown && !preview.textMode
            paperAppearance:preview.app.paperAppearance
            Accessible.role:Accessible.Graphic
            Accessible.name:qsTr("Read-only PDF preview of page %1").arg(preview.page+1)
            Accessible.description:qsTr("Use Read page text to select and copy this snapshot's text.")
        }
        ScrollBar.vertical:ScrollBar {}
        ScrollBar.horizontal:ScrollBar {}
        HoverHandler {id:zoomHover}
        WheelHandler {
            target:null
            acceptedModifiers:Qt.ControlModifier
            onWheel:function(event){preview.fitting=false;preview.changeZoom(preview.zoom*Math.pow(1.0015,event.angleDelta.y),zoomHover.point.position.x,zoomHover.point.position.y);event.accepted=true;}
        }
    }
    ScrollView {
        anchors.fill:parent
        visible:preview.textMode
        contentWidth:availableWidth
        TextArea {
            objectName:"pdfPreviewText"
            readonly property var extracted:preview.previewReader ? preview.previewReader.textPages[String(preview.page)] : null
            text:extracted ? extracted.text : ""
            placeholderText:preview.previewReader && preview.previewReader.error.length ? qsTr("Page text is unavailable.") : extracted ? qsTr("No selectable text was found on this page.") : qsTr("Loading page text…")
            textFormat:TextEdit.PlainText
            readOnly:true;selectByMouse:true;selectByKeyboard:true;wrapMode:TextEdit.Wrap
            padding:16;font.pixelSize:16;color:preview.colors.textPrimary
            background:Rectangle {color:preview.colors.raisedBg}
            Accessible.name:qsTr("Read-only text of preview page %1").arg(preview.page+1)
            Accessible.readOnly:true
        }
    }
    BusyIndicator {anchors.centerIn:parent;running:!!preview.previewReader && preview.previewReader.loading;visible:running}
    footer:Label {
        textFormat:Text.PlainText
        padding:8;wrapMode:Text.Wrap
        color:preview.previewReader && preview.previewReader.error.length ? preview.colors.errorFg : preview.colors.textSecondary
        text:preview.previewReader && preview.previewReader.error.length ? preview.previewReader.error : qsTr("Read-only snapshot. Reopen the preview to see newer edits.")+(calibration.fallbackReason.length ? " · "+qsTr("Uncalibrated display: %1").arg(calibration.fallbackReason) : "")
        background:Rectangle {color:preview.colors.panelBg}
    }
    Shortcut {sequence:"Escape";onActivated:preview.close()}
    Shortcut {sequence:"Ctrl++";onActivated:preview.zoomBy(1.2)}
    Shortcut {sequence:"Ctrl+-";onActivated:preview.zoomBy(1/1.2)}
    Shortcut {sequence:"Alt+PgDown";onActivated:preview.navigate(preview.page+1,0)}
    Shortcut {sequence:"Alt+PgUp";onActivated:preview.navigate(preview.page-1,0)}
}

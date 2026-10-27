import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: chrome
    required property var app
    spacing: 0
    property int tabDragCancelEpoch:0
    implicitHeight: 90
    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 44
        color: app.colors.tabbarBg
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            spacing: 4
            ListView {
                id: tabStrip
                objectName:"tabStrip"
                property var tabDrag:null
                function sameOrder() {
                    return tabDrag && app.session && tabDrag.readers.length===app.session.tabs.length &&
                        tabDrag.readers.every(function(reader,index){return reader===app.session.tabs[index].reader;});
                }
                function updateDrag(x,y) {
                    if(!tabDrag)return;
                    const d=tabDrag,dx=x+contentX-d.pressX,pitch=d.width+spacing;
                    d.x=x;d.y=y;d.dx=dx;d.inside=y>=0 && y<=height && x>=0 && x<=width;
                    d.gap=d.sourceIndex;
                    if(d.inside && Math.abs(dx)>=d.width/2) {
                        const steps=1+Math.floor((Math.abs(dx)-d.width/2)/pitch);
                        const target=Math.max(0,Math.min(d.readers.length-1,d.sourceIndex+(dx<0 ? -steps : steps)));
                        d.gap=target>d.sourceIndex ? target+1 : target;
                    }
                    tabDrag=Object.assign({},d);
                }
                onWidthChanged:tabDrag=null
                Timer {
                    interval:16;repeat:true;running:!!tabStrip.tabDrag && tabStrip.tabDrag.inside
                    onTriggered:{const d=tabStrip.tabDrag,step=d.x<24 ? -8 : d.x>tabStrip.width-24 ? 8 : 0;
                        if(step){tabStrip.contentX=Math.max(0,Math.min(Math.max(0,tabStrip.contentWidth-tabStrip.width),tabStrip.contentX+step));tabStrip.updateDrag(d.x,d.y);}}
                }
                Connections {
                    target:app.session
                    function onTabsChanged(){tabStrip.tabDrag=null;chrome.tabDragCancelEpoch++;}
                }
                Connections {
                    target:app
                    function onCancelTabReorder(){tabStrip.tabDrag=null;chrome.tabDragCancelEpoch++;}
                    function onTabReorderFinished(owner){const index=app.readerIndex(owner);tabStrip.positionViewAtIndex(index,ListView.Contain);
                        Qt.callLater(function(){const item=tabStrip.itemAtIndex(index);if(item)item.focusTab();});}
                }
                Layout.fillWidth: true
                Layout.fillHeight: true
                orientation: ListView.Horizontal
                spacing: 4
                clip: true
                model: app.session ? app.session.tabs : [
                    {
                        title: app.currentReader.title
                    }
                ]
                currentIndex: app.session ? app.session.activeIndex : 0
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                delegate: Rectangle {
                    id: tab
                    objectName:"readerTab"+index
                    function focusTab(){tabMouse.forceActiveFocus();}
                    opacity:tabStrip.tabDrag && tabStrip.tabDrag.reader===modelData.reader ? .35 : 1
                    required property var modelData
                    required property int index
                    // A QVariantList reset may temporarily reset ListView's
                    // currentIndex while documents finish loading. The workspace
                    // remains the source of truth for the actual active reader.
                    readonly property bool selected: index === (app.session ? app.session.activeIndex : 0)
                    width: Math.max(120, Math.min(230, (tabStrip.width - 30) / Math.max(1, tabStrip.count) - 4))
                    height: 40
                    y: 4
                    topLeftRadius: 7
                    topRightRadius: 7
                    color: selected ? app.colors.raisedBg : tabMouse.containsMouse ? app.colors.hoverBg : "transparent"
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 4
                        spacing: 8
                        Label {
                            textFormat: Text.PlainText
                            text: modelData.title
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            color: tab.selected ? app.colors.textPrimary : app.colors.textSecondary
                            font.pixelSize: 12
                        }
                        BusyIndicator {
                            running: !!modelData.loading
                            visible: running
                            implicitWidth: 18
                            implicitHeight: 18
                        }
                        LyraToolButton {
                            symbol: "close"
                            text: qsTr("Close %1").arg(modelData.title)
                            implicitWidth: 24
                            implicitHeight: 24
                            padding: 5
                            visible: !!app.session
                            onClicked: app.requestCloseTab(tab.index)
                        }
                    }
                    MouseArea {
                        id: tabMouse
                        objectName:"tabSurface"+tab.index
                        enabled:!!app.session
                        preventStealing:true
                        property point pressPoint
                        property var pressReaders:[]
                        property bool hadDrag:false
                        property bool canceled:false
                        property int pressCancelEpoch:0
                        cursorShape:hadDrag ? (tabStrip.tabDrag && tabStrip.tabDrag.inside ? Qt.ClosedHandCursor : Qt.ForbiddenCursor) : Qt.ArrowCursor
                        anchors.fill: parent
                        anchors.rightMargin: app.session ? 30 : 0
                        hoverEnabled: true
                        activeFocusOnTab: true
                        onPressed:function(mouse){forceActiveFocus();pressPoint=mapToItem(tabStrip,mouse.x,mouse.y);pressPoint.x+=tabStrip.contentX;
                            pressCancelEpoch=chrome.tabDragCancelEpoch;pressReaders=app.session.tabs.map(function(t){return t.reader;});hadDrag=false;canceled=false;}
                        onPositionChanged:function(mouse){if(!pressed || canceled || pressCancelEpoch!==chrome.tabDragCancelEpoch)return;
                            const p=mapToItem(tabStrip,mouse.x,mouse.y);
                            if(!hadDrag && Math.hypot(p.x+tabStrip.contentX-pressPoint.x,p.y-pressPoint.y)<3)return;
                            if(!hadDrag){hadDrag=true;tabStrip.tabDrag={reader:modelData.reader,readers:pressReaders,sourceIndex:tab.index,width:tab.width,dx:0,gap:tab.index,inside:true,pressX:pressPoint.x,pressY:pressPoint.y,title:modelData.title};}
                            if(!tabStrip.sameOrder()){tabStrip.tabDrag=null;canceled=true;return;}
                            tabStrip.updateDrag(p.x,p.y);}
                        onReleased:function(mouse){if(canceled || pressCancelEpoch!==chrome.tabDragCancelEpoch){hadDrag=false;tabStrip.tabDrag=null;return;}
                            if(!hadDrag){app.selectReaderTab(tab.index);return;}
                            const p=mapToItem(tabStrip,mouse.x,mouse.y);tabStrip.updateDrag(p.x,p.y);
                            const d=tabStrip.tabDrag,valid=tabStrip.sameOrder();tabStrip.tabDrag=null;hadDrag=false;
                            if(valid && d.inside)app.reorderReaderTab(d.reader,d.readers[d.gap] || null);}
                        onCanceled:{canceled=true;hadDrag=false;tabStrip.tabDrag=null;}
                        Keys.onEscapePressed:{canceled=true;hadDrag=false;tabStrip.tabDrag=null;}
                        Keys.onPressed:function(event){if((event.modifiers & (Qt.AltModifier|Qt.ShiftModifier))!==(Qt.AltModifier|Qt.ShiftModifier))return;
                            const gap=event.key===Qt.Key_Left ? tab.index-1 : event.key===Qt.Key_Right ? tab.index+2 : -1;
                            if(gap>=0 && gap<=app.session.tabs.length){event.accepted=true;app.reorderReaderTab(modelData.reader,app.session.tabs[gap] ? app.session.tabs[gap].reader : null);}}
                        Keys.onReturnPressed: if (app.session)
                            app.selectReaderTab(tab.index)
                        Keys.onSpacePressed: if (app.session)
                            app.selectReaderTab(tab.index)
                        Accessible.description:qsTr("Drag half a tab width to reorder; Alt+Shift+Left or Right moves this tab. Escape cancels.")
                        Accessible.role: Accessible.PageTab
                        Accessible.name: modelData.title
                        Accessible.selectable: true
                        Accessible.selected: tab.selected
                        Accessible.onPressAction: if (app.session)
                            app.selectReaderTab(tab.index)
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 2
                        visible: tab.selected || tabMouse.activeFocus
                        color: tabMouse.activeFocus ? app.colors.focusRing : app.colors.accent
                    }
                }
            }
            Rectangle {
                parent:tabStrip
                visible:!!tabStrip.tabDrag
                z:10
                x:visible ? tabStrip.tabDrag.sourceIndex*(tabStrip.tabDrag.width+tabStrip.spacing)+tabStrip.tabDrag.dx-tabStrip.contentX : 0
                y:4
                width:visible ? tabStrip.tabDrag.width : 0;height:40;radius:7
                color:app.colors.selectedBg;border.color:app.colors.accent
                Accessible.ignored:true
                Label {anchors.fill:parent;anchors.margins:12;textFormat:Text.PlainText;text:tabStrip.tabDrag ? tabStrip.tabDrag.title : "";elide:Text.ElideRight;color:app.colors.selectedFg}
            }
            Rectangle {
                parent:tabStrip;z:11;visible:!!tabStrip.tabDrag && tabStrip.tabDrag.inside
                x:{const d=tabStrip.tabDrag;if(!d)return 0;const gap=d.gap;
                    return (gap===0 ? 0 : gap===d.readers.length ? gap*(d.width+tabStrip.spacing)-tabStrip.spacing : gap*(d.width+tabStrip.spacing)-tabStrip.spacing/2)-tabStrip.contentX-1;}
                width:2;height:36;y:6;color:app.colors.accent
                Accessible.ignored:true
            }
            LyraToolButton {
                symbol: "plus"
                text: qsTr("Open PDF in a new tab (Ctrl+O)")
                onClicked: app.openDialog()
            }
        }
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: app.colors.separator
        }
    }
    ToolBar {
        Layout.fillWidth: true
        Layout.preferredHeight: 46
        background: Rectangle {
            color: app.colors.toolbarBg
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: app.width < 1000 ? 3 : 7
            LyraToolButton {
                symbol: "sidebar"
                text: qsTr("Toggle sidebar (Ctrl+B)")
                selected: app.sidebarVisible
                onClicked: {
                    app.overviewVisible = false;
                    app.sidebarVisible = !app.sidebarVisible;
                }
            }
            LyraToolButton {
                symbol: "back"
                text: qsTr("Back to reading position (Alt+Left)")
                visible: app.canGoBack
                onClicked: app.goBack()
            }
            LyraToolButton {
                symbol: "overview"
                text: qsTr("Page overview")
                selected: app.overviewVisible
                enabled: app.currentReader.pageCount > 0
                onClicked: app.showOverview()
            }
            LyraToolButton {
                symbol: "view"
                text: qsTr("View settings")
                onClicked: viewMenu.popup(0, height)
            }
            Menu {
                id: viewMenu
                MenuItem {
                    text: qsTr("Read Page Text (Ctrl+Shift+R)")
                    checkable: true
                    checked: app.textViewVisible
                    enabled: app.currentReader.pageCount > 0
                    onTriggered: app.setTextViewEnabled(!app.textViewVisible)
                }
                MenuSeparator {}
                MenuItem {
                    text: qsTr("Continuous Pages")
                    checkable: true
                    checked: app.layoutMode === "Continuous"
                    onTriggered: app.setPageLayout("Continuous")
                }
                MenuItem {
                    text: qsTr("Facing Pages")
                    checkable: true
                    checked: app.layoutMode === "Facing"
                    onTriggered: app.setPageLayout("Facing")
                }
                MenuSeparator {}
                MenuItem {
                    text: qsTr("Fit Width")
                    enabled: !app.textViewVisible
                    onTriggered: app.fitWidth()
                }
                MenuItem {
                    text: qsTr("Actual Size")
                    enabled: !app.textViewVisible
                    onTriggered: {
                        app.actualSize();
                    }
                }
                MenuItem {
                    text: qsTr("Reading Appearance…")
                    onTriggered: app.showSettings()
                }
            }
            ToolSeparator {}
            LyraToolButton {
                symbol: "minus"
                text: qsTr("Zoom Out (Ctrl+−)")
                enabled: app.currentReader.pageCount > 0
                onClicked: app.zoomBy(1 / 1.2)
            }
            ToolButton {
                text: Math.round((app.textViewVisible ? app.textViewZoom * 100 : app.zoomPercent)) + (app.textViewVisible ? "%" : "% ▾")
                Layout.preferredWidth: 72
                Layout.minimumWidth: 72
                onClicked: zoomMenu.popup(0, height)
                enabled: app.currentReader.pageCount > 0 && !app.textViewVisible
            }
            Menu {
                id: zoomMenu
                MenuItem {
                    text: qsTr("Actual Size (100%)")
                    onTriggered: {
                        app.actualSize();
                    }
                }
                MenuItem {
                    text: qsTr("Fit Width")
                    onTriggered: app.fitWidth()
                }
                MenuItem {
                    text: qsTr("Fit Page")
                    onTriggered: app.fitPage()
                }
            }
            LyraToolButton {
                symbol: "plus"
                text: qsTr("Zoom In (Ctrl++)")
                enabled: app.currentReader.pageCount > 0
                onClicked: app.zoomBy(1.2)
            }
            ToolSeparator {}
            LyraToolButton {
                objectName: "annotateButton"
                symbol: "annotations"
                text: qsTr("Annotate")
                selected: app.secondaryRow === "annotate"
                display: app.width < 1250 ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
                enabled: app.canModifyPdf
                onClicked: app.toggleSecondaryRow("annotate")
            }
            LyraToolButton {
                objectName: "editPdfButton"
                symbol: "pen"
                text: qsTr("Edit")
                selected: app.secondaryRow === "edit"
                display: app.width < 1250 ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
                enabled: app.canModifyPdf
                onClicked: app.toggleSecondaryRow("edit")
            }
            LyraToolButton {
                objectName: "fillSignButton"
                symbol: "form"
                text: qsTr("Fill && Sign")
                Accessible.name:qsTr("Fill & Sign")
                ToolTip.text:qsTr("Fill & Sign")
                selected: app.secondaryRow === "fill"
                display: app.width < 1250 ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
                enabled: app.canModifyPdf
                onClicked: app.toggleSecondaryRow("fill")
            }
            LyraToolButton {
                objectName: "exportButton"
                symbol: "export"
                text: qsTr("Export")
                selected: app.secondaryRow === "export"
                display: app.width < 1250 ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
                enabled: app.currentReader.pageCount > 0
                onClicked: app.toggleSecondaryRow("export")
            }
            LyraToolButton {
                objectName: "lyraButton"
                symbol: "ai"
                text: qsTr("Lyra")
                selected: app.secondaryRow === "lyra"
                display: app.width < 1250 ? AbstractButton.IconOnly : AbstractButton.TextBesideIcon
                enabled: app.currentReader.pageCount > 0
                onClicked: app.toggleSecondaryRow("lyra")
            }
            LyraToolButton {
                objectName: "moreCommands"
                symbol: "more"
                text: qsTr("More commands")
                onClicked: moreMenu.popup(0, height)
            }
            Menu {
                id: moreMenu
                objectName: "moreCommandsMenu"
                MenuItem {
                    text: qsTr("Fill & Sign")
                    enabled: app.canModifyPdf
                    onTriggered: app.toggleForms()
                }
                MenuItem {
                    text: qsTr("AI Assistant")
                    enabled: app.currentReader.pageCount > 0
                    onTriggered: app.showSidebar("ai")
                }
                MenuItem {
                    text: qsTr("Page operations")
                    enabled: app.currentReader.pageCount > 0
                    onTriggered: app.showOverview()
                }
                MenuSeparator {}
                MenuItem {
                    text: qsTr("Open PDF…")
                    onTriggered: app.openDialog()
                }
                MenuItem {
                    text: qsTr("Add Bookmark")
                    enabled: app.currentReader.pageCount > 0
                    onTriggered: app.addBookmark()
                }
                MenuItem {
                    text: qsTr("Merge PDFs…")
                    enabled: app.canModifyPdf && !app.currentReader.hasEditDrafts
                    onTriggered: app.showMergeDialog()
                }
                MenuItem {
                    text: qsTr("Split PDF…")
                    enabled: app.canModifyPdf && !app.currentReader.hasEditDrafts
                    onTriggered: app.showSplitDialog()
                }
                MenuItem {
                    text: qsTr("Document Information…")
                    enabled: app.currentReader.pageCount > 0
                    onTriggered: app.showDocumentInformation()
                }
                MenuItem {
                    text: qsTr("Print…")
                    enabled: app.currentReader.pageCount > 0
                    onTriggered: app.printDocument()
                }
                MenuSeparator {}
                MenuItem {
                    text: qsTr("Settings…")
                    onTriggered: app.showSettings()
                }
            }
            Label {
                textFormat: Text.PlainText
                visible: (app.originalReadOnly || app.xfaReadOnly) && app.width >= 1000
                text: app.xfaReadOnly ? qsTr("XFA · read only") : qsTr("Signed · edits to copy")
                color: app.colors.textSecondary
                font.pixelSize: 11
                ToolTip.visible: signedHover.hovered
                ToolTip.text: app.readOnlyReason
                HoverHandler {
                    id: signedHover
                }
            }
            Item {
                Layout.fillWidth: true
            }
            LyraToolButton {
                objectName:"searchButton"
                visible:app.width<850
                symbol:"search";text:qsTr("Search document (Ctrl+F)")
                onClicked:app.focusSearch()
            }
            TextField {
                visible:app.width>=850
                id: searchField
                objectName: "searchField"
                Layout.preferredWidth: app.width < 850 ? 120 : app.width < 1000 ? 135 : 220
                Layout.minimumWidth: 100
                implicitHeight: 30
                placeholderText: qsTr("Search document")
                text: app.searchQuery
                onTextEdited: {
                    app.searchQuery = text;
                    app.searchDebounce.restart();
                }
                onAccepted: app.runSearch()
                Accessible.name: qsTr("Search document (Ctrl+F)")
                Component.onCompleted: app.chromeSearchField = searchField
            }
        }
    }
}

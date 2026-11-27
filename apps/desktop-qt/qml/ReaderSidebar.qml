import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
import LyraReader 1.0
import "ReaderLogic.js" as Logic
import "AnnotationSidebar.js" as AnnotationSidebar

Pane {
    id: sidebarPanel
    objectName:"readerSidebar"
    required property var app
    padding: 0
    component BookmarkOption: LyraMenuItem {
        implicitHeight: 30
        font.pixelSize: 12
        icon.width: 14
        icon.height: 14
        icon.color: sidebarPanel.app.colors.iconPrimary
    }
    readonly property var passageInputs: {
        const result={},flags=app.currentReader.data.annotation_rules && app.currentReader.data.annotation_rules.kind_flags || [];
        const rows=app.annotationThreads.rows;
        const ordered=rows.filter(function(row){return row.annotation.foreign;}).concat(rows.filter(function(row){return !row.annotation.foreign;}));
        for(const row of ordered) {
            const a=row.annotation;
            if(a.is_reply || !a.visible || !flags.some(function(f){return f.kind===a.kind && f.is_markup;}))continue;
            const regions=(a.foreign ? a.quads : a.fileQuads || []).map(function(r){return {x_pt:r.x,y_pt:r.y,width_pt:r.width,height_pt:r.height};});
            const key=String(a.page);if(!result[key])result[key]=[];
            result[key].push({id:a.id,start:a.foreign ? null : a.start,end:a.foreign ? null : a.end,regions:regions});
        }
        return result;
    }
    readonly property var passageInputKeys: {
        const keys={};
        for(const page of Object.keys(passageInputs))keys[page]=app.currentReader.annotationPassageInputKey(passageInputs[page]);
        return keys;
    }
    readonly property var annotationRows: {
        const owner=app.currentReader,generation=owner.documentGeneration;
        return AnnotationSidebar.rows(app.annotationThreads.rows,owner.annotationPassages,passageInputKeys).map(function(row){return Object.assign({},row,{owner:owner,generation:generation});});
    }
    property var pendingPassages:({})
    function requestPassage(page,owner,generation) {
        const key=passageInputKeys[String(page)];if(!key)return;
        const next=Object.assign({},pendingPassages);next[page]={owner:owner,generation:generation,key:key};pendingPassages=next;
        Qt.callLater(flushPassages);
    }
    function flushPassages() {
        const queued=pendingPassages;pendingPassages=({});
        if(!visible || !app.sidebarVisible || app.sidebarTab!=="annotations")return;
        for(const page of Object.keys(queued)) {
            const ticket=queued[page];
            if(ticket.owner!==app.currentReader || ticket.generation!==ticket.owner.documentGeneration || ticket.owner.loading
                    || ticket.key!==passageInputKeys[page])continue;
            const demanded=Array.from(annotationList.contentItem.children).some(function(item){return item.passageDemand && item.annotation && String(item.annotation.page)===page;});
            if(demanded)ticket.owner.requestAnnotationPassages(Number(page),passageInputs[page]);
        }
    }
    readonly property var annotationCounts: {
        const result={};for(const row of app.annotationThreads.rows)result[row.sectionKey]=(result[row.sectionKey] || 0)+1;
        return result;
    }
    property var collapsedAnnotationPages:({})
    function toggleAnnotationPage(page) {const next=Object.assign({},collapsedAnnotationPages);next[page]=!next[page];collapsedAnnotationPages=next;}
    function revealAnnotation() {
        const owner=app.currentReader,generation=owner.documentGeneration,id=app.selectedSidebarAnnotationID;
        if(!id)return;
        const row=annotationRows.find(function(r){return r.sourceIDs.indexOf(id)>=0;});if(!row)return;
        if(collapsedAnnotationPages[row.sectionKey]){const next=Object.assign({},collapsedAnnotationPages);delete next[row.sectionKey];collapsedAnnotationPages=next;}
        Qt.callLater(function(){if(owner!==app.currentReader || generation!==owner.documentGeneration)return;const index=annotationRows.findIndex(function(r){return r.sourceIDs.indexOf(id)>=0;});if(index>=0)annotationList.positionViewAtIndex(index,ListView.Contain);});
    }
    function contextInputKey(row) {
        const ids=row.sourceIDs || [row.id];
        return JSON.stringify((passageInputs[String(row.page)] || []).filter(function(entry){return ids.indexOf(entry.id)>=0;}));
    }
    property string fullInputKey:""
    onPassageInputsChanged:if(fullContext && contextInputKey(fullContext)!==fullInputKey)contextDialog.close()
    property var fullContext:null
    property var fullOwner:null
    property var fullGeneration:null
    function excerptHtml(row) {
        if(!row)return "";
        const escape=function(text){return text.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/\"/g,"&quot;");};
        return escape(row.context.slice(0,row.start))+"<b>"+escape(row.context.slice(row.start,row.end))+"</b>"+escape(row.context.slice(row.end));
    }
    function openContext(row,owner,generation) {if(!row || owner!==app.currentReader || generation!==owner.documentGeneration)return;fullInputKey=contextInputKey(row);fullContext=row;fullOwner=app.currentReader;fullGeneration=fullOwner.documentGeneration;contextDialog.open();}
    Connections {target:sidebarPanel.app;function onCurrentReaderChanged(){contextDialog.close();sidebarPanel.collapsedAnnotationPages=({});sidebarPanel.pendingPassages=({});} function onSelectedSidebarAnnotationIDChanged(){sidebarPanel.revealAnnotation();}}
    Connections {target:sidebarPanel.app.currentReader;function onDocumentChanged(){sidebarPanel.collapsedAnnotationPages=({});sidebarPanel.pendingPassages=({});if(sidebarPanel.fullOwner && (sidebarPanel.fullOwner!==sidebarPanel.app.currentReader || sidebarPanel.fullGeneration!==sidebarPanel.fullOwner.documentGeneration))contextDialog.close();}}
    background: Rectangle {
        color: app.colors.sidebarBg
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        Item {
            Layout.fillWidth: true
            Layout.margins: 8
            implicitHeight: 32
            Rectangle { anchors.fill: parent; color: app.colors.titlebarBg }
            RowLayout {
                anchors.fill: parent
                spacing: 0
                Repeater {
                    model: [
                        {
                            key: "bookmarks",
                            name: qsTr("Bookmarks"),
                            icon: "bookmark"
                        },
                        {
                            key: "outline",
                            name: qsTr("Outline"),
                            icon: "outline"
                        },
                        {
                            key: "annotations",
                            name: qsTr("Annotations"),
                            icon: "annotations"
                        },
                        {
                            key: "thumbnails",
                            name: qsTr("Thumbnails"),
                            icon: "overview"
                        }
                    ]
                    LyraToolButton {
                        id: sidebarTabButton
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        symbol: modelData.icon
                        text: modelData.name
                        selected: app.sidebarTab === modelData.key
                        onClicked: app.showSidebar(modelData.key)
                        background: Rectangle {
                            color: sidebarTabButton.down ? app.colors.pressedBg
                                  : sidebarTabButton.selected ? app.colors.selectedBg : app.colors.hoverBg
                            Rectangle {
                                visible: sidebarTabButton.index > 0
                                width: 1; height: parent.height
                                color: app.colors.separator
                            }
                            Rectangle {
                                anchors.fill: parent
                                visible: sidebarTabButton.visualFocus
                                color: "transparent"; border.width: 2; border.color: app.colors.focusRing
                            }
                        }
                    }
                }
            }
            Rectangle { anchors.fill: parent; color: "transparent"; border.color: app.colors.separator }
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 14
            Layout.rightMargin: 8
            Layout.bottomMargin: 8
            Label {
                textFormat: Text.PlainText
                text: ({
                        bookmarks: qsTr("Bookmarks"),
                        outline: qsTr("Outline"),
                        annotations: qsTr("Annotations"),
                        thumbnails: qsTr("Thumbnails")
                    })[app.sidebarTab] || ""
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            LyraToolButton {
                visible: app.sidebarTab === "bookmarks"
                symbol: "plus"
                text: qsTr("Bookmark this page (Ctrl+D)")
                onClicked: app.addBookmark()
            }
        }
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: app.colors.separator
        }
        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: ({
                    thumbnails: 0,
                    outline: 1,
                    bookmarks: 2,
                    annotations: 3
                })[app.sidebarTab] || 0
            ListView {
                id: thumbnails
                PanelWheelHandler { viewport: thumbnails }
                objectName: "pagesSidebar"
                clip: true
                model: app.currentReader.pages
                currentIndex: app.currentPage
                topMargin: 10
                bottomMargin: 10
                spacing: 10
                boundsBehavior: Flickable.StopAtBounds
                onCurrentIndexChanged: if (currentIndex >= 0)
                    positionViewAtIndex(currentIndex, ListView.Contain)
                ScrollBar.vertical: AiReadingScrollBar {id: thumbnailBar}
                delegate: ItemDelegate {
                    id: thumbnail
                    activeFocusOnTab: true
                    Accessible.onPressAction: if (enabled && visible)
                        clicked()
                    required property var modelData
                    required property int index
                    width: thumbnails.width
                    height: cell.height + 8
                    highlighted: app.currentPage === index
                    Accessible.name: qsTr("Page %1 thumbnail").arg(index + 1)
                    Accessible.selectable: true
                    Accessible.selected: highlighted
                    background: Rectangle {
                        objectName: "thumbnailSelection" + thumbnail.index
                        x: cell.x - 4
                        y: cell.y - 4
                        width: cell.width + 8
                        height: cell.height + 8
                        radius: 6
                        color: thumbnail.highlighted ? (app.active ? app.colors.selectedBg : app.colors.inactiveSelectionBg) : thumbnail.hovered ? app.colors.hoverBg : "transparent"
                        border.width: thumbnail.visualFocus || app.selectedPages.indexOf(thumbnail.index) >= 0 ? 2 : 0
                        border.color: thumbnail.visualFocus ? app.colors.focusRing : app.colors.accentBorder
                    }
                    Column {
                        id: cell
                        objectName: "thumbnailContent" + thumbnail.index
                        x: (parent.width - thumbnailBar.gutterWidth - width) / 2
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        Rectangle {
                            id: miniature
                            objectName: "thumbnailPaper" + thumbnail.index
                            readonly property real thumbnailScale: Math.min(132 / thumbnail.modelData.width, 300 / thumbnail.modelData.height)
                            width: thumbnail.modelData.width * thumbnailScale
                            height: thumbnail.modelData.height * thumbnailScale
                            color: app.currentReader.paperBackground(app.paperAppearance)
                            border.width: 1
                            border.color: app.colors.pageEdge
                            Item {
                                id: thumbnailPage
                                anchors.centerIn: parent
                                readonly property real pageScale: Math.min((miniature.width - 2 * miniature.border.width) / thumbnail.modelData.width,
                                    (miniature.height - 2 * miniature.border.width) / thumbnail.modelData.height)
                                width: thumbnail.modelData.width * pageScale
                                height: thumbnail.modelData.height * pageScale
                                PdfPage {
                                    objectName: "thumbnailRaster" + thumbnail.index
                                    resourceActive: thumbnail.y + thumbnail.height > thumbnails.contentY && thumbnail.y < thumbnails.contentY + thumbnails.height
                                    anchors.fill: parent
                                    embeddedAnnotations: true
                                    paperAppearance: app.paperAppearance
                                    controller: app.currentReader
                                    pageIndex: thumbnail.index
                                    rasterScale: thumbnailPage.pageScale
                                }
                                AnnotationsLayer {
                                    anchors.fill: parent
                                    app: sidebarPanel.app
                                    page: thumbnail.index
                                    zoom: thumbnailPage.pageScale
                                    ownOnly: true
                                }
                            }
                        }
                        Label {
                            textFormat: Text.PlainText
                            width: miniature.width
                            horizontalAlignment: Text.AlignHCenter
                            text: thumbnail.index + 1
                            font.pixelSize: 11
                            color: thumbnail.highlighted ? app.colors.textPrimary : app.colors.textTertiary
                        }
                    }
                    onClicked: {
                        app.selectPage(index, Qt.NoModifier);
                        app.navigate(index);
                    }
                }
            }
            ListView {
                id: outline
                objectName: "outlineSidebar"
                PanelWheelHandler { viewport: outline }
                clip: true
                model: Logic.outlineRows(app.currentReader.data.outline || [])
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                    id: outlineRow
                    required property var modelData
                    required property int index
                    objectName: "outlineRow" + index
                    activeFocusOnTab: true
                    hoverEnabled: true
                    Accessible.onPressAction: if (enabled && visible)
                        clicked()
                    width: outline.width
                    height: Math.max(24, outlineContent.implicitHeight + topPadding + bottomPadding)
                    leftPadding: 8 + modelData.indent
                    rightPadding: 8
                    topPadding: 1
                    bottomPadding: 1
                    Accessible.name: modelData.page === null
                        ? qsTr("%1 · %2").arg(modelData.number).arg(modelData.title)
                        : qsTr("%1 · %2 · page %3").arg(modelData.number).arg(modelData.title).arg(modelData.page + 1)
                    background: Rectangle {
                        color: outlineRow.down ? app.colors.pressedBg : outlineRow.hovered ? app.colors.hoverBg : "transparent"
                        radius: 6
                        border.width: outlineRow.visualFocus ? 2 : 0
                        border.color: app.colors.focusRing
                    }
                    contentItem: RowLayout {
                        id: outlineContent
                        spacing: 6
                        Label {
                            objectName: "outlineNumber" + outlineRow.index
                            textFormat: Text.PlainText
                            text: outlineRow.modelData.number
                            Layout.minimumWidth: 18
                            Layout.alignment: Qt.AlignBaseline
                            horizontalAlignment: Text.AlignRight
                            font.pixelSize: 11
                            font.features: ({"tnum": 1})
                            color: app.colors.textSecondary
                        }
                        Label {
                            objectName: "outlineTitle" + outlineRow.index
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            Layout.alignment: Qt.AlignBaseline
                            textFormat: Text.PlainText
                            text: outlineRow.modelData.title
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            font.pixelSize: 13
                            color: app.colors.textPrimary
                        }
                        Label {
                            objectName: "outlinePage" + outlineRow.index
                            visible: outlineRow.modelData.page !== null
                            textFormat: Text.PlainText
                            text: visible ? outlineRow.modelData.page + 1 : ""
                            Layout.alignment: Qt.AlignBaseline
                            font.pixelSize: 11
                            font.features: ({"tnum": 1})
                            color: app.colors.textSecondary
                        }
                    }
                    onClicked: if (modelData.page !== null)
                        app.navigate(modelData.page, modelData.y_pt || 0)
                }
                Label {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    visible: outline.count === 0
                    width: parent.width - 30
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("This document has no outline.")
                    wrapMode: Text.Wrap
                    color: app.colors.textSecondary
                }
            }
            ListView {
                id: bookmarkList
                objectName: "bookmarksSidebar"
                PanelWheelHandler { viewport: bookmarkList }
                clip: true
                model: app.bookmarks
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                    id: bookmarkRow
                    required property var modelData
                    required property int index
                    readonly property var presentation: (app.markState.bookmark_presentation || {})[modelData.id] || null
                    property var menuContext: null
                    function contextCurrent() {
                        const c=menuContext;
                        return c && c.owner && c.owner===app.currentReader && !c.owner.loading && !c.owner.documentRevisionPending
                            && c.generation===c.owner.documentGeneration && app.bookmarks.some(function(b){return b.id===c.bookmark.id;});
                    }
                    function command(operation, delta) {
                        if (!contextCurrent()) return;
                        const request={id:menuContext.bookmark.id};
                        if (delta!==undefined) request.delta=delta;
                        menuContext.owner.submit(operation,request);
                    }
                    activeFocusOnTab: true
                    hoverEnabled: true
                    Accessible.name: presentation ? presentation.title + " · " + presentation.page_label : qsTr("Bookmark title unavailable")
                    Accessible.onPressAction: if (enabled && visible)
                        clicked()
                    width: bookmarkList.width
                    padding: 10
                    leftPadding: 18
                    rightPadding: 18
                    leftInset: 8
                    rightInset: 8
                    height: Math.max(52, bookmarkBody.implicitHeight + 20)
                    background: Rectangle {
                        radius: 8
                        color: bookmarkRow.down ? app.colors.pressedBg : bookmarkRow.modelData.page===app.currentPage ? app.colors.selectedBg : bookmarkRow.hovered ? app.colors.hoverBg : "transparent"
                        border.width: bookmarkRow.visualFocus ? 2 : 0
                        border.color: app.colors.focusRing
                    }
                    contentItem: RowLayout {
                        id: bookmarkBody
                        spacing: 10
                        Shape {
                            objectName: "bookmarkFlag" + bookmarkRow.index
                            Layout.preferredWidth: 16
                            Layout.preferredHeight: 18
                            Layout.alignment: Qt.AlignTop
                            Accessible.ignored: true
                            ShapePath {
                                strokeWidth: 0
                                strokeColor: "transparent"
                                fillColor: app.colors.accent
                                PathSvg { path: "M2 0 H14 V18 L8 14 L2 18 Z" }
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            spacing: 5
                            Label {
                                objectName: "bookmarkTitle" + bookmarkRow.index
                                textFormat: Text.PlainText
                                text: bookmarkRow.presentation ? bookmarkRow.presentation.title : qsTr("Bookmark title unavailable")
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                font.pixelSize: 13
                                font.weight: Font.Medium
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                color: app.colors.textPrimary
                            }
                            Label {
                                objectName: "bookmarkPage" + bookmarkRow.index
                                textFormat: Text.PlainText
                                text: bookmarkRow.presentation ? bookmarkRow.presentation.page_label : ""
                                color: app.colors.textSecondary
                                font.pixelSize: 12
                            }
                        }
                        LyraToolButton {
                            id: bookmarkOptions
                            objectName: "bookmarkOptions" + bookmarkRow.index
                            Layout.alignment: Qt.AlignTop
                            symbol: "more"
                            text: qsTr("Bookmark options")
                            selected: bookmarkMenu.visible
                            Accessible.description: bookmarkMenu.visible ? qsTr("Expanded") : qsTr("Collapsed")
                            onClicked: bookmarkMenu.openBelow(bookmarkOptions)
                            LyraMenu {
                                id: bookmarkMenu
                                objectName: "bookmarkOptionsMenu" + bookmarkRow.index
                                onAboutToShow: bookmarkRow.menuContext={owner:app.currentReader,generation:app.currentReader.documentGeneration,bookmark:Object.assign({},bookmarkRow.modelData)}
                                BookmarkOption {
                                    text: qsTr("Rename…")
                                    icon.source: "qrc:/icons/pen.svg"
                                    onTriggered: if(bookmarkRow.contextCurrent())app.editBookmarkAt(bookmarkRow.menuContext.bookmark,bookmarkRow.index,bookmarkOptions)
                                }
                                BookmarkOption { text: qsTr("Remove Bookmark"); icon.source:"qrc:/icons/delete.svg"; onTriggered: bookmarkRow.command("bookmark_delete") }
                                LyraMenuSeparator {}
                                BookmarkOption { text: qsTr("Move Up"); icon.source:"qrc:/icons/arrow-up.svg"; onTriggered: bookmarkRow.command("bookmark_move",-1) }
                                BookmarkOption { text: qsTr("Move Down"); icon.source:"qrc:/icons/arrow-down.svg"; onTriggered: bookmarkRow.command("bookmark_move",1) }
                            }
                            Connections { target:app; function onCurrentReaderChanged(){bookmarkMenu.close();bookmarkRow.menuContext=null;} }
                            Connections {
                                target:bookmarkRow.menuContext ? bookmarkRow.menuContext.owner : null
                                function onDocumentChanged(){if(!bookmarkRow.contextCurrent())bookmarkMenu.close();}
                            }
                        }
                    }
                    onClicked: app.navigate(modelData.page, modelData.yPt || 0)
                }
                Label {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    width: parent.width - 32
                    visible: bookmarkList.count === 0
                    text: qsTr("Keep your place with a bookmark.\nCtrl+D bookmarks the current page.")
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: app.colors.textSecondary
                }
            }
            ListView {
                id: annotationList
                PanelWheelHandler { viewport: annotationList }
                clip: true
                objectName: "annotationThreadList"
                model: sidebarPanel.annotationRows
                section.property: "sectionKey"
                section.delegate: Button {
                    id:pageHeader
                    required property string section
                    objectName:"annotationPageHeader_"+section
                    width:annotationList.width;height:34;leftPadding:12;rightPadding:12
                    hoverEnabled:true
                    Accessible.name:qsTr("Page %1 · %2 annotations").arg(section).arg(sidebarPanel.annotationCounts[section] || 0)
                    Accessible.description:sidebarPanel.collapsedAnnotationPages[section] ? qsTr("Collapsed") : qsTr("Expanded")
                    onClicked:sidebarPanel.toggleAnnotationPage(section)
                    contentItem:RowLayout {
                        spacing:6
                        Label {text:sidebarPanel.collapsedAnnotationPages[section] ? "▸" : "▾";font.pixelSize:9;color:app.colors.textPrimary;Layout.preferredWidth:10}
                        Label {text:qsTr("Page %1").arg(section);font.pixelSize:11;font.bold:true;color:app.colors.textPrimary;Layout.fillWidth:true}
                        Label {text:String(sidebarPanel.annotationCounts[section] || 0);font.pixelSize:11;color:app.colors.textSecondary}
                    }
                    background:Rectangle {
                        color:pageHeader.down ? app.colors.pressedBg : pageHeader.hovered ? app.colors.hoverBg : app.colors.panelBg
                        Rectangle {anchors.bottom:parent.bottom;width:parent.width;height:1;color:app.colors.separator}
                        Rectangle {
                            objectName:"annotationPageHeaderFocus_"+pageHeader.section
                            anchors.fill:parent;anchors.margins:2;radius:3;color:"transparent"
                            border.width:2;border.color:app.colors.focusRing
                            visible:pageHeader.visualFocus && app.active
                        }
                    }
                }
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                    id:annotationRow
                    required property var modelData
                    readonly property var annotation: modelData.annotation
                    readonly property var group:modelData.passage || null
                    readonly property bool current:modelData.owner===app.currentReader && modelData.generation===app.currentReader.documentGeneration && !modelData.owner.loading
                    readonly property bool expanded:!sidebarPanel.collapsedAnnotationPages[modelData.sectionKey]
                    readonly property var groupNotes:group ? group.marks.filter(function(m){return String(m.source.annotation.note || m.source.annotation.contents || "").trim().length>0;}) : []
                    readonly property string groupMetadata: {
                        if(!group)return "";
                        const authors=Array.from(new Set(group.marks.map(function(m){return m.source.annotation.author;}).filter(function(v){return !!v;}))).sort().join(", ");
                        let date="";
                        for(const mark of group.marks) {
                            const source=mark.source.annotation;
                            if(source.modified){date=Logic.annotationDate(source.modified);break;}
                            if(source.createdAt!==undefined){const formatted=app.currentReader.formattedAnnotationDate(source.createdAt);date=formatted.text || formatted.error;break;}
                        }
                        return [authors,date].filter(function(v){return !!v;}).join(" · ");
                    }
                    readonly property bool passageWanted:(sidebarPanel.passageInputs[String(annotation.page)] || []).some(function(e){return e.id===annotation.id;})
                    readonly property var contextFrame:app.currentReader.annotationPassages[String(annotation.page)] || ({})
                    readonly property var passage:contextFrame.input_key===sidebarPanel.passageInputKeys[String(annotation.page)] ? (contextFrame.entries || {})[annotation.id] || null : null
                    readonly property string passageError:passageWanted ? (contextFrame.error || ((contextFrame.warnings || []).find(function(w){return w.id===annotation.id;}) || {}).message || "") : ""
                    readonly property bool passageDemand:current && expanded && sidebarPanel.visible && app.sidebarVisible && app.sidebarTab==="annotations" && !app.currentReader.loading && passageWanted && !annotation.is_reply && y+height>annotationList.contentY && y<annotationList.contentY+annotationList.height
                    function requestPassage() {if(passageDemand)sidebarPanel.requestPassage(annotation.page,modelData.owner,modelData.generation);}
                    onPassageDemandChanged:requestPassage()
                    Component.onCompleted:requestPassage()
                    Connections {target:sidebarPanel;function onPassageInputsChanged(){annotationRow.requestPassage();}}
                    enabled:current
                    activeFocusOnTab: true
                    hoverEnabled:true
                    Accessible.name: group ? group.text : qsTr("%1 · page %2").arg(annotation.is_reply ? annotation.author || qsTr("Reply") : annotation.kind).arg(annotation.page + 1)
                    Accessible.description: (annotation.note || annotation.contents || "") + (modelData.orphanReason ? " · " + modelData.orphanReason : "")
                    Accessible.onPressAction: if (enabled && visible)
                        clicked()
                    objectName: "annotationThreadRow_" + annotation.id
                    highlighted:modelData.sourceIDs.indexOf(app.selectedSidebarAnnotationID)>=0
                    Accessible.selectable:true
                    Accessible.selected:highlighted
                    width: annotationList.width
                    leftPadding: 10 + Math.min(modelData.depth, 6) * 14
                    visible:expanded
                    height:expanded ? Math.max(group ? 40 : 68, annotationContent.implicitHeight + 24) : 0
                    background:Rectangle {
                        color:annotationRow.down ? app.colors.pressedBg : annotationRow.highlighted ? app.colors.selectedBg : annotationRow.hovered ? app.colors.hoverBg : "transparent"
                        Rectangle {
                            objectName:"annotationThreadFocus_"+annotationRow.annotation.id
                            anchors.fill:parent;anchors.margins:2;radius:3;color:"transparent"
                            border.width:2;border.color:app.colors.focusRing
                            visible:annotationRow.visualFocus && app.active
                        }
                    }
                    contentItem: ColumnLayout {
                        id: annotationContent
                        spacing:group ? 8 : 4
                        RowLayout {
                            visible:!annotationRow.group
                            Label {
                                textFormat: Text.PlainText
                                text: annotation.is_reply ? "↳ " + (annotation.author || qsTr("Reply")) : annotation.kind
                                color: app.colors.accent
                                font.pixelSize: 11
                                Layout.fillWidth: true
                            }
                            Label {
                                textFormat: Text.PlainText
                                text: qsTr("p.%1").arg(annotation.page + 1)
                                color: app.colors.textTertiary
                                font.pixelSize: 11
                            }
                        }
                        Label {
                            objectName:"annotationContext_"+annotation.id
                            visible:!!passage && !annotationRow.group
                            text:sidebarPanel.excerptHtml(passage)
                            textFormat:Text.RichText;wrapMode:Text.Wrap
                            maximumLineCount:5;elide:Text.ElideRight
                            color:app.colors.textPrimary;font.pixelSize:12
                            Layout.fillWidth:true
                            Accessible.name:passage ? passage.context : ""
                        }
                        AnnotationPassageText {
                            id:groupText
                            objectName:"annotationPassage_"+(annotationRow.group ? annotationRow.group.id : annotation.id)
                            visible:!!annotationRow.group
                            Layout.fillWidth:true;Layout.preferredHeight:implicitHeight
                            text:annotationRow.group ? annotationRow.group.text : ""
                            marks:annotationRow.group ? annotationRow.group.marks.map(function(mark){const source=mark.source.annotation;return {start:mark.start,end:mark.end,kind:source.kind,color:Logic.displayColor(Logic.color(source),app.paperAppearance)};}) : []
                            color:app.colors.textPrimary;font.pixelSize:12
                            Accessible.role:Accessible.StaticText;Accessible.name:text
                        }
                        Repeater {
                            model:annotationRow.groupNotes
                            delegate:Button {
                                id:passageNote
                                required property var modelData
                                objectName:"annotationPassageNote_"+modelData.source.annotation.id
                                Layout.fillWidth:true;leftPadding:7;rightPadding:7;topPadding:7;bottomPadding:7
                                hoverEnabled:true
                                Accessible.name:String(modelData.source.annotation.note || modelData.source.annotation.contents || "")
                                onClicked:app.openSidebarPassageNote(modelData.source,annotationRow.modelData.owner,annotationRow.modelData.generation)
                                contentItem:Label {text:passageNote.Accessible.name;textFormat:Text.PlainText;wrapMode:Text.Wrap;font.pixelSize:12;color:app.colors.noteFg}
                                background:Rectangle {
                                    color:app.colors.noteBg;radius:3
                                    border.width:passageNote.down || passageNote.hovered ? 1 : 0
                                    border.color:app.colors.noteFg
                                    Rectangle {
                                        objectName:"annotationPassageNoteFocus_"+passageNote.modelData.source.annotation.id
                                        anchors.fill:parent;anchors.margins:2;radius:2;color:"transparent"
                                        border.width:2;border.color:app.colors.focusRing
                                        visible:passageNote.visualFocus && app.active
                                    }
                                }
                            }
                        }
                        Label {
                            visible:!!annotationRow.groupMetadata;text:annotationRow.groupMetadata
                            Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText;font.pixelSize:10;color:app.colors.textTertiary
                        }
                        Label {
                            visible:!!groupText.warning && !!annotationRow.group;text:groupText.warning
                            Layout.fillWidth:true;wrapMode:Text.Wrap;font.pixelSize:10;color:app.colors.warningFg
                        }
                        ToolButton {
                            objectName:"annotationFullContext_"+annotation.id
                            visible:!!passage && (!annotationRow.group || groupText.clipped || !!groupText.warning);text:qsTr("Full context…")
                            Accessible.name:qsTr("Full annotation context on page %1").arg(annotation.page+1)
                            onClicked:sidebarPanel.openContext(annotationRow.group ? {id:annotation.id,page:annotation.page,context:annotationRow.group.text,quote:annotationRow.group.members.map(function(member){return annotationRow.contextFrame.entries[member.id].quote;}).join(" · "),sourceIDs:modelData.sourceIDs} : passage,modelData.owner,modelData.generation)
                        }
                        Label {
                            visible:passageError.length>0;text:passageError;textFormat:Text.PlainText
                            wrapMode:Text.Wrap;Layout.fillWidth:true;font.pixelSize:10;color:app.colors.warningFg
                        }
                        Label {
                            id: annotationText
                            textFormat: Text.PlainText
                            visible:!annotationRow.group && (!!(annotation.note || annotation.contents) || !passage)
                            text: annotation.note || annotation.contents || qsTr("No text")
                            wrapMode: Text.Wrap
                            maximumLineCount: 4
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            font.pixelSize: 12
                        }
                        Label {
                            textFormat: Text.PlainText
                            visible: !annotationRow.group && !!annotation.modified
                            text: Logic.annotationDate(annotation.modified)
                            font.pixelSize: 10
                            color: app.colors.textTertiary
                        }
                        Label {
                            textFormat: Text.PlainText
                            visible: modelData.orphanReason.length > 0
                            text: modelData.orphanReason
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            font.pixelSize: 10
                            color: app.colors.warningFg
                        }
                    }
                    onClicked: if(group)app.activateAnnotationPassage(modelData,modelData.owner,modelData.generation);else app.activateAnnotationThreadRow(modelData)
                }
                Label {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    visible: annotationList.count === 0
                    width: parent.width - 30
                    text: qsTr("No annotations yet.")
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: app.colors.textSecondary
                }
            }
        }
    }
    DropArea {
        anchors.fill: parent
        onDropped: function (drop) {
            if (app.session && drop.hasUrls) {
                for (const url of drop.urls)
                    app.session.openInNewWindow(url, 0);
                drop.accepted = true;
            }
        }
    }
    Dialog {
        id:contextDialog;objectName:"annotationContextDialog"
        parent:Overlay.overlay;anchors.centerIn:parent
        width:Math.min(640,app.width-40);height:Math.min(480,app.height-40)
        title:qsTr("Annotation context");modal:true;standardButtons:Dialog.Close
        onClosed:{sidebarPanel.fullContext=null;sidebarPanel.fullOwner=null;sidebarPanel.fullGeneration=null;}
        ColumnLayout {
            anchors.fill:parent
            Label {text:qsTr("Quoted text");font.weight:Font.DemiBold;color:app.colors.textPrimary}
            Label {objectName:"annotationFullQuote";text:sidebarPanel.fullContext ? sidebarPanel.fullContext.quote : "";textFormat:Text.PlainText;wrapMode:Text.Wrap;maximumLineCount:3;elide:Text.ElideRight;Layout.fillWidth:true;color:app.colors.textPrimary}
            ScrollView {
                Layout.fillWidth:true;Layout.fillHeight:true;contentWidth:availableWidth
                TextArea {objectName:"annotationFullContextText";width:parent.width;text:sidebarPanel.fullContext ? sidebarPanel.fullContext.context : "";textFormat:TextEdit.PlainText;readOnly:true;selectByMouse:true;selectByKeyboard:true;activeFocusOnTab:true;wrapMode:TextEdit.Wrap}
            }
        }
    }

}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0
import "ReaderLogic.js" as Logic

Pane {
    id: sidebarPanel
    required property var app
    padding: 0
    readonly property var passageInputs: {
        const result={},flags=app.currentReader.data.annotation_rules && app.currentReader.data.annotation_rules.kind_flags || [];
        for(const row of app.annotationThreads.rows) {
            const a=row.annotation;
            if(a.is_reply || !a.visible || !flags.some(function(f){return f.kind===a.kind && f.is_markup;}))continue;
            const regions=(a.foreign ? a.quads : a.fileQuads || []).map(function(r){return {x_pt:r.x,y_pt:r.y,width_pt:r.width,height_pt:r.height};});
            const key=String(a.page);if(!result[key])result[key]=[];
            result[key].push({id:a.id,start:a.foreign ? null : a.start,end:a.foreign ? null : a.end,regions:regions});
        }
        return result;
    }
    property string fullInputKey:""
    onPassageInputsChanged:if(fullContext && JSON.stringify((passageInputs[String(fullContext.page)] || []).find(function(e){return e.id===fullContext.id;}))!==fullInputKey)contextDialog.close()
    property var fullContext:null
    property var fullOwner:null
    property var fullGeneration:null
    function excerptHtml(row) {
        if(!row)return "";
        const escape=function(text){return text.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/\"/g,"&quot;");};
        return escape(row.context.slice(0,row.start))+"<b>"+escape(row.context.slice(row.start,row.end))+"</b>"+escape(row.context.slice(row.end));
    }
    function openContext(row) {fullInputKey=JSON.stringify((passageInputs[String(row.page)] || []).find(function(e){return e.id===row.id;}));fullContext=row;fullOwner=app.currentReader;fullGeneration=fullOwner.documentGeneration;contextDialog.open();}
    Connections {target:sidebarPanel.app;function onCurrentReaderChanged(){contextDialog.close();}}
    Connections {target:sidebarPanel.app.currentReader;function onDocumentChanged(){if(sidebarPanel.fullOwner && (sidebarPanel.fullOwner!==sidebarPanel.app.currentReader || sidebarPanel.fullGeneration!==sidebarPanel.fullOwner.documentGeneration))contextDialog.close();}}
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
                            color: sidebarTabButton.selected ? app.colors.selectedBg : sidebarTabButton.down ? app.colors.pressedBg
                                  : sidebarTabButton.hovered ? app.colors.hoverBg : "transparent"
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
                model: app.currentReader.data.outline || []
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                    required property var modelData
                    activeFocusOnTab: true
                    Accessible.onPressAction: if (enabled && visible)
                        clicked()
                    width: outline.width
                    height: Math.max(42, outlineText.implicitHeight + 18)
                    leftPadding: 12 + modelData.depth * 13
                    highlighted: modelData.page === app.currentPage
                    Accessible.name: modelData.title
                    contentItem: Label {
                        id: outlineText
                        textFormat: Text.PlainText
                        text: modelData.title
                        wrapMode: Text.Wrap
                        font.pixelSize: 12
                        color: app.colors.textPrimary
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
                    required property var modelData
                    required property int index
                    activeFocusOnTab: true
                    Accessible.name: qsTr("%1 · page %2").arg(modelData.title || qsTr("Bookmark")).arg(modelData.page + 1)
                    Accessible.onPressAction: if (enabled && visible)
                        clicked()
                    width: bookmarkList.width
                    height: 62
                    contentItem: RowLayout {
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3
                            Label {
                                textFormat: Text.PlainText
                                text: modelData.title
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                            Label {
                                textFormat: Text.PlainText
                                text: qsTr("Page %1").arg(modelData.page + 1)
                                color: app.colors.textTertiary
                                font.pixelSize: 11
                            }
                        }
                        LyraToolButton {
                            symbol: "more"
                            text: qsTr("Edit bookmark")
                            onClicked: app.editBookmark(modelData, index)
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
                model: app.annotationThreads.rows
                section.property: "sectionKey"
                section.delegate: Label {
                    required property string section
                    text: qsTr("Page %1").arg(section)
                    width: annotationList.width
                    padding: 10
                    color: app.colors.textSecondary
                    font.bold: true
                    font.pixelSize: 11
                }
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                    id:annotationRow
                    required property var modelData
                    readonly property var annotation: modelData.annotation
                    readonly property bool passageWanted:(sidebarPanel.passageInputs[String(annotation.page)] || []).some(function(e){return e.id===annotation.id;})
                    readonly property var contextFrame:app.currentReader.annotationPassages[String(annotation.page)] || ({})
                    readonly property var passage:(contextFrame.entries || {})[annotation.id] || null
                    readonly property string passageError:passageWanted ? (contextFrame.error || ((contextFrame.warnings || []).find(function(w){return w.id===annotation.id;}) || {}).message || "") : ""
                    readonly property bool passageDemand:sidebarPanel.visible && app.sidebarVisible && app.sidebarTab==="annotations" && !app.currentReader.loading && passageWanted && !annotation.is_reply && y+height>annotationList.contentY && y<annotationList.contentY+annotationList.height
                    function requestPassage() {const inputs=sidebarPanel.passageInputs[String(annotation.page)];if(passageDemand && inputs)app.currentReader.requestAnnotationPassages(annotation.page,inputs);}
                    onPassageDemandChanged:requestPassage()
                    Component.onCompleted:requestPassage()
                    Connections {target:sidebarPanel;function onPassageInputsChanged(){annotationRow.requestPassage();}}
                    activeFocusOnTab: true
                    Accessible.name: qsTr("%1 · page %2").arg(annotation.is_reply ? annotation.author || qsTr("Reply") : annotation.kind).arg(annotation.page + 1)
                    Accessible.description: (annotation.note || annotation.contents || "") + (modelData.orphanReason ? " · " + modelData.orphanReason : "")
                    Accessible.onPressAction: if (enabled && visible)
                        clicked()
                    objectName: "annotationThreadRow_" + annotation.id
                    highlighted:app.selectedSidebarAnnotationID===annotation.id
                    Accessible.selectable:true
                    Accessible.selected:highlighted
                    width: annotationList.width
                    leftPadding: 10 + Math.min(modelData.depth, 6) * 14
                    height: Math.max(68, annotationContent.implicitHeight + 20)
                    contentItem: ColumnLayout {
                        id: annotationContent
                        spacing: 4
                        RowLayout {
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
                            visible:!!passage
                            text:sidebarPanel.excerptHtml(passage)
                            textFormat:Text.RichText;wrapMode:Text.Wrap
                            maximumLineCount:5;elide:Text.ElideRight
                            color:app.colors.textPrimary;font.pixelSize:12
                            Layout.fillWidth:true
                            Accessible.name:passage ? passage.context : ""
                        }
                        ToolButton {
                            objectName:"annotationFullContext_"+annotation.id
                            visible:!!passage;text:qsTr("Full context…")
                            Accessible.name:qsTr("Full annotation context on page %1").arg(annotation.page+1)
                            onClicked:sidebarPanel.openContext(passage)
                        }
                        Label {
                            visible:passageError.length>0;text:passageError;textFormat:Text.PlainText
                            wrapMode:Text.Wrap;Layout.fillWidth:true;font.pixelSize:10;color:app.colors.warningFg
                        }
                        Label {
                            id: annotationText
                            textFormat: Text.PlainText
                            visible:!!(annotation.note || annotation.contents) || !passage
                            text: annotation.note || annotation.contents || qsTr("No text")
                            wrapMode: Text.Wrap
                            maximumLineCount: 4
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            font.pixelSize: 12
                        }
                        Label {
                            textFormat: Text.PlainText
                            visible: !!annotation.modified
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
                    onClicked: app.activateAnnotationThreadRow(modelData)
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
                TextArea {objectName:"annotationFullContextText";width:parent.width;text:sidebarPanel.fullContext ? sidebarPanel.fullContext.context : "";textFormat:TextEdit.PlainText;readOnly:true;selectByMouse:true;wrapMode:TextEdit.Wrap}
            }
        }
    }

}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes

Item {
    id: welcome
    objectName: "welcomeView"
    required property var app
    property bool showAll: false
    readonly property var recents: app.session ? app.session.recentDocuments : []
    readonly property real margin: width < 520 ? 16 : 36
    clip: true

    function syncRecents() {
        const hadCurrent = cards.currentIndex >= 0;
        const desired = showAll ? recents : recents.slice(0, 5);
        for (let i = 0; i < desired.length; ++i) {
            const entry = desired[i];
            let found = i;
            while (found < history.count && history.get(found).fileUrl !== String(entry.url)) ++found;
            if (found === history.count) history.insert(i, {fileUrl:String(entry.url), title:"", date:"", coverKey:""});
            else if (found !== i) history.move(found, i, 1);
            // A cover arriving from another reader must not rebuild focused cards.
            history.set(i, {fileUrl:String(entry.url), title:String(entry.displayTitle || entry.title),
                date:String(entry.openedDate || ""), coverKey:String(entry.coverKey || "")});
        }
        if (history.count > desired.length) history.remove(desired.length, history.count - desired.length);
        if (!hadCurrent) cards.currentIndex = -1;
    }
    function focusCard(index) {
        if (!history.count) return;
        cards.currentIndex = Math.max(0, Math.min(history.count - 1, index));
        cards.positionViewAtIndex(cards.currentIndex, GridView.Contain);
        Qt.callLater(function() { if (cards.currentItem) cards.currentItem.forceActiveFocus(Qt.TabFocusReason); });
    }
    function showStart() {
        if (cards.headerItem) cards.headerItem.forceLayout();
        cards.forceLayout();
        // GridView's inline header lives before the first cell's origin.
        cards.contentY = cards.headerItem ? cards.headerItem.y - cards.topMargin : cards.originY - cards.topMargin;
    }
    onRecentsChanged: syncRecents()
    onShowAllChanged: {
        syncRecents(); cards.currentIndex = -1;
        Qt.callLater(function() { welcome.showStart(); if (cards.headerItem) cards.headerItem.focusStart(); });
    }
    onVisibleChanged: if (visible) { showAll = false; cards.currentIndex = -1; Qt.callLater(showStart); }
    Component.onCompleted: { syncRecents(); cards.currentIndex = -1; Qt.callLater(showStart); }
    ListModel { id: history }
    GridView {
        id: cards
        objectName: "recentDocuments"
        width: Math.max(0, Math.min(1060, welcome.width - 2 * welcome.margin))
        height: welcome.height
        anchors.horizontalCenter: parent.horizontalCenter
        topMargin: welcome.margin
        bottomMargin: welcome.margin
        readonly property int columns: Math.max(1, Math.floor((width + 22) / 172))
        cellWidth: width / columns
        cellHeight: 282
        clip: true
        model: history
        currentIndex: -1
        highlightFollowsCurrentItem: false
        keyNavigationEnabled: false
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { }
        PanelWheelHandler { viewport: cards }
        header: Column {
            width: cards.width
            spacing: 28
            function focusStart() { (welcome.showAll ? back : primaryOpen).forceActiveFocus(Qt.TabFocusReason); }
            LyraToolButton {
                id: back
                objectName: "recentDocumentsBack"
                symbol: "back"; text: qsTr("Back"); display: AbstractButton.TextBesideIcon
                visible: welcome.showAll
                Accessible.name: qsTr("Back to Open File")
                onClicked: welcome.showAll = false
            }
            Item {
                id: dropPanel
                objectName: "welcomeDropPanel"
                width: parent.width; height: 232
                visible: !welcome.showAll
                Rectangle { anchors.fill: parent; radius: 18; color: fileDrop.containsDrag ? app.colors.selectedBg : app.colors.panelBg }
                Shape {
                    anchors.fill: parent
                    ShapePath {
                        strokeColor: fileDrop.containsDrag ? app.colors.accentBorder : app.colors.border
                        strokeWidth: 1.5; strokeStyle: ShapePath.DashLine; dashPattern: [4, 3.333333]
                        fillColor: "transparent"
                        PathSvg { path: "M18 .75 H" + (dropPanel.width-18) + " Q" + (dropPanel.width-.75) + " .75 " + (dropPanel.width-.75) + " 18 V214 Q" + (dropPanel.width-.75) + " 231.25 " + (dropPanel.width-18) + " 231.25 H18 Q.75 231.25 .75 214 V18 Q.75 .75 18 .75 Z" }
                    }
                }
                Column {
                    anchors.centerIn: parent
                    spacing: 12
                    Item {
                        width: parent.width; height: 52
                        HomeDocumentGlyph { anchors.horizontalCenter: parent.horizontalCenter; width:48; height:52; ink:app.colors.accent; badgeInk:app.colors.accentFg; visible:!app.currentReader.loading }
                        BusyIndicator { anchors.centerIn: parent; width:48; height:48; running:app.currentReader.loading; visible:running }
                    }
                    Label {
                        objectName: "welcomeTitle"
                        width: Math.min(360, dropPanel.width - 32)
                        horizontalAlignment: Text.AlignHCenter
                        text: app.currentReader.loading ? qsTr("Opening your document") : qsTr("Open a PDF")
                        font.pixelSize: 25; font.weight: Font.DemiBold
                        textFormat: Text.PlainText; wrapMode: Text.Wrap
                        color: app.colors.textPrimary
                    }
                    Label {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: qsTr("Drop files here to start reading")
                        textFormat: Text.PlainText; wrapMode: Text.Wrap
                        color: app.colors.textSecondary
                    }
                    Button {
                        id: primaryOpen
                        objectName: "welcomeOpen"
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: qsTr("Open Files…")
                        icon.source: "qrc:/icons/folder.svg"; icon.color:app.colors.accentFg
                        icon.width:18; icon.height:18
                        palette.buttonText: app.colors.accentFg
                        leftPadding:26; rightPadding:26; topPadding:7; bottomPadding:7
                        enabled: !app.currentReader.loading
                        onClicked: app.openDialog()
                        contentItem: Row {
                            spacing: 8
                            Shape {
                                width: 18; height: 18; anchors.verticalCenter: parent.verticalCenter
                                ShapePath {
                                    strokeColor:app.colors.accentFg;strokeWidth:1.2;fillColor:"transparent"
                                    capStyle:ShapePath.RoundCap;joinStyle:ShapePath.RoundJoin
                                    PathSvg { path:"M2 5 H7 L10 7 H16 V15 Q16 16 15 16 H3 Q2 16 2 15 Z M2 5 V3 H7 L10 5 H15 Q16 5 16 6 V7" }
                                }
                            }
                            Text { text:primaryOpen.text; font:primaryOpen.font; color:app.colors.accentFg; textFormat:Text.PlainText }
                        }
                        background: Rectangle {
                            radius:5
                            color: primaryOpen.down ? app.colors.accentPressed : primaryOpen.hovered ? app.colors.accentHover : app.colors.accent
                            border.width:primaryOpen.visualFocus ? 2 : 0; border.color:app.colors.focusRing
                        }
                    }
                }
                DropArea {
                    id: fileDrop
                    objectName: "welcomeFileDrop"
                    anchors.fill: parent
                    enabled: !app.currentReader.loading
                    onEntered: function(drag) { drag.accepted = drag.hasUrls; }
                    onDropped: function(drop) {
                        if (drop.hasUrls && app.session) { app.session.openFiles(drop.urls); drop.acceptProposedAction(); }
                    }
                }
            }
            RowLayout {
                width: parent.width
                spacing: 8
                Label {
                    text: qsTr("Recents")
                    textFormat: Text.PlainText; font.pixelSize: welcome.showAll ? 28 : 22; font.weight:Font.DemiBold
                    color: app.colors.textPrimary
                    Layout.fillWidth: true
                }
                LyraToolButton {
                    objectName: "clearRecentDocuments"
                    text:qsTr("Clear"); display:AbstractButton.TextOnly
                    enabled: welcome.recents.length>0
                    ToolTip.text:qsTr("Clear recent history; keep the original files")
                    onClicked:app.session.clearRecentDocuments()
                }
                LyraToolButton {
                    objectName: "viewAllRecentDocuments"
                    text:qsTr("View All"); display:AbstractButton.TextOnly
                    visible:!welcome.showAll
                    onClicked:welcome.showAll=true
                }
            }
            Label {
                visible: history.count===0
                text:qsTr("Your recently opened PDFs will appear here.")
                textFormat:Text.PlainText; wrapMode:Text.Wrap; width:parent.width
                color:app.colors.textSecondary
                topPadding:20; bottomPadding:20
            }
            Item { width:1; height:8 }
        }
        delegate: Button {
            id: card
            required property int index
            required property string fileUrl
            required property string title
            required property string date
            required property string coverKey
            objectName: "recentDocument"+index
            width: cards.cellWidth; height:256
            padding:0
            activeFocusOnTab:true
            Accessible.name:qsTr("Open recent PDF: %1").arg(title)
            Accessible.description:app.session ? app.session.localPath(fileUrl) : fileUrl
            Accessible.onPressAction:if(enabled && visible)clicked()
            onClicked:app.session.openFile(fileUrl)
            onActiveFocusChanged:if(activeFocus && (focusReason===Qt.TabFocusReason || focusReason===Qt.BacktabFocusReason)) {
                cards.currentIndex=index;cards.positionViewAtIndex(index,GridView.Contain);
            }
            Keys.onLeftPressed: welcome.focusCard(index-1)
            Keys.onRightPressed: welcome.focusCard(index+1)
            Keys.onUpPressed: welcome.focusCard(index-cards.columns)
            Keys.onDownPressed: welcome.focusCard(index+cards.columns)
            Keys.onPressed: function(event) {
                if(event.key===Qt.Key_Home) { welcome.focusCard(0); event.accepted=true; }
                else if(event.key===Qt.Key_End) { welcome.focusCard(history.count-1); event.accepted=true; }
                else event.accepted=false;
            }
            ToolTip.visible:hovered
            ToolTip.text: title
            background:Rectangle {
                radius:5
                color:card.down ? app.colors.pressedBg : card.hovered ? app.colors.hoverBg : "transparent"
                border.width:card.visualFocus ? 2 : 0; border.color:app.colors.focusRing
            }
            contentItem:Column {
                spacing:9
                Item {
                    width:parent.width; height:188
                    Item {
                        anchors.centerIn:parent
                        width:cover.status===Image.Ready ? cover.paintedWidth : 140
                        height:cover.status===Image.Ready ? cover.paintedHeight : 188
                        Repeater {
                            model:3
                            Rectangle { required property int index; x:-index-1; y:1; width:parent.width+2*(index+1); height:parent.height+index+2; radius:4; color:app.colors.coverShadow }
                        }
                        Rectangle { anchors.fill:parent; radius:4; color:app.colors.raisedBg; visible:cover.status!==Image.Ready }
                    }
                    Image {
                        id:cover
                        objectName:"recentDocumentCover"+card.index
                        anchors.centerIn:parent
                        width:140; height:188
                        fillMode:Image.PreserveAspectFit
                        asynchronous:true; cache:false
                        sourceSize:Qt.size(280,376)
                        source:welcome.visible && card.coverKey.length ? "image://lyrapreview/recent/"+card.coverKey+"?paper="+app.paperAppearance : ""
                        Accessible.ignored:true
                    }
                    HomeDocumentGlyph { anchors.centerIn:parent; width:40; height:48; badge:false; ink:app.colors.textTertiary; visible:cover.status!==Image.Ready }
                }
                Label {
                    width:parent.width-12; x:6; height:34
                    text:card.title; textFormat:Text.PlainText
                    font.pixelSize:12; font.weight:Font.Medium; horizontalAlignment:Text.AlignHCenter
                    wrapMode:Text.Wrap; maximumLineCount:2; elide:Text.ElideRight
                    color:app.colors.textPrimary
                }
                Label {
                    width:parent.width-8; x:4
                    text:card.date.length ? card.date : qsTr("Recently opened")
                    textFormat:Text.PlainText; font.pixelSize:11; horizontalAlignment:Text.AlignHCenter
                    elide:Text.ElideRight; color:app.colors.textTertiary
                }
            }
        }
    }
}

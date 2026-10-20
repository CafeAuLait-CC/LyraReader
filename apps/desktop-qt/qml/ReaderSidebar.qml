import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import LyraReader 1.0
import "ReaderLogic.js" as Logic

Pane {
    id: sidebarPanel
    required property var app
    padding: 0
    background: Rectangle {
        color: app.colors.sidebarBg
    }
    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 8
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
                    },
                    {
                        key: "ai",
                        name: qsTr("AI Assistant"),
                        icon: "ai"
                    }
                ]
                LyraToolButton {
                    required property var modelData
                    Layout.fillWidth: true
                    symbol: modelData.icon
                    text: modelData.name
                    selected: app.sidebarTab === modelData.key
                    onClicked: app.showSidebar(modelData.key)
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 14
            Layout.rightMargin: 8
            Layout.bottomMargin: 8
            Label {
                text: ({
                        bookmarks: qsTr("Bookmarks"),
                        outline: qsTr("Outline"),
                        annotations: qsTr("Annotations"),
                        thumbnails: qsTr("Thumbnails"),
                        ai: qsTr("AI Assistant")
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
                    annotations: 3,
                    ai: 4
                })[app.sidebarTab] || 0
            ListView {
                id: thumbnails
                objectName: "pagesSidebar"
                clip: true
                model: app.currentReader.pages
                currentIndex: app.currentPage
                boundsBehavior: Flickable.StopAtBounds
                onCurrentIndexChanged: if (currentIndex >= 0)
                    positionViewAtIndex(currentIndex, ListView.Contain)
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                    id: thumbnail
                    required property var modelData
                    required property int index
                    width: thumbnails.width
                    height: 178
                    highlighted: app.currentPage === index
                    background: Rectangle {
                        color: thumbnail.highlighted ? (app.active ? app.colors.selectedBg : app.colors.inactiveSelectionBg) : thumbnail.hovered ? app.colors.hoverBg : app.colors.sidebarBg
                        border.width: thumbnail.visualFocus ? 2 : 0
                        border.color: app.colors.focusRing
                    }
                    Column {
                        anchors.centerIn: parent
                        spacing: 7
                        Rectangle {
                            readonly property real thumbnailScale: Math.min(102 / thumbnail.modelData.width, 135 / thumbnail.modelData.height)
                            width: thumbnail.modelData.width * thumbnailScale
                            height: thumbnail.modelData.height * thumbnailScale
                            color: "white"
                            border.width: thumbnail.highlighted ? 2 : 1
                            border.color: thumbnail.highlighted ? app.colors.accentBorder : app.colors.pageEdge
                            PdfPage {
                                resourceActive: thumbnail.y + thumbnail.height > thumbnails.contentY && thumbnail.y < thumbnails.contentY + thumbnails.height
                                anchors.fill: parent
                                anchors.margins: parent.border.width
                                embeddedAnnotations: true
                                paperAppearance: app.paperAppearance
                                controller: app.currentReader
                                pageIndex: thumbnail.index
                                rasterScale: Math.min(100 / thumbnail.modelData.width, 133 / thumbnail.modelData.height)
                            }
                            AnnotationsLayer {
                                anchors.fill: parent
                                app: sidebarPanel.app
                                page: thumbnail.index
                                zoom: parent.thumbnailScale
                                ownOnly: true
                            }
                        }
                        Label {
                            width: 102
                            horizontalAlignment: Text.AlignHCenter
                            text: qsTr("Page %1").arg(thumbnail.index + 1)
                            font.pixelSize: 11
                            color: thumbnail.highlighted ? app.colors.selectedFg : app.colors.textTertiary
                        }
                    }
                    onClicked: app.navigate(index)
                }
            }
            ListView {
                id: outline
                clip: true
                model: app.currentReader.data.outline || []
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                    required property var modelData
                    width: outline.width
                    height: Math.max(42, outlineText.implicitHeight + 18)
                    leftPadding: 12 + modelData.depth * 13
                    highlighted: modelData.page === app.currentPage
                    contentItem: Label {
                        id: outlineText
                        text: modelData.title
                        wrapMode: Text.Wrap
                        font.pixelSize: 12
                        color: app.colors.textPrimary
                    }
                    onClicked: if (modelData.page !== null)
                        app.navigate(modelData.page, modelData.y_pt || 0)
                }
                Label {
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
                clip: true
                model: app.bookmarks
                ScrollBar.vertical: ScrollBar {}
                delegate: ItemDelegate {
                    required property var modelData
                    required property int index
                    width: bookmarkList.width
                    height: 62
                    contentItem: RowLayout {
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3
                            Label {
                                text: modelData.title
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                            Label {
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
                    required property var modelData
                    readonly property var annotation: modelData.annotation
                    objectName: "annotationThreadRow_" + annotation.id
                    width: annotationList.width
                    leftPadding: 10 + Math.min(modelData.depth, 6) * 14
                    height: Math.max(68, annotationContent.implicitHeight + 20)
                    contentItem: ColumnLayout {
                        id: annotationContent
                        spacing: 4
                        RowLayout {
                            Label {
                                text: annotation.is_reply ? "↳ " + (annotation.author || qsTr("Reply")) : annotation.kind
                                color: app.colors.accent
                                font.pixelSize: 11
                                Layout.fillWidth: true
                            }
                            Label {
                                text: qsTr("p.%1").arg(annotation.page + 1)
                                color: app.colors.textTertiary
                                font.pixelSize: 11
                            }
                        }
                        Label {
                            id: annotationText
                            text: annotation.note || annotation.contents || qsTr("No text")
                            wrapMode: Text.Wrap
                            maximumLineCount: 4
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            font.pixelSize: 12
                        }
                        Label {
                            visible: !!annotation.modified
                            text: Logic.annotationDate(annotation.modified)
                            font.pixelSize: 10
                            color: app.colors.textTertiary
                        }
                        Label {
                            visible: modelData.orphanReason.length > 0
                            text: modelData.orphanReason
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            font.pixelSize: 10
                            color: app.colors.warningFg
                        }
                    }
                    onClicked: app.selectAnnotation(annotation)
                }
                Label {
                    anchors.centerIn: parent
                    visible: annotationList.count === 0
                    width: parent.width - 30
                    text: qsTr("No annotations yet.")
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: app.colors.textSecondary
                }
            }
            AiPanel {
                app: sidebarPanel.app
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
}

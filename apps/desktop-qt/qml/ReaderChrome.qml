import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: chrome
    required property var app
    spacing: 0
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
                        anchors.fill: parent
                        anchors.rightMargin: app.session ? 30 : 0
                        hoverEnabled: true
                        activeFocusOnTab: true
                        onClicked: {
                            forceActiveFocus();
                            if (app.session)
                                app.selectReaderTab(tab.index);
                        }
                        Keys.onReturnPressed: if (app.session)
                            app.selectReaderTab(tab.index)
                        Keys.onSpacePressed: if (app.session)
                            app.selectReaderTab(tab.index)
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
                text: qsTr("Fill & Sign")
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

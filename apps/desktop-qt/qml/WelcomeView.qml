import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ScrollView {
    id: welcome
    required property var app
    readonly property var recents: app.session ? app.session.recentDocuments : []
    clip: true
    contentWidth: availableWidth
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
    ColumnLayout {
        width: Math.min(560, welcome.availableWidth - 32)
        x: (welcome.availableWidth - width) / 2
        y: Math.max(20, (welcome.availableHeight - implicitHeight) / 2)
        spacing: 12
        Label {
            Layout.alignment: Qt.AlignHCenter
            text: "L"
            visible: welcome.height > 440
            color: app.colors.accent
            font.pixelSize: 46
            Accessible.ignored: true
        }
        Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: app.currentReader.loading ? qsTr("Opening your document") : qsTr("Make room for a good paper.")
            font.pixelSize: welcome.height < 400 ? 20 : 23
            font.weight: Font.Light
        }
        Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Drop a PDF here, or open one to begin.")
            color: app.colors.textSecondary
        }
        Button {
            id: primaryOpen
            objectName: "welcomeOpen"
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Open PDF…")
            visible: !app.currentReader.loading
            onClicked: app.openDialog()
            contentItem: Text {
                text: primaryOpen.text
                font: primaryOpen.font
                color: app.colors.onAccent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                implicitWidth: 130
                implicitHeight: 36
                radius: 4
                color: primaryOpen.down ? app.colors.accentPressed : primaryOpen.hovered ? app.colors.accentHover : app.colors.accent
                border.width: primaryOpen.visualFocus ? 2 : 0
                border.color: app.colors.focusRing
            }
        }
        BusyIndicator {
            Layout.alignment: Qt.AlignHCenter
            running: app.currentReader.loading
            visible: running
        }
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 12
            visible: welcome.recents.length > 0 && !app.currentReader.loading
            Label {
                text: qsTr("Recent documents")
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            ToolButton {
                objectName: "clearRecentDocuments"
                text: qsTr("Clear history")
                onClicked: app.session.clearRecentDocuments()
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Remove this list; your documents remain on disk.")
            }
        }
        ListView {
            objectName: "recentDocuments"
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(count, welcome.height < 400 ? 2 : 4) * 44
            visible: count > 0 && !app.currentReader.loading
            model: welcome.recents
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}
            delegate: ItemDelegate {
                required property var modelData
                required property int index
                objectName: "recentDocument" + index
                width: ListView.view.width
                height: 44
                text: modelData.title
                Accessible.name: qsTr("Open recent document %1").arg(modelData.title)
                Accessible.description: decodeURIComponent(modelData.url)
                ToolTip.visible: hovered
                ToolTip.text: decodeURIComponent(modelData.url)
                onClicked: app.session.openFile(modelData.url)
            }
        }
    }
}

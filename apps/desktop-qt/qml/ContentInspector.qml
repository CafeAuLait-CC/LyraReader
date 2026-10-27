import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Pane {
    id: inspector
    required property var app
    readonly property var editor: app.contentEditor
    readonly property var item: editor.selected
    padding: 12
    background: Rectangle {color:app.colors.sidebarBg;border.color:app.colors.separator}
    function sync() {
        const r=item ? item.bounds : {x:0,y:0,width:100,height:40};
        gx.text=String(r.x);gy.text=String(r.y);gw.text=String(r.width);gh.text=String(r.height);
        linkPage.value=item && item.link_page!==null ? item.link_page+1 : 1;
        linkUri.text=item && item.link_uri ? item.link_uri : "https://";
    }
    onItemChanged: sync()
    ColumnLayout {
        anchors.fill: parent
        RowLayout {
            Label {text:qsTr("Edit PDF");font.bold:true;Layout.fillWidth:true}
            LyraToolButton {symbol:"close";text:qsTr("Close PDF editing");onClicked:app.setSecondaryRow("")}
        }
        ScrollView {
            Layout.fillWidth:true
            Layout.fillHeight:true
            contentWidth: availableWidth
            ColumnLayout {
                width:parent.width
                spacing:10
                Label {
                    Layout.fillWidth:true;wrapMode:Text.Wrap;textFormat:Text.PlainText
                    text:editor.hasDraft && editor.draft.error ? qsTr("Your draft is preserved: %1").arg(editor.draft.error) :
                        editor.tool==="erase" || editor.tool==="blackout" ? qsTr("Drag a rectangle to remove actual PDF content. Undo restores the preceding revision.") :
                        item ? qsTr("%1 object").arg(item.kind) : qsTr("Select text, an image or a graphic. Double-click text to edit it; Control+Return applies.")
                    color:app.colors.textSecondary
                }
                RowLayout {
                    visible:editor.tool==="erase" || editor.tool==="blackout"
                    Button {text:qsTr("Erase");checkable:true;checked:editor.tool==="erase";onClicked:editor.arm("erase")}
                    Button {text:qsTr("Blackout");checkable:true;checked:editor.tool==="blackout";onClicked:editor.arm("blackout")}
                }
                Label {visible:!!item && item.kind==="text";text:qsTr("Text");font.bold:true}
                Button {
                    visible:!!item && item.kind==="text" && !editor.hasDraft
                    text:qsTr("Edit Text");enabled:!!item && item.can_edit_text
                    onClicked:editor.editText(item,editor.model.page)
                }
                Label {
                    visible:!!item && item.kind==="text" && !item.can_edit_text
                    textFormat:Text.PlainText;text:item ? item.reason || "" : ""
                    Layout.fillWidth:true;wrapMode:Text.Wrap;color:app.colors.textSecondary
                }
                TextArea {
                    objectName:"contentDraftText"
                    visible:editor.textDraft
                    Layout.fillWidth:true
                    Layout.preferredHeight:130
                    textFormat:TextEdit.PlainText;wrapMode:TextEdit.Wrap;selectByMouse:true
                    text:editor.textDraft ? (editor.payload.text || "") : ""
                    onTextChanged:if(visible && activeFocus)editor.changeText(text)
                    Accessible.name:qsTr("Preserved PDF text draft")
                }
                ComboBox {
                    visible:editor.textDraft
                    Layout.fillWidth:true
                    model:["Original","Helvetica","Helvetica-Bold","Helvetica-Oblique","Times-Roman","Times-Bold","Courier","LyraReader Sans SC"]
                    currentIndex:Math.max(0,model.indexOf(editor.payload.font || "Original"))
                    onActivated:editor.changeStyle({font:currentText})
                    Accessible.name:qsTr("PDF text font")
                }
                TextField {
                    visible:editor.textDraft
                    Layout.fillWidth:true
                    text:editor.textDraft ? String(editor.payload.size) : "12"
                    validator:DoubleValidator {bottom:1;top:1000;notation:DoubleValidator.StandardNotation}
                    onEditingFinished:if(acceptableInput)editor.changeStyle({size:Number(text)})
                    Accessible.name:qsTr("PDF font size in points")
                }
                RowLayout {
                    visible:editor.hasDraft
                    Button {objectName:"applyContentDraft";text:qsTr("Apply");enabled:editor.canCommit;onClicked:editor.commitDraft()}
                    Button {text:qsTr("Discard Draft");onClicked:editor.discard()}
                    Button {visible:editor.textDraft;text:qsTr("Copy");onClicked:if(app.session)app.session.copyText(editor.payload.text)}
                }
                Label {
                    visible:editor.hasDraft && editor.payload.revision!==editor.model.revision
                    text:qsTr("This draft belongs to an older page revision. Copy your text before discarding it and selecting the current object.")
                    Layout.fillWidth:true;wrapMode:Text.Wrap;color:app.colors.warningFg
                }
                Label {visible:!!item;text:qsTr("Geometry · page points");font.bold:true}
                GridLayout {
                    visible:!!item
                    columns:2
                    Layout.fillWidth:true
                    TextField {id:gx;Layout.fillWidth:true;placeholderText:"X";validator:DoubleValidator {}Accessible.name:qsTr("Object X")}
                    TextField {id:gy;Layout.fillWidth:true;placeholderText:"Y";validator:DoubleValidator {}Accessible.name:qsTr("Object Y")}
                    TextField {id:gw;Layout.fillWidth:true;placeholderText:qsTr("Width");validator:DoubleValidator {bottom:0.01}Accessible.name:qsTr("Object width")}
                    TextField {id:gh;Layout.fillWidth:true;placeholderText:qsTr("Height");validator:DoubleValidator {bottom:0.01}Accessible.name:qsTr("Object height")}
                }
                Button {
                    visible:!!item;text:qsTr("Apply Geometry");enabled:!editor.hasDraft && gx.acceptableInput && gy.acceptableInput && gw.acceptableInput && gh.acceptableInput
                    onClicked:editor.applyGeometry(item,{x:Number(gx.text),y:Number(gy.text),width:Number(gw.text),height:Number(gh.text)})
                }
                Button {
                    visible:!!item && item.kind==="image";text:qsTr("Replace Image…");enabled:!editor.hasDraft
                    onClicked:editor.chooseImage(item.bounds,item.id)
                }
                Label {visible:editor.tool==="link" || !!item && item.kind==="link";text:qsTr("Link destination");font.bold:true}
                ComboBox {id:linkKind;visible:editor.tool==="link" || !!item && item.kind==="link";model:[qsTr("Page"),qsTr("Web address")];Layout.fillWidth:true}
                SpinBox {id:linkPage;visible:linkKind.visible && linkKind.currentIndex===0;from:1;to:app.currentReader.pageCount;editable:true;Accessible.name:qsTr("Link page")}
                TextField {id:linkUri;visible:linkKind.visible && linkKind.currentIndex===1;Layout.fillWidth:true;Accessible.name:qsTr("Link web address")}
                Button {
                    visible:linkKind.visible;text:qsTr("Apply Link")
                    enabled:!editor.hasDraft && (!!item && item.kind==="link" || !!editor.gesture)
                    onClicked:editor.setLink(item && item.kind==="link" ? item.bounds : editor.gesture,
                        linkKind.currentIndex===0 ? linkPage.value-1 : null,linkKind.currentIndex===1 ? linkUri.text : null)
                }
                Button {
                    visible:!!item;text:qsTr("Delete Object");enabled:!editor.hasDraft
                    onClicked:editor.remove()
                }
                Item {Layout.fillHeight:true}
            }
        }
    }
}

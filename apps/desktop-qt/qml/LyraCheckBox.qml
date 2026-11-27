import QtQuick
import QtQuick.Controls

CheckBox {
    id:control
    required property var colors
    indicator:Rectangle {
        implicitWidth:16;implicitHeight:16
        x:control.mirrored ? control.width-control.rightPadding-width : control.leftPadding
        y:control.topPadding+(control.availableHeight-height)/2
        radius:2
        color:control.checked ? control.colors.selectedBg
            : control.down ? control.colors.pressedBg
            : control.hovered ? control.colors.hoverBg : control.colors.fieldBg
        border.color:control.enabled ? control.colors.controlBorder : control.colors.textDisabled
        Rectangle {
            objectName:"checkboxFocusRing"
            anchors.fill:parent;anchors.margins:-3;radius:4
            color:"transparent";border.width:2;border.color:control.colors.focusRing
            visible:control.enabled && control.visualFocus
        }
        Canvas {
            id:mark
            objectName:"checkboxMark"
            anchors.fill:parent;visible:control.checked
            property color strokeColor:control.enabled ? control.colors.selectedFg : control.colors.textDisabled
            onStrokeColorChanged:requestPaint()
            onVisibleChanged:if(visible)requestPaint()
            onPaint: {
                const context=getContext("2d");context.clearRect(0,0,width,height);
                context.strokeStyle=strokeColor;context.lineWidth=2;context.lineCap="round";context.lineJoin="round";
                context.beginPath();
                if(control.checkState===Qt.PartiallyChecked){context.moveTo(4,8);context.lineTo(12,8);}
                else {context.moveTo(4,8);context.lineTo(7,11);context.lineTo(12,5);}
                context.stroke();
            }
        }
    }
    onCheckStateChanged:if(mark)mark.requestPaint()
}

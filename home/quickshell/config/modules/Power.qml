import QtQuick
import "../core" as Core
import "../services" as Services

Item {
    id: root
    property var screen: null
    implicitWidth: 30
    implicitHeight: Core.Theme.moduleHeight
    Text {
        anchors.centerIn: parent
        text: Services.BatteryService.profileIcon(Services.BatteryService.profile)
        color: Core.Theme.accent
        font.family: Core.Theme.iconFont
        font.pixelSize: Core.Theme.iconSize
    }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            const p = root.mapToItem(null, 0, root.height);
            Core.PopupManager.toggle("battery", p.x + root.width / 2, p.y + Core.Theme.barMarginTop, root.screen);
        }
    }
}

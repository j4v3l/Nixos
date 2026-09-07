pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland

QtObject {
    id: root
    property string current: ""
    property string screenName: ""
    property real anchorCenter: 0
    property real anchorBottom: 0
    property bool contextMenuOpen: false
    property bool dnd: false

    readonly property var screens: Quickshell.screens
    readonly property var focusedScreen: {
        const monitor = Hyprland.focusedMonitor;
        return root.screens.find(s => monitor && s.name === monitor.name) || root.screens[0] || null;
    }
    readonly property var screen: root.screens.find(s => s.name === root.screenName) || root.focusedScreen

    onScreensChanged: root.reconcileScreens()

    function reconcileScreens() {
        if (root.current !== "" && !root.screens.some(s => s.name === root.screenName))
            root.close();
    }

    function isOpen(id, display) {
        return root.current === id && (!display || display.name === root.screenName);
    }

    function open(id, center, bottom, display) {
        const target = display || root.focusedScreen;
        if (!target) return;
        root.contextMenuOpen = false;
        root.anchorCenter = center;
        root.anchorBottom = bottom;
        root.screenName = target.name;
        root.current = id;
    }

    function toggle(id, center, bottom, display) {
        const target = display || root.focusedScreen;
        if (target && root.isOpen(id, target)) root.close();
        else root.open(id, center, bottom, target);
    }

    function close() {
        root.contextMenuOpen = false;
        root.current = "";
    }
}

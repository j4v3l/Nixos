import Quickshell
import Quickshell.Io

Scope {
    IpcHandler {
        target: "launcher"
        function toggle(): void { PopupManager.toggle("launcher", 0, 0); }
        function open(): void { PopupManager.open("launcher", 0, 0); }
        function close(): void { if (PopupManager.isOpen("launcher")) PopupManager.close(); }
    }
    IpcHandler {
        target: "theme"
        function toggle(): void { PopupManager.toggle("theme", 0, 0); }
        function open(): void { PopupManager.open("theme", 0, 0); }
        function close(): void { if (PopupManager.isOpen("theme")) PopupManager.close(); }
    }
    IpcHandler {
        target: "wallpaper"
        function toggle(): void { PopupManager.toggle("wallpaper", 0, 0); }
        function open(): void { PopupManager.open("wallpaper", 0, 0); }
        function close(): void { if (PopupManager.isOpen("wallpaper")) PopupManager.close(); }
    }
    IpcHandler {
        target: "clipboard"
        function toggle(): void { PopupManager.toggle("clipboard", 0, 0); }
        function open(): void { PopupManager.open("clipboard", 0, 0); }
        function close(): void { if (PopupManager.isOpen("clipboard")) PopupManager.close(); }
    }
    IpcHandler {
        target: "emoji"
        function toggle(): void { PopupManager.toggle("emoji", 0, 0); }
        function open(): void { PopupManager.open("emoji", 0, 0); }
        function close(): void { if (PopupManager.isOpen("emoji")) PopupManager.close(); }
    }
}

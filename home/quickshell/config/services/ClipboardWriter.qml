pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root
    property var queue: []
    property string current: ""

    function copy(text) {
        root.queue.push(String(text));
        root.next();
    }

    function next() {
        if (writer.running || root.queue.length === 0)
            return;
        root.current = root.queue.shift();
        writer.stdinEnabled = true;
        writer.running = true;
    }

    Process {
        id: writer
        command: ["wl-copy", "--type", "text/plain;charset=utf-8"]
        onStarted: {
            writer.write(root.current);
            writer.stdinEnabled = false;
        }
        onExited: function(code) {
            if (code !== 0)
                console.warn("Could not copy text to the Wayland clipboard");
            Qt.callLater(root.next);
        }
    }
}

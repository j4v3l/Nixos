pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    property var items: []
    property bool ready: false

    signal historyChanged

    function refresh() {
        listProcess.running = false;
        listProcess.running = true;
    }

    function paste(item) {
        if (!item)
            return;
        enqueue("paste", item.raw);
    }

    function remove(item) {
        if (!item)
            return;

        enqueue("delete", item.raw);
    }

    function clear() {
        enqueue("wipe", "");
    }

    property var operations: []
    property var operation: null

    function enqueue(action, raw) {
        root.operations.push({ action: action, raw: String(raw) });
        root.nextOperation();
    }

    function nextOperation() {
        if (actionProcess.running || root.operations.length === 0) return;
        root.operation = root.operations.shift();
        // Keep decoded image bytes in the pipe. History text is written to stdin.
        actionProcess.command = root.operation.action === "paste"
            ? ["bash", "-o", "pipefail", "-c", "cliphist decode | wl-copy"]
            : ["cliphist", root.operation.action];
        actionProcess.stdinEnabled = true;
        actionProcess.running = true;
    }

    Process {
        id: actionProcess
        onStarted: {
            actionProcess.write(root.operation.raw + "\n");
            actionProcess.stdinEnabled = false;
        }
        onExited: function(code) {
            if (code === 0 && root.operation.action === "paste") pasteDelay.restart();
            if (code !== 0) console.warn("Clipboard history operation failed");
            root.refresh();
            Qt.callLater(root.nextOperation);
        }
    }

    Timer {
        id: pasteDelay
        interval: 50
        onTriggered: Quickshell.execDetached(["wtype", "-M", "ctrl", "v", "-m", "ctrl"])
    }

    Process {
        id: listProcess

        command: ["cliphist", "list"]

        stdout: StdioCollector {
            onStreamFinished: {
                const output = text.trim();
                const result = [];

                if (output !== "") {
                    const lines = output.split("\n");

                    for (const line of lines) {
                        if (!line.trim())
                            continue;

                        const tab = line.indexOf("\t");

                        result.push({
                            raw: line,
                            text: tab >= 0 ? line.slice(tab + 1) : line
                        });
                    }
                }

                root.items = result;
                root.ready = true;
                root.historyChanged();
            }
        }
    }

    Process {
        id: watcher

        // No --type filter on purpose: cliphist stores images too, and pinning
        // this to text meant image copies never reached the history.
        command: ["wl-paste", "--watch", "cliphist", "store"]

        running: true

        // Restart via a timer instead of reassigning running here. The immediate
        // version was an unbounded busy loop any time wl-paste could not start at
        // all -- missing binary, or no Wayland display yet.
        onExited: watcherRestart.start()
    }

    Timer {
        id: watcherRestart

        interval: 2000
        repeat: false

        onTriggered: {
            if (!watcher.running)
                watcher.running = true;
        }
    }

    Component.onCompleted: {
        refresh();
    }
}

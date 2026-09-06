//@ pragma UseQApplication

import Quickshell
import Quickshell.Wayland

import "components"
import "modules"
import "core" as Core

Scope {
    id: root
    Core.LauncherIpc {}
    Variants {
        model: Quickshell.screens
        delegate: Bar {
            required property var modelData
            screen: modelData
        }
    }
    NetworkPopup {}
    BluetoothPopup {}
    BatteryPopup {}
    AudioPopup {}
    CalendarPopup {}
    NotificationPopup {}
    Notifications {}
}

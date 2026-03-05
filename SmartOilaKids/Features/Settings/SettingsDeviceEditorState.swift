import Foundation

struct SettingsDeviceEditorState {
    var isPresented = false
    var device: ConnectedDevice?
    var name: String = ""

    mutating func beginEditing(_ device: ConnectedDevice) {
        self.device = device
        self.name = device.name
        self.isPresented = true
    }

    mutating func clearSelection() {
        device = nil
    }

    mutating func close() {
        isPresented = false
        device = nil
        name = ""
    }
}

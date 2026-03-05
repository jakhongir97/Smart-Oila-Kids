import Foundation

extension SettingsViewModel {
    func normalizedDSN(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
    }

    func connectedDevice(matchingDSN dsn: String) -> ConnectedDevice? {
        connectedDevices.first { device in
            guard let remoteDSN = normalizedDSN(device.dsn) else { return false }
            return remoteDSN.caseInsensitiveCompare(dsn) == .orderedSame
        }
    }

    func isCurrentDevice(_ device: ConnectedDevice) -> Bool {
        guard let currentDSN = normalizedDSN(runtime.currentDSN),
              let deviceDSN = normalizedDSN(device.dsn) else {
            return false
        }
        return currentDSN.caseInsensitiveCompare(deviceDSN) == .orderedSame
    }

    func updateConnectedDeviceCache(with updated: ConnectedDevice) {
        var devices = connectedDevices
        if let index = devices.firstIndex(where: { $0.id == updated.id }) {
            devices[index] = updated
            setConnectedDevices(devices)
            dependencies.cacheStore.saveConnectedDevices(devices)
            return
        }

        devices.append(updated)
        setConnectedDevices(devices)
        dependencies.cacheStore.saveConnectedDevices(devices)
    }

    func replaceConnectedDevices(_ devices: [ConnectedDevice]) {
        setConnectedDevices(devices)
        dependencies.cacheStore.saveConnectedDevices(devices)
    }

    func clearRemoteProfileName() {
        setRemoteProfileName(nil)
        dependencies.cacheStore.saveProfileName(nil)
    }
}

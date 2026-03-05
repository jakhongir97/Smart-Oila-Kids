import Foundation

extension SettingsViewModel {
    func loadIfNeeded(currentDSN: String?) async {
        let normalizedCurrentDSN = normalizedDSN(currentDSN)
        guard !(runtime.didLoad && runtime.currentDSN == normalizedCurrentDSN) else { return }

        runtime.didLoad = true
        runtime.currentDSN = normalizedCurrentDSN

        let cachedDevices = dependencies.cacheStore.loadConnectedDevices()
        if !cachedDevices.isEmpty {
            setConnectedDevices(cachedDevices)
            runtime.hasLoadedRemoteDeviceNames = true
        }

        if let cachedProfileName = dependencies.cacheStore.loadProfileName() {
            setRemoteProfileName(cachedProfileName)
        }

        if let devices = try? await dependencies.service.fetchConnectedDevices() {
            replaceConnectedDevices(devices)
            runtime.hasLoadedRemoteDeviceNames = true
        }

        if let normalizedCurrentDSN,
           let matched = connectedDevice(matchingDSN: normalizedCurrentDSN) {
            setRemoteProfileName(matched.name)
            return
        }

        if let name = try? await dependencies.service.fetchProfileName() {
            setRemoteProfileName(name)
            dependencies.cacheStore.saveProfileName(name)
        }
    }

    func ensureConnectedDevicesLoadedIfNeeded(required: Bool) async throws {
        guard !runtime.hasLoadedRemoteDeviceNames else { return }

        if required {
            let devices = try await dependencies.service.fetchConnectedDevices()
            setConnectedDevices(devices)
            runtime.hasLoadedRemoteDeviceNames = true
            return
        }

        if let devices = try? await dependencies.service.fetchConnectedDevices() {
            setConnectedDevices(devices)
            runtime.hasLoadedRemoteDeviceNames = true
        }
    }
}

import Foundation

extension SettingsViewModel {
    func renameDevice(deviceID: Int, name: String) async throws -> String {
        guard !isUpdatingDevice else { return name }
        setUpdatingDevice(true)
        defer { setUpdatingDevice(false) }

        let updated = try await dependencies.service.renameConnectedDevice(deviceID: deviceID, name: name)
        updateConnectedDeviceCache(with: updated)
        return updated.name
    }

    func deleteDevice(deviceID: Int) async throws -> Bool {
        guard !isUpdatingDevice else { return false }
        setUpdatingDevice(true)
        defer { setUpdatingDevice(false) }

        try? await ensureConnectedDevicesLoadedIfNeeded(required: false)

        let target = connectedDevices.first { $0.id == deviceID }
        try await dependencies.service.deleteConnectedDevice(deviceID: deviceID)

        let filtered = connectedDevices.filter { $0.id != deviceID }
        replaceConnectedDevices(filtered)

        guard let target else { return false }
        let deletedCurrentDevice = isCurrentDevice(target)
        if deletedCurrentDevice {
            clearRemoteProfileName()
        }
        return deletedCurrentDevice
    }

    func uploadCurrentDeviceAvatar(dsn: String?, imageData: Data) async throws -> URL? {
        guard let normalized = normalizedDSN(dsn) else {
            throw NetworkError.unexpectedBody
        }

        guard !isUploadingAvatar else {
            return currentAvatarURL(for: normalized)
        }

        setUploadingAvatar(true)
        defer { setUploadingAvatar(false) }

        try? await ensureConnectedDevicesLoadedIfNeeded(required: false)

        let target: ConnectedDevice
        if let cached = connectedDevice(matchingDSN: normalized) {
            target = cached
        } else {
            target = try await dependencies.service.resolveConnectedDevice(dsn: normalized)
            updateConnectedDeviceCache(with: target)
        }

        let updated = try await dependencies.service.uploadConnectedDeviceAvatar(
            deviceID: target.id,
            imageData: imageData
        )
        updateConnectedDeviceCache(with: updated)
        return updated.avatarURL
    }

    func currentAvatarURL(for dsn: String?) -> URL? {
        guard let normalized = normalizedDSN(dsn) else {
            return nil
        }
        return connectedDevice(matchingDSN: normalized)?.avatarURL
    }

    func deleteCurrentDeviceSession(dsn: String?) async throws {
        guard let normalized = normalizedDSN(dsn) else {
            return
        }

        guard !isUpdatingDevice else { return }
        setUpdatingDevice(true)
        defer { setUpdatingDevice(false) }

        try await ensureConnectedDevicesLoadedIfNeeded(required: true)

        let target: ConnectedDevice
        if let cached = connectedDevice(matchingDSN: normalized) {
            target = cached
        } else if let resolved = try? await dependencies.service.resolveConnectedDevice(dsn: normalized) {
            target = resolved
            updateConnectedDeviceCache(with: resolved)
        } else {
            return
        }

        try await dependencies.service.deleteConnectedDevice(deviceID: target.id)
        let filtered = connectedDevices.filter { $0.id != target.id }
        replaceConnectedDevices(filtered)

        if let currentDSN = normalizedDSN(runtime.currentDSN),
           currentDSN.caseInsensitiveCompare(normalized) == .orderedSame {
            clearRemoteProfileName()
        }
    }
}

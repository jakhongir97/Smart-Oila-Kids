import Foundation

protocol SettingsCacheStoring {
    func loadProfileName() -> String?
    func saveProfileName(_ value: String?)
    func loadConnectedDevices() -> [ConnectedDevice]
    func saveConnectedDevices(_ devices: [ConnectedDevice])
}

final class SettingsCacheStore: SettingsCacheStoring {
    static let shared = SettingsCacheStore()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadProfileName() -> String? {
        userDefaults.string(forKey: profileNameKey)?.trimmedNonEmpty
    }

    func saveProfileName(_ value: String?) {
        guard let value = value?.trimmedNonEmpty else {
            userDefaults.removeObject(forKey: profileNameKey)
            return
        }
        userDefaults.set(value, forKey: profileNameKey)
    }

    func loadConnectedDevices() -> [ConnectedDevice] {
        guard let data = userDefaults.data(forKey: connectedDevicesKey),
              let payload = try? JSONDecoder().decode([CachedConnectedDevice].self, from: data) else {
            return []
        }

        return payload.map {
            ConnectedDevice(
                id: $0.id,
                dsn: $0.dsn,
                name: $0.name,
                avatarURL: $0.avatarURL.flatMap(URL.init(string:))
            )
        }
    }

    func saveConnectedDevices(_ devices: [ConnectedDevice]) {
        let payload = devices.map {
            CachedConnectedDevice(
                id: $0.id,
                dsn: $0.dsn,
                name: $0.name,
                avatarURL: $0.avatarURL?.absoluteString
            )
        }

        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: connectedDevicesKey)
    }

    private struct CachedConnectedDevice: Codable {
        let id: Int
        let dsn: String?
        let name: String
        let avatarURL: String?
    }

    private let userDefaults: UserDefaults
    private let profileNameKey = "SETTINGS_CACHE_PROFILE_NAME"
    private let connectedDevicesKey = "SETTINGS_CACHE_CONNECTED_DEVICES"
}

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var connectedDevices: [ConnectedDevice] = []
    @Published private(set) var remoteProfileName: String?
    @Published private(set) var isSaving = false
    @Published private(set) var isUpdatingDevice = false
    @Published private(set) var isUploadingAvatar = false

    init(
        service: SettingsServicing,
        cacheStore: SettingsCacheStoring = SettingsCacheStore.shared
    ) {
        self.service = service
        self.cacheStore = cacheStore
    }

    func loadIfNeeded(currentDSN: String?) async {
        let normalizedDSN = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(didLoad && self.currentDSN == normalizedDSN) else { return }
        didLoad = true
        self.currentDSN = normalizedDSN

        let cachedDevices = cacheStore.loadConnectedDevices()
        if !cachedDevices.isEmpty {
            connectedDevices = cachedDevices
            hasLoadedRemoteDeviceNames = true
        }

        if let cachedProfileName = cacheStore.loadProfileName() {
            remoteProfileName = cachedProfileName
        }

        if let devices = try? await service.fetchConnectedDevices() {
            connectedDevices = devices
            hasLoadedRemoteDeviceNames = true
            cacheStore.saveConnectedDevices(devices)
        }

        if let normalizedDSN,
           let matched = connectedDevices.first(where: { device in
               guard let remoteDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                   return false
               }
               return remoteDSN.caseInsensitiveCompare(normalizedDSN) == .orderedSame
           }) {
            remoteProfileName = matched.name
            return
        }

        if let name = try? await service.fetchProfileName() {
            remoteProfileName = name
            cacheStore.saveProfileName(name)
        }
    }

    func saveProfileName(_ name: String, currentDSN: String?) async throws -> String {
        guard !isSaving else {
            return remoteProfileName ?? name
        }

        isSaving = true
        defer { isSaving = false }

        let normalizedDSN = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedDSN, !normalizedDSN.isEmpty {
            if !hasLoadedRemoteDeviceNames {
                if let devices = try? await service.fetchConnectedDevices() {
                    connectedDevices = devices
                    hasLoadedRemoteDeviceNames = true
                }
            }

            if let target = connectedDevices.first(where: { device in
                guard let remoteDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return false
                }
                return remoteDSN.caseInsensitiveCompare(normalizedDSN) == .orderedSame
            }) {
                let updated = try await service.renameConnectedDevice(deviceID: target.id, name: name)
                updateConnectedDeviceCache(with: updated)
                remoteProfileName = updated.name
                cacheStore.saveProfileName(updated.name)
                return updated.name
            }

            if let resolved = try? await service.resolveConnectedDevice(dsn: normalizedDSN) {
                let updated = try await service.renameConnectedDevice(deviceID: resolved.id, name: name)
                updateConnectedDeviceCache(with: updated)
                remoteProfileName = updated.name
                cacheStore.saveProfileName(updated.name)
                return updated.name
            }
        }

        let resolvedName = try await service.updateProfileName(name)
        remoteProfileName = resolvedName
        cacheStore.saveProfileName(resolvedName)
        return resolvedName
    }

    func renameDevice(deviceID: Int, name: String) async throws -> String {
        guard !isUpdatingDevice else { return name }
        isUpdatingDevice = true
        defer { isUpdatingDevice = false }

        let updated = try await service.renameConnectedDevice(deviceID: deviceID, name: name)
        updateConnectedDeviceCache(with: updated)
        return updated.name
    }

    func deleteDevice(deviceID: Int) async throws -> Bool {
        guard !isUpdatingDevice else { return false }
        isUpdatingDevice = true
        defer { isUpdatingDevice = false }

        if !hasLoadedRemoteDeviceNames {
            if let devices = try? await service.fetchConnectedDevices() {
                connectedDevices = devices
                hasLoadedRemoteDeviceNames = true
            }
        }

        let target = connectedDevices.first { $0.id == deviceID }
        try await service.deleteConnectedDevice(deviceID: deviceID)

        connectedDevices.removeAll { $0.id == deviceID }
        cacheStore.saveConnectedDevices(connectedDevices)

        guard let target else { return false }
        let deletedCurrentDevice = isCurrentDevice(target)
        if deletedCurrentDevice {
            remoteProfileName = nil
            cacheStore.saveProfileName(nil)
        }
        return deletedCurrentDevice
    }

    func uploadCurrentDeviceAvatar(dsn: String?, imageData: Data) async throws -> URL? {
        guard let dsn = dsn?.trimmingCharacters(in: .whitespacesAndNewlines), !dsn.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        guard !isUploadingAvatar else {
            return currentAvatarURL(for: dsn)
        }

        isUploadingAvatar = true
        defer { isUploadingAvatar = false }

        if !hasLoadedRemoteDeviceNames {
            if let devices = try? await service.fetchConnectedDevices() {
                connectedDevices = devices
                hasLoadedRemoteDeviceNames = true
            }
        }

        let target: ConnectedDevice
        if let cached = connectedDevices.first(where: { device in
            guard let remoteDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return remoteDSN.caseInsensitiveCompare(dsn) == .orderedSame
        }) {
            target = cached
        } else {
            target = try await service.resolveConnectedDevice(dsn: dsn)
            updateConnectedDeviceCache(with: target)
        }

        let updated = try await service.uploadConnectedDeviceAvatar(deviceID: target.id, imageData: imageData)
        updateConnectedDeviceCache(with: updated)
        return updated.avatarURL
    }

    func currentAvatarURL(for dsn: String?) -> URL? {
        guard let dsn = dsn?.trimmingCharacters(in: .whitespacesAndNewlines), !dsn.isEmpty else {
            return nil
        }
        return connectedDevices.first(where: { device in
            guard let remoteDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return remoteDSN.caseInsensitiveCompare(dsn) == .orderedSame
        })?.avatarURL
    }

    func deleteCurrentDeviceSession(dsn: String?) async throws {
        guard let dsn = dsn?.trimmingCharacters(in: .whitespacesAndNewlines), !dsn.isEmpty else {
            return
        }

        guard !isUpdatingDevice else { return }
        isUpdatingDevice = true
        defer { isUpdatingDevice = false }

        if !hasLoadedRemoteDeviceNames {
            let devices = try await service.fetchConnectedDevices()
            connectedDevices = devices
            hasLoadedRemoteDeviceNames = true
        }

        let target: ConnectedDevice
        if let cached = connectedDevices.first(where: { device in
            guard let remoteDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return remoteDSN.caseInsensitiveCompare(dsn) == .orderedSame
        }) {
            target = cached
        } else if let resolved = try? await service.resolveConnectedDevice(dsn: dsn) {
            target = resolved
            updateConnectedDeviceCache(with: resolved)
        } else {
            return
        }

        try await service.deleteConnectedDevice(deviceID: target.id)
        connectedDevices.removeAll { $0.id == target.id }
        cacheStore.saveConnectedDevices(connectedDevices)

        if let currentDSN = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines),
           currentDSN.caseInsensitiveCompare(dsn) == .orderedSame {
            remoteProfileName = nil
            cacheStore.saveProfileName(nil)
        }
    }

    private let service: SettingsServicing
    private let cacheStore: SettingsCacheStoring
    private var didLoad = false
    private var hasLoadedRemoteDeviceNames = false
    private var currentDSN: String?

    private func isCurrentDevice(_ device: ConnectedDevice) -> Bool {
        guard let currentDSN = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines),
              !currentDSN.isEmpty,
              let deviceDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceDSN.isEmpty else {
            return false
        }
        return currentDSN.caseInsensitiveCompare(deviceDSN) == .orderedSame
    }

    private func updateConnectedDeviceCache(with updated: ConnectedDevice) {
        if let index = connectedDevices.firstIndex(where: { $0.id == updated.id }) {
            connectedDevices[index] = updated
            cacheStore.saveConnectedDevices(connectedDevices)
            return
        }
        connectedDevices.append(updated)
        cacheStore.saveConnectedDevices(connectedDevices)
    }
}

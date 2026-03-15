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
                avatarURL: RemoteAssetURLResolver.resolveURL($0.avatarURL)
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

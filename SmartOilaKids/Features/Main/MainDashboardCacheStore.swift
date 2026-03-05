import Foundation

final class MainDashboardCacheStore {
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func saveStatus(_ status: MainDeviceStatus, for dsn: String) {
        let payload = CachedDeviceStatus(
            deviceName: status.deviceName,
            battery: status.battery,
            connectionType: status.connectionType,
            soundMode: status.soundMode,
            latitude: status.latitude,
            longitude: status.longitude,
            cachedAt: Date()
        )

        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: cacheKey(for: dsn))
    }

    func status(for dsn: String) -> MainDeviceStatus? {
        guard let data = userDefaults.data(forKey: cacheKey(for: dsn)),
              let payload = try? JSONDecoder().decode(CachedDeviceStatus.self, from: data) else {
            return nil
        }

        return MainDeviceStatus(
            deviceName: payload.deviceName,
            battery: payload.battery,
            connectionType: payload.connectionType,
            soundMode: payload.soundMode,
            latitude: payload.latitude,
            longitude: payload.longitude
        )
    }

    func saveWeeklyUsage(_ hours: [Double], for dsn: String) {
        let normalized = normalizeWeeklyUsage(hours)
        let payload = CachedWeeklyUsage(hours: normalized, cachedAt: Date())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: weeklyUsageCacheKey(for: dsn))
    }

    func weeklyUsage(for dsn: String) -> [Double]? {
        guard let data = userDefaults.data(forKey: weeklyUsageCacheKey(for: dsn)),
              let payload = try? JSONDecoder().decode(CachedWeeklyUsage.self, from: data) else {
            return nil
        }

        return normalizeWeeklyUsage(payload.hours)
    }

    private let userDefaults: UserDefaults

    private func normalizeWeeklyUsage(_ value: [Double]) -> [Double] {
        var normalized = value.prefix(7).map { max(0, $0) }
        if normalized.count < 7 {
            normalized.append(contentsOf: Array(repeating: 0, count: 7 - normalized.count))
        }
        return normalized
    }

    private func cacheKey(for dsn: String) -> String {
        DSNScopedStorage.userDefaultsKey(prefix: "MAIN_DEVICE_STATUS_CACHE_", dsn: dsn)
    }

    private func weeklyUsageCacheKey(for dsn: String) -> String {
        DSNScopedStorage.userDefaultsKey(prefix: "MAIN_WEEKLY_USAGE_CACHE_", dsn: dsn)
    }
}

private struct CachedDeviceStatus: Codable {
    let deviceName: String
    let battery: Int?
    let connectionType: String?
    let soundMode: String?
    let latitude: Double?
    let longitude: Double?
    let cachedAt: Date
}

private struct CachedWeeklyUsage: Codable {
    let hours: [Double]
    let cachedAt: Date
}

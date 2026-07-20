import Foundation

struct DeviceAppLimitResponse: Decodable, Equatable {
    let packageName: String
    let dailyLimitMinutes: Int
    let isLimitEnabled: Bool
    let usedTodaySeconds: Int
    let remainingTodaySeconds: Int
    let isLimitReached: Bool

    private enum CodingKeys: String, CodingKey {
        case packageName = "package_name"
        case dailyLimitMinutes = "daily_limit_minutes"
        case isLimitEnabled = "is_limit_enabled"
        case usedTodaySeconds = "used_today_seconds"
        case remainingTodaySeconds = "remaining_today_seconds"
        case isLimitReached = "is_limit_reached"
    }
}

struct DeviceAppLimitFetchResult {
    let deviceID: Int
    let endpoint: String
    let limits: [DeviceAppLimitResponse]
}

protocol DeviceAppLimitServicing {
    func fetchLimits(dsn: String) async throws -> DeviceAppLimitFetchResult
}

/// PARKED transport (legacy backend decommissioned; runs only behind the Screen-Time flag,
/// off in v1). Reimplement against the oila360 device API when v1.1 enforcement ships —
/// the per-app limit state already arrives in the `POST /device/apps/usage` response.
final class DeviceAppLimitService: DeviceAppLimitServicing {
    init() {}

    func fetchLimits(dsn: String) async throws -> DeviceAppLimitFetchResult {
        throw NetworkError.invalidURL
    }
}

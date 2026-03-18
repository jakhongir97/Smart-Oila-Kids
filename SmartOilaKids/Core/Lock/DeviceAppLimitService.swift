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

final class DeviceAppLimitService: DeviceAppLimitServicing {
    init(
        client: APIClient = APIClient(),
        memberDevicesService: MemberDevicesServicing = MemberDevicesService()
    ) {
        self.client = client
        self.memberDevicesService = memberDevicesService
    }

    func fetchLimits(dsn: String) async throws -> DeviceAppLimitFetchResult {
        let device = try await memberDevicesService.resolveDevice(byDSN: dsn, limit: 100)
        let endpoint = "members/device/v2/\(device.id)/applications?is_limit_enabled=true"
        let limits: [DeviceAppLimitResponse] = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: endpoint,
            method: .get,
            headers: ["Accept": "application/json"],
            as: [DeviceAppLimitResponse].self
        )

        return DeviceAppLimitFetchResult(
            deviceID: device.id,
            endpoint: endpoint,
            limits: limits
        )
    }

    private let client: APIClient
    private let memberDevicesService: MemberDevicesServicing
}

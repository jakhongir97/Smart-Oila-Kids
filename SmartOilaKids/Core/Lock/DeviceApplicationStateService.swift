import Foundation

struct DeviceApplicationRecord: Decodable, Equatable {
    let packageName: String
    let name: String
    let isLocked: Bool
    let lockEndTime: String?

    enum CodingKeys: String, CodingKey {
        case packageName = "package_name"
        case name
        case isLocked = "is_locked"
        case lockEndTime = "lock_end_time"
    }
}

struct DeviceApplicationStateFetchResult {
    let deviceID: Int
    let applicationsEndpoint: String
    let applications: [DeviceApplicationRecord]

    var remoteLockedApplications: [DeviceAppSelectionApplication] {
        applications.compactMap { application in
            guard application.isLocked else { return nil }
            return Self.makeApplicationIdentity(from: application)
        }
        .sorted { lhs, rhs in
            lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    var remoteLockedIdentifiers: Set<String> {
        Set(remoteLockedApplications.map(\.packageName))
    }

    var payloadSummary: String {
        "\(applications.count) apps, \(remoteLockedIdentifiers.count) locked"
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    private static func makeApplicationIdentity(from record: DeviceApplicationRecord) -> DeviceAppSelectionApplication? {
        guard let packageName = normalizedIdentifier(record.packageName) else {
            return nil
        }

        let appName = record.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? ProductFallbackText.appName()

        return DeviceAppSelectionApplication(
            packageName: packageName,
            appName: appName
        )
    }
}

protocol DeviceApplicationStateServicing {
    func fetchState(dsn: String) async throws -> DeviceApplicationStateFetchResult
}

final class DeviceApplicationStateService: DeviceApplicationStateServicing {
    init(
        client: APIClient = APIClient(),
        memberDevicesService: MemberDevicesServicing = MemberDevicesService()
    ) {
        self.client = client
        self.memberDevicesService = memberDevicesService
    }

    func fetchState(dsn: String) async throws -> DeviceApplicationStateFetchResult {
        let device = try await memberDevicesService.resolveDevice(byDSN: dsn, limit: 100)
        let applicationsEndpoint = "members/device/v2/\(device.id)/applications"

        async let applicationsTask: [DeviceApplicationRecord]? = client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: applicationsEndpoint,
            method: .get,
            headers: ["Accept": "application/json"],
            as: Optional<[DeviceApplicationRecord]>.self
        )

        let applications = try await applicationsTask ?? []

        return DeviceApplicationStateFetchResult(
            deviceID: device.id,
            applicationsEndpoint: applicationsEndpoint,
            applications: applications
        )
    }

    private let client: APIClient
    private let memberDevicesService: MemberDevicesServicing
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

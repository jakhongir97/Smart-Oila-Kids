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
    let lockedEndpoint: String
    let applications: [DeviceApplicationRecord]
    let lockedApplications: [DeviceApplicationRecord]

    var authoritativeLockedApplications: [DeviceAppSelectionApplication] {
        var resolved: [String: DeviceAppSelectionApplication] = [:]
        let genericFallbackName = ProductFallbackText.appName()

        for application in applications where application.isLocked {
            guard let normalized = Self.makeApplicationIdentity(from: application) else { continue }
            resolved[normalized.packageName] = normalized
        }

        for application in lockedApplications {
            guard let normalized = Self.makeApplicationIdentity(from: application) else { continue }

            if let existing = resolved[normalized.packageName],
               existing.appName != existing.packageName,
               existing.appName != genericFallbackName {
                continue
            }

            resolved[normalized.packageName] = normalized
        }

        return resolved.values.sorted { lhs, rhs in
            lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    var authoritativeLockedIdentifiers: Set<String> {
        Set(authoritativeLockedApplications.map(\.packageName))
    }

    var payloadSummary: String {
        "\(applications.count) apps, \(authoritativeLockedIdentifiers.count) locked"
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
        let lockedEndpoint = "-"

        async let applicationsTask: [DeviceApplicationRecord]? = client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: applicationsEndpoint,
            method: .get,
            headers: ["Accept": "application/json"],
            as: Optional<[DeviceApplicationRecord]>.self
        )

        let applications = try await applicationsTask ?? []
        let lockedApplications: [DeviceApplicationRecord] = []

        return DeviceApplicationStateFetchResult(
            deviceID: device.id,
            applicationsEndpoint: applicationsEndpoint,
            lockedEndpoint: lockedEndpoint,
            applications: applications,
            lockedApplications: lockedApplications
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

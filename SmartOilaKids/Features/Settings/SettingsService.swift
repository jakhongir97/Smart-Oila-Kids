import Foundation

struct ConnectedDevice: Identifiable, Equatable {
    let id: Int
    let dsn: String?
    let name: String
}

protocol SettingsServicing {
    func fetchProfileName() async throws -> String
    func fetchConnectedDevices(limit: Int) async throws -> [ConnectedDevice]
    func resolveConnectedDevice(dsn: String) async throws -> ConnectedDevice
    func updateProfileName(_ name: String) async throws -> String
    func renameConnectedDevice(deviceID: Int, name: String) async throws -> ConnectedDevice
    func deleteConnectedDevice(deviceID: Int) async throws
}

extension SettingsServicing {
    func fetchConnectedDevices() async throws -> [ConnectedDevice] {
        try await fetchConnectedDevices(limit: 50)
    }
}

final class SettingsService: SettingsServicing {
    init(client: APIClient = APIClient(), memberDevicesService: MemberDevicesServicing? = nil) {
        self.client = client
        self.memberDevicesService = memberDevicesService ?? MemberDevicesService(client: client)
    }

    func fetchProfileName() async throws -> String {
        try ensureAuthorized()

        let profile: MemberProfile = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "members/me",
            method: .get,
            headers: ["Accept": "application/json"],
            as: MemberProfile.self
        )

        if let name = profile.resolvedName?.trimmedNonEmpty {
            return name
        }

        throw NetworkError.unexpectedBody
    }

    func fetchConnectedDevices(limit: Int) async throws -> [ConnectedDevice] {
        let records = try await memberDevicesService.fetchDevices(limit: limit)
        return records.map { record in
            ConnectedDevice(id: record.id, dsn: record.dsn, name: record.name)
        }
    }

    func resolveConnectedDevice(dsn: String) async throws -> ConnectedDevice {
        try ensureAuthorized()
        let record = try await memberDevicesService.resolveDevice(byDSN: dsn, limit: 100)
        return ConnectedDevice(id: record.id, dsn: record.dsn, name: record.name)
    }

    func updateProfileName(_ name: String) async throws -> String {
        try ensureAuthorized()
        let payload = MemberProfileUpdate(name: name, region: nil)
        let body = try JSONEncoder().encode(payload)

        let profile: MemberProfile = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "members/me",
            method: .put,
            headers: ["Accept": "application/json"],
            body: body,
            contentType: "application/json",
            as: MemberProfile.self
        )

        return profile.resolvedName?.trimmedNonEmpty ?? name
    }

    func renameConnectedDevice(deviceID: Int, name: String) async throws -> ConnectedDevice {
        try ensureAuthorized()
        let payload = ConnectedDeviceRenameRequest(name: name)
        let body = try JSONEncoder().encode(payload)
        let response: MemberDevice = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/\(deviceID)",
            method: .put,
            headers: ["Accept": "application/json"],
            body: body,
            contentType: "application/json",
            as: MemberDevice.self
        )

        let resolvedName = response.resolvedName?.trimmedNonEmpty ?? name
        return ConnectedDevice(id: deviceID, dsn: response.dsn?.trimmedNonEmpty, name: resolvedName)
    }

    func deleteConnectedDevice(deviceID: Int) async throws {
        try ensureAuthorized()
        _ = try await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/\(deviceID)",
            method: .delete,
            headers: ["Accept": "application/json"]
        )
    }

    private let client: APIClient
    private let memberDevicesService: MemberDevicesServicing
    private let userDefaults: UserDefaults = .standard

    private func ensureAuthorized() throws {
        guard userDefaults.string(forKey: "API_ACCESS_TOKEN")?.trimmedNonEmpty != nil else {
            throw NetworkError.server(statusCode: 401, body: "Not authenticated")
        }
    }
}

private struct MemberProfile: Decodable {
    let name: String?
    let username: String?
    let fullName: String?
    let data: Nested?

    struct Nested: Decodable {
        let name: String?
        let username: String?
        let fullName: String?
    }

    var resolvedName: String? {
        name ?? username ?? fullName ?? data?.name ?? data?.username ?? data?.fullName
    }

    enum CodingKeys: String, CodingKey {
        case name
        case username
        case fullName = "full_name"
        case data
    }
}

private struct MemberProfileUpdate: Encodable {
    let name: String?
    let region: String?
}

private struct ConnectedDeviceRenameRequest: Encodable {
    let name: String
}

private struct MemberDevice: Decodable {
    let id: Int?
    let dsn: String?
    let name: String?
    let username: String?
    let fullName: String?

    var resolvedName: String? {
        name ?? username ?? fullName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case dsn
        case name
        case username
        case fullName = "full_name"
    }
}

import Foundation

protocol SettingsServicing {
    func fetchProfileName() async throws -> String
    func fetchConnectedDeviceNames(limit: Int) async throws -> [String]
    func updateProfileName(_ name: String) async throws -> String
}

extension SettingsServicing {
    func fetchConnectedDeviceNames() async throws -> [String] {
        try await fetchConnectedDeviceNames(limit: 50)
    }
}

final class SettingsService: SettingsServicing {
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func fetchProfileName() async throws -> String {
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

    func fetchConnectedDeviceNames(limit: Int) async throws -> [String] {
        let response: MembersDevicesResponse = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "members/me/devices",
            method: .get,
            queryItems: [
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ],
            headers: ["Accept": "application/json"],
            as: MembersDevicesResponse.self
        )

        let names = response.devices
            .compactMap(\.resolvedName)
            .compactMap(\.trimmedNonEmpty)

        return uniqueStableValues(in: names)
    }

    func updateProfileName(_ name: String) async throws -> String {
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

    private func uniqueStableValues(in values: [String]) -> [String] {
        var visited = Set<String>()
        var unique: [String] = []

        for value in values where visited.insert(value).inserted {
            unique.append(value)
        }

        return unique
    }

    private let client: APIClient
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

private struct MemberDevice: Decodable {
    let name: String?
    let username: String?
    let fullName: String?

    var resolvedName: String? {
        name ?? username ?? fullName
    }

    enum CodingKeys: String, CodingKey {
        case name
        case username
        case fullName = "full_name"
    }
}

private enum MembersDevicesResponse: Decodable {
    case array([MemberDevice])
    case envelope(Envelope)

    struct Envelope: Decodable {
        let data: [MemberDevice]?
        let results: [MemberDevice]?
        let devices: [MemberDevice]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let items = try? container.decode([MemberDevice].self) {
            self = .array(items)
            return
        }

        if let envelope = try? container.decode(Envelope.self) {
            self = .envelope(envelope)
            return
        }

        throw DecodingError.typeMismatch(
            MembersDevicesResponse.self,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported devices response shape")
        )
    }

    var devices: [MemberDevice] {
        switch self {
        case let .array(items):
            return items
        case let .envelope(payload):
            return payload.data ?? payload.results ?? payload.devices ?? []
        }
    }
}

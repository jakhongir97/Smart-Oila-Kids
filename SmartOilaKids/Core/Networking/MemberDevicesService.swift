import Foundation

struct MemberDeviceRecord: Identifiable, Equatable {
    let id: Int
    let dsn: String?
    let name: String
    let avatarURL: URL?
}

protocol MemberDevicesServicing {
    func fetchDevices(limit: Int) async throws -> [MemberDeviceRecord]
    func resolveDevice(byDSN dsn: String, limit: Int) async throws -> MemberDeviceRecord
}

extension MemberDevicesServicing {
    func fetchDevices() async throws -> [MemberDeviceRecord] {
        try await fetchDevices(limit: 100)
    }

    func resolveDevice(byDSN dsn: String) async throws -> MemberDeviceRecord {
        try await resolveDevice(byDSN: dsn, limit: 100)
    }
}

final class MemberDevicesService: MemberDevicesServicing {
    init(
        client: APIClient = APIClient(),
        secureTokens: SecureTokenStoring = SecureTokenStore.shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.client = client
        self.secureTokens = secureTokens
        self.userDefaults = userDefaults
    }

    func fetchDevices(limit: Int) async throws -> [MemberDeviceRecord] {
        guard hasAuthorization else {
            return cachedRecords(limit: limit)
        }

        do {
            let response: MembersDevicesResponse = try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "members/me/devices",
                method: .get,
                queryItems: [
                    URLQueryItem(name: "offset", value: "0"),
                    URLQueryItem(name: "limit", value: "\(max(1, min(limit, 500)))")
                ],
                headers: ["Accept": "application/json"],
                as: MembersDevicesResponse.self
            )

            let sortedDevices = response.devices.sorted { lhs, rhs in
                (lhs.id ?? 0) < (rhs.id ?? 0)
            }

            var visited = Set<Int>()
            let records: [MemberDeviceRecord] = sortedDevices.compactMap { item -> MemberDeviceRecord? in
                guard let id = item.id else { return nil }
                guard visited.insert(id).inserted else { return nil }
                let resolvedDSN = item.resolvedDSN?.trimmedNonEmpty
                let name = item.resolvedName?.trimmedNonEmpty
                    ?? resolvedDSN
                    ?? "Device \(id)"
                return MemberDeviceRecord(
                    id: id,
                    dsn: resolvedDSN,
                    name: name,
                    avatarURL: item.resolvedAvatarURL
                )
            }

            saveCachedRecords(records)
            return records
        } catch {
            let cached = cachedRecords(limit: limit)
            if !cached.isEmpty {
                return cached
            }
            throw error
        }
    }

    func resolveDevice(byDSN dsn: String, limit: Int) async throws -> MemberDeviceRecord {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDSN.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        let devices = try await fetchDevices(limit: limit)
        if let matched = devices.first(where: { device in
            guard let remoteDSN = device.dsn?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return remoteDSN.caseInsensitiveCompare(normalizedDSN) == .orderedSame
        }) {
            return matched
        }

        throw NetworkError.unexpectedBody
    }

    private let client: APIClient
    private let secureTokens: SecureTokenStoring
    private let userDefaults: UserDefaults

    private var hasAuthorization: Bool {
        secureTokens.accessToken() != nil
    }

    private func saveCachedRecords(_ records: [MemberDeviceRecord]) {
        let payload = records.map {
            CachedDeviceRecord(
                id: $0.id,
                dsn: $0.dsn,
                name: $0.name,
                avatarURL: $0.avatarURL?.absoluteString
            )
        }

        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: cacheKey)
    }

    private func cachedRecords(limit: Int) -> [MemberDeviceRecord] {
        guard let data = userDefaults.data(forKey: cacheKey),
              let payload = try? JSONDecoder().decode([CachedDeviceRecord].self, from: data) else {
            return []
        }

        let records = payload.map {
            MemberDeviceRecord(
                id: $0.id,
                dsn: $0.dsn,
                name: $0.name,
                avatarURL: $0.avatarURL.flatMap(URL.init(string:))
            )
        }

        let normalizedLimit = max(1, min(limit, 500))
        return Array(records.prefix(normalizedLimit))
    }

    private struct CachedDeviceRecord: Codable {
        let id: Int
        let dsn: String?
        let name: String
        let avatarURL: String?
    }

    private var cacheKey: String { "MEMBER_DEVICES_CACHE_V1" }
}

private struct MemberDeviceDTO: Decodable {
    let id: Int?
    let dsn: String?
    let deviceDSN: String?
    let childrenDeviceDSN: String?
    let name: String?
    let username: String?
    let fullName: String?
    let avatarURL: String?

    var resolvedDSN: String? {
        dsn ?? deviceDSN ?? childrenDeviceDSN
    }

    var resolvedName: String? {
        name ?? username ?? fullName
    }

    var resolvedAvatarURL: URL? {
        guard let avatarURL = avatarURL?.trimmedNonEmpty else { return nil }
        return URL(string: avatarURL)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case dsn
        case deviceDSN = "device_dsn"
        case childrenDeviceDSN = "children_device_dsn"
        case name
        case username
        case fullName = "full_name"
        case avatarURL = "avatar_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyIntIfPresent(forKey: .id)
        dsn = container.decodeLossyStringIfPresent(forKey: .dsn)
        deviceDSN = container.decodeLossyStringIfPresent(forKey: .deviceDSN)
        childrenDeviceDSN = container.decodeLossyStringIfPresent(forKey: .childrenDeviceDSN)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        username = container.decodeLossyStringIfPresent(forKey: .username)
        fullName = container.decodeLossyStringIfPresent(forKey: .fullName)
        avatarURL = container.decodeLossyStringIfPresent(forKey: .avatarURL)
    }
}

private enum MembersDevicesResponse: Decodable {
    case array([MemberDeviceDTO])
    case envelope(Envelope)

    struct Envelope: Decodable {
        let data: [MemberDeviceDTO]?
        let results: [MemberDeviceDTO]?
        let devices: [MemberDeviceDTO]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let items = try? container.decode([MemberDeviceDTO].self) {
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

    var devices: [MemberDeviceDTO] {
        switch self {
        case let .array(items):
            return items
        case let .envelope(payload):
            return payload.data ?? payload.results ?? payload.devices ?? []
        }
    }
}

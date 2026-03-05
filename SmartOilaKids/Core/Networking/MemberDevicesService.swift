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
        userDefaults: UserDefaults = .standard,
        mapper: MemberDevicesMapper = MemberDevicesMapper()
    ) {
        self.client = client
        self.secureTokens = secureTokens
        self.userDefaults = userDefaults
        self.mapper = mapper
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

            let records = mapper.mapRecords(from: response)
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
    private let mapper: MemberDevicesMapper

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

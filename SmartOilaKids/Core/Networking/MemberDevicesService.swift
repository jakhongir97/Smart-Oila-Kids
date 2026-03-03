import Foundation

struct MemberDeviceRecord: Identifiable, Equatable {
    let id: Int
    let dsn: String?
    let name: String
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
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func fetchDevices(limit: Int) async throws -> [MemberDeviceRecord] {
        guard hasAuthorization else {
            return []
        }

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
        return sortedDevices.compactMap { item in
            guard let id = item.id else { return nil }
            guard visited.insert(id).inserted else { return nil }
            let resolvedDSN = item.resolvedDSN?.trimmedNonEmpty
            let name = item.resolvedName?.trimmedNonEmpty
                ?? resolvedDSN
                ?? "Device \(id)"
            return MemberDeviceRecord(id: id, dsn: resolvedDSN, name: name)
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
    private let userDefaults: UserDefaults = .standard

    private var hasAuthorization: Bool {
        userDefaults.string(forKey: "API_ACCESS_TOKEN")?.trimmedNonEmpty != nil
    }
}

private struct MemberDeviceDTO: Decodable {
    let id: Int?
    let dsn: String?
    let deviceDSN: String?
    let childrenDeviceDSN: String?
    let name: String?
    let username: String?
    let fullName: String?

    var resolvedDSN: String? {
        dsn ?? deviceDSN ?? childrenDeviceDSN
    }

    var resolvedName: String? {
        name ?? username ?? fullName
    }

    enum CodingKeys: String, CodingKey {
        case id
        case dsn
        case deviceDSN = "device_dsn"
        case childrenDeviceDSN = "children_device_dsn"
        case name
        case username
        case fullName = "full_name"
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

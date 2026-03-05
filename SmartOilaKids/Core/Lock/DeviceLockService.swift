import Foundation

protocol DeviceLockServicing {
    func fetchFullLockStatus(dsn: String) async throws -> DeviceFullLockStatus
    func fetchGlobalLockStatus(dsn: String) async throws -> Bool
}

final class DeviceLockService: DeviceLockServicing {
    init(
        client: APIClient = APIClient(),
        globalLockParser: DeviceGlobalLockPayloadParser = DeviceGlobalLockPayloadParser()
    ) {
        self.client = client
        self.globalLockParser = globalLockParser
    }

    func fetchFullLockStatus(dsn: String) async throws -> DeviceFullLockStatus {
        let normalized = try normalizedDSN(dsn)

        return try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/dsn/\(normalized)/full_lock_status",
            method: .get,
            headers: ["Accept": "application/json"],
            as: DeviceFullLockStatus.self
        )
    }

    func fetchGlobalLockStatus(dsn: String) async throws -> Bool {
        let normalized = try normalizedDSN(dsn)

        let data = try await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/dsn/\(normalized)/global_application_lock",
            method: .get,
            headers: ["Accept": "application/json"]
        )

        guard let parsed = globalLockParser.parse(from: data) else {
            throw NetworkError.decodingFailed
        }

        return parsed
    }

    private let client: APIClient
    private let globalLockParser: DeviceGlobalLockPayloadParser

    private func normalizedDSN(_ dsn: String) throws -> String {
        let normalized = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw NetworkError.unexpectedBody
        }
        return normalized
    }
}

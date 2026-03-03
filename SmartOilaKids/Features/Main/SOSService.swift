import Foundation

protocol SOSServicing {
    func sendSOS(deviceDSN: String) async throws
}

final class SOSService: SOSServicing {
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func sendSOS(deviceDSN: String) async throws {
        _ = try await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/notify/member",
            method: .post,
            queryItems: [URLQueryItem(name: "device_dsn", value: deviceDSN)]
        )
    }

    private let client: APIClient
}

import Foundation

enum AuthDeviceNameSync {
    static func syncIfPossible(
        scannedDeviceName: String?,
        registration: AuthRegistrationResult,
        client: APIClient,
        onDebug: (String) -> Void
    ) async {
        guard let scannedDeviceName else { return }

        let authorization = registration.authorizationHeader?.trimmedNonEmpty
        var headers: [String: String] = ["Accept": "application/json"]
        if let authorization {
            headers["Authorization"] = authorization
        }

        do {
            let devices: [RenamableDevice] = try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "members/me/devices",
                method: .get,
                queryItems: [
                    URLQueryItem(name: "offset", value: "0"),
                    URLQueryItem(name: "limit", value: "100")
                ],
                headers: headers,
                as: [RenamableDevice].self
            )

            guard let target = devices.first(where: { device in
                guard let dsn = device.resolvedDSN?.trimmedNonEmpty else { return false }
                return dsn.caseInsensitiveCompare(registration.dsn) == .orderedSame
            }) else {
                return
            }

            let body = try JSONEncoder().encode(DeviceRenamePayload(name: scannedDeviceName))
            _ = try await client.requestDataWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "devices/\(target.id)",
                method: .put,
                headers: headers,
                body: body,
                contentType: "application/json"
            )

            onDebug("Synced child name from QR payload for DSN \(registration.dsn).")
        } catch {
            onDebug("Skipping QR name sync: \(error.localizedDescription)")
        }
    }
}

private struct RenamableDevice: Decodable {
    let id: Int
    let dsn: String?
    let deviceDSN: String?
    let childrenDeviceDSN: String?

    var resolvedDSN: String? {
        dsn ?? deviceDSN ?? childrenDeviceDSN
    }

    enum CodingKeys: String, CodingKey {
        case id
        case dsn
        case deviceDSN = "device_dsn"
        case childrenDeviceDSN = "children_device_dsn"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyIntIfPresent(forKey: .id) ?? 0
        dsn = container.decodeLossyStringIfPresent(forKey: .dsn)
        deviceDSN = container.decodeLossyStringIfPresent(forKey: .deviceDSN)
        childrenDeviceDSN = container.decodeLossyStringIfPresent(forKey: .childrenDeviceDSN)
    }
}

private struct DeviceRenamePayload: Encodable {
    let name: String
}

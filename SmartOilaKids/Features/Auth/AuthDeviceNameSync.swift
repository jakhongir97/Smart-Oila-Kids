import Foundation

enum AuthDeviceNameSync {
    static func syncIfPossible(
        scannedDeviceName: String?,
        registration: AuthRegistrationResult,
        client: APIClient,
        onDebug: (String) -> Void
    ) async {
        seedCacheIfPossible(
            scannedDeviceName: scannedDeviceName,
            registration: registration,
            client: client,
            onDebug: onDebug
        )

        let authorization = registration.authorizationHeader?.trimmedNonEmpty
        var headers: [String: String] = ["Accept": "application/json"]
        if let authorization {
            headers["Authorization"] = authorization
        }

        do {
            let response: MembersDevicesResponse = try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "members/me/devices",
                method: .get,
                queryItems: [
                    URLQueryItem(name: "offset", value: "0"),
                    URLQueryItem(name: "limit", value: "100")
                ],
                headers: headers,
                as: MembersDevicesResponse.self
            )

            let mapper = MemberDevicesMapper()
            let devices = mapper.mapRecords(from: response)

            guard let target = devices.first(where: { device in
                guard let dsn = device.dsn?.trimmedNonEmpty else { return false }
                return dsn.caseInsensitiveCompare(registration.dsn) == .orderedSame
            }) else {
                return
            }

            MemberDevicesService(client: client).primeCache(with: target)

            guard let scannedDeviceName else {
                onDebug("Seeded current child device cache for DSN \(registration.dsn).")
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

    static func seedCacheIfPossible(
        scannedDeviceName: String?,
        registration: AuthRegistrationResult,
        client: APIClient,
        onDebug: (String) -> Void
    ) {
        guard let deviceID = registration.deviceID, deviceID > 0 else { return }

        let seededName = scannedDeviceName?.trimmedNonEmpty ?? ProductFallbackText.localDeviceName()
        MemberDevicesService(client: client).primeCache(
            with: MemberDeviceRecord(
                id: deviceID,
                dsn: registration.dsn,
                name: seededName,
                avatarURL: nil
            )
        )
        onDebug("Seeded current child device cache from registration payload for DSN \(registration.dsn).")
    }
}

private struct DeviceRenamePayload: Encodable {
    let name: String
}

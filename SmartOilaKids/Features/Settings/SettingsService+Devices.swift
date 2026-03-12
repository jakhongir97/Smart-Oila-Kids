import Foundation

extension SettingsService {
    func fetchConnectedDevices(limit: Int) async throws -> [ConnectedDevice] {
        let records = try await memberDevicesService.fetchDevices(limit: limit)
        return records.map(Self.makeConnectedDevice(from:))
    }

    func resolveConnectedDevice(dsn: String) async throws -> ConnectedDevice {
        let record = try await memberDevicesService.resolveDevice(byDSN: dsn, limit: 100)
        return Self.makeConnectedDevice(from: record)
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
        return ConnectedDevice(
            id: deviceID,
            dsn: response.dsn?.trimmedNonEmpty,
            name: resolvedName,
            avatarURL: response.resolvedAvatarURL
        )
    }

    func uploadConnectedDeviceAvatar(deviceID: Int, imageData: Data) async throws -> ConnectedDevice {
        let boundary = UUID().uuidString
        let body = createAvatarMultipartBody(boundary: boundary, imageData: imageData)

        let response: MemberDevice = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/\(deviceID)/upload-avatar/",
            method: .post,
            headers: ["Accept": "application/json"],
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            as: MemberDevice.self
        )

        let resolvedName = response.resolvedName?.trimmedNonEmpty ?? "Device \(deviceID)"
        return ConnectedDevice(
            id: deviceID,
            dsn: response.dsn?.trimmedNonEmpty,
            name: resolvedName,
            avatarURL: response.resolvedAvatarURL
        )
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
}

private extension SettingsService {
    static func makeConnectedDevice(from record: MemberDeviceRecord) -> ConnectedDevice {
        ConnectedDevice(
            id: record.id,
            dsn: record.dsn,
            name: record.name,
            avatarURL: record.avatarURL
        )
    }
}

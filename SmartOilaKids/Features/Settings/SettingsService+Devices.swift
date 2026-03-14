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
        let path = "devices/\(deviceID)/upload-avatar/"

#if DEBUG
        SettingsAvatarUploadServiceDebugLogger.log(
            "request deviceID=\(deviceID) path=\(path) imageBytes=\(imageData.count) multipartBytes=\(body.count) boundary=\(boundary)"
        )
#endif

        let response: MemberDevice = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: path,
            method: .post,
            headers: ["Accept": "application/json"],
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            as: MemberDevice.self
        )

        let resolvedName = response.resolvedName?.trimmedNonEmpty ?? "Device \(deviceID)"
#if DEBUG
        SettingsAvatarUploadServiceDebugLogger.log(
            "response deviceID=\(deviceID) name=\(resolvedName) avatarURL=\(response.resolvedAvatarURL?.absoluteString ?? "nil")"
        )
#endif
        return ConnectedDevice(
            id: deviceID,
            dsn: response.dsn?.trimmedNonEmpty,
            name: resolvedName,
            avatarURL: response.resolvedAvatarURL
        )
    }

    func uploadConnectedDeviceAvatar(dsn: String, imageData: Data) async throws -> URL? {
        let boundary = UUID().uuidString
        let body = createAvatarMultipartBody(boundary: boundary, imageData: imageData)
        let path = "devices/\(dsn)/upload-avatar/"

#if DEBUG
        SettingsAvatarUploadServiceDebugLogger.log(
            "fallback request dsn=\(dsn) path=\(path) imageBytes=\(imageData.count) multipartBytes=\(body.count) boundary=\(boundary)"
        )
#endif

        let data = try await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: path,
            method: .post,
            headers: ["Accept": "application/json"],
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )

        let avatarURL = parseAvatarUploadURL(from: data)
#if DEBUG
        SettingsAvatarUploadServiceDebugLogger.log(
            "fallback response dsn=\(dsn) avatarURL=\(avatarURL?.absoluteString ?? "nil") payloadBytes=\(data.count)"
        )
#endif
        return avatarURL
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

#if DEBUG
private enum SettingsAvatarUploadServiceDebugLogger {
    static func log(_ message: String) {
        print("[AvatarUploadDebug][Service] \(message)")
    }
}
#endif

private extension SettingsService {
    func parseAvatarUploadURL(from data: Data) -> URL? {
        if let response = try? JSONDecoder().decode(MemberDevice.self, from: data),
           let avatarURL = response.resolvedAvatarURL {
            return avatarURL
        }

        if let response = try? JSONDecoder().decode(AvatarUploadEnvelope.self, from: data),
           let avatarURL = response.resolvedAvatarURL {
            return avatarURL
        }

        if let payload = try? JSONSerialization.jsonObject(with: data) {
            return parseAvatarUploadURL(fromJSONObject: payload)
        }

        if let text = String(data: data, encoding: .utf8)?.trimmedNonEmpty {
            return RemoteAssetURLResolver.resolveURL(text)
        }

        return nil
    }

    func parseAvatarUploadURL(fromJSONObject value: Any) -> URL? {
        if let string = value as? String {
            return RemoteAssetURLResolver.resolveURL(string)
        }

        if let dictionary = value as? [String: Any] {
            for key in ["avatar_url", "avatar", "url"] {
                if let string = dictionary[key] as? String,
                   let avatarURL = RemoteAssetURLResolver.resolveURL(string) {
                    return avatarURL
                }
            }

            for key in ["data", "result", "device", "payload"] {
                if let nested = dictionary[key],
                   let avatarURL = parseAvatarUploadURL(fromJSONObject: nested) {
                    return avatarURL
                }
            }
        }

        if let array = value as? [Any] {
            for item in array {
                if let avatarURL = parseAvatarUploadURL(fromJSONObject: item) {
                    return avatarURL
                }
            }
        }

        return nil
    }

    static func makeConnectedDevice(from record: MemberDeviceRecord) -> ConnectedDevice {
        ConnectedDevice(
            id: record.id,
            dsn: record.dsn,
            name: record.name,
            avatarURL: record.avatarURL
        )
    }
}

private struct AvatarUploadEnvelope: Decodable {
    let avatarURL: String?
    let url: String?
    let data: MemberDevice?
    let result: MemberDevice?
    let device: MemberDevice?

    var resolvedAvatarURL: URL? {
        data?.resolvedAvatarURL ??
        result?.resolvedAvatarURL ??
        device?.resolvedAvatarURL ??
        RemoteAssetURLResolver.resolveURL(avatarURL) ??
        RemoteAssetURLResolver.resolveURL(url)
    }

    enum CodingKeys: String, CodingKey {
        case avatarURL = "avatar_url"
        case url
        case data
        case result
        case device
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        avatarURL = container.decodeLossyStringIfPresent(forKey: .avatarURL)
        url = container.decodeLossyStringIfPresent(forKey: .url)
        data = try? container.decode(MemberDevice.self, forKey: .data)
        result = try? container.decode(MemberDevice.self, forKey: .result)
        device = try? container.decode(MemberDevice.self, forKey: .device)
    }
}

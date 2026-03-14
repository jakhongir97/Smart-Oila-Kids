import Foundation

extension SettingsService {
    func ensureAuthorized() throws {
        guard secureTokens.accessToken() != nil || secureTokens.refreshToken() != nil else {
            throw NetworkError.server(statusCode: 401, body: "Not authenticated")
        }
    }

    func createAvatarMultipartBody(boundary: String, imageData: Data) -> Data {
        var data = Data()
        data.append("--\(boundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\n")
        data.append("Content-Type: image/jpeg\r\n\r\n")
        data.append(imageData)
        data.append("\r\n")
        data.append("--\(boundary)--\r\n")
        return data
    }
}

private extension Data {
    mutating func append(_ string: String) {
        guard let value = string.data(using: .utf8) else { return }
        append(value)
    }
}

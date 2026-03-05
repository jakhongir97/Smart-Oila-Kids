import Foundation

extension AuthService {
    func registerDeviceByQRClaim(token: String, deviceName: String, appVersion: String) async throws -> Data {
        let payload = QRClaimRequest(token: token, deviceName: deviceName, appVersion: appVersion)
        let bodyData = try JSONEncoder().encode(payload)

        return try await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: AppConfig.qrClaimPath,
            method: .post,
            headers: ["Accept": "application/json"],
            body: bodyData,
            contentType: "application/json"
        )
    }

    func registerDeviceByLegacyEndpoint(
        token: String?,
        parentPhone: String?,
        deviceName: String,
        appVersion: String
    ) async throws -> AuthRegistrationResult {
        let phone = parentPhone ?? token.flatMap(AuthInputNormalization.extractPhoneFromJWT)
        guard let phone else {
            throw NetworkError.server(
                statusCode: 400,
                body: "Legacy fallback failed: parent phone is missing in QR payload"
            )
        }

        var request = URLRequest(url: AppConfig.legacyDeviceClaimURL)
        debugLog("Using legacy claim endpoint: \(AppConfig.legacyDeviceClaimURL.absoluteString)")
        request.httpMethod = HTTPMethod.post.rawValue
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.httpBody = formURLEncodedBody([
            ("email", phone),
            ("DeviceName", deviceName),
            ("content", "add-dev"),
            ("client-ver", appVersion),
            ("app-ver", appVersion),
            ("device", ""),
            ("client-date-time", legacyClientDateTimeString())
        ])

        let data = try await client.requestData(request)
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw NetworkError.unexpectedBody
        }

        if text.uppercased().hasPrefix("ERR:") {
            throw NetworkError.server(statusCode: 400, body: text)
        }

        return try AuthRegistrationParser.parseRegistrationResponse(
            data: data,
            text: text,
            headers: [:],
            onDebug: debugLog
        )
    }

    func formURLEncodedBody(_ fields: [(String, String)]) -> Data {
        let encoded = fields
            .map { "\(urlEncode($0.0))=\(urlEncode($0.1))" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    func urlEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._* ")
        return value
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: " ", with: "+") ?? value
    }

    func legacyClientDateTimeString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return formatter.string(from: Date())
    }
}

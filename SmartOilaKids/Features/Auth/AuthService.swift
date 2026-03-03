import Foundation

protocol AuthServicing {
    func registerDevice(
        qrToken: String?,
        qrRefreshToken: String?,
        parentPhone: String?,
        deviceName: String,
        appVersion: String
    ) async throws -> AuthRegistrationResult
    func verifyChildBinding(dsn: String) async throws -> Bool
}

final class AuthService: AuthServicing {
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func registerDevice(
        qrToken: String?,
        qrRefreshToken: String?,
        parentPhone: String?,
        deviceName: String,
        appVersion: String
    ) async throws -> AuthRegistrationResult {
        let normalizedToken = qrToken?.trimmedNonEmpty
        let normalizedRefreshToken = qrRefreshToken?.trimmedNonEmpty
        let normalizedPhone = normalizePhone(parentPhone)

        guard normalizedToken != nil || normalizedPhone != nil else {
            throw NetworkError.unexpectedBody
        }

        if let normalizedToken {
            do {
                let data = try await registerDeviceByQRClaim(
                    token: normalizedToken,
                    deviceName: deviceName,
                    appVersion: appVersion
                )

                guard let text = String(data: data, encoding: .utf8) else {
                    throw NetworkError.unexpectedBody
                }

                return try parseRegistrationResponse(
                    data: data,
                    text: text,
                    headers: [:]
                )
            } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
                debugLog("`\(AppConfig.qrClaimPath)` returned 404. Falling back to legacy claim endpoint.")
                let legacyResult = try await registerDeviceByLegacyEndpoint(
                    token: normalizedToken,
                    parentPhone: normalizedPhone,
                    deviceName: deviceName,
                    appVersion: appVersion
                )
                return mergeAuthorization(
                    from: legacyResult,
                    fallbackToken: normalizedToken,
                    fallbackRefreshToken: normalizedRefreshToken
                )
            }
        }

        return try await registerDeviceByLegacyEndpoint(
            token: nil,
            parentPhone: normalizedPhone,
            deviceName: deviceName,
            appVersion: appVersion
        )
    }

    func verifyChildBinding(dsn: String) async throws -> Bool {
        let sanitized = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return false }

        do {
            _ = try await client.requestDataWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "devices/dsn/\(sanitized)/full_lock_status",
                method: .get,
                headers: ["Accept": "application/json"]
            )
            return true
        } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
            return false
        }
    }

    private let client: APIClient
}

private extension AuthService {
    func mergeAuthorization(
        from result: AuthRegistrationResult,
        fallbackToken: String?,
        fallbackRefreshToken: String?
    ) -> AuthRegistrationResult {
        let resolvedRefreshToken = result.refreshToken?.trimmedNonEmpty ?? fallbackRefreshToken?.trimmedNonEmpty

        if let header = result.authorizationHeader?.trimmedNonEmpty {
            return AuthRegistrationResult(
                dsn: result.dsn,
                authorizationHeader: header,
                refreshToken: resolvedRefreshToken
            )
        }

        if let fallbackToken = fallbackToken?.trimmedNonEmpty {
            debugLog("Legacy registration succeeded without auth header. Reusing scanned QR token for API authorization.")
            return AuthRegistrationResult(
                dsn: result.dsn,
                authorizationHeader: fallbackToken,
                refreshToken: resolvedRefreshToken
            )
        }

        return AuthRegistrationResult(
            dsn: result.dsn,
            authorizationHeader: result.authorizationHeader,
            refreshToken: resolvedRefreshToken
        )
    }

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
        let phone = parentPhone ?? token.flatMap(extractPhoneFromJWT)
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

        return try parseRegistrationResponse(data: data, text: text, headers: [:])
    }

    func extractPhoneFromJWT(_ token: String) -> String? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let jwt = normalized.split(separator: " ").last.map(String.init) ?? normalized
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let phone = json["phone"] as? String {
            let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let phone = json["phone"] as? NSNumber {
            let value = phone.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        return nil
    }

    func normalizePhone(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let phoneCharset = CharacterSet(charactersIn: "+0123456789() -")
        let hasInvalidCharacter = trimmed.unicodeScalars.contains { !phoneCharset.contains($0) }
        guard !hasInvalidCharacter else { return nil }

        let allowedScalars = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) || $0 == "+" }
        guard !allowedScalars.isEmpty else { return nil }

        var normalized = String(String.UnicodeScalarView(allowedScalars))
        let digitsCount = normalized.filter(\.isNumber).count
        guard digitsCount >= 9 else { return nil }

        if !normalized.hasPrefix("+") {
            normalized = "+" + normalized.filter(\.isNumber)
        }

        return normalized
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

    func parseRegistrationResponse(
        data: Data,
        text: String,
        headers: [AnyHashable: Any]
    ) throws -> AuthRegistrationResult {
        let headerAuthorization = extractAuthorizationHeader(from: headers)

        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let status = payload["status"] as? Bool, status == false {
                let message = extractString(in: payload, keys: ["message"]) ?? text
                throw NetworkError.server(statusCode: 400, body: message)
            }

            if let dsn = extractString(in: payload, keys: ["dsn", "device_dsn", "deviceDsn", "children_device_dsn"]) {
                let bodyAuthorization = buildAuthorizationHeader(
                    token: extractString(in: payload, keys: ["authorization", "auth_token", "access_token", "accessToken", "token"]),
                    tokenType: extractString(in: payload, keys: ["token_type", "tokenType", "type"])
                )
                let bodyRefreshToken = extractString(in: payload, keys: ["refresh_token", "refreshToken"])

                return AuthRegistrationResult(
                    dsn: dsn,
                    authorizationHeader: headerAuthorization ?? bodyAuthorization,
                    refreshToken: bodyRefreshToken
                )
            }
        }

        if let dsn = parseDSN(from: text) {
            debugLog("Registration success. Parsed DSN: \(dsn)")
            return AuthRegistrationResult(
                dsn: dsn,
                authorizationHeader: headerAuthorization,
                refreshToken: nil
            )
        }

        throw NetworkError.unexpectedBody
    }

    func parseDSN(from body: String) -> String? {
        if let value = body.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }

        if let range = body.range(of: #"([A-Za-z0-9_-]{6,})$"#, options: .regularExpression) {
            let token = String(body[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return token
            }
        }

        let tokens = body.split(whereSeparator: { $0.isWhitespace || $0 == "\n" })
        return tokens.last.map(String.init)
    }

    func extractAuthorizationHeader(from headers: [AnyHashable: Any]) -> String? {
        let normalized = Dictionary(uniqueKeysWithValues: headers.compactMap { key, value in
            let normalizedKey = "\(key)".lowercased()

            if let stringValue = value as? String {
                return (normalizedKey, stringValue)
            }

            if let numberValue = value as? NSNumber {
                return (normalizedKey, numberValue.stringValue)
            }

            return nil
        })

        if let authorization = normalized["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !authorization.isEmpty {
            return authorization
        }

        return buildAuthorizationHeader(
            token: normalized["x-access-token"] ?? normalized["access-token"] ?? normalized["access_token"] ?? normalized["token"],
            tokenType: normalized["token_type"] ?? normalized["token-type"]
        )
    }

    func buildAuthorizationHeader(token: String?, tokenType: String?) -> String? {
        guard var token else { return nil }
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        if token.contains(" ") {
            return token
        }

        if var tokenType {
            tokenType = tokenType.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tokenType.isEmpty {
                return "\(tokenType) \(token)"
            }
        }

        return token
    }

    func extractString(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = readValue(from: payload, key: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        for containerKey in ["data", "result"] {
            guard let nested = payload[containerKey] as? [String: Any] else { continue }
            for key in keys {
                if let value = readValue(from: nested, key: key) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        }

        return nil
    }

    func readValue(from payload: [String: Any], key: String) -> String? {
        if let direct = payload[key] {
            return valueToString(direct)
        }

        if let matchedKey = payload.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
           let value = payload[matchedKey] {
            return valueToString(value)
        }

        return nil
    }

    func valueToString(_ value: Any) -> String? {
        if let value = value as? String {
            return value
        }

        if let value = value as? NSNumber {
            return value.stringValue
        }

        return nil
    }

    func debugLog(_ message: String) {
#if DEBUG
        print("[AuthService] \(message)")
#endif
    }
}

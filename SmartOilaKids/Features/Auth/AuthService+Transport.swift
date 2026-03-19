import Foundation

extension AuthService {
    func requestParentPhoneCode(phone: String) async throws {
        let normalizedPhone = AuthInputNormalization.normalizeAndroidParentPhone(phone) ?? phone

        do {
            let response = try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "v2/login",
                method: .post,
                headers: ["Accept": "application/json"],
                body: try JSONEncoder().encode(AuthLoginRequest(phone: normalizedPhone)),
                contentType: "application/json",
                as: AuthLoginResponse.self
            )

            if response.userExists == false {
                debugLog("`/v2/login` reported missing user. Falling back to `/auth_v2`.")
                try await registerParentPhoneForCode(phone: normalizedPhone)
            }
        } catch let NetworkError.server(statusCode, body)
            where statusCode == 404 || statusCode == 405
        {
            debugLog("`/v2/login` failed with \(statusCode). Falling back to `/auth_v2`.")
            _ = body
            try await registerParentPhoneForCode(phone: normalizedPhone)
        }
    }

    func confirmParentPhoneCode(phone: String, code: Int) async throws -> AuthSessionTokens {
        let response = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "auth_v2/confirm",
            method: .post,
            headers: ["Accept": "application/json"],
            body: try JSONEncoder().encode(AuthConfirmRequest(phone: phone, code: code)),
            contentType: "application/json",
            as: APITokenRefreshResponse.self
        )

        guard let accessToken = response.accessToken?.trimmedNonEmpty else {
            throw NetworkError.unexpectedBody
        }

        let authorizationHeader = normalizedAuthorizationHeader(
            accessToken: accessToken,
            tokenType: response.tokenType
        )

        return AuthSessionTokens(
            authorizationHeader: authorizationHeader,
            refreshToken: response.refreshToken?.trimmedNonEmpty
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

    private func registerParentPhoneForCode(phone: String) async throws {
        _ = try await client.requestDecodableWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "auth_v2",
            method: .post,
            headers: ["Accept": "application/json"],
            body: try JSONEncoder().encode(AuthRegisterRequest(phone: phone)),
            contentType: "application/json",
            as: AuthResponseMessage.self
        )
    }

    private func normalizedAuthorizationHeader(accessToken: String, tokenType: String?) -> String {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.contains(" ") {
            return token
        }

        if let tokenType = tokenType?.trimmedNonEmpty {
            return "\(tokenType) \(token)"
        }

        return token
    }
}

private struct AuthLoginRequest: Encodable {
    let phone: String
}

private struct AuthRegisterRequest: Encodable {
    let phone: String
    let name: String = "unset"
    let role: String = "member"
    let active: Int = 0
    let region: String = "unset"
}

private struct AuthConfirmRequest: Encodable {
    let phone: String
    let code: Int
}

private struct AuthLoginResponse: Decodable {
    let message: String?
    let userExists: Bool

    enum CodingKeys: String, CodingKey {
        case message
        case userExists = "user_exists"
    }
}

private struct AuthResponseMessage: Decodable {
    let message: String
}

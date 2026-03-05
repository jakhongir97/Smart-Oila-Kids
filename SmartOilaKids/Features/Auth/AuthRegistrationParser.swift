import Foundation

enum AuthRegistrationParser {
    static func parseRegistrationResponse(
        data: Data,
        text: String,
        headers: [AnyHashable: Any],
        onDebug: (String) -> Void
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
            onDebug("Registration success. Parsed DSN: \(dsn)")
            return AuthRegistrationResult(
                dsn: dsn,
                authorizationHeader: headerAuthorization,
                refreshToken: nil
            )
        }

        throw NetworkError.unexpectedBody
    }

    private static func parseDSN(from body: String) -> String? {
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

    private static func extractAuthorizationHeader(from headers: [AnyHashable: Any]) -> String? {
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

    private static func buildAuthorizationHeader(token: String?, tokenType: String?) -> String? {
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

    private static func extractString(in payload: [String: Any], keys: [String]) -> String? {
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

    private static func readValue(from payload: [String: Any], key: String) -> String? {
        if let direct = payload[key] {
            return valueToString(direct)
        }

        if let matchedKey = payload.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }),
           let value = payload[matchedKey] {
            return valueToString(value)
        }

        return nil
    }

    private static func valueToString(_ value: Any) -> String? {
        if let value = value as? String {
            return value
        }

        if let value = value as? NSNumber {
            return value.stringValue
        }

        return nil
    }
}

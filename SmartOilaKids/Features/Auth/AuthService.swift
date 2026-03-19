import Foundation

protocol AuthServicing {
    func registerDevice(
        qrToken: String?,
        qrRefreshToken: String?,
        parentPhone: String?,
        qrDSN: String?,
        scannedDeviceName: String?,
        deviceName: String,
        appVersion: String
    ) async throws -> AuthRegistrationResult
    func requestParentPhoneCode(phone: String) async throws
    func confirmParentPhoneCode(phone: String, code: Int) async throws -> AuthSessionTokens
    func verifyChildBinding(dsn: String, authorizationHeader: String?) async throws -> Bool
}

final class AuthService: AuthServicing {
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func verifyChildBinding(dsn: String, authorizationHeader: String? = nil) async throws -> Bool {
        try await AuthBindingVerifier.verifyChildBinding(
            dsn: dsn,
            onDebug: debugLog,
            performRequest: { sanitized in
                var lastError: Error?

                for baseURL in AppConfig.apiBaseCandidates {
                    do {
                        let request = try client.makeRequest(
                            baseURL: baseURL,
                            path: "devices/dsn/\(sanitized)/full_lock_status",
                            method: .get,
                            headers: requestHeaders(
                                authorizationHeader: authorizationHeader,
                                accept: "application/json"
                            )
                        )
                        _ = try await client.requestData(request)
                        return
                    } catch {
                        lastError = error
                    }
                }

                throw lastError ?? NetworkError.invalidURL
            }
        )
    }

    let client: APIClient
}

extension AuthService {
    func debugLog(_ message: String) {
#if DEBUG
        print("[AuthService] \(message)")
#endif
    }

    func requestHeaders(authorizationHeader: String?, accept: String) -> [String: String] {
        var headers = ["Accept": accept]
        if let authorizationHeader = authorizationHeader?.trimmedNonEmpty {
            headers["Authorization"] = authorizationHeader
        }
        return headers
    }
}

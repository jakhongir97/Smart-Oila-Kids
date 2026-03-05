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
    func verifyChildBinding(dsn: String) async throws -> Bool
}

final class AuthService: AuthServicing {
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func verifyChildBinding(dsn: String) async throws -> Bool {
        try await AuthBindingVerifier.verifyChildBinding(
            dsn: dsn,
            client: client,
            onDebug: debugLog
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
}

import Foundation
import SwiftUI

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var isLoading: Bool = false
    @Published var errorText: String?

    init(authService: AuthServicing) {
        self.authService = authService
    }

    func submit(scannedPayload: AuthScanPayload) async -> AuthRegistrationResult? {
        guard !isLoading else { return nil }
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            guard scannedPayload.hasAuthData else {
                errorText = L10n.tr("auth.qr_missing_auth_data")
                return nil
            }
            let result = try await bindByScanPayload(scannedPayload)

            let isVerified = try await authService.verifyChildBinding(dsn: result.dsn)
            guard isVerified else {
                errorText = L10n.tr("auth.verify_failed")
                return nil
            }

            return result
        } catch {
            errorText = error.localizedDescription
        }

        return nil
    }

    private func bindByScanPayload(_ payload: AuthScanPayload) async throws -> AuthRegistrationResult {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let preferredDeviceName = payload.deviceName?.trimmedNonEmpty ?? UIDevice.current.name
        return try await authService.registerDevice(
            qrToken: payload.token,
            qrRefreshToken: payload.refreshToken,
            parentPhone: payload.parentPhone,
            deviceName: preferredDeviceName,
            appVersion: appVersion
        )
    }

    private let authService: AuthServicing
}

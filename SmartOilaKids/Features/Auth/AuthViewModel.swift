import Foundation
import SwiftUI
import UIKit

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var isLoading: Bool = false
    @Published var errorText: String?

    init(authService: AuthServicing) {
        self.authService = authService
    }

    func submit(parentPhone: String) async -> AuthPhoneSubmitResult? {
        guard !isLoading else { return nil }
        guard let normalizedPhone = AuthInputNormalization.normalizeAndroidParentPhone(parentPhone) else {
            errorText = L10n.tr("auth.phone_invalid")
            return nil
        }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let result = try await bindByParentPhone(normalizedPhone)

            if result.authorizationHeader?.trimmedNonEmpty != nil {
                let isVerified = try await authService.verifyChildBinding(
                    dsn: result.dsn,
                    authorizationHeader: result.authorizationHeader
                )
                guard isVerified else {
                    errorText = L10n.tr("auth.verify_failed")
                    return nil
                }

                return .completed(result)
            }

            try await authService.requestParentPhoneCode(phone: normalizedPhone)
            return .confirmationRequired(
                AuthPhoneConfirmationContext(
                    dsn: result.dsn,
                    parentPhone: normalizedPhone
                )
            )
        } catch {
            errorText = NetworkError.userMessage(for: error)
        }

        return nil
    }

    func confirm(
        confirmation: AuthPhoneConfirmationContext,
        code: String
    ) async -> AuthRegistrationResult? {
        guard !isLoading else { return nil }
        guard let normalizedCode = AuthInputNormalization.normalizeVerificationCode(code) else {
            errorText = L10n.tr("auth.code_invalid")
            return nil
        }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let tokens = try await authService.confirmParentPhoneCode(
                phone: confirmation.parentPhone,
                code: normalizedCode
            )

            let result = AuthRegistrationResult(
                dsn: confirmation.dsn,
                authorizationHeader: tokens.authorizationHeader,
                refreshToken: tokens.refreshToken
            )

            let isVerified = try await authService.verifyChildBinding(
                dsn: result.dsn,
                authorizationHeader: result.authorizationHeader
            )
            guard isVerified else {
                errorText = L10n.tr("auth.verify_failed")
                return nil
            }

            return result
        } catch {
            errorText = NetworkError.userMessage(for: error)
        }

        return nil
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

            let isVerified = try await authService.verifyChildBinding(
                dsn: result.dsn,
                authorizationHeader: result.authorizationHeader
            )
            guard isVerified else {
                errorText = L10n.tr("auth.verify_failed")
                return nil
            }

            return result
        } catch {
            errorText = NetworkError.userMessage(for: error)
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
            qrDSN: payload.dsn,
            scannedDeviceName: payload.deviceName,
            deviceName: preferredDeviceName,
            appVersion: appVersion
        )
    }

    private func bindByParentPhone(_ parentPhone: String) async throws -> AuthRegistrationResult {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let deviceName = UIDevice.current.name
        return try await authService.registerDevice(
            qrToken: nil,
            qrRefreshToken: nil,
            parentPhone: parentPhone,
            qrDSN: nil,
            scannedDeviceName: nil,
            deviceName: deviceName,
            appVersion: appVersion
        )
    }

    private let authService: AuthServicing
}

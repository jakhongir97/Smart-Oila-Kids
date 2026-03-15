import Foundation

extension AuthService {
    func registerDevice(
        qrToken: String?,
        qrRefreshToken: String?,
        parentPhone: String?,
        qrDSN: String?,
        scannedDeviceName: String?,
        deviceName: String,
        appVersion: String
    ) async throws -> AuthRegistrationResult {
        let normalizedToken = qrToken?.trimmedNonEmpty
        let normalizedRefreshToken = qrRefreshToken?.trimmedNonEmpty
        let normalizedPhone = AuthInputNormalization.normalizePhone(parentPhone)
        let normalizedDSN = AuthInputNormalization.normalizeDSN(qrDSN)
        let normalizedScannedDeviceName = AuthInputNormalization.normalizeDeviceName(scannedDeviceName)
        let effectiveDeviceName = normalizedScannedDeviceName
            ?? AuthInputNormalization.normalizeDeviceName(deviceName)
            ?? ProductFallbackText.localDeviceName()

        if let normalizedDSN {
            debugLog("Using pre-created DSN from QR payload: \(normalizedDSN)")
            let result = AuthRegistrationResult(
                dsn: normalizedDSN,
                authorizationHeader: normalizedToken,
                refreshToken: normalizedRefreshToken
            )
            await syncDeviceNameIfNeeded(
                scannedDeviceName: normalizedScannedDeviceName,
                registration: result
            )
            return result
        }

        guard normalizedToken != nil || normalizedPhone != nil || normalizedDSN != nil else {
            throw NetworkError.unexpectedBody
        }

        if let normalizedToken {
            do {
                let data = try await registerDeviceByQRClaim(
                    token: normalizedToken,
                    deviceName: effectiveDeviceName,
                    appVersion: appVersion
                )
                guard let text = String(data: data, encoding: .utf8) else {
                    throw NetworkError.unexpectedBody
                }

                return try AuthRegistrationParser.parseRegistrationResponse(
                    data: data,
                    text: text,
                    headers: [:],
                    onDebug: debugLog
                )
            } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
                debugLog("`\(AppConfig.qrClaimPath)` returned 404. Falling back to legacy claim endpoint.")
                let legacyResult = try await registerDeviceByLegacyEndpoint(
                    token: normalizedToken,
                    parentPhone: normalizedPhone,
                    deviceName: effectiveDeviceName,
                    appVersion: appVersion
                )
                let merged = mergeAuthorization(
                    from: legacyResult,
                    fallbackToken: normalizedToken,
                    fallbackRefreshToken: normalizedRefreshToken
                )
                await syncDeviceNameIfNeeded(
                    scannedDeviceName: normalizedScannedDeviceName,
                    registration: merged
                )
                return merged
            }
        }

        let result = try await registerDeviceByLegacyEndpoint(
            token: nil,
            parentPhone: normalizedPhone,
            deviceName: effectiveDeviceName,
            appVersion: appVersion
        )
        await syncDeviceNameIfNeeded(
            scannedDeviceName: normalizedScannedDeviceName,
            registration: result
        )
        return result
    }
}

private extension AuthService {
    func syncDeviceNameIfNeeded(
        scannedDeviceName: String?,
        registration: AuthRegistrationResult
    ) async {
        await AuthDeviceNameSync.syncIfPossible(
            scannedDeviceName: scannedDeviceName,
            registration: registration,
            client: client,
            onDebug: debugLog
        )
    }

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
}

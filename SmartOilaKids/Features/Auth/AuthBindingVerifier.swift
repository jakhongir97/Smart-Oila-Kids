import Foundation

enum AuthBindingVerifier {
    typealias BindingRequest = (String) async throws -> Void
    typealias SleepAction = (UInt64) async -> Void

    static func verifyChildBinding(
        dsn: String,
        client: APIClient,
        onDebug: (String) -> Void
    ) async throws -> Bool {
        try await verifyChildBinding(
            dsn: dsn,
            onDebug: onDebug,
            performRequest: { sanitized in
                _ = try await client.requestDataWithBaseFallback(
                    baseURLs: AppConfig.apiBaseCandidates,
                    path: "devices/dsn/\(sanitized)/full_lock_status",
                    method: .get,
                    headers: ["Accept": "application/json"]
                )
            }
        )
    }

    static func verifyChildBinding(
        dsn: String,
        onDebug: (String) -> Void,
        maxAttempts: Int = 5,
        performRequest: BindingRequest,
        sleep: SleepAction = defaultSleep
    ) async throws -> Bool {
        let sanitized = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return false }
        guard maxAttempts > 0 else { return false }

        for attempt in 1...maxAttempts {
            do {
                try await performRequest(sanitized)
                return true
            } catch let NetworkError.server(statusCode, _) where statusCode == 401 || statusCode == 403 {
                // Some environments gate this endpoint behind member scope.
                // Registration already returned a DSN, so do not block onboarding.
                onDebug("Binding verification is auth-scoped (\(statusCode)); treating DSN as verified.")
                return true
            } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
                if attempt < maxAttempts {
                    onDebug("Binding verification: DSN not ready yet (\(attempt)/\(maxAttempts)). Retrying...")
                    await sleep(retryDelayNanoseconds(attempt: attempt))
                    continue
                }
                return false
            } catch let error as NetworkError {
                if attempt < maxAttempts,
                   NetworkError.shouldRetry(error, policy: .bindingVerification) {
                    if case let .server(statusCode, _) = error {
                        onDebug("Binding verification temporary server issue (\(statusCode)) (\(attempt)/\(maxAttempts)). Retrying...")
                    } else {
                        onDebug("Binding verification temporary failure (\(attempt)/\(maxAttempts)): \(error.localizedDescription). Retrying...")
                    }
                    await sleep(retryDelayNanoseconds(attempt: attempt))
                    continue
                }
                throw error
            } catch let error as URLError {
                if attempt < maxAttempts,
                   NetworkError.shouldRetry(error, policy: .bindingVerification) {
                    onDebug("Binding verification network issue (\(attempt)/\(maxAttempts)): \(error.code.rawValue). Retrying...")
                    await sleep(retryDelayNanoseconds(attempt: attempt))
                    continue
                }
                throw error
            } catch {
                if attempt < maxAttempts {
                    onDebug("Binding verification temporary failure (\(attempt)/\(maxAttempts)): \(error.localizedDescription). Retrying...")
                    await sleep(retryDelayNanoseconds(attempt: attempt))
                    continue
                }
                throw error
            }
        }

        return false
    }
    private static func retryDelayNanoseconds(attempt: Int) -> UInt64 {
        let safeAttempt = max(1, attempt)
        let baseDelay: UInt64 = 700_000_000
        let incrementalDelay: UInt64 = 300_000_000
        let delay = baseDelay + UInt64(safeAttempt - 1) * incrementalDelay
        return min(delay, 2_000_000_000)
    }

    private static func defaultSleep(_ nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

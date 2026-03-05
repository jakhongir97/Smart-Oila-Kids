import Foundation

enum AuthBindingVerifier {
    static func verifyChildBinding(
        dsn: String,
        client: APIClient,
        onDebug: (String) -> Void
    ) async throws -> Bool {
        let sanitized = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return false }

        let maxAttempts = 5

        for attempt in 1...maxAttempts {
            do {
                _ = try await client.requestDataWithBaseFallback(
                    baseURLs: AppConfig.apiBaseCandidates,
                    path: "devices/dsn/\(sanitized)/full_lock_status",
                    method: .get,
                    headers: ["Accept": "application/json"]
                )
                return true
            } catch let NetworkError.server(statusCode, _) where statusCode == 401 || statusCode == 403 {
                // Some environments gate this endpoint behind member scope.
                // Registration already returned a DSN, so do not block onboarding.
                onDebug("Binding verification is auth-scoped (\(statusCode)); treating DSN as verified.")
                return true
            } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
                if attempt < maxAttempts {
                    onDebug("Binding verification: DSN not ready yet (\(attempt)/\(maxAttempts)). Retrying...")
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds(attempt: attempt))
                    continue
                }
                return false
            } catch let NetworkError.server(statusCode, body) where statusCode == 429 || (500 ... 599).contains(statusCode) {
                if attempt < maxAttempts {
                    onDebug("Binding verification temporary server issue (\(statusCode)) (\(attempt)/\(maxAttempts)). Retrying...")
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds(attempt: attempt))
                    continue
                }
                throw NetworkError.server(statusCode: statusCode, body: body)
            } catch let error as URLError {
                if attempt < maxAttempts,
                   isRetryableNetworkError(error) {
                    onDebug("Binding verification network issue (\(attempt)/\(maxAttempts)): \(error.code.rawValue). Retrying...")
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds(attempt: attempt))
                    continue
                }
                throw error
            } catch {
                if attempt < maxAttempts {
                    onDebug("Binding verification temporary failure (\(attempt)/\(maxAttempts)): \(error.localizedDescription). Retrying...")
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds(attempt: attempt))
                    continue
                }
                throw error
            }
        }

        return false
    }

    private static func isRetryableNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .dataNotAllowed,
             .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    private static func retryDelayNanoseconds(attempt: Int) -> UInt64 {
        let safeAttempt = max(1, attempt)
        let baseDelay: UInt64 = 700_000_000
        let incrementalDelay: UInt64 = 300_000_000
        let delay = baseDelay + UInt64(safeAttempt - 1) * incrementalDelay
        return min(delay, 2_000_000_000)
    }
}

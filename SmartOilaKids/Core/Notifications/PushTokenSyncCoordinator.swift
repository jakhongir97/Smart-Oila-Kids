import Foundation

protocol PushTokenServicing {
    func syncToken(_ token: String, dsn: String) async throws
    func fetchRemoteToken(dsn: String) async throws -> String?
}

final class PushTokenService: PushTokenServicing {
    private struct FirebaseTokenResponse: Decodable {
        let token: String?
    }

    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func syncToken(_ token: String, dsn: String) async throws {
        struct Payload: Encodable {
            let token: String
        }

        let body = try JSONEncoder().encode(Payload(token: token))
        _ = try await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/dsn/\(dsn)/firebase_notification_token",
            method: .post,
            headers: ["Accept": "application/json"],
            body: body,
            contentType: "application/json"
        )
    }

    func fetchRemoteToken(dsn: String) async throws -> String? {
        do {
            let response: FirebaseTokenResponse = try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "devices/dsn/\(dsn)/firebase_notification_token",
                method: .get,
                headers: ["Accept": "application/json"],
                as: FirebaseTokenResponse.self
            )
            return response.token?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
            let fallbackResponse: FirebaseTokenResponse = try await client.requestDecodableWithBaseFallback(
                baseURLs: AppConfig.apiBaseCandidates,
                path: "members/me/firebase_notification_token",
                method: .get,
                headers: ["Accept": "application/json"],
                as: FirebaseTokenResponse.self
            )
            return fallbackResponse.token?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private let client: APIClient
}

actor PushTokenSyncCoordinator {
    static let shared = PushTokenSyncCoordinator()

    private enum Keys {
        static let token = "PUSH_NOTIFICATION_TOKEN"
        static let dsn = "DSN"
    }

    init(service: PushTokenServicing = PushTokenService(), userDefaults: UserDefaults = .standard) {
        self.service = service
        self.userDefaults = userDefaults
        self.cachedToken = userDefaults.string(forKey: Keys.token)
    }

    func bootstrapFromDefaults() async {
        if cachedToken == nil {
            cachedToken = userDefaults.string(forKey: Keys.token)
        }
        if currentDSN == nil {
            currentDSN = userDefaults.string(forKey: Keys.dsn)
        }
        await refreshDiagnostics()
        await syncIfNeeded()
    }

    func updateDSN(_ dsn: String?) async {
        currentDSN = dsn
        lastSyncedSignature = nil
        await refreshDiagnostics()
        await syncIfNeeded()
    }

    func updateToken(_ token: String?) async {
        let normalized = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedToken = normalized

        if let normalized, !normalized.isEmpty {
            userDefaults.set(normalized, forKey: Keys.token)
        } else {
            userDefaults.removeObject(forKey: Keys.token)
            cancelRetry()
        }

        lastSyncedSignature = nil
        await refreshDiagnostics()
        await syncIfNeeded()
    }

    private func syncIfNeeded() async {
        guard
            let dsn = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines),
            !dsn.isEmpty,
            let token = cachedToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return
        }

        let endpoint = pushTokenEndpoint(for: dsn)
        let signature = "\(dsn)|\(token)"
        guard signature != lastSyncedSignature else { return }

        await updateDiagnostics(
            status: "syncing",
            endpoint: endpoint,
            dsn: dsn,
            localToken: summarizeToken(token),
            remoteToken: nil,
            lastError: "-"
        )

        do {
            try await service.syncToken(token, dsn: dsn)
            lastSyncedSignature = signature
            resetRetryState()
            await updateDiagnostics(
                status: "synced",
                endpoint: endpoint,
                dsn: dsn,
                localToken: summarizeToken(token),
                lastError: "-"
            )
            await refreshRemoteToken(dsn: dsn, localToken: token)
        } catch {
            await updateDiagnostics(
                status: "sync_failed",
                endpoint: endpoint,
                dsn: dsn,
                localToken: summarizeToken(token),
                remoteToken: "-",
                lastError: error.localizedDescription
            )
            scheduleRetry(expectedSignature: signature)
        }
    }

    private func scheduleRetry(expectedSignature: String) {
        let delay = nextRetryDelay
        nextRetryDelay = min(nextRetryDelay * 2, maxRetryDelay)

        retryTask?.cancel()
        retryTask = Task {
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await self.handleRetry(expectedSignature: expectedSignature)
        }
    }

    private func handleRetry(expectedSignature: String) async {
        retryTask = nil

        guard
            let dsn = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines),
            !dsn.isEmpty,
            let token = cachedToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            return
        }

        let signature = "\(dsn)|\(token)"
        guard signature == expectedSignature else { return }
        await syncIfNeeded()
    }

    private func resetRetryState() {
        retryTask?.cancel()
        retryTask = nil
        nextRetryDelay = initialRetryDelay
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        nextRetryDelay = initialRetryDelay
    }

    private func refreshRemoteToken(dsn: String, localToken: String) async {
        do {
            let remoteToken = try await service.fetchRemoteToken(dsn: dsn)
            let remoteSummary = summarizeToken(remoteToken)
            let normalizedRemoteToken = remoteToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            let status: String
            if let normalizedRemoteToken, !normalizedRemoteToken.isEmpty {
                status = normalizedRemoteToken == localToken ? "verified" : "mismatch"
            } else {
                status = "synced"
            }

            await updateDiagnostics(
                status: status,
                endpoint: pushTokenEndpoint(for: dsn),
                dsn: dsn,
                localToken: summarizeToken(localToken),
                remoteToken: remoteSummary,
                lastError: "-"
            )
        } catch {
            await updateDiagnostics(
                status: "synced",
                endpoint: pushTokenEndpoint(for: dsn),
                dsn: dsn,
                localToken: summarizeToken(localToken),
                remoteToken: "-",
                lastError: "Readback failed: \(error.localizedDescription)"
            )
        }
    }

    private func refreshDiagnostics() async {
        let dsn = currentDSN?.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = cachedToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDSN = dsn?.isEmpty == false
        let hasToken = token?.isEmpty == false
        let status = (hasDSN && hasToken) ? "ready" : "idle"

        await updateDiagnostics(
            status: status,
            endpoint: dsn.map { pushTokenEndpoint(for: $0) } ?? "-",
            dsn: dsn ?? "-",
            localToken: summarizeToken(token),
            remoteToken: "-",
            lastError: status == "idle" ? "-" : nil
        )
    }

    private func pushTokenEndpoint(for dsn: String) -> String {
        "/devices/dsn/\(dsn)/firebase_notification_token"
    }

    private func summarizeToken(_ token: String?) -> String {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return "-"
        }

        if token.count <= 10 {
            return "\(token.prefix(3))...\(token.suffix(2)) (\(token.count))"
        }

        return "\(token.prefix(6))...\(token.suffix(4)) (\(token.count))"
    }

    @MainActor
    private func updateDiagnostics(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        localToken: String? = nil,
        remoteToken: String? = nil,
        lastError: String? = nil
    ) {
        RuntimeDiagnosticsCenter.shared.updatePushToken(
            status: status,
            endpoint: endpoint,
            dsn: dsn,
            localToken: localToken,
            remoteToken: remoteToken,
            lastError: lastError
        )
    }

    private let service: PushTokenServicing
    private let userDefaults: UserDefaults

    private var currentDSN: String?
    private var cachedToken: String?
    private var lastSyncedSignature: String?
    private var retryTask: Task<Void, Never>?
    private let initialRetryDelay: TimeInterval = 5
    private let maxRetryDelay: TimeInterval = 300
    private var nextRetryDelay: TimeInterval = 5
}

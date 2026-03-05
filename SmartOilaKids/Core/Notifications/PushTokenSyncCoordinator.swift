import Foundation

protocol PushTokenServicing {
    func syncToken(_ token: String, dsn: String) async throws
}

final class PushTokenService: PushTokenServicing {
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
        await syncIfNeeded()
    }

    func updateDSN(_ dsn: String?) async {
        currentDSN = dsn
        lastSyncedSignature = nil
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

        let signature = "\(dsn)|\(token)"
        guard signature != lastSyncedSignature else { return }

        do {
            try await service.syncToken(token, dsn: dsn)
            lastSyncedSignature = signature
            resetRetryState()
        } catch {
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

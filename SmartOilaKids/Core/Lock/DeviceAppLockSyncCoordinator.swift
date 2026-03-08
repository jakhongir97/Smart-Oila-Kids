import Foundation

struct DeviceAppLockSyncEntry: Codable, Equatable, Hashable {
    let packageName: String
    let appName: String
    let isLocked: Bool
    let usedTime: Int

    enum CodingKeys: String, CodingKey {
        case packageName = "package_name"
        case appName = "app_name"
        case isLocked = "is_locked"
        case usedTime = "used_time"
    }
}

protocol DeviceAppLockSyncServicing {
    func syncApplications(_ entries: [DeviceAppLockSyncEntry], dsn: String) async throws
}

final class DeviceAppLockSyncService: DeviceAppLockSyncServicing {
    init(client: APIClient = APIClient()) {
        self.client = client
    }

    func syncApplications(_ entries: [DeviceAppLockSyncEntry], dsn: String) async throws {
        let body = try JSONEncoder().encode(entries)
        _ = try await client.requestDataWithBaseFallback(
            baseURLs: AppConfig.apiBaseCandidates,
            path: "devices/\(dsn)/applications/sync",
            method: .put,
            headers: ["Accept": "application/json"],
            body: body,
            contentType: "application/json"
        )
    }

    private let client: APIClient
}

actor DeviceAppLockSyncCoordinator {
    static let shared = DeviceAppLockSyncCoordinator()

    init(service: DeviceAppLockSyncServicing = DeviceAppLockSyncService()) {
        self.service = service
    }

    func update(dsn: String?, entries: [DeviceAppLockSyncEntry]) async {
        currentDSN = normalizedDSN(dsn)
        currentEntries = entries.sorted { lhs, rhs in
            lhs.packageName.localizedCaseInsensitiveCompare(rhs.packageName) == .orderedAscending
        }

        if currentDSN == nil {
            lastSyncedSignature = nil
            cancelRetry()
            updateDiagnostics(status: "idle", dsn: "-", lastPayload: "0 apps", lastError: "-")
            return
        }

        await syncIfNeeded(force: false)
    }

    func retryNow() async {
        await syncIfNeeded(force: true)
    }

    private func syncIfNeeded(force: Bool) async {
        guard let dsn = currentDSN else { return }

        let signature = signatureForCurrentState(dsn: dsn)
        guard force || signature != lastSyncedSignature else { return }

        let endpoint = "\(AppConfig.apiBaseURL.absoluteString)/devices/\(dsn)/applications/sync"
        updateDiagnostics(
            status: retryTask == nil ? "syncing" : "retrying",
            endpoint: endpoint,
            dsn: dsn,
            lastPayload: payloadSummary(),
            lastError: "-"
        )

        do {
            try await service.syncApplications(currentEntries, dsn: dsn)
            lastSyncedSignature = signature
            resetRetryState()
            updateDiagnostics(
                status: "synced",
                endpoint: endpoint,
                dsn: dsn,
                lastPayload: payloadSummary(),
                lastError: "-",
                lastSyncAt: Date()
            )
        } catch {
            updateDiagnostics(
                status: "failed",
                endpoint: endpoint,
                dsn: dsn,
                lastPayload: payloadSummary(),
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

        guard let dsn = currentDSN else { return }
        guard expectedSignature == signatureForCurrentState(dsn: dsn) else { return }
        await syncIfNeeded(force: true)
    }

    private func signatureForCurrentState(dsn: String) -> String {
        let fingerprint = currentEntries
            .map { entry in
                "\(entry.packageName)|\(entry.appName)|\(entry.isLocked ? 1 : 0)|\(entry.usedTime)"
            }
            .joined(separator: ",")
        return "\(dsn)|\(fingerprint)"
    }

    private func payloadSummary() -> String {
        let lockedCount = currentEntries.reduce(into: 0) { count, entry in
            if entry.isLocked {
                count += 1
            }
        }
        let totalUsedTime = currentEntries.reduce(into: 0) { result, entry in
            result += max(0, entry.usedTime)
        }
        return "\(currentEntries.count) apps, \(lockedCount) locked, \(totalUsedTime)s"
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

    private func normalizedDSN(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            return normalized
        }
        return nil
    }

    private func updateDiagnostics(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil,
        lastSyncAt: Date? = nil
    ) {
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updateAppLockSync(
                status: status,
                endpoint: endpoint,
                dsn: dsn,
                lastPayload: lastPayload,
                lastError: lastError,
                lastSyncAt: lastSyncAt
            )
        }
    }

    private let service: DeviceAppLockSyncServicing
    private var currentDSN: String?
    private var currentEntries: [DeviceAppLockSyncEntry] = []
    private var lastSyncedSignature: String?
    private var retryTask: Task<Void, Never>?
    private let initialRetryDelay: TimeInterval = 5
    private let maxRetryDelay: TimeInterval = 300
    private var nextRetryDelay: TimeInterval = 5
}

import Foundation

/// One row of `PUT /device/apps/sync` — `AppSyncItemDto` exactly: `packageName` + `name`, both
/// required, camelCase, 1...255 characters.
///
/// The shape is the contract, not a convenience: the API runs `forbidNonWhitelisted`, so the
/// snake_case `package_name`/`app_name`/`is_locked`/`used_time` this type used to serialise would
/// have been rejected with a 400 on all four keys. The lock flag and today's usage are NOT part of
/// this endpoint — the parent sets locks through `PUT /parent/children/{id}/apps/{packageName}/lock`
/// and usage rides `POST /device/apps/usage`.
struct DeviceAppLockSyncEntry: Codable, Equatable, Hashable {
    let packageName: String
    let name: String
}

protocol DeviceAppLockSyncServicing {
    func syncApplications(_ entries: [DeviceAppLockSyncEntry], dsn: String) async throws
}

/// Thrown when there is nothing the endpoint will accept, so the coordinator can tell "nothing to
/// send" apart from a real network failure. Retrying an empty catalogue cannot help — only a new
/// probe result can — so this case cancels the retry instead of scheduling one.
struct DeviceAppLockSyncUnavailableError: LocalizedError {
    var errorDescription: String? {
        "No installed apps to sync (PUT /device/apps/sync requires at least one item)"
    }
}

/// Live transport for the installed-app catalogue: `PUT /device/apps/sync`.
///
/// It replaces a stub that threw `DeviceAppLockSyncUnavailableError`, which was correct while iOS
/// had nothing to send — Apple offers no way to enumerate installed apps. The catalogue probe
/// (`InstalledAppProbe`) is what gives this endpoint something true to say.
///
/// `SyncAppsDto` declares `minItems: 1`, so an empty catalogue is not "sync nothing", it is a 400.
/// Callers must skip the request instead; this transport refuses it loudly rather than sending it.
final class DeviceAppLockSyncService: DeviceAppLockSyncServicing {
    init(client: OilaDeviceServicing = OilaDeviceClient.shared) {
        self.client = client
    }

    func syncApplications(_ entries: [DeviceAppLockSyncEntry], dsn: String) async throws {
        guard !entries.isEmpty else { throw DeviceAppLockSyncUnavailableError() }
        try await client.syncInstalledApps(items: entries)
    }

    private let client: OilaDeviceServicing
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

        let endpoint = "\(AppConfig.oilaAPIBaseURL.absoluteString)/device/apps/sync"
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
        } catch is DeviceAppLockSyncUnavailableError {
            // Nothing to send is not a failure: `SyncAppsDto` requires at least one item, and only
            // a fresh probe can change that. Retrying would leave the diagnostics screen cycling
            // "retrying"/"failed" against a request the app is deliberately not making.
            cancelRetry()
            updateDiagnostics(
                status: "empty",
                endpoint: endpoint,
                dsn: dsn,
                lastPayload: payloadSummary(),
                lastError: "-"
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
        retryGeneration &+= 1
        let generation = retryGeneration
        retryTask = Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            // A cancelled sleep returns immediately; without this guard the superseded retry would
            // fire right away and, worse, clear the replacement task that just cancelled it.
            guard !Task.isCancelled else { return }
            await self?.handleRetry(expectedSignature: expectedSignature, generation: generation)
        }
    }

    private func handleRetry(expectedSignature: String, generation: Int) async {
        // Only the currently-scheduled retry may act / clear the shared task handle.
        guard generation == retryGeneration else { return }
        retryTask = nil

        guard let dsn = currentDSN else { return }
        guard expectedSignature == signatureForCurrentState(dsn: dsn) else { return }
        await syncIfNeeded(force: true)
    }

    private func signatureForCurrentState(dsn: String) -> String {
        let fingerprint = currentEntries
            .map { entry in "\(entry.packageName)|\(entry.name)" }
            .joined(separator: ",")
        return "\(dsn)|\(fingerprint)"
    }

    private func payloadSummary() -> String {
        "\(currentEntries.count) apps"
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
    private var retryGeneration = 0
    private let initialRetryDelay: TimeInterval = 5
    private let maxRetryDelay: TimeInterval = 300
    private var nextRetryDelay: TimeInterval = 5
}

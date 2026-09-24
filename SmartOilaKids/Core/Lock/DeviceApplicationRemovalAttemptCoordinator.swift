import Foundation

struct DeviceApplicationRemovalAttemptEntry: Codable, Equatable, Hashable {
    let dsn: String
    let packageName: String
    let appName: String
}

protocol DeviceApplicationRemovalAttemptServicing {
    func reportRemovalAttempt(dsn: String, packageName: String, appName: String) async throws
}

final class DeviceApplicationRemovalAttemptService: DeviceApplicationRemovalAttemptServicing {
    init(oila: OilaDeviceServicing = OilaDeviceClient.shared) {
        self.oila = oila
    }

    func reportRemovalAttempt(dsn: String, packageName: String, appName: String) async throws {
        // oila360 identifies the device from its Bearer token (issued at pairing), so `dsn`
        // is only used by the coordinator for dedup/diagnostics — the request body carries
        // just the app. `POST /device/apps/removal-attempt` → ReportRemovalAttemptDto.
        try await oila.reportRemovalAttempt(packageName: packageName, applicationName: appName)
    }

    private let oila: OilaDeviceServicing
}

actor DeviceApplicationRemovalAttemptCoordinator {
    static let shared = DeviceApplicationRemovalAttemptCoordinator()

    init(
        service: DeviceApplicationRemovalAttemptServicing = DeviceApplicationRemovalAttemptService(),
        userDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.userDefaults = userDefaults
        let restored = Self.loadQueue(userDefaults: userDefaults)
        pendingEntries = restored
        pendingFingerprints = Set(restored.map { Self.fingerprint(for: $0) })
    }

    func enqueue(dsn: String, packageName: String, appName: String) async {
        guard let entry = normalizedEntry(dsn: dsn, packageName: packageName, appName: appName) else { return }
        let fingerprint = Self.fingerprint(for: entry)

        guard !pendingFingerprints.contains(fingerprint) else { return }
        pendingEntries.append(entry)
        pendingFingerprints.insert(fingerprint)
        persistQueue()

        await processQueueIfPossible()
    }

    /// Drains anything that survived a relaunch (or an unfired backoff). Mirrors the usage
    /// coordinator's foreground retry hook.
    func retryNow() async {
        await processQueueIfPossible()
    }

    private func processQueueIfPossible() async {
        guard !isProcessing, retryTask == nil else { return }
        isProcessing = true
        defer { isProcessing = false }

        while let entry = pendingEntries.first {
            updateDiagnostics(
                status: "reporting",
                endpoint: endpoint(for: entry),
                dsn: entry.dsn,
                lastEvent: payloadSummary(for: entry),
                lastError: "-"
            )

            // Actors are re-entrant: while this one waits on the request, `purge()` (a Disconnect)
            // can empty the queue and the next pairing can refill it. So the answer below may only
            // touch THIS entry, and only in the queue it came from — `removeFirst()` on the emptied
            // array was a crash (build 27), and on a refilled one it dropped the next pairing's
            // report unsent.
            let generation = purgeGeneration
            do {
                try await service.reportRemovalAttempt(
                    dsn: entry.dsn,
                    packageName: entry.packageName,
                    appName: entry.appName
                )

                guard generation == purgeGeneration else { continue }
                remove(entry)
                persistQueue()
                nextRetryDelay = initialRetryDelay
                updateDiagnostics(
                    status: "reported",
                    endpoint: endpoint(for: entry),
                    dsn: entry.dsn,
                    lastEvent: payloadSummary(for: entry),
                    lastError: "-"
                )
            } catch {
                // Purged meanwhile: this entry is gone, and its failure says nothing about the next
                // pairing's queue — carry on with whatever that holds.
                guard generation == purgeGeneration else { continue }
                if Self.isPermanentReject(error) {
                    // The server will never accept this entry (non-auth 4xx), so retrying it would
                    // wedge the head of the queue forever. Drop it and continue with the rest —
                    // same model as DeviceApplicationUsageReportCoordinator.
                    remove(entry)
                    persistQueue()
                    updateDiagnostics(
                        status: "dropped",
                        endpoint: endpoint(for: entry),
                        dsn: entry.dsn,
                        lastEvent: payloadSummary(for: entry),
                        lastError: "dropped: \(error.localizedDescription)"
                    )
                    continue
                }

                updateDiagnostics(
                    status: "failed",
                    endpoint: endpoint(for: entry),
                    dsn: entry.dsn,
                    lastEvent: payloadSummary(for: entry),
                    lastError: error.localizedDescription
                )
                scheduleRetry()
                return
            }
        }
    }

    /// By identity, not position: see `processQueueIfPossible`.
    private func remove(_ entry: DeviceApplicationRemovalAttemptEntry) {
        if let index = pendingEntries.firstIndex(of: entry) {
            pendingEntries.remove(at: index)
        }
        pendingFingerprints.remove(Self.fingerprint(for: entry))
    }

    private func scheduleRetry() {
        let delay = nextRetryDelay
        nextRetryDelay = min(nextRetryDelay * 2, maxRetryDelay)

        retryTask?.cancel()
        retryTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self.handleRetry()
        }
    }

    private func handleRetry() async {
        retryTask = nil
        await processQueueIfPossible()
    }

    private func normalizedEntry(
        dsn: String,
        packageName: String,
        appName: String
    ) -> DeviceApplicationRemovalAttemptEntry? {
        let normalizedDSN = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPackageName = packageName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedDSN.isEmpty,
              !normalizedPackageName.isEmpty,
              !normalizedAppName.isEmpty else {
            return nil
        }

        return DeviceApplicationRemovalAttemptEntry(
            dsn: normalizedDSN,
            packageName: normalizedPackageName,
            appName: normalizedAppName
        )
    }

    private func payloadSummary(for entry: DeviceApplicationRemovalAttemptEntry) -> String {
        "\(entry.appName) (\(entry.packageName))"
    }

    private func endpoint(for entry: DeviceApplicationRemovalAttemptEntry) -> String {
        "\(AppConfig.oilaAPIBaseURL.absoluteString)/device/apps/removal-attempt"
    }

    private func updateDiagnostics(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastEvent: String? = nil,
        lastError: String? = nil
    ) {
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updateAppLockIntegrity(
                status: status,
                endpoint: endpoint,
                dsn: dsn,
                lastEvent: lastEvent,
                lastError: lastError
            )
        }
    }

    private static func fingerprint(for entry: DeviceApplicationRemovalAttemptEntry) -> String {
        "\(entry.dsn.lowercased())|\(entry.packageName)|\(entry.appName.lowercased())"
    }

    /// A tamper report the server rejects with a non-auth 4xx will never succeed on retry. 401
    /// (auth), 408/425 (timeout) and 429 (rate limit) are transient and stay queued; 5xx and
    /// network errors are transient too.
    private static func isPermanentReject(_ error: Error) -> Bool {
        guard let api = error as? OilaAPIError else { return false }
        switch api.statusCode {
        case 401, 408, 425, 429:
            return false
        case 400 ..< 500:
            return true
        default:
            return false
        }
    }

    /// Drops every queued report and the persisted copy, for unpair.
    ///
    /// Clearing only the UserDefaults key is not enough: this actor is long-lived, so its in-memory
    /// queue and any armed retry survive the disconnect and `persistQueue()` writes the key straight
    /// back. `POST /device/apps/removal-attempt` carries no dsn, so a report queued for the previous
    /// child would then be attributed to the NEXT family's device token, leaking that child's app names.
    func purge() {
        purgeGeneration &+= 1
        retryTask?.cancel()
        retryTask = nil
        pendingEntries.removeAll()
        pendingFingerprints.removeAll()
        userDefaults.removeObject(forKey: Self.storageKey)
    }

    // The queue is persisted so a tamper report is not lost when the app is killed mid-backoff —
    // it is the only signal the parent gets that protection was removed from the child's phone.
    private func persistQueue() {
        guard let data = try? JSONEncoder().encode(pendingEntries) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private static func loadQueue(userDefaults: UserDefaults) -> [DeviceApplicationRemovalAttemptEntry] {
        guard let data = userDefaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([DeviceApplicationRemovalAttemptEntry].self, from: data) else {
            return []
        }
        return entries
    }

    private let service: DeviceApplicationRemovalAttemptServicing
    private let userDefaults: UserDefaults
    private var pendingEntries: [DeviceApplicationRemovalAttemptEntry] = []
    private var pendingFingerprints: Set<String> = []
    private var isProcessing = false
    /// Bumped by every `purge()`, so a request that was out across one knows its queue is gone.
    private var purgeGeneration = 0
    private var retryTask: Task<Void, Never>?
    private let initialRetryDelay: TimeInterval = 5
    private let maxRetryDelay: TimeInterval = 300
    private var nextRetryDelay: TimeInterval = 5
    private static let storageKey = "DEVICE_APPLICATION_REMOVAL_ATTEMPT_QUEUE"
}

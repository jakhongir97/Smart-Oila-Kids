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

    init(service: DeviceApplicationRemovalAttemptServicing = DeviceApplicationRemovalAttemptService()) {
        self.service = service
    }

    func enqueue(dsn: String, packageName: String, appName: String) async {
        guard let entry = normalizedEntry(dsn: dsn, packageName: packageName, appName: appName) else { return }
        let fingerprint = Self.fingerprint(for: entry)

        guard !pendingFingerprints.contains(fingerprint) else { return }
        pendingEntries.append(entry)
        pendingFingerprints.insert(fingerprint)

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

            do {
                try await service.reportRemovalAttempt(
                    dsn: entry.dsn,
                    packageName: entry.packageName,
                    appName: entry.appName
                )

                pendingEntries.removeFirst()
                pendingFingerprints.remove(Self.fingerprint(for: entry))
                nextRetryDelay = initialRetryDelay
                updateDiagnostics(
                    status: "reported",
                    endpoint: endpoint(for: entry),
                    dsn: entry.dsn,
                    lastEvent: payloadSummary(for: entry),
                    lastError: "-"
                )
            } catch {
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

    private let service: DeviceApplicationRemovalAttemptServicing
    private var pendingEntries: [DeviceApplicationRemovalAttemptEntry] = []
    private var pendingFingerprints: Set<String> = []
    private var isProcessing = false
    private var retryTask: Task<Void, Never>?
    private let initialRetryDelay: TimeInterval = 5
    private let maxRetryDelay: TimeInterval = 300
    private var nextRetryDelay: TimeInterval = 5
}

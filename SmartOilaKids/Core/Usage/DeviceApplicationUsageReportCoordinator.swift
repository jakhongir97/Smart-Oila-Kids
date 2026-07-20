import Foundation

struct DeviceApplicationUsageReportItemRequest: Codable, Equatable {
    let packageName: String
    let usedSeconds: Int

    // Live oila360 contract (`POST /device/apps/usage`, PostUsageDto/UsageItemDto) is camelCase.
    enum CodingKeys: String, CodingKey {
        case packageName
        case usedSeconds
    }
}

struct DeviceApplicationUsageReportStat: Decodable, Equatable {
    let packageName: String
    let usageDate: String?
    let usedSeconds: Int
    let dailyLimitSeconds: Int?
    let remainingSeconds: Int?
    let isLimitReached: Bool

    // Live oila360 contract (usage response `stats[]`, mirrors Android AppUsageStatDto) is camelCase.
    enum CodingKeys: String, CodingKey {
        case packageName
        case usageDate
        case usedSeconds
        case dailyLimitSeconds
        case remainingSeconds
        case isLimitReached
    }
}

// Tolerant decode mirroring Android's proven-nullable AppUsageStatDto (secondary all-null ctor):
// the live backend sometimes omits/nulls these fields, so decode must never throw on a sparse
// 200 — otherwise the usage batch fails to decode, the coordinator retries the same delta
// forever, and the enforcement state never reaches the app-limit monitor. The custom init lives
// in an extension so the memberwise initializer (used by tests) is preserved.
extension DeviceApplicationUsageReportStat {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packageName = try c.decodeIfPresent(String.self, forKey: .packageName) ?? ""
        usageDate = try c.decodeIfPresent(String.self, forKey: .usageDate)
        usedSeconds = try c.decodeIfPresent(Int.self, forKey: .usedSeconds) ?? 0
        dailyLimitSeconds = try c.decodeIfPresent(Int.self, forKey: .dailyLimitSeconds)
        remainingSeconds = try c.decodeIfPresent(Int.self, forKey: .remainingSeconds)
        isLimitReached = try c.decodeIfPresent(Bool.self, forKey: .isLimitReached) ?? false
    }
}

struct DeviceApplicationUsageReportResponse: Decodable, Equatable {
    let lockedPackages: [String]
    let stats: [DeviceApplicationUsageReportStat]

    // Live oila360 contract (usage response, mirrors Android UsageReportResponse) is camelCase.
    enum CodingKeys: String, CodingKey {
        case lockedPackages
        case stats
    }
}

// Tolerant decode mirroring Android's nullable UsageReportResponse (all-null secondary ctor): a
// sparse/null 200 decodes to empty lists instead of throwing, so the batch is accepted and the
// queue advances rather than retrying forever. Custom init in an extension keeps the memberwise
// initializer available to tests.
extension DeviceApplicationUsageReportResponse {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lockedPackages = try c.decodeIfPresent([String].self, forKey: .lockedPackages) ?? []
        stats = try c.decodeIfPresent([DeviceApplicationUsageReportStat].self, forKey: .stats) ?? []
    }
}

protocol DeviceApplicationUsageReportServicing {
    func reportUsage(
        dsn: String,
        items: [DeviceApplicationUsageReportItemRequest]
    ) async throws -> DeviceApplicationUsageReportResponse
}

final class DeviceApplicationUsageReportService: DeviceApplicationUsageReportServicing {
    init(client: OilaDeviceServicing = OilaDeviceClient.shared) {
        self.client = client
    }

    /// Reports app-usage deltas to the live oila360 device surface
    /// (`POST /api/v1/device/apps/usage`). The device is identified by its bearer token, so
    /// `dsn` no longer appears in the path — it is retained only for the coordinator's queue
    /// keying/diagnostics. The non-empty response is the enforcement state that drives
    /// on-device app-limit locking.
    func reportUsage(
        dsn: String,
        items: [DeviceApplicationUsageReportItemRequest]
    ) async throws -> DeviceApplicationUsageReportResponse {
        try await client.reportAppUsage(items: items)
    }

    private let client: OilaDeviceServicing
}

actor DeviceApplicationUsageReportCoordinator {
    typealias ResponseHandler = @Sendable (String, DeviceApplicationUsageReportResponse) async -> Void
    typealias DiagnosticsUpdater = @Sendable (
        String?,
        String?,
        String?,
        Int?,
        String?,
        String?,
        Date?,
        String?
    ) -> Void
    typealias RetryScheduler = @Sendable (
        TimeInterval,
        @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>

    static let shared = DeviceApplicationUsageReportCoordinator()

    init(
        service: DeviceApplicationUsageReportServicing = DeviceApplicationUsageReportService(),
        userDefaults: UserDefaults = .standard,
        initialRetryDelay: TimeInterval = 5,
        maxRetryDelay: TimeInterval = 300,
        responseHandler: ResponseHandler? = nil,
        diagnosticsUpdater: DiagnosticsUpdater? = nil,
        retryScheduler: RetryScheduler? = nil
    ) {
        self.service = service
        self.userDefaults = userDefaults
        self.initialRetryDelay = initialRetryDelay
        self.maxRetryDelay = maxRetryDelay
        self.nextRetryDelay = initialRetryDelay
        self.responseHandler = responseHandler ?? { dsn, response in
            await Self.defaultResponseHandler(dsn: dsn, response: response)
        }
        self.diagnosticsUpdater = diagnosticsUpdater ?? { status, dsn, endpoint, queuedBatchCount, lastPayload, lastResponse, lastUploadAt, lastError in
            Self.defaultDiagnosticsUpdater(
                status: status,
                dsn: dsn,
                endpoint: endpoint,
                queuedBatchCount: queuedBatchCount,
                lastPayload: lastPayload,
                lastResponse: lastResponse,
                lastUploadAt: lastUploadAt,
                lastError: lastError
            )
        }
        self.retryScheduler = retryScheduler ?? { delay, operation in
            Self.defaultRetryScheduler(delay: delay, operation: operation)
        }
        let loadedState = Self.loadState(userDefaults: userDefaults, storageKey: Self.storageKey)
        persistedState = loadedState

        let initialDSN = loadedState.pendingBatches.first?.dsn ?? "-"
        self.diagnosticsUpdater(
            loadedState.pendingBatches.isEmpty ? "idle" : "queued",
            initialDSN,
            loadedState.lastEndpoint ?? endpointPlaceholder,
            loadedState.pendingBatches.count,
            loadedState.lastPayloadSummary ?? "-",
            loadedState.lastResponseSummary ?? "-",
            loadedState.lastSuccessfulUploadAt,
            loadedState.lastErrorSummary ?? "-"
        )
    }

    func updateDSN(_ dsn: String?) async {
        currentDSN = normalizedDSN(dsn)

        if currentDSN == nil {
            cancelRetry()
        }

        updateDiagnostics(
            status: persistedState.pendingBatches.isEmpty
                ? (currentDSN == nil ? "idle" : "ready")
                : "queued",
            dsn: currentDSN ?? persistedState.pendingBatches.first?.dsn ?? "-",
            endpoint: persistedState.lastEndpoint ?? endpointPlaceholder,
            queuedBatchCount: persistedState.pendingBatches.count,
            lastPayload: persistedState.lastPayloadSummary ?? "-",
            lastResponse: persistedState.lastResponseSummary ?? "-",
            lastUploadAt: persistedState.lastSuccessfulUploadAt,
            lastError: persistedState.lastErrorSummary ?? "-"
        )

        await processQueueIfPossible(force: true)
    }

    func updateSnapshot(_ snapshot: ScreenTimeUsageSnapshot) async {
        guard let batch = makePendingBatch(from: snapshot) else {
            persistState()
            updateDiagnostics(
                status: persistedState.pendingBatches.isEmpty
                    ? (currentDSN == nil ? "idle" : "ready")
                    : "queued",
                dsn: currentDSN ?? normalizedDSN(snapshot.dsn) ?? persistedState.pendingBatches.first?.dsn ?? "-",
                endpoint: persistedState.lastEndpoint ?? endpointPlaceholder,
                queuedBatchCount: persistedState.pendingBatches.count,
                lastPayload: persistedState.lastPayloadSummary ?? "-",
                lastResponse: persistedState.lastResponseSummary ?? "-",
                lastUploadAt: persistedState.lastSuccessfulUploadAt,
                lastError: persistedState.lastErrorSummary ?? "-"
            )
            return
        }

        persistedState.pendingBatches.append(batch)
        // Bound the backlog: an extended offline period (or a permanently-wedged head, now guarded
        // below) must not let the queue grow without limit. Oldest batches are the least useful.
        if persistedState.pendingBatches.count > maxPendingBatches {
            persistedState.pendingBatches.removeFirst(persistedState.pendingBatches.count - maxPendingBatches)
        }
        persistedState.lastPayloadSummary = payloadSummary(for: batch)
        persistedState.lastEndpoint = endpoint(for: batch.dsn)
        persistedState.lastErrorSummary = "-"
        persistState()

        updateDiagnostics(
            status: "queued",
            dsn: batch.dsn,
            endpoint: endpoint(for: batch.dsn),
            queuedBatchCount: persistedState.pendingBatches.count,
            lastPayload: persistedState.lastPayloadSummary,
            lastResponse: persistedState.lastResponseSummary ?? "-",
            lastUploadAt: persistedState.lastSuccessfulUploadAt,
            lastError: "-"
        )

        await processQueueIfPossible(force: false)
    }

    func retryNow() async {
        await processQueueIfPossible(force: true)
    }

    func pendingBatchCount() -> Int {
        persistedState.pendingBatches.count
    }

    private struct PendingBatchItem: Codable, Equatable {
        let packageName: String
        let appName: String
        let usedSeconds: Int
        let totalUsedSeconds: Int
    }

    private struct PendingBatch: Codable, Equatable {
        let id: String
        let dsn: String
        let dayKey: String
        let items: [PendingBatchItem]
        let createdAt: Date

        var requestItems: [DeviceApplicationUsageReportItemRequest] {
            items.map { item in
                DeviceApplicationUsageReportItemRequest(
                    packageName: item.packageName,
                    usedSeconds: item.usedSeconds
                )
            }
        }
    }

    private struct PersistedState: Codable, Equatable {
        var pendingBatches: [PendingBatch] = []
        var accountedUsageByKey: [String: Int] = [:]
        var lastSuccessfulUploadAt: Date? = nil
        var lastPayloadSummary: String? = nil
        var lastResponseSummary: String? = nil
        var lastEndpoint: String? = nil
        var lastErrorSummary: String? = nil
    }

    private func processQueueIfPossible(force: Bool) async {
        guard !isProcessing else { return }
        guard force || retryTask == nil else { return }

        guard !persistedState.pendingBatches.isEmpty else {
            updateDiagnostics(
                status: currentDSN == nil ? "idle" : "ready",
                dsn: currentDSN ?? "-",
                endpoint: persistedState.lastEndpoint ?? endpointPlaceholder,
                queuedBatchCount: 0,
                lastPayload: persistedState.lastPayloadSummary ?? "-",
                lastResponse: persistedState.lastResponseSummary ?? "-",
                lastUploadAt: persistedState.lastSuccessfulUploadAt,
                lastError: persistedState.lastErrorSummary ?? "-"
            )
            return
        }

        guard currentDSN != nil else {
            updateDiagnostics(
                status: "queued",
                dsn: persistedState.pendingBatches.first?.dsn ?? "-",
                endpoint: persistedState.lastEndpoint ?? endpointPlaceholder,
                queuedBatchCount: persistedState.pendingBatches.count,
                lastPayload: persistedState.lastPayloadSummary ?? "-",
                lastResponse: persistedState.lastResponseSummary ?? "-",
                lastUploadAt: persistedState.lastSuccessfulUploadAt,
                lastError: persistedState.lastErrorSummary ?? "-"
            )
            return
        }

        isProcessing = true
        defer { isProcessing = false }

        while let batch = persistedState.pendingBatches.first {
            let endpoint = endpoint(for: batch.dsn)
            let payloadSummary = payloadSummary(for: batch)
            let syncStatus = retryTask == nil ? "syncing" : "retrying"

            persistedState.lastEndpoint = endpoint
            persistedState.lastPayloadSummary = payloadSummary
            persistedState.lastErrorSummary = "-"
            persistState()

            updateDiagnostics(
                status: syncStatus,
                dsn: batch.dsn,
                endpoint: endpoint,
                queuedBatchCount: persistedState.pendingBatches.count,
                lastPayload: payloadSummary,
                lastResponse: persistedState.lastResponseSummary ?? "-",
                lastUploadAt: persistedState.lastSuccessfulUploadAt,
                lastError: "-"
            )

            do {
                let response = try await service.reportUsage(
                    dsn: batch.dsn,
                    items: batch.requestItems
                )

                persistedState.pendingBatches.removeFirst()
                persistedState.lastSuccessfulUploadAt = Date()
                persistedState.lastPayloadSummary = payloadSummary
                persistedState.lastResponseSummary = responseSummary(response)
                persistedState.lastEndpoint = endpoint
                persistedState.lastErrorSummary = "-"
                nextRetryDelay = initialRetryDelay
                cancelRetry()
                persistState()

                updateDiagnostics(
                    status: persistedState.pendingBatches.isEmpty ? "synced" : "queued",
                    dsn: batch.dsn,
                    endpoint: endpoint,
                    queuedBatchCount: persistedState.pendingBatches.count,
                    lastPayload: payloadSummary,
                    lastResponse: persistedState.lastResponseSummary,
                    lastUploadAt: persistedState.lastSuccessfulUploadAt,
                    lastError: "-"
                )

                await responseHandler(batch.dsn, response)
            } catch {
                persistedState.lastEndpoint = endpoint
                persistedState.lastPayloadSummary = payloadSummary
                persistedState.lastErrorSummary = error.localizedDescription

                if Self.isPermanentReject(error) {
                    // The server will never accept this batch (4xx validation error). Drop it so it
                    // cannot wedge the head of the queue forever, and continue with the rest.
                    persistedState.pendingBatches.removeFirst()
                    persistState()
                    updateDiagnostics(
                        status: persistedState.pendingBatches.isEmpty ? "synced" : "queued",
                        dsn: batch.dsn,
                        endpoint: endpoint,
                        queuedBatchCount: persistedState.pendingBatches.count,
                        lastPayload: payloadSummary,
                        lastResponse: persistedState.lastResponseSummary ?? "-",
                        lastUploadAt: persistedState.lastSuccessfulUploadAt,
                        lastError: "dropped: \(error.localizedDescription)"
                    )
                    continue
                }

                persistState()

                updateDiagnostics(
                    status: "failed",
                    dsn: batch.dsn,
                    endpoint: endpoint,
                    queuedBatchCount: persistedState.pendingBatches.count,
                    lastPayload: payloadSummary,
                    lastResponse: persistedState.lastResponseSummary ?? "-",
                    lastUploadAt: persistedState.lastSuccessfulUploadAt,
                    lastError: error.localizedDescription
                )

                scheduleRetry()
                return
            }
        }
    }

    private func makePendingBatch(from snapshot: ScreenTimeUsageSnapshot) -> PendingBatch? {
        guard let dsn = normalizedDSN(snapshot.dsn),
              let dayKey = normalizedDayKey(snapshot.dayKey) else {
            return nil
        }

        var items: [PendingBatchItem] = []

        for entry in snapshot.entries.sorted(by: { lhs, rhs in
            lhs.packageName.localizedCaseInsensitiveCompare(rhs.packageName) == .orderedAscending
        }) {
            guard let packageName = normalizedIdentifier(entry.packageName) else { continue }

            let accountedKey = usageKey(dsn: dsn, dayKey: dayKey, packageName: packageName)
            let normalizedUsedSeconds = max(0, min(entry.usedTime, 86_400))
            let previousUsedSeconds = persistedState.accountedUsageByKey[accountedKey] ?? 0

            if normalizedUsedSeconds < previousUsedSeconds {
                persistedState.accountedUsageByKey[accountedKey] = normalizedUsedSeconds
                continue
            }

            let deltaUsedSeconds = normalizedUsedSeconds - previousUsedSeconds
            guard deltaUsedSeconds > 0 else { continue }

            persistedState.accountedUsageByKey[accountedKey] = normalizedUsedSeconds
            items.append(PendingBatchItem(
                packageName: packageName,
                appName: normalizedAppName(entry.appName),
                usedSeconds: deltaUsedSeconds,
                totalUsedSeconds: normalizedUsedSeconds
            ))
        }

        guard !items.isEmpty else { return nil }

        pruneAccountedUsage(keepingDSN: dsn, dayKey: dayKey)

        return PendingBatch(
            id: UUID().uuidString,
            dsn: dsn,
            dayKey: dayKey,
            items: items,
            createdAt: snapshot.generatedAt
        )
    }

    private func payloadSummary(for batch: PendingBatch) -> String {
        let totalDeltaSeconds = batch.items.reduce(into: 0) { result, item in
            result += max(0, item.usedSeconds)
        }
        return "\(batch.items.count) apps, \(totalDeltaSeconds)s delta"
    }

    private func responseSummary(_ response: DeviceApplicationUsageReportResponse) -> String {
        let reachedCount = response.stats.reduce(into: 0) { result, stat in
            if stat.isLimitReached {
                result += 1
            }
        }
        return "\(response.stats.count) stats, \(response.lockedPackages.count) locked, \(reachedCount) reached"
    }

    private func endpoint(for dsn: String) -> String {
        "\(AppConfig.oilaAPIBaseURL.absoluteString)/device/apps/usage"
    }

    private func scheduleRetry() {
        guard currentDSN != nil else { return }

        let delay = nextRetryDelay
        nextRetryDelay = min(nextRetryDelay * 2, maxRetryDelay)
        retryTask?.cancel()
        retryTask = retryScheduler(delay) { [weak self] in
            await self?.handleRetry()
        }
    }

    private func handleRetry() async {
        retryTask = nil
        await processQueueIfPossible(force: true)
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        nextRetryDelay = initialRetryDelay
    }

    private func updateDiagnostics(
        status: String? = nil,
        dsn: String? = nil,
        endpoint: String? = nil,
        queuedBatchCount: Int? = nil,
        lastPayload: String? = nil,
        lastResponse: String? = nil,
        lastUploadAt: Date? = nil,
        lastError: String? = nil
    ) {
        diagnosticsUpdater(
            status,
            dsn,
            endpoint,
            queuedBatchCount,
            lastPayload,
            lastResponse,
            lastUploadAt,
            lastError
        )
    }

    private func persistState() {
        Self.storeState(persistedState, userDefaults: userDefaults, storageKey: Self.storageKey)
    }

    private func usageKey(dsn: String, dayKey: String, packageName: String) -> String {
        "\(dsn.lowercased())|\(dayKey)|\(packageName)"
    }

    private func pruneAccountedUsage(keepingDSN: String, dayKey: String) {
        let protectedPrefix = "\(keepingDSN.lowercased())|\(dayKey)|"
        persistedState.accountedUsageByKey = persistedState.accountedUsageByKey.filter { key, _ in
            key.hasPrefix(protectedPrefix)
                || persistedState.pendingBatches.contains(where: { batch in
                    let batchPrefix = "\(batch.dsn.lowercased())|\(batch.dayKey)|"
                    return key.hasPrefix(batchPrefix)
                })
        }
    }

    private func normalizedDSN(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func normalizedDayKey(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func normalizedIdentifier(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    private func normalizedAppName(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? ProductFallbackText.appName()
    }

    private let service: DeviceApplicationUsageReportServicing
    private let userDefaults: UserDefaults
    private let initialRetryDelay: TimeInterval
    private let maxRetryDelay: TimeInterval
    private let responseHandler: ResponseHandler
    private let diagnosticsUpdater: DiagnosticsUpdater
    private let retryScheduler: RetryScheduler
    private var currentDSN: String?
    private var persistedState: PersistedState
    private var retryTask: Task<Void, Never>?
    private var nextRetryDelay: TimeInterval
    private var isProcessing = false

    private static let storageKey = "DEVICE_APPLICATION_USAGE_REPORT_STATE"
    private let endpointPlaceholder = "-"
    /// Cap on the offline backlog. Beyond this the oldest (least useful) batches are dropped.
    private let maxPendingBatches = 500

    /// A batch the server rejects with a non-auth 4xx will never succeed on retry, so it should be
    /// dropped rather than retried forever. 401 (auth), 408/425 (timeout) and 429 (rate limit) are
    /// transient and stay queued; 5xx and network errors are transient too.
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
}

private extension DeviceApplicationUsageReportCoordinator {
    private static func loadState(userDefaults: UserDefaults, storageKey: String) -> PersistedState {
        guard let data = userDefaults.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return PersistedState()
        }
        return state
    }

    private static func storeState(_ state: PersistedState, userDefaults: UserDefaults, storageKey: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    static func defaultResponseHandler(
        dsn: String,
        response: DeviceApplicationUsageReportResponse
    ) async {
        await MainActor.run {
            DeviceAppLimitMonitorController.shared.applyUsageReportResponse(response, dsn: dsn)
        }
    }

    static func defaultDiagnosticsUpdater(
        status: String?,
        dsn: String?,
        endpoint: String?,
        queuedBatchCount: Int?,
        lastPayload: String?,
        lastResponse: String?,
        lastUploadAt: Date?,
        lastError: String?
    ) {
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updateAppLimitsUsage(
                status: status,
                dsn: dsn,
                endpoint: endpoint,
                queuedBatchCount: queuedBatchCount,
                lastPayload: lastPayload,
                lastResponse: lastResponse,
                lastUploadAt: lastUploadAt,
                lastError: lastError
            )
        }
    }

    static func defaultRetryScheduler(
        delay: TimeInterval,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await operation()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

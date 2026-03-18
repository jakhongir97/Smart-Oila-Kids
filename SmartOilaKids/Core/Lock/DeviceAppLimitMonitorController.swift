import Combine
import DeviceActivity
import Foundation
import ManagedSettings

struct DeviceAppLimitPresentationItem: Identifiable, Equatable {
    let packageName: String
    let appName: String
    let dailyLimitMinutes: Int
    let usedTodaySeconds: Int
    let remainingTodaySeconds: Int
    let isLimitReached: Bool

    var id: String { packageName }
}

struct DeviceAppLimitPresentationState: Equatable {
    var status: String = "idle"
    var dsn: String = "-"
    var endpoint: String = "-"
    var remoteLimitCount: Int = 0
    var matchedLimitCount: Int = 0
    var reachedLimitCount: Int = 0
    var items: [DeviceAppLimitPresentationItem] = []
    var lastError: String = "-"

    var unmatchedLimitCount: Int {
        max(0, remoteLimitCount - matchedLimitCount)
    }
}

@MainActor
final class DeviceAppLimitMonitorController: ObservableObject {
    typealias AuthorizationStatusAction = () -> ScreenTimePermissionStatus
    typealias UsedTimeAction = (_ packageName: String, _ dsn: String?) -> Int
    typealias MatchedConfigurationsAction = (_ limits: [DeviceAppLimitResponse]) -> [DeviceAppLimitConfiguration]
    typealias MonitorStartAction = (_ dsn: String, _ configurations: [DeviceAppLimitConfiguration]) throws -> Void
    typealias MonitorStopAction = (_ activityName: DeviceActivityName) -> Void
    typealias SnapshotAction = (_ snapshot: DeviceAppLimitSnapshot) -> Void

    static let shared = DeviceAppLimitMonitorController()

    @Published private(set) var presentationState = DeviceAppLimitPresentationState()

    init(
        service: DeviceAppLimitServicing = DeviceAppLimitService(),
        selectionStore: DeviceAppLockSelectionStore? = nil,
        sharedStore: DeviceAppLimitSharedStore = DeviceAppLimitSharedStore(),
        authorizationStatus: AuthorizationStatusAction? = nil,
        usedTime: UsedTimeAction? = nil,
        matchedConfigurationsFromLimits: MatchedConfigurationsAction? = nil,
        startMonitoring: MonitorStartAction? = nil,
        stopMonitoring: MonitorStopAction? = nil,
        applyShield: SnapshotAction? = nil,
        clearShield: (() -> Void)? = nil,
        reportRecovery: SnapshotAction? = nil
    ) {
        let resolvedSelectionStore = selectionStore ?? .shared
        let activityCenter = DeviceActivityCenter()
        let limitStore = DeviceLockManagedSettingsStoreFactory.make(
            named: DeviceLockManagedSettingsStoreName.limit
        )

        self.service = service
        self.selectionStore = resolvedSelectionStore
        self.sharedStore = sharedStore
        self.authorizationStatus = authorizationStatus ?? {
            Self.defaultAuthorizationStatus()
        }
        self.usedTime = usedTime ?? { packageName, dsn in
            Self.defaultUsedTime(for: packageName, dsn: dsn)
        }
        self.matchedConfigurationsFromLimits = matchedConfigurationsFromLimits ?? { limits in
            Self.defaultMatchedConfigurations(from: limits, selectionStore: resolvedSelectionStore)
        }
        self.startMonitoring = startMonitoring ?? { dsn, configurations in
            try activityCenter.startMonitoring(
                DeviceActivityName(DeviceAppLimitActivityIdentifier.rawValue(dsn: dsn)),
                during: Self.makeDailySchedule(),
                events: Self.defaultMonitoringEvents(for: configurations)
            )
        }
        self.stopMonitoring = stopMonitoring ?? { activityName in
            activityCenter.stopMonitoring([activityName])
        }
        self.applyShield = applyShield ?? { snapshot in
            Self.defaultApplyLimitShield(using: snapshot, store: limitStore)
        }
        self.clearShield = clearShield ?? {
            DeviceLockManagedSettingsStoreFactory.clearAllSettings(limitStore)
        }
        self.reportRecovery = reportRecovery ?? { snapshot in
            Self.defaultReportRecovery(using: snapshot)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .deviceAppLockConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSelectionChange()
            }
        }
        usageSnapshotObserver = NotificationCenter.default.addObserver(
            forName: .screenTimeUsageSnapshotDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleUsageSnapshotDidChange(notification)
            }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        if let usageSnapshotObserver {
            NotificationCenter.default.removeObserver(usageSnapshotObserver)
        }
    }

    func activate(dsn: String?) {
        let normalizedDSN = normalizedDSN(dsn)
        guard normalizedDSN != currentDSN else {
            if normalizedDSN != nil && latestFetchResult == nil {
                Task { [weak self] in
                    await self?.refreshNow()
                }
            }
            return
        }

        stopCurrentMonitoring()
        currentDSN = normalizedDSN
        latestFetchResult = nil

        guard let normalizedDSN else {
            publishState(
                status: "idle",
                dsn: "-",
                endpoint: "-",
                remoteLimits: [],
                items: [],
                lastError: "-"
            )
            updateDiagnostics(
                status: "idle",
                dsn: "-",
                endpoint: "-",
                remoteCount: 0,
                matchedCount: 0,
                reachedCount: 0,
                lastPayload: "-",
                lastError: "-"
            )
            return
        }

        if let snapshot = sharedStore.loadSnapshot(dsn: normalizedDSN) {
            applyLimitShield(using: snapshot)
            publishState(
                status: "cached",
                dsn: normalizedDSN,
                endpoint: latestFetchResult?.endpoint ?? "-",
                remoteLimits: snapshot.configurations.map { configuration in
                    DeviceAppLimitResponse(
                        packageName: configuration.packageName,
                        dailyLimitMinutes: configuration.dailyLimitMinutes,
                        isLimitEnabled: true,
                        usedTodaySeconds: usedTime(configuration.packageName, normalizedDSN),
                        remainingTodaySeconds: max(
                            0,
                            (configuration.dailyLimitMinutes * 60) - usedTime(configuration.packageName, normalizedDSN)
                        ),
                        isLimitReached: snapshot.reachedPackageNames.contains(configuration.packageName)
                    )
                },
                items: makePresentationItems(
                    configurations: snapshot.configurations,
                    responses: nil,
                    reachedIdentifiers: Set(snapshot.reachedPackageNames),
                    dsn: normalizedDSN
                ),
                lastError: "-"
            )
            updateDiagnostics(
                status: "cached",
                dsn: normalizedDSN,
                endpoint: latestFetchResult?.endpoint ?? "-",
                remoteCount: snapshot.configurations.count,
                matchedCount: snapshot.configurations.count,
                reachedCount: snapshot.reachedPackageNames.count,
                lastPayload: payloadSummary(
                    remoteCount: snapshot.configurations.count,
                    enabledCount: snapshot.configurations.count,
                    matchedCount: snapshot.configurations.count,
                    reachedCount: snapshot.reachedPackageNames.count
                ),
                lastError: "-"
            )
        }

        Task { [weak self] in
            await self?.refreshNow()
        }
    }

    func stop() {
        let previousDSN = currentDSN
        stopCurrentMonitoring()
        if let previousDSN {
            sharedStore.clearSnapshot(dsn: previousDSN)
        }
        currentDSN = nil
        latestFetchResult = nil
        publishState(
            status: "idle",
            dsn: "-",
            endpoint: "-",
            remoteLimits: [],
            items: [],
            lastError: "-"
        )
        updateDiagnostics(
            status: "idle",
            dsn: "-",
            endpoint: "-",
            remoteCount: 0,
            matchedCount: 0,
            reachedCount: 0,
            lastPayload: "-",
            lastError: "-"
        )
    }

    func refreshNow() async {
        guard let currentDSN else { return }

        let authorizationStatus = authorizationStatus()
        guard authorizationStatus == .granted else {
            stopCurrentMonitoring()
            publishState(
                status: authorizationStatus == .unavailable ? "unavailable" : "not_authorized",
                dsn: currentDSN,
                endpoint: latestFetchResult?.endpoint ?? "-",
                remoteLimits: latestFetchResult?.limits.filter { $0.isLimitEnabled && $0.dailyLimitMinutes > 0 } ?? [],
                items: [],
                lastError: "-"
            )
            updateDiagnostics(
                status: authorizationStatus == .unavailable ? "unavailable" : "not_authorized",
                dsn: currentDSN,
                endpoint: latestFetchResult?.endpoint ?? "-",
                remoteCount: latestFetchResult?.limits.count ?? 0,
                matchedCount: matchedCount(from: latestFetchResult?.limits ?? []),
                reachedCount: sharedStore.loadSnapshot(dsn: currentDSN)?.reachedPackageNames.count ?? 0,
                lastPayload: latestFetchResult.map(payloadSummary(from:)) ?? "-",
                lastError: "-"
            )
            return
        }

        do {
            let result = try await service.fetchLimits(dsn: currentDSN)
            guard isCurrent(dsn: currentDSN) else { return }
            latestFetchResult = result
            try applyConfiguration(result, dsn: currentDSN)
        } catch {
            guard isCurrent(dsn: currentDSN) else { return }
            let snapshot = sharedStore.loadSnapshot(dsn: currentDSN)
            publishState(
                status: "failed",
                dsn: currentDSN,
                endpoint: latestFetchResult?.endpoint ?? "-",
                remoteLimits: latestFetchResult?.limits.filter { $0.isLimitEnabled && $0.dailyLimitMinutes > 0 } ?? [],
                items: snapshot.map {
                    makePresentationItems(
                        configurations: $0.configurations,
                        responses: latestFetchResult?.limits,
                        reachedIdentifiers: Set($0.reachedPackageNames),
                        dsn: currentDSN
                    )
                } ?? [],
                lastError: error.localizedDescription
            )
            updateDiagnostics(
                status: "failed",
                dsn: currentDSN,
                endpoint: latestFetchResult?.endpoint ?? "-",
                remoteCount: latestFetchResult?.limits.count ?? 0,
                matchedCount: matchedCount(from: latestFetchResult?.limits ?? []),
                reachedCount: snapshot?.reachedPackageNames.count ?? 0,
                lastPayload: latestFetchResult.map(payloadSummary(from:)) ?? "-",
                lastError: error.localizedDescription
            )
        }
    }

    func armForegroundRecoveryCheck() {
        pendingForegroundRecoveryCheck = true
    }

    func applyUsageReportResponse(_ response: DeviceApplicationUsageReportResponse, dsn: String) {
        guard isCurrent(dsn: dsn) else { return }

        let normalizedLockedPackages = Set(response.lockedPackages.compactMap(normalizedIdentifier(_:)))
        let reportedLimits = response.stats.compactMap { stat -> DeviceAppLimitResponse? in
            guard let packageName = normalizedIdentifier(stat.packageName) else {
                return nil
            }

            let normalizedUsedSeconds = max(0, stat.usedSeconds)
            let normalizedDailyLimitSeconds = max(0, stat.dailyLimitSeconds ?? 0)
            let normalizedRemainingSeconds = max(
                0,
                stat.remainingSeconds ?? max(0, normalizedDailyLimitSeconds - normalizedUsedSeconds)
            )

            return DeviceAppLimitResponse(
                packageName: packageName,
                dailyLimitMinutes: normalizedDailyLimitSeconds > 0
                    ? max(1, Int(ceil(Double(normalizedDailyLimitSeconds) / 60.0)))
                    : 0,
                isLimitEnabled: normalizedDailyLimitSeconds > 0,
                usedTodaySeconds: normalizedUsedSeconds,
                remainingTodaySeconds: normalizedRemainingSeconds,
                isLimitReached: stat.isLimitReached || normalizedLockedPackages.contains(packageName)
            )
        }

        let reportedLimitByPackage = Dictionary(
            uniqueKeysWithValues: reportedLimits.compactMap { limit -> (String, DeviceAppLimitResponse)? in
                guard let packageName = normalizedIdentifier(limit.packageName) else {
                    return nil
                }
                return (packageName, limit)
            }
        )

        var mergedLimits = latestFetchResult?.limits ?? []
        var mergedIdentifiers = Set<String>()

        if !mergedLimits.isEmpty {
            mergedLimits = mergedLimits.map { limit in
                guard let packageName = normalizedIdentifier(limit.packageName),
                      let reported = reportedLimitByPackage[packageName] else {
                    return limit
                }

                mergedIdentifiers.insert(packageName)
                return reported
            }
        }

        for reportedLimit in reportedLimits {
            guard let packageName = normalizedIdentifier(reportedLimit.packageName),
                  !mergedIdentifiers.contains(packageName) else {
                continue
            }
            mergedLimits.append(reportedLimit)
        }

        let mergedResult = DeviceAppLimitFetchResult(
            deviceID: latestFetchResult?.deviceID ?? 0,
            endpoint: latestFetchResult?.endpoint ?? "devices/\(dsn)/applications/usage",
            limits: mergedLimits.sorted { lhs, rhs in
                lhs.packageName.localizedCaseInsensitiveCompare(rhs.packageName) == .orderedAscending
            }
        )

        latestFetchResult = mergedResult

        do {
            try applyConfiguration(mergedResult, dsn: dsn)
        } catch {
            publishState(
                status: "failed",
                dsn: dsn,
                endpoint: mergedResult.endpoint,
                remoteLimits: mergedResult.limits.filter { $0.isLimitEnabled && $0.dailyLimitMinutes > 0 },
                items: sharedStore.loadSnapshot(dsn: dsn).map {
                    makePresentationItems(
                        configurations: $0.configurations,
                        responses: mergedResult.limits,
                        reachedIdentifiers: Set($0.reachedPackageNames),
                        dsn: dsn
                    )
                } ?? [],
                lastError: error.localizedDescription
            )
            updateDiagnostics(
                status: "failed",
                dsn: dsn,
                endpoint: mergedResult.endpoint,
                remoteCount: mergedResult.limits.count,
                matchedCount: matchedCount(from: mergedResult.limits),
                reachedCount: sharedStore.loadSnapshot(dsn: dsn)?.reachedPackageNames.count ?? 0,
                lastPayload: payloadSummary(from: mergedResult),
                lastError: error.localizedDescription
            )
        }
    }

    private let service: DeviceAppLimitServicing
    private let selectionStore: DeviceAppLockSelectionStore
    private let sharedStore: DeviceAppLimitSharedStore
    private let authorizationStatus: AuthorizationStatusAction
    private let usedTime: UsedTimeAction
    private let matchedConfigurationsFromLimits: MatchedConfigurationsAction
    private let startMonitoring: MonitorStartAction
    private let stopMonitoring: MonitorStopAction
    private let applyShield: SnapshotAction
    private let clearShield: () -> Void
    private let reportRecovery: SnapshotAction

    private var currentDSN: String?
    private var latestFetchResult: DeviceAppLimitFetchResult?
    private var currentActivityName: DeviceActivityName?
    private var currentSignature: String?
    private var pendingForegroundRecoveryCheck = false
    private var configurationObserver: NSObjectProtocol?
    private var usageSnapshotObserver: NSObjectProtocol?
}

private extension DeviceAppLimitMonitorController {
    func handleUsageSnapshotDidChange(_ notification: Notification) {
        guard let currentDSN,
              let changedDSN = (notification.userInfo?[ScreenTimeUsageSnapshotUserInfoKey.dsn] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              changedDSN.caseInsensitiveCompare(currentDSN) == .orderedSame else {
            return
        }

        if let latestFetchResult {
            try? applyConfiguration(latestFetchResult, dsn: currentDSN)
            return
        }

        guard let snapshot = sharedStore.loadSnapshot(dsn: currentDSN) else { return }
        applyLimitShield(using: snapshot)
        publishState(
            status: presentationState.status == "idle" ? "cached" : presentationState.status,
            dsn: currentDSN,
            endpoint: presentationState.endpoint,
            remoteLimits: snapshot.configurations.map { configuration in
                let usedTodaySeconds = usedTime(configuration.packageName, currentDSN)
                return DeviceAppLimitResponse(
                    packageName: configuration.packageName,
                    dailyLimitMinutes: configuration.dailyLimitMinutes,
                    isLimitEnabled: true,
                    usedTodaySeconds: usedTodaySeconds,
                    remainingTodaySeconds: max(0, (configuration.dailyLimitMinutes * 60) - usedTodaySeconds),
                    isLimitReached: snapshot.reachedPackageNames.contains(configuration.packageName)
                )
            },
            items: makePresentationItems(
                configurations: snapshot.configurations,
                responses: nil,
                reachedIdentifiers: Set(snapshot.reachedPackageNames),
                dsn: currentDSN
            ),
            lastError: presentationState.lastError
        )
    }

    func handleSelectionChange() {
        guard let currentDSN else { return }

        guard authorizationStatus() == .granted else {
            stopCurrentMonitoring()
            publishState(
                status: "not_authorized",
                dsn: currentDSN,
                endpoint: latestFetchResult?.endpoint ?? "-",
                remoteLimits: latestFetchResult?.limits.filter { $0.isLimitEnabled && $0.dailyLimitMinutes > 0 } ?? [],
                items: [],
                lastError: "-"
            )
            updateDiagnostics(
                status: "not_authorized",
                dsn: currentDSN,
                endpoint: latestFetchResult?.endpoint ?? "-",
                remoteCount: latestFetchResult?.limits.count ?? 0,
                matchedCount: 0,
                reachedCount: 0,
                lastPayload: latestFetchResult.map(payloadSummary(from:)) ?? "-",
                lastError: "-"
            )
            return
        }

        guard let latestFetchResult else {
            Task { [weak self] in
                await self?.refreshNow()
            }
            return
        }

        do {
            try applyConfiguration(latestFetchResult, dsn: currentDSN)
        } catch {
            publishState(
                status: "failed",
                dsn: currentDSN,
                endpoint: latestFetchResult.endpoint,
                remoteLimits: latestFetchResult.limits.filter { $0.isLimitEnabled && $0.dailyLimitMinutes > 0 },
                items: sharedStore.loadSnapshot(dsn: currentDSN).map {
                    makePresentationItems(
                        configurations: $0.configurations,
                        responses: latestFetchResult.limits,
                        reachedIdentifiers: Set($0.reachedPackageNames),
                        dsn: currentDSN
                    )
                } ?? [],
                lastError: error.localizedDescription
            )
            updateDiagnostics(
                status: "failed",
                dsn: currentDSN,
                endpoint: latestFetchResult.endpoint,
                remoteCount: latestFetchResult.limits.count,
                matchedCount: matchedCount(from: latestFetchResult.limits),
                reachedCount: sharedStore.loadSnapshot(dsn: currentDSN)?.reachedPackageNames.count ?? 0,
                lastPayload: payloadSummary(from: latestFetchResult),
                lastError: error.localizedDescription
            )
        }
    }

    func applyConfiguration(_ result: DeviceAppLimitFetchResult, dsn: String) throws {
        guard sharedStore.isAvailable else {
            stopCurrentMonitoring()
            updateDiagnostics(
                status: "app_group_unavailable",
                dsn: dsn,
                endpoint: result.endpoint,
                remoteCount: result.limits.count,
                matchedCount: 0,
                reachedCount: 0,
                lastPayload: payloadSummary(from: result),
                lastError: DeviceAppLimitSharedStoreError.appGroupUnavailable.localizedDescription
            )
            return
        }

        let enabledLimits = result.limits.filter { $0.isLimitEnabled && $0.dailyLimitMinutes > 0 }
        guard !enabledLimits.isEmpty else {
            stopCurrentMonitoring()
            sharedStore.clearSnapshot(dsn: dsn)
            publishState(
                status: "no_limits",
                dsn: dsn,
                endpoint: result.endpoint,
                remoteLimits: [],
                items: [],
                lastError: "-"
            )
            updateDiagnostics(
                status: "no_limits",
                dsn: dsn,
                endpoint: result.endpoint,
                remoteCount: result.limits.count,
                matchedCount: 0,
                reachedCount: 0,
                lastPayload: payloadSummary(from: result),
                lastError: "-"
            )
            return
        }

        let configurations = matchedConfigurations(from: enabledLimits)
        guard !configurations.isEmpty else {
            stopCurrentMonitoring()
            sharedStore.clearSnapshot(dsn: dsn)
            publishState(
                status: "no_matches",
                dsn: dsn,
                endpoint: result.endpoint,
                remoteLimits: enabledLimits,
                items: [],
                lastError: "-"
            )
            updateDiagnostics(
                status: "no_matches",
                dsn: dsn,
                endpoint: result.endpoint,
                remoteCount: result.limits.count,
                matchedCount: 0,
                reachedCount: 0,
                lastPayload: payloadSummary(from: result),
                lastError: "-"
            )
            return
        }

        let existingReachedIdentifiers = Set(
            sharedStore
                .loadSnapshot(dsn: dsn)?
                .reachedPackageNames
                .compactMap(normalizedIdentifier(_:)) ?? []
        )
        let remoteReachedIdentifiers = Set(
            enabledLimits
                .filter(\.isLimitReached)
                .compactMap { normalizedIdentifier($0.packageName) }
        )
        let localReachedIdentifiers = Set(
            enabledLimits.compactMap { limit -> String? in
                guard let packageName = normalizedIdentifier(limit.packageName) else {
                    return nil
                }
                let usedTodaySeconds = usedTime(packageName, dsn)
                return usedTodaySeconds >= (max(1, min(limit.dailyLimitMinutes, 1440)) * 60)
                    ? packageName
                    : nil
            }
        )
        let matchedIdentifiers = Set(configurations.map(\.packageName))
        let reachedIdentifiers = existingReachedIdentifiers
            .union(remoteReachedIdentifiers)
            .union(localReachedIdentifiers)
            .intersection(matchedIdentifiers)

        let snapshot = DeviceAppLimitSnapshot(
            dsn: dsn,
            configurations: configurations,
            reachedPackageNames: Array(reachedIdentifiers).sorted(),
            generatedAt: Date()
        )

        try sharedStore.saveSnapshot(snapshot)
        applyLimitShield(using: snapshot)
        reportRecoveryIfNeeded(using: snapshot)

        let signature = monitoringSignature(for: snapshot)
        if signature != currentSignature || currentActivityName == nil {
            stopCurrentMonitoring()
            do {
                let activityName = DeviceActivityName(DeviceAppLimitActivityIdentifier.rawValue(dsn: dsn))
                try startMonitoring(dsn, snapshot.configurations)
                currentActivityName = activityName
                currentSignature = signature
            } catch {
                stopCurrentMonitoring()
                publishState(
                    status: "failed",
                    dsn: dsn,
                    endpoint: result.endpoint,
                    remoteLimits: enabledLimits,
                    items: makePresentationItems(
                        configurations: configurations,
                        responses: enabledLimits,
                        reachedIdentifiers: reachedIdentifiers,
                        dsn: dsn
                    ),
                    lastError: error.localizedDescription
                )
                updateDiagnostics(
                    status: "failed",
                    dsn: dsn,
                    endpoint: result.endpoint,
                    remoteCount: result.limits.count,
                    matchedCount: configurations.count,
                    reachedCount: reachedIdentifiers.count,
                    lastPayload: payloadSummary(
                        remoteCount: result.limits.count,
                        enabledCount: enabledLimits.count,
                        matchedCount: configurations.count,
                        reachedCount: reachedIdentifiers.count
                    ),
                    lastError: error.localizedDescription
                )
                throw error
            }
        }

        publishState(
            status: "monitoring",
            dsn: dsn,
            endpoint: result.endpoint,
            remoteLimits: enabledLimits,
            items: makePresentationItems(
                configurations: configurations,
                responses: enabledLimits,
                reachedIdentifiers: reachedIdentifiers,
                dsn: dsn
            ),
            lastError: "-"
        )
        updateDiagnostics(
            status: "monitoring",
            dsn: dsn,
            endpoint: result.endpoint,
            remoteCount: result.limits.count,
            matchedCount: configurations.count,
            reachedCount: reachedIdentifiers.count,
            lastPayload: payloadSummary(
                remoteCount: result.limits.count,
                enabledCount: enabledLimits.count,
                matchedCount: configurations.count,
                reachedCount: reachedIdentifiers.count
            ),
            lastError: "-"
        )
    }

    func stopCurrentMonitoring() {
        if let currentActivityName {
            stopMonitoring(currentActivityName)
        }
        currentActivityName = nil
        currentSignature = nil
        pendingForegroundRecoveryCheck = false
        clearShield()
    }

    func matchedConfigurations(from limits: [DeviceAppLimitResponse]) -> [DeviceAppLimitConfiguration] {
        matchedConfigurationsFromLimits(limits)
    }

    func monitoringEvents(
        for configurations: [DeviceAppLimitConfiguration]
    ) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        Self.defaultMonitoringEvents(for: configurations)
    }

    func thresholdComponents(for minutes: Int) -> DateComponents {
        Self.defaultThresholdComponents(for: minutes)
    }

    func monitoringSignature(for snapshot: DeviceAppLimitSnapshot) -> String {
        let configs = snapshot.configurations.map { configuration in
            "\(configuration.packageName):\(configuration.dailyLimitMinutes)"
        }.joined(separator: ",")
        let reached = snapshot.reachedPackageNames.joined(separator: ",")
        return "\(snapshot.dsn)|\(configs)|\(reached)"
    }

    func reportRecoveryIfNeeded(using snapshot: DeviceAppLimitSnapshot) {
        guard pendingForegroundRecoveryCheck else { return }
        pendingForegroundRecoveryCheck = false
        reportRecovery(snapshot)
    }

    func applyLimitShield(using snapshot: DeviceAppLimitSnapshot) {
        applyShield(snapshot)
    }

    func matchedCount(from limits: [DeviceAppLimitResponse]) -> Int {
        matchedConfigurations(from: limits.filter { $0.isLimitEnabled && $0.dailyLimitMinutes > 0 }).count
    }

    func makePresentationItems(
        configurations: [DeviceAppLimitConfiguration],
        responses: [DeviceAppLimitResponse]?,
        reachedIdentifiers: Set<String>,
        dsn: String?
    ) -> [DeviceAppLimitPresentationItem] {
        let responseByPackage = Dictionary(
            uniqueKeysWithValues: (responses ?? []).compactMap { response -> (String, DeviceAppLimitResponse)? in
                guard let packageName = normalizedIdentifier(response.packageName) else {
                    return nil
                }
                return (packageName, response)
            }
        )

        let normalizedReachedIdentifiers = Set(reachedIdentifiers.compactMap(normalizedIdentifier(_:)))

        return configurations.map { configuration in
            let remoteResponse = responseByPackage[configuration.packageName]
            let limitSeconds = configuration.dailyLimitMinutes * 60
            let localUsedSeconds = usedTime(configuration.packageName, dsn)
            let usedTodaySeconds = max(remoteResponse?.usedTodaySeconds ?? 0, localUsedSeconds)
            let isLimitReached = normalizedReachedIdentifiers.contains(configuration.packageName)
                || (remoteResponse?.isLimitReached ?? false)
                || usedTodaySeconds >= limitSeconds
            let remainingTodaySeconds = max(0, limitSeconds - usedTodaySeconds)

            return DeviceAppLimitPresentationItem(
                packageName: configuration.packageName,
                appName: configuration.appName,
                dailyLimitMinutes: configuration.dailyLimitMinutes,
                usedTodaySeconds: usedTodaySeconds,
                remainingTodaySeconds: remainingTodaySeconds,
                isLimitReached: isLimitReached
            )
        }
        .sorted { lhs, rhs in
            if lhs.isLimitReached != rhs.isLimitReached {
                return lhs.isLimitReached && !rhs.isLimitReached
            }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    func publishState(
        status: String,
        dsn: String,
        endpoint: String,
        remoteLimits: [DeviceAppLimitResponse],
        items: [DeviceAppLimitPresentationItem],
        lastError: String
    ) {
        presentationState = DeviceAppLimitPresentationState(
            status: status,
            dsn: dsn,
            endpoint: endpoint,
            remoteLimitCount: remoteLimits.count,
            matchedLimitCount: items.count,
            reachedLimitCount: items.filter(\.isLimitReached).count,
            items: items,
            lastError: lastError
        )
    }

    func payloadSummary(from result: DeviceAppLimitFetchResult) -> String {
        let enabledCount = result.limits.filter { $0.isLimitEnabled && $0.dailyLimitMinutes > 0 }.count
        return payloadSummary(
            remoteCount: result.limits.count,
            enabledCount: enabledCount,
            matchedCount: matchedCount(from: result.limits),
            reachedCount: sharedStore.loadSnapshot(dsn: currentDSN ?? "")?.reachedPackageNames.count ?? 0
        )
    }

    func payloadSummary(
        remoteCount: Int,
        enabledCount: Int,
        matchedCount: Int,
        reachedCount: Int
    ) -> String {
        "\(remoteCount) remote, \(enabledCount) enabled, \(matchedCount) matched, \(reachedCount) reached"
    }

    func normalizedDSN(_ value: String?) -> String? {
        Self.defaultNormalizedDSN(value)
    }

    func normalizedIdentifier(_ value: String?) -> String? {
        Self.defaultNormalizedIdentifier(value)
    }

    func isCurrent(dsn: String) -> Bool {
        guard let currentDSN else { return false }
        return currentDSN.caseInsensitiveCompare(dsn) == .orderedSame
    }

    func updateDiagnostics(
        status: String? = nil,
        dsn: String? = nil,
        endpoint: String? = nil,
        remoteCount: Int? = nil,
        matchedCount: Int? = nil,
        reachedCount: Int? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil
    ) {
        RuntimeDiagnosticsCenter.shared.updateAppLimits(
            status: status,
            dsn: dsn,
            endpoint: endpoint,
            remoteCount: remoteCount,
            matchedCount: matchedCount,
            reachedCount: reachedCount,
            lastPayload: lastPayload,
            lastError: lastError
        )
    }
}

private extension DeviceAppLimitMonitorController {
    static func defaultAuthorizationStatus() -> ScreenTimePermissionStatus {
        ScreenTimeAuthorizationManager.shared.refreshStatus()
        return ScreenTimeAuthorizationManager.shared.status
    }

    static func defaultUsedTime(for packageName: String, dsn: String?) -> Int {
        ScreenTimeUsageCoordinator.shared.usedTime(for: packageName, dsn: dsn)
    }

    static func defaultMatchedConfigurations(
        from limits: [DeviceAppLimitResponse],
        selectionStore: DeviceAppLockSelectionStore
    ) -> [DeviceAppLimitConfiguration] {
        let selectedApplications = selectionStore.selection.applications.reduce(
            into: [String: ManagedSettings.Application]()
        ) { result, application in
            guard let packageName = defaultNormalizedIdentifier(application.bundleIdentifier) else { return }
            result[packageName] = application
        }

        return limits.compactMap { limit in
            guard let packageName = defaultNormalizedIdentifier(limit.packageName),
                  let application = selectedApplications[packageName],
                  let applicationToken = application.token else {
                return nil
            }

            return DeviceAppLimitConfiguration(
                packageName: packageName,
                appName: application.localizedDisplayName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                    ?? ProductFallbackText.appName(),
                applicationToken: applicationToken,
                dailyLimitMinutes: max(1, min(limit.dailyLimitMinutes, 1440))
            )
        }
        .sorted { lhs, rhs in
            lhs.packageName.localizedCaseInsensitiveCompare(rhs.packageName) == .orderedAscending
        }
    }

    static func makeDailySchedule() -> DeviceActivitySchedule {
        DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
            repeats: true
        )
    }

    static func defaultMonitoringEvents(
        for configurations: [DeviceAppLimitConfiguration]
    ) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        configurations.reduce(into: [DeviceActivityEvent.Name: DeviceActivityEvent]()) { result, configuration in
            let name = DeviceActivityEvent.Name(
                DeviceAppLimitEventIdentifier.rawValue(packageName: configuration.packageName)
            )
            result[name] = DeviceActivityEvent(
                applications: [configuration.applicationToken],
                threshold: defaultThresholdComponents(for: configuration.dailyLimitMinutes)
            )
        }
    }

    static func defaultThresholdComponents(for minutes: Int) -> DateComponents {
        let normalizedMinutes = max(1, min(minutes, 1440))
        if normalizedMinutes == 1440 {
            return DateComponents(day: 1)
        }
        return DateComponents(
            hour: normalizedMinutes / 60,
            minute: normalizedMinutes % 60
        )
    }

    static func defaultReportRecovery(using snapshot: DeviceAppLimitSnapshot) {
        let reachedIdentifiers = snapshot.reachedPackageNames.compactMap(defaultNormalizedIdentifier(_:))
        guard !reachedIdentifiers.isEmpty else { return }

        let singledOutConfiguration = snapshot.configurations.first { configuration in
            reachedIdentifiers.count == 1 && reachedIdentifiers.contains(configuration.packageName)
        }

        Task {
            await DeviceControlRecoveryNotifier.shared.recordAppLimitRestored(
                dsn: snapshot.dsn,
                packageName: singledOutConfiguration?.packageName,
                appName: singledOutConfiguration?.appName
            )
        }
    }

    static func defaultApplyLimitShield(
        using snapshot: DeviceAppLimitSnapshot,
        store: ManagedSettingsStore
    ) {
        let reachedIdentifiers = Set(snapshot.reachedPackageNames)
        let tokens = snapshot.configurations.compactMap { configuration -> ApplicationToken? in
            reachedIdentifiers.contains(configuration.packageName) ? configuration.applicationToken : nil
        }

        DeviceLockManagedSettingsStoreFactory.clearAllSettings(store)
        guard !tokens.isEmpty else { return }

        store.shield.applications = Set(tokens)
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
    }

    static func defaultNormalizedDSN(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func defaultNormalizedIdentifier(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

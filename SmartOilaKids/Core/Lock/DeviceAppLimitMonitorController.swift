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
    static let shared = DeviceAppLimitMonitorController()

    @Published private(set) var presentationState = DeviceAppLimitPresentationState()

    init(
        service: DeviceAppLimitServicing = DeviceAppLimitService(),
        selectionStore: DeviceAppLockSelectionStore? = nil,
        sharedStore: DeviceAppLimitSharedStore = DeviceAppLimitSharedStore()
    ) {
        self.service = service
        self.selectionStore = selectionStore ?? .shared
        self.sharedStore = sharedStore
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
                        usedTodaySeconds: ScreenTimeUsageCoordinator.shared.usedTime(
                            for: configuration.packageName,
                            dsn: normalizedDSN
                        ),
                        remainingTodaySeconds: max(
                            0,
                            (configuration.dailyLimitMinutes * 60) - ScreenTimeUsageCoordinator.shared.usedTime(
                                for: configuration.packageName,
                                dsn: normalizedDSN
                            )
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

        ScreenTimeAuthorizationManager.shared.refreshStatus()
        let authorizationStatus = ScreenTimeAuthorizationManager.shared.status
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

    private let service: DeviceAppLimitServicing
    private let selectionStore: DeviceAppLockSelectionStore
    private let sharedStore: DeviceAppLimitSharedStore
    private let activityCenter = DeviceActivityCenter()
    private let limitStore = ManagedSettingsStore(named: .init(DeviceLockManagedSettingsStoreName.limit))
    private let dailySchedule = DeviceActivitySchedule(
        intervalStart: DateComponents(hour: 0, minute: 0),
        intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
        repeats: true
    )

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
                let usedTodaySeconds = ScreenTimeUsageCoordinator.shared.usedTime(
                    for: configuration.packageName,
                    dsn: currentDSN
                )
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

        ScreenTimeAuthorizationManager.shared.refreshStatus()
        guard ScreenTimeAuthorizationManager.shared.status == .granted else {
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
                let usedTodaySeconds = ScreenTimeUsageCoordinator.shared.usedTime(for: packageName, dsn: dsn)
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
                try activityCenter.startMonitoring(
                    DeviceActivityName(DeviceAppLimitActivityIdentifier.rawValue(dsn: dsn)),
                    during: dailySchedule,
                    events: monitoringEvents(for: snapshot.configurations)
                )
                currentActivityName = DeviceActivityName(DeviceAppLimitActivityIdentifier.rawValue(dsn: dsn))
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
            activityCenter.stopMonitoring([currentActivityName])
        }
        currentActivityName = nil
        currentSignature = nil
        pendingForegroundRecoveryCheck = false
        limitStore.clearAllSettings()
    }

    func matchedConfigurations(from limits: [DeviceAppLimitResponse]) -> [DeviceAppLimitConfiguration] {
        let selectedApplications = selectionStore.selection.applications.reduce(into: [String: ManagedSettings.Application]()) {
            result, application in
            guard let packageName = normalizedIdentifier(application.bundleIdentifier) else { return }
            result[packageName] = application
        }

        return limits.compactMap { limit in
            guard let packageName = normalizedIdentifier(limit.packageName),
                  let application = selectedApplications[packageName],
                  let applicationToken = application.token else {
                return nil
            }

            return DeviceAppLimitConfiguration(
                packageName: packageName,
                appName: application.localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? application.bundleIdentifier
                    ?? packageName,
                applicationToken: applicationToken,
                dailyLimitMinutes: max(1, min(limit.dailyLimitMinutes, 1440))
            )
        }
        .sorted { lhs, rhs in
            lhs.packageName.localizedCaseInsensitiveCompare(rhs.packageName) == .orderedAscending
        }
    }

    func monitoringEvents(
        for configurations: [DeviceAppLimitConfiguration]
    ) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        configurations.reduce(into: [DeviceActivityEvent.Name: DeviceActivityEvent]()) { result, configuration in
            let name = DeviceActivityEvent.Name(
                DeviceAppLimitEventIdentifier.rawValue(packageName: configuration.packageName)
            )
            result[name] = DeviceActivityEvent(
                applications: [configuration.applicationToken],
                threshold: thresholdComponents(for: configuration.dailyLimitMinutes)
            )
        }
    }

    func thresholdComponents(for minutes: Int) -> DateComponents {
        let normalizedMinutes = max(1, min(minutes, 1440))
        if normalizedMinutes == 1440 {
            return DateComponents(day: 1)
        }
        return DateComponents(
            hour: normalizedMinutes / 60,
            minute: normalizedMinutes % 60
        )
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

        let reachedIdentifiers = snapshot.reachedPackageNames.compactMap(normalizedIdentifier(_:))
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

    func applyLimitShield(using snapshot: DeviceAppLimitSnapshot) {
        let reachedIdentifiers = Set(snapshot.reachedPackageNames)
        let tokens = snapshot.configurations.compactMap { configuration -> ApplicationToken? in
            reachedIdentifiers.contains(configuration.packageName) ? configuration.applicationToken : nil
        }

        limitStore.clearAllSettings()
        guard !tokens.isEmpty else { return }

        limitStore.shield.applications = Set(tokens)
        limitStore.shield.applicationCategories = nil
        limitStore.shield.webDomains = nil
        limitStore.shield.webDomainCategories = nil
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
            let localUsedSeconds = ScreenTimeUsageCoordinator.shared.usedTime(
                for: configuration.packageName,
                dsn: dsn
            )
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
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func normalizedIdentifier(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

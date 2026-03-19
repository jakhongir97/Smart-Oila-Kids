import Foundation

@MainActor
final class DeviceLockCoordinator: ObservableObject {
    typealias ConnectAction = (String) -> Void
    typealias OptionalDSNAction = (String?) -> Void
    typealias VoidAction = () -> Void
    typealias AsyncVoidAction = () async -> Void
    typealias ScheduleApplyAction = (DeviceFullLockSchedule?, String?) -> Void
    typealias ShieldApplyAction = (Bool, DeviceAppLockShieldConfiguration) -> Void

    static let shared = DeviceLockCoordinator()

    struct AppLockMismatchState: Equatable {
        var unenforceableApplications: [DeviceAppSelectionApplication]

        var count: Int {
            unenforceableApplications.count
        }

        var previewNames: [String] {
            Array(unenforceableApplications.map(\.appName).prefix(5))
        }

        var hasMismatch: Bool {
            !unenforceableApplications.isEmpty
        }

        static let empty = AppLockMismatchState(unenforceableApplications: [])
    }

    struct State: Equatable {
        var isLocked: Bool
        var deviceLocalTime: String?
        var scheduleRange: String?

        static let unlocked = State(isLocked: false, deviceLocalTime: nil, scheduleRange: nil)
    }

    @Published private(set) var state: State = .unlocked
    @Published private(set) var lastErrorText: String?
    @Published private(set) var appLockMismatchState: AppLockMismatchState = .empty

    init(
        service: DeviceLockServicing = DeviceLockService(),
        applicationStateService: DeviceApplicationStateServicing = DeviceApplicationStateService(),
        shieldController: DeviceLockShieldController? = nil,
        webSocketService: DeviceLockWebSocketService = DeviceLockWebSocketService(),
        appLockStore: DeviceAppLockSelectionStore? = nil,
        appLockWebSocketService: DeviceApplicationLockWebSocketService = DeviceApplicationLockWebSocketService(),
        applicationsSyncWebSocketService: DeviceApplicationsSyncWebSocketService = DeviceApplicationsSyncWebSocketService(),
        scheduleMonitorController: DeviceLockScheduleMonitorController? = nil,
        appLimitMonitorController: DeviceAppLimitMonitorController? = nil,
        connectGlobalLockWebSocket: ConnectAction? = nil,
        disconnectGlobalLockWebSocket: VoidAction? = nil,
        connectAppLockWebSocket: ConnectAction? = nil,
        disconnectAppLockWebSocket: VoidAction? = nil,
        connectApplicationsSyncWebSocket: ConnectAction? = nil,
        disconnectApplicationsSyncWebSocket: VoidAction? = nil,
        applyScheduleMonitoring: ScheduleApplyAction? = nil,
        stopScheduleMonitoring: VoidAction? = nil,
        activateAppLimitMonitoring: OptionalDSNAction? = nil,
        stopAppLimitMonitoring: VoidAction? = nil,
        refreshAppLimitMonitoring: AsyncVoidAction? = nil,
        armAppLimitRecoveryCheck: VoidAction? = nil,
        syncSelectedApplicationsNow: AsyncVoidAction? = nil,
        syncApplicationUsageNow: AsyncVoidAction? = nil,
        applyShield: ShieldApplyAction? = nil,
        clearShield: VoidAction? = nil,
        shouldStartPolling: Bool = true
    ) {
        let resolvedShieldController = shieldController ?? DeviceLockShieldController()
        let resolvedAppLockStore = appLockStore ?? .shared
        let resolvedScheduleMonitorController = scheduleMonitorController ?? DeviceLockScheduleMonitorController()
        let resolvedAppLimitMonitorController = appLimitMonitorController ?? .shared

        self.service = service
        self.applicationStateService = applicationStateService
        self.appLockStore = resolvedAppLockStore
        self.connectGlobalLockWebSocket = connectGlobalLockWebSocket ?? { [webSocketService] in
            webSocketService.connect(dsn: $0)
        }
        self.disconnectGlobalLockWebSocket = disconnectGlobalLockWebSocket ?? { [webSocketService] in
            webSocketService.disconnect()
        }
        self.connectAppLockWebSocket = connectAppLockWebSocket ?? { [appLockWebSocketService] in
            appLockWebSocketService.connect(dsn: $0)
        }
        self.disconnectAppLockWebSocket = disconnectAppLockWebSocket ?? { [appLockWebSocketService] in
            appLockWebSocketService.disconnect()
        }
        self.connectApplicationsSyncWebSocket = connectApplicationsSyncWebSocket ?? { [applicationsSyncWebSocketService] in
            applicationsSyncWebSocketService.connect(dsn: $0)
        }
        self.disconnectApplicationsSyncWebSocket = disconnectApplicationsSyncWebSocket ?? { [applicationsSyncWebSocketService] in
            applicationsSyncWebSocketService.disconnect()
        }
        self.applyScheduleMonitoring = applyScheduleMonitoring ?? { [resolvedScheduleMonitorController] schedule, dsn in
            resolvedScheduleMonitorController.applySchedule(schedule, dsn: dsn)
        }
        self.stopScheduleMonitoring = stopScheduleMonitoring ?? { [resolvedScheduleMonitorController] in
            resolvedScheduleMonitorController.stop()
        }
        self.activateAppLimitMonitoring = activateAppLimitMonitoring ?? { [resolvedAppLimitMonitorController] in
            resolvedAppLimitMonitorController.activate(dsn: $0)
        }
        self.stopAppLimitMonitoring = stopAppLimitMonitoring ?? { [resolvedAppLimitMonitorController] in
            resolvedAppLimitMonitorController.stop()
        }
        self.refreshAppLimitMonitoring = refreshAppLimitMonitoring ?? { [resolvedAppLimitMonitorController] in
            await resolvedAppLimitMonitorController.refreshNow()
        }
        self.armAppLimitRecoveryCheck = armAppLimitRecoveryCheck ?? { [resolvedAppLimitMonitorController] in
            resolvedAppLimitMonitorController.armForegroundRecoveryCheck()
        }
        self.syncSelectedApplicationsNow = syncSelectedApplicationsNow ?? {
            await DeviceAppLockSyncCoordinator.shared.retryNow()
        }
        self.syncApplicationUsageNow = syncApplicationUsageNow ?? {
            await DeviceApplicationUsageReportCoordinator.shared.retryNow()
        }
        self.applyShield = applyShield ?? { [resolvedShieldController] isLocked, configuration in
            resolvedShieldController.applyLockState(isLocked, appLockConfiguration: configuration)
        }
        self.clearShield = clearShield ?? { [resolvedShieldController] in
            resolvedShieldController.clearAllRestrictions()
        }
        self.shouldStartPolling = shouldStartPolling
        webSocketService.onGlobalLockStatusChange = { [weak self] isLocked, isReconnectDelivery in
            Task { @MainActor in
                self?.handleRealtimeGlobalLockStatus(
                    isLocked,
                    isReconnectDelivery: isReconnectDelivery
                )
            }
        }
        appLockWebSocketService.onLockEvent = { [weak self] event, isReconnectDelivery in
            Task { @MainActor in
                self?.handleRealtimeApplicationLockEvent(
                    event,
                    isReconnectDelivery: isReconnectDelivery
                )
            }
        }
        applicationsSyncWebSocketService.onSyncRequested = { [weak self] isReconnectDelivery in
            Task { @MainActor in
                await self?.handleApplicationsSyncRequested(isReconnectDelivery: isReconnectDelivery)
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .deviceAppLockConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleAppLockConfigurationChanged(notification)
            }
        }
    }

    func start(dsn: String?, armRecoveryCheck: Bool = false) {
        guard let normalized = dsn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            stop()
            return
        }

        guard normalized != currentDSN else {
            if armRecoveryCheck {
                armForegroundRecoveryCheck()
            }
            return
        }

        pollingTask?.cancel()
        pollingTask = nil
        stopScheduleMonitoring()
        currentDSN = normalized
        pendingForegroundRecoveryCheck = armRecoveryCheck
        resetGlobalLockCache()
        lastApplicationStateRefreshAt = nil
        lastAuthoritativeLockedApplications = []
        appLockMismatchState = .empty
        updateAppLockStateDiagnostics(
            status: "idle",
            endpoint: "-",
            dsn: "-",
            remoteApplicationCount: 0,
            remoteLockedCount: 0,
            remoteUnenforceableCount: 0,
            lastError: "-"
        )
        appLockStore.activate(dsn: normalized)
        if armRecoveryCheck {
            armAppLimitRecoveryCheck()
        }
        activateAppLimitMonitoring(normalized)
        updateState(.unlocked)
        lastErrorText = nil
        connectGlobalLockWebSocket(normalized)
        connectAppLockWebSocket(normalized)
        connectApplicationsSyncWebSocket(normalized)
        updateAppLockSyncDiagnostics(
            status: "listening",
            endpoint: applicationsSyncEndpoint(for: normalized),
            dsn: normalized,
            lastSyncAt: nil
        )

        guard shouldStartPolling else { return }

        pollingTask = Task { [weak self] in
            await self?.pollLoop(for: normalized)
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        currentDSN = nil
        pendingForegroundRecoveryCheck = false
        disconnectAppLockWebSocket()
        disconnectApplicationsSyncWebSocket()
        updateAppLockSyncDiagnostics(
            status: "idle",
            endpoint: "-",
            dsn: "-",
            lastSyncAt: nil
        )
        stopScheduleMonitoring()
        stopAppLimitMonitoring()
        appLockStore.activate(dsn: nil)
        updateState(.unlocked)
        lastErrorText = nil
        resetGlobalLockCache()
        lastApplicationStateRefreshAt = nil
        lastAuthoritativeLockedApplications = []
        appLockMismatchState = .empty
        updateAppLockStateDiagnostics(
            status: "idle",
            endpoint: "-",
            dsn: "-",
            remoteApplicationCount: 0,
            remoteLockedCount: 0,
            remoteUnenforceableCount: 0,
            lastError: "-"
        )
        disconnectGlobalLockWebSocket()
        clearShield()
    }

    func refreshNow() async {
        guard let dsn = currentDSN else { return }
        await refreshStatus(for: dsn, forceApplicationStateRefresh: true)
        await refreshAppLimitMonitoring()
    }

    func armForegroundRecoveryCheck() {
        pendingForegroundRecoveryCheck = true
        armAppLimitRecoveryCheck()
    }

    private func pollLoop(for dsn: String) async {
        await refreshStatus(for: dsn)

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
            guard !Task.isCancelled else { break }
            await refreshStatus(for: dsn)
        }
    }

    private func refreshStatus(for dsn: String, forceApplicationStateRefresh: Bool = false) async {
        guard currentDSN == dsn else { return }

        do {
            let status = try await service.fetchFullLockStatus(dsn: dsn)
            let globalLockStatus = await resolveGlobalLockStatus(dsn: dsn) ?? false
            let didRefreshApplicationState = await refreshApplicationStateIfNeeded(
                for: dsn,
                force: forceApplicationStateRefresh || pendingForegroundRecoveryCheck
            )
            guard currentDSN == dsn else { return }

            updateState(State(
                isLocked: status.isLocked || globalLockStatus,
                deviceLocalTime: status.normalizedLocalTime,
                scheduleRange: status.schedule?.normalizedRange
            ))
            applyScheduleMonitoring(status.schedule, dsn)
            lastErrorText = nil
            await evaluateForegroundRecoveryIfNeeded(
                dsn: dsn,
                allowRecoveredApplicationLocks: didRefreshApplicationState
            )
        } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
            guard currentDSN == dsn else { return }
            applyScheduleMonitoring(nil, dsn)
            let didRefreshApplicationState = await refreshApplicationStateIfNeeded(
                for: dsn,
                force: forceApplicationStateRefresh || pendingForegroundRecoveryCheck
            )
            if let globalLockStatus = await resolveGlobalLockStatus(dsn: dsn) {
                updateState(State(
                    isLocked: globalLockStatus,
                    deviceLocalTime: nil,
                    scheduleRange: nil
                ))
                lastErrorText = nil
                await evaluateForegroundRecoveryIfNeeded(
                    dsn: dsn,
                    allowRecoveredApplicationLocks: didRefreshApplicationState
                )
            } else {
                // Keep current lock state when global fallback is unavailable.
                applyCurrentShieldState()
                lastErrorText = nil
                await evaluateForegroundRecoveryIfNeeded(
                    dsn: dsn,
                    allowRecoveredApplicationLocks: didRefreshApplicationState
                )
            }
        } catch {
            guard currentDSN == dsn else { return }
            if let globalLockStatus = await resolveGlobalLockStatus(dsn: dsn) {
                updateState(State(
                    isLocked: globalLockStatus,
                    deviceLocalTime: state.deviceLocalTime,
                    scheduleRange: state.scheduleRange
                ))
                lastErrorText = nil
            } else {
                // Keep current lock state on temporary network errors.
                applyCurrentShieldState()
                lastErrorText = error.localizedDescription
            }
        }
    }

    private func resolveGlobalLockStatus(dsn: String) async -> Bool? {
        do {
            let value = try await service.fetchGlobalLockStatus(dsn: dsn)
            lastKnownGlobalLockStatus = value
            lastKnownGlobalLockUpdatedAt = Date()
            return value
        } catch {
            return cachedGlobalLockStatus()
        }
    }

    private func cachedGlobalLockStatus(referenceDate: Date = Date()) -> Bool? {
        guard let value = lastKnownGlobalLockStatus,
              let updatedAt = lastKnownGlobalLockUpdatedAt,
              referenceDate.timeIntervalSince(updatedAt) <= globalLockCacheTTL else {
            return nil
        }
        return value
    }

    private func resetGlobalLockCache() {
        lastKnownGlobalLockStatus = nil
        lastKnownGlobalLockUpdatedAt = nil
    }

    private func refreshApplicationStateIfNeeded(for dsn: String, force: Bool) async -> Bool {
        guard currentDSN == dsn else { return false }

        let now = Date()
        if !force,
           let lastApplicationStateRefreshAt,
           now.timeIntervalSince(lastApplicationStateRefreshAt) < applicationStateRefreshTTL {
            return true
        }

        do {
            let result = try await applicationStateService.fetchState(dsn: dsn)
            guard currentDSN == dsn else { return false }

            appLockStore.reconcileRemoteLockedIdentifiers(result.remoteLockedIdentifiers)
            updateAppLockMismatchState(
                dsn: dsn,
                remoteLockedApplications: result.remoteLockedApplications,
                shouldNotify: true
            )
            lastApplicationStateRefreshAt = Date()
            updateAppLockStateDiagnostics(
                status: "reconciled",
                endpoint: result.applicationsEndpoint,
                dsn: dsn,
                remoteApplicationCount: result.applications.count,
                remoteLockedCount: result.remoteLockedIdentifiers.count,
                remoteUnenforceableCount: appLockMismatchState.count,
                lastError: "-"
            )
            return true
        } catch {
            updateAppLockStateDiagnostics(
                status: "failed",
                dsn: dsn,
                lastError: error.localizedDescription
            )
            return false
        }
    }

    private func handleRealtimeGlobalLockStatus(_ isLocked: Bool, isReconnectDelivery: Bool) {
        guard let currentDSN else { return }

        let previousValue = state.isLocked
        lastKnownGlobalLockStatus = isLocked
        lastKnownGlobalLockUpdatedAt = Date()
        updateState(State(
            isLocked: isLocked,
            deviceLocalTime: state.deviceLocalTime,
            scheduleRange: state.scheduleRange
        ))
        lastErrorText = nil

        if isReconnectDelivery {
            reportLockRecoveryIfNeeded(dsn: currentDSN)
        }

        guard previousValue != isLocked else { return }
        Task { [weak self] in
            await self?.refreshNow()
        }
    }

    private func handleRealtimeApplicationLockEvent(
        _ event: DeviceApplicationLockEvent,
        isReconnectDelivery: Bool
    ) {
        guard let currentDSN else { return }

        appLockStore.applyRemoteUpdate(
            lockStatus: event.lockStatus,
            identifiers: event.applicationIdentifiers
        )
        updateAppLockMismatchStateFromRealtimeEvent(event, dsn: currentDSN)
        applyCurrentShieldState()

        if isReconnectDelivery {
            reportLockRecoveryIfNeeded(dsn: currentDSN)
        }
    }

    private func updateState(_ newState: State) {
        state = newState
        applyCurrentShieldState()
    }

    private func applyCurrentShieldState() {
        applyShield(state.isLocked, appLockStore.shieldConfiguration())
    }

    private func handleAppLockConfigurationChanged(_ notification: Notification) {
        let previousMismatchState = appLockMismatchState
        let previousActiveLockedIdentifiers = appLockStore.activeLockedApplicationIdentifiers

        applyCurrentShieldState()
        recalculateAppLockMismatchState()

        guard configurationChangeReason(from: notification) == .selectionChanged,
              let currentDSN,
              !previousMismatchState.unenforceableApplications.isEmpty else {
            return
        }

        let mismatchImproved = appLockMismatchState.count < previousMismatchState.count
        let activeLocksIncreased = appLockStore.activeLockedApplicationIdentifiers.count > previousActiveLockedIdentifiers.count
        guard mismatchImproved || activeLocksIncreased else { return }

        let previousMismatchApplications = previousMismatchState.unenforceableApplications
        Task { [weak self] in
            await self?.recoverSelectionEnforcedLocksIfNeeded(
                dsn: currentDSN,
                previousMismatchApplications: previousMismatchApplications
            )
        }
    }

    private let service: DeviceLockServicing
    private let applicationStateService: DeviceApplicationStateServicing
    private let appLockStore: DeviceAppLockSelectionStore
    private let connectGlobalLockWebSocket: ConnectAction
    private let disconnectGlobalLockWebSocket: VoidAction
    private let connectAppLockWebSocket: ConnectAction
    private let disconnectAppLockWebSocket: VoidAction
    private let connectApplicationsSyncWebSocket: ConnectAction
    private let disconnectApplicationsSyncWebSocket: VoidAction
    private let applyScheduleMonitoring: ScheduleApplyAction
    private let stopScheduleMonitoring: VoidAction
    private let activateAppLimitMonitoring: OptionalDSNAction
    private let stopAppLimitMonitoring: VoidAction
    private let refreshAppLimitMonitoring: AsyncVoidAction
    private let armAppLimitRecoveryCheck: VoidAction
    private let syncSelectedApplicationsNow: AsyncVoidAction
    private let syncApplicationUsageNow: AsyncVoidAction
    private let applyShield: ShieldApplyAction
    private let clearShield: VoidAction
    private let shouldStartPolling: Bool
    private var currentDSN: String?
    private var pollingTask: Task<Void, Never>?
    private let pollingIntervalNanoseconds: UInt64 = 15_000_000_000
    private let globalLockCacheTTL: TimeInterval = 120
    private let applicationStateRefreshTTL: TimeInterval = 90
    private var lastKnownGlobalLockStatus: Bool?
    private var lastKnownGlobalLockUpdatedAt: Date?
    private var lastApplicationStateRefreshAt: Date?
    private var lastAuthoritativeLockedApplications: [DeviceAppSelectionApplication] = []
    private var pendingForegroundRecoveryCheck = false
    private var configurationObserver: NSObjectProtocol?

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }
    
    private func handleApplicationsSyncRequested(
        isReconnectDelivery: Bool
    ) async {
        guard let dsn = currentDSN else { return }
        updateAppLockSyncDiagnostics(
            status: "sync_received",
            endpoint: applicationsSyncEndpoint(for: dsn),
            dsn: dsn,
            lastSyncAt: Date()
        )
        await syncSelectedApplicationsNow()
        await syncApplicationUsageNow()
        let didRefresh = await refreshApplicationStateIfNeeded(for: dsn, force: true)
        await refreshAppLimitMonitoring()
        if isReconnectDelivery && didRefresh {
            reportLockRecoveryIfNeeded(dsn: dsn)
        }
    }
}

private extension DeviceLockCoordinator {
    func evaluateForegroundRecoveryIfNeeded(
        dsn: String,
        allowRecoveredApplicationLocks: Bool
    ) async {
        guard pendingForegroundRecoveryCheck else { return }
        pendingForegroundRecoveryCheck = false
        guard state.isLocked || (allowRecoveredApplicationLocks && appLockStore.shieldConfiguration().hasRestrictions) else {
            return
        }

        Task {
            await DeviceControlRecoveryNotifier.shared.recordLockRestored(dsn: dsn)
        }
    }

    func reportLockRecoveryIfNeeded(dsn: String) {
        guard state.isLocked || appLockStore.shieldConfiguration().hasRestrictions else {
            return
        }

        Task {
            await DeviceControlRecoveryNotifier.shared.recordLockRestored(dsn: dsn)
        }
    }

    func updateAppLockStateDiagnostics(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        remoteApplicationCount: Int? = nil,
        remoteLockedCount: Int? = nil,
        remoteUnenforceableCount: Int? = nil,
        lastError: String? = nil
    ) {
        RuntimeDiagnosticsCenter.shared.updateAppLockState(
            status: status,
            endpoint: endpoint,
            dsn: dsn,
            remoteApplicationCount: remoteApplicationCount,
            remoteLockedCount: remoteLockedCount,
            remoteUnenforceableCount: remoteUnenforceableCount,
            lastError: lastError
        )
    }

    func updateAppLockSyncDiagnostics(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastSyncAt: Date? = nil
    ) {
        RuntimeDiagnosticsCenter.shared.updateAppLockSync(
            status: status,
            endpoint: endpoint,
            dsn: dsn,
            lastPayload: nil,
            lastError: nil,
            lastSyncAt: lastSyncAt
        )
    }

    func applicationsSyncEndpoint(for dsn: String) -> String {
        "/children/device/\(dsn)/applications/sync"
    }

    func recalculateAppLockMismatchState() {
        guard let currentDSN else {
            appLockMismatchState = .empty
            return
        }

        updateAppLockMismatchState(
            dsn: currentDSN,
            remoteLockedApplications: lastAuthoritativeLockedApplications,
            shouldNotify: false
        )
    }

    func updateAppLockMismatchState(
        dsn: String,
        remoteLockedApplications: [DeviceAppSelectionApplication],
        shouldNotify: Bool
    ) {
        lastAuthoritativeLockedApplications = remoteLockedApplications
        let unmatchedApplications = appLockStore.unmatchedRemoteLockedApplications(from: remoteLockedApplications)
        appLockMismatchState = AppLockMismatchState(unenforceableApplications: unmatchedApplications)
        updateAppLockStateDiagnostics(
            dsn: dsn,
            remoteUnenforceableCount: unmatchedApplications.count
        )

        guard shouldNotify, !unmatchedApplications.isEmpty else { return }

        Task {
            await DeviceControlIntegrityNotifier.shared.recordUnenforceableRemoteLocks(
                dsn: dsn,
                applications: unmatchedApplications
            )
        }
    }

    func updateAppLockMismatchStateFromRealtimeEvent(_ event: DeviceApplicationLockEvent, dsn: String) {
        var resolved = Dictionary(uniqueKeysWithValues: lastAuthoritativeLockedApplications.map { ($0.packageName, $0) })

        for identifier in event.applicationIdentifiers {
            let normalizedIdentifier = identifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalizedIdentifier.isEmpty else { continue }

            if event.lockStatus {
                resolved[normalizedIdentifier] = resolved[normalizedIdentifier]
                    ?? DeviceAppSelectionApplication(
                        packageName: normalizedIdentifier,
                        appName: normalizedIdentifier
                    )
            } else {
                resolved.removeValue(forKey: normalizedIdentifier)
            }
        }

        let remoteLockedApplications = resolved.values.sorted { lhs, rhs in
            lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
        updateAppLockMismatchState(
            dsn: dsn,
            remoteLockedApplications: remoteLockedApplications,
            shouldNotify: event.lockStatus
        )
    }

    func recoverSelectionEnforcedLocksIfNeeded(
        dsn: String,
        previousMismatchApplications: [DeviceAppSelectionApplication]
    ) async {
        guard currentDSN == dsn,
              !previousMismatchApplications.isEmpty else {
            return
        }

        let didRefresh = await refreshApplicationStateIfNeeded(for: dsn, force: true)
        guard didRefresh, currentDSN == dsn else { return }

        let currentMismatchIdentifiers = Set(appLockMismatchState.unenforceableApplications.map(\.packageName))
        let activeLockedIdentifiers = appLockStore.activeLockedApplicationIdentifiers
        let restoredApplications = previousMismatchApplications.filter { application in
            !currentMismatchIdentifiers.contains(application.packageName)
                && activeLockedIdentifiers.contains(application.packageName)
        }
        guard !restoredApplications.isEmpty else { return }

        await DeviceControlRecoveryNotifier.shared.recordAppLockRestored(
            dsn: dsn,
            applications: restoredApplications
        )
    }

    func configurationChangeReason(from notification: Notification) -> DeviceAppLockConfigurationChangeReason {
        guard let rawValue = (notification.userInfo?[DeviceAppLockConfigurationChangeUserInfoKey.reason] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let reason = DeviceAppLockConfigurationChangeReason(rawValue: rawValue) else {
            return .remoteStateChanged
        }
        return reason
    }
}

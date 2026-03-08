import Foundation

@MainActor
final class DeviceLockCoordinator: ObservableObject {
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
        scheduleMonitorController: DeviceLockScheduleMonitorController? = nil,
        appLimitMonitorController: DeviceAppLimitMonitorController? = nil
    ) {
        self.service = service
        self.applicationStateService = applicationStateService
        self.shieldController = shieldController ?? DeviceLockShieldController()
        self.webSocketService = webSocketService
        self.appLockStore = appLockStore ?? .shared
        self.appLockWebSocketService = appLockWebSocketService
        self.scheduleMonitorController = scheduleMonitorController ?? DeviceLockScheduleMonitorController()
        self.appLimitMonitorController = appLimitMonitorController ?? .shared
        self.webSocketService.onGlobalLockStatusChange = { [weak self] isLocked, isReconnectDelivery in
            Task { @MainActor in
                self?.handleRealtimeGlobalLockStatus(
                    isLocked,
                    isReconnectDelivery: isReconnectDelivery
                )
            }
        }
        self.appLockWebSocketService.onLockEvent = { [weak self] event, isReconnectDelivery in
            Task { @MainActor in
                self?.handleRealtimeApplicationLockEvent(
                    event,
                    isReconnectDelivery: isReconnectDelivery
                )
            }
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .deviceAppLockConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyCurrentShieldState()
                self?.recalculateAppLockMismatchState()
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
        scheduleMonitorController.stop()
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
            appLimitMonitorController.armForegroundRecoveryCheck()
        }
        appLimitMonitorController.activate(dsn: normalized)
        updateState(.unlocked)
        lastErrorText = nil
        webSocketService.connect(dsn: normalized)
        appLockWebSocketService.connect(dsn: normalized)

        pollingTask = Task { [weak self] in
            await self?.pollLoop(for: normalized)
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        currentDSN = nil
        pendingForegroundRecoveryCheck = false
        appLockWebSocketService.disconnect()
        scheduleMonitorController.stop()
        appLimitMonitorController.stop()
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
        webSocketService.disconnect()
        shieldController.clearAllRestrictions()
    }

    func refreshNow() async {
        guard let dsn = currentDSN else { return }
        await refreshStatus(for: dsn, forceApplicationStateRefresh: true)
        await appLimitMonitorController.refreshNow()
    }

    func armForegroundRecoveryCheck() {
        pendingForegroundRecoveryCheck = true
        appLimitMonitorController.armForegroundRecoveryCheck()
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
            scheduleMonitorController.applySchedule(status.schedule, dsn: dsn)
            lastErrorText = nil
            await evaluateForegroundRecoveryIfNeeded(
                dsn: dsn,
                allowRecoveredApplicationLocks: didRefreshApplicationState
            )
        } catch let NetworkError.server(statusCode, _) where statusCode == 404 {
            guard currentDSN == dsn else { return }
            scheduleMonitorController.applySchedule(nil, dsn: dsn)
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

            appLockStore.reconcileRemoteLockedIdentifiers(result.authoritativeLockedIdentifiers)
            updateAppLockMismatchState(
                dsn: dsn,
                remoteLockedApplications: result.authoritativeLockedApplications,
                shouldNotify: true
            )
            lastApplicationStateRefreshAt = Date()
            updateAppLockStateDiagnostics(
                status: "reconciled",
                endpoint: "\(result.applicationsEndpoint) | \(result.lockedEndpoint)",
                dsn: dsn,
                remoteApplicationCount: result.applications.count,
                remoteLockedCount: result.authoritativeLockedIdentifiers.count,
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
        shieldController.applyLockState(
            state.isLocked,
            appLockConfiguration: appLockStore.shieldConfiguration()
        )
    }

    private let service: DeviceLockServicing
    private let applicationStateService: DeviceApplicationStateServicing
    private let shieldController: DeviceLockShieldController
    private let webSocketService: DeviceLockWebSocketService
    private let appLockStore: DeviceAppLockSelectionStore
    private let appLockWebSocketService: DeviceApplicationLockWebSocketService
    private let scheduleMonitorController: DeviceLockScheduleMonitorController
    private let appLimitMonitorController: DeviceAppLimitMonitorController
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
                    ?? DeviceAppSelectionApplication(packageName: normalizedIdentifier, appName: normalizedIdentifier)
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
}

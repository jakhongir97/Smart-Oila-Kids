import Combine
import FamilyControls
import SwiftUI

@MainActor
final class SettingsAppLockPanelController: ObservableObject {
    typealias ActivateAppLimitsAction = (String?) -> Void
    typealias RefreshLockAction = () async -> Void
    typealias RetryUsageAction = () async -> Void
    typealias SelectedApplicationsProvider = () -> [DeviceAppSelectionApplication]
    typealias ClearSelectionAction = () -> Void
    typealias RecordRemovedApplicationsAction = (String?, [DeviceAppSelectionApplication]) async -> Void
    typealias BuildUsageSummaryAction = (
        String?,
        ScreenTimeUsageActivityPeriod,
        DeviceAppLockSelectionStore,
        DeviceAppLimitPresentationState
    ) -> ScreenTimeUsageActivitySummary
    typealias HapticAction = () -> Void

    @Published var showPicker = false
    @Published var usagePeriod: ScreenTimeUsageActivityPeriod = .daily
    @Published private(set) var usageSummary = ScreenTimeUsageActivitySummary.empty(period: .daily)

    let permissionManager: LocationPermissionManager
    let store: DeviceAppLockSelectionStore

    private let lockCoordinator: DeviceLockCoordinator
    private let appLimitMonitor: DeviceAppLimitMonitorController
    private let diagnostics: RuntimeDiagnosticsCenter
    private let usageCoordinator: ScreenTimeUsageCoordinator
    private let screenTimeRequirement = PermissionRequirement.usageStats
    private let activateAppLimits: ActivateAppLimitsAction
    private let refreshLock: RefreshLockAction
    private let retryUsage: RetryUsageAction
    private let selectedApplications: SelectedApplicationsProvider
    private let clearSelectionAction: ClearSelectionAction
    private let recordRemovedApplications: RecordRemovedApplicationsAction
    private let buildUsageSummary: BuildUsageSummaryAction
    private let tapHaptic: HapticAction

    private var pickerBaselineApplications: [DeviceAppSelectionApplication] = []
    private var cancellables: Set<AnyCancellable> = []

    convenience init(
        permissionManager: LocationPermissionManager,
        store: DeviceAppLockSelectionStore
    ) {
        self.init(
            permissionManager: permissionManager,
            store: store,
            lockCoordinator: DeviceLockCoordinator.shared,
            appLimitMonitor: DeviceAppLimitMonitorController.shared,
            diagnostics: RuntimeDiagnosticsCenter.shared,
            usageCoordinator: ScreenTimeUsageCoordinator.shared
        )
    }

    init(
        permissionManager: LocationPermissionManager,
        store: DeviceAppLockSelectionStore,
        lockCoordinator: DeviceLockCoordinator,
        appLimitMonitor: DeviceAppLimitMonitorController,
        diagnostics: RuntimeDiagnosticsCenter,
        usageCoordinator: ScreenTimeUsageCoordinator,
        activateAppLimits: ActivateAppLimitsAction? = nil,
        refreshLock: RefreshLockAction? = nil,
        retryUsage: RetryUsageAction? = nil,
        selectedApplications: SelectedApplicationsProvider? = nil,
        clearSelectionAction: ClearSelectionAction? = nil,
        recordRemovedApplications: RecordRemovedApplicationsAction? = nil,
        buildUsageSummary: BuildUsageSummaryAction? = nil,
        tapHaptic: HapticAction? = nil
    ) {
        self.permissionManager = permissionManager
        self.store = store
        self.lockCoordinator = lockCoordinator
        self.appLimitMonitor = appLimitMonitor
        self.diagnostics = diagnostics
        self.usageCoordinator = usageCoordinator
        self.activateAppLimits = activateAppLimits ?? { [appLimitMonitor] dsn in
            appLimitMonitor.activate(dsn: dsn)
        }
        self.refreshLock = refreshLock ?? { [lockCoordinator] in
            await lockCoordinator.refreshNow()
        }
        self.retryUsage = retryUsage ?? { [usageCoordinator] in
            await usageCoordinator.retryNow()
        }
        self.selectedApplications = selectedApplications ?? { [store] in
            store.selectedApplications()
        }
        self.clearSelectionAction = clearSelectionAction ?? { [store] in
            store.clearSelection()
        }
        self.recordRemovedApplications = recordRemovedApplications ?? { dsn, applications in
            await DeviceControlIntegrityNotifier.shared.recordAppProtectionRemoved(
                dsn: dsn,
                applications: applications
            )
        }
        self.buildUsageSummary = buildUsageSummary ?? { dsn, period, selectionStore, appLimitState in
            ScreenTimeUsageActivitySummaryBuilder.build(
                dsn: dsn,
                period: period,
                selectionStore: selectionStore,
                appLimitState: appLimitState
            )
        }
        self.tapHaptic = tapHaptic ?? AppHaptics.tap
        bindDependencies()
        reloadUsageSummary()
    }

    var summary: DeviceAppLockSelectionSummary {
        store.selectionSummary()
    }

    var appLimitState: DeviceAppLimitPresentationState {
        appLimitMonitor.presentationState
    }

    var scheduleDiagnostics: LockScheduleMonitorDiagnosticsSnapshot {
        diagnostics.lockSchedule
    }

    var mismatchState: DeviceLockCoordinator.AppLockMismatchState {
        lockCoordinator.appLockMismatchState
    }

    var lockState: DeviceLockCoordinator.State {
        lockCoordinator.state
    }

    var isScreenTimeReady: Bool {
        permissionManager.isSatisfied(screenTimeRequirement)
    }

    var actionTitle: String? {
        permissionManager.primaryActionTitle(for: screenTimeRequirement)
    }

    var selectionBinding: Binding<FamilyActivitySelection> {
        Binding(
            get: { self.store.selection },
            set: { self.store.updateSelection($0) }
        )
    }

    func handleAppear() {
        permissionManager.refreshStatuses()
        activateAppLimits(store.currentDSN)
        reloadUsageSummary()

        Task { [weak self] in
            await self?.refreshLock()
        }
    }

    func refreshProtectionState() {
        permissionManager.refreshStatuses()

        Task { [weak self] in
            await self?.refreshLock()
        }
    }

    func requestScreenTimeAccess() {
        tapHaptic()
        permissionManager.performAction(for: screenTimeRequirement)
    }

    func refreshUsage() {
        tapHaptic()

        Task { [weak self] in
            guard let self else { return }
            await retryUsage()
            reloadUsageSummary()
        }
    }

    func openPicker() {
        tapHaptic()
        pickerBaselineApplications = selectedApplications()
        showPicker = true
    }

    func clearSelection() {
        tapHaptic()
        let removedApplications = selectedApplications()
        clearSelectionAction()

        Task { [weak self] in
            guard let self else { return }
            await recordRemovedApplications(store.currentDSN, removedApplications)
            await refreshLock()
        }
    }

    func statusSubtitle() -> String {
        if summary.hasSelection {
            return L10n.tr("settings.app_lock_subtitle")
        }

        return L10n.tr("settings.app_lock_no_selection")
    }

    func shouldShowAppLimits() -> Bool {
        guard isScreenTimeReady else { return false }
        return !appLimitState.items.isEmpty || appLimitState.remoteLimitCount > 0
    }

    func shouldShowLockSchedule() -> Bool {
        if let scheduleRange = lockState.scheduleRange, !scheduleRange.isEmpty {
            return true
        }

        return scheduleDiagnostics.status != "idle"
    }
}

private extension SettingsAppLockPanelController {
    func bindDependencies() {
        [
            permissionManager.objectWillChange.eraseToAnyPublisher(),
            store.objectWillChange.eraseToAnyPublisher(),
            lockCoordinator.objectWillChange.eraseToAnyPublisher(),
            appLimitMonitor.objectWillChange.eraseToAnyPublisher(),
            diagnostics.objectWillChange.eraseToAnyPublisher(),
            usageCoordinator.objectWillChange.eraseToAnyPublisher()
        ]
        .forEach { publisher in
            publisher
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &cancellables)
        }

        store.$currentDSN
            .dropFirst()
            .sink { [weak self] newValue in
                self?.handleDSNChange(newValue)
            }
            .store(in: &cancellables)

        permissionManager.$screenTimePermissionStatus
            .dropFirst()
            .sink { [weak self] _ in
                self?.reloadUsageSummary()
            }
            .store(in: &cancellables)

        appLimitMonitor.$presentationState
            .dropFirst()
            .sink { [weak self] _ in
                self?.reloadUsageSummary()
            }
            .store(in: &cancellables)

        usageCoordinator.$latestSnapshot
            .dropFirst()
            .sink { [weak self] _ in
                self?.reloadUsageSummary()
            }
            .store(in: &cancellables)

        $usagePeriod
            .dropFirst()
            .sink { [weak self] _ in
                self?.reloadUsageSummary()
            }
            .store(in: &cancellables)

        $showPicker
            .dropFirst()
            .sink { [weak self] isPresented in
                self?.handlePickerVisibilityChange(isPresented)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .deviceAppLockConfigurationDidChange)
            .sink { [weak self] _ in
                self?.reloadUsageSummary()
            }
            .store(in: &cancellables)
    }

    func handleDSNChange(_ newValue: String?) {
        activateAppLimits(newValue)
        reloadUsageSummary()

        Task { [weak self] in
            await self?.refreshLock()
        }
    }

    func handlePickerVisibilityChange(_ isPresented: Bool) {
        guard !isPresented else { return }

        reportRemovedApplications(comparedTo: pickerBaselineApplications)
        pickerBaselineApplications = []

        Task { [weak self] in
            await self?.refreshLock()
        }
    }

    func reloadUsageSummary() {
        usageSummary = buildUsageSummary(
            store.currentDSN,
            usagePeriod,
            store,
            appLimitMonitor.presentationState
        )
    }

    func reportRemovedApplications(comparedTo baseline: [DeviceAppSelectionApplication]) {
        guard !baseline.isEmpty else { return }

        let currentIdentifiers = Set(selectedApplications().map(\.packageName))
        let removedApplications = baseline.filter { application in
            !currentIdentifiers.contains(application.packageName)
        }
        guard !removedApplications.isEmpty else { return }

        Task {
            await recordRemovedApplications(store.currentDSN, removedApplications)
        }
    }
}

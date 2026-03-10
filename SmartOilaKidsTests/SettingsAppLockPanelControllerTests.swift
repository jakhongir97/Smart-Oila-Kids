import XCTest
@testable import SmartOilaKids

@MainActor
final class SettingsAppLockPanelControllerTests: XCTestCase {
    private var store: DeviceAppLockSelectionStore!
    private var userDefaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        userDefaultsSuiteName = "SettingsAppLockPanelControllerTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        store = DeviceAppLockSelectionStore(
            userDefaults: userDefaults,
            syncUpdate: { _, _ in }
        )
        store.activate(dsn: nil)
        store.clearSelection()
    }

    override func tearDown() {
        store.activate(dsn: nil)
        store.clearSelection()
        UserDefaults(suiteName: userDefaultsSuiteName)?.removePersistentDomain(forName: userDefaultsSuiteName)
        store = nil
        userDefaultsSuiteName = nil
        super.tearDown()
    }

    func testHandleAppearActivatesLimitsForCurrentDSNAndRefreshesLock() async {
        let dsn = uniqueDSN()
        store.activate(dsn: dsn)

        let refreshExpectation = expectation(description: "refresh lock")
        var activatedDSNs: [String?] = []

        let controller = makeController(
            activateAppLimits: { activatedDSNs.append($0) },
            refreshLock: {
                refreshExpectation.fulfill()
            }
        )

        controller.handleAppear()

        await fulfillment(of: [refreshExpectation], timeout: 1)
        XCTAssertEqual(activatedDSNs, [dsn])
    }

    func testDSNChangeActivatesLimitsAndRefreshesLock() async {
        let dsn = uniqueDSN()
        let activatedExpectation = expectation(description: "activate limits")
        let refreshExpectation = expectation(description: "refresh lock")
        var activatedDSN: String?

        let controller = makeController(
            activateAppLimits: { value in
                activatedDSN = value
                activatedExpectation.fulfill()
            },
            refreshLock: {
                refreshExpectation.fulfill()
            }
        )
        _ = controller

        store.activate(dsn: dsn)

        await fulfillment(of: [activatedExpectation, refreshExpectation], timeout: 1)
        XCTAssertEqual(activatedDSN, dsn)
    }

    func testRefreshUsageRetriesAndRebuildsSummary() async {
        let retryExpectation = expectation(description: "retry usage")
        var totalUsedTime = 10

        let controller = makeController(
            retryUsage: {
                totalUsedTime = 25
                retryExpectation.fulfill()
            },
            buildUsageSummary: { _, period, _, _ in
                Self.summary(period: period, totalUsedTime: totalUsedTime)
            }
        )

        XCTAssertEqual(controller.usageSummary.totalUsedTime, 10)

        controller.refreshUsage()

        await fulfillment(of: [retryExpectation], timeout: 1)
        await Task.yield()

        XCTAssertEqual(controller.usageSummary.totalUsedTime, 25)
    }

    func testUsagePeriodChangeRebuildsSummary() async {
        let weeklyExpectation = expectation(description: "weekly summary")

        let controller = makeController(
            buildUsageSummary: { _, period, _, _ in
                if period == .weekly {
                    weeklyExpectation.fulfill()
                }
                return Self.summary(period: period, totalUsedTime: 5)
            }
        )

        controller.usagePeriod = .weekly

        await fulfillment(of: [weeklyExpectation], timeout: 1)
        XCTAssertEqual(controller.usageSummary.period, .weekly)
    }

    func testPickerDismissalReportsRemovedApplicationsAndRefreshesLock() async {
        let removedExpectation = expectation(description: "record removed apps")
        let refreshExpectation = expectation(description: "refresh lock")
        var currentApplications = [
            DeviceAppSelectionApplication(packageName: "com.example.first", appName: "First"),
            DeviceAppSelectionApplication(packageName: "com.example.second", appName: "Second")
        ]
        var removedApplications: [DeviceAppSelectionApplication] = []

        let controller = makeController(
            refreshLock: {
                refreshExpectation.fulfill()
            },
            selectedApplications: {
                currentApplications
            },
            recordRemovedApplications: { _, applications in
                removedApplications = applications
                removedExpectation.fulfill()
            }
        )

        controller.openPicker()
        await Task.yield()

        currentApplications = [
            DeviceAppSelectionApplication(packageName: "com.example.second", appName: "Second")
        ]
        controller.showPicker = false

        await fulfillment(of: [removedExpectation, refreshExpectation], timeout: 1)
        XCTAssertEqual(removedApplications.map(\.packageName), ["com.example.first"])
    }

    private func makeController(
        activateAppLimits: SettingsAppLockPanelController.ActivateAppLimitsAction? = nil,
        refreshLock: SettingsAppLockPanelController.RefreshLockAction? = nil,
        retryUsage: SettingsAppLockPanelController.RetryUsageAction? = nil,
        selectedApplications: SettingsAppLockPanelController.SelectedApplicationsProvider? = nil,
        clearSelectionAction: SettingsAppLockPanelController.ClearSelectionAction? = nil,
        recordRemovedApplications: SettingsAppLockPanelController.RecordRemovedApplicationsAction? = nil,
        buildUsageSummary: SettingsAppLockPanelController.BuildUsageSummaryAction? = nil
    ) -> SettingsAppLockPanelController {
        let permissionManager = LocationPermissionManager()
        let appLimitMonitor = DeviceAppLimitMonitorController(selectionStore: store)
        let lockCoordinator = DeviceLockCoordinator(
            appLockStore: store,
            scheduleMonitorController: DeviceLockScheduleMonitorController(),
            appLimitMonitorController: appLimitMonitor
        )

        return SettingsAppLockPanelController(
            permissionManager: permissionManager,
            store: store,
            lockCoordinator: lockCoordinator,
            appLimitMonitor: appLimitMonitor,
            diagnostics: RuntimeDiagnosticsCenter.shared,
            usageCoordinator: ScreenTimeUsageCoordinator.shared,
            activateAppLimits: activateAppLimits,
            refreshLock: refreshLock,
            retryUsage: retryUsage,
            selectedApplications: selectedApplications,
            clearSelectionAction: clearSelectionAction,
            recordRemovedApplications: recordRemovedApplications,
            buildUsageSummary: buildUsageSummary,
            tapHaptic: {}
        )
    }

    private func uniqueDSN() -> String {
        "settings-panel-\(UUID().uuidString)"
    }

    private static func summary(
        period: ScreenTimeUsageActivityPeriod,
        totalUsedTime: Int
    ) -> ScreenTimeUsageActivitySummary {
        ScreenTimeUsageActivitySummary(
            period: period,
            hasSelection: false,
            snapshotCount: 1,
            totalUsedTime: totalUsedTime,
            lastUpdatedAt: nil,
            items: [],
            isAppGroupAvailable: true
        )
    }
}

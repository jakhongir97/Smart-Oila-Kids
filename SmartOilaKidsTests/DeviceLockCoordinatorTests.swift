import XCTest
@testable import SmartOilaKids

@MainActor
final class DeviceLockCoordinatorTests: XCTestCase {
    private var store: DeviceAppLockSelectionStore!
    private var userDefaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        userDefaultsSuiteName = "DeviceLockCoordinatorTests.\(UUID().uuidString)"
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

    func testStartAndStopCoordinateInjectedCollaborators() {
        let service = DeviceLockServiceSpy()
        let applicationStateService = DeviceApplicationStateServiceSpy()

        var globalConnects: [String] = []
        var globalDisconnects = 0
        var appConnects: [String] = []
        var appDisconnects = 0
        var appSyncConnects: [String] = []
        var appSyncDisconnects = 0
        var scheduleStops = 0
        var appLimitActivations: [String?] = []
        var appLimitStops = 0
        var appLimitRecoveryArms = 0

        let coordinator = makeCoordinator(
            service: service,
            applicationStateService: applicationStateService,
            connectGlobalLockWebSocket: { globalConnects.append($0) },
            disconnectGlobalLockWebSocket: { globalDisconnects += 1 },
            connectAppLockWebSocket: { appConnects.append($0) },
            disconnectAppLockWebSocket: { appDisconnects += 1 },
            connectApplicationsSyncWebSocket: { appSyncConnects.append($0) },
            disconnectApplicationsSyncWebSocket: { appSyncDisconnects += 1 },
            stopScheduleMonitoring: { scheduleStops += 1 },
            activateAppLimitMonitoring: { appLimitActivations.append($0) },
            stopAppLimitMonitoring: { appLimitStops += 1 },
            armAppLimitRecoveryCheck: { appLimitRecoveryArms += 1 }
        )

        coordinator.start(dsn: "  child-1  ", armRecoveryCheck: true)

        XCTAssertEqual(store.currentDSN, "child-1")
        XCTAssertEqual(coordinator.state, .unlocked)
        XCTAssertEqual(globalConnects, ["child-1"])
        XCTAssertEqual(appConnects, ["child-1"])
        XCTAssertEqual(appSyncConnects, ["child-1"])
        XCTAssertEqual(scheduleStops, 1)
        XCTAssertEqual(appLimitActivations, ["child-1"])
        XCTAssertEqual(appLimitRecoveryArms, 1)

        coordinator.stop()

        XCTAssertNil(store.currentDSN)
        XCTAssertEqual(coordinator.state, .unlocked)
        XCTAssertNil(coordinator.lastErrorText)
        XCTAssertEqual(globalDisconnects, 1)
        XCTAssertEqual(appDisconnects, 1)
        XCTAssertEqual(appSyncDisconnects, 1)
        XCTAssertEqual(scheduleStops, 2)
        XCTAssertEqual(appLimitStops, 1)
    }

    func testRefreshNowCombinesFullStatusAndGlobalLockState() async throws {
        let service = DeviceLockServiceSpy(
            fullStatusResults: [.success(try makeFullLockStatus(
                isLocked: false,
                deviceLocalTime: "08:05:33.000",
                scheduleStart: "22:30:00",
                scheduleEnd: "06:45:00",
                isScheduleEnabled: true
            ))],
            globalLockResults: [.success(true)]
        )
        let applicationStateService = DeviceApplicationStateServiceSpy()

        var appliedSchedules: [(String?, String?)] = []
        var appLimitRefreshCount = 0

        let coordinator = makeCoordinator(
            service: service,
            applicationStateService: applicationStateService,
            applyScheduleMonitoring: { schedule, dsn in
                appliedSchedules.append((dsn, schedule?.normalizedRange))
            },
            refreshAppLimitMonitoring: {
                appLimitRefreshCount += 1
            }
        )

        coordinator.start(dsn: "child-1")
        await coordinator.refreshNow()

        XCTAssertTrue(coordinator.state.isLocked)
        XCTAssertEqual(coordinator.state.deviceLocalTime, "08:05")
        XCTAssertEqual(coordinator.state.scheduleRange, "22:30 - 06:45")
        XCTAssertNil(coordinator.lastErrorText)
        XCTAssertEqual(service.fullStatusRequests, ["child-1"])
        XCTAssertEqual(service.globalLockRequests, ["child-1"])
        XCTAssertEqual(applicationStateService.requests, ["child-1"])
        XCTAssertEqual(appLimitRefreshCount, 1)
        XCTAssertEqual(appliedSchedules.map(\.0), ["child-1"])
        XCTAssertEqual(appliedSchedules.map(\.1), ["22:30 - 06:45"])
    }

    func testRefreshNowUsesGlobalFallbackWhenFullStatusReturns404() async {
        let service = DeviceLockServiceSpy(
            fullStatusResults: [.failure(NetworkError.server(statusCode: 404, body: ""))],
            globalLockResults: [.success(true)]
        )
        let coordinator = makeCoordinator(service: service)

        coordinator.start(dsn: "child-404")
        await coordinator.refreshNow()

        XCTAssertTrue(coordinator.state.isLocked)
        XCTAssertNil(coordinator.state.deviceLocalTime)
        XCTAssertNil(coordinator.state.scheduleRange)
        XCTAssertNil(coordinator.lastErrorText)
    }

    func testRefreshNowUsesCachedGlobalStatusOnTransientFailure() async throws {
        let service = DeviceLockServiceSpy(
            fullStatusResults: [
                .success(try makeFullLockStatus(
                    isLocked: false,
                    deviceLocalTime: "09:10:00",
                    scheduleStart: nil,
                    scheduleEnd: nil,
                    isScheduleEnabled: nil
                )),
                .failure(TestLockCoordinatorError.expected)
            ],
            globalLockResults: [
                .success(true),
                .failure(TestLockCoordinatorError.expected)
            ]
        )
        let coordinator = makeCoordinator(service: service)

        coordinator.start(dsn: "child-cache")
        await coordinator.refreshNow()
        XCTAssertTrue(coordinator.state.isLocked)
        XCTAssertNil(coordinator.lastErrorText)

        await coordinator.refreshNow()

        XCTAssertTrue(coordinator.state.isLocked)
        XCTAssertEqual(coordinator.state.deviceLocalTime, "09:10")
        XCTAssertNil(coordinator.lastErrorText)
    }

    func testRefreshNowSurfacesErrorWhenNoGlobalFallbackExists() async {
        let service = DeviceLockServiceSpy(
            fullStatusResults: [.failure(TestLockCoordinatorError.expected)],
            globalLockResults: [.failure(TestLockCoordinatorError.expected)]
        )
        let coordinator = makeCoordinator(service: service)

        coordinator.start(dsn: "child-error")
        await coordinator.refreshNow()

        XCTAssertEqual(coordinator.state, .unlocked)
        XCTAssertEqual(coordinator.lastErrorText, TestLockCoordinatorError.expected.localizedDescription)
    }

    func testRealtimeApplicationLockEventUpdatesMismatchState() async {
        let service = DeviceLockServiceSpy()
        let appLockWebSocketService = DeviceApplicationLockWebSocketService()
        let coordinator = makeCoordinator(
            service: service,
            appLockWebSocketService: appLockWebSocketService
        )

        coordinator.start(dsn: "child-realtime")
        appLockWebSocketService.onLockEvent?(
            DeviceApplicationLockEvent(
                lockStatus: true,
                applicationIdentifiers: ["com.example.blocked"]
            ),
            false
        )

        await Task.yield()
        await Task.yield()

        XCTAssertEqual(coordinator.appLockMismatchState.count, 1)
        XCTAssertEqual(coordinator.appLockMismatchState.previewNames, ["com.example.blocked"])
        XCTAssertTrue(store.activeLockedApplicationIdentifiers.isEmpty)
    }

    func testApplicationsSyncEventRetriesChildSyncSurfacesUsageRetryAndRefreshesState() async {
        let service = DeviceLockServiceSpy()
        let applicationStateService = DeviceApplicationStateServiceSpy()
        let applicationsSyncWebSocketService = DeviceApplicationsSyncWebSocketService()
        var selectedSyncRetryCount = 0
        var usageRetryCount = 0
        var appLimitRefreshCount = 0

        let coordinator = makeCoordinator(
            service: service,
            applicationStateService: applicationStateService,
            applicationsSyncWebSocketService: applicationsSyncWebSocketService,
            refreshAppLimitMonitoring: {
                appLimitRefreshCount += 1
            },
            syncSelectedApplicationsNow: {
                selectedSyncRetryCount += 1
            },
            syncApplicationUsageNow: {
                usageRetryCount += 1
            }
        )

        coordinator.start(dsn: "child-sync")
        applicationsSyncWebSocketService.onSyncRequested?(false)

        await Task.yield()
        await Task.yield()

        XCTAssertEqual(selectedSyncRetryCount, 1)
        XCTAssertEqual(usageRetryCount, 1)
        XCTAssertEqual(applicationStateService.requests, ["child-sync"])
        XCTAssertEqual(appLimitRefreshCount, 1)
    }

    private func makeCoordinator(
        service: DeviceLockServicing? = nil,
        applicationStateService: DeviceApplicationStateServicing? = nil,
        appLockWebSocketService: DeviceApplicationLockWebSocketService = DeviceApplicationLockWebSocketService(),
        applicationsSyncWebSocketService: DeviceApplicationsSyncWebSocketService = DeviceApplicationsSyncWebSocketService(),
        connectGlobalLockWebSocket: DeviceLockCoordinator.ConnectAction? = nil,
        disconnectGlobalLockWebSocket: DeviceLockCoordinator.VoidAction? = nil,
        connectAppLockWebSocket: DeviceLockCoordinator.ConnectAction? = nil,
        disconnectAppLockWebSocket: DeviceLockCoordinator.VoidAction? = nil,
        connectApplicationsSyncWebSocket: DeviceLockCoordinator.ConnectAction? = nil,
        disconnectApplicationsSyncWebSocket: DeviceLockCoordinator.VoidAction? = nil,
        applyScheduleMonitoring: DeviceLockCoordinator.ScheduleApplyAction? = nil,
        stopScheduleMonitoring: DeviceLockCoordinator.VoidAction? = nil,
        activateAppLimitMonitoring: DeviceLockCoordinator.OptionalDSNAction? = nil,
        stopAppLimitMonitoring: DeviceLockCoordinator.VoidAction? = nil,
        refreshAppLimitMonitoring: DeviceLockCoordinator.AsyncVoidAction? = nil,
        armAppLimitRecoveryCheck: DeviceLockCoordinator.VoidAction? = nil,
        syncSelectedApplicationsNow: DeviceLockCoordinator.AsyncVoidAction? = nil,
        syncApplicationUsageNow: DeviceLockCoordinator.AsyncVoidAction? = nil
    ) -> DeviceLockCoordinator {
        let resolvedService = service ?? DeviceLockServiceSpy()
        let resolvedApplicationStateService = applicationStateService ?? DeviceApplicationStateServiceSpy()

        return DeviceLockCoordinator(
            service: resolvedService,
            applicationStateService: resolvedApplicationStateService,
            webSocketService: DeviceLockWebSocketService(),
            appLockStore: store,
            appLockWebSocketService: appLockWebSocketService,
            applicationsSyncWebSocketService: applicationsSyncWebSocketService,
            connectGlobalLockWebSocket: connectGlobalLockWebSocket ?? { _ in },
            disconnectGlobalLockWebSocket: disconnectGlobalLockWebSocket ?? {},
            connectAppLockWebSocket: connectAppLockWebSocket ?? { _ in },
            disconnectAppLockWebSocket: disconnectAppLockWebSocket ?? {},
            connectApplicationsSyncWebSocket: connectApplicationsSyncWebSocket ?? { _ in },
            disconnectApplicationsSyncWebSocket: disconnectApplicationsSyncWebSocket ?? {},
            applyScheduleMonitoring: applyScheduleMonitoring ?? { _, _ in },
            stopScheduleMonitoring: stopScheduleMonitoring ?? {},
            activateAppLimitMonitoring: activateAppLimitMonitoring ?? { _ in },
            stopAppLimitMonitoring: stopAppLimitMonitoring ?? {},
            refreshAppLimitMonitoring: refreshAppLimitMonitoring ?? {},
            armAppLimitRecoveryCheck: armAppLimitRecoveryCheck ?? {},
            syncSelectedApplicationsNow: syncSelectedApplicationsNow ?? {},
            syncApplicationUsageNow: syncApplicationUsageNow ?? {},
            applyShield: { _, _ in },
            clearShield: {},
            shouldStartPolling: false
        )
    }

    private func makeFullLockStatus(
        isLocked: Bool,
        deviceLocalTime: String?,
        scheduleStart: String?,
        scheduleEnd: String?,
        isScheduleEnabled: Bool?
    ) throws -> DeviceFullLockStatus {
        var payload: [String: Any] = ["is_locked": isLocked]
        if let deviceLocalTime {
            payload["device_local_time"] = deviceLocalTime
        }
        if scheduleStart != nil || scheduleEnd != nil || isScheduleEnabled != nil {
            var schedule: [String: Any] = [:]
            if let scheduleStart {
                schedule["start_time"] = scheduleStart
            }
            if let scheduleEnd {
                schedule["end_time"] = scheduleEnd
            }
            if let isScheduleEnabled {
                schedule["is_schedule_enabled"] = isScheduleEnabled
            }
            payload["schedule"] = schedule
        }

        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(DeviceFullLockStatus.self, from: data)
    }
}

private enum TestLockCoordinatorError: LocalizedError {
    case expected

    var errorDescription: String? {
        "Coordinator failure"
    }
}

@MainActor
private final class DeviceLockServiceSpy: DeviceLockServicing {
    private(set) var fullStatusRequests: [String] = []
    private(set) var globalLockRequests: [String] = []
    private var fullStatusResults: [Result<DeviceFullLockStatus, Error>]
    private var globalLockResults: [Result<Bool, Error>]

    init(
        fullStatusResults: [Result<DeviceFullLockStatus, Error>] = [],
        globalLockResults: [Result<Bool, Error>] = []
    ) {
        self.fullStatusResults = fullStatusResults
        self.globalLockResults = globalLockResults
    }

    func fetchFullLockStatus(dsn: String) async throws -> DeviceFullLockStatus {
        fullStatusRequests.append(dsn)
        return try nextFullStatusResult().get()
    }

    func fetchGlobalLockStatus(dsn: String) async throws -> Bool {
        globalLockRequests.append(dsn)
        return try nextGlobalLockResult().get()
    }

    private func nextFullStatusResult() -> Result<DeviceFullLockStatus, Error> {
        if !fullStatusResults.isEmpty {
            return fullStatusResults.removeFirst()
        }
        return .success(try! JSONDecoder().decode(DeviceFullLockStatus.self, from: Data(#"{"is_locked":false}"#.utf8)))
    }

    private func nextGlobalLockResult() -> Result<Bool, Error> {
        if !globalLockResults.isEmpty {
            return globalLockResults.removeFirst()
        }
        return .success(false)
    }
}

@MainActor
private final class DeviceApplicationStateServiceSpy: DeviceApplicationStateServicing {
    private(set) var requests: [String] = []
    private var results: [Result<DeviceApplicationStateFetchResult, Error>]

    init(results: [Result<DeviceApplicationStateFetchResult, Error>] = []) {
        self.results = results
    }

    func fetchState(dsn: String) async throws -> DeviceApplicationStateFetchResult {
        requests.append(dsn)
        if !results.isEmpty {
            return try results.removeFirst().get()
        }
        return DeviceApplicationStateFetchResult(
            deviceID: 1,
            applicationsEndpoint: "members/device/v2/1/applications",
            lockedEndpoint: "-",
            applications: [],
            lockedApplications: []
        )
    }
}

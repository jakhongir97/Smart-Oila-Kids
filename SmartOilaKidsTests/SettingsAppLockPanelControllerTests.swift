import AVFAudio
import AVFoundation
import CoreLocation
import UIKit
import UserNotifications
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

@MainActor
final class SettingsViewModelLoadingTests: XCTestCase {
    func testLoadIfNeededUsesMatchedDeviceNameAndSkipsProfileFetch() async {
        let service = SettingsServiceSpy(
            fetchConnectedDevicesResults: [
                .success([ConnectedDevice(id: 1, dsn: "child-1", name: "Kid Remote", avatarURL: nil)])
            ],
            fetchProfileNameResult: .success("Parent Remote")
        )
        let cacheStore = SettingsCacheStoreSpy(
            cachedProfileName: "Cached Parent",
            cachedDevices: [ConnectedDevice(id: 1, dsn: " child-1 ", name: "Kid Cached", avatarURL: nil)]
        )
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)

        await viewModel.loadIfNeeded(currentDSN: " child-1 ")

        XCTAssertEqual(service.fetchConnectedDevicesCalls, 1)
        XCTAssertEqual(service.fetchProfileNameCalls, 0)
        XCTAssertEqual(viewModel.remoteProfileName, "Kid Remote")
        XCTAssertEqual(viewModel.connectedDevices.first?.name, "Kid Remote")
        XCTAssertEqual(cacheStore.savedConnectedDevicesSnapshots.last?.first?.name, "Kid Remote")
    }

    func testLoadIfNeededUsesProfileEndpointWhenNoMatchingDeviceExists() async {
        let service = SettingsServiceSpy(
            fetchConnectedDevicesResults: [
                .success([ConnectedDevice(id: 2, dsn: "other-child", name: "Sibling", avatarURL: nil)])
            ],
            fetchProfileNameResult: .success("Parent Remote")
        )
        let cacheStore = SettingsCacheStoreSpy()
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)

        await viewModel.loadIfNeeded(currentDSN: "child-1")

        XCTAssertEqual(service.fetchConnectedDevicesCalls, 1)
        XCTAssertEqual(service.fetchProfileNameCalls, 1)
        XCTAssertEqual(viewModel.remoteProfileName, "Parent Remote")
        XCTAssertEqual(cacheStore.savedProfileNames.last, "Parent Remote")
    }

    func testLoadIfNeededSkipsDuplicateLoadForSameDSN() async {
        let service = SettingsServiceSpy(
            fetchConnectedDevicesResults: [
                .success([ConnectedDevice(id: 1, dsn: "child-1", name: "Kid", avatarURL: nil)])
            ],
            fetchProfileNameResult: .success("Parent Remote")
        )
        let viewModel = SettingsViewModel(service: service, cacheStore: SettingsCacheStoreSpy())

        await viewModel.loadIfNeeded(currentDSN: "child-1")
        await viewModel.loadIfNeeded(currentDSN: " child-1 ")

        XCTAssertEqual(service.fetchConnectedDevicesCalls, 1)
    }

    func testEnsureConnectedDevicesLoadedIfNeededRequiredThrowsOnFailure() async {
        let failure = NetworkError.server(statusCode: 500, body: "")
        let service = SettingsServiceSpy(
            fetchConnectedDevicesResults: [.failure(failure)]
        )
        let viewModel = SettingsViewModel(service: service, cacheStore: SettingsCacheStoreSpy())

        do {
            try await viewModel.ensureConnectedDevicesLoadedIfNeeded(required: true)
            XCTFail("Expected required device loading to throw")
        } catch {
            XCTAssertEqual(NetworkError.userMessage(for: error), NetworkError.userMessage(for: failure))
        }

        XCTAssertFalse(viewModel.runtime.hasLoadedRemoteDeviceNames)
        XCTAssertTrue(viewModel.connectedDevices.isEmpty)
    }

    func testEnsureConnectedDevicesLoadedIfNeededOptionalSwallowsFailure() async {
        let service = SettingsServiceSpy(
            fetchConnectedDevicesResults: [.failure(NetworkError.server(statusCode: 500, body: ""))]
        )
        let viewModel = SettingsViewModel(service: service, cacheStore: SettingsCacheStoreSpy())

        do {
            try await viewModel.ensureConnectedDevicesLoadedIfNeeded(required: false)
        } catch {
            XCTFail("Optional loading should not throw")
        }

        XCTAssertFalse(viewModel.runtime.hasLoadedRemoteDeviceNames)
        XCTAssertTrue(viewModel.connectedDevices.isEmpty)
    }
}

@MainActor
final class MainViewModelDashboardTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "DSN")
    }

    func testLoadWeeklyUsageWithoutDSNResetsStateAndShowsMissingDSN() async {
        let viewModel = makeViewModel()
        viewModel.setCurrentDeviceName("Kid")
        viewModel.setDeviceStatus(
            MainDeviceStatus(
                deviceName: "Kid",
                battery: 80,
                connectionType: "wifi",
                soundMode: "normal",
                latitude: 41.0,
                longitude: 69.0
            )
        )
        viewModel.setPendingTasksCount(2)
        viewModel.setUnreadChatCount(4)
        viewModel.setUnreadNotificationCount(3)
        viewModel.setRecentDeviceControlItems([
            PushInboxItem(
                id: "device-control",
                title: "Lock",
                body: "Body",
                event: "device_control_lock",
                dsn: "child-1",
                receivedAt: .init(timeIntervalSince1970: 10),
                isRead: false,
                fingerprint: "device-control"
            )
        ])

        await viewModel.loadWeeklyUsage(dsn: nil)

        XCTAssertEqual(viewModel.usagePhase, .failed(L10n.tr("common.dsn_missing")))
        XCTAssertNil(viewModel.currentDeviceName)
        XCTAssertNil(viewModel.deviceStatus)
        XCTAssertNil(viewModel.pendingTasksCount)
        XCTAssertNil(viewModel.unreadChatCount)
        XCTAssertEqual(viewModel.unreadNotificationCount, 0)
        XCTAssertTrue(viewModel.recentDeviceControlItems.isEmpty)
        XCTAssertTrue(viewModel.recentMediaItems.isEmpty)
    }

    func testLoadWeeklyUsageUsesZeroFallbackForUnauthorizedUsage() async {
        let dashboardService = MainDashboardServiceSpy(
            weeklyUsageResult: .failure(NetworkError.server(statusCode: 401, body: "")),
            currentDeviceNameResult: .success("Unused Fallback"),
            deviceStatusResult: .success(
                MainDeviceStatus(
                    deviceName: "Kid Remote",
                    battery: 71,
                    connectionType: "wifi",
                    soundMode: "normal",
                    latitude: 41.3111,
                    longitude: 69.2797
                )
            )
        )
        let taskSummaryService = MainTaskSummaryServiceSpy(result: .success(3))
        let chatService = MainChatServiceSpy(historyResult: .success(makeChatMessagesModel(groupedMessages: [:])))
        let viewModel = makeViewModel(
            dashboardService: dashboardService,
            taskSummaryService: taskSummaryService,
            chatService: chatService
        )

        await viewModel.loadWeeklyUsage(dsn: "child-1")

        XCTAssertEqual(viewModel.weeklyUsageHours, Array(repeating: 0, count: 7))
        XCTAssertEqual(viewModel.usagePhase, .loaded)
        XCTAssertEqual(viewModel.currentDeviceName, "Kid Remote")
        XCTAssertEqual(viewModel.deviceStatus?.battery, 71)
        XCTAssertEqual(viewModel.pendingTasksCount, 3)
        XCTAssertEqual(viewModel.unreadChatCount, 0)
        XCTAssertEqual(dashboardService.fetchCurrentDeviceNameCalls, 0)
    }

    func testLoadWeeklyUsageFallsBackToCachedTaskAndChatDataAndBuildsNotificationTimelines() async {
        await PushInboxStore.shared.clearAll()
        let dashboardService = MainDashboardServiceSpy(
            weeklyUsageResult: .success([1, 2, 3, 4, 5, 6, 7]),
            currentDeviceNameResult: .success("Fallback Device"),
            deviceStatusResult: .failure(NetworkError.server(statusCode: 500, body: ""))
        )
        let chatHistory = [
            "2026-03-11": [
                Datum(userType: "parent", text: "Older", attachments: [], time: "2026-03-11T09:00:00Z"),
                Datum(userType: "parent", text: "Newer", attachments: [], time: "2026-03-11T11:00:00Z"),
                Datum(userType: "child", text: "Reply", attachments: [], time: "2026-03-11T11:30:00Z")
            ]
        ]
        let viewModel = makeViewModel(
            dashboardService: dashboardService,
            taskSummaryService: MainTaskSummaryServiceSpy(
                result: .failure(NetworkError.server(statusCode: 503, body: ""))
            ),
            chatService: MainChatServiceSpy(
                historyResult: .failure(NetworkError.server(statusCode: 503, body: ""))
            ),
            chatReadStateStore: MainChatReadStateStoreSpy(lastReadTimestamp: "2026-03-11T10:00:00Z"),
            chatHistoryStore: MainChatHistoryStoreSpy(history: ["child-1": chatHistory]),
            taskCacheStore: MainTaskCacheStoreSpy(
                awardsByDSN: ["child-1": [makePendingAward(awardID: 7, unfinishedTaskIDs: [701, 702])]]
            )
        )

        await PushInboxStore.shared.append(
            title: "Lock",
            body: "Device locked",
            event: "device_control_lock",
            dsn: "child-1",
            isRead: false,
            receivedAt: .init(timeIntervalSince1970: 100)
        )
        await PushInboxStore.shared.append(
            title: "Audio",
            body: "Audio ready",
            event: "media_audio",
            dsn: "child-1",
            isRead: false,
            receivedAt: .init(timeIntervalSince1970: 200)
        )
        await PushInboxStore.shared.append(
            title: "Camera",
            body: "Camera ready",
            event: "media_camera",
            dsn: "child-1",
            isRead: false,
            receivedAt: .init(timeIntervalSince1970: 300)
        )

        await viewModel.loadWeeklyUsage(dsn: "child-1")

        XCTAssertEqual(viewModel.weeklyUsageHours, [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(viewModel.usagePhase, .loaded)
        XCTAssertNil(viewModel.deviceStatus)
        XCTAssertEqual(viewModel.currentDeviceName, "Fallback Device")
        XCTAssertEqual(viewModel.pendingTasksCount, 2)
        XCTAssertEqual(viewModel.unreadChatCount, 1)
        XCTAssertEqual(viewModel.unreadNotificationCount, 3)
        XCTAssertEqual(viewModel.recentDeviceControlItems.map(\.event), ["device_control_lock"])
        XCTAssertEqual(viewModel.recentMediaItems.map(\.event), ["media_camera", "media_audio"])

        await PushInboxStore.shared.clearAll()
    }

    private func makeViewModel(
        dashboardService: MainDashboardServicing = MainDashboardServiceSpy(),
        taskSummaryService: TaskSummaryServicing = MainTaskSummaryServiceSpy(),
        chatService: ChatServicing = MainChatServiceSpy(),
        chatReadStateStore: ChatReadStateStoring = MainChatReadStateStoreSpy(),
        chatHistoryStore: ChatHistoryCaching = MainChatHistoryStoreSpy(),
        taskCacheStore: TaskCacheStoring = MainTaskCacheStoreSpy()
    ) -> MainViewModel {
        MainViewModel(
            sosService: NoopSOSService(),
            dashboardService: dashboardService,
            taskSummaryService: taskSummaryService,
            chatService: chatService,
            chatReadStateStore: chatReadStateStore,
            chatHistoryStore: chatHistoryStore,
            taskCacheStore: taskCacheStore
        )
    }

    private func makePendingAward(awardID: Int, unfinishedTaskIDs: [Int]) -> AwardsResponse {
        AwardsResponse(
            awardID: awardID,
            name: "Award \(awardID)",
            imageURL: nil,
            neededPoints: 100,
            isCompleted: unfinishedTaskIDs.isEmpty,
            collectedCoins: 0,
            tasks: unfinishedTaskIDs.map {
                TaskItem(taskID: $0, name: "Task \($0)", isFinished: false, pointsAmount: 10)
            }
        )
    }
}

@MainActor
final class MainViewModelSOSTests: XCTestCase {
    func testSendSOSShowsMissingBindingAlertWithoutDSN() async {
        let sosService = SOSServiceSpy()
        let viewModel = makeViewModel(sosService: sosService)

        await viewModel.sendSOS(dsn: nil)

        XCTAssertEqual(viewModel.sosBanner?.text, L10n.tr("main.device_not_bound"))
        XCTAssertEqual(viewModel.sosBanner?.tone, .error)
        XCTAssertFalse(viewModel.isSendingSOS)
        let recordedCalls = await sosService.recordedCalls()
        XCTAssertTrue(recordedCalls.isEmpty)
    }

    func testSendSOSUpdatesAlertWhenRequestSucceeds() async {
        let sosService = SOSServiceSpy()
        let viewModel = makeViewModel(sosService: sosService)

        await viewModel.sendSOS(dsn: "child-sos-1")

        XCTAssertEqual(viewModel.sosBanner?.text, L10n.tr("main.sos_sent"))
        XCTAssertEqual(viewModel.sosBanner?.tone, .success)
        XCTAssertFalse(viewModel.isSendingSOS)
        let recordedCalls = await sosService.recordedCalls()
        XCTAssertEqual(recordedCalls, ["child-sos-1"])
    }

    func testSendSOSUsesNetworkUserMessageWhenRequestFails() async {
        let error = URLError(.notConnectedToInternet)
        let sosService = SOSServiceSpy(results: [.failure(error)])
        let viewModel = makeViewModel(sosService: sosService)

        await viewModel.sendSOS(dsn: "child-sos-2")

        XCTAssertEqual(viewModel.sosBanner?.text, NetworkError.userMessage(for: error))
        XCTAssertEqual(viewModel.sosBanner?.tone, .error)
        XCTAssertFalse(viewModel.isSendingSOS)
        let recordedCalls = await sosService.recordedCalls()
        XCTAssertEqual(recordedCalls, ["child-sos-2"])
    }

    func testSendSOSIgnoresSecondRequestWhileFirstIsInFlight() async {
        let sosService = SOSServiceSpy(suspendFirstCall: true)
        let viewModel = makeViewModel(sosService: sosService)

        let first = Task {
            await viewModel.sendSOS(dsn: "child-sos-3")
        }

        await waitForSOSCallCount(sosService, count: 1)
        XCTAssertTrue(viewModel.isSendingSOS)

        await viewModel.sendSOS(dsn: "child-sos-3")
        let inFlightCalls = await sosService.recordedCalls()
        XCTAssertEqual(inFlightCalls, ["child-sos-3"])

        await sosService.resumeSuspendedCallIfNeeded()
        _ = await first.result

        XCTAssertEqual(viewModel.sosBanner?.text, L10n.tr("main.sos_sent"))
        XCTAssertEqual(viewModel.sosBanner?.tone, .success)
        XCTAssertFalse(viewModel.isSendingSOS)
    }

    private func makeViewModel(sosService: SOSServicing) -> MainViewModel {
        MainViewModel(
            sosService: sosService,
            dashboardService: MainDashboardServiceSpy(),
            taskSummaryService: MainTaskSummaryServiceSpy(),
            chatService: MainChatServiceSpy()
        )
    }
}

final class MainDashboardWeekRangeTests: XCTestCase {
    func testCurrentWeekRangeStartsOnMondayAndBuildsOrderedIndex() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let range = MainDashboardWeekRange.current(using: calendar)

        XCTAssertEqual(range.orderedDateStrings.count, 7)
        XCTAssertEqual(Set(range.orderedDateStrings).count, 7)
        XCTAssertEqual(range.dateIndex.count, 7)
        XCTAssertEqual(calendar.component(.weekday, from: range.start), 2)
        XCTAssertEqual(apiDateFormatter.string(from: range.start), range.orderedDateStrings.first)
        XCTAssertEqual(apiDateFormatter.string(from: range.end), range.orderedDateStrings.last)
        XCTAssertEqual(calendar.dateComponents([.day], from: range.start, to: range.end).day, 6)
        XCTAssertEqual(range.dateIndex[range.orderedDateStrings[3]], 3)
    }
}

final class MainDashboardLocationLogParserTests: XCTestCase {
    func testLatestLocationSupportsTopLevelAndNestedPayloadShapes() {
        let parser = MainDashboardLocationLogParser()

        let direct = parser.latestLocation(
            from: try! JSONSerialization.data(withJSONObject: [["latitude": 41.31, "longitude": 69.24]])
        )
        let dataNested = parser.latestLocation(
            from: try! JSONSerialization.data(withJSONObject: [["data": ["latitude": "41.11", "longitude": "69.22"]]])
        )
        let payloadNested = parser.latestLocation(
            from: try! JSONSerialization.data(withJSONObject: [["payload": ["latitude": 41.5, "longitude": 69.6]]])
        )
        let locationNested = parser.latestLocation(
            from: try! JSONSerialization.data(withJSONObject: [["location": ["lat": "41.7", "lng": "69.8"]]])
        )
        let pointNested = parser.latestLocation(
            from: try! JSONSerialization.data(withJSONObject: [["point": ["lat": 41.9, "lon": 70.0]]])
        )

        XCTAssertEqual(direct?.latitude, 41.31)
        XCTAssertEqual(direct?.longitude, 69.24)
        XCTAssertEqual(dataNested?.latitude, 41.11)
        XCTAssertEqual(dataNested?.longitude, 69.22)
        XCTAssertEqual(payloadNested?.latitude, 41.5)
        XCTAssertEqual(payloadNested?.longitude, 69.6)
        XCTAssertEqual(locationNested?.latitude, 41.7)
        XCTAssertEqual(locationNested?.longitude, 69.8)
        XCTAssertEqual(pointNested?.latitude, 41.9)
        XCTAssertEqual(pointNested?.longitude, 70.0)
    }

    func testLatestLocationSkipsInvalidNewestEntryAndReturnsPreviousValidLocation() {
        let parser = MainDashboardLocationLogParser()
        let payload = try! JSONSerialization.data(withJSONObject: [
            ["latitude": 40.0, "longitude": 70.0],
            ["latitude": "", "longitude": NSNull()]
        ])

        let location = parser.latestLocation(from: payload)

        XCTAssertEqual(location?.latitude, 40.0)
        XCTAssertEqual(location?.longitude, 70.0)
    }

    func testLatestLocationReturnsNilForInvalidPayload() {
        let parser = MainDashboardLocationLogParser()

        XCTAssertNil(parser.latestLocation(from: Data("not-json".utf8)))
        XCTAssertNil(parser.latestLocation(from: try! JSONSerialization.data(withJSONObject: [["foo": "bar"]])))
    }
}

final class MainDashboardRemoteDataSourceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testResolveCurrentDeviceRejectsBlankDSN() async {
        let dataSource = makeMainDashboardRemoteDataSourceForTests()

        do {
            _ = try await dataSource.resolveCurrentDevice(for: "   ") { _ in }
            XCTFail("Expected unexpectedBody")
        } catch NetworkError.unexpectedBody {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testResolveCurrentDeviceMatchesTrimmedCaseInsensitiveDSN() async throws {
        let devices = MemberDevicesSequenceStub(fetchDevicesResults: [
            .success([
                MemberDeviceRecord(id: 11, dsn: " Child-11 ", name: "Kid Eleven", avatarURL: nil)
            ])
        ])
        let dataSource = makeMainDashboardRemoteDataSourceForTests(memberDevicesService: devices)

        let device = try await dataSource.resolveCurrentDevice(for: " child-11 ") { _ in }

        XCTAssertEqual(device.id, 11)
        XCTAssertEqual(device.name, "Kid Eleven")
        XCTAssertEqual(devices.fetchLimits, [100])
    }

    func testResolveCurrentDeviceRetriesUntilDeviceAppears() async throws {
        let devices = MemberDevicesSequenceStub(fetchDevicesResults: [
            .success([]),
            .success([
                MemberDeviceRecord(id: 15, dsn: "CHILD-15", name: "Kid Fifteen", avatarURL: nil)
            ])
        ])
        let dataSource = makeMainDashboardRemoteDataSourceForTests(memberDevicesService: devices)
        var debugMessages: [String] = []

        let device = try await dataSource.resolveCurrentDevice(for: "child-15") { debugMessages.append($0) }

        XCTAssertEqual(device.id, 15)
        XCTAssertEqual(devices.fetchLimits, [100, 100])
        XCTAssertEqual(
            debugMessages,
            ["Device DSN child-15 not visible in member list yet. Retry 2/3."]
        )
    }

    func testFetchWeeklyUsageHoursUsesV2LogsAndAggregatesMatchingDates() async throws {
        let week = makeMainDashboardWeekRange(startingAt: "2026-03-09")
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/devices/v2/55/logs")

            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(queryItems.first(where: { $0.name == "date_from" })?.value, "2026-03-09")
            XCTAssertEqual(queryItems.first(where: { $0.name == "date_to" })?.value, "2026-03-15")
            XCTAssertEqual(queryItems.first(where: { $0.name == "all_records" })?.value, "true")

            let payload = #"""
            [
              { "date": "2026-03-09", "duration": 3600 },
              { "date": "2026-03-09", "duration": "1800" },
              { "date": "2026-03-12", "duration": 7200 },
              { "date": "2026-04-01", "duration": 600 },
              { "date": "2026-03-10", "duration": 0 }
            ]
            """#.data(using: .utf8)!

            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let dataSource = makeMainDashboardRemoteDataSourceForTests(accessToken: "Bearer access")
        let hours = try await dataSource.fetchWeeklyUsageHours(deviceID: 55, week: week)

        XCTAssertEqual(hours, [1.5, 0, 0, 2, 0, 0, 0])
    }

    func testFetchWeeklyUsageHoursFallsBackToLegacyEndpointAfter404() async throws {
        let week = makeMainDashboardWeekRange(startingAt: "2026-03-09")
        TestHTTPURLProtocol.requestHandler = { request in
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []

            if request.url?.path == "/api/devices/v2/55/logs" {
                XCTAssertEqual(queryItems.first(where: { $0.name == "all_records" })?.value, "true")
                return (makeHTTPResponse(for: request.url!, statusCode: 404), Data())
            }

            XCTAssertEqual(request.url?.path, "/api/devices/55/logs")
            XCTAssertNil(queryItems.first(where: { $0.name == "all_records" }))
            let payload = #"""
            [
              { "date": "2026-03-10", "duration": 5400 }
            ]
            """#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let dataSource = makeMainDashboardRemoteDataSourceForTests(accessToken: "Bearer access")
        let hours = try await dataSource.fetchWeeklyUsageHours(deviceID: 55, week: week)

        XCTAssertEqual(hours, [0, 1.5, 0, 0, 0, 0, 0])
        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.map { $0.url?.path }, [
            "/api/devices/v2/55/logs",
            "/api/devices/55/logs"
        ])
    }

    func testFetchSystemInfoDecodesPayload() async {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/devices/77/system_info")
            let payload = #"{"battery":"82","connect":"wifi","sound_mode":"silent"}"#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let dataSource = makeMainDashboardRemoteDataSourceForTests(accessToken: "Bearer access")
        let payload = await dataSource.fetchSystemInfo(deviceID: 77)

        XCTAssertEqual(payload?.battery, 82)
        XCTAssertEqual(payload?.connect, "wifi")
        XCTAssertEqual(payload?.soundMode, "silent")
    }

    func testFetchSystemInfoReturnsNilForForbiddenResponse() async {
        TestHTTPURLProtocol.requestHandler = { request in
            (makeHTTPResponse(for: request.url!, statusCode: 403), Data())
        }

        let dataSource = makeMainDashboardRemoteDataSourceForTests(accessToken: "Bearer access")
        let payload = await dataSource.fetchSystemInfo(deviceID: 77)

        XCTAssertNil(payload)
    }

    func testFetchCurrentLocationFallsBackToLatestLocationLogWhenDirectEndpointFails() async {
        TestHTTPURLProtocol.requestHandler = { request in
            if request.url?.path == "/api/devices/88/current-location" {
                return (makeHTTPResponse(for: request.url!, statusCode: 404), Data())
            }

            XCTAssertEqual(request.url?.path, "/api/devices/v2/88/logs")
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(queryItems.first(where: { $0.name == "log_type" })?.value, "gps-point")

            let payload = #"""
            [
              { "location": { "lat": "41.3000", "lng": "69.2000" } },
              { "payload": { "latitude": "41.3111", "longitude": "69.2797" } }
            ]
            """#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let dataSource = makeMainDashboardRemoteDataSourceForTests(accessToken: "Bearer access")
        let location = await dataSource.fetchCurrentLocation(deviceID: 88)

        XCTAssertEqual(location?.latitude, 41.3111)
        XCTAssertEqual(location?.longitude, 69.2797)
        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.map { $0.url?.path }, [
            "/api/devices/88/current-location",
            "/api/devices/v2/88/logs"
        ])
    }
}

@MainActor
final class MainDashboardServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testServiceMethodsRejectBlankDSN() async {
        let suiteName = "MainDashboardServiceBlankDSNTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let service = MainDashboardService(
            client: makeTestAPIClient(accessToken: "Bearer access"),
            memberDevicesService: MemberDevicesSequenceStub(),
            userDefaults: userDefaults
        )

        do {
            _ = try await service.fetchWeeklyUsageHours(dsn: "   ")
            XCTFail("Expected unexpectedBody")
        } catch NetworkError.unexpectedBody {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await service.fetchCurrentDeviceName(dsn: "\n")
            XCTFail("Expected unexpectedBody")
        } catch NetworkError.unexpectedBody {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await service.fetchDeviceStatus(dsn: "\t")
            XCTFail("Expected unexpectedBody")
        } catch NetworkError.unexpectedBody {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchWeeklyUsageHoursCachesRemoteResultAndFallsBackToCacheAfterFailure() async throws {
        let suiteName = "MainDashboardServiceWeeklyUsageTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let week = MainDashboardWeekRange.current(using: calendar)

        let device = MemberDeviceRecord(id: 44, dsn: "child-44", name: "Kid Forty Four", avatarURL: nil)
        let memberDevices = MemberDevicesSequenceStub(fetchDevicesResults: [
            .success([device]),
            .success([device])
        ])
        let service = MainDashboardService(
            client: makeTestAPIClient(accessToken: "Bearer access"),
            calendar: calendar,
            memberDevicesService: memberDevices,
            userDefaults: userDefaults
        )

        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/devices/v2/44/logs")
            let payload = try! JSONSerialization.data(withJSONObject: [
                ["date": week.orderedDateStrings[0], "duration": 1800],
                ["date": week.orderedDateStrings[2], "duration": 7200],
                ["date": week.orderedDateStrings[2], "duration": 1800]
            ])
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let first = try await service.fetchWeeklyUsageHours(dsn: " child-44 ")

        XCTAssertEqual(first, [0.5, 0, 2.5, 0, 0, 0, 0])
        XCTAssertEqual(MainDashboardCacheStore(userDefaults: userDefaults).weeklyUsage(for: "child-44"), first)

        TestHTTPURLProtocol.reset()
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/devices/v2/44/logs")
            return (makeHTTPResponse(for: request.url!, statusCode: 500), Data("server".utf8))
        }

        let second = try await service.fetchWeeklyUsageHours(dsn: "child-44")

        XCTAssertEqual(second, first)
        XCTAssertEqual(memberDevices.fetchLimits, [100, 100])
    }

    func testFetchCurrentDeviceNameReturnsTrimmedRemoteNameAndFallsBackWhenRemoteNameMissing() async throws {
        let remoteSuiteName = "MainDashboardServiceRemoteNameTests.\(UUID().uuidString)"
        let remoteDefaults = UserDefaults(suiteName: remoteSuiteName)!
        defer { remoteDefaults.removePersistentDomain(forName: remoteSuiteName) }

        let remoteService = MainDashboardService(
            client: makeTestAPIClient(accessToken: "Bearer access"),
            memberDevicesService: MemberDevicesSequenceStub(fetchDevicesResults: [
                .success([MemberDeviceRecord(id: 45, dsn: "child-45", name: " Kid Forty Five ", avatarURL: nil)])
            ]),
            userDefaults: remoteDefaults
        )

        let remoteName = try await remoteService.fetchCurrentDeviceName(dsn: " child-45 ")

        XCTAssertEqual(remoteName, "Kid Forty Five")

        let fallbackSuiteName = "MainDashboardServiceFallbackNameTests.\(UUID().uuidString)"
        let fallbackDefaults = UserDefaults(suiteName: fallbackSuiteName)!
        defer { fallbackDefaults.removePersistentDomain(forName: fallbackSuiteName) }

        let fallbackService = MainDashboardService(
            client: makeTestAPIClient(accessToken: "Bearer access"),
            memberDevicesService: MemberDevicesSequenceStub(fetchDevicesResults: [
                .success([MemberDeviceRecord(id: 45, dsn: "child-45", name: "   ", avatarURL: nil)])
            ]),
            userDefaults: fallbackDefaults
        )

        let fallbackName = try await fallbackService.fetchCurrentDeviceName(dsn: "child-45")

        XCTAssertEqual(fallbackName.trimmingCharacters(in: .whitespacesAndNewlines), fallbackName)
        XCTAssertFalse(fallbackName.isEmpty)
    }

    func testFetchDeviceStatusUsesRemotePayloadAndFallsBackToCachedStatus() async throws {
        let suiteName = "MainDashboardServiceStatusTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let remoteService = MainDashboardService(
            client: makeTestAPIClient(accessToken: "Bearer access"),
            memberDevicesService: MemberDevicesSequenceStub(fetchDevicesResults: [
                .success([MemberDeviceRecord(id: 46, dsn: "child-46", name: " Kid Forty Six ", avatarURL: nil)])
            ]),
            userDefaults: userDefaults
        )

        TestHTTPURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/devices/46/system_info":
                let payload = #"{"battery":"82","connect":" wifi ","sound_mode":" silent "}"#.data(using: .utf8)!
                return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
            case "/api/devices/46/current-location":
                let payload = #"{"latitude":"41.3111","longitude":"69.2797"}"#.data(using: .utf8)!
                return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "<nil>")")
                return (makeHTTPResponse(for: request.url!, statusCode: 404), Data())
            }
        }

        let remoteStatus = try await remoteService.fetchDeviceStatus(dsn: " child-46 ")

        XCTAssertEqual(remoteStatus.deviceName, "Kid Forty Six")
        XCTAssertEqual(remoteStatus.battery, 82)
        XCTAssertEqual(remoteStatus.connectionType, "wifi")
        XCTAssertEqual(remoteStatus.soundMode, "silent")
        XCTAssertEqual(remoteStatus.latitude ?? 0, 41.3111, accuracy: 0.0001)
        XCTAssertEqual(remoteStatus.longitude ?? 0, 69.2797, accuracy: 0.0001)
        XCTAssertEqual(MainDashboardCacheStore(userDefaults: userDefaults).status(for: "child-46")?.deviceName, "Kid Forty Six")

        TestHTTPURLProtocol.reset()

        let cachedService = MainDashboardService(
            client: makeTestAPIClient(accessToken: "Bearer access"),
            memberDevicesService: MemberDevicesSequenceStub(fetchDevicesResults: [
                .failure(NetworkError.server(statusCode: 500, body: ""))
            ]),
            userDefaults: userDefaults
        )

        let cachedStatus = try await cachedService.fetchDeviceStatus(dsn: "child-46")

        XCTAssertEqual(cachedStatus.deviceName, "Kid Forty Six")
        XCTAssertEqual(cachedStatus.battery, 82)
        XCTAssertEqual(cachedStatus.connectionType, "wifi")
        XCTAssertEqual(cachedStatus.soundMode, "silent")
        XCTAssertEqual(cachedStatus.latitude ?? 0, 41.3111, accuracy: 0.0001)
        XCTAssertEqual(cachedStatus.longitude ?? 0, 69.2797, accuracy: 0.0001)
    }
}

final class MainDashboardCacheStoreTests: XCTestCase {
    func testSaveWeeklyUsageNormalizesLengthAndNegativeValues() {
        let suiteName = "MainDashboardCacheStoreWeeklyUsageTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = MainDashboardCacheStore(userDefaults: userDefaults)

        store.saveWeeklyUsage([-1, 1, 2, 3, 4, 5, 6, 7], for: " child/1 ")

        XCTAssertEqual(store.weeklyUsage(for: "child/1"), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertNil(store.weeklyUsage(for: "other-child"))
    }

    func testStatusRoundTripAndInvalidPayloadsReturnNil() {
        let suiteName = "MainDashboardCacheStoreStatusTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = MainDashboardCacheStore(userDefaults: userDefaults)
        let status = MainDeviceStatus(
            deviceName: "Kid Cache",
            battery: 57,
            connectionType: "wifi",
            soundMode: "normal",
            latitude: 41.3,
            longitude: 69.2
        )

        store.saveStatus(status, for: " child.2 ")

        let loaded = store.status(for: "child.2")
        XCTAssertEqual(loaded?.deviceName, "Kid Cache")
        XCTAssertEqual(loaded?.battery, 57)
        XCTAssertEqual(loaded?.connectionType, "wifi")
        XCTAssertEqual(loaded?.soundMode, "normal")
        XCTAssertEqual(loaded?.latitude ?? 0, 41.3, accuracy: 0.0001)
        XCTAssertEqual(loaded?.longitude ?? 0, 69.2, accuracy: 0.0001)

        let statusKey = DSNScopedStorage.userDefaultsKey(prefix: "MAIN_DEVICE_STATUS_CACHE_", dsn: "child.2")
        userDefaults.set(Data("broken".utf8), forKey: statusKey)
        XCTAssertNil(store.status(for: "child.2"))

        let weeklyUsageKey = DSNScopedStorage.userDefaultsKey(prefix: "MAIN_WEEKLY_USAGE_CACHE_", dsn: "child.2")
        userDefaults.set(Data("broken".utf8), forKey: weeklyUsageKey)
        XCTAssertNil(store.weeklyUsage(for: "child.2"))
    }
}

final class PushDeepLinkStoreTests: XCTestCase {
    func testSaveConsumesMatchingDSNCaseInsensitivelyAndClearsAfterConsumption() async {
        let suiteName = "PushDeepLinkStoreConsumeTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        await MainActor.run { RuntimeDiagnosticsCenter.shared.resetPush() }

        let store = PushDeepLinkStore(userDefaults: userDefaults)

        await store.save(destination: .chat, dsn: " Child-1 ")
        let savedDiagnostics = await waitForPushDiagnosticsForTests {
            $0.pendingDeepLink == "chat" && $0.pendingDeepLinkDSN == "Child-1"
        }
        XCTAssertEqual(savedDiagnostics.pendingDeepLink, "chat")
        XCTAssertEqual(savedDiagnostics.pendingDeepLinkDSN, "Child-1")

        let consumed = await store.consume(matching: "child-1")
        XCTAssertEqual(consumed, .chat)
        let consumedDiagnostics = await waitForPushDiagnosticsForTests {
            $0.pendingDeepLink == "-" && $0.pendingDeepLinkDSN == "-"
        }
        XCTAssertEqual(consumedDiagnostics.pendingDeepLink, "-")
        XCTAssertEqual(consumedDiagnostics.pendingDeepLinkDSN, "-")

        let cleared = await store.consume(matching: "child-1")
        XCTAssertNil(cleared)
    }

    func testConsumeMismatchKeepsPendingLinkUntilMatchingDSNArrives() async {
        let suiteName = "PushDeepLinkStoreMismatchTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = PushDeepLinkStore(userDefaults: userDefaults)

        await store.save(destination: .tasks, dsn: "child-2")

        let mismatched = await store.consume(matching: "child-1")
        XCTAssertNil(mismatched)

        let matched = await store.consume(matching: " CHILD-2 ")
        XCTAssertEqual(matched, .tasks)
    }

    func testConsumeClearsExpiredDeepLink() async {
        let suiteName = "PushDeepLinkStoreExpiryTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set(stalePushDeepLinkPayloadData(destination: .chat, dsn: "child-3"), forKey: "PUSH_PENDING_DEEPLINK")
        let store = PushDeepLinkStore(userDefaults: userDefaults)

        let consumed = await store.consume(matching: "child-3")
        XCTAssertNil(consumed)
        XCTAssertNil(userDefaults.data(forKey: "PUSH_PENDING_DEEPLINK"))
    }

    func testClearMatchingClearsWildcardAndMatchingPayloadsOnly() async {
        let suiteName = "PushDeepLinkStoreClearTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = PushDeepLinkStore(userDefaults: userDefaults)

        await store.save(destination: .chat, dsn: nil)
        await store.clear(matching: "child-1")
        let clearedWildcard = await store.consume(matching: "child-1")
        XCTAssertNil(clearedWildcard)

        await store.save(destination: .tasks, dsn: "child-2")
        await store.clear(matching: "child-1")
        let retained = await store.consume(matching: "child-2")
        XCTAssertEqual(retained, .tasks)

        await store.save(destination: .chat, dsn: " child-3 ")
        await store.clear(matching: "CHILD-3")
        let clearedMatching = await store.consume(matching: "child-3")
        XCTAssertNil(clearedMatching)

        await store.save(destination: .tasks, dsn: "child-4")
        await store.clear(matching: nil)
        let clearedAll = await store.consume(matching: "child-4")
        XCTAssertNil(clearedAll)
    }
}

final class PushCommandRouterPayloadTests: XCTestCase {
    func testParsePayloadUsesDirectFieldsAndStringAlert() {
        let payload = PushCommandRouter.parsePayload(from: [
            "event": " MESSAGE_NEW ",
            "dsn": " child-1 ",
            "aps": [
                "alert": "  Hello from parent  "
            ]
        ])

        XCTAssertEqual(payload.event, "message_new")
        XCTAssertEqual(payload.dsn, "child-1")
        XCTAssertNil(payload.title)
        XCTAssertEqual(payload.body, "Hello from parent")
        XCTAssertTrue(payload.routingHaystack.contains("message_new"))
        XCTAssertTrue(payload.routingHaystack.contains("hello from parent"))
    }

    func testParsePayloadUsesJSONStringPayloadForEventAndTopLevelAlertFallback() {
        let payload = PushCommandRouter.parsePayload(from: [
            "payload": #"{"type":" task_update ","children_device_dsn":" child-2 ","notification_title":" Tasks ","message":" Complete award "}"#
        ])

        XCTAssertEqual(payload.event, "task_update")
        XCTAssertEqual(payload.dsn, "child-2")
        XCTAssertEqual(payload.title, "Tasks")
        XCTAssertEqual(payload.body, "Complete award")
    }

    func testParsePayloadUsesAPSNestedPayloadAndLocKeyBody() {
        let payload = PushCommandRouter.parsePayload(from: [
            "aps": [
                "data": [
                    "command": "CHAT_MESSAGE",
                    "device_dsn": " child-3 "
                ],
                "alert": [
                    "title": " Parent ",
                    "loc-key": " Tap to open chat "
                ]
            ]
        ])

        XCTAssertEqual(payload.event, "chat_message")
        XCTAssertEqual(payload.dsn, "child-3")
        XCTAssertEqual(payload.title, "Parent")
        XCTAssertEqual(payload.body, "Tap to open chat")
    }

    func testParsePayloadSupportsAnyHashableNestedDictionaryAndNumericValues() {
        let nested: [AnyHashable: Any] = [
            AnyHashable("command"): NSNumber(value: 42),
            AnyHashable("child_dsn"): NSNumber(value: 123456),
            AnyHashable("alert"): " Locked by parent "
        ]

        let payload = PushCommandRouter.parsePayload(from: [
            "extra": nested
        ])

        XCTAssertEqual(payload.event, "42")
        XCTAssertEqual(payload.dsn, "123456")
        XCTAssertNil(payload.title)
        XCTAssertEqual(payload.body, "Locked by parent")
    }
}

final class PushCommandRouterTests: XCTestCase {
    func testHandleOpenedFromInteractionRoutesAllRelevantDomainsAndSavesChatDeepLink() async {
        await PushInboxStore.shared.clearAll()
        await PushDeepLinkStore.shared.clearAll()
        await MainActor.run { RuntimeDiagnosticsCenter.shared.resetPush() }
        defer {
            Task {
                await PushInboxStore.shared.clearAll()
                await PushDeepLinkStore.shared.clearAll()
            }
        }

        let names: [Notification.Name] = [
            .pushShouldRefreshDashboard,
            .pushShouldRefreshLockState,
            .pushShouldRefreshTasks,
            .pushShouldOpenTasks,
            .pushShouldRefreshChat,
            .pushShouldOpenChat
        ]
        var received: [Notification.Name] = []
        var receivedDSNs: [String] = []
        let tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notification in
                received.append(notification.name)
                receivedDSNs.append((notification.userInfo?[PushUserInfoKeys.dsn] as? String) ?? "")
            }
        }
        defer {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }

        PushCommandRouter.handle(
            userInfo: [
                "event": " message_task_lock ",
                "dsn": " child-5 ",
                "title": " Task message ",
                "body": " Location update and lock state "
            ],
            openedFromInteraction: true,
            deliveryContext: .userResponse
        )

        let items = await waitForPushInboxItemsMatchingDSNForTests(count: 1, dsn: "child-5")
        let diagnosticsBeforeConsume = await waitForPushDiagnosticsForTests {
            $0.pendingDeepLink == "chat"
                && $0.pendingDeepLinkDSN == "child-5"
                && $0.inboxTotalCount >= 1
                && $0.lastRoute.contains("chat_open")
        }
        let deepLink = await waitForPushDeepLinkForTests(dsn: "child-5")
        let diagnosticsAfterConsume = await waitForPushDiagnosticsForTests {
            $0.pendingDeepLink == "-" && $0.pendingDeepLinkDSN == "-"
        }

        XCTAssertEqual(Set(received), Set(names))
        XCTAssertTrue(receivedDSNs.allSatisfy { $0 == "child-5" })
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, "message_task_lock")
        XCTAssertEqual(items.first?.dsn, "child-5")
        XCTAssertTrue(items.first?.isRead ?? false)
        XCTAssertEqual(diagnosticsBeforeConsume.dsn, "child-5")
        XCTAssertEqual(diagnosticsBeforeConsume.deliveryContext, "user_response")
        XCTAssertEqual(diagnosticsBeforeConsume.lastEvent, "message_task_lock")
        XCTAssertTrue(diagnosticsBeforeConsume.lastRoute.contains("dashboard_refresh"))
        XCTAssertTrue(diagnosticsBeforeConsume.lastRoute.contains("lock_refresh"))
        XCTAssertTrue(diagnosticsBeforeConsume.lastRoute.contains("tasks_refresh"))
        XCTAssertTrue(diagnosticsBeforeConsume.lastRoute.contains("tasks_open"))
        XCTAssertTrue(diagnosticsBeforeConsume.lastRoute.contains("chat_refresh"))
        XCTAssertTrue(diagnosticsBeforeConsume.lastRoute.contains("chat_open"))
        XCTAssertEqual(diagnosticsBeforeConsume.pendingDeepLink, "chat")
        XCTAssertEqual(diagnosticsBeforeConsume.pendingDeepLinkDSN, "child-5")
        XCTAssertEqual(diagnosticsBeforeConsume.inboxTotalCount, 1)
        XCTAssertEqual(diagnosticsAfterConsume.pendingDeepLink, "-")
        XCTAssertEqual(diagnosticsAfterConsume.pendingDeepLinkDSN, "-")
        XCTAssertEqual(deepLink, .chat)
    }

    func testHandleBackgroundDeliveryPersistsUnreadInboxItemWithoutOpenDeepLink() async {
        await PushInboxStore.shared.clearAll()
        await PushDeepLinkStore.shared.clearAll()
        defer {
            Task {
                await PushInboxStore.shared.clearAll()
                await PushDeepLinkStore.shared.clearAll()
            }
        }

        var received: [Notification.Name] = []
        let refreshToken = NotificationCenter.default.addObserver(
            forName: .pushShouldRefreshTasks,
            object: nil,
            queue: nil
        ) { notification in
            received.append(notification.name)
            XCTAssertEqual(notification.userInfo?[PushUserInfoKeys.dsn] as? String, "child-6")
        }
        let openToken = NotificationCenter.default.addObserver(
            forName: .pushShouldOpenTasks,
            object: nil,
            queue: nil
        ) { notification in
            received.append(notification.name)
        }
        defer {
            NotificationCenter.default.removeObserver(refreshToken)
            NotificationCenter.default.removeObserver(openToken)
        }

        PushCommandRouter.handle(
            userInfo: [
                "event": " award_update ",
                "children_device_dsn": " child-6 ",
                "body": " New task assigned "
            ],
            openedFromInteraction: false,
            deliveryContext: .backgroundFetch
        )

        let items = await waitForPushInboxItemsMatchingDSNForTests(count: 1, dsn: "child-6")
        let diagnostics = await waitForPushDiagnosticsForTests {
            $0.dsn == "child-6" && $0.deliveryContext == "background_fetch"
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let deepLink = await PushDeepLinkStore.shared.consume(matching: "child-6")

        XCTAssertEqual(received, [.pushShouldRefreshTasks])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, "award_update")
        XCTAssertFalse(items.first?.isRead ?? true)
        XCTAssertEqual(diagnostics.deliveryContext, "background_fetch")
        XCTAssertEqual(diagnostics.lastRoute, "tasks_refresh")
        XCTAssertNil(deepLink)
    }
}

// MARK: - Recording trigger (push parsing + routing + lock policy)

final class PushRecordingCommandParsingTests: XCTestCase {
    func testParsesTriggerRecordingDtoFromNestedDataWithTolerantKeys() {
        let payload = PushCommandRouter.parsePayload(from: [
            "event": " trigger_recording ",
            "data": [
                "recordingId": " rec-42 ",
                "type": "Video",
                "durationSeconds": "45",
                "cameraType": "Front"
            ]
        ])

        let command = payload.recordingCommand
        XCTAssertEqual(command?.recordingID, "rec-42")
        XCTAssertEqual(command?.type, .video)
        XCTAssertEqual(command?.durationSeconds, 45)
        XCTAssertEqual(command?.cameraType, .front)
    }

    func testClampsOutOfRangeDurationAndDefaultsToAudioWhenTypeMissing() {
        let payload = PushCommandRouter.parsePayload(from: [
            "event": "record_audio",
            "recording_id": "rec-9",
            "duration": 9000
        ])

        let command = payload.recordingCommand
        XCTAssertEqual(command?.recordingID, "rec-9")
        XCTAssertEqual(command?.type, .audio)
        XCTAssertEqual(command?.durationSeconds, 300)
        XCTAssertNil(command?.cameraType)
    }

    func testInfersVideoTypeFromEventWhenTypeUnparseable() {
        let payload = PushCommandRouter.parsePayload(from: [
            "event": "record_video",
            "recordingId": "rec-v"
        ])

        XCTAssertEqual(payload.recordingCommand?.type, .video)
        XCTAssertEqual(payload.recordingCommand?.durationSeconds, PushRecordingCommand.defaultDurationSeconds)
    }

    func testReturnsNilWithoutRecordingIdEvenForRecordingEvent() {
        let payload = PushCommandRouter.parsePayload(from: [
            "event": "trigger_recording",
            "durationSeconds": 20
        ])

        XCTAssertNil(payload.recordingCommand)
    }
}

final class PushRecordingRoutingTests: XCTestCase {
    func testRecordingPushPostsStartRecordingWithParsedCommand() async {
        let expectation = expectation(description: "start recording posted")
        var receivedCommand: PushRecordingCommand?
        var receivedDSN: String?
        let token = NotificationCenter.default.addObserver(
            forName: .pushShouldStartRecording,
            object: nil,
            queue: nil
        ) { notification in
            receivedCommand = notification.userInfo?[PushUserInfoKeys.recordingCommand] as? PushRecordingCommand
            receivedDSN = notification.userInfo?[PushUserInfoKeys.dsn] as? String
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        PushCommandRouter.handle(
            userInfo: [
                "event": " trigger_recording ",
                "dsn": " child-9 ",
                "recordingId": " rec-77 ",
                "type": "Audio",
                "durationSeconds": "30"
            ],
            deliveryContext: .backgroundFetch
        )

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(receivedCommand?.recordingID, "rec-77")
        XCTAssertEqual(receivedCommand?.type, .audio)
        XCTAssertEqual(receivedCommand?.durationSeconds, 30)
        XCTAssertEqual(receivedDSN, "child-9")
    }
}

final class LockPushRefreshPolicyTests: XCTestCase {
    func testAlwaysRefreshesOilaLockStateWhenPushMatchesEvenWithScreenTimeDisabled() {
        let actions = LockPushRefreshPolicy.actions(
            pushMatchesSession: true,
            screenTimeFeaturesEnabled: false,
            shouldRunLocalChildServices: false
        )
        XCTAssertTrue(actions.refreshOilaLockState)
        XCTAssertFalse(actions.refreshLegacyLockCoordinator)
    }

    func testRefreshesLegacyCoordinatorOnlyWhenScreenTimeEnabledAndServicesRunning() {
        let actions = LockPushRefreshPolicy.actions(
            pushMatchesSession: true,
            screenTimeFeaturesEnabled: true,
            shouldRunLocalChildServices: true
        )
        XCTAssertTrue(actions.refreshOilaLockState)
        XCTAssertTrue(actions.refreshLegacyLockCoordinator)
    }

    func testNoRefreshWhenPushDoesNotMatchSession() {
        let actions = LockPushRefreshPolicy.actions(
            pushMatchesSession: false,
            screenTimeFeaturesEnabled: true,
            shouldRunLocalChildServices: true
        )
        XCTAssertFalse(actions.refreshOilaLockState)
        XCTAssertFalse(actions.refreshLegacyLockCoordinator)
    }
}

@MainActor
final class OilaRecordingTriggerServiceTests: XCTestCase {
    func testAudioCommandRecordsThenUploadsWithClampedDuration() async {
        var recordedArgs: (String, TimeInterval)?
        var uploadedArgs: (String, URL, Int)?
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        try? Data("audio".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let service = OilaRecordingTriggerService(
            recordAudioAction: { id, duration in
                recordedArgs = (id, duration)
                return fileURL
            },
            uploadAction: { id, url, duration in
                uploadedArgs = (id, url, duration)
            }
        )
        service.start(dsn: "child-1")

        await service.handleCommand(
            PushRecordingCommand(
                recordingID: "rec-1",
                type: .audio,
                durationSeconds: 20,
                cameraType: nil
            )
        )

        XCTAssertEqual(recordedArgs?.0, "rec-1")
        XCTAssertEqual(recordedArgs?.1, 20)
        XCTAssertEqual(uploadedArgs?.0, "rec-1")
        XCTAssertEqual(uploadedArgs?.2, 20)
        XCTAssertNil(service.activeRecordingID)
    }

    func testVideoCommandIsSkippedInAudioOnlyV1() async {
        var recordCalled = false
        let service = OilaRecordingTriggerService(
            recordAudioAction: { _, _ in
                recordCalled = true
                return FileManager.default.temporaryDirectory.appendingPathComponent("x.m4a")
            },
            uploadAction: { _, _, _ in }
        )
        service.start(dsn: "child-1")

        await service.handleCommand(
            PushRecordingCommand(recordingID: "rec-v", type: .video, durationSeconds: 10, cameraType: .back)
        )

        XCTAssertFalse(recordCalled)
    }

    func testCommandIgnoredWhenNotStarted() async {
        var recordCalled = false
        let service = OilaRecordingTriggerService(
            recordAudioAction: { _, _ in
                recordCalled = true
                return FileManager.default.temporaryDirectory.appendingPathComponent("x.m4a")
            },
            uploadAction: { _, _, _ in }
        )

        await service.handleCommand(
            PushRecordingCommand(recordingID: "rec-1", type: .audio, durationSeconds: 10, cameraType: nil)
        )

        XCTAssertFalse(recordCalled)
    }
}

final class DeviceControlEventSharedStoreTests: XCTestCase {
    func testAppendNormalizesIdentifiersDeduplicatesRecentEventsAndRemovesSpecificIDs() throws {
        let suiteName = "DeviceControlEventSharedStoreDedupTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = DeviceControlEventSharedStore(userDefaults: userDefaults)
        let first = try XCTUnwrap(
            store.append(
                kind: .appLimitReached,
                dsn: " Child-1 ",
                packageName: " COM.EXAMPLE.Camera ",
                appName: " Camera ",
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )
        let duplicate = try store.append(
            kind: .appLimitReached,
            dsn: "child-1",
            packageName: "com.example.camera",
            appName: "camera",
            createdAt: Date(timeIntervalSince1970: 110)
        )
        let second = try XCTUnwrap(
            store.append(
                kind: .appLimitReached,
                dsn: "child-1",
                packageName: "com.example.camera",
                appName: "Camera",
                createdAt: Date(timeIntervalSince1970: 131)
            )
        )

        XCTAssertTrue(store.isAvailable)
        XCTAssertEqual(first.dsn, "child-1")
        XCTAssertEqual(first.packageName, "com.example.camera")
        XCTAssertEqual(first.appName, "Camera")
        XCTAssertEqual(first.fingerprint, "device_control_app_limit_reached|child-1|com.example.camera|camera")
        XCTAssertNil(duplicate)
        XCTAssertEqual(store.loadPendingEvents().map(\.id), [second.id, first.id])

        try store.removePendingEvents(ids: [first.id])
        XCTAssertEqual(store.loadPendingEvents().map(\.id), [second.id])
    }

    func testAppendRejectsBlankDSNAndThrowsWhenStorageUnavailable() throws {
        let unavailableStore = DeviceControlEventSharedStore(userDefaults: nil)

        XCTAssertFalse(unavailableStore.isAvailable)
        XCTAssertNil(
            try unavailableStore.append(
                kind: .scheduleStarted,
                dsn: "   ",
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )
        XCTAssertThrowsError(
            try unavailableStore.append(
                kind: .scheduleStarted,
                dsn: "child-2",
                createdAt: Date(timeIntervalSince1970: 100)
            )
        ) { error in
            XCTAssertEqual(error as? DeviceControlEventSharedStoreError, .appGroupUnavailable)
        }
    }

    func testLoadPendingEventsRecoversFromInvalidPayloadAndRemovingEmptyIDsIsNoOp() throws {
        let suiteName = "DeviceControlEventSharedStoreInvalidPayloadTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(Data("broken".utf8), forKey: "DEVICE_CONTROL_PENDING_EVENTS")

        let store = DeviceControlEventSharedStore(userDefaults: userDefaults)

        XCTAssertTrue(store.loadPendingEvents().isEmpty)
        XCTAssertNoThrow(try store.removePendingEvents(ids: []))

        let event = try XCTUnwrap(
            store.append(
                kind: .scheduleEnded,
                dsn: "child-3",
                createdAt: Date(timeIntervalSince1970: 200)
            )
        )
        XCTAssertEqual(store.loadPendingEvents().map(\.id), [event.id])
    }

    func testAppendTrimsPendingEventsToMaximumCount() throws {
        let suiteName = "DeviceControlEventSharedStoreTrimTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = DeviceControlEventSharedStore(userDefaults: userDefaults)
        for index in 0 ..< 70 {
            _ = try store.append(
                kind: .scheduleStarted,
                dsn: "child-\(index)",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let events = store.loadPendingEvents()
        XCTAssertEqual(events.count, 64)
        XCTAssertEqual(events.first?.dsn, "child-69")
        XCTAssertEqual(events.last?.dsn, "child-6")
    }
}

@MainActor
final class DeviceControlEventBridgeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearDeviceControlPendingEventsForTests()
    }

    override func tearDown() {
        clearDeviceControlPendingEventsForTests()
        super.tearDown()
    }

    func testSyncNowAppendsSortedInboxItemsAndClearsPendingEvents() async {
        await PushInboxStore.shared.clearAll()
        defer { Task { await PushInboxStore.shared.clearAll() } }

        seedDeviceControlPendingEventsForTests([
            DeviceControlEvent(
                id: "device-control-1",
                kind: .scheduleStarted,
                dsn: "child-bridge",
                packageName: nil,
                appName: nil,
                createdAt: Date(timeIntervalSince1970: 100),
                fingerprint: "device_control_schedule_started|child-bridge||"
            ),
            DeviceControlEvent(
                id: "device-control-2",
                kind: .scheduleEnded,
                dsn: "child-bridge",
                packageName: nil,
                appName: nil,
                createdAt: Date(timeIntervalSince1970: 200),
                fingerprint: "device_control_schedule_ended|child-bridge||"
            ),
            DeviceControlEvent(
                id: "device-control-3",
                kind: .appLimitReached,
                dsn: "child-bridge",
                packageName: "com.example.camera",
                appName: "Camera",
                createdAt: Date(timeIntervalSince1970: 300),
                fingerprint: "device_control_app_limit_reached|child-bridge|com.example.camera|camera"
            )
        ])

        let bridge = DeviceControlEventBridge()
        await bridge.syncNow()

        let items = await pushInboxItemsMatchingDSNForTests("child-bridge")
        let store = DeviceControlEventSharedStore(userDefaults: deviceControlEventSharedDefaultsForTests())

        XCTAssertEqual(items.map(\.event), [
            DeviceControlEventKind.appLimitReached.rawValue,
            DeviceControlEventKind.scheduleEnded.rawValue,
            DeviceControlEventKind.scheduleStarted.rawValue
        ])
        XCTAssertEqual(items[0].title, L10n.tr("notifications.device_control.app_limit_reached_title", "Camera"))
        XCTAssertEqual(items[0].body, L10n.tr("notifications.device_control.app_limit_reached_body", "Camera"))
        XCTAssertEqual(items[1].title, L10n.tr("notifications.device_control.schedule_ended_title"))
        XCTAssertEqual(items[1].body, L10n.tr("notifications.device_control.schedule_ended_body"))
        XCTAssertEqual(items[2].title, L10n.tr("notifications.device_control.schedule_started_title"))
        XCTAssertEqual(items[2].body, L10n.tr("notifications.device_control.schedule_started_body"))
        XCTAssertTrue(store.loadPendingEvents().isEmpty)
    }

    func testSyncNowUsesFallbackCopyForUnnamedAppLimitEvents() async {
        await PushInboxStore.shared.clearAll()
        defer { Task { await PushInboxStore.shared.clearAll() } }

        seedDeviceControlPendingEventsForTests([
            DeviceControlEvent(
                id: "device-control-fallback",
                kind: .appLimitReached,
                dsn: "child-bridge-fallback",
                packageName: nil,
                appName: nil,
                createdAt: Date(timeIntervalSince1970: 100),
                fingerprint: "device_control_app_limit_reached|child-bridge-fallback||"
            )
        ])

        let bridge = DeviceControlEventBridge()
        await bridge.syncNow()
        await bridge.syncNow()

        let items = await pushInboxItemsMatchingDSNForTests("child-bridge-fallback")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, L10n.tr("notifications.device_control.app_limit_reached_title_fallback"))
        XCTAssertEqual(items[0].body, L10n.tr("notifications.device_control.app_limit_reached_body_fallback"))
    }
}

@MainActor
final class SmartOilaKidsAppDelegateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearDeviceControlPendingEventsForTests()
        UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_ACTIVITY_EVENTS")
        UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_INBOX_SYNCED_IDS")
    }

    override func tearDown() {
        clearDeviceControlPendingEventsForTests()
        UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_ACTIVITY_EVENTS")
        UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_INBOX_SYNCED_IDS")
        super.tearDown()
    }

    func testApplicationDidBecomeActiveSyncsDeviceControlAndMediaTelemetryInboxSources() async {
        await PushInboxStore.shared.clearAll()
        defer { Task { await PushInboxStore.shared.clearAll() } }

        seedDeviceControlPendingEventsForTests([
            DeviceControlEvent(
                id: "app-active-device-control",
                kind: .scheduleStarted,
                dsn: "child-app-active",
                packageName: nil,
                appName: nil,
                createdAt: Date(timeIntervalSince1970: 100),
                fingerprint: "device_control_schedule_started|child-app-active||"
            )
        ])
        seedMediaActivityEventsForTests([
            MediaActivityEvent(
                id: "app-active-media",
                dsn: "child-app-active",
                event: .recordingCompleted,
                mediaType: .camera,
                recordingID: nil,
                reason: nil,
                createdAt: Date(timeIntervalSince1970: 200)
            )
        ])

        let appDelegate = SmartOilaKidsAppDelegate()
        appDelegate.applicationDidBecomeActive(UIApplication.shared)

        let items = await waitForPushInboxItemsMatchingDSNForTests(count: 2, dsn: "child-app-active")
        XCTAssertEqual(Set(items.map(\.event)), [
            DeviceControlEventKind.scheduleStarted.rawValue,
            MediaTelemetryEvent.recordingCompleted.rawValue
        ])
        XCTAssertTrue(
            (UserDefaults.standard.stringArray(forKey: "SMARTOILA_MEDIA_INBOX_SYNCED_IDS") ?? [])
                .contains("app-active-media")
        )
    }

    func testDidReceiveRemoteNotificationRoutesPushAndCompletesWithNewData() async {
        await PushInboxStore.shared.clearAll()
        defer { Task { await PushInboxStore.shared.clearAll() } }

        let completionExpectation = expectation(description: "background fetch completion")
        let appDelegate = SmartOilaKidsAppDelegate()

        appDelegate.application(
            UIApplication.shared,
            didReceiveRemoteNotification: [
                "event": " award_update ",
                "children_device_dsn": " child-app-remote ",
                "body": " New task assigned "
            ]
        ) { result in
            XCTAssertEqual(result, .newData)
            completionExpectation.fulfill()
        }

        await fulfillment(of: [completionExpectation], timeout: 1)
        let items = await waitForPushInboxItemsMatchingDSNForTests(count: 1, dsn: "child-app-remote")

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, "award_update")
        XCTAssertEqual(items.first?.dsn, "child-app-remote")
        XCTAssertFalse(items.first?.isRead ?? true)
    }
}

@MainActor
final class MediaTelemetryInboxBridgeTests: XCTestCase {
    func testSyncNowAppendsEventsUsesBodyFallbacksAndSkipsAlreadySyncedOnSecondRun() async {
        let suiteName = "MediaTelemetryInboxBridgeTests.\(UUID().uuidString)"
        let bridgeDefaults = UserDefaults(suiteName: suiteName)!
        defer { bridgeDefaults.removePersistentDomain(forName: suiteName) }
        await PushInboxStore.shared.clearAll()
        UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_ACTIVITY_EVENTS")
        UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_INBOX_SYNCED_IDS")
        defer {
            UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_ACTIVITY_EVENTS")
            UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_INBOX_SYNCED_IDS")
            Task { await PushInboxStore.shared.clearAll() }
        }

        seedMediaActivityEventsForTests([
            MediaActivityEvent(
                id: "media-1",
                dsn: "child-bridge",
                event: .streamStarted,
                mediaType: .cameraStream,
                recordingID: " rec-1 ",
                reason: nil,
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            MediaActivityEvent(
                id: "media-2",
                dsn: "child-bridge",
                event: .streamFailed,
                mediaType: .camera,
                recordingID: nil,
                reason: " disconnected ",
                createdAt: Date(timeIntervalSince1970: 200)
            ),
            MediaActivityEvent(
                id: "media-3",
                dsn: "child-bridge",
                event: .recordingCompleted,
                mediaType: .display,
                recordingID: nil,
                reason: nil,
                createdAt: Date(timeIntervalSince1970: 300)
            )
        ])

        let bridge = MediaTelemetryInboxBridge(userDefaults: bridgeDefaults)

        await bridge.syncNow()
        let items = await pushInboxItemsMatchingDSNForTests("child-bridge")

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.event), [
            MediaTelemetryEvent.recordingCompleted.rawValue,
            MediaTelemetryEvent.streamFailed.rawValue,
            MediaTelemetryEvent.streamStarted.rawValue
        ])
        XCTAssertEqual(items[0].body, L10n.tr("notifications.media.recording_completed_body"))
        XCTAssertEqual(items[1].body, "disconnected")
        XCTAssertEqual(items[2].body, L10n.tr("notifications.media.stream_started_body"))
        XCTAssertEqual(Set(bridgeDefaults.stringArray(forKey: "SMARTOILA_MEDIA_INBOX_SYNCED_IDS") ?? []), [
            "media-1",
            "media-2",
            "media-3"
        ])

        await bridge.syncNow()
        let secondPassItems = await pushInboxItemsMatchingDSNForTests("child-bridge")
        XCTAssertEqual(secondPassItems.count, 3)
    }

    func testSyncNowOnlyAppendsUnsyncedEvents() async {
        let suiteName = "MediaTelemetryInboxBridgeSeededSyncTests.\(UUID().uuidString)"
        let bridgeDefaults = UserDefaults(suiteName: suiteName)!
        defer { bridgeDefaults.removePersistentDomain(forName: suiteName) }
        await PushInboxStore.shared.clearAll()
        UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_ACTIVITY_EVENTS")
        UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_INBOX_SYNCED_IDS")
        defer {
            UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_ACTIVITY_EVENTS")
            UserDefaults.standard.removeObject(forKey: "SMARTOILA_MEDIA_INBOX_SYNCED_IDS")
            Task { await PushInboxStore.shared.clearAll() }
        }

        let dsn = "child-seeded-\(UUID().uuidString)"
        let seenID = "media-seen-\(UUID().uuidString)"
        let newID = "media-new-\(UUID().uuidString)"
        UserDefaults.standard.set([seenID, newID], forKey: "SMARTOILA_MEDIA_INBOX_SYNCED_IDS")
        seedMediaActivityEventsForTests([
            MediaActivityEvent(
                id: seenID,
                dsn: dsn,
                event: .recordingStarted,
                mediaType: .camera,
                recordingID: nil,
                reason: nil,
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            MediaActivityEvent(
                id: newID,
                dsn: dsn,
                event: .streamDeliveryFailed,
                mediaType: .audioStream,
                recordingID: nil,
                reason: " upload failed ",
                createdAt: Date(timeIntervalSince1970: 200)
            )
        ])
        bridgeDefaults.set([seenID], forKey: "SMARTOILA_MEDIA_INBOX_SYNCED_IDS")

        let bridge = MediaTelemetryInboxBridge(userDefaults: bridgeDefaults)
        await bridge.syncNow()

        let items = await pushInboxItemsMatchingDSNForTests(dsn)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, MediaTelemetryEvent.streamDeliveryFailed.rawValue)
        XCTAssertEqual(items.first?.body, "upload failed")
        XCTAssertEqual(
            Set(bridgeDefaults.stringArray(forKey: "SMARTOILA_MEDIA_INBOX_SYNCED_IDS") ?? []),
            [seenID, newID]
        )
    }
}

final class PermissionRequirementTests: XCTestCase {
    func testComputedKeysMatchCurrentPermissionCatalog() {
        XCTAssertEqual(PermissionRequirement.onboardingCases, [.location])
        XCTAssertEqual(
            PermissionRequirement.settingsCases,
            [.location, .notifications, .microphone, .camera]
        )

        XCTAssertEqual(PermissionRequirement.location.id, PermissionRequirement.location.rawValue)
        XCTAssertEqual(PermissionRequirement.location.titleKey, "permissions.item_2")
        XCTAssertEqual(PermissionRequirement.location.detailBodyKey, "permissions.details.body_2")
        XCTAssertEqual(PermissionRequirement.location.detailStepKey, "permissions.details.step_2")

        XCTAssertEqual(PermissionRequirement.usageStats.titleKey, "permissions.item_5")
        XCTAssertEqual(PermissionRequirement.usageStats.detailBodyKey, "permissions.details.body_5")
        XCTAssertEqual(PermissionRequirement.usageStats.detailStepKey, "permissions.details.step_5")

        XCTAssertEqual(PermissionRequirement.notifications.titleKey, "permissions.item_7")
        XCTAssertEqual(PermissionRequirement.microphone.titleKey, "permissions.item_4")
        XCTAssertEqual(PermissionRequirement.camera.titleKey, "permissions.item_8")
    }
}

final class PermissionChecklistEvaluatorTests: XCTestCase {
    func testIsInteractiveAndSatisfiedCoverEveryRequirement() {
        let satisfied = makePermissionSnapshot()

        XCTAssertFalse(PermissionChecklistEvaluator.isInteractive(.usageStats, in: makePermissionSnapshot(screenTime: .unavailable)))
        XCTAssertTrue(PermissionChecklistEvaluator.isInteractive(.usageStats, in: makePermissionSnapshot(screenTime: .denied)))
        XCTAssertTrue(PermissionChecklistEvaluator.isInteractive(.location, in: satisfied))
        XCTAssertTrue(PermissionChecklistEvaluator.isInteractive(.notifications, in: satisfied))
        XCTAssertTrue(PermissionChecklistEvaluator.isInteractive(.microphone, in: satisfied))
        XCTAssertTrue(PermissionChecklistEvaluator.isInteractive(.camera, in: satisfied))

        XCTAssertTrue(PermissionChecklistEvaluator.isSatisfied(.location, in: satisfied))
        XCTAssertFalse(PermissionChecklistEvaluator.isSatisfied(.location, in: makePermissionSnapshot(location: .authorizedWhenInUse)))
        XCTAssertTrue(PermissionChecklistEvaluator.isOnboardingSatisfied(.location, in: makePermissionSnapshot(location: .authorizedWhenInUse)))
        XCTAssertTrue(PermissionChecklistEvaluator.isSatisfied(.microphone, in: satisfied))
        XCTAssertFalse(PermissionChecklistEvaluator.isSatisfied(.microphone, in: makePermissionSnapshot(microphone: .denied)))
        XCTAssertTrue(PermissionChecklistEvaluator.isSatisfied(.usageStats, in: satisfied))
        XCTAssertFalse(PermissionChecklistEvaluator.isSatisfied(.usageStats, in: makePermissionSnapshot(screenTime: .denied)))
        XCTAssertTrue(PermissionChecklistEvaluator.isSatisfied(.camera, in: satisfied))
        XCTAssertFalse(PermissionChecklistEvaluator.isSatisfied(.camera, in: makePermissionSnapshot(camera: .denied)))
        XCTAssertTrue(PermissionChecklistEvaluator.isSatisfied(.notifications, in: makePermissionSnapshot(notification: .provisional)))
        XCTAssertFalse(PermissionChecklistEvaluator.isSatisfied(.notifications, in: makePermissionSnapshot(notification: .denied)))
    }

    func testStatusTextAndPrimaryActionTitleCoverPermissionStates() {
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .usageStats, in: makePermissionSnapshot(screenTime: .granted)),
            L10n.tr("permissions.status_granted")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .usageStats, in: makePermissionSnapshot(screenTime: .unavailable)),
            L10n.tr("permissions.status_unavailable")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .usageStats, in: makePermissionSnapshot(screenTime: .denied)),
            L10n.tr("permissions.status_tap_to_allow")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.primaryActionTitle(for: .usageStats, in: makePermissionSnapshot(screenTime: .denied)),
            L10n.tr("permissions.action_allow_screen_time")
        )

        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .location, in: makePermissionSnapshot(location: .notDetermined)),
            L10n.tr("permissions.status_tap_to_allow")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.primaryActionTitle(for: .location, in: makePermissionSnapshot(location: .notDetermined)),
            L10n.tr("permissions.action_allow_location")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .location, in: makePermissionSnapshot(location: .authorizedWhenInUse)),
            L10n.tr("permissions.status_location_always_required")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.onboardingStatusText(for: .location, in: makePermissionSnapshot(location: .authorizedWhenInUse)),
            L10n.tr("permissions.status_granted")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.primaryActionTitle(for: .location, in: makePermissionSnapshot(location: .authorizedWhenInUse)),
            L10n.tr("permissions.action_allow_location_always")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .location, in: makePermissionSnapshot(location: .denied)),
            L10n.tr("permissions.status_open_settings")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.primaryActionTitle(for: .location, in: makePermissionSnapshot(location: .denied)),
            L10n.tr("permissions.action_open_settings")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .location, in: makePermissionSnapshot(location: .authorizedAlways)),
            L10n.tr("permissions.status_granted")
        )
        XCTAssertNil(
            PermissionChecklistEvaluator.primaryActionTitle(for: .location, in: makePermissionSnapshot(location: .authorizedAlways))
        )

        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .microphone, in: makePermissionSnapshot(microphone: .undetermined)),
            L10n.tr("permissions.status_tap_to_allow")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.primaryActionTitle(for: .microphone, in: makePermissionSnapshot(microphone: .undetermined)),
            L10n.tr("permissions.action_allow_microphone")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .microphone, in: makePermissionSnapshot(microphone: .denied)),
            L10n.tr("permissions.status_open_settings")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.primaryActionTitle(for: .microphone, in: makePermissionSnapshot(microphone: .denied)),
            L10n.tr("permissions.action_open_settings")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .microphone, in: makePermissionSnapshot(microphone: .granted)),
            L10n.tr("permissions.status_granted")
        )
        XCTAssertNil(
            PermissionChecklistEvaluator.primaryActionTitle(for: .microphone, in: makePermissionSnapshot(microphone: .granted))
        )

        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .camera, in: makePermissionSnapshot(camera: .notDetermined)),
            L10n.tr("permissions.status_tap_to_allow")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.primaryActionTitle(for: .camera, in: makePermissionSnapshot(camera: .notDetermined)),
            L10n.tr("permissions.action_allow_camera")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .camera, in: makePermissionSnapshot(camera: .denied)),
            L10n.tr("permissions.status_open_settings")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.primaryActionTitle(for: .camera, in: makePermissionSnapshot(camera: .denied)),
            L10n.tr("permissions.action_open_settings")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .camera, in: makePermissionSnapshot(camera: .authorized)),
            L10n.tr("permissions.status_granted")
        )
        XCTAssertNil(
            PermissionChecklistEvaluator.primaryActionTitle(for: .camera, in: makePermissionSnapshot(camera: .authorized))
        )

        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .notifications, in: makePermissionSnapshot(notification: .notDetermined)),
            L10n.tr("permissions.status_tap_to_allow")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.primaryActionTitle(for: .notifications, in: makePermissionSnapshot(notification: .notDetermined)),
            L10n.tr("permissions.action_allow_notifications")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .notifications, in: makePermissionSnapshot(notification: .denied)),
            L10n.tr("permissions.status_open_settings")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.primaryActionTitle(for: .notifications, in: makePermissionSnapshot(notification: .denied)),
            L10n.tr("permissions.action_open_settings")
        )
        XCTAssertEqual(
            PermissionChecklistEvaluator.statusText(for: .notifications, in: makePermissionSnapshot(notification: .authorized)),
            L10n.tr("permissions.status_granted")
        )
        XCTAssertNil(
            PermissionChecklistEvaluator.primaryActionTitle(for: .notifications, in: makePermissionSnapshot(notification: .authorized))
        )
    }

    func testAllChecklistSatisfiedAndMediaReadinessIgnoreUsageStatsButRespectDisplayCapture() {
        let satisfiedExceptUsageStats = makePermissionSnapshot(displayCapture: .ready, screenTime: .denied)

        XCTAssertTrue(PermissionChecklistEvaluator.allChecklistSatisfied(in: satisfiedExceptUsageStats))
        XCTAssertTrue(
            PermissionChecklistEvaluator.onboardingChecklistSatisfied(
                in: makePermissionSnapshot(location: .authorizedWhenInUse, displayCapture: .ready, screenTime: .denied)
            )
        )
        XCTAssertTrue(PermissionChecklistEvaluator.mediaReadinessSatisfied(in: satisfiedExceptUsageStats))
        XCTAssertEqual(
            PermissionChecklistEvaluator.mediaReadinessMessage(in: satisfiedExceptUsageStats),
            L10n.tr("permissions.media_readiness_ready")
        )

        let displayInactive = makePermissionSnapshot(displayCapture: .inactive)
        XCTAssertFalse(PermissionChecklistEvaluator.mediaReadinessSatisfied(in: displayInactive))
        XCTAssertEqual(
            PermissionChecklistEvaluator.mediaReadinessMessage(in: displayInactive),
            L10n.tr("permissions.media_readiness_attention")
        )
    }

    func testMediaCapabilityStatusesExposeReadyInactiveUnavailableAndActionStates() {
        let readyStatuses = PermissionChecklistEvaluator.mediaCapabilityStatuses(in: makePermissionSnapshot())
        XCTAssertEqual(readyStatuses.map(\.kind), [.microphone, .camera, .displayCapture])
        XCTAssertEqual(readyStatuses.map(\.state), [.ready, .ready, .ready])
        XCTAssertTrue(readyStatuses[0].isReady)
        XCTAssertEqual(readyStatuses[0].id, MediaCapabilityKind.microphone.id)
        XCTAssertEqual(readyStatuses[2].badgeText, L10n.tr("permissions.media_capability_badge_ready"))

        let mixedStatuses = PermissionChecklistEvaluator.mediaCapabilityStatuses(
            in: makePermissionSnapshot(
                microphone: .denied,
                camera: .notDetermined,
                displayCapture: .inactive
            )
        )
        XCTAssertEqual(mixedStatuses.map(\.state), [.actionNeeded, .actionNeeded, .inactive])
        XCTAssertEqual(mixedStatuses[0].badgeText, L10n.tr("permissions.media_capability_badge_action"))
        XCTAssertEqual(mixedStatuses[1].badgeText, L10n.tr("permissions.media_capability_badge_action"))
        XCTAssertEqual(mixedStatuses[2].badgeText, L10n.tr("permissions.media_capability_badge_inactive"))

        let unavailableDisplay = PermissionChecklistEvaluator.mediaCapabilityStatuses(
            in: makePermissionSnapshot(displayCapture: .unavailable)
        )
        XCTAssertEqual(unavailableDisplay[2].state, .unavailable)
        XCTAssertEqual(unavailableDisplay[2].badgeText, L10n.tr("permissions.media_capability_badge_unavailable"))
    }
}

final class GrowthMetricsStoreTests: XCTestCase {
    func testTrackNormalizesDSNUpdatesSnapshotAndPostsScopedNotification() {
        let suiteName = "GrowthMetricsStoreScopedTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = GrowthMetricsStore(userDefaults: userDefaults)
        let expectation = expectation(description: "growth metrics change")
        var notifications: [Notification] = []
        let token = NotificationCenter.default.addObserver(
            forName: .growthMetricsDidChange,
            object: nil,
            queue: nil
        ) { notification in
            notifications.append(notification)
            if notifications.count == 3 {
                expectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.track(.inviteShareClicked, dsn: " Child-1 ")
        store.track(.inviteShareCompleted, dsn: "child-1")
        store.track(.deviceRenameCompleted, dsn: "CHILD-1")

        wait(for: [expectation], timeout: 1)

        let snapshot = store.snapshot(for: "child-1")
        XCTAssertEqual(snapshot.inviteShareClickedCount, 1)
        XCTAssertEqual(snapshot.inviteShareCompletedCount, 1)
        XCTAssertEqual(snapshot.deviceRenameCompletedCount, 1)
        XCTAssertEqual(snapshot.inviteShareCompletionRate, 1)
        XCTAssertNotNil(snapshot.lastInviteShareClickedAt)
        XCTAssertNotNil(snapshot.lastInviteShareCompletedAt)
        XCTAssertNotNil(snapshot.lastDeviceRenameCompletedAt)
        XCTAssertEqual(notifications.compactMap { $0.userInfo?[GrowthMetricsUserInfoKey.dsn] as? String }, ["Child-1", "child-1", "CHILD-1"])
    }

    func testTrackWithoutDSNUsesGlobalScopeAndNotificationHasNoUserInfo() {
        let suiteName = "GrowthMetricsStoreGlobalTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = GrowthMetricsStore(userDefaults: userDefaults)
        let expectation = expectation(description: "global growth metrics change")
        var notifications: [Notification] = []
        let token = NotificationCenter.default.addObserver(
            forName: .growthMetricsDidChange,
            object: nil,
            queue: nil
        ) { notification in
            notifications.append(notification)
            if notifications.count == 2 {
                expectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.track(.inviteLinkOpened, dsn: nil)
        store.track(.deviceDeleteCompleted, dsn: "   ")

        wait(for: [expectation], timeout: 1)

        let globalSnapshot = store.snapshot(for: nil)
        XCTAssertEqual(globalSnapshot.inviteLinkOpenedCount, 1)
        XCTAssertEqual(globalSnapshot.deviceDeleteCompletedCount, 1)
        XCTAssertEqual(notifications.count, 2)
        XCTAssertTrue(notifications.allSatisfy { $0.userInfo == nil })
    }

    func testSnapshotFallsBackToEmptyForInvalidStoredPayload() {
        let suiteName = "GrowthMetricsStoreInvalidPayloadTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set(Data("broken".utf8), forKey: "GROWTH_METRICS_BY_DSN")
        let store = GrowthMetricsStore(userDefaults: userDefaults)

        let snapshot = store.snapshot(for: "child-1")

        XCTAssertEqual(snapshot.inviteShareClickedCount, GrowthMetricsSnapshot.empty.inviteShareClickedCount)
        XCTAssertEqual(snapshot.deviceDeleteCompletedCount, GrowthMetricsSnapshot.empty.deviceDeleteCompletedCount)
        XCTAssertNil(snapshot.lastInviteShareClickedAt)
    }
}

final class SMSTemplatesStoreTests: XCTestCase {
    func testLoadReturnsDefaultsForMissingInvalidAndEmptyPayloadsThenRoundTripsSavedTemplates() {
        let suiteName = "SMSTemplatesStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SMSTemplatesStore.load(userDefaults: userDefaults), [
            L10n.tr("templates.default_1"),
            L10n.tr("templates.default_2"),
            L10n.tr("templates.default_3")
        ])

        userDefaults.set(Data("broken".utf8), forKey: "SMS_TEMPLATES")
        XCTAssertEqual(SMSTemplatesStore.load(userDefaults: userDefaults), [
            L10n.tr("templates.default_1"),
            L10n.tr("templates.default_2"),
            L10n.tr("templates.default_3")
        ])

        SMSTemplatesStore.save([], userDefaults: userDefaults)
        XCTAssertEqual(SMSTemplatesStore.load(userDefaults: userDefaults), [
            L10n.tr("templates.default_1"),
            L10n.tr("templates.default_2"),
            L10n.tr("templates.default_3")
        ])

        let saved = ["Call me when you can", "I am on the way"]
        SMSTemplatesStore.save(saved, userDefaults: userDefaults)
        XCTAssertEqual(SMSTemplatesStore.load(userDefaults: userDefaults), saved)
    }

    func testUpsertDeleteAndNormalizeTemplateValues() {
        XCTAssertNil(SMSTemplatesStore.normalizedTemplate("   "))
        XCTAssertEqual(SMSTemplatesStore.normalizedTemplate("  Need help  "), "Need help")

        let initial = ["One"]
        let appended = SMSTemplatesStore.upsert(" Two ", at: nil, in: initial)
        XCTAssertEqual(appended, ["One", "Two"])

        let updated = SMSTemplatesStore.upsert(" Updated ", at: 0, in: appended)
        XCTAssertEqual(updated, ["Updated", "Two"])

        XCTAssertEqual(SMSTemplatesStore.upsert("   ", at: nil, in: updated), updated)
        XCTAssertEqual(SMSTemplatesStore.delete(at: 99, in: updated), updated)
        XCTAssertEqual(SMSTemplatesStore.delete(at: 1, in: updated), ["Updated"])
    }
}

@MainActor
final class SMSTemplatesRepositoryTests: XCTestCase {
    func testUpsertPersistsTemplatesAndSynchronizesAcrossRepositories() {
        let suiteName = "SMSTemplatesRepositorySyncTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let notificationCenter = NotificationCenter()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let primary = SMSTemplatesRepository(userDefaults: userDefaults, notificationCenter: notificationCenter)
        let mirror = SMSTemplatesRepository(userDefaults: userDefaults, notificationCenter: notificationCenter)

        XCTAssertTrue(primary.upsert(" Call me back ", at: nil))
        XCTAssertEqual(primary.templates.last, "Call me back")
        XCTAssertEqual(mirror.templates.last, "Call me back")
        XCTAssertEqual(SMSTemplatesStore.load(userDefaults: userDefaults).last, "Call me back")
    }

    func testRefreshAndNoOpOperationsUseCurrentStoredTemplates() {
        let suiteName = "SMSTemplatesRepositoryRefreshTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let notificationCenter = NotificationCenter()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        SMSTemplatesStore.save(["Template A", "Template B"], userDefaults: userDefaults)
        let repository = SMSTemplatesRepository(userDefaults: userDefaults, notificationCenter: notificationCenter)

        XCTAssertFalse(repository.upsert("   ", at: nil))
        XCTAssertFalse(repository.delete(at: 99))

        SMSTemplatesStore.save(["Remote 1", "Remote 2"], userDefaults: userDefaults)
        repository.refresh()
        XCTAssertEqual(repository.templates, ["Remote 1", "Remote 2"])

        notificationCenter.post(name: .smsTemplatesDidChange, object: nil)
        XCTAssertEqual(repository.templates, ["Remote 1", "Remote 2"])
    }
}

@MainActor
final class SMSTemplateEditorStateTests: XCTestCase {
    func testEditorLifecycleCreateEditAndDeleteSelectedTemplate() {
        let suiteName = "SMSTemplateEditorLifecycleTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let notificationCenter = NotificationCenter()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let repository = SMSTemplatesRepository(userDefaults: userDefaults, notificationCenter: notificationCenter)
        let state = SMSTemplateEditorState()

        state.beginCreate()
        XCTAssertTrue(state.showEditor)
        XCTAssertNil(state.editingIndex)
        XCTAssertNil(state.selectedTemplateIndex)

        state.draftText = " Need help "
        XCTAssertFalse(state.isDraftEmpty)
        XCTAssertTrue(state.save(using: repository))
        XCTAssertEqual(repository.templates.last, "Need help")
        XCTAssertFalse(state.showEditor)
        XCTAssertTrue(state.draftText.isEmpty)

        let selectedIndex = repository.templates.count - 1
        state.selectTemplate(at: selectedIndex)
        XCTAssertEqual(state.selectedTemplateIndex, selectedIndex)
        XCTAssertTrue(state.showActionsDialog)

        state.beginEditingSelectedTemplate(from: repository.templates)
        XCTAssertEqual(state.editingIndex, selectedIndex)
        XCTAssertEqual(state.draftText, "Need help")

        state.draftText = " Call me back "
        XCTAssertTrue(state.save(using: repository))
        XCTAssertEqual(repository.templates.last, "Call me back")

        state.selectTemplate(at: repository.templates.count - 1)
        XCTAssertTrue(state.deleteSelectedTemplate(using: repository))
        XCTAssertNil(state.selectedTemplateIndex)
        XCTAssertNil(state.editingIndex)
        XCTAssertTrue(state.draftText.isEmpty)
        XCTAssertFalse(repository.templates.contains("Call me back"))
    }

    func testEditorGuardsAgainstInvalidSelectionAndBlankDraftSaves() {
        let suiteName = "SMSTemplateEditorGuardTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let notificationCenter = NotificationCenter()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let repository = SMSTemplatesRepository(userDefaults: userDefaults, notificationCenter: notificationCenter)
        let state = SMSTemplateEditorState()

        XCTAssertTrue(state.isDraftEmpty)
        state.selectTemplate(at: 99)
        state.beginEditingSelectedTemplate(from: repository.templates)
        XCTAssertNil(state.editingIndex)
        XCTAssertTrue(state.draftText.isEmpty)

        state.beginCreate()
        state.draftText = "   "
        XCTAssertTrue(state.isDraftEmpty)
        XCTAssertFalse(state.save(using: repository))
        XCTAssertFalse(state.deleteSelectedTemplate(using: repository))

        state.resetEditor()
        XCTAssertFalse(state.showEditor)
        XCTAssertNil(state.selectedTemplateIndex)
        XCTAssertNil(state.editingIndex)
        XCTAssertTrue(state.draftText.isEmpty)
    }
}

final class SettingsInviteShareBuilderTests: XCTestCase {
    func testPayloadUsesProvidedNameAndNormalizedInviteDSNInGeneratedURL() throws {
        let payload = SettingsInviteShareBuilder.payload(profileName: " Parent One ", dsn: " child_7 ")
        let lines = payload.message.components(separatedBy: "\n")
        let inviteURL = try XCTUnwrap(URL(string: try XCTUnwrap(lines.last)))
        let items = try XCTUnwrap(URLComponents(url: inviteURL, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertTrue(payload.message.contains(L10n.tr("settings.invite_share_message", "Parent One")))
        XCTAssertEqual(items.first(where: { $0.name == "inviter_name" })?.value, "Parent One")
        XCTAssertEqual(items.first(where: { $0.name == "inviter_dsn" })?.value, "child_7")
    }

    func testPayloadFallsBackToDefaultNameWhenProfileNameIsBlank() throws {
        let payload = SettingsInviteShareBuilder.payload(profileName: "   ", dsn: nil)
        let lines = payload.message.components(separatedBy: "\n")
        let inviteURL = try XCTUnwrap(URL(string: try XCTUnwrap(lines.last)))
        let items = try XCTUnwrap(URLComponents(url: inviteURL, resolvingAgainstBaseURL: false)?.queryItems)
        let defaultName = L10n.tr("settings.invite_share_default_name")

        XCTAssertTrue(payload.message.contains(L10n.tr("settings.invite_share_message", defaultName)))
        XCTAssertEqual(items.first(where: { $0.name == "inviter_name" })?.value, defaultName)
        XCTAssertNil(items.first(where: { $0.name == "inviter_dsn" }))
    }
}

final class SettingsDeviceEditorStateTests: XCTestCase {
    func testBeginEditingClearSelectionAndCloseUpdateState() {
        let device = ConnectedDevice(id: 7, dsn: "child-7", name: "Kid Seven", avatarURL: nil)
        var state = SettingsDeviceEditorState()

        state.beginEditing(device)

        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.device, device)
        XCTAssertEqual(state.name, "Kid Seven")

        state.clearSelection()

        XCTAssertTrue(state.isPresented)
        XCTAssertNil(state.device)
        XCTAssertEqual(state.name, "Kid Seven")

        state.close()

        XCTAssertFalse(state.isPresented)
        XCTAssertNil(state.device)
        XCTAssertTrue(state.name.isEmpty)
    }
}

@MainActor
final class SettingsActionFlowsTests: XCTestCase {
    func testSaveProfileNameReturnsSavedOutcomeOnSuccess() async {
        let service = SettingsServiceSpy(updateProfileNameResult: .success("Remote Parent"))
        let viewModel = SettingsViewModel(service: service, cacheStore: SettingsCacheStoreSpy())
        let flows = SettingsActionFlows(viewModel: viewModel, currentDSN: nil, profileName: "Parent")

        let outcome = await flows.saveProfileName("Updated Parent")

        switch outcome {
        case let .saved(remoteName):
            XCTAssertEqual(remoteName, "Remote Parent")
        case .localFallback:
            XCTFail("Expected remote save outcome")
        }
        XCTAssertEqual(service.updateProfileNames, ["Updated Parent"])
    }

    func testSaveProfileNameFallsBackLocallyOnFailure() async {
        enum SettingsActionFlowError: Error {
            case expected
        }

        let service = SettingsServiceSpy(updateProfileNameResult: .failure(SettingsActionFlowError.expected))
        let viewModel = SettingsViewModel(service: service, cacheStore: SettingsCacheStoreSpy())
        let flows = SettingsActionFlows(viewModel: viewModel, currentDSN: nil, profileName: "Parent")

        let outcome = await flows.saveProfileName("Fallback Parent")

        switch outcome {
        case .saved:
            XCTFail("Expected local fallback outcome")
        case let .localFallback(localName):
            XCTAssertEqual(localName, "Fallback Parent")
        }
    }

    func testRenameDeviceReturnsUnchangedWhenServerKeepsOriginalName() async throws {
        let device = ConnectedDevice(id: 21, dsn: "child-21", name: "Same Kid", avatarURL: nil)
        let service = SettingsServiceSpy(renameConnectedDeviceResult: .success(device))
        let viewModel = SettingsViewModel(service: service, cacheStore: SettingsCacheStoreSpy())
        let flows = SettingsActionFlows(viewModel: viewModel, currentDSN: nil, profileName: "Parent")

        let result = await flows.renameDevice(device, to: "Same Kid")

        switch try result.get() {
        case .unchanged:
            break
        case .renamed:
            XCTFail("Expected unchanged rename outcome")
        }
        XCTAssertEqual(service.renameCalls.map(\.0), [21])
        XCTAssertEqual(service.renameCalls.map(\.1), ["Same Kid"])
    }

    func testRenameDeviceReturnsRenamedOutcomeWhenServerChangesName() async throws {
        let device = ConnectedDevice(id: 22, dsn: "child-22", name: "Before", avatarURL: nil)
        let updated = ConnectedDevice(id: 22, dsn: "child-22", name: "After", avatarURL: nil)
        let service = SettingsServiceSpy(renameConnectedDeviceResult: .success(updated))
        let viewModel = SettingsViewModel(service: service, cacheStore: SettingsCacheStoreSpy())
        let flows = SettingsActionFlows(viewModel: viewModel, currentDSN: nil, profileName: "Parent")

        let result = await flows.renameDevice(device, to: "After")

        switch try result.get() {
        case .unchanged:
            XCTFail("Expected renamed outcome")
        case let .renamed(name):
            XCTAssertEqual(name, "After")
        }
    }

    func testRenameDeviceReturnsFailureWhenRenameThrows() async {
        enum SettingsActionFlowError: Error {
            case expected
        }

        let device = ConnectedDevice(id: 23, dsn: "child-23", name: "Kid", avatarURL: nil)
        let service = SettingsServiceSpy(renameConnectedDeviceResult: .failure(SettingsActionFlowError.expected))
        let viewModel = SettingsViewModel(service: service, cacheStore: SettingsCacheStoreSpy())
        let flows = SettingsActionFlows(viewModel: viewModel, currentDSN: nil, profileName: "Parent")

        let result = await flows.renameDevice(device, to: "Renamed")

        do {
            _ = try result.get()
            XCTFail("Expected rename to fail")
        } catch SettingsActionFlowError.expected {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDeleteDeviceReturnsCurrentDeviceOutcome() async throws {
        let device = ConnectedDevice(id: 31, dsn: "child-31", name: "Kid Current", avatarURL: nil)
        let service = SettingsServiceSpy()
        let cacheStore = SettingsCacheStoreSpy(cachedDevices: [device])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices([device])
        viewModel.setRemoteProfileName("Kid Current")
        viewModel.runtime.currentDSN = "child-31"
        viewModel.runtime.hasLoadedRemoteDeviceNames = true
        let flows = SettingsActionFlows(viewModel: viewModel, currentDSN: nil, profileName: "Parent")

        let result = await flows.deleteDevice(device)

        XCTAssertEqual(try result.get(), .deletedCurrentDevice)
        XCTAssertEqual(service.deletedDeviceIDs, [31])
        XCTAssertTrue(viewModel.connectedDevices.isEmpty)
        XCTAssertNil(viewModel.remoteProfileName)
    }

    func testDeleteDeviceReturnsRemoteDeviceOutcome() async throws {
        let device = ConnectedDevice(id: 32, dsn: "child-32", name: "Kid Remote", avatarURL: nil)
        let service = SettingsServiceSpy()
        let cacheStore = SettingsCacheStoreSpy(cachedDevices: [device])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices([device])
        viewModel.runtime.currentDSN = "child-99"
        viewModel.runtime.hasLoadedRemoteDeviceNames = true
        let flows = SettingsActionFlows(viewModel: viewModel, currentDSN: nil, profileName: "Parent")

        let result = await flows.deleteDevice(device)

        XCTAssertEqual(try result.get(), .deletedRemoteDevice)
        XCTAssertEqual(service.deletedDeviceIDs, [32])
    }

    func testDeleteCurrentDeviceSessionReturnsSuccessAndClearsProfileForCurrentDevice() async throws {
        let device = ConnectedDevice(id: 41, dsn: "child-41", name: "Kid Forty One", avatarURL: nil)
        let service = SettingsServiceSpy()
        let cacheStore = SettingsCacheStoreSpy(cachedDevices: [device])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices([device])
        viewModel.setRemoteProfileName("Kid Forty One")
        viewModel.runtime.currentDSN = "child-41"
        viewModel.runtime.hasLoadedRemoteDeviceNames = true
        let flows = SettingsActionFlows(viewModel: viewModel, currentDSN: " child-41 ", profileName: "Parent")

        let result = await flows.deleteCurrentDeviceSession()

        _ = try result.get()
        XCTAssertEqual(service.deletedDeviceIDs, [41])
        XCTAssertTrue(viewModel.connectedDevices.isEmpty)
        XCTAssertNil(viewModel.remoteProfileName)
    }

    func testDeleteCurrentDeviceSessionReturnsFailureWhenDeleteThrows() async {
        enum SettingsActionFlowError: Error {
            case expected
        }

        let device = ConnectedDevice(id: 42, dsn: "child-42", name: "Kid Forty Two", avatarURL: nil)
        let service = SettingsServiceSpy(deleteConnectedDeviceResult: .failure(SettingsActionFlowError.expected))
        let cacheStore = SettingsCacheStoreSpy(cachedDevices: [device])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices([device])
        viewModel.runtime.hasLoadedRemoteDeviceNames = true
        let flows = SettingsActionFlows(viewModel: viewModel, currentDSN: "child-42", profileName: "Parent")

        let result = await flows.deleteCurrentDeviceSession()

        do {
            _ = try result.get()
            XCTFail("Expected deleteCurrentDeviceSession to fail")
        } catch SettingsActionFlowError.expected {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUploadCurrentDeviceAvatarReturnsUploadedURL() async throws {
        let imageData = Data([0x01, 0x02, 0x03, 0x04])
        let device = ConnectedDevice(id: 51, dsn: "child-51", name: "Kid Fifty One", avatarURL: nil)
        let updated = ConnectedDevice(
            id: 51,
            dsn: "child-51",
            name: "Kid Fifty One",
            avatarURL: URL(string: "https://example.com/child-51.jpg")
        )
        let service = SettingsServiceSpy(uploadConnectedDeviceAvatarResult: .success(updated))
        let cacheStore = SettingsCacheStoreSpy(cachedDevices: [device])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices([device])
        viewModel.runtime.hasLoadedRemoteDeviceNames = true
        let flows = SettingsActionFlows(viewModel: viewModel, currentDSN: " child-51 ", profileName: "Parent")

        let result = await flows.uploadCurrentDeviceAvatar(data: imageData)

        XCTAssertEqual(try result.get()?.absoluteString, "https://example.com/child-51.jpg")
        XCTAssertEqual(service.uploadCalls.map(\.0), [51])
        XCTAssertEqual(service.uploadCalls.map(\.1), [4])
    }

    func testUploadCurrentDeviceAvatarReturnsFailureWhenDSNIsMissing() async {
        let service = SettingsServiceSpy()
        let viewModel = SettingsViewModel(service: service, cacheStore: SettingsCacheStoreSpy())
        let flows = SettingsActionFlows(viewModel: viewModel, currentDSN: nil, profileName: "Parent")

        let result = await flows.uploadCurrentDeviceAvatar(data: Data([0x01]))

        do {
            _ = try result.get()
            XCTFail("Expected uploadCurrentDeviceAvatar to fail")
        } catch NetworkError.unexpectedBody {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(service.uploadCalls.isEmpty)
    }

    func testMakeInvitePayloadUsesBuilderOutput() {
        let viewModel = SettingsViewModel(service: SettingsServiceSpy(), cacheStore: SettingsCacheStoreSpy())
        let flows = SettingsActionFlows(
            viewModel: viewModel,
            currentDSN: " child-77 ",
            profileName: " Parent One "
        )

        let payload = flows.makeInvitePayload()
        let lines = payload.message.components(separatedBy: "\n")
        let inviteURL = try! XCTUnwrap(URL(string: try! XCTUnwrap(lines.last)))
        let items = try! XCTUnwrap(URLComponents(url: inviteURL, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertTrue(payload.message.contains(L10n.tr("settings.invite_share_message", "Parent One")))
        XCTAssertEqual(items.first(where: { $0.name == "inviter_name" })?.value, "Parent One")
        XCTAssertEqual(items.first(where: { $0.name == "inviter_dsn" })?.value, "child-77")
        XCTAssertEqual(items.first(where: { $0.name == "invite" })?.value, "1")
    }
}

final class DeviceControlRecoveryNotifierTests: XCTestCase {
    func testRecordLockRestoredAppendsInboxAndPostsTelemetry() async {
        let suiteName = "DeviceControlRecoveryNotifierLockTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let dsn = "child-lock-\(UUID().uuidString)"
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        await PushInboxStore.shared.clearAll()
        defer { Task { await PushInboxStore.shared.clearAll() } }

        let notifier = DeviceControlRecoveryNotifier(userDefaults: userDefaults)
        let expectation = expectation(description: "device control telemetry")
        var receivedRecord: DeviceControlTelemetryRecord?
        let token = NotificationCenter.default.addObserver(
            forName: .deviceControlTelemetryRecorded,
            object: nil,
            queue: nil
        ) { notification in
            receivedRecord = DeviceControlTelemetryRecord(notification: notification)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await notifier.recordLockRestored(dsn: " \(dsn) ")

        await fulfillment(of: [expectation], timeout: 1)

        let items = await PushInboxStore.shared.loadItems(dsn: dsn)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, DeviceControlRecoveryEvent.lockRestored.rawValue)
        XCTAssertEqual(items.first?.dsn, dsn)
        XCTAssertFalse(items.first?.title.isEmpty ?? true)
        XCTAssertFalse(items.first?.body.isEmpty ?? true)
        XCTAssertEqual(receivedRecord?.dsn, dsn)
        XCTAssertEqual(receivedRecord?.event, DeviceControlRecoveryEvent.lockRestored.rawValue)
        XCTAssertNil(receivedRecord?.packageName)
        XCTAssertNil(receivedRecord?.appName)
    }

    func testRecordAppLimitRestoredDeduplicatesWithinCooldownAndNormalizesIdentifiers() async {
        let suiteName = "DeviceControlRecoveryNotifierLimitTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let dsn = "child-limit-\(UUID().uuidString)"
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        await PushInboxStore.shared.clearAll()
        defer { Task { await PushInboxStore.shared.clearAll() } }

        let notifier = DeviceControlRecoveryNotifier(userDefaults: userDefaults)
        var telemetryRecords: [DeviceControlTelemetryRecord] = []
        let token = NotificationCenter.default.addObserver(
            forName: .deviceControlTelemetryRecorded,
            object: nil,
            queue: nil
        ) { notification in
            if let record = DeviceControlTelemetryRecord(notification: notification) {
                telemetryRecords.append(record)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await notifier.recordAppLimitRestored(
            dsn: dsn,
            packageName: " COM.EXAMPLE.APP ",
            appName: " Example App "
        )
        await notifier.recordAppLimitRestored(
            dsn: " \(dsn.uppercased()) ",
            packageName: "com.example.app",
            appName: "Example App"
        )

        let items = await PushInboxStore.shared.loadItems(dsn: dsn)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, DeviceControlRecoveryEvent.appLimitRestored.rawValue)
        XCTAssertEqual(telemetryRecords.count, 1)
        XCTAssertEqual(telemetryRecords.first?.dsn, dsn)
        XCTAssertEqual(telemetryRecords.first?.packageName, "com.example.app")
        XCTAssertEqual(telemetryRecords.first?.appName, "Example App")
    }

    func testRecordAppLockRestoredIgnoresInvalidApplicationsAndUsesNormalizedAlphabeticalApplication() async {
        let suiteName = "DeviceControlRecoveryNotifierAppLockTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let dsn = "child-app-lock-\(UUID().uuidString)"
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        await PushInboxStore.shared.clearAll()
        defer { Task { await PushInboxStore.shared.clearAll() } }

        let notifier = DeviceControlRecoveryNotifier(userDefaults: userDefaults)
        var telemetryRecords: [DeviceControlTelemetryRecord] = []
        let token = NotificationCenter.default.addObserver(
            forName: .deviceControlTelemetryRecorded,
            object: nil,
            queue: nil
        ) { notification in
            if let record = DeviceControlTelemetryRecord(notification: notification) {
                telemetryRecords.append(record)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await notifier.recordAppLockRestored(
            dsn: dsn,
            applications: [
                DeviceAppSelectionApplication(packageName: " ", appName: "Invalid"),
                DeviceAppSelectionApplication(packageName: "com.beta.app", appName: " Beta "),
                DeviceAppSelectionApplication(packageName: "COM.ALPHA.APP", appName: "Alpha"),
                DeviceAppSelectionApplication(packageName: "com.alpha.app", appName: "Alpha")
            ]
        )

        let items = await PushInboxStore.shared.loadItems(dsn: dsn)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, DeviceControlRecoveryEvent.appLockRestored.rawValue)
        XCTAssertEqual(telemetryRecords.count, 1)
        XCTAssertEqual(telemetryRecords.first?.dsn, dsn)
        XCTAssertEqual(telemetryRecords.first?.packageName, "com.alpha.app")
        XCTAssertNotNil(telemetryRecords.first?.appName)

        await PushInboxStore.shared.clearAll()
        telemetryRecords.removeAll()

        let invalidDSN = "child-app-lock-invalid-\(UUID().uuidString)"
        await notifier.recordAppLockRestored(
            dsn: invalidDSN,
            applications: [DeviceAppSelectionApplication(packageName: "   ", appName: "   ")]
        )

        let afterInvalid = await PushInboxStore.shared.loadItems(dsn: invalidDSN)
        XCTAssertTrue(afterInvalid.isEmpty)
        XCTAssertTrue(telemetryRecords.isEmpty)
    }

    func testTelemetryRecordInitializerTrimsFieldsAndFallsBackTimestamp() {
        let notification = Notification(
            name: .deviceControlTelemetryRecorded,
            object: nil,
            userInfo: [
                DeviceControlTelemetryUserInfoKey.dsn: " child-4 ",
                DeviceControlTelemetryUserInfoKey.event: " device_control_lock_restored ",
                DeviceControlTelemetryUserInfoKey.packageName: " com.example.app ",
                DeviceControlTelemetryUserInfoKey.appName: " Example App "
            ]
        )

        let record = DeviceControlTelemetryRecord(notification: notification)

        XCTAssertEqual(record?.dsn, "child-4")
        XCTAssertEqual(record?.event, "device_control_lock_restored")
        XCTAssertEqual(record?.packageName, "com.example.app")
        XCTAssertEqual(record?.appName, "Example App")
        XCTAssertNotNil(record?.createdAt)
    }
}

final class DeviceControlIntegrityNotifierTests: XCTestCase {
    func testRecordAppProtectionRemovedAppendsInboxPostsTelemetryAndReportsEachNormalizedApplication() async {
        let suiteName = "DeviceControlIntegrityNotifierRemovalTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        await PushInboxStore.shared.clearAll()
        defer { Task { await PushInboxStore.shared.clearAll() } }

        let removalService = DeviceApplicationRemovalAttemptReportingServiceSpy()
        let removalCoordinator = DeviceApplicationRemovalAttemptCoordinator(service: removalService)
        let notifier = DeviceControlIntegrityNotifier(
            userDefaults: userDefaults,
            removalAttemptCoordinator: removalCoordinator
        )

        var telemetryRecords: [DeviceControlTelemetryRecord] = []
        let token = NotificationCenter.default.addObserver(
            forName: .deviceControlTelemetryRecorded,
            object: nil,
            queue: nil
        ) { notification in
            if let record = DeviceControlTelemetryRecord(notification: notification) {
                telemetryRecords.append(record)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await notifier.recordAppProtectionRemoved(
            dsn: " child-1 ",
            applications: [
                DeviceAppSelectionApplication(packageName: "   ", appName: "Invalid"),
                DeviceAppSelectionApplication(packageName: "com.beta.app", appName: " Beta "),
                DeviceAppSelectionApplication(packageName: "COM.ALPHA.APP", appName: "Alpha"),
                DeviceAppSelectionApplication(packageName: "com.alpha.app", appName: "Alpha")
            ]
        )

        let items = await PushInboxStore.shared.loadItems(dsn: "child-1")
        let reportedAttempts = await removalService.recordedCalls()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, DeviceControlIntegrityEvent.appTargetsRemoved.rawValue)
        XCTAssertEqual(items.first?.dsn, "child-1")
        XCTAssertEqual(telemetryRecords.count, 1)
        XCTAssertEqual(telemetryRecords.first?.dsn, "child-1")
        XCTAssertEqual(telemetryRecords.first?.event, DeviceControlIntegrityEvent.appTargetsRemoved.rawValue)
        XCTAssertEqual(telemetryRecords.first?.packageName, "com.alpha.app")
        XCTAssertEqual(telemetryRecords.first?.appName, "Alpha")
        XCTAssertEqual(
            reportedAttempts,
            [
                DeviceApplicationRemovalAttemptEntry(
                    dsn: "child-1",
                    packageName: "com.alpha.app",
                    appName: "Alpha"
                ),
                DeviceApplicationRemovalAttemptEntry(
                    dsn: "child-1",
                    packageName: "com.beta.app",
                    appName: "Beta"
                )
            ]
        )
    }

    func testRecordScreenTimeRevokedIgnoresBlankDSNAndDeduplicatesWithinCooldown() async {
        let suiteName = "DeviceControlIntegrityNotifierScreenTimeTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        await PushInboxStore.shared.clearAll()
        defer { Task { await PushInboxStore.shared.clearAll() } }

        let notifier = DeviceControlIntegrityNotifier(userDefaults: userDefaults)
        var telemetryRecords: [DeviceControlTelemetryRecord] = []
        let token = NotificationCenter.default.addObserver(
            forName: .deviceControlTelemetryRecorded,
            object: nil,
            queue: nil
        ) { notification in
            if let record = DeviceControlTelemetryRecord(notification: notification) {
                telemetryRecords.append(record)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await notifier.recordScreenTimeRevoked(dsn: "   ")
        await notifier.recordScreenTimeRevoked(dsn: "child-2")
        await notifier.recordScreenTimeRevoked(dsn: " CHILD-2 ")

        let items = await PushInboxStore.shared.loadItems(dsn: "child-2")

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, DeviceControlIntegrityEvent.screenTimeRevoked.rawValue)
        XCTAssertEqual(telemetryRecords.count, 1)
        XCTAssertEqual(telemetryRecords.first?.dsn, "child-2")
        XCTAssertEqual(telemetryRecords.first?.event, DeviceControlIntegrityEvent.screenTimeRevoked.rawValue)
        XCTAssertNil(telemetryRecords.first?.packageName)
        XCTAssertNil(telemetryRecords.first?.appName)
    }

    func testRecordUnenforceableRemoteLocksUsesSingleNormalizedApplication() async {
        let suiteName = "DeviceControlIntegrityNotifierRemoteLockTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        await PushInboxStore.shared.clearAll()
        defer { Task { await PushInboxStore.shared.clearAll() } }

        let notifier = DeviceControlIntegrityNotifier(userDefaults: userDefaults)
        var telemetryRecords: [DeviceControlTelemetryRecord] = []
        let token = NotificationCenter.default.addObserver(
            forName: .deviceControlTelemetryRecorded,
            object: nil,
            queue: nil
        ) { notification in
            if let record = DeviceControlTelemetryRecord(notification: notification) {
                telemetryRecords.append(record)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await notifier.recordUnenforceableRemoteLocks(
            dsn: " child-3 ",
            applications: [
                DeviceAppSelectionApplication(packageName: " COM.EXAMPLE.CAMERA ", appName: " Camera ")
            ]
        )

        let items = await PushInboxStore.shared.loadItems(dsn: "child-3")

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.event, DeviceControlIntegrityEvent.remoteLocksUnenforceable.rawValue)
        XCTAssertEqual(telemetryRecords.count, 1)
        XCTAssertEqual(telemetryRecords.first?.dsn, "child-3")
        XCTAssertEqual(telemetryRecords.first?.event, DeviceControlIntegrityEvent.remoteLocksUnenforceable.rawValue)
        XCTAssertEqual(telemetryRecords.first?.packageName, "com.example.camera")
        XCTAssertEqual(telemetryRecords.first?.appName, "Camera")
    }
}

final class MediaTelemetryNotifierTests: XCTestCase {
    func testRecordTrimsValuesPostsNotificationAndRespectsCooldown() async {
        let suiteName = "MediaTelemetryNotifierTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let notifier = MediaTelemetryNotifier(userDefaults: userDefaults)
        var records: [MediaTelemetryRecord] = []
        let token = NotificationCenter.default.addObserver(
            forName: .mediaTelemetryRecorded,
            object: nil,
            queue: nil
        ) { notification in
            if let record = MediaTelemetryRecord(notification: notification) {
                records.append(record)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await notifier.record(
            .streamFailed,
            dsn: " child-telemetry ",
            mediaType: .cameraStream,
            recordingID: " rec-1 ",
            reason: " socket closed ",
            cooldown: 600
        )
        await notifier.record(
            .streamFailed,
            dsn: "CHILD-TELEMETRY",
            mediaType: .cameraStream,
            recordingID: "rec-1",
            reason: "socket closed",
            cooldown: 600
        )

        let events = await notifier.loadEvents(dsn: " child-telemetry ", limit: 10)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.dsn, "child-telemetry")
        XCTAssertEqual(records.first?.event, MediaTelemetryEvent.streamFailed.rawValue)
        XCTAssertEqual(records.first?.mediaType, MediaTelemetryType.cameraStream.rawValue)
        XCTAssertEqual(records.first?.recordingID, "rec-1")
        XCTAssertEqual(records.first?.reason, "socket closed")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.dsn, "child-telemetry")
        XCTAssertEqual(events.first?.event, .streamFailed)
        XCTAssertEqual(events.first?.mediaType, .cameraStream)
        XCTAssertEqual(events.first?.recordingID, "rec-1")
        XCTAssertEqual(events.first?.reason, "socket closed")
    }

    func testLoadEventsFiltersByDSNAndRecoversFromInvalidStoredPayload() async {
        let suiteName = "MediaTelemetryNotifierInvalidPayloadTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set(Data("broken".utf8), forKey: "SMARTOILA_MEDIA_ACTIVITY_EVENTS")
        let notifier = MediaTelemetryNotifier(userDefaults: userDefaults)

        let emptyEvents = await notifier.loadEvents(dsn: nil)
        XCTAssertTrue(emptyEvents.isEmpty)

        await notifier.record(.recordingStarted, dsn: "child-a", mediaType: .camera)
        await notifier.record(.recordingCompleted, dsn: "child-b", mediaType: .display)
        await notifier.record(.recordingFailed, dsn: "child-b", mediaType: .display, reason: " disconnected ")

        let filtered = await notifier.loadEvents(dsn: " CHILD-B ", limit: 1)
        let allEvents = await notifier.loadEvents(dsn: nil, limit: 10)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.dsn, "child-b")
        XCTAssertEqual(filtered.first?.event, .recordingFailed)
        XCTAssertEqual(filtered.first?.reason, "disconnected")
        XCTAssertEqual(allEvents.count, 3)
    }

    func testMediaTelemetryRecordInitializerTrimsFieldsAndFallsBackTimestamp() {
        let notification = Notification(
            name: .mediaTelemetryRecorded,
            object: nil,
            userInfo: [
                MediaTelemetryUserInfoKey.dsn: " child-media ",
                MediaTelemetryUserInfoKey.event: " media_stream_failed ",
                MediaTelemetryUserInfoKey.mediaType: " camera_stream ",
                MediaTelemetryUserInfoKey.recordingID: " rec-9 ",
                MediaTelemetryUserInfoKey.reason: " disconnected "
            ]
        )

        let record = MediaTelemetryRecord(notification: notification)

        XCTAssertEqual(record?.dsn, "child-media")
        XCTAssertEqual(record?.event, "media_stream_failed")
        XCTAssertEqual(record?.mediaType, "camera_stream")
        XCTAssertEqual(record?.recordingID, "rec-9")
        XCTAssertEqual(record?.reason, "disconnected")
        XCTAssertNotNil(record?.createdAt)
    }
}

final class PushTokenServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testSyncTokenBuildsAuthorizedRequestAndJSONBody() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/devices/dsn/child-1/firebase_notification_token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["token"] as? String, "device-token")
            return (makeHTTPResponse(for: request.url!, statusCode: 200), Data())
        }

        let service = PushTokenService(client: makeTestAPIClient(accessToken: "Bearer access"))
        try await service.syncToken("device-token", dsn: "child-1")

        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.count, 1)
    }

    func testFetchRemoteTokenBuildsAuthorizedRequestAndDecodesResponse() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/devices/dsn/child-1/firebase_notification_token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (
                makeHTTPResponse(for: request.url!, statusCode: 200),
                Data(#"{"token":"0123456789abcdef"}"#.utf8)
            )
        }

        let service = PushTokenService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let token = try await service.fetchRemoteToken(dsn: "child-1")

        XCTAssertEqual(token, "0123456789abcdef")
        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.count, 1)
    }

    func testFetchRemoteTokenFallsBackToMemberRouteWhenDeviceReadbackIsMissing() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

            switch request.url?.path {
            case "/api/devices/dsn/child-1/firebase_notification_token":
                return (
                    makeHTTPResponse(for: request.url!, statusCode: 404),
                    Data(#"{"detail":"missing"}"#.utf8)
                )
            case "/api/members/me/firebase_notification_token":
                return (
                    makeHTTPResponse(for: request.url!, statusCode: 200),
                    Data(#"{"token":"member-fallback-token"}"#.utf8)
                )
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return (makeHTTPResponse(for: request.url!, statusCode: 404), Data())
            }
        }

        let service = PushTokenService(client: makeTestAPIClient(accessToken: "Bearer access"))
        let token = try await service.fetchRemoteToken(dsn: "child-1")

        XCTAssertEqual(token, "member-fallback-token")
        XCTAssertEqual(
            TestHTTPURLProtocol.recordedRequests.compactMap(\.url?.path),
            [
                "/api/devices/dsn/child-1/firebase_notification_token",
                "/api/members/me/firebase_notification_token"
            ]
        )
    }
}

final class PushTokenSyncCoordinatorTests: XCTestCase {
    func testBootstrapFromDefaultsLoadsPersistedTokenAndDSNAndSyncsOnlyOnce() async {
        let suiteName = "PushTokenSyncCoordinatorBootstrapTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(" saved-token ", forKey: "PUSH_NOTIFICATION_TOKEN")
        userDefaults.set(" child-1 ", forKey: "DSN")

        let service = PushTokenServiceSpy()
        let coordinator = PushTokenSyncCoordinator(service: service, userDefaults: userDefaults)

        await coordinator.bootstrapFromDefaults()
        await coordinator.bootstrapFromDefaults()

        let syncCalls = await service.recordedCalls()
        XCTAssertEqual(syncCalls.count, 1)
        XCTAssertEqual(syncCalls.first?.token, "saved-token")
        XCTAssertEqual(syncCalls.first?.dsn, "child-1")
    }

    func testUpdateTokenPersistsTrimmedValueResyncsOnExplicitUpdateAndClearsStoredToken() async {
        let suiteName = "PushTokenSyncCoordinatorUpdateTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let service = PushTokenServiceSpy()
        let coordinator = PushTokenSyncCoordinator(service: service, userDefaults: userDefaults)

        await coordinator.updateDSN(" child-1 ")
        await coordinator.updateToken(" token-1 ")
        await coordinator.updateToken("token-1")
        await coordinator.updateToken(" token-2 ")
        await coordinator.updateToken("   ")

        let syncCalls = await service.recordedCalls()
        XCTAssertEqual(
            syncCalls,
            [
                PushTokenSyncCall(token: "token-1", dsn: "child-1"),
                PushTokenSyncCall(token: "token-1", dsn: "child-1"),
                PushTokenSyncCall(token: "token-2", dsn: "child-1")
            ]
        )
        XCTAssertNil(userDefaults.string(forKey: "PUSH_NOTIFICATION_TOKEN"))
    }

    func testRetryAfterFailureEventuallyResyncs() async {
        let suiteName = "PushTokenSyncCoordinatorRetryTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let service = PushTokenServiceSpy(syncResults: [
            .failure(NetworkError.server(statusCode: 500, body: "retry")),
            .success(())
        ])
        let coordinator = PushTokenSyncCoordinator(service: service, userDefaults: userDefaults)

        await coordinator.updateDSN("child-2")
        await coordinator.updateToken("retry-token")
        await waitForPushTokenSyncCallCount(service, count: 2, timeoutNanoseconds: 6_500_000_000)

        let syncCalls = await service.recordedCalls()
        XCTAssertEqual(
            syncCalls,
            [
                PushTokenSyncCall(token: "retry-token", dsn: "child-2"),
                PushTokenSyncCall(token: "retry-token", dsn: "child-2")
            ]
        )
    }

    func testSuccessfulSyncFetchesRemoteTokenAndUpdatesDiagnostics() async {
        let suiteName = "PushTokenSyncCoordinatorDiagnosticsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let service = PushTokenServiceSpy(fetchResults: [.success("0123456789abcdef")])
        let coordinator = PushTokenSyncCoordinator(service: service, userDefaults: userDefaults)

        await coordinator.updateDSN("child-3")
        await coordinator.updateToken("0123456789abcdef")

        let syncCalls = await service.recordedCalls()
        let fetchCalls = await service.recordedFetchDSNs()
        let diagnostics = await MainActor.run { RuntimeDiagnosticsCenter.shared.pushToken }

        XCTAssertEqual(syncCalls, [PushTokenSyncCall(token: "0123456789abcdef", dsn: "child-3")])
        XCTAssertEqual(fetchCalls, ["child-3"])
        XCTAssertEqual(diagnostics.status, "verified")
        XCTAssertEqual(diagnostics.dsn, "child-3")
        XCTAssertEqual(diagnostics.endpoint, "/devices/dsn/child-3/firebase_notification_token")
        XCTAssertEqual(diagnostics.localToken, "012345...cdef (16)")
        XCTAssertEqual(diagnostics.remoteToken, "012345...cdef (16)")
        XCTAssertEqual(diagnostics.lastError, "-")
        XCTAssertNotNil(diagnostics.updatedAt)
    }
}

final class MediaIntegrityNotifierTests: XCTestCase {
    func testRecordPermissionRevokedUsesStoredDSNPostsTelemetryAndDeduplicates() async {
        let suiteName = "MediaIntegrityNotifierPermissionTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let dsn = "Child-\(UUID().uuidString)"
        userDefaults.set(" \(dsn) ", forKey: "DSN")

        let notifier = MediaIntegrityNotifier(userDefaults: userDefaults)
        let expectation = expectation(description: "media integrity telemetry")
        var records: [MediaTelemetryRecord] = []
        let token = NotificationCenter.default.addObserver(
            forName: .mediaTelemetryRecorded,
            object: nil,
            queue: nil
        ) { notification in
            if let record = MediaTelemetryRecord(notification: notification) {
                records.append(record)
                expectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await notifier.recordPermissionRevoked(mediaType: .camera)
        await notifier.recordPermissionRevoked(dsn: dsn.lowercased(), mediaType: .camera)

        await fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.dsn, dsn)
        XCTAssertEqual(records.first?.event, MediaTelemetryEvent.permissionRevoked.rawValue)
        XCTAssertEqual(records.first?.mediaType, MediaTelemetryType.camera.rawValue)
        XCTAssertEqual(records.first?.reason, L10n.tr("notifications.media.permission_revoked_camera_body"))
    }

    func testRecordPermissionRevokedUsesMicrophoneCopyForEnvironmentMedia() async {
        let suiteName = "MediaIntegrityNotifierAudioPermissionTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let notifier = MediaIntegrityNotifier(userDefaults: userDefaults)
        let expectation = expectation(description: "environment telemetry")
        var record: MediaTelemetryRecord?
        let token = NotificationCenter.default.addObserver(
            forName: .mediaTelemetryRecorded,
            object: nil,
            queue: nil
        ) { notification in
            record = MediaTelemetryRecord(notification: notification)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await notifier.recordPermissionRevoked(dsn: "child-audio", mediaType: .environment)

        await fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(record?.mediaType, MediaTelemetryType.environment.rawValue)
        XCTAssertEqual(record?.reason, L10n.tr("notifications.media.permission_revoked_microphone_body"))
    }

    func testRecordForegroundInterruptedTrimsRecordingIDAndUsesScreenSpecificReason() async {
        let suiteName = "MediaIntegrityNotifierForegroundTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let notifier = MediaIntegrityNotifier(userDefaults: userDefaults)
        let expectation = expectation(description: "foreground telemetry")
        var records: [MediaTelemetryRecord] = []
        let token = NotificationCenter.default.addObserver(
            forName: .mediaTelemetryRecorded,
            object: nil,
            queue: nil
        ) { notification in
            if let record = MediaTelemetryRecord(notification: notification) {
                records.append(record)
                expectation.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await notifier.recordForegroundInterrupted(
            dsn: " child-screen ",
            mediaType: .display,
            recordingID: " rec-screen "
        )

        await fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.dsn, "child-screen")
        XCTAssertEqual(records.first?.event, MediaTelemetryEvent.foregroundInterrupted.rawValue)
        XCTAssertEqual(records.first?.mediaType, MediaTelemetryType.display.rawValue)
        XCTAssertEqual(records.first?.recordingID, "rec-screen")
        XCTAssertEqual(
            records.first?.reason,
            L10n.tr("notifications.media.foreground_interrupted_screen_body")
        )
    }

    func testRecordPermissionRevokedIgnoresBlankDSN() async {
        let suiteName = "MediaIntegrityNotifierBlankDSNTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let notifier = MediaIntegrityNotifier(userDefaults: userDefaults)
        var records: [MediaTelemetryRecord] = []
        let token = NotificationCenter.default.addObserver(
            forName: .mediaTelemetryRecorded,
            object: nil,
            queue: nil
        ) { notification in
            if let record = MediaTelemetryRecord(notification: notification) {
                records.append(record)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        await notifier.recordPermissionRevoked(dsn: "   ", mediaType: .camera)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(records.isEmpty)
    }
}

final class SettingsCacheStoreTests: XCTestCase {
    func testProfileNameTrimsStoredValueAndClearsEmptyInput() {
        let suiteName = "SettingsCacheStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsCacheStore(userDefaults: userDefaults)
        userDefaults.set("  Parent Account  ", forKey: "SETTINGS_CACHE_PROFILE_NAME")

        XCTAssertEqual(store.loadProfileName(), "Parent Account")

        store.saveProfileName("  Updated Parent  ")
        XCTAssertEqual(store.loadProfileName(), "Updated Parent")

        store.saveProfileName("   ")
        XCTAssertNil(store.loadProfileName())
    }

    func testConnectedDevicesRoundTripAndInvalidPayloadFallsBackToEmptyList() {
        let suiteName = "SettingsCacheStoreDevicesTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsCacheStore(userDefaults: userDefaults)
        let devices = [
            ConnectedDevice(
                id: 1,
                dsn: "child-1",
                name: "Kid One",
                avatarURL: URL(string: "https://example.com/one.jpg")
            ),
            ConnectedDevice(id: 2, dsn: nil, name: "Kid Two", avatarURL: nil)
        ]

        store.saveConnectedDevices(devices)
        let loaded = store.loadConnectedDevices()

        XCTAssertEqual(loaded.map(\.id), [1, 2])
        XCTAssertEqual(loaded.first?.avatarURL?.absoluteString, "https://example.com/one.jpg")
        XCTAssertEqual(loaded.last?.name, "Kid Two")

        userDefaults.set(Data("broken".utf8), forKey: "SETTINGS_CACHE_CONNECTED_DEVICES")
        XCTAssertTrue(store.loadConnectedDevices().isEmpty)
    }

    func testConnectedDevicesResolveRelativeAvatarURLsFromLegacyCachePayload() throws {
        let suiteName = "SettingsCacheStoreRelativeAvatarTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        struct CachedConnectedDevice: Codable {
            let id: Int
            let dsn: String?
            let name: String
            let avatarURL: String?
        }

        let payload = [
            CachedConnectedDevice(
                id: 7,
                dsn: "child-7",
                name: "Kid Seven",
                avatarURL: "/uploads/settings/avatar 7.jpg"
            )
        ]
        let data = try JSONEncoder().encode(payload)
        userDefaults.set(data, forKey: "SETTINGS_CACHE_CONNECTED_DEVICES")

        let store = SettingsCacheStore(userDefaults: userDefaults)
        let loaded = store.loadConnectedDevices()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(
            loaded.first?.avatarURL?.absoluteString,
            "https://backend.smart-oila.uz/uploads/settings/avatar%207.jpg"
        )
    }
}

final class ScreenTimeUsageSharedModelsTests: XCTestCase {
    func testSnapshotTotalUsedTimeClampsNegativeEntriesAndDayFormatterBuildsExpectedValues() {
        let date = makeUTCDate(year: 2026, month: 3, day: 11, hour: 18, minute: 45, second: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let snapshot = ScreenTimeUsageSnapshot(
            dsn: "child-usage",
            dayKey: "2026-03-11",
            generatedAt: date,
            entries: [
                ScreenTimeUsageSnapshotEntry(packageName: "com.example.chat", appName: "Chat", usedTime: 125),
                ScreenTimeUsageSnapshotEntry(packageName: "com.example.games", appName: "Games", usedTime: -40)
            ]
        )

        let interval = ScreenTimeUsageDayFormatter.dayInterval(containing: date, calendar: calendar)

        XCTAssertEqual(snapshot.totalUsedTime, 125)
        XCTAssertEqual(interval.start, makeUTCDate(year: 2026, month: 3, day: 11))
        XCTAssertEqual(interval.end, makeUTCDate(year: 2026, month: 3, day: 12))
        XCTAssertEqual(ScreenTimeUsageDayFormatter.dayKey(for: date, calendar: calendar), "2026-03-11")
    }

    func testScreenTimeUsageAppGroupUsesEnvironmentOverrideAndFallback() {
        let key = "SMARTOILA_APP_GROUP_IDENTIFIER"
        let previousValue = getenv(key).map { String(cString: $0) }
        defer {
            if let previousValue {
                setenv(key, previousValue, 1)
            } else {
                unsetenv(key)
            }
        }

        setenv(key, " group.test.screen-time ", 1)
        XCTAssertEqual(ScreenTimeUsageAppGroup.identifier, "group.test.screen-time")
        XCTAssertNotNil(ScreenTimeUsageAppGroup.sharedUserDefaults())

        unsetenv(key)
        XCTAssertEqual(ScreenTimeUsageAppGroup.identifier, "group.3twn5nw4bl.uz.smartoila.kids")
    }
}

final class ScreenTimeUsageSharedStoreTests: XCTestCase {
    func testUnavailableStoreThrowsAndReturnsEmptyState() {
        let store = ScreenTimeUsageSharedStore(userDefaults: nil)

        XCTAssertFalse(store.isAvailable)
        XCTAssertNil(store.loadBridgeConfiguration())
        XCTAssertNil(store.loadSnapshot(dsn: "child-usage"))
        XCTAssertTrue(store.loadSnapshots(dsn: "child-usage", dayKeys: ["2026-03-11"]).isEmpty)
        XCTAssertTrue(store.loadHistoryDayKeys(dsn: "child-usage").isEmpty)

        XCTAssertThrowsError(
            try store.saveBridgeConfiguration(
                ScreenTimeUsageBridgeConfiguration(
                    dsn: "child-usage",
                    dayKey: "2026-03-11",
                    updatedAt: makeUTCDate(year: 2026, month: 3, day: 11)
                )
            )
        ) { error in
            guard case ScreenTimeUsageSharedStoreError.appGroupUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try store.saveSnapshot(
                ScreenTimeUsageSnapshot(
                    dsn: "child-usage",
                    dayKey: "2026-03-11",
                    generatedAt: makeUTCDate(year: 2026, month: 3, day: 11),
                    entries: []
                )
            )
        ) { error in
            guard case ScreenTimeUsageSharedStoreError.appGroupUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        store.clearSnapshot(dsn: "child-usage")
    }

    func testSharedStoreSavesBridgeConfigurationTrimsHistoryAndClearsSnapshots() throws {
        let suiteName = "ScreenTimeUsageSharedStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = ScreenTimeUsageSharedStore(userDefaults: userDefaults)
        let configuration = ScreenTimeUsageBridgeConfiguration(
            dsn: "child-usage",
            dayKey: "2026-03-11",
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        try store.saveBridgeConfiguration(configuration)
        XCTAssertEqual(store.loadBridgeConfiguration(), configuration)

        let dsn = " Child/Usage "
        for day in 1...37 {
            try store.saveSnapshot(
                ScreenTimeUsageSnapshot(
                    dsn: dsn,
                    dayKey: "2026/03/\(String(format: "%02d", day))",
                    generatedAt: Date(timeIntervalSince1970: Double(day)),
                    entries: [
                        ScreenTimeUsageSnapshotEntry(
                            packageName: "com.example.\(day)",
                            appName: "App \(day)",
                            usedTime: day
                        )
                    ]
                )
            )
        }

        let historyDayKeys = store.loadHistoryDayKeys(dsn: dsn)

        XCTAssertEqual(historyDayKeys.count, 35)
        XCTAssertEqual(historyDayKeys.first, "2026_03_37")
        XCTAssertEqual(historyDayKeys.last, "2026_03_03")
        XCTAssertEqual(store.loadSnapshot(dsn: dsn)?.dayKey, "2026/03/37")
        XCTAssertNil(store.loadSnapshot(dsn: dsn, dayKey: "2026/03/01"))
        XCTAssertEqual(store.loadSnapshot(dsn: dsn, dayKey: "2026/03/37")?.entries.first?.packageName, "com.example.37")

        store.clearSnapshot(dsn: dsn)

        XCTAssertNil(store.loadSnapshot(dsn: dsn))
        XCTAssertTrue(store.loadHistoryDayKeys(dsn: dsn).isEmpty)
    }
}

@MainActor
final class ScreenTimeUsageActivitySummaryBuilderTests: XCTestCase {
    func testBuildReturnsUnavailableSummaryWhenAppGroupIsUnavailable() {
        let suiteName = "ScreenTimeUsageActivitySummaryUnavailableTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let selectionStore = DeviceAppLockSelectionStore(
            userDefaults: userDefaults,
            syncUpdate: { _, _ in }
        )

        let summary = ScreenTimeUsageActivitySummaryBuilder.build(
            dsn: "child-usage",
            period: .daily,
            selectionStore: selectionStore,
            sharedStore: ScreenTimeUsageSharedStore(userDefaults: nil),
            calendar: makeUTCCalendar(),
            referenceDate: makeUTCDate(year: 2026, month: 3, day: 11)
        )

        XCTAssertEqual(summary.period, .daily)
        XCTAssertFalse(summary.hasSelection)
        XCTAssertEqual(summary.snapshotCount, 0)
        XCTAssertEqual(summary.totalUsedTime, 0)
        XCTAssertNil(summary.lastUpdatedAt)
        XCTAssertTrue(summary.items.isEmpty)
        XCTAssertFalse(summary.isAppGroupAvailable)
    }

    func testBuildReturnsEmptySummaryForBlankDSN() throws {
        let suiteName = "ScreenTimeUsageActivitySummaryBlankDSNTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = ScreenTimeUsageSharedStore(userDefaults: userDefaults)
        try store.saveSnapshot(
            ScreenTimeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-11",
                generatedAt: makeUTCDate(year: 2026, month: 3, day: 11, hour: 12),
                entries: [
                    ScreenTimeUsageSnapshotEntry(packageName: "com.example.chat", appName: "Chat", usedTime: 60)
                ]
            )
        )

        let selectionStore = DeviceAppLockSelectionStore(
            userDefaults: userDefaults,
            syncUpdate: { _, _ in }
        )

        let summary = ScreenTimeUsageActivitySummaryBuilder.build(
            dsn: "   ",
            period: .daily,
            selectionStore: selectionStore,
            sharedStore: store,
            calendar: makeUTCCalendar(),
            referenceDate: makeUTCDate(year: 2026, month: 3, day: 11)
        )

        XCTAssertEqual(summary, .empty(period: .daily))
    }

    func testBuildDailySummaryUsesOnlyCurrentDaySnapshot() throws {
        let suiteName = "ScreenTimeUsageActivitySummaryDailyTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = ScreenTimeUsageSharedStore(userDefaults: userDefaults)
        try store.saveSnapshot(
            ScreenTimeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-10",
                generatedAt: makeUTCDate(year: 2026, month: 3, day: 10, hour: 10),
                entries: [
                    ScreenTimeUsageSnapshotEntry(packageName: "com.example.other", appName: "Other", usedTime: 30)
                ]
            )
        )
        try store.saveSnapshot(
            ScreenTimeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-11",
                generatedAt: makeUTCDate(year: 2026, month: 3, day: 11, hour: 18),
                entries: [
                    ScreenTimeUsageSnapshotEntry(packageName: " com.example.chat ", appName: " Chat ", usedTime: 120),
                    ScreenTimeUsageSnapshotEntry(packageName: "com.example.games", appName: "Games", usedTime: -50)
                ]
            )
        )

        let selectionStore = DeviceAppLockSelectionStore(
            userDefaults: userDefaults,
            syncUpdate: { _, _ in }
        )
        let summary = ScreenTimeUsageActivitySummaryBuilder.build(
            dsn: " child-usage ",
            period: .daily,
            selectionStore: selectionStore,
            sharedStore: store,
            calendar: makeUTCCalendar(),
            referenceDate: makeUTCDate(year: 2026, month: 3, day: 11, hour: 20)
        )

        XCTAssertEqual(summary.snapshotCount, 1)
        XCTAssertEqual(summary.totalUsedTime, 120)
        XCTAssertEqual(summary.lastUpdatedAt, makeUTCDate(year: 2026, month: 3, day: 11, hour: 18))
        XCTAssertEqual(summary.items.map(\.packageName), ["com.example.chat", "com.example.games"])
        XCTAssertEqual(summary.items.map(\.usedTime), [120, 0])
    }

    func testBuildWeeklySummaryAggregatesSnapshotsAndAppliesLimitMetadata() throws {
        let suiteName = "ScreenTimeUsageActivitySummaryWeeklyTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = ScreenTimeUsageSharedStore(userDefaults: userDefaults)
        try store.saveSnapshot(
            ScreenTimeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-10",
                generatedAt: makeUTCDate(year: 2026, month: 3, day: 10, hour: 9),
                entries: [
                    ScreenTimeUsageSnapshotEntry(packageName: " COM.example.chat ", appName: "Chat", usedTime: 120),
                    ScreenTimeUsageSnapshotEntry(packageName: "com.example.games", appName: "Games", usedTime: -30)
                ]
            )
        )
        try store.saveSnapshot(
            ScreenTimeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-12",
                generatedAt: makeUTCDate(year: 2026, month: 3, day: 12, hour: 18),
                entries: [
                    ScreenTimeUsageSnapshotEntry(packageName: "com.example.chat", appName: "   ", usedTime: 45),
                    ScreenTimeUsageSnapshotEntry(packageName: "com.example.mail", appName: "   ", usedTime: 60)
                ]
            )
        )
        try store.saveSnapshot(
            ScreenTimeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-20",
                generatedAt: makeUTCDate(year: 2026, month: 3, day: 20, hour: 12),
                entries: [
                    ScreenTimeUsageSnapshotEntry(packageName: "com.example.future", appName: "Future", usedTime: 999)
                ]
            )
        )

        let limits = DeviceAppLimitPresentationState(
            status: "loaded",
            dsn: "child-usage",
            endpoint: "/limits",
            remoteLimitCount: 2,
            matchedLimitCount: 2,
            reachedLimitCount: 1,
            items: [
                DeviceAppLimitPresentationItem(
                    packageName: "com.example.mail",
                    appName: "Mail",
                    dailyLimitMinutes: 15,
                    usedTodaySeconds: 60,
                    remainingTodaySeconds: 0,
                    isLimitReached: true
                ),
                DeviceAppLimitPresentationItem(
                    packageName: "com.example.chat",
                    appName: "Chat",
                    dailyLimitMinutes: 30,
                    usedTodaySeconds: 165,
                    remainingTodaySeconds: 600,
                    isLimitReached: false
                )
            ],
            lastError: "-"
        )

        var calendar = makeUTCCalendar()
        calendar.firstWeekday = 2

        let selectionStore = DeviceAppLockSelectionStore(
            userDefaults: userDefaults,
            syncUpdate: { _, _ in }
        )
        let summary = ScreenTimeUsageActivitySummaryBuilder.build(
            dsn: "child-usage",
            period: .weekly,
            selectionStore: selectionStore,
            appLimitState: limits,
            sharedStore: store,
            calendar: calendar,
            referenceDate: makeUTCDate(year: 2026, month: 3, day: 12, hour: 21)
        )

        XCTAssertEqual(summary.snapshotCount, 2)
        XCTAssertEqual(summary.totalUsedTime, 225)
        XCTAssertEqual(summary.lastUpdatedAt, makeUTCDate(year: 2026, month: 3, day: 12, hour: 18))
        XCTAssertEqual(summary.items.map(\.packageName), ["com.example.mail", "com.example.chat", "com.example.games"])
        XCTAssertEqual(summary.items.map(\.appName), ["com.example.mail", "Chat", "Games"])
        XCTAssertEqual(summary.items.map(\.usedTime), [60, 165, 0])
        XCTAssertEqual(summary.items.map(\.dailyLimitMinutes), [15, 30, nil])
        XCTAssertEqual(summary.items.map(\.remainingTodaySeconds), [0, 600, nil])
        XCTAssertEqual(summary.items.map(\.isLimitReached), [true, false, false])
        XCTAssertTrue(summary.items.allSatisfy { $0.isRemotelyLocked == false })
    }

    func testBuildMonthlySummaryOnlyIncludesSnapshotsInCurrentMonth() throws {
        let suiteName = "ScreenTimeUsageActivitySummaryMonthlyTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = ScreenTimeUsageSharedStore(userDefaults: userDefaults)
        try store.saveSnapshot(
            ScreenTimeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-02-28",
                generatedAt: makeUTCDate(year: 2026, month: 2, day: 28, hour: 11),
                entries: [
                    ScreenTimeUsageSnapshotEntry(packageName: "com.example.winter", appName: "Winter", usedTime: 50)
                ]
            )
        )
        try store.saveSnapshot(
            ScreenTimeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-01",
                generatedAt: makeUTCDate(year: 2026, month: 3, day: 1, hour: 9),
                entries: [
                    ScreenTimeUsageSnapshotEntry(packageName: "com.example.spring", appName: "Spring", usedTime: 90)
                ]
            )
        )

        let selectionStore = DeviceAppLockSelectionStore(
            userDefaults: userDefaults,
            syncUpdate: { _, _ in }
        )
        let summary = ScreenTimeUsageActivitySummaryBuilder.build(
            dsn: "child-usage",
            period: .monthly,
            selectionStore: selectionStore,
            sharedStore: store,
            calendar: makeUTCCalendar(),
            referenceDate: makeUTCDate(year: 2026, month: 3, day: 15, hour: 8)
        )

        XCTAssertEqual(summary.snapshotCount, 1)
        XCTAssertEqual(summary.totalUsedTime, 90)
        XCTAssertEqual(summary.items.map(\.packageName), ["com.example.spring"])
        XCTAssertEqual(summary.lastUpdatedAt, makeUTCDate(year: 2026, month: 3, day: 1, hour: 9))
    }
}

final class GeoPayloadEncoderTests: XCTestCase {
    func testEncodeLocationAndSystemInfoProduceExpectedJSONAndSummaries() throws {
        let encoder = GeoPayloadEncoder()
        let now = makeUTCDate(year: 2026, month: 3, day: 11, hour: 12, minute: 34, second: 56)
        let location = CLLocation(latitude: 41.3111, longitude: 69.2797)

        let locationPayload = try encoder.encodeLocation(location, dsn: "child-geo", now: now)
        let locationJSON = try makeJSONObject(from: locationPayload.text)
        let locationData = try XCTUnwrap(locationJSON["data"] as? [String: Any])

        XCTAssertEqual(locationPayload.summary, "location \(expectedGeoSummaryTime(for: now))")
        XCTAssertEqual(locationJSON["event"] as? String, "location")
        XCTAssertEqual(locationData["device_id"] as? String, "child-geo")
        XCTAssertEqual(locationData["device_date"] as? String, expectedGeoDeviceDate(for: now))
        XCTAssertEqual(try XCTUnwrap(locationData["latitude"] as? Double), 41.3111, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(locationData["longitude"] as? Double), 69.2797, accuracy: 0.0001)

        let systemPayload = try encoder.encodeSystemInfo(
            GeoSystemInfoSnapshot(battery: 87, connection: "wifi", soundMode: "mute"),
            now: now
        )
        let systemJSON = try makeJSONObject(from: systemPayload.text)
        let systemData = try XCTUnwrap(systemJSON["data"] as? [String: Any])

        XCTAssertEqual(systemPayload.summary, "system_info \(expectedGeoSummaryTime(for: now))")
        XCTAssertEqual(systemJSON["event"] as? String, "system_info")
        XCTAssertEqual(systemData["battery"] as? String, "87")
        XCTAssertEqual(systemData["connect"] as? String, "wifi")
        XCTAssertEqual(systemData["sound_mode"] as? String, "mute")
    }

    func testEncodeTelemetryPayloadsIncludeAndOmitOptionalFieldsAsExpected() throws {
        let encoder = GeoPayloadEncoder()
        let now = makeUTCDate(year: 2026, month: 3, day: 11, hour: 8, minute: 5, second: 1)

        let controlPayload = try encoder.encodeDeviceControlTelemetry(
            DeviceControlTelemetryRecord(
                dsn: "child-geo",
                event: "device_control_lock_restored",
                packageName: "com.example.chat",
                appName: "Chat",
                createdAt: now
            )
        )
        let controlJSON = try makeJSONObject(from: controlPayload.text)
        let controlData = try XCTUnwrap(controlJSON["data"] as? [String: Any])

        XCTAssertEqual(controlPayload.summary, "device_control device_control_lock_restored \(expectedGeoSummaryTime(for: now))")
        XCTAssertEqual(controlJSON["event"] as? String, "device_control")
        XCTAssertEqual(controlData["package_name"] as? String, "com.example.chat")
        XCTAssertEqual(controlData["app_name"] as? String, "Chat")

        let controlWithoutApp = try encoder.encodeDeviceControlTelemetry(
            DeviceControlTelemetryRecord(
                dsn: "child-geo",
                event: "device_control_lock_restored",
                packageName: nil,
                appName: nil,
                createdAt: now
            )
        )
        let controlWithoutAppData = try XCTUnwrap(
            makeJSONObject(from: controlWithoutApp.text)["data"] as? [String: Any]
        )
        XCTAssertNil(controlWithoutAppData["package_name"])
        XCTAssertNil(controlWithoutAppData["app_name"])

        let mediaPayload = try encoder.encodeMediaTelemetry(
            MediaTelemetryRecord(
                dsn: "child-geo",
                event: "media_recording_started",
                mediaType: "camera",
                recordingID: "rec-7",
                reason: "network",
                createdAt: now
            )
        )
        let mediaJSON = try makeJSONObject(from: mediaPayload.text)
        let mediaData = try XCTUnwrap(mediaJSON["data"] as? [String: Any])

        XCTAssertEqual(mediaPayload.summary, "media_control media_recording_started \(expectedGeoSummaryTime(for: now))")
        XCTAssertEqual(mediaJSON["event"] as? String, "media_control")
        XCTAssertEqual(mediaData["recording_id"] as? String, "rec-7")
        XCTAssertEqual(mediaData["reason"] as? String, "network")

        let mediaWithoutOptionalFields = try encoder.encodeMediaTelemetry(
            MediaTelemetryRecord(
                dsn: "child-geo",
                event: "media_stream_stopped",
                mediaType: "audio_stream",
                recordingID: nil,
                reason: nil,
                createdAt: now
            )
        )
        let mediaWithoutOptionalFieldsData = try XCTUnwrap(
            makeJSONObject(from: mediaWithoutOptionalFields.text)["data"] as? [String: Any]
        )
        XCTAssertNil(mediaWithoutOptionalFieldsData["recording_id"])
        XCTAssertNil(mediaWithoutOptionalFieldsData["reason"])
    }
}

final class GeoPendingPayloadQueueTests: XCTestCase {
    func testQueueEnqueuesRestoresCapsAndDequeuesPersistedPayloads() {
        let suiteName = "GeoPendingPayloadQueueTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let queue = GeoPendingPayloadQueue(maxPayloads: 3, userDefaults: userDefaults)

        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(queue.enqueue(text: "one", summary: "One", dsn: "child-geo"))
        XCTAssertFalse(queue.enqueue(text: "one", summary: "Duplicate", dsn: "child-geo"))
        XCTAssertTrue(queue.enqueue(text: "two", summary: "Two", dsn: "child-geo"))
        XCTAssertTrue(queue.enqueue(text: "three", summary: "Three", dsn: "child-geo"))
        XCTAssertTrue(queue.enqueue(text: "four", summary: "Four", dsn: "child-geo"))

        let restoredQueue = GeoPendingPayloadQueue(maxPayloads: 3, userDefaults: userDefaults)
        XCTAssertEqual(restoredQueue.restore(for: " child-geo "), 3)
        XCTAssertEqual(restoredQueue.count, 3)

        let dequeued = restoredQueue.dequeueAll(dsn: "child-geo")

        XCTAssertEqual(dequeued.map(\.text), ["two", "three", "four"])
        XCTAssertTrue(restoredQueue.isEmpty)
        XCTAssertNil(
            userDefaults.data(
                forKey: DSNScopedStorage.userDefaultsKey(
                    prefix: "GEO_PENDING_PAYLOADS_",
                    dsn: "child-geo",
                    lowercased: true
                )
            )
        )
    }

    func testRestoreInvalidPayloadResetsQueueAndPersistRemovesEmptyState() {
        let suiteName = "GeoPendingPayloadQueueInvalidTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let key = DSNScopedStorage.userDefaultsKey(
            prefix: "GEO_PENDING_PAYLOADS_",
            dsn: "child-geo",
            lowercased: true
        )
        userDefaults.set(Data("broken".utf8), forKey: key)

        let queue = GeoPendingPayloadQueue(userDefaults: userDefaults)

        XCTAssertEqual(queue.restore(for: "child-geo"), 0)
        XCTAssertTrue(queue.isEmpty)

        queue.persist(for: "child-geo")
        XCTAssertNil(userDefaults.data(forKey: key))
    }
}

@MainActor
final class GeoServiceTimersTests: XCTestCase {
    func testStartInvokesTickClosuresAndStopCancelsScheduledTimers() {
        let locationExpectation = expectation(description: "location tick")
        let systemInfoExpectation = expectation(description: "system info tick")
        let locationAfterStopExpectation = expectation(description: "location tick after stop")
        locationAfterStopExpectation.isInverted = true
        let systemInfoAfterStopExpectation = expectation(description: "system info tick after stop")
        systemInfoAfterStopExpectation.isInverted = true

        var locationTickCount = 0
        var systemInfoTickCount = 0
        var didStop = false

        var timers: GeoServiceTimers? = GeoServiceTimers(
            locationInterval: 0.05,
            systemInfoInterval: 0.05,
            onLocationTick: {
                locationTickCount += 1
                if didStop {
                    locationAfterStopExpectation.fulfill()
                } else if locationTickCount == 1 {
                    locationExpectation.fulfill()
                }
            },
            onSystemInfoTick: {
                systemInfoTickCount += 1
                if didStop {
                    systemInfoAfterStopExpectation.fulfill()
                } else if systemInfoTickCount == 1 {
                    systemInfoExpectation.fulfill()
                }
            }
        )

        timers?.start()
        wait(for: [locationExpectation, systemInfoExpectation], timeout: 1)

        didStop = true
        timers?.stop()
        let stoppedLocationCount = locationTickCount
        let stoppedSystemInfoCount = systemInfoTickCount

        wait(
            for: [locationAfterStopExpectation, systemInfoAfterStopExpectation],
            timeout: 0.15
        )

        XCTAssertEqual(locationTickCount, stoppedLocationCount)
        XCTAssertEqual(systemInfoTickCount, stoppedSystemInfoCount)

        timers = nil
    }
}

final class SettingsDiagnosticsValueMapperTests: XCTestCase {
    func testTimestampThemeAndLanguageMappings() {
        let date = makeUTCDate(year: 2026, month: 3, day: 11, hour: 14, minute: 5, second: 9)

        XCTAssertEqual(SettingsDiagnosticsValueMapper.timestamp(nil), "-")
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.timestamp(date),
            date.formatted(
                Date.FormatStyle()
                    .year()
                    .month(.twoDigits)
                    .day(.twoDigits)
                    .hour(.twoDigits(amPM: .omitted))
                    .minute(.twoDigits)
                    .second(.twoDigits)
            )
        )
        XCTAssertEqual(SettingsDiagnosticsValueMapper.theme(.system), L10n.tr("settings.theme.system"))
        XCTAssertEqual(SettingsDiagnosticsValueMapper.theme(.light), L10n.tr("settings.theme.light"))
        XCTAssertEqual(SettingsDiagnosticsValueMapper.theme(.dark), L10n.tr("settings.theme.dark"))
        XCTAssertEqual(SettingsDiagnosticsValueMapper.language(.en), L10n.tr("settings.language.en"))
        XCTAssertEqual(SettingsDiagnosticsValueMapper.language(.ru), L10n.tr("settings.language.ru"))
        XCTAssertEqual(SettingsDiagnosticsValueMapper.language(.uz), L10n.tr("settings.language.uz"))
    }

    func testPermissionStatusMappingsCoverKnownCases() {
        XCTAssertEqual(SettingsDiagnosticsValueMapper.locationStatus(.authorizedAlways), "authorizedAlways")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.locationStatus(.authorizedWhenInUse), "authorizedWhenInUse")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.locationStatus(.denied), "denied")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.locationStatus(.restricted), "restricted")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.locationStatus(.notDetermined), "notDetermined")

        XCTAssertEqual(SettingsDiagnosticsValueMapper.notificationStatus(.authorized), "authorized")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.notificationStatus(.provisional), "provisional")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.notificationStatus(.ephemeral), "ephemeral")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.notificationStatus(.denied), "denied")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.notificationStatus(.notDetermined), "notDetermined")

        XCTAssertEqual(SettingsDiagnosticsValueMapper.microphoneStatus(.granted), "granted")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.microphoneStatus(.denied), "denied")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.microphoneStatus(.undetermined), "undetermined")

        XCTAssertEqual(SettingsDiagnosticsValueMapper.cameraStatus(.authorized), "authorized")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.cameraStatus(.denied), "denied")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.cameraStatus(.restricted), "restricted")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.cameraStatus(.notDetermined), "notDetermined")

        XCTAssertEqual(SettingsDiagnosticsValueMapper.displayCaptureStatus(.ready), "ready")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.displayCaptureStatus(.inactive), "inactive")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.displayCaptureStatus(.unavailable), "unavailable")

        XCTAssertEqual(SettingsDiagnosticsValueMapper.screenTimeStatus(.notDetermined), "notDetermined")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.screenTimeStatus(.denied), "denied")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.screenTimeStatus(.granted), "granted")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.screenTimeStatus(.unavailable), "unavailable")

        XCTAssertEqual(SettingsDiagnosticsValueMapper.backgroundRefreshStatus(.available), "available")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.backgroundRefreshStatus(.denied), "denied")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.backgroundRefreshStatus(.restricted), "restricted")
    }

    func testGeoTrackingReadinessReflectsLinkingAndPermissionState() {
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoTrackingReadiness(
                dsn: nil,
                locationAuthorizationStatus: .authorizedAlways
            ),
            .notLinked
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoTrackingReadiness(
                dsn: " - ",
                locationAuthorizationStatus: .authorizedAlways
            ),
            .notLinked
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoTrackingReadiness(
                dsn: "child-dsn",
                locationAuthorizationStatus: .authorizedAlways
            ),
            .backgroundReady
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoTrackingReadiness(
                dsn: "child-dsn",
                locationAuthorizationStatus: .authorizedWhenInUse
            ),
            .foregroundOnly
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoTrackingReadiness(
                dsn: "child-dsn",
                locationAuthorizationStatus: .notDetermined
            ),
            .notAuthorized
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoTrackingReadiness(
                dsn: "child-dsn",
                locationAuthorizationStatus: .denied
            ),
            .notAuthorized
        )
    }

    func testGeoFormattingHelpersExposeCoordinateAccuracyAndAge() {
        let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 7, minute: 10, second: 5)

        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoCoordinates(latitude: 41.302468, longitude: 69.250246),
            "41.302468, 69.250246"
        )
        XCTAssertEqual(SettingsDiagnosticsValueMapper.geoCoordinates(latitude: nil, longitude: 69.250246), "-")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.geoAccuracy(12.34), "12.3 m")
        XCTAssertEqual(SettingsDiagnosticsValueMapper.geoAccuracy(150.8), "151 m")
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoFixAge(
                since: date,
                now: date.addingTimeInterval(125)
            ),
            "2m ago"
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoParentVisibilityStatus("checking"),
            L10n.tr("diagnostics.geo_parent_visibility_value_checking")
        )
        XCTAssertEqual(SettingsDiagnosticsValueMapper.geoFixAge(since: nil), "-")
    }

    func testGeoSettingsSummaryAndBadgeReflectReadinessAndFixFreshness() {
        let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 7, minute: 10, second: 5)

        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoSettingsSummary(
                readiness: .backgroundReady,
                lastLocationAt: date,
                now: date.addingTimeInterval(30)
            ),
            "Geo: \(L10n.tr("diagnostics.geo_readiness_value_background_ready")) • Fix 30s ago"
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoSettingsSummary(
                readiness: .foregroundOnly,
                lastLocationAt: nil
            ),
            "Geo: \(L10n.tr("diagnostics.geo_readiness_value_foreground_only")) • No fix yet"
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoSettingsSummary(
                readiness: .notAuthorized,
                lastLocationAt: nil
            ),
            "Geo: \(L10n.tr("diagnostics.geo_readiness_value_not_authorized"))"
        )

        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoSettingsBadgeState(
                readiness: .backgroundReady,
                lastLocationAt: date,
                now: date.addingTimeInterval(120)
            ),
            .live
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoSettingsBadgeState(
                readiness: .backgroundReady,
                lastLocationAt: date,
                now: date.addingTimeInterval(600)
            ),
            .stale
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoSettingsBadgeState(
                readiness: .backgroundReady,
                lastLocationAt: nil
            ),
            .waitingForFix
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoSettingsBadgeText(.foregroundOnly),
            L10n.tr("diagnostics.geo_readiness_badge_foreground_only")
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.geoSettingsBadgeText(.live),
            L10n.tr("settings.diagnostics_geo_badge_live")
        )
    }

    func testMainGeoTrackingSummaryAndDetailExposeParentVisibleState() {
        let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 7, minute: 10, second: 5)

        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.mainGeoTrackingSummary(
                readiness: .backgroundReady,
                lastLocationAt: date,
                now: date.addingTimeInterval(45)
            ),
            "\(L10n.tr("diagnostics.geo_readiness_value_background_ready")) • Fix 45s ago"
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.mainGeoTrackingSummary(
                readiness: .notLinked,
                lastLocationAt: nil
            ),
            L10n.tr("diagnostics.geo_readiness_value_not_linked")
        )

        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.mainGeoTrackingDetail(
                readiness: .backgroundReady,
                parentLatitude: 41.302468,
                parentLongitude: 69.250246,
                localLatitude: nil,
                localLongitude: nil
            ),
            "Parent sees: 41.302468, 69.250246"
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.mainGeoTrackingDetail(
                readiness: .foregroundOnly,
                parentLatitude: nil,
                parentLongitude: nil,
                localLatitude: 41.302468,
                localLongitude: 69.250246
            ),
            "Phone fix: 41.302468, 69.250246 • waiting for parent-visible update"
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.mainGeoTrackingDetail(
                readiness: .notAuthorized,
                parentLatitude: nil,
                parentLongitude: nil,
                localLatitude: nil,
                localLongitude: nil
            ),
            L10n.tr("main.parent_tracking_not_authorized")
        )
    }

    func testMainGeoTrackingVerificationNoteAndActionReflectParentCheckState() {
        let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 8, minute: 20, second: 0)

        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.mainGeoTrackingVerificationNote(
                parentVisibilityStatus: "visible",
                checkedAt: date,
                now: date.addingTimeInterval(25)
            ),
            "Parent-visible location verified 25s ago."
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.mainGeoTrackingVerificationNote(
                parentVisibilityStatus: "not_visible",
                checkedAt: date,
                now: date.addingTimeInterval(125)
            ),
            "Last check 2m ago has not reached the parent yet."
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.mainGeoTrackingVerificationNote(
                parentVisibilityStatus: "checking",
                checkedAt: nil
            ),
            L10n.tr("main.parent_tracking_checking")
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.mainGeoTrackingActionTitle(
                readiness: .backgroundReady,
                locationActionTitle: nil,
                parentVisibilityStatus: "idle"
            ),
            L10n.tr("main.parent_tracking_action_check_now")
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.mainGeoTrackingActionTitle(
                readiness: .backgroundReady,
                locationActionTitle: nil,
                parentVisibilityStatus: "checking"
            ),
            L10n.tr("main.parent_tracking_action_checking")
        )
        XCTAssertEqual(
            SettingsDiagnosticsValueMapper.mainGeoTrackingActionTitle(
                readiness: .notAuthorized,
                locationActionTitle: L10n.tr("permissions.action_allow_location_always"),
                parentVisibilityStatus: "idle"
            ),
            L10n.tr("permissions.action_allow_location_always")
        )
        XCTAssertNil(
            SettingsDiagnosticsValueMapper.mainGeoTrackingActionTitle(
                readiness: .notLinked,
                locationActionTitle: nil,
                parentVisibilityStatus: "idle"
            )
        )
    }
}

@MainActor
final class RuntimeDiagnosticsHistoryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RuntimeDiagnosticsCenter.shared.resetLifecycle()
        RuntimeDiagnosticsCenter.shared.resetPush()
        RuntimeDiagnosticsCenter.shared.resetGeo()
    }

    override func tearDown() {
        RuntimeDiagnosticsCenter.shared.resetLifecycle()
        RuntimeDiagnosticsCenter.shared.resetPush()
        RuntimeDiagnosticsCenter.shared.resetGeo()
        super.tearDown()
    }

    func testLifecycleHistoryKeepsMostRecentEightEntries() {
        for index in 0..<10 {
            let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 5, minute: index, second: 0)
            RuntimeDiagnosticsCenter.shared.updateLifecycle(
                scenePhase: index.isMultiple(of: 2) ? "active" : "background",
                applicationState: index.isMultiple(of: 2) ? "active" : "background",
                lastEvent: "scene_transition_\(index)",
                lastForegroundAt: index.isMultiple(of: 2) ? date : nil,
                lastBackgroundAt: index.isMultiple(of: 2) ? nil : date,
                eventDate: date
            )
        }

        let snapshot = RuntimeDiagnosticsCenter.shared.lifecycle

        XCTAssertEqual(snapshot.lastEvent, "scene_transition_9")
        XCTAssertEqual(snapshot.lastBackgroundAt, makeUTCDate(year: 2026, month: 3, day: 12, hour: 5, minute: 9, second: 0))
        XCTAssertEqual(snapshot.recentEvents.count, 8)
        XCTAssertFalse(snapshot.recentEvents.contains(where: { $0.contains("scene_transition_0") }))
        XCTAssertFalse(snapshot.recentEvents.contains(where: { $0.contains("scene_transition_1") }))
        XCTAssertTrue(snapshot.recentEvents.first?.contains("scene_transition_2") ?? false)
        XCTAssertTrue(snapshot.recentEvents.last?.contains("scene_transition_9") ?? false)
    }

    func testPushHistoryKeepsMostRecentEightEntries() {
        for index in 0..<10 {
            let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 6, minute: index, second: 0)
            RuntimeDiagnosticsCenter.shared.updatePush(
                status: "routed",
                dsn: "child-\(index)",
                lastEvent: "burst_\(index)",
                lastRoute: "chat_refresh",
                deliveryContext: "background_fetch",
                inboxTotalCount: index + 1,
                sessionUnreadCount: index,
                badgeCount: index,
                eventDate: date
            )
        }

        let snapshot = RuntimeDiagnosticsCenter.shared.push

        XCTAssertEqual(snapshot.lastEvent, "burst_9")
        XCTAssertEqual(snapshot.recentEvents.count, 8)
        XCTAssertFalse(snapshot.recentEvents.contains(where: { $0.contains("burst_0") }))
        XCTAssertFalse(snapshot.recentEvents.contains(where: { $0.contains("burst_1") }))
        XCTAssertTrue(snapshot.recentEvents.first?.contains("burst_2") ?? false)
        XCTAssertTrue(snapshot.recentEvents.last?.contains("burst_9") ?? false)
        XCTAssertTrue(snapshot.recentEvents.last?.contains("badge=9") ?? false)
    }

    func testGeoHistoryKeepsMostRecentEightEntries() {
        for index in 0..<10 {
            let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 7, minute: index, second: 0)
            RuntimeDiagnosticsCenter.shared.updateGeo(
                status: index.isMultiple(of: 2) ? "connected" : "reconnecting",
                endpoint: "/children/device/child-geo/geo/\(index)",
                dsn: "child-geo",
                lastPayload: "location \(index)",
                lastError: index.isMultiple(of: 2) ? "-" : "socket not connected",
                reconnectCount: index,
                lastLatitude: 41.300000 + (Double(index) * 0.001),
                lastLongitude: 69.250000 + (Double(index) * 0.001),
                lastLocationAt: date.addingTimeInterval(-30),
                lastHorizontalAccuracy: Double(index) + 0.5,
                eventDate: date
            )
        }

        let snapshot = RuntimeDiagnosticsCenter.shared.geo

        XCTAssertEqual(snapshot.reconnectCount, 9)
        XCTAssertNotNil(snapshot.lastLatitude)
        XCTAssertNotNil(snapshot.lastLongitude)
        XCTAssertEqual(
            snapshot.lastLocationAt,
            makeUTCDate(year: 2026, month: 3, day: 12, hour: 7, minute: 8, second: 30)
        )
        XCTAssertNotNil(snapshot.lastHorizontalAccuracy)
        XCTAssertEqual(snapshot.lastLatitude ?? 0, 41.309000, accuracy: 0.000001)
        XCTAssertEqual(snapshot.lastLongitude ?? 0, 69.259000, accuracy: 0.000001)
        XCTAssertEqual(snapshot.lastHorizontalAccuracy ?? 0, 9.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.recentEvents.count, 8)
        XCTAssertFalse(snapshot.recentEvents.contains(where: { $0.contains("location 0") }))
        XCTAssertFalse(snapshot.recentEvents.contains(where: { $0.contains("location 1") }))
        XCTAssertTrue(snapshot.recentEvents.first?.contains("location 2") ?? false)
        XCTAssertTrue(snapshot.recentEvents.last?.contains("location 9") ?? false)
        XCTAssertTrue(snapshot.recentEvents.last?.contains("coord=41.309000,69.259000") ?? false)
        XCTAssertTrue(snapshot.recentEvents.last?.contains("accuracy=9.5m") ?? false)
        XCTAssertTrue(snapshot.recentEvents.last?.contains("retries=9") ?? false)
        XCTAssertTrue(snapshot.recentEvents.last?.contains("error=socket not connected") ?? false)
    }

    func testGeoSnapshotCanRefreshLocationMetadataWithoutAppendingHistory() {
        let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 7, minute: 42, second: 11)

        RuntimeDiagnosticsCenter.shared.updateGeo(
            status: "connected",
            dsn: "child-geo",
            lastLatitude: 41.302468,
            lastLongitude: 69.250246,
            lastLocationAt: date,
            lastHorizontalAccuracy: 12.3,
            recordEvent: false,
            eventDate: date
        )

        let snapshot = RuntimeDiagnosticsCenter.shared.geo

        XCTAssertNotNil(snapshot.lastLatitude)
        XCTAssertNotNil(snapshot.lastLongitude)
        XCTAssertEqual(snapshot.lastLocationAt, date)
        XCTAssertNotNil(snapshot.lastHorizontalAccuracy)
        XCTAssertEqual(snapshot.lastLatitude ?? 0, 41.302468, accuracy: 0.000001)
        XCTAssertEqual(snapshot.lastLongitude ?? 0, 69.250246, accuracy: 0.000001)
        XCTAssertEqual(snapshot.lastHorizontalAccuracy ?? 0, 12.3, accuracy: 0.0001)
        XCTAssertTrue(snapshot.recentEvents.isEmpty)
    }

    func testGeoSnapshotStoresParentVisibilityVerification() {
        let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 8, minute: 2, second: 10)

        RuntimeDiagnosticsCenter.shared.updateGeoParentVisibility(
            status: "visible",
            latitude: 41.302468,
            longitude: 69.250246,
            checkedAt: date
        )

        let snapshot = RuntimeDiagnosticsCenter.shared.geo

        XCTAssertEqual(snapshot.parentVisibilityStatus, "visible")
        XCTAssertEqual(snapshot.parentVisibleLatitude ?? 0, 41.302468, accuracy: 0.000001)
        XCTAssertEqual(snapshot.parentVisibleLongitude ?? 0, 69.250246, accuracy: 0.000001)
        XCTAssertEqual(snapshot.parentVisibilityCheckedAt, date)
        XCTAssertTrue(snapshot.recentEvents.last?.contains("parent=visible") ?? false)
        XCTAssertTrue(snapshot.recentEvents.last?.contains("parent_coord=41.302468,69.250246") ?? false)
    }
}

final class DiagnosticsExportArtifactTests: XCTestCase {
    func testMakeFilenameUsesSanitizedDSNAndStableTimestamp() {
        let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 4, minute: 7, second: 9)

        let filename = DiagnosticsExportArtifact.makeFilename(
            dsn: " Child 5 / QA ",
            now: date
        )

        XCTAssertEqual(
            filename,
            "smart_oila_kids_diagnostics_child-5-qa_2026-03-12_04-07-09Z.txt"
        )
    }

    func testMakeFilenameFallsBackWhenDSNIsMissing() {
        let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 4, minute: 7, second: 9)

        let filename = DiagnosticsExportArtifact.makeFilename(
            dsn: "   ",
            now: date
        )

        XCTAssertEqual(
            filename,
            "smart_oila_kids_diagnostics_no-dsn_2026-03-12_04-07-09Z.txt"
        )
    }

    func testCreateWritesNamedUTF8Artifact() throws {
        let date = makeUTCDate(year: 2026, month: 3, day: 12, hour: 4, minute: 7, second: 9)
        let text = "Smart Oila Kids Diagnostics Snapshot\nstate: ok"

        let artifact = try DiagnosticsExportArtifact.create(
            text: text,
            dsn: "Child-7",
            now: date
        )
        defer { try? FileManager.default.removeItem(at: artifact.fileURL) }

        XCTAssertEqual(
            artifact.fileURL.lastPathComponent,
            "smart_oila_kids_diagnostics_child-7_2026-03-12_04-07-09Z.txt"
        )
        XCTAssertEqual(artifact.text, text)
        XCTAssertEqual(try String(contentsOf: artifact.fileURL, encoding: .utf8), text)
    }
}

@MainActor
final class SettingsBannerCenterTests: XCTestCase {
    func testShowSetsBannerTextAndHidesAfterDuration() async {
        let center = SettingsBannerCenter()

        center.show("Saved", duration: 0.01)
        XCTAssertEqual(center.text, "Saved")

        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertNil(center.text)
    }

    func testShowCancelsPreviousHideTaskWhenReplacingBanner() async {
        let center = SettingsBannerCenter()

        center.show("First", duration: 0.01)
        center.show("Second", duration: 0.05)

        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(center.text, "Second")

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(center.text)
    }
}

final class ChatUtilityTests: XCTestCase {
    func testChatParentRowsBuilderBuildsPlaceholderAndLiveRowsForPreviewVariants() {
        let builder = ChatParentRowsBuilder()

        let placeholderRows = builder.build(
            flatMessages: [],
            parentDisplayName: "  Mom  ",
            unreadParentCount: 2
        )
        XCTAssertEqual(placeholderRows.count, 1)
        XCTAssertEqual(placeholderRows.first?.id, "placeholder-parent")
        XCTAssertEqual(placeholderRows.first?.name, "Mom")
        XCTAssertEqual(placeholderRows.first?.preview, L10n.tr("chat.default_preview"))
        XCTAssertEqual(placeholderRows.first?.unreadCount, 2)

        let attachmentRows = builder.build(
            flatMessages: [
                Datum(userType: "parent", text: nil, attachments: ["https://example.com/photo.jpg"], time: "2026-03-11T10:00:00Z", senderName: " Parent ")
            ],
            parentDisplayName: nil,
            unreadParentCount: 1
        )
        XCTAssertEqual(attachmentRows.first?.name, "Parent")
        XCTAssertEqual(attachmentRows.first?.preview, L10n.tr("chat.attachment"))
        XCTAssertEqual(attachmentRows.first?.unreadCount, 1)

        let defaultRows = builder.build(
            flatMessages: [
                Datum(userType: "child", text: nil, attachments: [], time: "2026-03-11T11:00:00Z")
            ],
            parentDisplayName: nil,
            unreadParentCount: 0
        )
        XCTAssertEqual(defaultRows.first?.name, L10n.tr("chat.parent"))
        XCTAssertEqual(defaultRows.first?.preview, L10n.tr("chat.default_preview"))

        let textRows = builder.build(
            flatMessages: [
                Datum(userType: "parent", text: "Hello from parent", attachments: [], time: "2026-03-11T12:00:00Z")
            ],
            parentDisplayName: " Guardian ",
            unreadParentCount: 0
        )
        XCTAssertEqual(textRows.first?.name, "Guardian")
        XCTAssertEqual(textRows.first?.preview, "Hello from parent")
    }

    func testChatTimestampParsesFormatsAndFallsBackToLexicographicComparison() {
        XCTAssertNotNil(ChatTimestamp.parse("2026-03-11T10:15:30.123Z"))
        XCTAssertNotNil(ChatTimestamp.parse("2026-03-11T10:15:30Z"))
        XCTAssertNotNil(ChatTimestamp.parse("2026-03-11T10:15:30"))
        XCTAssertNil(ChatTimestamp.parse("   "))

        XCTAssertEqual(
            ChatTimestamp.compare("2026-03-11T10:15:30Z", "2026-03-11T10:16:30Z"),
            .orderedAscending
        )
        XCTAssertEqual(
            ChatTimestamp.compare("2026-03-11T10:16:30Z", "2026-03-11T10:15:30Z"),
            .orderedDescending
        )
        XCTAssertEqual(ChatTimestamp.compare("Beta", "alpha"), .orderedDescending)
        XCTAssertEqual(ChatTimestamp.dateKey(from: "2026-03-11T10:15:30Z"), "2026-03-11")
        XCTAssertEqual(ChatTimestamp.dateKey(from: "short"), "short")
    }
}

@MainActor
final class MiscUtilityTests: XCTestCase {
    func testLegacyClientDateFormattingAndAppHapticsFunctionsAreCallable() {
        let date = makeUTCDate(year: 2026, month: 3, day: 11, hour: 9, minute: 8, second: 7)

        XCTAssertEqual(date.formattedLegacyClientDate(), expectedLegacyClientDate(for: date))

        AppHaptics.tap()
        AppHaptics.success()
        AppHaptics.warning()
        AppHaptics.selection()
    }
}

@MainActor
final class SettingsViewModelDeviceTests: XCTestCase {
    func testRenameDeviceUpdatesConnectedDeviceCache() async throws {
        let updated = ConnectedDevice(id: 1, dsn: "child-1", name: "Renamed Kid", avatarURL: nil)
        let service = SettingsServiceSpy(renameConnectedDeviceResult: .success(updated))
        let cacheStore = SettingsCacheStoreSpy(cachedDevices: [
            ConnectedDevice(id: 1, dsn: "child-1", name: "Old Kid", avatarURL: nil)
        ])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices(cacheStore.loadConnectedDevices())
        viewModel.runtime.hasLoadedRemoteDeviceNames = true

        let name = try await viewModel.renameDevice(deviceID: 1, name: "Renamed Kid")

        XCTAssertEqual(name, "Renamed Kid")
        XCTAssertEqual(service.renameCalls.count, 1)
        XCTAssertEqual(service.renameCalls.first?.0, 1)
        XCTAssertEqual(service.renameCalls.first?.1, "Renamed Kid")
        XCTAssertEqual(viewModel.connectedDevices.first?.name, "Renamed Kid")
        XCTAssertEqual(cacheStore.savedConnectedDevicesSnapshots.last?.first?.name, "Renamed Kid")
        XCTAssertFalse(viewModel.isUpdatingDevice)
    }

    func testDeleteDeviceForCurrentDSNClearsRemoteProfileName() async throws {
        let current = ConnectedDevice(id: 1, dsn: "child-1", name: "Current Kid", avatarURL: nil)
        let sibling = ConnectedDevice(id: 2, dsn: "child-2", name: "Sibling", avatarURL: nil)
        let service = SettingsServiceSpy()
        let cacheStore = SettingsCacheStoreSpy(cachedProfileName: "Current Kid", cachedDevices: [current, sibling])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices([current, sibling])
        viewModel.setRemoteProfileName("Current Kid")
        viewModel.runtime.currentDSN = "child-1"
        viewModel.runtime.hasLoadedRemoteDeviceNames = true

        let deletedCurrent = try await viewModel.deleteDevice(deviceID: 1)

        XCTAssertTrue(deletedCurrent)
        XCTAssertEqual(service.deletedDeviceIDs, [1])
        XCTAssertEqual(viewModel.connectedDevices.map(\.id), [2])
        XCTAssertNil(viewModel.remoteProfileName)
        XCTAssertNil(cacheStore.savedProfileNames.last!)
    }

    func testUploadCurrentDeviceAvatarResolvesMissingDeviceAndCachesUploadedAvatar() async throws {
        let resolved = ConnectedDevice(id: 7, dsn: "child-7", name: "Resolved Kid", avatarURL: nil)
        let uploaded = ConnectedDevice(
            id: 7,
            dsn: "child-7",
            name: "Resolved Kid",
            avatarURL: URL(string: "https://example.com/avatar-7.jpg")
        )
        let service = SettingsServiceSpy(
            resolveConnectedDeviceResult: .success(resolved),
            uploadConnectedDeviceAvatarResult: .success(uploaded)
        )
        let cacheStore = SettingsCacheStoreSpy()
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.runtime.hasLoadedRemoteDeviceNames = true

        let avatarURL = try await viewModel.uploadCurrentDeviceAvatar(
            dsn: " child-7 ",
            imageData: Data([0x01, 0x02, 0x03])
        )

        XCTAssertEqual(service.resolvedDSNs, ["child-7"])
        XCTAssertEqual(service.uploadCalls.map(\.0), [7])
        XCTAssertEqual(avatarURL?.absoluteString, "https://example.com/avatar-7.jpg")
        XCTAssertEqual(viewModel.connectedDevices.first?.avatarURL?.absoluteString, "https://example.com/avatar-7.jpg")
        XCTAssertEqual(cacheStore.savedConnectedDevicesSnapshots.count, 3)
        XCTAssertEqual(cacheStore.savedConnectedDevicesSnapshots.last?.first?.id, 7)
        XCTAssertFalse(viewModel.isUploadingAvatar)
    }

    func testUploadCurrentDeviceAvatarFallsBackToDSNUploadWhenDeviceUploadIsAuthScoped() async throws {
        let current = ConnectedDevice(id: 8, dsn: "child-8", name: "Current Kid", avatarURL: nil)
        let fallbackURL = try XCTUnwrap(URL(string: "https://backend.smart-oila.uz/uploads/devices/avatar-8.jpg"))
        let service = SettingsServiceSpy(
            uploadConnectedDeviceAvatarResult: .failure(NetworkError.server(statusCode: 403, body: "forbidden")),
            uploadConnectedDeviceAvatarByDSNResult: .success(fallbackURL)
        )
        let cacheStore = SettingsCacheStoreSpy(cachedDevices: [current])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices([current])
        viewModel.runtime.hasLoadedRemoteDeviceNames = true

        let avatarURL = try await viewModel.uploadCurrentDeviceAvatar(
            dsn: " child-8 ",
            imageData: Data([0x05, 0x06, 0x07])
        )

        XCTAssertEqual(service.uploadCalls.map(\.0), [8])
        XCTAssertEqual(service.uploadDSNCalls.map(\.0), ["child-8"])
        XCTAssertEqual(avatarURL, fallbackURL)
        XCTAssertEqual(viewModel.connectedDevices.first?.avatarURL, fallbackURL)
        XCTAssertEqual(cacheStore.savedConnectedDevicesSnapshots.last?.first?.avatarURL, fallbackURL)
        XCTAssertFalse(viewModel.isUploadingAvatar)
    }

    func testUploadCurrentDeviceAvatarResolvesRemoteDeviceWhenCacheOnlyHasSyntheticPlaceholder() async throws {
        let placeholder = ConnectedDevice(id: -131, dsn: "child-18", name: "Current Device", avatarURL: nil)
        let resolved = ConnectedDevice(id: 18, dsn: "child-18", name: "Resolved Kid", avatarURL: nil)
        let uploaded = ConnectedDevice(
            id: 18,
            dsn: "child-18",
            name: "Resolved Kid",
            avatarURL: URL(string: "https://example.com/avatar-18.jpg")
        )
        let service = SettingsServiceSpy(
            resolveConnectedDeviceResult: .success(resolved),
            uploadConnectedDeviceAvatarResult: .success(uploaded)
        )
        let cacheStore = SettingsCacheStoreSpy(cachedDevices: [placeholder])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices([placeholder])
        viewModel.runtime.hasLoadedRemoteDeviceNames = true

        let avatarURL = try await viewModel.uploadCurrentDeviceAvatar(
            dsn: " child-18 ",
            imageData: Data([0x08, 0x09, 0x0A])
        )

        XCTAssertEqual(service.resolvedDSNs, ["child-18"])
        XCTAssertEqual(service.uploadCalls.map(\.0), [18])
        XCTAssertEqual(avatarURL?.absoluteString, "https://example.com/avatar-18.jpg")
        XCTAssertEqual(viewModel.connectedDevices.first?.id, 18)
        XCTAssertEqual(viewModel.connectedDevices.first?.avatarURL?.absoluteString, "https://example.com/avatar-18.jpg")
    }

    func testDeleteCurrentDeviceSessionRemovesCachedCurrentDeviceAndClearsProfile() async throws {
        let current = ConnectedDevice(id: 9, dsn: "child-9", name: "Current Kid", avatarURL: nil)
        let sibling = ConnectedDevice(id: 10, dsn: "child-10", name: "Sibling", avatarURL: nil)
        let service = SettingsServiceSpy()
        let cacheStore = SettingsCacheStoreSpy(cachedProfileName: "Current Kid", cachedDevices: [current, sibling])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices([current, sibling])
        viewModel.setRemoteProfileName("Current Kid")
        viewModel.runtime.currentDSN = "child-9"
        viewModel.runtime.hasLoadedRemoteDeviceNames = true

        try await viewModel.deleteCurrentDeviceSession(dsn: "child-9")

        XCTAssertEqual(service.deletedDeviceIDs, [9])
        XCTAssertEqual(viewModel.connectedDevices.map(\.id), [10])
        XCTAssertNil(viewModel.remoteProfileName)
        XCTAssertNil(cacheStore.savedProfileNames.last!)
    }

    func testDeleteCurrentDeviceSessionResolvesRemoteDeviceWhenCacheOnlyHasSyntheticPlaceholder() async throws {
        let placeholder = ConnectedDevice(id: -101, dsn: "child-15", name: "Current Device", avatarURL: nil)
        let resolved = ConnectedDevice(id: 15, dsn: "child-15", name: "Current Kid", avatarURL: nil)
        let service = SettingsServiceSpy(resolveConnectedDeviceResult: .success(resolved))
        let cacheStore = SettingsCacheStoreSpy(cachedProfileName: "Current Kid", cachedDevices: [placeholder])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices([placeholder])
        viewModel.setRemoteProfileName("Current Kid")
        viewModel.runtime.currentDSN = "child-15"
        viewModel.runtime.hasLoadedRemoteDeviceNames = true

        try await viewModel.deleteCurrentDeviceSession(dsn: "child-15")

        XCTAssertEqual(service.resolvedDSNs, ["child-15"])
        XCTAssertEqual(service.deletedDeviceIDs, [15])
        XCTAssertTrue(viewModel.connectedDevices.isEmpty)
        XCTAssertNil(viewModel.remoteProfileName)
    }
}

@MainActor
final class SettingsViewModelProfileTests: XCTestCase {
    func testSaveProfileNameRenamesCurrentConnectedDeviceAndCachesResult() async throws {
        let updated = ConnectedDevice(id: 11, dsn: "child-11", name: "Renamed Current", avatarURL: nil)
        let service = SettingsServiceSpy(renameConnectedDeviceResult: .success(updated))
        let cacheStore = SettingsCacheStoreSpy(cachedDevices: [
            ConnectedDevice(id: 11, dsn: "child-11", name: "Before", avatarURL: nil)
        ])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices(cacheStore.loadConnectedDevices())
        viewModel.runtime.hasLoadedRemoteDeviceNames = true

        let name = try await viewModel.saveProfileName("Renamed Current", currentDSN: "child-11")

        XCTAssertEqual(name, "Renamed Current")
        XCTAssertEqual(viewModel.remoteProfileName, "Renamed Current")
        XCTAssertEqual(service.renameCalls.count, 1)
        XCTAssertEqual(service.renameCalls.first?.0, 11)
        XCTAssertEqual(service.renameCalls.first?.1, "Renamed Current")
        XCTAssertEqual(cacheStore.savedProfileNames.last!, "Renamed Current")
        XCTAssertEqual(viewModel.connectedDevices.first?.name, "Renamed Current")
        XCTAssertFalse(viewModel.isSaving)
    }

    func testSaveProfileNameResolvesDeviceWhenCurrentDSNIsNotCached() async throws {
        let resolved = ConnectedDevice(id: 12, dsn: "child-12", name: "Resolved", avatarURL: nil)
        let updated = ConnectedDevice(id: 12, dsn: "child-12", name: "Resolved Rename", avatarURL: nil)
        let service = SettingsServiceSpy(
            resolveConnectedDeviceResult: .success(resolved),
            renameConnectedDeviceResult: .success(updated)
        )
        let cacheStore = SettingsCacheStoreSpy()
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.runtime.hasLoadedRemoteDeviceNames = true

        let name = try await viewModel.saveProfileName("Resolved Rename", currentDSN: "child-12")

        XCTAssertEqual(name, "Resolved Rename")
        XCTAssertEqual(service.resolvedDSNs, ["child-12"])
        XCTAssertEqual(service.renameCalls.first?.0, 12)
        XCTAssertEqual(viewModel.remoteProfileName, "Resolved Rename")
        XCTAssertEqual(viewModel.connectedDevices.first?.id, 12)
        XCTAssertEqual(cacheStore.savedProfileNames.last!, "Resolved Rename")
    }

    func testSaveProfileNameIgnoresSyntheticPlaceholderAndResolvesRemoteDeviceBeforeRename() async throws {
        let placeholder = ConnectedDevice(id: -121, dsn: "child-13", name: "Current Device", avatarURL: nil)
        let resolved = ConnectedDevice(id: 13, dsn: "child-13", name: "Resolved", avatarURL: nil)
        let updated = ConnectedDevice(id: 13, dsn: "child-13", name: "Resolved Rename", avatarURL: nil)
        let service = SettingsServiceSpy(
            resolveConnectedDeviceResult: .success(resolved),
            renameConnectedDeviceResult: .success(updated)
        )
        let cacheStore = SettingsCacheStoreSpy(cachedDevices: [placeholder])
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)
        viewModel.setConnectedDevices([placeholder])
        viewModel.runtime.hasLoadedRemoteDeviceNames = true

        let name = try await viewModel.saveProfileName("Resolved Rename", currentDSN: "child-13")

        XCTAssertEqual(name, "Resolved Rename")
        XCTAssertEqual(service.resolvedDSNs, ["child-13"])
        XCTAssertEqual(service.renameCalls.first?.0, 13)
        XCTAssertEqual(viewModel.connectedDevices.first?.id, 13)
        XCTAssertEqual(cacheStore.savedProfileNames.last!, "Resolved Rename")
    }

    func testSaveProfileNameFallsBackToMemberProfileUpdateWhenNoCurrentDevice() async throws {
        let service = SettingsServiceSpy(updateProfileNameResult: .success("Parent Account"))
        let cacheStore = SettingsCacheStoreSpy()
        let viewModel = SettingsViewModel(service: service, cacheStore: cacheStore)

        let name = try await viewModel.saveProfileName("Parent Account", currentDSN: nil)

        XCTAssertEqual(name, "Parent Account")
        XCTAssertEqual(service.updateProfileNames, ["Parent Account"])
        XCTAssertEqual(viewModel.remoteProfileName, "Parent Account")
        XCTAssertEqual(cacheStore.savedProfileNames.last!, "Parent Account")
    }

    func testSaveProfileNameWhileAlreadySavingReturnsCurrentRemoteName() async throws {
        let service = SettingsServiceSpy()
        let viewModel = SettingsViewModel(service: service, cacheStore: SettingsCacheStoreSpy())
        viewModel.setRemoteProfileName("Existing Name")
        viewModel.setSaving(true)

        let name = try await viewModel.saveProfileName("Ignored", currentDSN: nil)

        XCTAssertEqual(name, "Existing Name")
        XCTAssertTrue(service.updateProfileNames.isEmpty)
        XCTAssertTrue(service.renameCalls.isEmpty)
    }
}

final class SettingsServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestHTTPURLProtocol.reset()
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    func testFetchProfileNameRequiresAuthorization() async {
        let service = makeSettingsServiceForTests(accessToken: nil)

        do {
            _ = try await service.fetchProfileName()
            XCTFail("Expected fetchProfileName to fail without authorization")
        } catch let NetworkError.server(statusCode, body) {
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(body, "Not authenticated")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchProfileNameBuildsAuthorizedGetRequestAndDecodesResolvedName() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/members/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")

            let payload = #"{"data":{"full_name":" Parent Account "}}"#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = makeSettingsServiceForTests(accessToken: "Bearer access")
        let name = try await service.fetchProfileName()

        XCTAssertEqual(name, "Parent Account")
        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.count, 1)
    }

    func testUpdateProfileNameBuildsJSONPutRequestAndFallsBackToInputName() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/members/me")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["name"] as? String, "Updated Parent")

            let payload = #"{}"#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = makeSettingsServiceForTests(accessToken: "Bearer access")
        let name = try await service.updateProfileName("Updated Parent")

        XCTAssertEqual(name, "Updated Parent")
    }

    func testFetchConnectedDevicesMapsRecordsFromMemberDevicesService() async throws {
        let memberDevices = MemberDevicesServiceStub(
            fetchDevicesResult: .success([
                MemberDeviceRecord(id: 2, dsn: "child-2", name: "Kid Two", avatarURL: nil),
                MemberDeviceRecord(id: 3, dsn: nil, name: "Kid Three", avatarURL: URL(string: "https://example.com/3.jpg"))
            ])
        )
        let service = makeSettingsServiceForTests(accessToken: "Bearer access", memberDevicesService: memberDevices)

        let devices = try await service.fetchConnectedDevices(limit: 10)

        XCTAssertEqual(memberDevices.fetchLimits, [10])
        XCTAssertEqual(devices.map(\.id), [2, 3])
        XCTAssertEqual(devices.last?.avatarURL?.absoluteString, "https://example.com/3.jpg")
    }

    func testResolveConnectedDeviceUsesMemberDevicesService() async throws {
        let memberDevices = MemberDevicesServiceStub(
            resolveDeviceResult: .success(
                MemberDeviceRecord(id: 5, dsn: "child-5", name: "Resolved Five", avatarURL: nil)
            )
        )
        let service = makeSettingsServiceForTests(accessToken: "Bearer access", memberDevicesService: memberDevices)

        let device = try await service.resolveConnectedDevice(dsn: "child-5")

        XCTAssertEqual(memberDevices.resolvedArguments.first?.0, "child-5")
        XCTAssertEqual(memberDevices.resolvedArguments.first?.1, 100)
        XCTAssertEqual(device.name, "Resolved Five")
    }

    func testRenameConnectedDeviceBuildsPutRequestAndUsesInputNameFallback() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/devices/42")
            let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["name"] as? String, "Kid Rename")

            let payload = #"{"id":42,"dsn":"child-42"}"#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = makeSettingsServiceForTests(accessToken: "Bearer access")
        let device = try await service.renameConnectedDevice(deviceID: 42, name: "Kid Rename")

        XCTAssertEqual(device.id, 42)
        XCTAssertEqual(device.dsn, "child-42")
        XCTAssertEqual(device.name, "Kid Rename")
    }

    func testUploadConnectedDeviceAvatarBuildsMultipartBodyAndDecodesResponse() async throws {
        let imageData = Data([0xAA, 0xBB, 0xCC])
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/devices/77/upload-avatar")
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
            let bodyString = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(bodyString.contains("filename=\"avatar.jpg\""))
            XCTAssertTrue(body.starts(with: "--".data(using: .utf8)!))
            XCTAssertTrue(body.range(of: imageData) != nil)

            let payload = #"{"id":77,"dsn":"child-77","name":"Avatar Kid","avatar_url":"https://example.com/avatar-77.jpg"}"#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = makeSettingsServiceForTests(accessToken: "Bearer access")
        let device = try await service.uploadConnectedDeviceAvatar(deviceID: 77, imageData: imageData)

        XCTAssertEqual(device.id, 77)
        XCTAssertEqual(device.name, "Avatar Kid")
        XCTAssertEqual(device.avatarURL?.absoluteString, "https://example.com/avatar-77.jpg")
    }

    func testUploadConnectedDeviceAvatarByDSNParsesNestedRelativeAvatarURL() async throws {
        let imageData = Data([0x10, 0x11, 0x12])
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/devices/child-77/upload-avatar")
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            let body = try XCTUnwrap(TestHTTPURLProtocol.bodyData(for: request))
            XCTAssertTrue(body.range(of: imageData) != nil)

            let payload = #"{"device":{"avatar_url":"/uploads/devices/avatar 77.jpg"}}"#.data(using: .utf8)!
            return (makeHTTPResponse(for: request.url!, statusCode: 200), payload)
        }

        let service = makeSettingsServiceForTests(accessToken: "Bearer access")
        let avatarURL = try await service.uploadConnectedDeviceAvatar(dsn: "child-77", imageData: imageData)

        XCTAssertEqual(
            avatarURL?.absoluteString,
            "https://backend.smart-oila.uz/uploads/devices/avatar%2077.jpg"
        )
    }

    func testDeleteConnectedDeviceBuildsDeleteRequest() async throws {
        TestHTTPURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/devices/88")
            return (makeHTTPResponse(for: request.url!, statusCode: 204), Data())
        }

        let service = makeSettingsServiceForTests(accessToken: "Bearer access")
        try await service.deleteConnectedDevice(deviceID: 88)

        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.count, 1)
    }
}

final class PushInboxStoreMutationTests: XCTestCase {
    func testAppendDeduplicatesRecentItemsAndPromotesReadState() async {
        let suiteName = "PushInboxStoreAppendDedupTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set("child-1", forKey: "DSN")
        await MainActor.run { RuntimeDiagnosticsCenter.shared.resetPush() }

        let store = PushInboxStore(userDefaults: userDefaults)
        let receivedAt = Date(timeIntervalSince1970: 100)

        await store.append(
            title: " Hello ",
            body: " World ",
            event: " message_new ",
            dsn: " Child-1 ",
            isRead: false,
            receivedAt: receivedAt
        )
        await store.append(
            title: "Hello",
            body: "World",
            event: "message_new",
            dsn: "child-1",
            isRead: true,
            receivedAt: receivedAt.addingTimeInterval(2)
        )

        let items = await store.loadItems(dsn: "child-1")
        waitForMainQueue()
        let diagnostics = await MainActor.run { RuntimeDiagnosticsCenter.shared.push }

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Hello")
        XCTAssertEqual(items.first?.body, "World")
        XCTAssertEqual(items.first?.event, "message_new")
        XCTAssertTrue(items.first?.isRead == true)
        XCTAssertEqual(diagnostics.dsn, "child-1")
        XCTAssertEqual(diagnostics.inboxTotalCount, 1)
        XCTAssertEqual(diagnostics.sessionUnreadCount, 0)
        XCTAssertEqual(diagnostics.badgeCount, 0)
    }

    func testAppendTrimsStoredItemsToMaximumCount() async {
        let suiteName = "PushInboxStoreAppendLimitTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = PushInboxStore(userDefaults: userDefaults)

        for index in 0 ... 205 {
            await store.append(
                title: "Title \(index)",
                body: "Body \(index)",
                event: "message_new",
                dsn: "child-\(index % 2)",
                isRead: false,
                receivedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        let items = await store.loadItems(dsn: nil)

        XCTAssertEqual(items.count, 200)
        XCTAssertEqual(items.first?.title, "Title 205")
        XCTAssertEqual(items.last?.title, "Title 6")
    }

    func testAppendDeduplicatesMatchingHistoricalItemEvenWhenItIsNotLatest() async {
        let suiteName = "PushInboxStoreNonLatestDedupTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = PushInboxStore(userDefaults: userDefaults)

        await store.append(
            title: "Started",
            body: "Recording rec-1",
            event: "media_stream_started",
            dsn: "child-1",
            isRead: false,
            receivedAt: Date(timeIntervalSince1970: 100)
        )
        await store.append(
            title: "Failed",
            body: "Disconnected",
            event: "media_stream_failed",
            dsn: "child-1",
            isRead: false,
            receivedAt: Date(timeIntervalSince1970: 200)
        )
        await store.append(
            title: "Completed",
            body: "Done",
            event: "media_recording_completed",
            dsn: "child-1",
            isRead: false,
            receivedAt: Date(timeIntervalSince1970: 300)
        )

        await store.append(
            title: "Started",
            body: "Recording rec-1",
            event: "media_stream_started",
            dsn: "child-1",
            isRead: false,
            receivedAt: Date(timeIntervalSince1970: 100)
        )

        let items = await store.loadItems(dsn: "child-1")
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.event), [
            "media_recording_completed",
            "media_stream_failed",
            "media_stream_started"
        ])
    }

    func testMarkAllReadMarksMatchingAndGlobalItemsOnly() async throws {
        let suiteName = "PushInboxStoreMarkAllReadTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = PushInboxStore(userDefaults: userDefaults)

        await store.append(title: "Global", body: "Body", event: "message_new", dsn: nil, isRead: false)
        await store.append(title: "Match", body: "Body", event: "message_new", dsn: "child-1", isRead: false)
        await store.append(title: "Other", body: "Body", event: "message_new", dsn: "child-2", isRead: false)

        await store.markAllRead(dsn: " CHILD-1 ")

        let items = await store.loadItems(dsn: nil)
        let global = try XCTUnwrap(items.first(where: { $0.title == "Global" }))
        let matching = try XCTUnwrap(items.first(where: { $0.title == "Match" }))
        let other = try XCTUnwrap(items.first(where: { $0.title == "Other" }))

        XCTAssertTrue(global.isRead)
        XCTAssertTrue(matching.isRead)
        XCTAssertFalse(other.isRead)
    }

    func testMarkReadIgnoresMismatchedDSNAndAllowsGlobalItem() async throws {
        let suiteName = "PushInboxStoreMarkReadTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = PushInboxStore(userDefaults: userDefaults)

        await store.append(title: "Global", body: "Body", event: "message_new", dsn: nil, isRead: false)
        await store.append(title: "Other", body: "Body", event: "message_new", dsn: "child-2", isRead: false)

        var items = await store.loadItems(dsn: nil)
        let globalID = try XCTUnwrap(items.first(where: { $0.title == "Global" })?.id)
        let otherID = try XCTUnwrap(items.first(where: { $0.title == "Other" })?.id)

        await store.markRead(itemID: "   ", dsn: "child-1")
        await store.markRead(itemID: otherID, dsn: "child-1")
        await store.markRead(itemID: globalID, dsn: "child-1")

        items = await store.loadItems(dsn: nil)

        XCTAssertTrue(items.first(where: { $0.id == globalID })?.isRead == true)
        XCTAssertTrue(items.first(where: { $0.id == otherID })?.isRead == false)
    }

    func testClearRemovesMatchingAndGlobalItemsAndClearNilRemovesEverything() async {
        let suiteName = "PushInboxStoreClearTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = PushInboxStore(userDefaults: userDefaults)

        await store.append(title: "Global", body: "Body", event: "message_new", dsn: nil, isRead: false)
        await store.append(title: "Match", body: "Body", event: "message_new", dsn: "child-1", isRead: false)
        await store.append(title: "Other", body: "Body", event: "message_new", dsn: "child-2", isRead: false)

        await store.clear(dsn: " CHILD-1 ")
        var items = await store.loadItems(dsn: nil)

        XCTAssertEqual(items.map(\.title), ["Other"])

        await store.clear(dsn: nil)
        items = await store.loadItems(dsn: nil)

        XCTAssertTrue(items.isEmpty)
    }
}

private final class SettingsServiceSpy: SettingsServicing {
    var fetchConnectedDevicesResults: [Result<[ConnectedDevice], Error>]
    var fetchProfileNameResult: Result<String, Error>
    var resolveConnectedDeviceResult: Result<ConnectedDevice, Error>
    var updateProfileNameResult: Result<String, Error>
    var renameConnectedDeviceResult: Result<ConnectedDevice, Error>
    var uploadConnectedDeviceAvatarResult: Result<ConnectedDevice, Error>
    var uploadConnectedDeviceAvatarByDSNResult: Result<URL?, Error>
    var deleteConnectedDeviceResult: Result<Void, Error>
    private(set) var fetchConnectedDevicesCalls = 0
    private(set) var fetchProfileNameCalls = 0
    private(set) var resolvedDSNs: [String] = []
    private(set) var updateProfileNames: [String] = []
    private(set) var renameCalls: [(Int, String)] = []
    private(set) var uploadCalls: [(Int, Int)] = []
    private(set) var uploadDSNCalls: [(String, Int)] = []
    private(set) var deletedDeviceIDs: [Int] = []

    init(
        fetchConnectedDevicesResults: [Result<[ConnectedDevice], Error>] = [],
        fetchProfileNameResult: Result<String, Error> = .success("Parent"),
        resolveConnectedDeviceResult: Result<ConnectedDevice, Error> = .success(
            ConnectedDevice(id: 99, dsn: "child-99", name: "Resolved", avatarURL: nil)
        ),
        updateProfileNameResult: Result<String, Error> = .success("Parent"),
        renameConnectedDeviceResult: Result<ConnectedDevice, Error> = .success(
            ConnectedDevice(id: 99, dsn: "child-99", name: "Renamed", avatarURL: nil)
        ),
        uploadConnectedDeviceAvatarResult: Result<ConnectedDevice, Error> = .success(
            ConnectedDevice(
                id: 99,
                dsn: "child-99",
                name: "Avatar",
                avatarURL: URL(string: "https://example.com/avatar.jpg")
            )
        ),
        uploadConnectedDeviceAvatarByDSNResult: Result<URL?, Error> = .success(
            URL(string: "https://example.com/avatar.jpg")
        ),
        deleteConnectedDeviceResult: Result<Void, Error> = .success(())
    ) {
        self.fetchConnectedDevicesResults = fetchConnectedDevicesResults
        self.fetchProfileNameResult = fetchProfileNameResult
        self.resolveConnectedDeviceResult = resolveConnectedDeviceResult
        self.updateProfileNameResult = updateProfileNameResult
        self.renameConnectedDeviceResult = renameConnectedDeviceResult
        self.uploadConnectedDeviceAvatarResult = uploadConnectedDeviceAvatarResult
        self.uploadConnectedDeviceAvatarByDSNResult = uploadConnectedDeviceAvatarByDSNResult
        self.deleteConnectedDeviceResult = deleteConnectedDeviceResult
    }

    func fetchProfileName() async throws -> String {
        fetchProfileNameCalls += 1
        return try fetchProfileNameResult.get()
    }

    func fetchConnectedDevices(limit: Int) async throws -> [ConnectedDevice] {
        fetchConnectedDevicesCalls += 1
        if fetchConnectedDevicesResults.isEmpty {
            return []
        }
        return try fetchConnectedDevicesResults.removeFirst().get()
    }

    func resolveConnectedDevice(dsn: String) async throws -> ConnectedDevice {
        resolvedDSNs.append(dsn)
        return try resolveConnectedDeviceResult.get()
    }

    func updateProfileName(_ name: String) async throws -> String {
        updateProfileNames.append(name)
        return try updateProfileNameResult.get()
    }

    func renameConnectedDevice(deviceID: Int, name: String) async throws -> ConnectedDevice {
        renameCalls.append((deviceID, name))
        return try renameConnectedDeviceResult.get()
    }

    func uploadConnectedDeviceAvatar(deviceID: Int, imageData: Data) async throws -> ConnectedDevice {
        uploadCalls.append((deviceID, imageData.count))
        return try uploadConnectedDeviceAvatarResult.get()
    }

    func uploadConnectedDeviceAvatar(dsn: String, imageData: Data) async throws -> URL? {
        uploadDSNCalls.append((dsn, imageData.count))
        return try uploadConnectedDeviceAvatarByDSNResult.get()
    }

    func deleteConnectedDevice(deviceID: Int) async throws {
        deletedDeviceIDs.append(deviceID)
        try deleteConnectedDeviceResult.get()
    }
}

private final class MemberDevicesServiceStub: MemberDevicesServicing {
    var fetchDevicesResult: Result<[MemberDeviceRecord], Error>
    var resolveDeviceResult: Result<MemberDeviceRecord, Error>
    private(set) var fetchLimits: [Int] = []
    private(set) var resolvedArguments: [(String, Int)] = []

    init(
        fetchDevicesResult: Result<[MemberDeviceRecord], Error> = .success([]),
        resolveDeviceResult: Result<MemberDeviceRecord, Error> = .failure(NetworkError.unexpectedBody)
    ) {
        self.fetchDevicesResult = fetchDevicesResult
        self.resolveDeviceResult = resolveDeviceResult
    }

    func fetchDevices(limit: Int) async throws -> [MemberDeviceRecord] {
        fetchLimits.append(limit)
        return try fetchDevicesResult.get()
    }

    func resolveDevice(byDSN dsn: String, limit: Int) async throws -> MemberDeviceRecord {
        resolvedArguments.append((dsn, limit))
        return try resolveDeviceResult.get()
    }
}

private final class MemberDevicesSequenceStub: MemberDevicesServicing {
    var fetchDevicesResults: [Result<[MemberDeviceRecord], Error>]
    private(set) var fetchLimits: [Int] = []

    init(fetchDevicesResults: [Result<[MemberDeviceRecord], Error>] = [.success([])]) {
        self.fetchDevicesResults = fetchDevicesResults
    }

    func fetchDevices(limit: Int) async throws -> [MemberDeviceRecord] {
        fetchLimits.append(limit)

        if fetchDevicesResults.count > 1 {
            return try fetchDevicesResults.removeFirst().get()
        }

        return try fetchDevicesResults.first?.get() ?? []
    }

    func resolveDevice(byDSN dsn: String, limit: Int) async throws -> MemberDeviceRecord {
        throw NetworkError.unexpectedBody
    }
}

private actor DeviceApplicationRemovalAttemptReportingServiceSpy: DeviceApplicationRemovalAttemptServicing {
    private var calls: [DeviceApplicationRemovalAttemptEntry] = []

    func reportRemovalAttempt(dsn: String, packageName: String, appName: String) async throws {
        calls.append(
            DeviceApplicationRemovalAttemptEntry(
                dsn: dsn,
                packageName: packageName,
                appName: appName
            )
        )
    }

    func recordedCalls() -> [DeviceApplicationRemovalAttemptEntry] {
        calls
    }
}

private struct PushTokenSyncCall: Equatable {
    let token: String
    let dsn: String
}

private actor PushTokenServiceSpy: PushTokenServicing {
    private var calls: [PushTokenSyncCall] = []
    private var syncResults: [Result<Void, Error>]
    private var fetchResults: [Result<String?, Error>]
    private var fetchDSNs: [String] = []

    init(
        syncResults: [Result<Void, Error>] = [.success(())],
        fetchResults: [Result<String?, Error>] = [.success(nil)]
    ) {
        self.syncResults = syncResults
        self.fetchResults = fetchResults
    }

    func syncToken(_ token: String, dsn: String) async throws {
        calls.append(PushTokenSyncCall(token: token, dsn: dsn))

        if syncResults.count > 1 {
            return try syncResults.removeFirst().get()
        }

        return try syncResults.first?.get() ?? ()
    }

    func fetchRemoteToken(dsn: String) async throws -> String? {
        fetchDSNs.append(dsn)

        if fetchResults.count > 1 {
            return try fetchResults.removeFirst().get()
        }

        return try fetchResults.first?.get() ?? nil
    }

    func recordedCalls() -> [PushTokenSyncCall] {
        calls
    }

    func recordedFetchDSNs() -> [String] {
        fetchDSNs
    }
}

final class TestHTTPURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { stateQueue.sync { _requestHandler } }
        set { stateQueue.sync { _requestHandler = newValue } }
    }

    static var recordedRequests: [URLRequest] {
        stateQueue.sync { _recordedRequests }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.stateQueue.sync { () -> ((URLRequest) throws -> (HTTPURLResponse, Data))? in
            Self._recordedRequests.append(request)
            return Self._requestHandler
        }

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: NetworkError.invalidResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        stateQueue.sync {
            _requestHandler = nil
            _recordedRequests = []
        }
    }

    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 {
                return nil
            }

            if count == 0 {
                break
            }

            data.append(buffer, count: count)
        }

        return data
    }

    private static let stateQueue = DispatchQueue(label: "TestHTTPURLProtocol.state")
    private static var _requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    private static var _recordedRequests: [URLRequest] = []
}

struct SecureTokenStoreStub: SecureTokenStoring {
    var access: String?
    var refresh: String? = nil

    func accessToken() -> String? { access }
    func refreshToken() -> String? { refresh }
    func setAccessToken(_ token: String?) {}
    func setRefreshToken(_ token: String?) {}
    func migrateFromUserDefaults(_ userDefaults: UserDefaults) {}
    func clear() {}
}

func makeHTTPResponse(for url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
}

func makeTestAPIClient(accessToken: String?) -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TestHTTPURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return APIClient(
        session: session,
        secureTokens: SecureTokenStoreStub(access: accessToken)
    )
}

func makeSettingsServiceForTests(
    accessToken: String?,
    memberDevicesService: MemberDevicesServicing = MemberDevicesServiceStub()
) -> SettingsService {
    let client = makeTestAPIClient(accessToken: accessToken)
    return SettingsService(
        client: client,
        memberDevicesService: memberDevicesService,
        secureTokens: SecureTokenStoreStub(access: accessToken)
    )
}

func makeMainDashboardRemoteDataSourceForTests(
    accessToken: String? = "Bearer access",
    memberDevicesService: MemberDevicesServicing = MemberDevicesSequenceStub(),
    calendar: Calendar? = nil,
    locationLogParser: MainDashboardLocationLogParser = MainDashboardLocationLogParser()
) -> MainDashboardRemoteDataSource {
    let client = makeTestAPIClient(accessToken: accessToken)
    var resolvedCalendar = calendar ?? Calendar(identifier: .gregorian)
    resolvedCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return MainDashboardRemoteDataSource(
        client: client,
        memberDevicesService: memberDevicesService,
        calendar: resolvedCalendar,
        locationLogParser: locationLogParser
    )
}

func makeMainDashboardWeekRange(startingAt mondayString: String) -> MainDashboardWeekRange {
    let start = apiDateFormatter.date(from: mondayString)!
    let orderedDates = (0 ..< 7).map { offset in
        Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: start)!
    }
    let orderedDateStrings = orderedDates.map(apiDateFormatter.string(from:))
    return MainDashboardWeekRange(
        start: start,
        end: orderedDates.last!,
        orderedDateStrings: orderedDateStrings,
        dateIndex: Dictionary(uniqueKeysWithValues: orderedDateStrings.enumerated().map { ($1, $0) })
    )
}

func pendingNotificationRequestsForTests() async -> [UNNotificationRequest] {
    await withCheckedContinuation { continuation in
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            continuation.resume(
                returning: requests.filter { $0.identifier.hasPrefix("media.integrity.") }
            )
        }
    }
}

func clearPendingNotificationRequestsForTests() async {
    let center = UNUserNotificationCenter.current()
    center.removeAllDeliveredNotifications()
    center.removeAllPendingNotificationRequests()
    _ = await pendingNotificationRequestsForTests()
}

func waitForPendingNotificationRequestsForTests(
    count expectedCount: Int,
    timeout: TimeInterval = 1
) async -> [UNNotificationRequest] {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        let requests = await pendingNotificationRequestsForTests()
        if requests.count >= expectedCount {
            return requests
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    return await pendingNotificationRequestsForTests()
}

func waitForPushInboxItemsForTests(
    count expectedCount: Int,
    dsn: String?,
    timeout: TimeInterval = 1
) async -> [PushInboxItem] {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        let items = await PushInboxStore.shared.loadItems(dsn: dsn)
        if items.count >= expectedCount {
            return items
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    return await PushInboxStore.shared.loadItems(dsn: dsn)
}

func pushInboxItemsMatchingDSNForTests(_ dsn: String?) async -> [PushInboxItem] {
    let normalizedDSN = dsn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let items = await PushInboxStore.shared.loadItems(dsn: nil)

    return items.filter { item in
        let itemDSN = item.dsn?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return itemDSN == normalizedDSN
    }
}

func waitForPushInboxItemsMatchingDSNForTests(
    count expectedCount: Int,
    dsn: String?,
    timeout: TimeInterval = 1
) async -> [PushInboxItem] {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        let items = await pushInboxItemsMatchingDSNForTests(dsn)
        if items.count >= expectedCount {
            return items
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    return await pushInboxItemsMatchingDSNForTests(dsn)
}

func waitForPushDeepLinkForTests(
    dsn: String?,
    timeout: TimeInterval = 1
) async -> PushDeepLinkDestination? {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if let destination = await PushDeepLinkStore.shared.consume(matching: dsn) {
            return destination
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    return await PushDeepLinkStore.shared.consume(matching: dsn)
}

func waitForPushDiagnosticsForTests(
    timeout: TimeInterval = 1,
    predicate: @escaping @Sendable (PushDiagnosticsSnapshot) -> Bool
) async -> PushDiagnosticsSnapshot {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        let snapshot = await MainActor.run { RuntimeDiagnosticsCenter.shared.push }
        if predicate(snapshot) {
            return snapshot
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    return await MainActor.run { RuntimeDiagnosticsCenter.shared.push }
}

private func waitForPushTokenSyncCallCount(
    _ service: PushTokenServiceSpy,
    count: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

    while DispatchTime.now().uptimeNanoseconds < deadline {
        let currentCount = await service.recordedCalls().count
        if currentCount >= count {
            return
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

func seedMediaActivityEventsForTests(_ events: [MediaActivityEvent]) {
    let data = try! JSONEncoder().encode(events)
    UserDefaults.standard.set(data, forKey: "SMARTOILA_MEDIA_ACTIVITY_EVENTS")
}

func deviceControlEventSharedDefaultsForTests() -> UserDefaults {
    UserDefaults(suiteName: "group.3twn5nw4bl.uz.smartoila.kids")!
}

func clearDeviceControlPendingEventsForTests() {
    deviceControlEventSharedDefaultsForTests().removeObject(forKey: "DEVICE_CONTROL_PENDING_EVENTS")
}

func seedDeviceControlPendingEventsForTests(_ events: [DeviceControlEvent]) {
    let defaults = deviceControlEventSharedDefaultsForTests()
    if events.isEmpty {
        defaults.removeObject(forKey: "DEVICE_CONTROL_PENDING_EVENTS")
        return
    }

    let data = try! JSONEncoder().encode(events)
    defaults.set(data, forKey: "DEVICE_CONTROL_PENDING_EVENTS")
}

final class LossyDecodingHelpersTests: XCTestCase {
    func testStringHelpersNormalizeCommonForms() {
        XCTAssertEqual("+998 (90) 123-45-67".digitsOnly, "998901234567")
        XCTAssertEqual("+child-dsn".withoutLeadingPlus, "child-dsn")
        XCTAssertEqual("child-dsn".withoutLeadingPlus, "child-dsn")
        XCTAssertEqual("  Smart Oila  ".trimmedNonEmpty, "Smart Oila")
        XCTAssertNil(" \n\t ".trimmedNonEmpty)
    }

    func testLossyStringValueDecodesPrimitiveScalarsAndRejectsUnsupportedValues() throws {
        XCTAssertEqual(try decodeLossyStringValue(#""hello""#).value, "hello")
        XCTAssertEqual(try decodeLossyStringValue("42").value, "42")
        XCTAssertEqual(try decodeLossyStringValue("42.0").value, "42")
        XCTAssertEqual(try decodeLossyStringValue("42.5").value, "42.5")
        XCTAssertEqual(try decodeLossyStringValue("true").value, "true")
        XCTAssertEqual(try decodeLossyStringValue("false").value, "false")

        XCTAssertThrowsError(try decodeLossyStringValue(#"["unsupported"]"#))
    }

    func testKeyedLossyDecodingCoversStringNumericBooleanAndArrayConversions() throws {
        let direct = try decodeLossyPayload(
            #"{"string":"value","int":5,"double":1.5,"bool":true,"array":["one","two"]}"#
        )
        XCTAssertEqual(direct.stringValue, "value")
        XCTAssertEqual(direct.intValue, 5)
        XCTAssertEqual(direct.doubleValue, 1.5)
        XCTAssertEqual(direct.boolValue, true)
        XCTAssertEqual(direct.arrayValue, ["one", "two"])

        let converted = try decodeLossyPayload(
            #"{"string":12,"int":"42.9","double":"3.25","bool":"YES","array":[1,"two",false]}"#
        )
        XCTAssertEqual(converted.stringValue, "12")
        XCTAssertEqual(converted.intValue, 42)
        XCTAssertEqual(converted.doubleValue, 3.25)
        XCTAssertEqual(converted.boolValue, true)
        XCTAssertEqual(converted.arrayValue, ["1", "two", "false"])

        let fractionalString = try decodeLossyPayload(#"{"string":4.25,"int":true,"double":2,"bool":0,"array":"solo"}"#)
        XCTAssertEqual(fractionalString.stringValue, "4.25")
        XCTAssertEqual(fractionalString.intValue, 1)
        XCTAssertEqual(fractionalString.doubleValue, 2)
        XCTAssertEqual(fractionalString.boolValue, false)
        XCTAssertEqual(fractionalString.arrayValue, ["solo"])

        let integerLikeString = try decodeLossyPayload(#"{"string":4.0,"bool":"off"}"#)
        XCTAssertEqual(integerLikeString.stringValue, "4")
        XCTAssertEqual(integerLikeString.boolValue, false)
    }

    func testKeyedLossyDecodingReturnsNilForInvalidOrEmptyValues() throws {
        let invalid = try decodeLossyPayload(
            #"{"string":{},"int":"abc","double":"bad","bool":"maybe","array":""}"#
        )

        XCTAssertNil(invalid.stringValue)
        XCTAssertNil(invalid.intValue)
        XCTAssertNil(invalid.doubleValue)
        XCTAssertNil(invalid.boolValue)
        XCTAssertNil(invalid.arrayValue)
    }
}

@MainActor
final class GeoBackgroundServiceTests: XCTestCase {
    func testBackgroundTrackingRequiresAlwaysLocationAuthorization() {
        let service = makeGeoBackgroundServiceForTests()
        defer { cleanupGeoService(service) }

        XCTAssertTrue(service.shouldStartLocationUpdates(for: .authorizedAlways))
        XCTAssertTrue(service.shouldStartLocationUpdates(for: .authorizedWhenInUse))
        XCTAssertFalse(service.shouldStartLocationUpdates(for: .notDetermined))
        XCTAssertFalse(service.shouldStartLocationUpdates(for: .denied))
    }

    func testLocationAuthorizationFailureReasonExplainsBackgroundTrackingRequirement() {
        let service = makeGeoBackgroundServiceForTests()
        defer { cleanupGeoService(service) }

        XCTAssertNil(service.locationAuthorizationFailureReason(for: .authorizedAlways))
        XCTAssertEqual(
            service.locationAuthorizationFailureReason(for: .authorizedWhenInUse),
            "Location Always authorization is required for background tracking; foreground tracking works only while the app is open"
        )
        XCTAssertEqual(
            service.locationAuthorizationFailureReason(for: .notDetermined),
            "Location permission has not been granted yet"
        )
        XCTAssertEqual(
            service.locationAuthorizationFailureReason(for: .denied),
            "Location access is unavailable for background tracking"
        )
    }

    func testDiagnosticsLocationPulseRequiresRunningService() {
        let service = makeGeoBackgroundServiceForTests()
        defer { cleanupGeoService(service) }

        service.state.currentDSN = "child-dsn"

        XCTAssertFalse(service.triggerDiagnosticsLocationPulse())
        waitForMainQueue()

        XCTAssertEqual(service.debugStatus, GeoConnectionStatus.stopped.rawValue)
        XCTAssertEqual(service.debugLastError, "geo service is not running")
    }

    func testPendingDebugSnapshotUpdateDoesNotRetainService() {
        weak var weakService: GeoBackgroundService?

        var service: GeoBackgroundService? = makeGeoBackgroundServiceForTests()
        weakService = service

        service?.updateDebugSnapshot(
            status: GeoConnectionStatus.failed.rawValue,
            endpoint: "wss://geo.example.test"
        )
        service = nil

        XCTAssertNil(weakService)
        waitForMainQueue()
    }

    func testReconnectHelpersRespectRunningStateAndClampBackoff() {
        let service = makeGeoBackgroundServiceForTests()
        defer { cleanupGeoService(service) }

        XCTAssertFalse(service.canReconnect)
        XCTAssertEqual(service.reconnectDelay(forAttempt: 1), 5)
        XCTAssertEqual(service.reconnectDelay(forAttempt: 2), 10)
        XCTAssertEqual(service.reconnectDelay(forAttempt: 4), 12)

        service.state.isRunning = true
        XCTAssertTrue(service.canReconnect)

        service.state.isDisconnectRequested = true
        XCTAssertFalse(service.canReconnect)
    }

    func testReceiveEventsResetReconnectCountAndScheduleReconnectOnCurrentBaseFailure() {
        let service = makeGeoBackgroundServiceForTests()
        defer { cleanupGeoService(service) }

        service.state.isRunning = true
        service.state.currentBaseIndex = 0
        service.state.reconnectAttemptCount = 3

        service.handleWebSocketReceiveEvent(.didReceiveFrame, baseIndex: 0)
        waitForMainQueue()

        XCTAssertEqual(service.state.reconnectAttemptCount, 0)
        XCTAssertEqual(service.debugReconnectCount, 0)

        service.handleWebSocketReceiveEvent(.didFail, baseIndex: 0)
        waitForMainQueue()

        XCTAssertEqual(service.debugStatus, GeoConnectionStatus.reconnecting.rawValue)
        XCTAssertEqual(service.state.reconnectAttemptCount, 1)
        XCTAssertEqual(service.debugReconnectCount, 1)
    }

    func testReceiveEventsMarkFailureWithoutReconnectForStaleBase() {
        let service = makeGeoBackgroundServiceForTests()
        defer { cleanupGeoService(service) }

        service.state.isRunning = true
        service.state.currentBaseIndex = 0

        service.handleWebSocketReceiveEvent(.didFail, baseIndex: 1)
        waitForMainQueue()

        XCTAssertEqual(service.debugStatus, GeoConnectionStatus.failed.rawValue)
        XCTAssertEqual(service.state.reconnectAttemptCount, 0)
        XCTAssertEqual(service.debugReconnectCount, 0)
        XCTAssertNil(service.reconnectWorkItem)
    }

    func testShouldReconnectBasedOnDebugStatusMatchesRetryableStates() {
        let service = makeGeoBackgroundServiceForTests()
        defer { cleanupGeoService(service) }

        service.setDebugSnapshot(GeoDebugSnapshot(status: GeoConnectionStatus.failed.rawValue))
        XCTAssertTrue(service.shouldReconnectBasedOnDebugStatus)

        service.setDebugSnapshot(GeoDebugSnapshot(status: GeoConnectionStatus.queued.rawValue))
        XCTAssertTrue(service.shouldReconnectBasedOnDebugStatus)

        service.setDebugSnapshot(GeoDebugSnapshot(status: GeoConnectionStatus.reconnecting.rawValue))
        XCTAssertTrue(service.shouldReconnectBasedOnDebugStatus)

        service.setDebugSnapshot(GeoDebugSnapshot(status: GeoConnectionStatus.connected.rawValue))
        XCTAssertFalse(service.shouldReconnectBasedOnDebugStatus)

        service.setDebugSnapshot(GeoDebugSnapshot(status: "mystery"))
        XCTAssertFalse(service.shouldReconnectBasedOnDebugStatus)
    }

    func testStopPersistsQueuedPayloadsAndBlankStartFallsBackToStoppedState() {
        let dsn = "geo-stop-\(UUID().uuidString)"
        let service = makeGeoBackgroundServiceForTests()
        defer {
            clearGeoPendingPayloads(for: dsn)
            cleanupGeoService(service)
        }

        service.state.currentDSN = dsn
        service.state.isRunning = true
        service.pendingPayloadQueue.enqueue(text: #"{"event":"test"}"#, summary: "test", dsn: dsn)
        service.reconnectWorkItem = DispatchWorkItem {}

        service.stop()
        waitForMainQueue()

        XCTAssertFalse(service.state.isRunning)
        XCTAssertTrue(service.state.isDisconnectRequested)
        XCTAssertNil(service.state.currentDSN)
        XCTAssertNil(service.reconnectWorkItem)
        XCTAssertEqual(service.debugStatus, GeoConnectionStatus.stopped.rawValue)

        let restoredQueue = GeoPendingPayloadQueue(userDefaults: .standard)
        XCTAssertEqual(restoredQueue.restore(for: dsn), 1)
        _ = restoredQueue.dequeueAll(dsn: dsn)

        service.start(dsn: "   ")
        waitForMainQueue()
        XCTAssertEqual(service.debugStatus, GeoConnectionStatus.stopped.rawValue)
    }
}

@MainActor
final class GeoBackgroundServicePayloadTests: XCTestCase {
    func testSendLocationQueuesSerializedPayloadWhenSocketIsDisconnected() throws {
        let dsn = "geo-location-\(UUID().uuidString)"
        let service = makeGeoBackgroundServiceForTests()
        defer {
            clearGeoPendingPayloads(for: dsn)
            cleanupGeoService(service)
        }

        service.state.currentDSN = dsn
        service.sendLocation(CLLocation(latitude: 41.3111, longitude: 69.2797))

        XCTAssertEqual(service.pendingPayloadQueue.count, 1)

        let payload = try XCTUnwrap(service.pendingPayloadQueue.dequeueAll(dsn: dsn).first)
        let json = try makeJSONObject(from: payload.text)
        let data = try XCTUnwrap(json["data"] as? [String: Any])

        XCTAssertEqual(json["event"] as? String, "location")
        XCTAssertEqual(try XCTUnwrap(data["device_id"] as? String), dsn)
        XCTAssertEqual(try XCTUnwrap(data["latitude"] as? Double), 41.3111, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(data["longitude"] as? Double), 69.2797, accuracy: 0.0001)
        XCTAssertTrue(payload.summary.hasPrefix("location "))
    }

    func testSendSystemInfoSkipsUnchangedSnapshotUnlessForced() throws {
        let dsn = "geo-system-\(UUID().uuidString)"
        let service = makeGeoBackgroundServiceForTests()
        defer {
            clearGeoPendingPayloads(for: dsn)
            cleanupGeoService(service)
        }

        service.state.currentDSN = dsn
        service.state.lastSystemInfoSnapshot = waitForStableSystemInfoSnapshot(service)

        service.sendSystemInfo(force: false)
        XCTAssertEqual(service.pendingPayloadQueue.count, 0)

        service.sendSystemInfo(force: true)
        XCTAssertEqual(service.pendingPayloadQueue.count, 1)

        let payload = try XCTUnwrap(service.pendingPayloadQueue.dequeueAll(dsn: dsn).first)
        let json = try makeJSONObject(from: payload.text)

        XCTAssertEqual(json["event"] as? String, "system_info")
        XCTAssertTrue(payload.summary.hasPrefix("system_info "))
    }

    func testMatchingDeviceControlTelemetryQueuesIntoActiveService() throws {
        let dsn = "geo-device-control-\(UUID().uuidString)"
        let service = makeGeoBackgroundServiceForTests()
        defer {
            clearGeoPendingPayloads(for: dsn)
            cleanupGeoService(service)
        }

        service.state.currentDSN = dsn
        service.handleDeviceControlTelemetryNotification(
            makeDeviceControlTelemetryNotification(
                dsn: dsn.uppercased(),
                event: DeviceControlRecoveryEvent.appLimitRestored.rawValue,
                packageName: "com.example.app",
                appName: "Example App",
                createdAt: Date(timeIntervalSince1970: 1_714_000_000)
            )
        )

        XCTAssertEqual(service.pendingPayloadQueue.count, 1)

        let payload = try XCTUnwrap(service.pendingPayloadQueue.dequeueAll(dsn: dsn).first)
        let json = try makeJSONObject(from: payload.text)
        let data = try XCTUnwrap(json["data"] as? [String: Any])

        XCTAssertEqual(json["event"] as? String, "device_control")
        XCTAssertEqual(data["telemetry_event"] as? String, DeviceControlRecoveryEvent.appLimitRestored.rawValue)
        XCTAssertEqual(data["package_name"] as? String, "com.example.app")
        XCTAssertEqual(data["app_name"] as? String, "Example App")
        XCTAssertEqual(data["device_id"] as? String, dsn.uppercased())
    }

    func testForeignDeviceControlTelemetryQueuesIntoScopedStore() throws {
        let currentDSN = "geo-device-active-\(UUID().uuidString)"
        let foreignDSN = "geo-device-foreign-\(UUID().uuidString)"
        let service = makeGeoBackgroundServiceForTests()
        defer {
            clearGeoPendingPayloads(for: currentDSN)
            clearGeoPendingPayloads(for: foreignDSN)
            cleanupGeoService(service)
        }

        service.state.currentDSN = currentDSN
        service.handleDeviceControlTelemetryNotification(
            makeDeviceControlTelemetryNotification(
                dsn: foreignDSN,
                event: DeviceControlRecoveryEvent.lockRestored.rawValue,
                packageName: nil,
                appName: nil,
                createdAt: Date(timeIntervalSince1970: 1_714_000_100)
            )
        )

        XCTAssertEqual(service.pendingPayloadQueue.count, 0)

        let scopedQueue = GeoPendingPayloadQueue(userDefaults: .standard)
        XCTAssertEqual(scopedQueue.restore(for: foreignDSN), 1)
        let payload = try XCTUnwrap(scopedQueue.dequeueAll(dsn: foreignDSN).first)
        let json = try makeJSONObject(from: payload.text)
        let data = try XCTUnwrap(json["data"] as? [String: Any])

        XCTAssertEqual(json["event"] as? String, "device_control")
        XCTAssertEqual(data["telemetry_event"] as? String, DeviceControlRecoveryEvent.lockRestored.rawValue)
        XCTAssertEqual(data["device_id"] as? String, foreignDSN)
    }

    func testMatchingMediaTelemetryQueuesIntoActiveService() throws {
        let dsn = "geo-media-\(UUID().uuidString)"
        let service = makeGeoBackgroundServiceForTests()
        defer {
            clearGeoPendingPayloads(for: dsn)
            cleanupGeoService(service)
        }

        service.state.currentDSN = dsn
        service.handleMediaTelemetryNotification(
            makeMediaTelemetryNotification(
                dsn: dsn.uppercased(),
                event: MediaTelemetryEvent.recordingUploadQueued.rawValue,
                mediaType: MediaTelemetryType.camera.rawValue,
                recordingID: "rec-1",
                reason: "queued",
                createdAt: Date(timeIntervalSince1970: 1_714_000_200)
            )
        )

        XCTAssertEqual(service.pendingPayloadQueue.count, 1)

        let payload = try XCTUnwrap(service.pendingPayloadQueue.dequeueAll(dsn: dsn).first)
        let json = try makeJSONObject(from: payload.text)
        let data = try XCTUnwrap(json["data"] as? [String: Any])

        XCTAssertEqual(json["event"] as? String, "media_control")
        XCTAssertEqual(data["telemetry_event"] as? String, MediaTelemetryEvent.recordingUploadQueued.rawValue)
        XCTAssertEqual(data["media_type"] as? String, MediaTelemetryType.camera.rawValue)
        XCTAssertEqual(data["recording_id"] as? String, "rec-1")
        XCTAssertEqual(data["reason"] as? String, "queued")
        XCTAssertEqual(data["device_id"] as? String, dsn.uppercased())
    }

    func testForeignMediaTelemetryQueuesIntoScopedStore() throws {
        let currentDSN = "geo-media-active-\(UUID().uuidString)"
        let foreignDSN = "geo-media-foreign-\(UUID().uuidString)"
        let service = makeGeoBackgroundServiceForTests()
        defer {
            clearGeoPendingPayloads(for: currentDSN)
            clearGeoPendingPayloads(for: foreignDSN)
            cleanupGeoService(service)
        }

        service.state.currentDSN = currentDSN
        service.handleMediaTelemetryNotification(
            makeMediaTelemetryNotification(
                dsn: foreignDSN,
                event: MediaTelemetryEvent.streamFailed.rawValue,
                mediaType: MediaTelemetryType.audioStream.rawValue,
                recordingID: nil,
                reason: "offline",
                createdAt: Date(timeIntervalSince1970: 1_714_000_300)
            )
        )

        XCTAssertEqual(service.pendingPayloadQueue.count, 0)

        let scopedQueue = GeoPendingPayloadQueue(userDefaults: .standard)
        XCTAssertEqual(scopedQueue.restore(for: foreignDSN), 1)
        let payload = try XCTUnwrap(scopedQueue.dequeueAll(dsn: foreignDSN).first)
        let json = try makeJSONObject(from: payload.text)
        let data = try XCTUnwrap(json["data"] as? [String: Any])

        XCTAssertEqual(json["event"] as? String, "media_control")
        XCTAssertEqual(data["telemetry_event"] as? String, MediaTelemetryEvent.streamFailed.rawValue)
        XCTAssertEqual(data["media_type"] as? String, MediaTelemetryType.audioStream.rawValue)
        XCTAssertEqual(data["reason"] as? String, "offline")
        XCTAssertEqual(data["device_id"] as? String, foreignDSN)
    }

    func testFlushPendingPayloadsDequeuesAndRequeuesWhileDisconnected() {
        let dsn = "geo-flush-\(UUID().uuidString)"
        let service = makeGeoBackgroundServiceForTests()
        defer {
            clearGeoPendingPayloads(for: dsn)
            cleanupGeoService(service)
        }

        service.state.currentDSN = dsn
        service.pendingPayloadQueue.enqueue(text: #"{"payload":1}"#, summary: "first", dsn: dsn)
        service.pendingPayloadQueue.enqueue(text: #"{"payload":2}"#, summary: "second", dsn: dsn)

        XCTAssertEqual(service.pendingPayloadQueue.count, 2)

        service.flushPendingPayloads()

        XCTAssertEqual(service.pendingPayloadQueue.count, 2)
        XCTAssertEqual(
            service.pendingPayloadQueue.dequeueAll(dsn: dsn).map(\.summary),
            ["first", "second"]
        )
    }

    private func makeDeviceControlTelemetryNotification(
        dsn: String,
        event: String,
        packageName: String?,
        appName: String?,
        createdAt: Date
    ) -> Notification {
        var userInfo: [AnyHashable: Any] = [
            DeviceControlTelemetryUserInfoKey.dsn: dsn,
            DeviceControlTelemetryUserInfoKey.event: event,
            DeviceControlTelemetryUserInfoKey.createdAt: createdAt.timeIntervalSince1970
        ]

        if let packageName {
            userInfo[DeviceControlTelemetryUserInfoKey.packageName] = packageName
        }

        if let appName {
            userInfo[DeviceControlTelemetryUserInfoKey.appName] = appName
        }

        return Notification(name: .deviceControlTelemetryRecorded, object: nil, userInfo: userInfo)
    }

    private func makeMediaTelemetryNotification(
        dsn: String,
        event: String,
        mediaType: String,
        recordingID: String?,
        reason: String?,
        createdAt: Date
    ) -> Notification {
        var userInfo: [AnyHashable: Any] = [
            MediaTelemetryUserInfoKey.dsn: dsn,
            MediaTelemetryUserInfoKey.event: event,
            MediaTelemetryUserInfoKey.mediaType: mediaType,
            MediaTelemetryUserInfoKey.createdAt: createdAt.timeIntervalSince1970
        ]

        if let recordingID {
            userInfo[MediaTelemetryUserInfoKey.recordingID] = recordingID
        }

        if let reason {
            userInfo[MediaTelemetryUserInfoKey.reason] = reason
        }

        return Notification(name: .mediaTelemetryRecorded, object: nil, userInfo: userInfo)
    }

    private func waitForStableSystemInfoSnapshot(
        _ service: GeoBackgroundService,
        timeout: TimeInterval = 1
    ) -> GeoSystemInfoSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = GeoSystemInfoSnapshotFactory.make(currentPath: service.pathMonitor.currentPath)

        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let current = GeoSystemInfoSnapshotFactory.make(currentPath: service.pathMonitor.currentPath)
            if current == previous {
                return current
            }
            previous = current
        }

        return previous
    }
}

@MainActor
final class GeoBackgroundServiceConnectionTests: XCTestCase {
    func testConnectUsingCurrentBaseSchedulesReconnectWhenBasesAreExhausted() {
        let service = makeGeoBackgroundServiceForTests()
        defer { cleanupGeoService(service) }

        service.state.isRunning = true
        service.state.currentDSN = "geo-connect-\(UUID().uuidString)"
        service.state.currentBaseIndex = AppConfig.websocketBaseCandidates.count

        service.connectUsingCurrentBase()

        XCTAssertEqual(service.state.reconnectAttemptCount, 1)
        XCTAssertNotNil(service.reconnectWorkItem)

        waitForMainQueue()
        XCTAssertEqual(service.debugReconnectCount, 1)
    }

    func testConnectNextBaseOrRetryResetsIndexAndSchedulesReconnectAfterLastBase() {
        let service = makeGeoBackgroundServiceForTests()
        defer { cleanupGeoService(service) }

        XCTAssertFalse(AppConfig.websocketBaseCandidates.isEmpty)

        service.state.isRunning = true
        service.state.currentDSN = "geo-retry-\(UUID().uuidString)"
        service.state.currentBaseIndex = AppConfig.websocketBaseCandidates.count - 1

        service.connectNextBaseOrRetry()

        XCTAssertEqual(service.state.currentBaseIndex, 0)
        XCTAssertEqual(service.state.reconnectAttemptCount, 1)
        XCTAssertNotNil(service.reconnectWorkItem)

        waitForMainQueue()
        XCTAssertEqual(service.debugReconnectCount, 1)
    }

    func testScheduleReconnectDoesNothingWhenReconnectIsDisabled() {
        let service = makeGeoBackgroundServiceForTests()
        defer { cleanupGeoService(service) }

        service.scheduleReconnect()
        waitForMainQueue()

        XCTAssertEqual(service.state.reconnectAttemptCount, 0)
        XCTAssertNil(service.reconnectWorkItem)

        service.state.isRunning = true
        service.state.isDisconnectRequested = true
        service.scheduleReconnect()
        waitForMainQueue()

        XCTAssertEqual(service.state.reconnectAttemptCount, 0)
        XCTAssertNil(service.reconnectWorkItem)
    }

    func testDidUpdateLocationsQueuesFirstLocationIgnoresShortMoveAndSendsLargeMove() throws {
        let dsn = "geo-locations-\(UUID().uuidString)"
        let service = makeGeoBackgroundServiceForTests()
        defer {
            clearGeoPendingPayloads(for: dsn)
            cleanupGeoService(service)
        }

        let first = CLLocation(latitude: 41.3111, longitude: 69.2797)
        let shortMove = CLLocation(latitude: 41.31111, longitude: 69.27971)
        let largeMove = CLLocation(latitude: 41.3125, longitude: 69.2815)

        service.state.isRunning = true
        service.state.currentDSN = dsn

        service.locationManager(service.locationManager, didUpdateLocations: [first])
        XCTAssertEqual(service.pendingPayloadQueue.count, 1)
        XCTAssertEqual(try XCTUnwrap(service.state.lastKnownLocation).coordinate.latitude, first.coordinate.latitude, accuracy: 0.000001)

        service.locationManager(service.locationManager, didUpdateLocations: [shortMove])
        XCTAssertEqual(service.pendingPayloadQueue.count, 1)
        XCTAssertEqual(try XCTUnwrap(service.state.lastKnownLocation).coordinate.latitude, first.coordinate.latitude, accuracy: 0.000001)

        service.locationManager(service.locationManager, didUpdateLocations: [largeMove])
        XCTAssertEqual(service.pendingPayloadQueue.count, 2)
        XCTAssertEqual(try XCTUnwrap(service.state.lastKnownLocation).coordinate.latitude, largeMove.coordinate.latitude, accuracy: 0.000001)
    }

    func testDidUpdateLocationsAndSendLastKnownLocationNoopWhenInactive() {
        let dsn = "geo-inactive-\(UUID().uuidString)"
        let service = makeGeoBackgroundServiceForTests()
        defer {
            clearGeoPendingPayloads(for: dsn)
            cleanupGeoService(service)
        }

        let location = CLLocation(latitude: 41.31, longitude: 69.28)
        service.state.currentDSN = dsn

        service.locationManager(service.locationManager, didUpdateLocations: [location])
        XCTAssertNil(service.state.lastKnownLocation)
        XCTAssertEqual(service.pendingPayloadQueue.count, 0)

        service.sendLastKnownLocation()
        XCTAssertEqual(service.pendingPayloadQueue.count, 0)

        service.state.lastKnownLocation = location
        service.sendLastKnownLocation()
        XCTAssertEqual(service.pendingPayloadQueue.count, 1)
    }
}

final class DeviceLockScheduleSupportTests: XCTestCase {
    func testScheduleActivityIdentifierNormalizesAndParsesDSN() {
        let rawValue = DeviceLockScheduleActivityIdentifier.rawValue(
            dsn: " Child DSN./42 ",
            suffix: "primary"
        )

        XCTAssertEqual(rawValue, "smartoila.global-lock.schedule._child_dsn__42_.primary")
        XCTAssertTrue(DeviceLockScheduleActivityIdentifier.isScheduleActivity(rawValue: rawValue))
        XCTAssertEqual(DeviceLockScheduleActivityIdentifier.dsn(from: rawValue), "_child_dsn__42_")
        XCTAssertNil(DeviceLockScheduleActivityIdentifier.dsn(from: "smartoila.global-lock.schedule."))
        XCTAssertNil(DeviceLockScheduleActivityIdentifier.dsn(from: "smartoila.global-lock.schedule"))
    }

    func testAppLimitIdentifiersNormalizeAndRejectInvalidPayloads() {
        let activity = DeviceAppLimitActivityIdentifier.rawValue(dsn: " Child/1 ")
        XCTAssertEqual(activity, "smartoila.app-limit|_child_1_")
        XCTAssertEqual(DeviceAppLimitActivityIdentifier.dsn(from: activity), "_child_1_")
        XCTAssertNil(DeviceAppLimitActivityIdentifier.dsn(from: "smartoila.app-limit"))

        let event = DeviceAppLimitEventIdentifier.rawValue(packageName: "  COM.Example.App  ")
        XCTAssertEqual(event, "smartoila.app-limit.event|com.example.app")
        XCTAssertEqual(DeviceAppLimitEventIdentifier.packageName(from: event), "com.example.app")
        XCTAssertNil(DeviceAppLimitEventIdentifier.packageName(from: "smartoila.app-limit.event"))
    }

    func testManagedSettingsStoreNamesRemainStable() {
        XCTAssertEqual(DeviceLockManagedSettingsStoreName.runtime, "SmartOilaKidsLock")
        XCTAssertEqual(DeviceLockManagedSettingsStoreName.schedule, "SmartOilaKidsScheduleLock")
        XCTAssertEqual(DeviceLockManagedSettingsStoreName.limit, "SmartOilaKidsLimitLock")
    }
}

final class AppRuntimeDefaultsTests: XCTestCase {
    func testDebugRuntimeDefaultsReflectUnsetEnvironment() {
        XCTAssertFalse(AppRuntime.screenTimeFeaturesEnabled)
        XCTAssertNil(AppRuntime.debugRoute)
        XCTAssertFalse(AppRuntime.hasDebugRoute)
        XCTAssertNil(AppRuntime.debugAuthStage)
        XCTAssertNil(AppRuntime.debugPermissionsStage)
        XCTAssertNil(AppRuntime.debugDSN)
        XCTAssertNil(AppRuntime.debugProfileName)
        XCTAssertFalse(AppRuntime.showGeoDebugOverlay)
    }

    func testDebugEnumsExposeSupportedRawValues() {
        XCTAssertEqual(DebugRoute.main.rawValue, "main")
        XCTAssertEqual(DebugRoute.permissions.rawValue, "permissions")
        XCTAssertEqual(DebugAuthStage.scan.rawValue, "scan")
        XCTAssertEqual(DebugPermissionsStage.checklist.rawValue, "checklist")
    }
}

final class RootLocalServiceRuntimeTests: XCTestCase {
    func testRegularLinkedChildFlowRunsChildServices() {
        XCTAssertTrue(
            RootLocalServiceRuntime.shouldRunChildServices(
                debugRoute: nil,
                hasLinkedChildDevice: true
            )
        )
    }

    func testRegularUnlinkedChildFlowDoesNotRunChildServices() {
        XCTAssertFalse(
            RootLocalServiceRuntime.shouldRunChildServices(
                debugRoute: nil,
                hasLinkedChildDevice: false
            )
        )
    }

    func testOnlyMainDebugOverrideRunsChildServices() {
        XCTAssertTrue(
            RootLocalServiceRuntime.shouldRunChildServices(
                debugRoute: .main,
                hasLinkedChildDevice: false
            )
        )
        XCTAssertFalse(
            RootLocalServiceRuntime.shouldRunChildServices(
                debugRoute: .settings,
                hasLinkedChildDevice: true
            )
        )
    }
}

final class AppConfigDiagnosticsTests: XCTestCase {
    func testWebSocketTokenPathIsRedactedInDiagnostics() {
        XCTAssertEqual(AppConfig.websocketTokenPathDiagnosticsValue, "/ws/{redacted}")
        XCTAssertNotEqual(AppConfig.websocketTokenPathDiagnosticsValue, AppConfig.websocketTokenPath)
    }
}

@MainActor
final class AppDependenciesTests: XCTestCase {
    func testFactoryMethodsBuildViewModelsWithExpectedDefaultState() {
        let dependencies = AppDependencies(
            apiClient: APIClient(
                session: URLSession(configuration: URLSessionConfiguration.ephemeral),
                secureTokens: SecureTokenStoreStub(access: nil)
            )
        )

        let authViewModel = dependencies.makeAuthViewModel()
        XCTAssertFalse(authViewModel.isLoading)
        XCTAssertNil(authViewModel.errorText)

        let mainViewModel = dependencies.makeMainViewModel()
        XCTAssertEqual(mainViewModel.weeklyUsageHours, Array(repeating: 0, count: 7))
        XCTAssertEqual(mainViewModel.usagePhase, .idle)
        XCTAssertNil(mainViewModel.currentDeviceName)
        XCTAssertNil(mainViewModel.deviceStatus)
        XCTAssertNil(mainViewModel.pendingTasksCount)
        XCTAssertNil(mainViewModel.unreadChatCount)
        XCTAssertEqual(mainViewModel.unreadNotificationCount, 0)

        let chatViewModel = dependencies.makeChatViewModel(dsn: "child-chat")
        XCTAssertEqual(chatViewModel.currentDSN, "child-chat")
        XCTAssertEqual(chatViewModel.phase, .loading)
        XCTAssertEqual(chatViewModel.queuedMessagesCount, 0)
        XCTAssertNil(chatViewModel.parentDisplayName)

        let taskViewModel = dependencies.makeTaskViewModel(dsn: "child-task")
        XCTAssertEqual(taskViewModel.currentDSN, "child-task")
        XCTAssertEqual(taskViewModel.phase, .loading)
        XCTAssertEqual(taskViewModel.queuedActionsCount, 0)
        XCTAssertNil(taskViewModel.messageText)

        let settingsViewModel = dependencies.makeSettingsViewModel()
        XCTAssertTrue(settingsViewModel.connectedDevices.isEmpty)
        XCTAssertNil(settingsViewModel.remoteProfileName)
        XCTAssertFalse(settingsViewModel.isSaving)
        XCTAssertFalse(settingsViewModel.isUpdatingDevice)
        XCTAssertFalse(settingsViewModel.isUploadingAvatar)
    }
}

private struct LossyPayload: Decodable {
    let stringValue: String?
    let intValue: Int?
    let doubleValue: Double?
    let boolValue: Bool?
    let arrayValue: [String]?

    private enum CodingKeys: String, CodingKey {
        case stringValue = "string"
        case intValue = "int"
        case doubleValue = "double"
        case boolValue = "bool"
        case arrayValue = "array"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stringValue = container.decodeLossyStringIfPresent(forKey: .stringValue)
        intValue = container.decodeLossyIntIfPresent(forKey: .intValue)
        doubleValue = container.decodeLossyDoubleIfPresent(forKey: .doubleValue)
        boolValue = container.decodeLossyBoolIfPresent(forKey: .boolValue)
        arrayValue = container.decodeLossyStringArrayIfPresent(forKey: .arrayValue)
    }
}

private final class SettingsCacheStoreSpy: SettingsCacheStoring {
    private var cachedProfileName: String?
    private var cachedDevices: [ConnectedDevice]
    private(set) var savedProfileNames: [String?] = []
    private(set) var savedConnectedDevicesSnapshots: [[ConnectedDevice]] = []

    init(cachedProfileName: String? = nil, cachedDevices: [ConnectedDevice] = []) {
        self.cachedProfileName = cachedProfileName
        self.cachedDevices = cachedDevices
    }

    func loadProfileName() -> String? {
        cachedProfileName
    }

    func saveProfileName(_ value: String?) {
        cachedProfileName = value
        savedProfileNames.append(value)
    }

    func loadConnectedDevices() -> [ConnectedDevice] {
        cachedDevices
    }

    func saveConnectedDevices(_ devices: [ConnectedDevice]) {
        cachedDevices = devices
        savedConnectedDevicesSnapshots.append(devices)
    }
}

private actor SOSServiceSpy: SOSServicing {
    private var calls: [String] = []
    private var results: [Result<Void, Error>]
    private let suspendFirstCall: Bool
    private var shouldSuspend = true
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        results: [Result<Void, Error>] = [.success(())],
        suspendFirstCall: Bool = false
    ) {
        self.results = results
        self.suspendFirstCall = suspendFirstCall
    }

    func sendSOS(deviceDSN: String) async throws {
        calls.append(deviceDSN)

        if suspendFirstCall, shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        if results.count > 1 {
            return try results.removeFirst().get()
        }

        return try results.first?.get() ?? ()
    }

    func recordedCalls() -> [String] {
        calls
    }

    func resumeSuspendedCallIfNeeded() {
        continuation?.resume()
        continuation = nil
    }
}

private func waitForSOSCallCount(
    _ service: SOSServiceSpy,
    count: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

    while DispatchTime.now().uptimeNanoseconds < deadline {
        let currentCount = await service.recordedCalls().count
        if currentCount >= count {
            return
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

private struct NoopSOSService: SOSServicing {
    func sendSOS(deviceDSN: String) async throws {}
}

private final class MainDashboardServiceSpy: MainDashboardServicing {
    var weeklyUsageResult: Result<[Double], Error>
    var currentDeviceNameResult: Result<String, Error>
    var deviceStatusResult: Result<MainDeviceStatus, Error>
    private(set) var fetchWeeklyUsageCalls: [String] = []
    private(set) var fetchCurrentDeviceNameCalls = 0
    private(set) var fetchDeviceStatusCalls: [String] = []

    init(
        weeklyUsageResult: Result<[Double], Error> = .success(Array(repeating: 0, count: 7)),
        currentDeviceNameResult: Result<String, Error> = .success("Kid"),
        deviceStatusResult: Result<MainDeviceStatus, Error> = .success(
            MainDeviceStatus(
                deviceName: "Kid",
                battery: 80,
                connectionType: "wifi",
                soundMode: "normal",
                latitude: nil,
                longitude: nil
            )
        )
    ) {
        self.weeklyUsageResult = weeklyUsageResult
        self.currentDeviceNameResult = currentDeviceNameResult
        self.deviceStatusResult = deviceStatusResult
    }

    func fetchWeeklyUsageHours(dsn: String) async throws -> [Double] {
        fetchWeeklyUsageCalls.append(dsn)
        return try weeklyUsageResult.get()
    }

    func fetchCurrentDeviceName(dsn: String) async throws -> String {
        fetchCurrentDeviceNameCalls += 1
        return try currentDeviceNameResult.get()
    }

    func fetchDeviceStatus(dsn: String) async throws -> MainDeviceStatus {
        fetchDeviceStatusCalls.append(dsn)
        return try deviceStatusResult.get()
    }
}

private final class MainTaskSummaryServiceSpy: TaskSummaryServicing {
    var result: Result<Int, Error>

    init(result: Result<Int, Error> = .success(0)) {
        self.result = result
    }

    func fetchPendingTasksCount(dsn: String) async throws -> Int {
        try result.get()
    }
}

private final class MainChatServiceSpy: ChatServicing {
    var historyResult: Result<ChatMessagesModel, Error>

    init(historyResult: Result<ChatMessagesModel, Error> = .success(makeChatMessagesModel(groupedMessages: [:]))) {
        self.historyResult = historyResult
    }

    func fetchChatHistory(dsn: String, limit: Int, page: Int) async throws -> ChatMessagesModel {
        try historyResult.get()
    }

    func sendMessage(sendFromID: String, text: String, attachments: [Data]) async throws -> WBSocketChat {
        fatalError("sendMessage is not used in MainViewModel tests")
    }
}

private final class MainChatReadStateStoreSpy: ChatReadStateStoring {
    var lastReadTimestamp: String?

    init(lastReadTimestamp: String? = nil) {
        self.lastReadTimestamp = lastReadTimestamp
    }

    func loadLastReadTimestamp(for dsn: String) -> String? {
        lastReadTimestamp
    }

    func saveLastReadTimestamp(_ timestamp: String?, for dsn: String) {
        lastReadTimestamp = timestamp
    }
}

private final class MainChatHistoryStoreSpy: ChatHistoryCaching {
    private var historyByDSN: [String: [String: [Datum]]]

    init(history: [String: [String: [Datum]]] = [:]) {
        historyByDSN = history
    }

    func loadHistory(for dsn: String) -> [String: [Datum]] {
        historyByDSN[dsn] ?? [:]
    }

    func saveHistory(_ groupedMessages: [String: [Datum]], for dsn: String) {
        historyByDSN[dsn] = groupedMessages
    }

    func clearHistory(for dsn: String) {
        historyByDSN.removeValue(forKey: dsn)
    }
}

private final class MainTaskCacheStoreSpy: TaskCacheStoring {
    var awardsByDSN: [String: [AwardsResponse]]

    init(awardsByDSN: [String: [AwardsResponse]] = [:]) {
        self.awardsByDSN = awardsByDSN
    }

    func load(for dsn: String) -> [AwardsResponse] {
        awardsByDSN[dsn] ?? []
    }

    func save(_ awards: [AwardsResponse], for dsn: String) {
        awardsByDSN[dsn] = awards
    }

    func clear(for dsn: String) {
        awardsByDSN.removeValue(forKey: dsn)
    }
}

private func makeChatMessagesModel(groupedMessages: [String: [Datum]]) -> ChatMessagesModel {
    let payload: [String: Any] = [
        "pagination": [
            "current": 1,
            "previous": NSNull(),
            "next": NSNull(),
            "per_page": 100,
            "total_page": 1,
            "total_count": groupedMessages.values.flatMap { $0 }.count
        ],
        "data": groupedMessages.mapValues { messages in
            messages.map { message in
                var payload: [String: Any] = [
                    "user_type": message.userType,
                    "attachments": message.attachments,
                    "time": message.time
                ]

                if let text = message.text {
                    payload["text"] = text
                }

                if let senderName = message.senderName {
                    payload["sender_name"] = senderName
                }

                return payload
            }
        }
    ]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    return try! JSONDecoder().decode(ChatMessagesModel.self, from: data)
}

private func stalePushDeepLinkPayloadData(
    destination: PushDeepLinkDestination,
    dsn: String?
) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "destination": destination.rawValue,
        "dsn": dsn as Any,
        "createdAt": Date(timeIntervalSinceNow: -(21 * 60)).timeIntervalSinceReferenceDate
    ])
}

private func makePermissionSnapshot(
    location: CLAuthorizationStatus = .authorizedAlways,
    notification: UNAuthorizationStatus = .authorized,
    microphone: AVAudioSession.RecordPermission = .granted,
    camera: AVAuthorizationStatus = .authorized,
    displayCapture: DisplayCaptureAvailabilityStatus = .ready,
    screenTime: ScreenTimePermissionStatus = .granted,
    backgroundRefresh: UIBackgroundRefreshStatus = .available,
    isLowPowerModeEnabled: Bool = false
) -> PermissionStatusSnapshot {
    PermissionStatusSnapshot(
        locationAuthorizationStatus: location,
        notificationAuthorizationStatus: notification,
        microphonePermission: microphone,
        cameraAuthorizationStatus: camera,
        displayCaptureAvailabilityStatus: displayCapture,
        screenTimePermissionStatus: screenTime,
        backgroundRefreshStatus: backgroundRefresh,
        isLowPowerModeEnabled: isLowPowerModeEnabled
    )
}

private func makeUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func makeUTCDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int = 0,
    minute: Int = 0,
    second: Int = 0
) -> Date {
    let components = DateComponents(
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second
    )
    return makeUTCCalendar().date(from: components)!
}

private func makeJSONObject(from text: String) throws -> [String: Any] {
    let data = try XCTUnwrap(text.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

final class ChatWebSocketServiceConcurrencyTests: XCTestCase {
    func testStaleFailureFromPreviousConnectionDoesNotReconnectCurrentDSN() {
        let factory = ChatWebSocketTaskFactoryMock()
        let scheduler = ChatReconnectSchedulerMock()
        let service = ChatWebSocketService(
            taskFactory: factory,
            reconnectScheduler: scheduler.schedule(after:item:)
        )

        service.connect(dsn: "child-a")
        let staleTask = factory.createdTasks[0]

        service.connect(dsn: "child-b")
        XCTAssertEqual(staleTask.cancelCallCount, 1)
        XCTAssertEqual(factory.createdTasks.count, 2)

        staleTask.complete(with: .failure(ChatWebSocketServiceTestError.sample))
        service.flushStateQueueForTests()

        XCTAssertEqual(factory.createdTasks.count, 2)
        XCTAssertTrue(scheduler.scheduledItems.isEmpty)
        XCTAssertTrue(factory.createdURLs[1].absoluteString.contains("/children/device/child-b/chat/"))
    }

    func testLateFailureAfterDisconnectDoesNotScheduleReconnect() {
        let factory = ChatWebSocketTaskFactoryMock()
        let scheduler = ChatReconnectSchedulerMock()
        let service = ChatWebSocketService(
            taskFactory: factory,
            reconnectScheduler: scheduler.schedule(after:item:)
        )

        service.connect(dsn: "child-disconnect")
        let task = factory.createdTasks[0]

        service.disconnect()
        XCTAssertEqual(task.cancelCallCount, 1)

        task.complete(with: .failure(ChatWebSocketServiceTestError.sample))
        service.flushStateQueueForTests()

        XCTAssertEqual(factory.createdTasks.count, 1)
        XCTAssertTrue(scheduler.scheduledItems.isEmpty)
    }

    func testCancelledReconnectWorkItemFromPreviousConnectionDoesNotStartAnotherSocket() throws {
        guard AppConfig.websocketBaseCandidates.count == 1 else {
            throw XCTSkip("Reconnect scheduling test assumes a single websocket base candidate.")
        }

        let factory = ChatWebSocketTaskFactoryMock()
        let scheduler = ChatReconnectSchedulerMock()
        let service = ChatWebSocketService(
            taskFactory: factory,
            reconnectScheduler: scheduler.schedule(after:item:)
        )

        service.connect(dsn: "child-a")
        let staleTask = factory.createdTasks[0]

        staleTask.complete(with: .failure(ChatWebSocketServiceTestError.sample))
        service.flushStateQueueForTests()

        let staleReconnect = try XCTUnwrap(scheduler.scheduledItems.first)

        service.connect(dsn: "child-b")
        XCTAssertEqual(factory.createdTasks.count, 2)

        staleReconnect.perform()
        service.flushStateQueueForTests()

        XCTAssertEqual(factory.createdTasks.count, 2)
        XCTAssertTrue(factory.createdURLs[1].absoluteString.contains("/children/device/child-b/chat/"))
    }
}

private enum ChatWebSocketServiceTestError: Error {
    case sample
}

private final class ChatWebSocketTaskFactoryMock: ChatWebSocketTaskCreating {
    private(set) var createdTasks: [ChatWebSocketTaskMock] = []
    private(set) var createdURLs: [URL] = []

    func makeTask(url: URL) -> ChatWebSocketTasking {
        let task = ChatWebSocketTaskMock()
        createdTasks.append(task)
        createdURLs.append(url)
        return task
    }
}

private final class ChatReconnectSchedulerMock {
    private(set) var scheduledItems: [DispatchWorkItem] = []

    func schedule(after _: TimeInterval, item: DispatchWorkItem) {
        scheduledItems.append(item)
    }
}

private final class ChatWebSocketTaskMock: ChatWebSocketTasking {
    private var completionHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?

    private(set) var resumeCallCount = 0
    private(set) var cancelCallCount = 0

    func resume() {
        resumeCallCount += 1
    }

    func cancel(with _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        cancelCallCount += 1
    }

    func receive(
        completionHandler: @Sendable @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        self.completionHandler = completionHandler
    }

    func complete(with result: Result<URLSessionWebSocketTask.Message, Error>) {
        completionHandler?(result)
    }
}

private func expectedGeoSummaryTime(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

private func expectedGeoDeviceDate(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

private func decodeLossyStringValue(_ json: String) throws -> LossyStringValue {
    try JSONDecoder().decode(LossyStringValue.self, from: Data(json.utf8))
}

private func decodeLossyPayload(_ json: String) throws -> LossyPayload {
    try JSONDecoder().decode(LossyPayload.self, from: Data(json.utf8))
}

private func makeGeoBackgroundServiceForTests() -> GeoBackgroundService {
    let service = GeoBackgroundService(
        configuration: GeoServiceConfiguration(
            minDistance: 10,
            periodicLocationInterval: 60,
            systemInfoInterval: 60,
            reconnectBaseDelay: 5,
            reconnectMaxDelay: 12
        )
    )
    service.pathMonitor.cancel()
    return service
}

private func cleanupGeoService(_ service: GeoBackgroundService) {
    service.reconnectWorkItem?.cancel()
    service.stop()
    service.pathMonitor.cancel()
}

private func clearGeoPendingPayloads(for dsn: String) {
    let queue = GeoPendingPayloadQueue(userDefaults: .standard)
    queue.restore(for: dsn)
    _ = queue.dequeueAll(dsn: dsn)
    UserDefaults.standard.removeObject(
        forKey: DSNScopedStorage.userDefaultsKey(
            prefix: "GEO_PENDING_PAYLOADS_",
            dsn: dsn,
            lowercased: true
        )
    )
}

private func waitForMainQueue(timeout: TimeInterval = 1) {
    let expectation = XCTestExpectation(description: "main queue drained")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed)
}

private func expectedLegacyClientDate(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
    return formatter.string(from: date)
}

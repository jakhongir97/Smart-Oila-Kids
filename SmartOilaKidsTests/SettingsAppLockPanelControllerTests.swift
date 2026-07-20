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
    }

    override func tearDown() {
        clearDeviceControlPendingEventsForTests()
        super.tearDown()
    }

    func testApplicationDidBecomeActiveSyncsDeviceControlInboxSources() async {
        await PushInboxStore.shared.clearAll()

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

        let appDelegate = SmartOilaKidsAppDelegate()
        appDelegate.applicationDidBecomeActive(UIApplication.shared)

        let items = await waitForPushInboxItemsMatchingDSNForTests(count: 1, dsn: "child-app-active")
        XCTAssertEqual(items.map(\.event), [DeviceControlEventKind.scheduleStarted.rawValue])
    }

    func testDidReceiveRemoteNotificationRoutesPushAndCompletesWithNewData() async {
        await PushInboxStore.shared.clearAll()

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

final class PermissionRequirementTests: XCTestCase {
    func testComputedKeysMatchCurrentPermissionCatalog() {
        XCTAssertEqual(PermissionRequirement.onboardingCases, [.location])
        // Microphone/camera are out of the visible catalog: audio recording was cut for v1 and
        // there is no camera feature, so their toggles would advertise permissions with no
        // consumer. The enum cases remain for the evaluator + diagnostics.
        XCTAssertEqual(
            PermissionRequirement.settingsCases,
            [.location, .notifications]
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

final class DeviceControlRecoveryNotifierTests: XCTestCase {
    func testRecordLockRestoredAppendsInboxAndPostsTelemetry() async {
        let suiteName = "DeviceControlRecoveryNotifierLockTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let dsn = "child-lock-\(UUID().uuidString)"
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        await PushInboxStore.shared.clearAll()

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

@MainActor
final class MiscUtilityTests: XCTestCase {
    func testLegacyClientDateFormattingAndAppHapticsFunctionsAreCallable() {
        // Build the date from LOCAL components so the expected string is deterministic regardless of
        // the device timezone (formattedLegacyClientDate formats in the current timezone). Asserting
        // a hardcoded literal — not re-deriving it with the same DateFormatter — makes this a real
        // regression test rather than a tautology.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(
            from: DateComponents(year: 2026, month: 3, day: 11, hour: 9, minute: 8, second: 7)
        )!
        XCTAssertEqual(date.formattedLegacyClientDate(), "11/03/2026 09:08:07")

        AppHaptics.tap()
        AppHaptics.success()
        AppHaptics.warning()
        AppHaptics.selection()
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
        XCTAssertNil(AppRuntime.debugSetupStep)
        XCTAssertNil(AppRuntime.debugDSN)
        XCTAssertNil(AppRuntime.debugProfileName)
        XCTAssertFalse(AppRuntime.showGeoDebugOverlay)
    }

    func testDebugEnumsExposeSupportedRawValues() {
        XCTAssertEqual(DebugRoute.bolajonSetup.rawValue, "setup")
        XCTAssertEqual(DebugRoute.bolajonPermissions.rawValue, "perm2")
        XCTAssertEqual(DebugRoute.bolajonHome.rawValue, "home2")
        XCTAssertEqual(DebugSetupStep.language.rawValue, "language")
        XCTAssertEqual(DebugSetupStep.connect.rawValue, "connect")
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

    func testAnyDebugOverrideDisablesChildServices() {
        XCTAssertFalse(
            RootLocalServiceRuntime.shouldRunChildServices(
                debugRoute: .bolajonHome,
                hasLinkedChildDevice: true
            )
        )
        XCTAssertFalse(
            RootLocalServiceRuntime.shouldRunChildServices(
                debugRoute: .bolajonSettings,
                hasLinkedChildDevice: true
            )
        )
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

private func decodeLossyStringValue(_ json: String) throws -> LossyStringValue {
    try JSONDecoder().decode(LossyStringValue.self, from: Data(json.utf8))
}

private func decodeLossyPayload(_ json: String) throws -> LossyPayload {
    try JSONDecoder().decode(LossyPayload.self, from: Data(json.utf8))
}

private func waitForMainQueue(timeout: TimeInterval = 1) {
    let expectation = XCTestExpectation(description: "main queue drained")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed)
}


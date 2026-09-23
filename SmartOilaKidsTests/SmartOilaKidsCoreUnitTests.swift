import AVFAudio
import AVFoundation
import CoreLocation
import DeviceActivity
import os
import UIKit
import UserNotifications
import XCTest
@testable import SmartOilaKids

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
        // The body here reads "Location update and lock state" — a human sentence. It used to
        // trigger a `dashboard_refresh` route, because that matcher ran over event + title + BODY.
        // The route is gone; nothing a parent can type may name a device action.
        XCTAssertFalse(diagnosticsBeforeConsume.lastRoute.contains("dashboard"))
        XCTAssertFalse(diagnosticsBeforeConsume.lastRoute.contains("status_report"))
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
        // A requirement is listed only while a shipping feature consumes it, so the catalog is a
        // function of the feature flags rather than a fixed list.
        XCTAssertEqual(
            PermissionRequirement.settingsCases(screenTimeEnabled: false, mediaEnabled: false),
            [.location, .notifications]
        )
        // Live audio/video on ⇒ microphone + camera become fixable from Settings. Without them a
        // child who declined the mic prompt has no route back and every listen request fails.
        XCTAssertEqual(
            PermissionRequirement.settingsCases(screenTimeEnabled: false, mediaEnabled: true),
            [.location, .notifications, .microphone, .camera]
        )
        XCTAssertEqual(
            PermissionRequirement.settingsCases(screenTimeEnabled: true, mediaEnabled: false),
            [.location, .usageStats, .notifications]
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
        // The coordinator persists its queue; keep it on this test's own suite so a pending entry
        // is never restored from (or left behind in) the host app's real defaults.
        let removalCoordinator = DeviceApplicationRemovalAttemptCoordinator(
            service: removalService,
            userDefaults: userDefaults
        )
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

        // Injected since build 26: a revocation now also reports to the parent, and the default
        // `.shared` coordinator would queue that report in the host app's real defaults.
        let removalService = DeviceApplicationRemovalAttemptReportingServiceSpy()
        let removalCoordinator = DeviceApplicationRemovalAttemptCoordinator(
            service: removalService,
            userDefaults: userDefaults
        )
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

        // The parent hears about it: ONE tamper report (the cooldown dedups the repeat), naming this
        // app. Before build 26 the revocation never left the phone.
        let report = DeviceControlIntegrityNotifier.screenTimeRevocationReport()
        let reportedAttempts = await removalService.recordedCalls()
        XCTAssertEqual(
            reportedAttempts,
            [DeviceApplicationRemovalAttemptEntry(dsn: "child-2", packageName: report.packageName, appName: report.appName)]
        )
    }

    func testScreenTimeRevocationReportNamesThisApp() {
        // The report is about THIS app — its bundle id is the `packageName` the contract documents as
        // "usually this app itself", and the name is what the parent's notification will print.
        let report = DeviceControlIntegrityNotifier.screenTimeRevocationReport()
        XCTAssertEqual(report.packageName, Bundle.main.bundleIdentifier)
        XCTAssertEqual(report.packageName, "uz.smartoila.kids")
        XCTAssertEqual(report.appName, "Bolajon360")
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
    // These assertions pin the ENGLISH diagnostics strings, so the language must be fixed rather
    // than inherited from the device default (which is Uzbek — see AppLanguage.defaultForDevice).
    override func setUp() {
        super.setUp()
        L10n.setLanguage(AppLanguage.en.rawValue)
    }

    override func tearDown() {
        L10n.setLanguage(AppLanguage.defaultForDevice.rawValue)
        super.tearDown()
    }

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
        // `message_new` is a person-authored push, so its body is the parent's actual message and is
        // deliberately NOT retained: nothing in the app renders it, and up to 200 of them would
        // otherwise sit in the app container on a child's device. Dedupe still works — this item was
        // recognised as a duplicate of the first append, which is what `count == 1` above proves.
        XCTAssertEqual(items.first?.body, "", "a parent's message must not be kept at rest")
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
        // Screen Time ships ON from build 23: the Info.plist key is `<true/>` and the app now
        // carries `com.apple.developer.family-controls`. The assertion is kept (rather than
        // deleted) because it is the tripwire that says which way the shipped flag points — if it
        // ever fails, someone turned the whole app-blocking lane off without meaning to.
        XCTAssertTrue(AppRuntime.screenTimeFeaturesEnabled)
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
    screenTime: ScreenTimePermissionStatus = .granted,
    backgroundRefresh: UIBackgroundRefreshStatus = .available,
    isLowPowerModeEnabled: Bool = false
) -> PermissionStatusSnapshot {
    PermissionStatusSnapshot(
        locationAuthorizationStatus: location,
        notificationAuthorizationStatus: notification,
        microphonePermission: microphone,
        cameraAuthorizationStatus: camera,
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


// MARK: - Live-audio push command routing
//
// This is the only push route that opens hardware, so it is pinned down directly. The two
// properties that matter are asymmetric on purpose: missing a START is a bug you find in testing,
// while missing a STOP (or inventing a start) leaves a child's microphone open.

// MARK: - The live-session wake as an ALERT push
//
// `stream.start` must move from a silent `content-available` push to an ALERT push carrying
// `content-available: 1` at priority 10, because iOS throttles the silent kind for minutes and
// never delivers it to a force-quit app (measured on hardware 2026-08-12; see
// `output/doc/stream_wake_push_type_2026-08-13.md`). That is the SENDER's change, and these tests
// pin the two client-side properties it depends on, so the flip needs no iOS release and cannot
// regress the badge.

final class PushAlertWakeWithoutInboxRowTests: XCTestCase {
    /// The wake still routes when the push carries our disclosure title and body — the media route
    /// reads the machine-authored event alone, so alert text is invisible to it.
    func testAlertShapedStreamStartStillRoutesTheWake() async {
        await PushInboxStore.shared.clearAll()
        await MainActor.run { RuntimeDiagnosticsCenter.shared.resetPush() }

        var started = 0
        let token = NotificationCenter.default.addObserver(
            forName: .pushShouldStartAudioStream,
            object: nil,
            queue: nil
        ) { _ in started += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        PushCommandRouter.handle(
            userInfo: [
                "event": "stream.start",
                "dsn": "child-alert-wake",
                "mode": "audio",
                "maxDurationSeconds": "120",
                "aps": [
                    "alert": ["title": "Ota-ona tekshiryapti", "body": "Ota-onangiz siz bilan bog'lanmoqda"],
                    "content-available": 1
                ]
            ],
            deliveryContext: .backgroundFetch
        )

        let diagnostics = await waitForPushDiagnosticsForTests { $0.lastRoute.contains("audio_start") }
        XCTAssertTrue(diagnostics.lastRoute.contains("audio_start"))
        XCTAssertEqual(started, 1)
    }

    /// ...and files no inbox row for it. Nothing in the app can render or clear that list, so a row
    /// per parent check is an app-icon badge that only deleting the app can reset.
    func testAlertShapedCommandsFileNoInboxRowWhileRealTextStillDoes() async {
        await PushInboxStore.shared.clearAll()
        await MainActor.run { RuntimeDiagnosticsCenter.shared.resetPush() }
        let dsn = "child-alert-inbox"

        for event in ["stream.start", "stream.stop", "status.report"] {
            PushCommandRouter.handle(
                userInfo: [
                    "event": event,
                    "dsn": dsn,
                    "aps": [
                        "alert": ["title": "Ota-ona tekshiryapti", "body": "Ota-onangiz siz bilan bog'lanmoqda"],
                        "content-available": 1
                    ]
                ],
                deliveryContext: .backgroundFetch
            )
        }

        // A control that MUST still file: human text under an event that names no hardware command.
        PushCommandRouter.handle(
            userInfo: [
                "event": "announcement",
                "dsn": dsn,
                "aps": ["alert": ["title": "E'lon", "body": "Yangi vazifa qo'shildi"]]
            ],
            deliveryContext: .backgroundFetch
        )

        let items = await waitForPushInboxItemsMatchingDSNForTests(count: 1, dsn: dsn)
        XCTAssertEqual(items.count, 1, "only the announcement may occupy a row")
        XCTAssertEqual(items.first?.event, "announcement")
    }
}

final class PushAudioCommandRoutingTests: XCTestCase {

    // MARK: Human-authored text can never reach the microphone

    func testParentMessageBodyNeverStartsAudio() {
        // The regression that motivated all of this: the router used to match over event + title +
        // body, and for a chat push the body IS the parent's typed message.
        for body in ["tingla", "listen", "audio darsi", "efirga chiq", "mic test", "stream"] {
            let payload = PushCommandRouter.parsePayload(from: [
                "event": "message_new",
                "aps": ["alert": ["title": "Ota-ona", "body": body]]
            ])
            XCTAssertNil(
                PushCommandRouter.audioRoute(forCommand: payload.commandHaystack),
                "body \"\(body)\" must not reach the audio route"
            )
        }
    }

    func testCommandHaystackExcludesTitleAndBody() {
        let payload = PushCommandRouter.parsePayload(from: [
            "event": "message_new",
            "aps": ["alert": ["title": "Listen", "body": "tingla"]]
        ])
        XCTAssertEqual(payload.commandHaystack, "message_new")
        XCTAssertTrue(payload.routingHaystack.contains("tingla"), "the wide haystack is unchanged")
    }

    // MARK: Start

    func testExplicitStartEventsStart() {
        for event in ["stream.audio.start", "stream.start", "audio.start", "listen.start",
                      "audio_start", "stream.audio.started", "device.audio.wake"] {
            XCTAssertEqual(PushCommandRouter.audioRoute(forCommand: event), .start, event)
        }
    }

    func testBareSubjectEventStarts() {
        for event in ["stream", "audio", "stream.audio", "streamaudio", "device.stream"] {
            XCTAssertEqual(PushCommandRouter.audioRoute(forCommand: event), .start, event)
        }
    }

    // MARK: Stop wins, including inflections

    func testExplicitStopEventsStop() {
        for event in ["stream.audio.stop", "stream.stop", "audio.stop", "listen.stop",
                      "stream.audio.end", "audio_stop", "efir.tugat"] {
            XCTAssertEqual(PushCommandRouter.audioRoute(forCommand: event), .stop, event)
        }
    }

    func testInflectedStopEventsStillStop() {
        // Whole-token EQUALITY would miss every one of these and — because the router previously
        // fell through to .start — would have opened the mic exactly when the parent hung up.
        for event in ["stream.audio.stopped", "audio.ended", "stream.stopping",
                      "audio.disconnected", "stream.audio.cancelled", "streamaudiostopped"] {
            XCTAssertEqual(PushCommandRouter.audioRoute(forCommand: event), .stop, event)
        }
    }

    func testStopWinsOverStart() {
        XCTAssertEqual(PushCommandRouter.audioRoute(forCommand: "stream.audio.start.stop"), .stop)
    }

    // MARK: The substring traps that caused the original bug

    func testWordsMerelyContainingStopStemsDoNotStop() {
        // "sending" and "friend" contain "end"; matching that as a substring turned a start into a
        // stop. Prefix-on-token is what keeps them apart.
        //
        // "stream.audio.sending" names no verb at all, so the fail-closed rule makes it nil — the
        // point here is only that "end" inside "sending" does not manufacture a .stop.
        XCTAssertNotEqual(PushCommandRouter.audioRoute(forCommand: "stream.audio.sending"), .stop)
        XCTAssertEqual(PushCommandRouter.audioRoute(forCommand: "audio.friend.start"), .start)
    }

    func testWordsMerelyContainingSubjectStemsDoNotRoute() {
        // "dynamic" contains "mic".
        XCTAssertNil(PushCommandRouter.audioRoute(forCommand: "dynamic.config.changed"))
        XCTAssertNil(PushCommandRouter.audioRoute(forCommand: "task.updated"))
        XCTAssertNil(PushCommandRouter.audioRoute(forCommand: ""))
    }

    // MARK: Fails closed

    func testAudioSubjectWithoutVerbDoesNotStart() {
        // Informational audio events must not be read as a wake.
        for event in ["stream.audio.failed", "audio.token.expired", "stream.status",
                      "audio.quality.degraded", "stream.audio.error"] {
            XCTAssertNil(
                PushCommandRouter.audioRoute(forCommand: event),
                "\(event) must not open the microphone"
            )
        }
    }
}

// MARK: - D-073 stream.start command parsing
//
// The lease/mode/camera fields ride through the push layer as strings; StreamCommand parses them
// once at the hardware boundary. These pin the drop-when-stale rule and the audio/video mapping.

final class StreamCommandParsingTests: XCTestCase {

    private func note(_ info: [String: Any]) -> Notification {
        Notification(name: .pushShouldStartAudioStream, object: nil, userInfo: info)
    }

    func testVideoBackCommandParses() {
        let future = Date().addingTimeInterval(120)
        let cmd = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "video",
            PushUserInfoKeys.streamCameraType: "Back",
            PushUserInfoKeys.streamMaxDurationSeconds: "90",
            PushUserInfoKeys.streamExpiresAt: String(Int(future.timeIntervalSince1970 * 1000))
        ]))
        XCTAssertEqual(cmd.mode, .video)
        XCTAssertEqual(cmd.cameraPosition, .back)
        XCTAssertEqual(cmd.maxDurationSeconds, 90)
        XCTAssertFalse(cmd.isStaleWake)
    }

    func testAudioCommandHasNoCamera() {
        let cmd = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "audio",
            // Even if a stray cameraType leaks in, audio mode must never carry a camera position.
            PushUserInfoKeys.streamCameraType: "Front",
            PushUserInfoKeys.streamMaxDurationSeconds: "120",
            PushUserInfoKeys.streamExpiresAt: String(Int(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000))
        ]))
        XCTAssertEqual(cmd.mode, .audio)
        XCTAssertNil(cmd.cameraPosition)
    }

    func testVideoWithoutCameraTypeDefaultsToFront() {
        let cmd = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "video",
            PushUserInfoKeys.streamExpiresAt: String(Int(Date().addingTimeInterval(60).timeIntervalSince1970 * 1000))
        ]))
        XCTAssertEqual(cmd.cameraPosition, .front)
    }

    func testExpiredWakeIsStale() {
        let past = Date().addingTimeInterval(-5)
        let cmd = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "audio",
            PushUserInfoKeys.streamExpiresAt: String(Int(past.timeIntervalSince1970 * 1000))
        ]))
        XCTAssertTrue(cmd.isStaleWake, "a wake past its expiresAt must be dropped")
    }

    /// The clock belongs to the CHILD. A phone wound forward makes every server `expiresAt` look
    /// long past, which used to drop 100% of the parent's live checks permanently and silently.
    func testImplausiblyOldExpiryIsDisbelievedRatherThanObeyed() {
        let wayPast = Date().addingTimeInterval(-(StreamCommand.maxTrustedClockSkew + 600))
        let cmd = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "audio",
            PushUserInfoKeys.streamExpiresAt: String(Int(wayPast.timeIntervalSince1970 * 1000))
        ]))
        XCTAssertTrue(cmd.hasImplausibleExpiry)
        XCTAssertFalse(cmd.isStaleWake, "a clock-skewed expiry must fall back to the receipt lease")
        XCTAssertGreaterThan(cmd.remainingLeaseSeconds, 0, "and the fallback lease must be usable")
    }

    /// The other side of the same rule: an ORDINARY late push is still dropped, so a command that
    /// genuinely expired while the parent walked away cannot open the microphone.
    func testOrdinaryLateWakeIsStillDropped() {
        let recentlyPast = Date().addingTimeInterval(-60)
        let cmd = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "audio",
            PushUserInfoKeys.streamExpiresAt: String(Int(recentlyPast.timeIntervalSince1970 * 1000))
        ]))
        XCTAssertFalse(cmd.hasImplausibleExpiry, "60s late is well within any delivery delay")
        XCTAssertTrue(cmd.isStaleWake)
    }

    func testMissingExpiresAtFallsBackToTheReceiptTimeLease() {
        // `expiresAt` is in no version of the D-073 contract, so failing closed on it dropped 100%
        // of stream.start pushes from a backend that never sends it. A command with no expiry is
        // NOT stale: its lease simply runs maxDurationSeconds from receipt.
        let cmd = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "audio",
            PushUserInfoKeys.streamMaxDurationSeconds: "90"
        ]))
        XCTAssertNil(cmd.expiresAt)
        XCTAssertFalse(cmd.isStaleWake, "a push with no expiresAt must still be honoured")
        XCTAssertEqual(cmd.remainingLeaseSeconds, 90, accuracy: 1)
    }

    func testUnparseableExpiresAtFallsBackToTheReceiptTimeLease() {
        let cmd = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "audio",
            PushUserInfoKeys.streamMaxDurationSeconds: "120",
            PushUserInfoKeys.streamExpiresAt: "whenever"
        ]))
        XCTAssertNil(cmd.expiresAt)
        XCTAssertFalse(cmd.isStaleWake)
        XCTAssertEqual(cmd.remainingLeaseSeconds, 120, accuracy: 1)
    }

    func testExpiresAtAcceptsSecondsAndISO8601AsWellAsMillis() {
        let future = Date().addingTimeInterval(60)
        let iso = ISO8601DateFormatter().string(from: future)

        for raw in [
            String(Int(future.timeIntervalSince1970 * 1000)),   // epoch millis
            String(Int(future.timeIntervalSince1970)),          // epoch seconds
            iso                                                  // ISO-8601
        ] {
            let cmd = StreamCommand(notification: note([
                PushUserInfoKeys.streamMode: "audio",
                PushUserInfoKeys.streamExpiresAt: raw
            ]))
            XCTAssertNotNil(cmd.expiresAt, "\(raw) must parse")
            XCTAssertFalse(cmd.isStaleWake, "\(raw) is 60s in the future")
            XCTAssertEqual(cmd.expiresAt?.timeIntervalSince1970 ?? 0, future.timeIntervalSince1970, accuracy: 1)
        }
    }

    func testLeaseIsArmedFromTheEffectiveDeadlineNotFromReceipt() {
        // A push held in transit: the server minted a 120s lease that already has 30s left. Arming
        // from maxDurationSeconds at receipt would hand the session another full 120s of publishing.
        let cmd = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "audio",
            PushUserInfoKeys.streamMaxDurationSeconds: "120",
            PushUserInfoKeys.streamExpiresAt: String(Int(Date().addingTimeInterval(30).timeIntervalSince1970 * 1000))
        ]))
        XCTAssertFalse(cmd.isStaleWake)
        XCTAssertEqual(cmd.remainingLeaseSeconds, 30, accuracy: 1)
    }

    /// A backend encoding `expiresAt` as a RELATIVE duration would resolve to 1970 and read as long
    /// expired — dropping every push, which is the fail-closed bug this parsing exists to remove.
    func testRelativeDurationExpiresAtFallsBackInsteadOfReadingAsExpired() {
        let cmd = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "audio",
            PushUserInfoKeys.streamMaxDurationSeconds: "120",
            PushUserInfoKeys.streamExpiresAt: "120"
        ]))

        XCTAssertFalse(cmd.isStaleWake, "an implausible epoch must fall back, not be treated as expired")
        XCTAssertEqual(cmd.remainingLeaseSeconds, 120, accuracy: 1)
    }

    // MARK: Consent split (mic vs camera)

    private func consentDefaults(audio: Bool, video: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "AudioConsentTests.\(UUID().uuidString)")!
        defaults.set(audio, forKey: "OILA_AUDIO_CONSENT_GRANTED")
        defaults.set(video, forKey: "OILA_VIDEO_CONSENT_GRANTED")
        return defaults
    }

    /// `requestStart` is gated by `AppRuntime.audioStreamingEnabled`, which is false in the shipping
    /// Info.plist (deliberately — the media feature is not released). Without overriding the gate
    /// every assertion below would pass vacuously against a method that returned at its first guard,
    /// so the manager exposes an injection seam. (`setenv` does not work here: `ProcessInfo`
    /// snapshots the environment at process start.)
    @MainActor
    private func makeEnabledManager(audio: Bool, video: Bool) -> DeviceAudioStreamManager {
        let manager = DeviceAudioStreamManager(defaults: consentDefaults(audio: audio, video: video))
        manager.isFeatureEnabled = { true }
        return manager
    }

    // MARK: Onboarding consent mirror

    /// The defect Ibrohim reported as *"men ruxsat berdim o'zi. yana so'rayapti"*: onboarding asked
    /// for the microphone and the camera, the child said yes, and the first listen asked the same
    /// question again — because nothing outside the consent sheet ever wrote the app-level flag.
    @MainActor
    func testAnsweringTheOnboardingStepsMeansTheFirstListenDoesNotAskAgain() {
        let manager = makeEnabledManager(audio: false, video: false)

        manager.grantOnboardingMediaConsent(microphone: true, camera: true)
        manager.requestStart(command: .debugAudio)

        XCTAssertFalse(manager.needsConsent, "the child already answered this question in onboarding")
        XCTAssertEqual(manager.grantedConsent, .video)
    }

    /// A microphone-only onboarding grant must NOT carry the camera with it — the Guideline 5.1.2
    /// half of the same rule the consent sheet enforces.
    @MainActor
    func testMicrophoneOnlyOnboardingGrantDoesNotAuthorizeTheCamera() {
        let manager = makeEnabledManager(audio: false, video: false)

        manager.grantOnboardingMediaConsent(microphone: true, camera: false)

        XCTAssertEqual(manager.grantedConsent, .audio)
    }

    /// A declined microphone step records nothing, so the sheet still appears. A consent flag
    /// standing over a denied OS permission is worse than the extra prompt: the session would go
    /// straight into a capture guard that fails with nothing on screen.
    @MainActor
    func testDecliningTheMicrophoneStepRecordsNoConsent() {
        let manager = makeEnabledManager(audio: false, video: false)

        manager.grantOnboardingMediaConsent(microphone: false, camera: true)

        XCTAssertNil(manager.grantedConsent)
        manager.requestStart(command: .debugAudio)
        XCTAssertTrue(manager.needsConsent)
    }

    /// The mirror is fired from a status change AND from the step itself, so it runs repeatedly with
    /// whatever the current pair of answers is. Writing one mode from the pair is what makes that
    /// safe: applying the two independently would let a late microphone callback call
    /// `recordConsent(.audio)` and clear a camera consent recorded a moment earlier.
    @MainActor
    func testRepeatedMirroringIsIdempotentAndKeepsTheCameraGrant() {
        let manager = makeEnabledManager(audio: false, video: false)

        manager.grantOnboardingMediaConsent(microphone: true, camera: true)
        manager.grantOnboardingMediaConsent(microphone: true, camera: true)

        XCTAssertEqual(manager.grantedConsent, .video)
    }

    /// REGRESSION. An adversarial review of the first version of this mirror found it took the live
    /// OS statuses rather than the child's answers, which re-created — out of the iOS grants that
    /// survive an unpair — the cross-child leak `SessionStore.purgeChildScopedData` step 4 exists to
    /// close.
    ///
    /// The scenario: the handset is re-paired to a DIFFERENT child, so `clearSession()` has wiped
    /// both consent flags while iOS still holds the microphone and camera grants from the previous
    /// family. The new child answers the microphone step (which comes FIRST) and has not yet been
    /// shown the camera step. Passing the raw camera status here wrote `.video`, and the child could
    /// then decline the camera outright and still have it opened with no sheet.
    ///
    /// The call site now passes `cameraAnswer == true && status == .authorized`, so an unanswered
    /// camera step contributes `false` no matter what iOS holds.
    @MainActor
    func testTheMicrophoneStepCannotGrantACameraTheChildWasNeverAskedAbout() {
        let manager = makeEnabledManager(audio: false, video: false)

        // Microphone answered yes; camera step not reached, so its answer is nil ⇒ `false` here.
        manager.grantOnboardingMediaConsent(microphone: true, camera: false)

        XCTAssertEqual(manager.grantedConsent, .audio, "an unanswered camera step must grant nothing")

        manager.requestStart(command: StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "video"
        ])))
        XCTAssertTrue(manager.needsConsent, "a video request must still meet the sheet")
    }

    /// REGRESSION (critical). The mirror is grant-only, and these three tests are why.
    ///
    /// The flow's answers are `@State` living for the whole of B1–B11, never reset, and the mirror
    /// re-fires from `.onChange` on either permission status. So a STALE decline replays on every
    /// later status change. Two earlier versions of this function could retract; with a
    /// `revokeConsent()` behind it the replay killed a live session: the child declines the
    /// microphone step, the parent later presses listen, the consent sheet (which RootView hangs
    /// above the routing branch, so it draws over onboarding) is answered "Allow", the session goes
    /// live — and the iOS permission alert's own resign/become-active cycle refreshes the status,
    /// re-fires the mirror, and the stale `false` tears the session down.
    @MainActor
    func testAStaleDeclineReplayCannotRevokeAGrantMadeAfterIt() {
        let manager = makeEnabledManager(audio: false, video: false)

        // The child declined the microphone step earlier in the flow.
        manager.grantOnboardingMediaConsent(microphone: false, camera: false)
        // Then answered the live consent sheet, which is a separate, deliberate grant.
        manager.requestStart(command: .debugAudio)
        manager.grantConsentAndStart()
        XCTAssertNotNil(manager.grantedConsent, "precondition: the sheet recorded a grant")

        // A later status change re-fires the mirror with the STALE decline still in @State.
        manager.grantOnboardingMediaConsent(microphone: false, camera: false)

        XCTAssertNotNil(manager.grantedConsent,
                        "an onboarding step must never revoke a consent given through the sheet")
    }

    /// REGRESSION. A step the child has NOT REACHED reads as `false` at the call site, and
    /// `recordConsent(.audio)` deliberately clears the camera flag — so answering the microphone
    /// step used to wipe a video consent granted through the sheet minutes earlier, reintroducing
    /// "men ruxsat berdim o'zi. yana so'rayapti" for video. Additive writes make that impossible.
    @MainActor
    func testAnsweringTheMicStepDoesNotWipeAVideoGrantTheSheetRecorded() {
        let manager = makeEnabledManager(audio: true, video: true)
        XCTAssertEqual(manager.grantedConsent, .video, "precondition: the sheet granted video")

        // Microphone step answered yes; the camera step has not been reached, so it sends `false`.
        manager.grantOnboardingMediaConsent(microphone: true, camera: false)

        XCTAssertEqual(manager.grantedConsent, .video,
                       "an unreached camera step must not read as a refusal")
    }

    /// A declined step grants nothing — that is the whole of its effect. Withdrawal lives on the
    /// Settings consent card and the indicator's Stop button, both of which DO stop the session;
    /// putting that power on a replayable onboarding answer is what caused the defect above.
    @MainActor
    func testADeclinedStepGrantsNothingAndTouchesNothingElse() {
        let manager = makeEnabledManager(audio: false, video: false)

        manager.grantOnboardingMediaConsent(microphone: false, camera: true)

        XCTAssertNil(manager.grantedConsent)
        manager.requestStart(command: .debugAudio)
        XCTAssertTrue(manager.needsConsent, "with nothing granted, the sheet is still the gate")
    }

    /// An existing audio-only grant must keep working without re-prompting — splitting the key must
    /// not invalidate consent every child in the field has already given.
    @MainActor
    func testExistingAudioGrantStillStartsAudioWithoutReprompting() {
        let manager = makeEnabledManager(audio: true, video: false)

        manager.requestStart(command: .debugAudio)

        XCTAssertFalse(manager.needsConsent, "an audio grant already on file must not re-prompt")
    }

    /// ...and must NOT silently authorize the camera. This is the Guideline 5.1.2 half: a child who
    /// allowed a microphone check once did not agree to have their camera opened.
    @MainActor
    func testExistingAudioGrantDoesNotAuthorizeVideo() {
        let manager = makeEnabledManager(audio: true, video: false)

        manager.requestStart(command: StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "video",
            PushUserInfoKeys.streamMaxDurationSeconds: "120"
        ])))

        XCTAssertTrue(manager.needsConsent, "video needs its own grant")
        XCTAssertEqual(manager.consentMode, .video, "the sheet must describe the camera, not the mic")
    }

    /// The consent sheet must never act on a default command: `pendingCommand` is cleared by stop()
    /// and by start()'s queued-command capture, so a tap arriving after that must open no hardware.
    ///
    /// But it must still RECORD the grant, and this test used to pin the opposite. Dropping it is
    /// the bug behind the product owner's "men ruxsat berdim o'zi. yana so'rayapti": a stop push
    /// landing while the sheet was on screen turned the child's Allow into a no-op, so the sheet
    /// returned on the next request. The tap is the consent; the parked command is only what
    /// happens next.
    ///
    /// `requestMicPermission` is stubbed because the grant now also banks the OS permission while
    /// the child is on screen (see `grantConsentWithoutStarting`), and the production default would
    /// reach a real `AVAudioApplication` prompt from the test host.
    @MainActor
    func testGrantWithNoPendingCommandRecordsConsentWithoutStartingAnything() {
        let manager = makeEnabledManager(audio: false, video: false)
        manager.requestMicPermission = { false }

        manager.grantConsentAndStart()

        XCTAssertFalse(manager.needsConsent)
        XCTAssertFalse(manager.isLive, "a grant with nothing pending must not open hardware")
        XCTAssertEqual(
            manager.grantedConsent,
            .audio,
            "the child answered the sheet — that answer has to survive to the next request"
        )
    }

    func testDurationIsClampedToBackendBounds() {
        let over = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "audio",
            PushUserInfoKeys.streamMaxDurationSeconds: "99999"
        ]))
        XCTAssertEqual(over.maxDurationSeconds, 300)

        let bad = StreamCommand(notification: note([
            PushUserInfoKeys.streamMode: "audio",
            PushUserInfoKeys.streamMaxDurationSeconds: "not-a-number"
        ]))
        XCTAssertEqual(bad.maxDurationSeconds, 120, "an unparseable duration falls back to 120s")
    }

    func testPayloadParsingLiftsStreamFieldsFromDataDictionary() {
        // The fields can arrive nested under `data` (FCM silent data message).
        let payload = PushCommandRouter.parsePayload(from: [
            "data": [
                "type": "stream.start",
                "mode": "video",
                "cameraType": "Back",
                "maxDurationSeconds": "120",
                "expiresAt": "1900000000000"
            ]
        ])
        XCTAssertEqual(payload.event, "stream.start")
        XCTAssertEqual(payload.streamMode, "video")
        XCTAssertEqual(payload.streamCameraType, "Back")
        XCTAssertEqual(payload.streamMaxDurationSeconds, "120")
        XCTAssertEqual(payload.streamExpiresAt, "1900000000000")
    }

    // MARK: Consent is revocable

    /// The published mirror is what the Settings card binds to. UserDefaults is not observable, so
    /// if this ever stopped tracking the stored flags the card would offer to revoke a grant that
    /// no longer exists — or, worse, hide one that does.
    @MainActor
    func testGrantedConsentMirrorsTheStoredGrant() {
        XCTAssertNil(makeEnabledManager(audio: false, video: false).grantedConsent,
                     "no grant on file means nothing to withdraw")
        XCTAssertEqual(makeEnabledManager(audio: true, video: false).grantedConsent, .audio)
        XCTAssertEqual(makeEnabledManager(audio: true, video: true).grantedConsent, .video)
    }

    /// A camera flag without the audio grant it was taken alongside is not a grant. `hasConsent`
    /// already requires both, and the mirror must agree — otherwise Settings would announce "live
    /// video is allowed" on a device where a video request still prompts.
    @MainActor
    func testOrphanVideoFlagIsNotReportedAsAGrant() {
        XCTAssertNil(makeEnabledManager(audio: false, video: true).grantedConsent)
    }

    /// Revoking must clear BOTH halves and leave nothing a later audio-only re-consent could
    /// inherit as camera permission.
    @MainActor
    func testRevokeConsentClearsBothHalves() {
        let defaults = consentDefaults(audio: true, video: true)
        let manager = DeviceAudioStreamManager(defaults: defaults)
        manager.isFeatureEnabled = { true }
        XCTAssertEqual(manager.grantedConsent, .video)

        manager.revokeConsent()

        XCTAssertNil(manager.grantedConsent)
        XCTAssertFalse(defaults.bool(forKey: "OILA_AUDIO_CONSENT_GRANTED"))
        XCTAssertFalse(defaults.bool(forKey: "OILA_VIDEO_CONSENT_GRANTED"))

        // And the gate must actually re-prompt afterwards, not just look revoked in the UI.
        manager.requestStart(command: .debugAudio)
        XCTAssertTrue(manager.needsConsent, "a withdrawn grant must ask again")
    }

    // MARK: Local notifications are not inbound commands

    /// `willPresent`/`didReceive` route arriving notifications through `PushCommandRouter`. The
    /// integrity and recovery notifiers post userInfo shaped exactly like a server command, so
    /// without this classification the app re-ingested its own output as a fresh event.
    func testLocallyScheduledNotificationsAreRecognised() {
        XCTAssertTrue(LocalNotificationID.isLocallyScheduled(LocalNotificationID.livePresence))
        XCTAssertTrue(LocalNotificationID.isLocallyScheduled(
            LocalNotificationID.integrityPrefix + UUID().uuidString))
        XCTAssertTrue(LocalNotificationID.isLocallyScheduled(
            LocalNotificationID.recoveryPrefix + UUID().uuidString))
    }

    /// The other direction matters more: misclassifying a real push as ours would silently drop the
    /// parent's command. Anything APNs delivers carries an identifier we did not choose.
    func testServerDeliveredNotificationsAreNotTreatedAsLocal() {
        for identifier in ["", "0:1234567890123456%abcdef", "stream.start", "device-control", "oila.live-stream"] {
            XCTAssertFalse(LocalNotificationID.isLocallyScheduled(identifier),
                           "\(identifier) is not one of ours and must still be routed")
        }
    }
}


// MARK: - Live-media wake addressing (F2)
//
// The gate in front of the child's microphone. It used to refuse any `stream.*` push that carried
// no `dsn` — and the backend addresses a child by FCM registration token and puts no `dsn` in the
// payload at all (the Android child app, the reference implementation of this contract, reads only
// type/mode/cameraType/maxDurationSeconds/expiresAt). So the gate discarded 100% of real wake
// commands while diagnostics recorded them as routed. These pin both halves: unaddressed commands
// are honoured under the stated conditions, and a command naming another device never is.

final class StreamWakeAddressingTests: XCTestCase {

    private let ours = "11111111-2222-3333-4444-555555555555"
    private let sibling = "99999999-8888-7777-6666-555555555555"

    // MARK: The regression itself

    func testUnaddressedStartIsAcceptedWhenAllowed() {
        // The whole point: this is the shape the backend actually sends.
        XCTAssertEqual(
            StreamWakeAddressing.decide(pushedDSN: nil, localDSN: ours, allowUnaddressed: true),
            .accept,
            "the backend sends no dsn in stream.*; refusing that shape drops every real wake"
        )
    }

    func testUnaddressedStartIsRefusedWhenNotAllowed() {
        // An unpaired install passes allowUnaddressed: false, so a stray broadcast opens nothing.
        XCTAssertEqual(
            StreamWakeAddressing.decide(pushedDSN: nil, localDSN: nil, allowUnaddressed: false),
            .dropUnaddressed
        )
    }

    func testEmptyDSNCountsAsUnaddressed() {
        // PushCommandRouter posts `dsn: ""` when the payload had none, so blank must not be read as
        // "a device named the empty string" and fall through to the mismatch branch.
        XCTAssertEqual(
            StreamWakeAddressing.decide(pushedDSN: "   ", localDSN: ours, allowUnaddressed: true),
            .accept
        )
        XCTAssertEqual(
            StreamWakeAddressing.decide(pushedDSN: "", localDSN: ours, allowUnaddressed: false),
            .dropUnaddressed
        )
    }

    // MARK: The protection that must survive the fix

    func testCommandForAnotherDeviceIsAlwaysRefused() {
        // A sibling child on the same family account. `allowUnaddressed` must not relax this.
        for allowUnaddressed in [true, false] {
            XCTAssertEqual(
                StreamWakeAddressing.decide(
                    pushedDSN: sibling, localDSN: ours, allowUnaddressed: allowUnaddressed
                ),
                .dropOtherDevice,
                "an addressed command is judged on its address, whatever unaddressed policy applies"
            )
        }
    }

    func testAddressedCommandForUsIsAccepted() {
        XCTAssertEqual(
            StreamWakeAddressing.decide(pushedDSN: ours, localDSN: ours, allowUnaddressed: false),
            .accept
        )
    }

    func testAddressingIsCaseInsensitive() {
        XCTAssertEqual(
            StreamWakeAddressing.decide(
                pushedDSN: ours.uppercased(), localDSN: ours.lowercased(), allowUnaddressed: false
            ),
            .accept,
            "DSNs are UUIDs and the server's casing is not guaranteed to match ours"
        )
    }

    func testAddressedCommandWithNoLocalIdentityIsRefused() {
        // Nothing to compare against — and asking must never mint an identity, which is why the
        // manager reads persistedDSN rather than deviceDSN.
        XCTAssertEqual(
            StreamWakeAddressing.decide(pushedDSN: sibling, localDSN: nil, allowUnaddressed: true),
            .dropNoLocalDSN,
            "a named command with no local DSN cannot match, even when unaddressed ones are allowed"
        )
    }

    func testEveryDecisionHasADistinctDiagnosticSuffix() {
        let suffixes = [
            StreamWakeAddressing.Decision.accept,
            .dropUnaddressed,
            .dropNoLocalDSN,
            .dropOtherDevice
        ].map(\.diagnosticSuffix)
        XCTAssertEqual(Set(suffixes).count, suffixes.count, "a drop reason must be tellable apart")
    }
}

// MARK: - Live-session disclosure policy
//
// The rule that keeps this feature non-covert: a session may only run while the child can SEE it
// running. It used to be enforced only on a foreground->background scene transition, which a
// push-woken session never makes — so once wake commands actually started working, a session begun
// off screen could open the microphone with no indicator rendered and no presence notification.

final class LiveSessionDisclosureTests: XCTestCase {

    func testForegroundIsAlwaysDisclosedByTheOnScreenIndicator() {
        for mode in [StreamMode.audio, .video] {
            // Notifications are irrelevant on screen: the in-app indicator is the channel.
            XCTAssertEqual(
                LiveSessionDisclosure.verdict(mode: mode, isForeground: true, presenceBannerWouldRender: false),
                .allowed(.onScreenIndicator)
            )
        }
    }

    func testBackgroundAudioNeedsTheNotificationChannel() {
        XCTAssertEqual(
            LiveSessionDisclosure.verdict(mode: .audio, isForeground: false, presenceBannerWouldRender: true),
            .allowed(.presenceNotification)
        )
    }

    /// The parameter is "would a banner RENDER", not "is the app authorized" — a distinction that
    /// used to be collapsed at the call site. A child can leave Allow Notifications on while turning
    /// Banners, Lock Screen and Notification Centre off (status stays `.authorized`, `add` still
    /// succeeds, nothing appears), and Scheduled Summary defers the banner to the evening digest.
    /// Both resolved to `true` and ran the microphone off-screen with nothing disclosing it.
    /// `presenceBannerWouldRenderNow()` is what now answers this honestly; this pins the contract it
    /// has to satisfy.
    func testABannerThatWouldNotRenderIsNotADisclosureChannel() {
        XCTAssertEqual(
            LiveSessionDisclosure.verdict(mode: .audio, isForeground: false,
                                          presenceBannerWouldRender: false),
            .refusedNoDisclosureChannel,
            "authorized-but-invisible must refuse exactly like unauthorized"
        )
    }

    /// The finding this whole type exists for.
    func testBackgroundAudioIsRefusedWithNoWayToDiscloseIt() {
        XCTAssertEqual(
            LiveSessionDisclosure.verdict(mode: .audio, isForeground: false, presenceBannerWouldRender: false),
            .refusedNoDisclosureChannel,
            "an open mic with nothing on the device disclosing it is the shape we refuse to ship"
        )
    }

    /// iOS suspends camera capture for a backgrounded app whatever is declared, so a background
    /// video session publishes a dead track behind a parent UI insisting they are watching.
    /// `handleAppDidEnterBackground` already stops video on the transition; starting must match.
    func testBackgroundVideoIsRefusedEvenWhenNotificationsAreAuthorized() {
        XCTAssertEqual(
            LiveSessionDisclosure.verdict(mode: .video, isForeground: false, presenceBannerWouldRender: true),
            .refusedVideoOffScreen
        )
    }

    func testOnlyAllowedVerdictsReportAsAllowed() {
        XCTAssertTrue(LiveSessionDisclosure.Verdict.allowed(.onScreenIndicator).isAllowed)
        XCTAssertTrue(LiveSessionDisclosure.Verdict.allowed(.presenceNotification).isAllowed)
        XCTAssertFalse(LiveSessionDisclosure.Verdict.refusedNoDisclosureChannel.isAllowed)
        XCTAssertFalse(LiveSessionDisclosure.Verdict.refusedVideoOffScreen.isAllowed)
    }

    func testEveryVerdictHasADistinctDiagnosticSuffix() {
        let suffixes: [LiveSessionDisclosure.Verdict] = [
            .allowed(.onScreenIndicator), .refusedNoDisclosureChannel, .refusedVideoOffScreen
        ].map { $0 }
        XCTAssertEqual(Set(suffixes.map(\.diagnosticSuffix)).count, 3)
    }
}

// MARK: - Stale parked-consent commands

extension StreamCommandParsingTests {

    /// A consent sheet raised by a push can sit unanswered for hours. The command parked behind it
    /// keeps the deadline it was minted with, so the staleness check that guards `onWakeStart` has
    /// to be applied again when consent finally arrives — otherwise Allow opens the microphone for
    /// the one second an expired lease clamps to, long after the parent stopped listening.
    func testAParkedCommandIsStillJudgedStaleWhenConsentArrivesLate() {
        let parked = StreamCommand(
            mode: .audio,
            cameraPosition: nil,
            maxDurationSeconds: 120,
            expiresAt: nil,
            receivedAt: Date().addingTimeInterval(-3600)   // pushed an hour ago
        )
        XCTAssertTrue(parked.isStaleWake, "an hour-old 120s lease is long gone")
        XCTAssertEqual(parked.remainingLeaseSeconds, 0, "and has no time left to run")
    }

    func testAFreshlyParkedCommandIsStillActionable() {
        let parked = StreamCommand(
            mode: .audio,
            cameraPosition: nil,
            maxDurationSeconds: 120,
            expiresAt: nil,
            receivedAt: Date().addingTimeInterval(-5)
        )
        XCTAssertFalse(parked.isStaleWake, "a child who taps Allow promptly must still be heard")
        XCTAssertGreaterThan(parked.remainingLeaseSeconds, 100)
    }
}

// MARK: - Live session lifecycle
//
// Everything below drives a REAL `DeviceAudioStreamManager` through a whole session. None of it was
// reachable before: `start()` built its publisher from a static factory and asked the microphone, the
// notification centre and `UIApplication` for the truth directly, so the first of those ended any
// test. The pure decision functions in front of it were well covered and the machine that obeys them
// was not covered at all -- which is why a disclosure gate could be walked past without a single test
// going red.

/// Records what the session did to the transport, and lets a test stall `connect()` at will so the
/// window between "gate passed" and "publishing" can be reasoned about.
private final class FakeMediaPublisher: LiveMediaPublishing, @unchecked Sendable {
    var onEnded: (() -> Void)?
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var connectedMode: StreamMode?
    /// Awaited inside `connect()`, so a test can act while the connect is in flight.
    var beforeConnectReturns: (@Sendable () async -> Void)?

    func connect(
        url: String,
        token: String,
        mode: StreamMode,
        cameraPosition: AVCaptureDevice.Position?
    ) async throws {
        connectCount += 1
        connectedMode = mode
        await beforeConnectReturns?()
    }

    func applyMode(_ mode: StreamMode, cameraPosition: AVCaptureDevice.Position?) async throws {
        connectedMode = mode
    }

    func disconnect() async { disconnectCount += 1 }
}

private struct FakeStreamTokenSource: OilaStreamServicing {
    func mintStreamToken() async throws -> OilaStreamToken {
        OilaStreamToken(token: "t", url: "wss://example.invalid", room: "r", identity: "device-1")
    }
}

@MainActor
final class LiveSessionLifecycleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "LiveSessionLifecycleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A manager wired to fakes, with consent already granted for `mode`.
    /// The parked request is re-based on the child's tap: a lease measured from the ORIGINAL push
    /// is already spent by the time anyone taps, so honouring it would open the microphone and close
    /// it in the same breath.
    func testAParkedRequestComesBackWithALeaseMeasuredFromTheTap() async {
        let store = PendingStreamRequestStore(userDefaults: defaults)
        let original = StreamCommand(
            mode: .audio,
            cameraPosition: nil,
            maxDurationSeconds: 120,
            expiresAt: Date().addingTimeInterval(-600),
            receivedAt: Date().addingTimeInterval(-600)
        )

        await store.save(original)
        let consumed = await store.consume()

        XCTAssertEqual(consumed?.mode, .audio)
        XCTAssertEqual(consumed?.maxDurationSeconds, 120)
        XCTAssertNil(consumed?.expiresAt, "the server window described the wait, not the session")
        XCTAssertGreaterThan(consumed?.remainingLeaseSeconds ?? 0, 0, "the tap must buy a usable session")
        let second = await store.consume()
        XCTAssertNil(second, "consuming a request must clear it")
    }

    /// A parent who pressed listen and walked away must not have the microphone open the moment
    /// their child next picks the phone up an hour later.
    func testAParkedRequestExpiresAfterTheAcceptanceWindow() async {
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let store = PendingStreamRequestStore(userDefaults: defaults, now: { clock.withLock { $0 } })
        await store.save(.debugAudio)
        let armed = await store.hasPending()
        XCTAssertTrue(armed)

        clock.withLock { $0 = $0.addingTimeInterval(PendingStreamRequestStore.acceptanceWindow + 1) }

        let consumed = await store.consume()
        XCTAssertNil(consumed, "a request older than the acceptance window must not open the microphone")
    }

    private func makeManager(
        publisher: FakeMediaPublisher,
        foreground: Bool = true,
        presenceBannerWouldRender: Bool = true,
        micGranted: Bool = true,
        cameraOutcome: DeviceAudioStreamManager.CameraPermissionOutcome = .granted,
        consentFor mode: StreamMode = .audio
    ) -> DeviceAudioStreamManager {
        defaults.set(true, forKey: "OILA_AUDIO_CONSENT_GRANTED")
        if mode == .video { defaults.set(true, forKey: "OILA_VIDEO_CONSENT_GRANTED") }
        let manager = DeviceAudioStreamManager(stream: FakeStreamTokenSource(), defaults: defaults)
        manager.isFeatureEnabled = { true }
        manager.makePublisher = { publisher }
        manager.isForeground = { foreground }
        manager.presenceBannerWouldRender = { presenceBannerWouldRender }
        manager.requestMicPermission = { micGranted }
        // Without this the camera gate answers from the real `AVCaptureDevice`, which is
        // `.notDetermined` in a test host — so every video test was refused at the camera before
        // it could reach the behaviour it was written to check.
        manager.requestCameraPermission = { cameraOutcome }
        return manager
    }

    func testAConsentedForegroundSessionReachesLive() async {
        let publisher = FakeMediaPublisher()
        let manager = makeManager(publisher: publisher)

        await manager.start(command: .debugAudio)

        XCTAssertTrue(manager.isLive, "a granted, disclosed, foreground session must actually publish")
        XCTAssertEqual(publisher.connectCount, 1)
        XCTAssertEqual(publisher.connectedMode, .audio)
        XCTAssertEqual(publisher.disconnectCount, 0)
    }

    // MARK: - A parent asking while the child's phone is in a pocket

    /// iOS refuses to open the microphone for a backgrounded process, so a cold start from a push
    /// must not even try: no token mint, no room join, no watchdog burned on an attempt that cannot
    /// succeed. It parks for the child's tap instead, and says so.
    func testABackgroundStartIsParkedForTheChildTapInsteadOfOpeningTheMicrophone() async {
        let publisher = FakeMediaPublisher()
        let manager = makeManager(publisher: publisher, foreground: false)

        manager.requestStart(command: .debugAudio)

        XCTAssertEqual(manager.state, .awaitingChildTap, "a background start must park, not connect")
        XCTAssertEqual(publisher.connectCount, 0, "nothing may reach the transport before the tap")
        XCTAssertFalse(manager.isLive)
    }

    /// The same request with the app on screen must behave exactly as it always has — the parking
    /// path is for the background only, and must not become a tap the child has to make while they
    /// are already looking at the app.
    func testAForegroundStartIsNotParked() async {
        let publisher = FakeMediaPublisher()
        let manager = makeManager(publisher: publisher, foreground: true)

        await manager.start(command: .debugAudio)

        XCTAssertTrue(manager.isLive)
        XCTAssertEqual(publisher.connectCount, 1)
    }

    /// THE CASE THAT MUST NOT REGRESS. A renewal is an un-mute of an engine that is already running,
    /// which iOS permits in the background — it is the one path that keeps a live session alive with
    /// the phone in a pocket. Parking it would silently end every session the moment the child
    /// locked the screen.
    func testARenewalIsNotParkedWhenTheAppIsInTheBackground() async {
        let publisher = FakeMediaPublisher()
        let onScreen = OSAllocatedUnfairLock(initialState: true)
        let manager = makeManager(publisher: publisher)
        manager.isForeground = { onScreen.withLock { $0 } }

        await manager.start(command: .debugAudio)
        XCTAssertTrue(manager.isLive)

        onScreen.withLock { $0 = false }
        manager.requestStart(command: .debugAudio)

        XCTAssertNotEqual(manager.state, .awaitingChildTap, "a live session must renew, never park")
        XCTAssertTrue(manager.isLive)
    }

    /// A stop is the parent saying they have stopped waiting. The parked request must not be able to
    /// open the microphone afterwards.
    func testStopClearsARequestThatWasWaitingForTheChildTap() async {
        let publisher = FakeMediaPublisher()
        let manager = makeManager(publisher: publisher, foreground: false)
        manager.requestStart(command: .debugAudio)
        XCTAssertEqual(manager.state, .awaitingChildTap)

        await manager.stop()

        XCTAssertNotEqual(manager.state, .awaitingChildTap)
        let store = PendingStreamRequestStore(userDefaults: defaults)
        let leftover = await store.consume()
        XCTAssertNil(leftover, "a stop must leave nothing behind that could open the microphone later")
    }

    func testStopTearsTheTransportDownAndLeavesNoLiveState() async {
        let publisher = FakeMediaPublisher()
        let manager = makeManager(publisher: publisher)
        await manager.start(command: .debugAudio)
        XCTAssertTrue(manager.isLive)

        await manager.stop()

        XCTAssertFalse(manager.isLive)
        XCTAssertEqual(publisher.disconnectCount, 1, "the room must be left, not just forgotten")
        XCTAssertNil(publisher.onEnded, "the room delegate must be detached before teardown")
    }

    /// THE REGRESSION. The child locks the screen while the token mint and the LiveKit connect are in
    /// flight, and has declined notifications. Before the second disclosure reading, this ended with
    /// `state == .live`: a microphone open with no indicator rendered and no banner available to post.
    func testBackgroundingDuringConnectRefusesTheSessionInsteadOfPublishingUnseen() async {
        let publisher = FakeMediaPublisher()
        // Foreground at the moment the parent asks, off screen by the time the room is up.
        let onScreen = OSAllocatedUnfairLock(initialState: true)
        let manager = makeManager(publisher: publisher, presenceBannerWouldRender: false)
        manager.isForeground = { onScreen.withLock { $0 } }
        publisher.beforeConnectReturns = { onScreen.withLock { $0 = false } }

        await manager.start(command: .debugAudio)

        XCTAssertFalse(manager.isLive, "a session the child cannot see must not go live")
        XCTAssertEqual(manager.state, .error("no_disclosure_channel"))
        XCTAssertEqual(publisher.disconnectCount, 1, "and the room it already joined must be left")
    }

    /// The same race, but the child DID authorize notifications, so the presence banner is a real
    /// disclosure channel and the session is allowed to continue off screen. This is the half that
    /// must not regress into refusing everything.
    func testBackgroundingDuringConnectIsAllowedWhenTheBannerCanBeShown() async {
        let publisher = FakeMediaPublisher()
        let onScreen = OSAllocatedUnfairLock(initialState: true)
        let manager = makeManager(publisher: publisher, presenceBannerWouldRender: true)
        manager.isForeground = { onScreen.withLock { $0 } }
        publisher.beforeConnectReturns = { onScreen.withLock { $0 = false } }

        await manager.start(command: .debugAudio)

        XCTAssertTrue(manager.isLive, "audio off screen is honest when the presence banner can be posted")
        XCTAssertEqual(publisher.disconnectCount, 0)
    }

    /// Video is refused off screen whatever the notification state: iOS suspends camera capture for a
    /// backgrounded app, so the parent would watch a frozen frame while the UI claimed otherwise.
    func testBackgroundingDuringConnectAlwaysRefusesVideo() async {
        let publisher = FakeMediaPublisher()
        let onScreen = OSAllocatedUnfairLock(initialState: true)
        let manager = makeManager(publisher: publisher, presenceBannerWouldRender: true, consentFor: .video)
        manager.isForeground = { onScreen.withLock { $0 } }
        publisher.beforeConnectReturns = { onScreen.withLock { $0 = false } }

        await manager.start(
            command: StreamCommand(mode: .video, cameraPosition: .front, maxDurationSeconds: 120, expiresAt: nil)
        )

        XCTAssertFalse(manager.isLive)
        XCTAssertEqual(manager.state, .error("video_off_screen"))
        XCTAssertEqual(publisher.disconnectCount, 1)
    }

    func testASessionRefusedBeforeConnectingNeverTouchesTheTransport() async {
        let publisher = FakeMediaPublisher()
        let manager = makeManager(publisher: publisher, foreground: false, presenceBannerWouldRender: false)

        await manager.start(command: .debugAudio)

        XCTAssertFalse(manager.isLive)
        XCTAssertEqual(publisher.connectCount, 0, "the first reading still refuses before any hardware")
    }

    func testADeniedMicrophoneNeverReachesTheTransport() async {
        let publisher = FakeMediaPublisher()
        let manager = makeManager(publisher: publisher, micGranted: false)

        await manager.start(command: .debugAudio)

        XCTAssertEqual(manager.state, .error("mic_denied"))
        XCTAssertEqual(publisher.connectCount, 0)
    }
}

@MainActor
final class LiveSessionConsentRaceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "LiveSessionConsentRaceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: "OILA_AUDIO_CONSENT_GRANTED")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeManager(_ publisher: FakeMediaPublisher) -> DeviceAudioStreamManager {
        let manager = DeviceAudioStreamManager(stream: FakeStreamTokenSource(), defaults: defaults)
        manager.isFeatureEnabled = { true }
        manager.makePublisher = { publisher }
        manager.isForeground = { true }
        manager.presenceBannerWouldRender = { true }
        manager.requestMicPermission = { true }
        manager.requestCameraPermission = { .granted }
        return manager
    }

    /// Declining a camera-upgrade sheet must not kill the audio session it is layered over. Before,
    /// `declineConsent()` reset the state whenever it was not `.live` -- which included `.connecting`,
    /// so a decline landing while the audio connect was still in flight silently aborted it at the
    /// next `state == .connecting` guard.
    func testDecliningConsentDoesNotAbortAConnectAlreadyInFlight() async {
        let publisher = FakeMediaPublisher()
        let manager = makeManager(publisher)
        // The decline has to land BEFORE the guards that read `state == .connecting`, which is where
        // the damage was done -- the microphone grant is the first await in `start()`, so a sheet
        // dismissed while iOS is showing that prompt is exactly the real-world shape.
        manager.requestMicPermission = { [weak manager] in
            await MainActor.run { manager?.declineConsent() }
            return true
        }

        await manager.start(command: .debugAudio)

        XCTAssertTrue(manager.isLive, "the audio session the child already consented to must survive")
        XCTAssertEqual(publisher.connectCount, 1)
        XCTAssertEqual(publisher.disconnectCount, 0)
    }

    /// A decline with nothing in flight still returns the manager to idle, so the sheet is not sticky.
    func testDecliningConsentWithNoSessionReturnsToIdle() async {
        let manager = makeManager(FakeMediaPublisher())
        manager.declineConsent()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.needsConsent)
    }
}

/// The wake observers are the seam a `stream.start` push crosses to reach the microphone. They were
/// the gate that dropped 100% of real commands before the addressing fix, and nothing tested that a
/// posted notification reaches the manager at all.
@MainActor
final class StreamWakeObserverTests: XCTestCase {
    private func makeManager(_ publisher: FakeMediaPublisher, defaults: UserDefaults) -> DeviceAudioStreamManager {
        defaults.set(true, forKey: "OILA_AUDIO_CONSENT_GRANTED")
        let manager = DeviceAudioStreamManager(stream: FakeStreamTokenSource(), defaults: defaults)
        manager.isFeatureEnabled = { true }
        manager.makePublisher = { publisher }
        manager.isForeground = { true }
        manager.presenceBannerWouldRender = { true }
        manager.requestMicPermission = { true }
        manager.requestCameraPermission = { .granted }
        return manager
    }

    /// An unaddressed `stream.start` — which is what the backend actually sends, as the Android
    /// client proved — must reach the hardware on a paired install.
    func testAPostedWakeStartsASessionOnAPairedInstall() async {
        let suiteName = "StreamWakeObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // `pushMatchesThisDevice` accepts an unaddressed start only on a paired install, and reads
        // the manager's OWN defaults — setting this on `.standard` is not enough.
        defaults.set(true, forKey: "BOLAJON_OILA_PAIRED")
        _ = OilaDeviceIdentity.deviceDSN()

        let publisher = FakeMediaPublisher()
        let manager = makeManager(publisher, defaults: defaults)

        NotificationCenter.default.post(
            name: .pushShouldStartAudioStream,
            object: nil,
            userInfo: [
                PushUserInfoKeys.streamMode: "audio",
                PushUserInfoKeys.streamMaxDurationSeconds: "120"
            ]
        )
        // The observer hops through a Task; give the main queue a turn to drain it.
        for _ in 0 ..< 40 where !manager.isLive {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(manager.isLive, "a posted stream.start must actually open the microphone")
        XCTAssertEqual(publisher.connectCount, 1)
    }

    /// And a stop must tear it down, unaddressed or not — a dropped stop leaves a microphone open.
    func testAPostedStopEndsTheSession() async {
        let suiteName = "StreamWakeObserverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let publisher = FakeMediaPublisher()
        let manager = makeManager(publisher, defaults: defaults)
        await manager.start(command: .debugAudio)
        XCTAssertTrue(manager.isLive)

        NotificationCenter.default.post(name: .pushShouldStopAudioStream, object: nil, userInfo: [:])
        for _ in 0 ..< 40 where manager.isLive {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(manager.isLive, "a stop must be honoured — a dropped one leaves the mic open")
        XCTAssertEqual(publisher.disconnectCount, 1)
    }
}

// MARK: - Stuck-connect reclaim

/// THE DEAF DEVICE. `cbdae04` added a reclaim for a `.connecting` attempt that iOS suspended
/// mid-connect — the watchdog is a sleeping Task, so a suspended process leaves an attempt that
/// neither completes nor times out, and the re-entrancy guard then rejects every later wake.
///
/// That reclaim shipped UNREACHABLE. It lives inside `start()`, and every production entry point
/// except the consent sheet goes through `requestStart(command:)`, which returned at its own
/// `.connecting` guard one frame earlier — so on the push route, the only route the bug occurs on,
/// `start()` was never entered and the reclaim never ran. Both tests below fail against that
/// version and are the reason the guard now consults `isStuckConnecting`.
@MainActor
final class LiveSessionReclaimTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// Released in tearDown so a wedged connect cannot outlive the test that parked it.
    private let wedge = OSAllocatedUnfairLock(initialState: false)

    override func setUp() async throws {
        suiteName = "LiveSessionReclaimTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        wedge.withLock { $0 = false }
    }

    override func tearDown() async throws {
        wedge.withLock { $0 = true }
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeManager(_ publisher: FakeMediaPublisher) -> DeviceAudioStreamManager {
        defaults.set(true, forKey: "OILA_AUDIO_CONSENT_GRANTED")
        let manager = DeviceAudioStreamManager(stream: FakeStreamTokenSource(), defaults: defaults)
        manager.isFeatureEnabled = { true }
        manager.makePublisher = { publisher }
        manager.isForeground = { true }
        manager.presenceBannerWouldRender = { true }
        manager.requestMicPermission = { true }
        manager.requestCameraPermission = { .granted }
        return manager
    }

    /// Parks a real attempt in `.connecting` the way a suspended background process does: the
    /// transport's `connect()` never returns, so the watchdog's sleep never advances either.
    private func wedgeAConnect(_ publisher: FakeMediaPublisher, on manager: DeviceAudioStreamManager) async {
        let wedge = self.wedge
        publisher.beforeConnectReturns = {
            while !wedge.withLock({ $0 }) {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        Task { await manager.start(command: .debugAudio) }
        for _ in 0 ..< 40 where manager.state != .connecting {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testASecondWakeReclaimsAStuckConnectInsteadOfBouncingOffIt() async {
        let stalled = FakeMediaPublisher()
        let manager = makeManager(stalled)
        // A clock the test can advance: `connectTimeout` is 45s and no test may sleep it out.
        let clock = OSAllocatedUnfairLock(initialState: TimeInterval(1_000))
        manager.monotonicNow = { clock.withLock { $0 } }

        await wedgeAConnect(stalled, on: manager)
        XCTAssertEqual(manager.state, .connecting, "the attempt must be parked before the reclaim is tested")

        // The attempt now outlives the watchdog's own timeout: a corpse, not an attempt in flight.
        clock.withLock { $0 += TimeInterval(120) }

        // The parent presses listen again. This is the line that used to return without a trace.
        let fresh = FakeMediaPublisher()
        manager.makePublisher = { fresh }
        manager.requestStart(command: .debugAudio)
        for _ in 0 ..< 40 where !manager.isLive {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(manager.isLive, "a wake arriving after the connect corpsed must reclaim it, not bounce off it")
        XCTAssertEqual(fresh.connectCount, 1, "and it must be a NEW room, not the wedged one")
    }

    /// The same corpse, driven through the real push observer — this is Ibrohim's acceptance gate
    /// end to end: "ota-ona tinglash bosadi va hech narsa bo'lmayapti".
    func testAPostedPushWakeReclaimsAStuckConnect() async {
        // `pushMatchesThisDevice` accepts an unaddressed start only on a paired install, and reads
        // the manager's OWN defaults — setting this on `.standard` is not enough.
        defaults.set(true, forKey: "BOLAJON_OILA_PAIRED")
        _ = OilaDeviceIdentity.deviceDSN()

        let stalled = FakeMediaPublisher()
        let manager = makeManager(stalled)
        let clock = OSAllocatedUnfairLock(initialState: TimeInterval(1_000))
        manager.monotonicNow = { clock.withLock { $0 } }

        await wedgeAConnect(stalled, on: manager)
        XCTAssertEqual(manager.state, .connecting)

        clock.withLock { $0 += TimeInterval(120) }

        let fresh = FakeMediaPublisher()
        manager.makePublisher = { fresh }
        NotificationCenter.default.post(
            name: .pushShouldStartAudioStream,
            object: nil,
            userInfo: [
                PushUserInfoKeys.streamMode: "audio",
                PushUserInfoKeys.streamMaxDurationSeconds: "120"
            ]
        )
        for _ in 0 ..< 40 where !manager.isLive {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(manager.isLive, "a push wake must reclaim a corpsed connect — this is the deaf-device bug")
        XCTAssertEqual(fresh.connectCount, 1)
    }

    /// The other half: a connect genuinely IN FLIGHT must still bounce a second wake, or the
    /// foreground double-delivery (alert + content-available) opens two publishers.
    func testAConnectStillInFlightStillBouncesASecondWake() async {
        let stalled = FakeMediaPublisher()
        let manager = makeManager(stalled)
        let clock = OSAllocatedUnfairLock(initialState: TimeInterval(1_000))
        manager.monotonicNow = { clock.withLock { $0 } }

        await wedgeAConnect(stalled, on: manager)
        XCTAssertEqual(manager.state, .connecting)

        // Well inside the 45s watchdog: this attempt is alive, not a corpse.
        clock.withLock { $0 += TimeInterval(5) }

        let fresh = FakeMediaPublisher()
        manager.makePublisher = { fresh }
        manager.requestStart(command: .debugAudio)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(fresh.connectCount, 0, "a live connect must absorb the duplicate, not race a second publisher")
        XCTAssertEqual(manager.state, .connecting)
    }
}

// MARK: - status.report routing

/// The Android child app answers `status.report` by posting a fresh `/device/status` snapshot at
/// once. iOS routed the event only to `.pushShouldRefreshDashboard`, which nothing observed, so the
/// parent's refresh did nothing. These pin the classifier that now drives `.pushShouldReportStatus`.
///
/// The rule under test is deliberately narrower than the dashboard route: the status subject must be
/// the event's FIRST token (or a whole-event alias), and the classifier reads the command — never the
/// notification title/body, which on a chat push is the parent's own words.
final class PushStatusReportRoutingTests: XCTestCase {

    func testBackendStatusReportEventIsRecognised() {
        XCTAssertTrue(PushCommandRouter.isStatusReportCommand("status.report"))
    }

    func testStatusVariantsAreRecognised() {
        for event in ["status", "status.request", "status_report", "STATUS.REPORT", " status.report ",
                      "statusreport", "holat.report", "device.status", "device_status"] {
            XCTAssertTrue(
                PushCommandRouter.isStatusReportCommand(event),
                "\(event) should be read as a status command"
            )
        }
    }

    /// `stream.status` is an informational event in the D-073 contract. It names the status, but the
    /// SUBJECT is the stream — reading it as a check-in command would have the device answer events
    /// that were never addressed to it.
    func testInformationalEventsNamingStatusAreNotCommands() {
        for event in ["stream.status", "audio.status", "lock.status.changed", "chat.refresh",
                      "stream.start", "stream.stop", "lock.refresh", ""] {
            XCTAssertFalse(
                PushCommandRouter.isStatusReportCommand(event),
                "\(event) must not be read as a status command"
            )
        }
    }

    /// The bug class this codebase has already been bitten by once (a parent typing "tingla" opened
    /// the microphone): a classifier that reads person-authored text.
    func testParentMessageBodyNeverTriggersAStatusReport() {
        for body in ["status", "holatni yubor", "device status", "status.report"] {
            let payload = PushCommandRouter.parsePayload(from: [
                "event": "chat.refresh",
                "aps": ["alert": ["title": "Ota-ona", "body": body]]
            ])
            XCTAssertFalse(
                PushCommandRouter.isStatusReportCommand(payload.commandHaystack),
                "body \"\(body)\" must not reach the status route"
            )
        }
    }

    /// The real payload the backend sends: a silent data push with no alert at all.
    func testSilentStatusReportPayloadRoutes() {
        let payload = PushCommandRouter.parsePayload(from: ["type": "status.report", "dsn": "abc"])
        XCTAssertTrue(PushCommandRouter.isStatusReportCommand(payload.commandHaystack))
    }
}

// MARK: - Location acceptance gate

/// Pins the port of the Android child app's `LocationProvider.accepts`. Before this existed, iOS
/// queued EVERY CoreLocation callback: a stationary child produced a scribble of GPS noise on the
/// parent's map, and a cell-tower-only fix could place them in the wrong district entirely.
final class LocationAcceptanceTests: XCTestCase {

    func testFirstFixIsAlwaysAccepted() {
        // Nothing to measure displacement against yet — the parent needs a point on the map.
        XCTAssertTrue(OilaTelemetryService.acceptsFix(accuracy: 12, distanceFromLast: nil))
    }

    /// Under `.authorizedAlways` the app also runs significant-location-change monitoring, and after
    /// a background relaunch that is the only source delivering. Its fixes are cell-derived and
    /// routinely 1–3 km, so a flat ceiling would freeze the child's map at wherever they were when
    /// the process died.
    func testCoarseFixIsAcceptedWhenTheLastOneIsStale() {
        XCTAssertTrue(
            OilaTelemetryService.acceptsFix(accuracy: 2500, distanceFromLast: 4000, lastAcceptedAge: 3600),
            "an hour-old pin is worse than a coarse new one"
        )
        XCTAssertFalse(
            OilaTelemetryService.acceptsFix(accuracy: 2500, distanceFromLast: 4000, lastAcceptedAge: 60),
            "…but while a recent fix exists the ceiling still applies"
        )
    }

    /// The shape the parent actually complained about: a hub with straight spokes radiating out of
    /// it, drawn over an afternoon the child spent in one building. Every spoke is a cell-tower fix
    /// whose apparent movement is smaller than its own uncertainty — the child never went anywhere,
    /// and the map said they crossed the district and came back a dozen times.
    func testCoarseFixThatMovedLessThanItsOwnUncertaintyIsRefused() {
        XCTAssertFalse(
            OilaTelemetryService.acceptsFix(accuracy: 2500, distanceFromLast: 1200, lastAcceptedAge: 3600),
            "1.2 km of 'movement' on a 2.5 km-accurate fix is the tower moving, not the child"
        )
        XCTAssertTrue(
            OilaTelemetryService.acceptsFix(accuracy: 2500, distanceFromLast: 40_000, lastAcceptedAge: 3600),
            "…while a trip to another city clears any tower's uncertainty and must still be reported"
        )
    }

    /// A stale pin that gets a SHARP answer is refreshed whatever the displacement. This is the
    /// stationary child whose phone was asleep for an hour: nothing moved, but the parent should see
    /// a recent timestamp rather than a position quietly aging into "offline".
    func testSharpFixRefreshesAStalePinWithoutMoving() {
        XCTAssertTrue(OilaTelemetryService.acceptsFix(accuracy: 20, distanceFromLast: 0, lastAcceptedAge: 3600))
        XCTAssertFalse(
            OilaTelemetryService.acceptsFix(accuracy: 20, distanceFromLast: 0, lastAcceptedAge: 60),
            "inside the stale window the displacement rule still applies"
        )
    }

    /// Past 5 km a fix is not a position, it is a province. Nothing is uploaded and the parent gets
    /// an honest gap — which the route page can draw as a gap — instead of a confident wrong vertex.
    func testAFixVaguerThanFiveKilometresIsNeverAccepted() {
        XCTAssertFalse(OilaTelemetryService.acceptsFix(accuracy: 5001, distanceFromLast: nil))
        XCTAssertFalse(
            OilaTelemetryService.acceptsFix(accuracy: 5001, distanceFromLast: 50_000, lastAcceptedAge: 3600)
        )
        XCTAssertTrue(OilaTelemetryService.acceptsFix(accuracy: 5000, distanceFromLast: nil))
    }

    func testUnknownAccuracyIsRefused() {
        // CoreLocation reports a negative horizontalAccuracy when it has no confidence at all; the
        // caller maps that to nil. That is not a location.
        XCTAssertFalse(OilaTelemetryService.acceptsFix(accuracy: nil, distanceFromLast: nil))
        XCTAssertFalse(OilaTelemetryService.acceptsFix(accuracy: -1, distanceFromLast: 500, lastAcceptedAge: 30))
    }

    func testCellTowerGradeFixIsRefused() {
        // ~1 km accuracy is the shape of a cell-only fix: it would move the child across town.
        XCTAssertFalse(OilaTelemetryService.acceptsFix(accuracy: 1000, distanceFromLast: 5000, lastAcceptedAge: 30))
        XCTAssertFalse(OilaTelemetryService.acceptsFix(accuracy: 101, distanceFromLast: 5000, lastAcceptedAge: 30))
        XCTAssertTrue(OilaTelemetryService.acceptsFix(accuracy: 100, distanceFromLast: 5000, lastAcceptedAge: 30))
    }

    func testStationaryDriftIsRefused() {
        // 10 m of movement on a 12 m-accurate fix is noise, not a walk: the floor is
        // max(15, 1.5 * 12) = 18.
        XCTAssertFalse(OilaTelemetryService.acceptsFix(accuracy: 12, distanceFromLast: 10, lastAcceptedAge: 30))
        XCTAssertTrue(OilaTelemetryService.acceptsFix(accuracy: 12, distanceFromLast: 25, lastAcceptedAge: 30))
    }

    /// Ibrohim's rule, pinned: a sharp fix that has moved MORE than the 15 m floor is packaged;
    /// a smaller move is held. Matches the Android child app's displacement gate.
    func testSharpFixSendsPastFifteenMetres() {
        // accuracy 8 → floor is max(15, 1.5 * 8 = 12) = 15.
        XCTAssertFalse(OilaTelemetryService.acceptsFix(accuracy: 8, distanceFromLast: 14, lastAcceptedAge: 30))
        XCTAssertTrue(OilaTelemetryService.acceptsFix(accuracy: 8, distanceFromLast: 15, lastAcceptedAge: 30))
    }

    /// The rule that makes the gate scale with confidence: a vaguer fix has to move further before
    /// it is believed. This is Android's ACCURACY_FACTOR, and it is why the threshold is a max().
    func testVaguerFixMustTravelFurther() {
        // 1.5 * 60 = 90 m required, so 50 m of apparent movement is not enough.
        XCTAssertFalse(OilaTelemetryService.acceptsFix(accuracy: 60, distanceFromLast: 50, lastAcceptedAge: 30))
        XCTAssertTrue(OilaTelemetryService.acceptsFix(accuracy: 60, distanceFromLast: 90, lastAcceptedAge: 30))
        // …while a sharp fix only has to clear the 15 m floor.
        XCTAssertTrue(OilaTelemetryService.acceptsFix(accuracy: 5, distanceFromLast: 25, lastAcceptedAge: 30))
    }
}

// MARK: - Route shape inside the time floor

/// The three rules that let a fix through `minFixIntervalS`. Each is a distinct claim about the
/// fix — sharper, further, or turning — and each fails closed on the sentinel values CoreLocation
/// uses for "unknown".
final class RouteShapeTests: XCTestCase {
    // MARK: better fix

    func testASharperFixOfTheSamePlaceIsTaken() {
        XCTAssertTrue(OilaTelemetryService.isMateriallyBetterFix(accuracy: 10, previousAccuracy: 40))
    }

    func testAFixThatIsNotMateriallySharperIsNot() {
        // 20 m improvement is the floor; 19 is not enough.
        XCTAssertFalse(OilaTelemetryService.isMateriallyBetterFix(accuracy: 21, previousAccuracy: 40))
        XCTAssertTrue(OilaTelemetryService.isMateriallyBetterFix(accuracy: 20, previousAccuracy: 40))
    }

    func testBetterThanACoarseFixIsStillNotARouteVertex() {
        // The bug this closes: the stale branch admits a 2.5 km fix, and a 900 m one is "better" —
        // and used to skip the ceiling entirely on the strength of that.
        XCTAssertFalse(OilaTelemetryService.isMateriallyBetterFix(accuracy: 900, previousAccuracy: 2500))
        XCTAssertFalse(OilaTelemetryService.isMateriallyBetterFix(accuracy: 101, previousAccuracy: 2500))
        XCTAssertTrue(OilaTelemetryService.isMateriallyBetterFix(accuracy: 100, previousAccuracy: 2500))
    }

    func testUnknownAccuracyIsNeverBetter() {
        XCTAssertFalse(OilaTelemetryService.isMateriallyBetterFix(accuracy: nil, previousAccuracy: 2500))
        XCTAssertFalse(OilaTelemetryService.isMateriallyBetterFix(accuracy: -1, previousAccuracy: 2500))
    }

    // MARK: displacement ceiling

    func testSixtyMetresOfRoadEarnsAVertexInsideTheInterval() {
        XCTAssertTrue(OilaTelemetryService.exceedsDisplacementCeiling(elapsed: 5, distanceFromLast: 60))
        XCTAssertFalse(OilaTelemetryService.exceedsDisplacementCeiling(elapsed: 5, distanceFromLast: 59))
    }

    func testABufferedBurstIsNotASprint() {
        // 60 m in under the burst floor is a replayed buffer, not movement.
        XCTAssertFalse(OilaTelemetryService.exceedsDisplacementCeiling(elapsed: 1, distanceFromLast: 60))
        XCTAssertTrue(OilaTelemetryService.exceedsDisplacementCeiling(elapsed: 2, distanceFromLast: 60))
    }

    func testNoReferenceMeansNoCeiling() {
        XCTAssertFalse(OilaTelemetryService.exceedsDisplacementCeiling(elapsed: 5, distanceFromLast: nil))
    }

    func testTheCeilingOnlyBindsAboveWalkingPace() {
        // 60 m / 30 s = 2 m/s. A child walking at 1.4 m/s covers 42 m in the whole window, so the
        // ceiling never fires for them and the time floor governs exactly as before.
        let walkingDistanceInWindow = 1.4 * 30
        XCTAssertFalse(OilaTelemetryService.exceedsDisplacementCeiling(elapsed: 29, distanceFromLast: walkingDistanceInWindow))
    }

    // MARK: corners

    private func turn(
        from previous: Double? = 0,
        to course: Double,
        courseAccuracy: Double = 5,
        speed: Double = 10,
        speedAccuracy: Double = 1,
        accuracy: Double? = 10,
        distance: Double? = 20
    ) -> Bool {
        OilaTelemetryService.isSignificantHeadingChange(
            from: previous,
            to: course,
            courseAccuracy: courseAccuracy,
            speed: speed,
            speedAccuracy: speedAccuracy,
            accuracy: accuracy,
            distanceFromLast: distance
        )
    }

    func testANinetyDegreeTurnAtCitySpeedIsACorner() {
        XCTAssertTrue(turn(from: 0, to: 90))
        XCTAssertTrue(turn(from: 90, to: 180))
    }

    func testALaneDriftIsNotACorner() {
        XCTAssertFalse(turn(from: 0, to: 20))
        XCTAssertTrue(turn(from: 0, to: 25))
    }

    func testHeadingWrapsAroundNorth() {
        // 359° → 5° is a 6° drift, not a 354° spin.
        XCTAssertFalse(turn(from: 359, to: 5))
        // 270° → 0° is a real 90° right turn.
        XCTAssertTrue(turn(from: 270, to: 0))
        // …and 10° → 350° is 20° of drift the other way.
        XCTAssertFalse(turn(from: 10, to: 350))
    }

    func testNoHeadingIsNotATurn() {
        XCTAssertFalse(turn(from: nil, to: 90))
        XCTAssertFalse(turn(from: -1, to: 90))
        XCTAssertFalse(turn(from: 0, to: -1))
    }

    func testAPedestrianCannotTurn() {
        // 2 m/s is a brisk walk. Course at walking pace is noise.
        XCTAssertFalse(turn(from: 0, to: 90, speed: 2))
        XCTAssertFalse(turn(from: 0, to: 90, speed: 3.9))
        XCTAssertTrue(turn(from: 0, to: 90, speed: 4))
    }

    func testAnUncertainHeadingIsNotATurn() {
        XCTAssertFalse(turn(from: 0, to: 90, courseAccuracy: 45))
        XCTAssertFalse(turn(from: 0, to: 90, courseAccuracy: -1))
        XCTAssertTrue(turn(from: 0, to: 90, courseAccuracy: 10))
    }

    func testAnUncertainSpeedIsNotATurn() {
        XCTAssertFalse(turn(from: 0, to: 90, speedAccuracy: -1))
    }

    func testAVagueFixCannotPlaceACorner() {
        XCTAssertFalse(turn(from: 0, to: 90, accuracy: 31))
        XCTAssertFalse(turn(from: 0, to: 90, accuracy: nil))
        XCTAssertTrue(turn(from: 0, to: 90, accuracy: 30))
    }

    func testACornerStillHasToClearTheFloor() {
        // The 15 m floor is inside the rule; the accuracy-scaled floor is waived by the caller.
        XCTAssertFalse(turn(from: 0, to: 90, distance: 14))
        XCTAssertTrue(turn(from: 0, to: 90, distance: 15))
        XCTAssertFalse(turn(from: 0, to: 90, distance: nil))
    }
}

// MARK: - Visits

/// `CLVisit` arrivals go into the queue on their own terms: the interval and displacement rules
/// are meaningless for a dwell centroid, so only the accuracy ceiling, a sanity bound on the
/// arrival time, and dedup against the previous report apply.
final class VisitAcceptanceTests: XCTestCase {
    private let tashkentCity = CLLocationCoordinate2D(latitude: 41.3111, longitude: 69.2797)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func accepts(
        accuracy: Double = 40,
        coordinate: CLLocationCoordinate2D? = nil,
        arrivedAgo: TimeInterval = 300,
        lastReported: OilaReportedVisit? = nil
    ) -> Bool {
        OilaTelemetryService.acceptsVisit(
            accuracy: accuracy,
            coordinate: coordinate ?? tashkentCity,
            arrivedAt: now.addingTimeInterval(-arrivedAgo),
            lastReported: lastReported,
            now: now
        )
    }

    private func reported(metresAway: Double = 0, arrivedAgo: TimeInterval) -> OilaReportedVisit {
        // ~1 m of latitude is 1/111_000 degrees.
        OilaReportedVisit(
            lat: tashkentCity.latitude + metresAway / 111_000,
            lng: tashkentCity.longitude,
            at: now.addingTimeInterval(-arrivedAgo)
        )
    }

    func testTheFirstVisitIsQueued() {
        XCTAssertTrue(accepts())
    }

    func testACoarseVisitIsRefused() {
        // A Wi-Fi-derived 800 m visit is the same spiderweb vertex as any other coarse fix.
        XCTAssertFalse(accepts(accuracy: 101))
        XCTAssertFalse(accepts(accuracy: 800))
        XCTAssertTrue(accepts(accuracy: 100))
        XCTAssertFalse(accepts(accuracy: -1))
    }

    func testTheSecondReportOfTheSameStopIsOneStop() {
        // CoreLocation reports a visit as it begins and again as it ends, same place, same arrival.
        XCTAssertFalse(accepts(arrivedAgo: 300, lastReported: reported(arrivedAgo: 300)))
        XCTAssertFalse(accepts(arrivedAgo: 300, lastReported: reported(metresAway: 24, arrivedAgo: 330)))
    }

    func testReturningToTheSamePlaceLaterIsANewStop() {
        XCTAssertTrue(accepts(arrivedAgo: 300, lastReported: reported(arrivedAgo: 1500)))
    }

    func testANearbyPlaceIsANewStop() {
        XCTAssertTrue(accepts(arrivedAgo: 300, lastReported: reported(metresAway: 30, arrivedAgo: 300)))
    }

    func testAnUnknownArrivalTimeIsRefused() {
        // `arrivalDate` is `distantPast` when CoreLocation has no value for it.
        XCTAssertFalse(OilaTelemetryService.acceptsVisit(
            accuracy: 40, coordinate: tashkentCity, arrivedAt: .distantPast, lastReported: nil, now: now
        ))
    }

    func testAStaleVisitIsNotNews() {
        XCTAssertFalse(accepts(arrivedAgo: 7 * 3600))
        XCTAssertTrue(accepts(arrivedAgo: 5 * 3600))
    }

    func testAnArrivalInTheFutureIsRefused() {
        XCTAssertFalse(accepts(arrivedAgo: -120))
        XCTAssertTrue(accepts(arrivedAgo: -30))
    }

    func testAnInvalidCoordinateIsRefused() {
        XCTAssertFalse(accepts(coordinate: kCLLocationCoordinate2DInvalid))
    }
}

// MARK: - status.report probe location

/// The probe deliberately does NOT run through the acceptance gate above: a parent who tapped
/// "check in now" has already paid for the answer, so "you have not moved 15 m" is no reason to
/// withhold it. What still applies is freshness — sending a point the server already holds adds a
/// phantom duplicate to the child's history and tells the parent nothing.
final class StatusProbeLocationTests: XCTestCase {
    private func location(at timestamp: Date, accuracy: CLLocationAccuracy = 12) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 41.31, longitude: 69.24),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            timestamp: timestamp
        )
    }

    /// The whole point of the change: an unreported fix rides along with the probe answer.
    func testAnUnreportedFixIsSentWithTheProbe() throws {
        let now = Date()
        let fix = try XCTUnwrap(
            OilaTelemetryService.probeFix(from: location(at: now), newerThan: now.addingTimeInterval(-60))
        )
        XCTAssertEqual(fix.lat, 41.31)
        XCTAssertEqual(fix.lng, 69.24)
        XCTAssertEqual(fix.accuracy, 12)
        XCTAssertEqual(fix.ts, now)
    }

    /// Nothing has ever been reported, so anything CoreLocation is holding is news.
    func testTheFirstProbeSendsWhateverIsHeld() throws {
        let fix = try XCTUnwrap(OilaTelemetryService.probeFix(from: location(at: Date()), newerThan: nil))
        XCTAssertEqual(fix.lat, 41.31)
    }

    /// A stationary child: the newest fix is the one already uploaded, and re-sending it would put a
    /// second identical point in the parent's history for no information at all.
    func testAFixTheServerAlreadyHasIsNotResent() {
        let reportedAt = Date()
        XCTAssertNil(OilaTelemetryService.probeFix(from: location(at: reportedAt), newerThan: reportedAt))
        XCTAssertNil(
            OilaTelemetryService.probeFix(from: location(at: reportedAt.addingTimeInterval(-30)), newerThan: reportedAt),
            "an older buffered fix is not a fresher answer"
        )
    }

    /// Location denied, or nothing resolved yet. The probe still answers — with status only — rather
    /// than blocking on a fix that may never arrive.
    func testNoHeldFixQueuesNothing() {
        XCTAssertNil(OilaTelemetryService.probeFix(from: nil, newerThan: nil))
    }

    /// A negative `horizontalAccuracy` condemns the COORDINATE, not just the accuracy figure —
    /// `CLLocationEssentials.h` calls it "negative if the lateral location is invalid". The probe
    /// used to null the accuracy and upload the coordinate anyway, and the backend takes it
    /// (`accuracy` is not required by `LocationPointDto`), so a parent tapping "check in now" could
    /// be handed a meaningless pin as the answer to exactly the question they asked. Answer with
    /// status alone instead; `sosUsableLocation` has always worked this way.
    func testAnInvalidCoordinateIsNotSentAtAll() {
        XCTAssertNil(OilaTelemetryService.probeFix(from: location(at: Date(), accuracy: -1), newerThan: nil))
    }
}

// MARK: - Chat system notice copy

/// The child's chat screen must never render the BACKEND's own wording. `systemKind` is an open
/// string in the live spec, so an unrecognized kind has to fall back to localized copy rather than
/// echoing whatever text arrived with it.
final class ChatSystemNoticeTextTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.setLanguage(AppLanguage.en.rawValue)
    }

    override func tearDown() {
        L10n.setLanguage(AppLanguage.defaultForDevice.rawValue)
        super.tearDown()
    }

    func testSosKindIsLocalized() {
        XCTAssertEqual(ChatSystemNoticeText.localized(forKind: "sos"), L10n.tr("chat2.system.sos"))
        // The backend's casing/padding must not decide whether a child sees the SOS copy.
        XCTAssertEqual(ChatSystemNoticeText.localized(forKind: " SOS "), L10n.tr("chat2.system.sos"))
    }

    func testUnknownAndAbsentKindsFallBackToLocalizedGeneric() {
        let generic = L10n.tr("chat2.system.generic")
        XCTAssertEqual(ChatSystemNoticeText.localized(forKind: "device_unpaired"), generic)
        XCTAssertEqual(ChatSystemNoticeText.localized(forKind: nil), generic)
        XCTAssertEqual(ChatSystemNoticeText.localized(forKind: "   "), generic)
    }

    /// The regression this closes: a kind the app does not know used to render the server's raw
    /// English `text` verbatim.
    func testCopyNeverEchoesBackendText() {
        let serverText = "Device was unpaired by parent (code 409)"
        XCTAssertNotEqual(ChatSystemNoticeText.localized(forKind: "unpaired"), serverText)
    }
}

// MARK: - Link health (the chip that used to always say "Connected")

/// Home and Settings both drew a hardcoded green "Connected" pill bound to no state whatsoever. On a
/// monitoring app that is the worst possible failure: the one surface that tells a family the phone is
/// being watched said yes unconditionally — with location revoked, with the device silent for days, and
/// with the Keychain credential gone after a restore-from-backup.
final class LinkHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testProtectingRequiresCredentialRecentContactAndEveryPermission() {
        XCTAssertEqual(
            LinkHealth.decide(hasCredential: true, offPermissions: 0,
                              lastContactAt: now.addingTimeInterval(-60), now: now),
            .protecting
        )
    }

    func testMissingCredentialOutranksEverythingElse() {
        // The restore-from-backup state: UserDefaults say "paired", the Keychain says nothing. Before
        // this, the chip stayed green for the life of the install.
        XCTAssertEqual(
            LinkHealth.decide(hasCredential: false, offPermissions: 0,
                              lastContactAt: now, now: now),
            .noCredential
        )
    }

    func testNeverHavingReachedTheServerIsNotHealthy() {
        XCTAssertEqual(
            LinkHealth.decide(hasCredential: true, offPermissions: 0, lastContactAt: nil, now: now),
            .outOfContact(since: nil)
        )
    }

    func testSilenceBeyondTheBackendOfflineThresholdReadsAsOutOfContact() {
        let last = now.addingTimeInterval(-(LinkHealth.contactStaleAfter + 1))
        XCTAssertEqual(
            LinkHealth.decide(hasCredential: true, offPermissions: 0, lastContactAt: last, now: now),
            .outOfContact(since: last)
        )
    }

    func testContactExactlyAtTheThresholdStillCounts() {
        let last = now.addingTimeInterval(-LinkHealth.contactStaleAfter)
        XCTAssertEqual(
            LinkHealth.decide(hasCredential: true, offPermissions: 0, lastContactAt: last, now: now),
            .protecting
        )
    }

    func testRevokedPermissionsDegradeAReachableDevice() {
        XCTAssertEqual(
            LinkHealth.decide(hasCredential: true, offPermissions: 2,
                              lastContactAt: now.addingTimeInterval(-60), now: now),
            .degraded(offPermissions: 2)
        )
    }

    func testOutOfContactOutranksOffPermissions() {
        // A phone that cannot reach the server has a worse problem than a permission toggle, and the
        // chip has room for one message.
        let last = now.addingTimeInterval(-(LinkHealth.contactStaleAfter + 1))
        XCTAssertEqual(
            LinkHealth.decide(hasCredential: true, offPermissions: 3, lastContactAt: last, now: now),
            .outOfContact(since: last)
        )
    }

    func testAClockMovedBackwardsDoesNotTurnTheChipRed() {
        // A child who sets the date forward, checks in, then sets it back would otherwise produce a
        // future timestamp and a permanently alarming chip. Staleness is not this app's tamper signal.
        XCTAssertEqual(
            LinkHealth.decide(hasCredential: true, offPermissions: 0,
                              lastContactAt: now.addingTimeInterval(3_600), now: now),
            .protecting
        )
    }

    func testOnlyProtectingIsHealthy() {
        XCTAssertTrue(LinkHealth.protecting.isHealthy)
        XCTAssertFalse(LinkHealth.degraded(offPermissions: 1).isHealthy)
        XCTAssertFalse(LinkHealth.outOfContact(since: nil).isHealthy)
        XCTAssertFalse(LinkHealth.noCredential.isHealthy)
    }

    func testEveryStateResolvesToLocalizedCopyAndNeverARawKey() {
        for state in [LinkHealth.protecting, .degraded(offPermissions: 2),
                      .outOfContact(since: nil), .noCredential] {
            let text = state.displayText
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("home2."), "raw key leaked to the UI: \(text)")
            XCTAssertFalse(text.contains("settings2."), "raw key leaked to the UI: \(text)")
        }
    }
}

// MARK: - Credential absence is conclusive

/// `readValue` used to collapse "the Keychain says this item does not exist" and "the Keychain cannot
/// be read right now" into one nil, and `requiresRePair` excluded the pair of them. That exclusion is
/// correct for a device locked before first unlock; applied to a provably empty slot it produced a
/// device that stayed "paired" forever and never sent another request.
final class CredentialAbsenceTests: XCTestCase {
    private func error(_ code: String) -> OilaAPIError {
        OilaAPIError(statusCode: 401, message: "m", errorCode: code, fieldErrors: [])
    }

    func testAConclusivelyAbsentCredentialForcesRePairing() {
        XCTAssertTrue(error(OilaAPIError.credentialAbsentCode).requiresRePair)
        XCTAssertTrue(error(OilaAPIError.credentialAbsentCode).isCredentialAbsent)
    }

    func testAnUnreadableKeychainStillDoesNotDestroyThePairing() {
        // The regression this exclusion exists to prevent: a locked device answering
        // errSecInteractionNotAllowed must never be read as "the parent unpaired me".
        XCTAssertFalse(error(OilaAPIError.noCredentialCode).requiresRePair)
        XCTAssertFalse(error(OilaAPIError.noCredentialCode).isCredentialAbsent)
    }

    func testARefusedTokenIsNotAGonePairing() {
        // Flipped in build 26. The live contract: UNAUTHORIZED is "a missing, malformed, expired or
        // foreign-signed token", and "only DEVICE_UNPAIRED means the pairing is gone". Treating it
        // as a re-pair let a backend auth blip wipe every child's pairing.
        XCTAssertFalse(error("UNAUTHORIZED").requiresRePair)
        XCTAssertFalse(error("UNAUTHORIZED").isCredentialAbsent)
        XCTAssertTrue(error("UNAUTHORIZED").isCredentialRejected)
    }

    func testDeviceUnpairedIsTheServersWordThatThePairingIsGone() {
        XCTAssertEqual(OilaAPIError.deviceUnpairedCode, "DEVICE_UNPAIRED")
        XCTAssertTrue(error(OilaAPIError.deviceUnpairedCode).requiresRePair)
        XCTAssertFalse(error(OilaAPIError.deviceUnpairedCode).isCredentialRejected)
    }

    func testABare401WithNoErrorCodeIsNotAGonePairing() {
        // A proxy or gateway 401 carries no errorCode at all. It used to match `statusCode == 401`.
        let bare = OilaAPIError(statusCode: 401, message: "m", errorCode: nil, fieldErrors: [])
        XCTAssertFalse(bare.requiresRePair)
        XCTAssertTrue(bare.isCredentialRejected)
    }

    func testTheLegacyRefreshRefusalStillForcesRePairing() {
        XCTAssertTrue(error("REFRESH_INVALID").requiresRePair)
    }

    func testAnUnreadableKeychainIsNeitherAGonePairingNorARefusedToken() {
        // NO_LOCAL_CREDENTIAL never reached a server, so it is not a server's refusal either.
        XCTAssertFalse(error(OilaAPIError.noCredentialCode).isCredentialRejected)
        XCTAssertFalse(error(OilaAPIError.credentialAbsentCode).isCredentialRejected)
    }

    func testOnlyAConclusiveProbeAnswerEndsThePairingAfterOneProbe() {
        // DEVICE_UNPAIRED and CREDENTIAL_ABSENT cannot change by asking again; the legacy refresh
        // refusal still needs the second agreeing probe.
        XCTAssertTrue(OilaTelemetryService.probeAnswerIsConclusive(error(OilaAPIError.deviceUnpairedCode)))
        XCTAssertTrue(OilaTelemetryService.probeAnswerIsConclusive(error(OilaAPIError.credentialAbsentCode)))
        XCTAssertFalse(OilaTelemetryService.probeAnswerIsConclusive(error("REFRESH_INVALID")))
    }
}

// MARK: - Which answers may end a pairing, end to end

/// `OilaTelemetryService` is the only code allowed to end a pairing, and until build 26 it did so for
/// ANY 401 after two probes — a refused token (UNAUTHORIZED), a gateway 401 with no code, and the
/// server's real DEVICE_UNPAIRED alike. These drive the real service through its `sleeper` and
/// `sessionInvalidationSignal` seams, so no real time passes and the host app's session is never
/// touched.
@MainActor
final class TelemetryPairingLossTests: XCTestCase {
    /// Thread-safe tally: the seams and the stub are called off the main actor.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// Every call the telemetry service makes, answered from fixed scripts.
    private final class Stub: OilaDeviceServicing, @unchecked Sendable {
        struct Unimplemented: Error {}
        private let lock = NSLock()
        /// Answers to `GET /device/lock/state`, in order; the last one repeats. Always a failure — the
        /// tests never need a lock state, only the answer that decides the pairing.
        private var lockAnswers: [Error]
        private let statusError: Error?
        private let locationError: Error?
        private var lockCalls = 0
        private var statusCalls = 0
        private var batches: [[OilaLocationFix]] = []
        private var sos: [OilaSOSContext] = []

        init(lockAnswers: [Error], statusError: Error? = nil, locationError: Error? = nil) {
            self.lockAnswers = lockAnswers
            self.statusError = statusError
            self.locationError = locationError
        }

        private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
        var lockStateCalls: Int { locked { lockCalls } }
        var statusPostCalls: Int { locked { statusCalls } }
        var uploadedBatches: [[OilaLocationFix]] { locked { batches } }
        var sentSOS: [OilaSOSContext] { locked { sos } }

        func fetchLockState() async throws -> OilaLockState {
            let answer: Error = locked { () -> Error in
                lockCalls += 1
                return lockAnswers.count > 1 ? lockAnswers.removeFirst() : lockAnswers[0]
            }
            throw answer
        }
        func postDeviceStatus(_ status: OilaDeviceStatus) async throws {
            locked { statusCalls += 1 }
            if let statusError { throw statusError }
        }
        func uploadLocationBatch(_ fixes: [OilaLocationFix]) async throws {
            locked { batches.append(fixes) }
            if let locationError { throw locationError }
        }
        func sendSOS(lat: Double?, lng: Double?, accuracy: Double?, batteryLevel: Double?) async throws {
            locked {
                sos.append(OilaSOSContext(lat: lat, lng: lng, accuracy: accuracy,
                                          batteryPercent: batteryLevel.map { Int($0) }))
            }
        }
        func pair(code: String) async throws -> OilaPairResult { throw Unimplemented() }
        func refreshSession() async throws { throw Unimplemented() }
        func logout() async throws {}
        func fetchActiveTasks() async throws -> [OilaDeviceTask] { [] }
        func fetchTasks() async throws -> [OilaDeviceTask] { [] }
        func completeTask(id: String) async throws {}
        func fetchTaskStarTotal() async throws -> Int? { nil }
        func updateFCMToken(_ token: String) async throws {}
        func reportAppUsage(items: [DeviceApplicationUsageReportItemRequest]) async throws -> DeviceApplicationUsageReportResponse { throw Unimplemented() }
        func reportDailyUsage(days: [ScreenTimeUsageReportDay]) async throws -> DeviceApplicationUsageReportResponse { throw Unimplemented() }
        func syncInstalledApps(items: [DeviceAppLockSyncEntry]) async throws {}
        func fetchScreenTime() async throws -> OilaDeviceScreenTime? { nil }
        func reportRemovalAttempt(packageName: String, applicationName: String) async throws {}
        func fetchHome() async throws -> OilaDeviceHome? { nil }
    }

    private static let pendingFixesKey = "OILA_PENDING_LOCATION_FIXES"
    private static let persistedKeys = [
        pendingFixesKey, "OILA_PENDING_SOS", "OILA_LAST_LOCK_STATE", "OILA_LAST_SUCCESSFUL_CONTACT",
        OilaTelemetryService.lockConfirmedAtKey, OilaTelemetryService.lockEndsAtKey,
        OilaTelemetryService.lockReleasedByDeadlineKey
    ]

    override func setUp() {
        super.setUp()
        for key in Self.persistedKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in Self.persistedKeys { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    private func apiError(_ status: Int, _ code: String?) -> OilaAPIError {
        OilaAPIError(statusCode: status, message: "m", errorCode: code, fieldErrors: [])
    }

    /// A running service whose probes cost no time and whose teardown signal is only counted.
    private func start(_ stub: Stub) -> (service: OilaTelemetryService, probes: Tally, invalidations: Tally) {
        let service = OilaTelemetryService(service: stub)
        let probes = Tally()
        let invalidations = Tally()
        service.sleeper = { _ in probes.bump() }
        service.sessionInvalidationSignal = { invalidations.bump() }
        service.start()
        return (service, probes, invalidations)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func persistedFixes() -> [OilaLocationFix] {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingFixesKey) else { return [] }
        return (try? JSONDecoder().decode([OilaLocationFix].self, from: data)) ?? []
    }

    // MARK: 401s

    func testARefusedTokenNeverEndsThePairing() async {
        for code in ["UNAUTHORIZED", nil] as [String?] {
            let refused = apiError(401, code)
            let stub = Stub(lockAnswers: [refused], statusError: refused, locationError: refused)
            let (service, probes, invalidations) = start(stub)
            defer { service.stop() }

            let answered = await waitUntil { stub.lockStateCalls >= 1 && stub.statusPostCalls >= 1 }
            XCTAssertTrue(answered, "the launch poll and status post both went out (code: \(code ?? "none"))")
            // The sleeper returns at once, so a confirmation that had (wrongly) started would long
            // since have finished.
            try? await Task.sleep(nanoseconds: 300_000_000)

            XCTAssertEqual(invalidations.value, 0, "a refused token is not a gone pairing (code: \(code ?? "none"))")
            XCTAssertEqual(probes.value, 0, "it must not even start the confirmation (code: \(code ?? "none"))")
            XCTAssertEqual(stub.lockStateCalls, 1, "no probe was sent (code: \(code ?? "none"))")
            XCTAssertTrue(service.isRunning)
        }
    }

    func testDeviceUnpairedEndsThePairingAfterOneProbe() async {
        let stub = Stub(lockAnswers: [apiError(401, OilaAPIError.deviceUnpairedCode)])
        let (service, probes, invalidations) = start(stub)
        defer { service.stop() }

        let ended = await waitUntil { invalidations.value == 1 }

        XCTAssertTrue(ended, "DEVICE_UNPAIRED, confirmed, ends the pairing")
        XCTAssertEqual(probes.value, 1, "conclusive: ONE probe, not the two a refresh refusal needs")
        XCTAssertEqual(stub.lockStateCalls, 2, "the poll that heard it, then the one probe")
        XCTAssertFalse(service.isRunning, "the pairing's telemetry stops with it")
    }

    func testAProbeAnsweringWithARefusedTokenKeepsThePairing() async {
        // The poll heard DEVICE_UNPAIRED, the probe heard UNAUTHORIZED: not a confirmation.
        let stub = Stub(lockAnswers: [apiError(401, OilaAPIError.deviceUnpairedCode), apiError(401, "UNAUTHORIZED")])
        let (service, probes, invalidations) = start(stub)
        defer { service.stop() }

        let probed = await waitUntil { stub.lockStateCalls >= 2 }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(probed)
        XCTAssertEqual(probes.value, 1)
        XCTAssertEqual(invalidations.value, 0)
        XCTAssertTrue(service.isRunning)
    }

    // MARK: Location batches

    private let seeded = [
        OilaLocationFix(lat: 41.3111, lng: 69.2406, accuracy: 12, ts: Date(timeIntervalSince1970: 1_800_000_000)),
        OilaLocationFix(lat: 41.3120, lng: 69.2419, accuracy: 9, ts: Date(timeIntervalSince1970: 1_800_000_060))
    ]

    private func seedPendingFixes() throws {
        UserDefaults.standard.set(try JSONEncoder().encode(seeded), forKey: Self.pendingFixesKey)
    }

    private func batchesCarryingSeeded(_ stub: Stub) -> Int {
        let seededTimes = Set(seeded.map(\.ts))
        return stub.uploadedBatches.filter { batch in batch.contains { seededTimes.contains($0.ts) } }.count
    }

    func testABatchTheServerRejectsForGoodIsDroppedNotRequeued() async throws {
        try seedPendingFixes()
        let stub = Stub(lockAnswers: [URLError(.notConnectedToInternet)],
                        locationError: apiError(400, "VALIDATION_FAILED"))
        let (service, _, _) = start(stub)
        defer { service.stop() }
        service.flushNow()

        let sent = await waitUntil { self.batchesCarryingSeeded(stub) >= 1 }
        let dropped = await waitUntil {
            !self.persistedFixes().contains { fix in self.seeded.contains { $0.ts == fix.ts } }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(sent)
        XCTAssertTrue(dropped, "\"the whole batch is rejected\": resending the same body cannot succeed")
        XCTAssertEqual(batchesCarryingSeeded(stub), 1, "and it is never sent again")
    }

    func testARefusedTokenKeepsTheQueuedRoute() async throws {
        try seedPendingFixes()
        let stub = Stub(lockAnswers: [URLError(.notConnectedToInternet)],
                        locationError: apiError(401, "UNAUTHORIZED"))
        let (service, _, _) = start(stub)
        defer { service.stop() }
        service.flushNow()

        let sent = await waitUntil { self.batchesCarryingSeeded(stub) >= 1 }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(sent)
        let kept = Set(persistedFixes().map(\.ts))
        XCTAssertTrue(Set(seeded.map(\.ts)).isSubset(of: kept), "a 401 keeps the child's route queued")
    }

    func testOnlyAValidationRejectionIsPermanent() {
        XCTAssertTrue(OilaTelemetryService.locationBatchIsPermanentlyRejected(apiError(400, "VALIDATION_FAILED")))
        XCTAssertTrue(OilaTelemetryService.locationBatchIsPermanentlyRejected(apiError(422, nil)))
        for status in [401, 403, 404, 408, 409, 425, 429, 500, 502, 503] {
            XCTAssertFalse(OilaTelemetryService.locationBatchIsPermanentlyRejected(apiError(status, nil)), "\(status)")
        }
        XCTAssertFalse(OilaTelemetryService.locationBatchIsPermanentlyRejected(URLError(.notConnectedToInternet)))
    }

    // MARK: SOS outbox

    func testAQueuedSOSWhosePositionHasGoneStaleIsSentWithoutIt() async {
        let stub = Stub(lockAnswers: [URLError(.notConnectedToInternet)])
        let (service, _, _) = start(stub)
        defer { service.stop() }

        service.enqueueUndeliveredSOS(OilaSOSContext(
            lat: 41.31, lng: 69.24, accuracy: 8, batteryPercent: 40,
            locationAt: Date().addingTimeInterval(-(OilaTelemetryService.sosLocationMaxAge + 30))
        ))

        let sent = await waitUntil { !stub.sentSOS.isEmpty }
        XCTAssertTrue(sent, "the alert still goes out")
        let delivered = stub.sentSOS.first
        XCTAssertNil(delivered?.lat)
        XCTAssertNil(delivered?.lng)
        XCTAssertNil(delivered?.accuracy)
        XCTAssertEqual(delivered?.batteryPercent, 40, "with everything that is still true")
    }
}

// MARK: - What an SOS is allowed to claim about where the child is

/// `currentSOSContext()` shipped whatever `CLLocationManager.location` happened to be holding — no
/// age bound, and a negative `horizontalAccuracy` nulled only the accuracy while still sending the
/// coordinate. `TriggerSosDto` carries no timestamp, so the parent sees a pin with no way to judge
/// it. A pin in the wrong place is worse than no pin when someone is deciding where to drive.
final class SOSLocationFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fix(age: TimeInterval, accuracy: CLLocationAccuracy = 25) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 41.31, longitude: 69.24),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            timestamp: now.addingTimeInterval(-age)
        )
    }

    func testAFreshFixIsCarried() {
        XCTAssertNotNil(OilaTelemetryService.sosUsableLocation(fix(age: 10), now: now))
    }

    func testAStaleFixTravelsAsAbsentRatherThanAsAPosition() {
        let stale = fix(age: OilaTelemetryService.sosLocationMaxAge + 1)
        XCTAssertNil(OilaTelemetryService.sosUsableLocation(stale, now: now),
                     "a child indoors for an hour must not be reported where they used to be")
    }

    func testAFixAtTheAgeBoundIsStillCarried() {
        let edge = fix(age: OilaTelemetryService.sosLocationMaxAge)
        XCTAssertNotNil(OilaTelemetryService.sosUsableLocation(edge, now: now))
    }

    func testAnInvalidCoordinateIsDroppedEntirelyNotJustItsAccuracy() {
        // CoreLocation signals "this coordinate is meaningless" with a negative accuracy. The old
        // code nulled `accuracy` and sent the latitude and longitude anyway.
        XCTAssertNil(OilaTelemetryService.sosUsableLocation(fix(age: 5, accuracy: -1), now: now))
    }

    func testNoFixAtAllIsHandled() {
        XCTAssertNil(OilaTelemetryService.sosUsableLocation(nil, now: now))
    }

    // MARK: The same bound at replay

    /// The press-time bound only held at the press. The outbox replays the context for up to six
    /// hours, and with no timestamp on `TriggerSosDto` the parent reads the pin as "where they are now".
    private func queued(fixAge: TimeInterval?, battery: Int? = 55) -> OilaPendingSOS {
        OilaPendingSOS(
            context: OilaSOSContext(lat: 41.31, lng: 69.24, accuracy: 12, batteryPercent: battery,
                                    locationAt: fixAge.map { now.addingTimeInterval(-$0) }),
            queuedAt: now.addingTimeInterval(-(fixAge ?? 0))
        )
    }

    func testAReplayInsideTheBoundCarriesItsPosition() {
        let context = OilaTelemetryService.sosReplayContext(queued(fixAge: 30), now: now)
        XCTAssertEqual(context.lat, 41.31)
        XCTAssertEqual(context.lng, 69.24)
        XCTAssertEqual(context.accuracy, 12)
    }

    func testAReplayAtTheBoundStillCarriesItsPosition() {
        let context = OilaTelemetryService.sosReplayContext(
            queued(fixAge: OilaTelemetryService.sosLocationMaxAge), now: now)
        XCTAssertNotNil(context.lat)
    }

    func testAReplayPastTheBoundTravelsWithoutAPositionButKeepsTheBattery() {
        let context = OilaTelemetryService.sosReplayContext(
            queued(fixAge: OilaTelemetryService.sosLocationMaxAge + 1), now: now)
        XCTAssertNil(context.lat)
        XCTAssertNil(context.lng)
        XCTAssertNil(context.accuracy)
        XCTAssertNil(context.locationAt)
        XCTAssertEqual(context.batteryPercent, 55, "the alert itself, and what is still true, still go")
    }

    func testAnEntryQueuedByAnOlderBuildCannotProveItsFixIsFresh() {
        // Persisted before `locationAt` existed: the age is unknown, so the position is not sent.
        let legacy = OilaPendingSOS(
            context: OilaSOSContext(lat: 41.31, lng: 69.24, accuracy: 12, batteryPercent: 80),
            queuedAt: now
        )
        XCTAssertNil(OilaTelemetryService.sosReplayContext(legacy, now: now).lat)
    }

    func testAnOlderBuildsPersistedOutboxStillDecodes() throws {
        // The outbox is JSON in UserDefaults; a new stored property must not drop what is queued.
        let legacyJSON = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","context":{"lat":1,"lng":2,"accuracy":3,"batteryPercent":4},"queuedAt":0}]"#
        let decoded = try JSONDecoder().decode([OilaPendingSOS].self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.first?.context.lat, 1)
        XCTAssertNil(decoded.first?.context.locationAt)
    }

    func testAReplayWithNoPositionIsLeftAlone() {
        let none = OilaPendingSOS(context: OilaSOSContext(batteryPercent: 20), queuedAt: now)
        XCTAssertEqual(OilaTelemetryService.sosReplayContext(none, now: now), none.context)
    }

    func testAFixTimestampedInTheFutureIsAlsoRefused() {
        // A child who moved the clock backwards leaves the manager holding a future-dated fix; its
        // real age is unknowable, so it is not evidence of anything.
        let future = fix(age: -(OilaTelemetryService.sosLocationMaxAge + 60))
        XCTAssertNil(OilaTelemetryService.sosUsableLocation(future, now: now))
    }
}

// MARK: - The PIN lockout runs on a clock the child does not own

/// The escalating ladder (1min → 24h) is the only thing that makes a 4-digit disconnect PIN
/// expensive to guess, and it was enforced entirely against `Date()` — on a device belonging to the
/// person it defends against. Settings → General → Date & Time, wind the clock forward, and every
/// tier evaporated: 5 guesses, change the date, 5 more, for all 10,000 values.
final class PINLockoutClockTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let uptime: TimeInterval = 50_000

    /// A lockout begun `elapsed` seconds ago for `duration`, on this boot.
    private func anchors(duration: TimeInterval, elapsed: TimeInterval)
        -> (uptimeUntil: TimeInterval, bootAnchor: TimeInterval) {
        (uptime - elapsed + duration, now.timeIntervalSince1970 - uptime)
    }

    func testNoRecordedLockoutIsClear() {
        XCTAssertEqual(
            PINLockoutClock.resolve(uptimeUntil: nil, bootAnchor: nil, now: now, uptime: uptime),
            .clear
        )
    }

    func testARunningLockoutReportsItsMonotonicRemainder() {
        let a = anchors(duration: 300, elapsed: 100)
        XCTAssertEqual(
            PINLockoutClock.resolve(uptimeUntil: a.uptimeUntil, bootAnchor: a.bootAnchor,
                                    now: now, uptime: uptime),
            .locked(remaining: 200)
        )
    }

    func testAServedLockoutIsClear() {
        let a = anchors(duration: 300, elapsed: 301)
        XCTAssertEqual(
            PINLockoutClock.resolve(uptimeUntil: a.uptimeUntil, bootAnchor: a.bootAnchor,
                                    now: now, uptime: uptime),
            .clear
        )
    }

    /// THE ATTACK. The child winds the wall clock a day forward; `systemUptime` does not move, so the
    /// remaining time is unchanged. The old code read `Date()` and released the lockout instantly.
    func testWindingTheWallClockForwardDoesNotShortenTheLockout() {
        let a = anchors(duration: 3_600, elapsed: 60)
        let tomorrow = now.addingTimeInterval(86_400)
        let resolution = PINLockoutClock.resolve(uptimeUntil: a.uptimeUntil, bootAnchor: a.bootAnchor,
                                                 now: tomorrow, uptime: uptime)
        XCTAssertNotEqual(resolution, .clear, "a date change must never end a lockout")
        // The anchor no longer matches, so we cannot tell a clock change from a reboot: fail closed.
        XCTAssertEqual(resolution, .restart)
    }

    func testWindingTheWallClockBackwardAlsoFailsClosed() {
        let a = anchors(duration: 3_600, elapsed: 60)
        let resolution = PINLockoutClock.resolve(uptimeUntil: a.uptimeUntil, bootAnchor: a.bootAnchor,
                                                 now: now.addingTimeInterval(-86_400), uptime: uptime)
        XCTAssertEqual(resolution, .restart)
    }

    /// A reboot resets `systemUptime`, so the recorded deadline is meaningless. Indistinguishable
    /// from a clock change, and treated the same way: serve the tier again rather than trust it.
    func testARebootRestartsRatherThanReleases() {
        let a = anchors(duration: 3_600, elapsed: 60)
        let resolution = PINLockoutClock.resolve(uptimeUntil: a.uptimeUntil, bootAnchor: a.bootAnchor,
                                                 now: now, uptime: 12)
        XCTAssertEqual(resolution, .restart)
    }

    /// Normal drift between the two clocks, and sub-second NTP corrections, must not read as tampering
    /// — otherwise every device would restart its lockout constantly.
    func testSmallDriftIsToleratedAsTheSameBoot() {
        let a = anchors(duration: 300, elapsed: 100)
        let drifted = now.addingTimeInterval(PINLockoutClock.bootAnchorTolerance - 1)
        XCTAssertEqual(
            PINLockoutClock.resolve(uptimeUntil: a.uptimeUntil, bootAnchor: a.bootAnchor,
                                    now: drifted, uptime: uptime),
            .locked(remaining: 200)
        )
    }
}

// MARK: - A lock poll that stops shouting into the network

/// The 30 s lock poll never slowed down, so an unreachable device woke its radio twice a minute
/// forever — real battery and real prepaid data, spent on a request that cannot succeed.
final class LockPollBackoffTests: XCTestCase {
    private let base: TimeInterval = 30

    func testAHealthyPollIsNotDelayed() {
        XCTAssertEqual(OilaTelemetryService.lockPollBackoff(consecutiveFailures: 0, baseInterval: base), 0)
    }

    func testTheIntervalDoublesWithEachFailure() {
        XCTAssertEqual(OilaTelemetryService.lockPollBackoff(consecutiveFailures: 1, baseInterval: base), 60)
        XCTAssertEqual(OilaTelemetryService.lockPollBackoff(consecutiveFailures: 2, baseInterval: base), 120)
        XCTAssertEqual(OilaTelemetryService.lockPollBackoff(consecutiveFailures: 3, baseInterval: base), 240)
    }

    func testTheBackoffIsCappedSoALockNeverGoesUnnoticedForLong() {
        XCTAssertEqual(OilaTelemetryService.lockPollBackoff(consecutiveFailures: 50, baseInterval: base), 600)
    }
}

// MARK: - The old-backend lock resolver

/// `OilaLockState.isDeviceLocked` is only the fallback for an OLD backend's payload now (one with no
/// `manualLock`, `schedules` or `serverTime`; see `OilaTelemetryService.lockPolicySnapshot`), and its
/// contract is three-valued on purpose: nil means "unrecognized payload, KEEP the saved policy",
/// never "unlocked". It has already regressed once — deriving only true-or-nil from the reason flags
/// made it a one-way latch that could never release a lock.
final class DeviceLockResolutionTests: XCTestCase {
    private func state(isLocked: Bool? = nil,
                       manual: Bool? = nil,
                       schedule: Bool? = nil) -> OilaLockState {
        OilaLockState(isLocked: isLocked, raw: [:],
                      manualLockEnabled: manual, scheduleLocked: schedule)
    }

    func testThePrimaryFlagWinsWhenPresent() {
        XCTAssertEqual(state(isLocked: true).isDeviceLocked, true)
        XCTAssertEqual(state(isLocked: false).isDeviceLocked, false)
    }

    func testThePrimaryFlagBeatsDisagreeingReasonFlags() {
        XCTAssertEqual(state(isLocked: false, manual: true, schedule: true).isDeviceLocked, false)
        XCTAssertEqual(state(isLocked: true, manual: false, schedule: false).isDeviceLocked, true)
    }

    func testEitherReasonFlagLocksWhenThePrimaryIsAbsent() {
        XCTAssertEqual(state(manual: true).isDeviceLocked, true)
        XCTAssertEqual(state(schedule: true).isDeviceLocked, true)
        XCTAssertEqual(state(manual: false, schedule: true).isDeviceLocked, true)
    }

    /// The regression this resolver was rewritten for: a payload carrying only `scheduleLocked: false`
    /// must RELEASE the lock. Resolving it to nil made the lock impossible to lift through this path.
    func testAReasonFlagCanReportUnlockedAndNotOnlyLocked() {
        XCTAssertEqual(state(schedule: false).isDeviceLocked, false)
        XCTAssertEqual(state(manual: false).isDeviceLocked, false)
        XCTAssertEqual(state(manual: false, schedule: false).isDeviceLocked, false)
    }

    /// THE FAIL-CLOSED CASE. An unrecognized 200 must resolve to nil so the caller keeps the last
    /// known lock. Returning `false` here would let any backend shape change silently unlock every
    /// locked child in the fleet at once.
    func testAnUnrecognizedPayloadIsUnknownRatherThanUnlocked() {
        XCTAssertNil(state().isDeviceLocked,
                     "nil means keep the last-known lock; false would release it")
    }
}

// MARK: - The audio-subject guard, and the PIN ladder

/// `audioRoute` is the gate between a push and the child's microphone. The existing suite covers the
/// verbs thoroughly, but nothing covered the SUBJECT guard at `PushCommandRouter.swift:332` — delete
/// that one line and the whole suite still passes while any start-verb push, on any topic, opens the
/// mic. These are the tests that fail when it is removed.
final class PushAudioSubjectGuardTests: XCTestCase {
    func testAStartVerbWithNoAudioSubjectDoesNotOpenTheMicrophone() {
        for command in ["task.start", "chat.open", "session.begin", "download.resume",
                        "sync.wake", "app.boshla", "lock.start"] {
            XCTAssertNil(PushCommandRouter.audioRoute(forCommand: command),
                         "\(command) names no audio subject and must never reach the mic")
        }
    }

    func testAStopVerbWithNoAudioSubjectIsAlsoIgnored() {
        // Not merely symmetry: a spurious `.stop` is a denial-of-service on a legitimate session.
        for command in ["task.stop", "download.cancel", "sync.end"] {
            XCTAssertNil(PushCommandRouter.audioRoute(forCommand: command))
        }
    }

    func testTheSubjectStillRoutesWhenItIsPresent() {
        XCTAssertEqual(PushCommandRouter.audioRoute(forCommand: "stream.start"), .start)
        XCTAssertEqual(PushCommandRouter.audioRoute(forCommand: "stream.stop"), .stop)
    }

    /// Fails closed: an audio subject with no verb at all is not a start.
    func testAnAudioSubjectWithNoVerbIsNotAStartUnlessItIsAKnownBareEvent() {
        XCTAssertNil(PushCommandRouter.audioRoute(forCommand: "stream.something"))
        XCTAssertEqual(PushCommandRouter.audioRoute(forCommand: "stream"), .start)
    }
}

/// The escalating lockout is the only thing making a 4-digit PIN expensive, and neither the ladder
/// nor its reset had a test. Both have already regressed once: a flat penalty allowed ~288 guesses a
/// day, and a tier that never reset let a child re-arm a 24-hour lockout of the parent's own controls
/// with five taps, indefinitely.
/// The phone's ladder now counts the SERVER's wrong-PIN answers (build 26): the backend allows 10
/// guesses a minute, which walks all 10 000 codes in about 17 hours without it.
@MainActor
final class PINLockoutLadderTests: XCTestCase {
    private func makeThrottle() -> (UnpairPINThrottle, UserDefaults, String) {
        let suite = "PINLadder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (UnpairPINThrottle(userDefaults: defaults), defaults, suite)
    }

    /// End a running lockout the way time would: push its monotonic deadline into the past while
    /// leaving the boot anchor current, so `PINLockoutClock` resolves `.clear` and not `.restart`.
    private func expireLockout(_ defaults: UserDefaults) {
        let uptime = ProcessInfo.processInfo.systemUptime
        defaults.set(uptime - 1, forKey: UnpairPINThrottle.lockUptimeUntilKey)
        defaults.set(Date().timeIntervalSince1970 - uptime, forKey: UnpairPINThrottle.lockBootAnchorKey)
    }

    func testTheLadderIsStrictlyEscalatingAndCapped() {
        let ladder = UnpairPINThrottle.ladder
        XCTAssertEqual(ladder, ladder.sorted(), "each tier must be at least as long as the last")
        XCTAssertEqual(Set(ladder).count, ladder.count, "a repeated tier is a flat penalty in disguise")
        XCTAssertEqual(ladder.first, 60)
        XCTAssertEqual(ladder.last, 86_400)
    }

    func testFiveServerRefusalsStartALockoutAndAFurtherFiveEscalateIt() {
        let (throttle, defaults, suite) = makeThrottle()
        defer { defaults.removePersistentDomain(forName: suite) }

        for _ in 0 ..< 4 { XCTAssertNil(throttle.recordRejectedPIN()) }
        XCTAssertNil(throttle.remaining, "four misses are not a lockout yet")
        XCTAssertNotNil(throttle.recordRejectedPIN(), "the 5th refusal locks")
        let first = throttle.remaining
        XCTAssertNotNil(first)

        expireLockout(defaults)
        XCTAssertNil(throttle.remaining, "a served lockout lets the next guess through")
        for _ in 0 ..< 5 { _ = throttle.recordRejectedPIN() }
        let second = throttle.remaining
        XCTAssertNotNil(second)
        XCTAssertGreaterThan(second ?? 0, first ?? 0, "the ladder must climb, not repeat")
    }

    /// A served lockout keeps its tier: only an accepted PIN or a new pairing walks it back down.
    func testServingALockoutDoesNotResetTheTier() {
        let (throttle, defaults, suite) = makeThrottle()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0 ..< 5 { _ = throttle.recordRejectedPIN() }
        expireLockout(defaults)
        _ = throttle.remaining
        XCTAssertEqual(defaults.integer(forKey: UnpairPINThrottle.tierKey), 1)
    }

    func testResetAndWipeClearTheWholeLadder() {
        let (throttle, defaults, suite) = makeThrottle()
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0 ..< 5 { _ = throttle.recordRejectedPIN() }
        XCTAssertNotNil(throttle.remaining, "precondition: locked out")

        throttle.reset()

        XCTAssertNil(throttle.remaining)
        XCTAssertNil(throttle.lockedUntil)
        for _ in 0 ..< 5 { _ = throttle.recordRejectedPIN() }
        XCTAssertEqual(throttle.remaining.map { $0.rounded() }, UnpairPINThrottle.ladder[0],
                       "after a reset the ladder starts at the bottom rung again")

        UnpairPINThrottle.wipe(userDefaults: defaults)
        for key in [UnpairPINThrottle.failCountKey, UnpairPINThrottle.lockUntilKey, UnpairPINThrottle.tierKey,
                    UnpairPINThrottle.lockUptimeUntilKey, UnpairPINThrottle.lockBootAnchorKey] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) must not survive a pairing boundary")
        }
    }

    /// A lockout running when build 25 updated to 26 keeps running: same storage keys.
    func testTheBuild25LockoutKeysAreStillHonoured() {
        XCTAssertEqual(UnpairPINThrottle.failCountKey, "SETTINGS_PROTECTION_PIN_FAILS")
        XCTAssertEqual(UnpairPINThrottle.lockUptimeUntilKey, "SETTINGS_PROTECTION_PIN_LOCK_UPTIME_UNTIL")
        XCTAssertEqual(UnpairPINThrottle.lockBootAnchorKey, "SETTINGS_PROTECTION_PIN_LOCK_BOOT_ANCHOR")
    }
}

// MARK: - Parsing a hostile number must not kill the app

/// `Int(Double)` is a TRAPPING conversion. `JSONSerialization` returns `Double.infinity` for a
/// literal like `1e400`, so one malformed number anywhere in a `/device/*` response crashed the
/// child's app every time it parsed that response — and on a monitoring app a crash loop is not a
/// glitch, it is monitoring silently switched off.
final class SafeIntConversionTests: XCTestCase {
    func testOrdinaryValuesConvert() {
        XCTAssertEqual(OilaDeviceClient.safeInt(42), 42)
        XCTAssertEqual(OilaDeviceClient.safeInt(-7), -7)
        XCTAssertEqual(OilaDeviceClient.safeInt(0), 0)
    }

    func testFractionsTruncateTowardZeroAsBefore() {
        XCTAssertEqual(OilaDeviceClient.safeInt(9.99), 9)
        XCTAssertEqual(OilaDeviceClient.safeInt(-9.99), -9)
    }

    /// Each of these traps under the old `Int(value)`.
    func testValuesThatWouldTrapAreTreatedAsAbsent() {
        XCTAssertNil(OilaDeviceClient.safeInt(.infinity))
        XCTAssertNil(OilaDeviceClient.safeInt(-.infinity))
        XCTAssertNil(OilaDeviceClient.safeInt(.nan))
        XCTAssertNil(OilaDeviceClient.safeInt(1e30), "outside Int64")
        XCTAssertNil(OilaDeviceClient.safeInt(-1e30))
    }

    /// The boundary that makes the OBVIOUS fix wrong too. `Double(Int.max)` rounds UP to
    /// 9223372036854775808 — one more than `Int.max` — so a `value <= Double(Int.max)` guard admits
    /// exactly this value and then traps converting it. Measured, not assumed.
    func testTheBoundaryValueThatDefeatsARangeCheck() {
        XCTAssertNil(OilaDeviceClient.safeInt(Double(Int.max)),
                     "Double(Int.max) is not representable as an Int")
        XCTAssertEqual(OilaDeviceClient.safeInt(Double(Int.min)), Int.min,
                       "Int.min IS exactly representable, so it must still convert")
    }

    /// Proof the crash is reachable from a real response and not theoretical. Note the mechanism is
    /// large FINITE doubles: `JSONSerialization` rejects `1e400` outright rather than yielding
    /// infinity, so the reachable case is an ordinary-looking literal like this one.
    func testTheRealJSONPathThatWouldHaveCrashedTheApp() throws {
        let data = Data(#"{"n": 1e19}"#.utf8)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let parsed = try XCTUnwrap(object["n"] as? Double)
        XCTAssertTrue(parsed.isFinite)
        XCTAssertNil(OilaDeviceClient.safeInt(parsed),
                     "this is the value that used to kill the process")
    }
}

// MARK: - The whole-device lock, decided on the phone (build 26)

/// Shared fixtures for the lock tests: fixed zones, local-time dates, schedules and snapshots.
/// 2026-09-21 is a Monday; Europe/Berlin springs forward on 2026-03-29 and falls back on 2026-10-25.
private enum LockFixture {
    static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    static let tashkent = calendar("Asia/Tashkent")
    static let berlin = calendar("Europe/Berlin")

    static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                      second: Int = 0, in calendar: Calendar = tashkent) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func utc(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    static func schedule(_ start: Int, _ end: Int, days: Int = 0x7F, enabled: Bool = true,
                         deletedAt: String? = nil) -> DeviceLockSchedule {
        DeviceLockSchedule(id: nil, startMinute: start, endMinute: end, daysBitmask: days, enabled: enabled, deletedAt: deletedAt)
    }

    static func snapshot(manual: DeviceLockManualWindow? = nil, schedules: [DeviceLockSchedule] = [],
                         clock: DeviceLockClockAnchor? = nil) -> DeviceLockPolicySnapshot {
        DeviceLockPolicySnapshot(dsn: "child", manualLock: manual, schedules: schedules, serverTime: nil,
                                 receivedAt: Date(timeIntervalSince1970: 0), clock: clock, isLegacy: false)
    }

    /// Day bits, Monday = bit 0.
    static let monday = 1, tuesday = 2, wednesday = 4, thursday = 8, friday = 16, saturday = 32, sunday = 64
}

/// The rule itself (Akramjon, 2026-09-23): locked iff a manual window is running
/// (`startsAt <= now < endsAt`) or a schedule is active, by the phone's clock and zone.
final class DeviceLockPolicyTests: XCTestCase {
    private typealias F = LockFixture
    private let cal = LockFixture.tashkent

    private func locked(_ date: Date, _ snapshot: DeviceLockPolicySnapshot?, _ calendar: Calendar = LockFixture.tashkent) -> Bool {
        DeviceLockPolicy.isLocked(at: date, snapshot: snapshot, calendar: calendar)
    }

    // MARK: Manual window

    func testAManualWindowLocksFromItsStartUpToButNotIncludingItsEnd() {
        let start = F.local(2026, 9, 21, 14, 0)
        let snapshot = F.snapshot(manual: DeviceLockManualWindow(startsAt: start, endsAt: start.addingTimeInterval(7_200)))
        XCTAssertFalse(locked(start.addingTimeInterval(-1), snapshot))
        XCTAssertTrue(locked(start, snapshot), "startsAt <= now")
        XCTAssertTrue(locked(start.addingTimeInterval(7_199), snapshot))
        XCTAssertFalse(locked(start.addingTimeInterval(7_200), snapshot), "now < endsAt: the end itself is open")
    }

    func testAFutureWindowLocksNothingUntilItStarts() {
        let now = F.local(2026, 9, 21, 13, 0)
        let snapshot = F.snapshot(manual: DeviceLockManualWindow(startsAt: now.addingTimeInterval(3_600), endsAt: now.addingTimeInterval(7_200)))
        XCTAssertFalse(locked(now, snapshot))
        XCTAssertTrue(locked(now.addingTimeInterval(3_600), snapshot))
    }

    func testNoWindowNoScheduleAndNoSnapshotAreAllUnlocked() {
        XCTAssertFalse(locked(F.local(2026, 9, 21, 13, 0), F.snapshot()))
        XCTAssertFalse(locked(F.local(2026, 9, 21, 13, 0), nil), "no snapshot is unknown, never a lock")
    }

    /// The backend refuses more than 8 h; the phone refuses to be locked longer by any payload.
    func testAManualWindowIsClampedToEightHoursAndAMinute() {
        let start = F.local(2026, 9, 21, 8, 0)
        let snapshot = F.snapshot(manual: DeviceLockManualWindow(startsAt: start, endsAt: start.addingTimeInterval(12 * 3_600)))
        XCTAssertTrue(locked(start.addingTimeInterval(8 * 3_600 + 59), snapshot))
        XCTAssertFalse(locked(start.addingTimeInterval(8 * 3_600 + 60), snapshot))
        XCTAssertEqual(DeviceLockPolicy.episodeEnd(at: start, snapshot: snapshot, calendar: cal),
                       start.addingTimeInterval(8 * 3_600 + 60))
    }

    func testAnInvertedOrEmptyWindowLocksNothing() {
        let start = F.local(2026, 9, 21, 14, 0)
        for end in [start, start.addingTimeInterval(-60)] {
            let snapshot = F.snapshot(manual: DeviceLockManualWindow(startsAt: start, endsAt: end))
            XCTAssertFalse(locked(start, snapshot))
            XCTAssertFalse(locked(end, snapshot))
            XCTAssertTrue(DeviceLockPolicy.edges(after: start.addingTimeInterval(-3_600), horizon: 86_400, snapshot: snapshot, calendar: cal).isEmpty)
        }
    }

    // MARK: Schedules

    func testASimpleScheduleIsActiveOnItsDayWithAnExclusiveEnd() {
        let snapshot = F.snapshot(schedules: [F.schedule(9 * 60, 11 * 60, days: F.monday)])
        XCTAssertFalse(locked(F.local(2026, 9, 21, 8, 59), snapshot))
        XCTAssertTrue(locked(F.local(2026, 9, 21, 9, 0), snapshot))
        XCTAssertTrue(locked(F.local(2026, 9, 21, 10, 59), snapshot))
        XCTAssertFalse(locked(F.local(2026, 9, 21, 11, 0), snapshot), "endMinute is exclusive")
        XCTAssertFalse(locked(F.local(2026, 9, 22, 10, 0), snapshot), "Tuesday's bit is off")
    }

    /// The day bit names the day the window STARTS: a Friday night locks into Saturday morning even
    /// with Saturday's bit off, and a Thursday-bit-less window does not lock Friday's early hours.
    func testAWindowCrossingMidnightBelongsToTheDayItStarts() {
        let snapshot = F.snapshot(schedules: [F.schedule(22 * 60, 7 * 60, days: F.friday)])
        XCTAssertFalse(locked(F.local(2026, 9, 25, 21, 59), snapshot), "Friday before the start")
        XCTAssertTrue(locked(F.local(2026, 9, 25, 22, 0), snapshot), "Friday, today's half")
        XCTAssertTrue(locked(F.local(2026, 9, 26, 0, 0), snapshot), "Saturday midnight, yesterday's half")
        XCTAssertTrue(locked(F.local(2026, 9, 26, 6, 59), snapshot))
        XCTAssertFalse(locked(F.local(2026, 9, 26, 7, 0), snapshot), "exclusive end")
        XCTAssertFalse(locked(F.local(2026, 9, 26, 23, 0), snapshot), "Saturday's own bit is off")
        XCTAssertFalse(locked(F.local(2026, 9, 25, 1, 0), snapshot), "Friday 01:00 is Thursday's window, and Thursday is off")
    }

    func testTheSundayToMondayWrapUsesSundaysBit() {
        let snapshot = F.snapshot(schedules: [F.schedule(21 * 60, 6 * 60, days: F.sunday)])
        XCTAssertTrue(locked(F.local(2026, 9, 27, 21, 30), snapshot), "Sunday evening")
        XCTAssertTrue(locked(F.local(2026, 9, 28, 5, 59), snapshot), "Monday morning, Sunday's window")
        XCTAssertFalse(locked(F.local(2026, 9, 28, 21, 30), snapshot), "Monday evening, Monday is off")
    }

    func testStartEqualToEndAndAnEmptyBitmaskNeverLock() {
        let now = F.local(2026, 9, 21, 12, 0)
        XCTAssertFalse(locked(now, F.snapshot(schedules: [F.schedule(12 * 60, 12 * 60)])), "start == end is inactive")
        XCTAssertFalse(locked(now, F.snapshot(schedules: [F.schedule(11 * 60, 13 * 60, days: 0)])))
    }

    func testEveryDayBitMapsToItsOwnWeekday() {
        for bit in 0 ..< 7 {
            let snapshot = F.snapshot(schedules: [F.schedule(10 * 60, 11 * 60, days: 1 << bit)])
            for offset in 0 ..< 7 {
                // 2026-09-21 is Monday (bit 0); +offset days is bit `offset`.
                let at = F.local(2026, 9, 21 + offset, 10, 30)
                XCTAssertEqual(locked(at, snapshot), offset == bit, "bit \(bit), day +\(offset)")
            }
        }
        XCTAssertEqual(DeviceLockPolicy.weekdayIndex(calendarWeekday: 2), 0, "Calendar's Monday is bit 0")
        XCTAssertEqual(DeviceLockPolicy.weekdayIndex(calendarWeekday: 1), 6, "Calendar's Sunday is bit 6")
    }

    func testDisabledAndDeletedSchedulesAreIgnored() {
        let now = F.local(2026, 9, 21, 10, 0)
        XCTAssertFalse(locked(now, F.snapshot(schedules: [F.schedule(9 * 60, 11 * 60, enabled: false)])))
        XCTAssertFalse(locked(now, F.snapshot(schedules: [F.schedule(9 * 60, 11 * 60, deletedAt: "2026-09-20T10:00:00.000Z")])))
        XCTAssertTrue(locked(now, F.snapshot(schedules: [F.schedule(9 * 60, 11 * 60)])))
    }

    // MARK: Episodes and edges

    func testAManualWindowAndAnAbuttingOrOverlappingScheduleAreOneEpisode() {
        let evening = F.local(2026, 9, 21, 21, 0)
        let night = F.schedule(22 * 60, 7 * 60)
        let abutting = F.snapshot(manual: DeviceLockManualWindow(startsAt: F.local(2026, 9, 21, 20, 0), endsAt: F.local(2026, 9, 21, 22, 0)),
                                  schedules: [night])
        XCTAssertEqual(DeviceLockPolicy.episodeEnd(at: evening, snapshot: abutting, calendar: cal), F.local(2026, 9, 22, 7, 0),
                       "the phone does not open for an instant at 22:00, so the cover must not promise it")
        let overlapping = F.snapshot(manual: DeviceLockManualWindow(startsAt: F.local(2026, 9, 21, 20, 0), endsAt: F.local(2026, 9, 21, 23, 0)),
                                     schedules: [night])
        XCTAssertEqual(DeviceLockPolicy.episodeEnd(at: evening, snapshot: overlapping, calendar: cal), F.local(2026, 9, 22, 7, 0))
        // A schedule that ends INSIDE the manual window: the window's end is the episode's.
        let inside = F.snapshot(manual: DeviceLockManualWindow(startsAt: F.local(2026, 9, 21, 20, 0), endsAt: F.local(2026, 9, 21, 23, 0)),
                                schedules: [F.schedule(20 * 60 + 30, 21 * 60 + 30)])
        XCTAssertEqual(DeviceLockPolicy.episodeEnd(at: evening, snapshot: inside, calendar: cal), F.local(2026, 9, 21, 23, 0))
    }

    func testThereIsNoEpisodeEndWhileUnlocked() {
        let snapshot = F.snapshot(schedules: [F.schedule(22 * 60, 7 * 60)])
        XCTAssertNil(DeviceLockPolicy.episodeEnd(at: F.local(2026, 9, 21, 12, 0), snapshot: snapshot, calendar: cal))
    }

    func testEdgesAreTheFlipsInOrderInsideTheHorizon() {
        let snapshot = F.snapshot(schedules: [F.schedule(22 * 60, 7 * 60)])
        let edges = DeviceLockPolicy.edges(after: F.local(2026, 9, 21, 12, 0), horizon: 48 * 3_600, snapshot: snapshot, calendar: cal)
        XCTAssertEqual(edges, [
            F.local(2026, 9, 21, 22, 0), F.local(2026, 9, 22, 7, 0),
            F.local(2026, 9, 22, 22, 0), F.local(2026, 9, 23, 7, 0)
        ])
        // (now, now + horizon]: an edge exactly at now is not ahead; one exactly at the horizon is.
        let fromTheEdge = DeviceLockPolicy.edges(after: F.local(2026, 9, 21, 22, 0), horizon: 9 * 3_600, snapshot: snapshot, calendar: cal)
        XCTAssertEqual(fromTheEdge, [F.local(2026, 9, 22, 7, 0)])
    }

    func testAScheduleStartingInsideARunningWindowIsNotAnEdge() {
        let snapshot = F.snapshot(manual: DeviceLockManualWindow(startsAt: F.local(2026, 9, 21, 21, 0), endsAt: F.local(2026, 9, 21, 23, 0)),
                                  schedules: [F.schedule(22 * 60, 23 * 60 + 30, days: F.monday)])
        let edges = DeviceLockPolicy.edges(after: F.local(2026, 9, 21, 20, 0), horizon: 6 * 3_600, snapshot: snapshot, calendar: cal)
        XCTAssertEqual(edges, [F.local(2026, 9, 21, 21, 0), F.local(2026, 9, 21, 23, 30)])
    }

    /// Spring forward (Berlin, 2026-03-29, 02:00 CET → 03:00 CEST): a 02:30–04:00 schedule's start
    /// minute does not exist that night. The rule reads the local minute, so the lock takes effect
    /// at 03:00 CEST — the transition itself — and the edge is there, not an hour late.
    func testASkippedStartMinuteLocksAtTheSpringForwardTransition() {
        let snapshot = F.snapshot(schedules: [F.schedule(2 * 60 + 30, 4 * 60)])
        XCTAssertFalse(locked(F.utc("2026-03-29T00:59:59Z"), snapshot, F.berlin), "01:59:59 CET")
        XCTAssertTrue(locked(F.utc("2026-03-29T01:00:00Z"), snapshot, F.berlin), "03:00 CEST")
        let edges = DeviceLockPolicy.edges(after: F.utc("2026-03-28T12:00:00Z"), horizon: 24 * 3_600, snapshot: snapshot, calendar: F.berlin)
        XCTAssertEqual(edges, [F.utc("2026-03-29T01:00:00Z"), F.utc("2026-03-29T02:00:00Z")],
                       "lock at the transition, open at 04:00 CEST")
    }

    /// Fall back (Berlin, 2026-10-25, 03:00 CEST → 02:00 CET): 02:00–02:59 happens twice. A
    /// 01:00–02:30 schedule opens at the first 02:30, locks again when the clock goes back to 02:00,
    /// and opens at the second 02:30 — what the minute-of-day rule says, with every flip an edge.
    func testARepeatedHourYieldsBothOccurrencesAsEdges() {
        let snapshot = F.snapshot(schedules: [F.schedule(60, 2 * 60 + 30)])
        let edges = DeviceLockPolicy.edges(after: F.utc("2026-10-24T22:00:00Z"), horizon: 4 * 3_600, snapshot: snapshot, calendar: F.berlin)
        XCTAssertEqual(edges, [
            F.utc("2026-10-24T23:00:00Z"), // 01:00 CEST
            F.utc("2026-10-25T00:30:00Z"), // 02:30 CEST
            F.utc("2026-10-25T01:00:00Z"), // 02:00 CET, the clock went back
            F.utc("2026-10-25T01:30:00Z")  // 02:30 CET
        ])
        // Every edge really is a flip.
        var state = locked(F.utc("2026-10-24T22:00:00Z"), snapshot, F.berlin)
        for edge in edges {
            let next = locked(edge, snapshot, F.berlin)
            XCTAssertNotEqual(next, state, "\(edge)")
            state = next
        }
    }

    func testTheSameLocalRuleHoldsInTashkentWhichHasNoDST() {
        let snapshot = F.snapshot(schedules: [F.schedule(22 * 60, 7 * 60, days: F.friday | F.saturday)])
        let edges = DeviceLockPolicy.edges(after: F.local(2026, 9, 25, 12, 0), horizon: 72 * 3_600, snapshot: snapshot, calendar: cal)
        XCTAssertEqual(edges, [
            F.local(2026, 9, 25, 22, 0), F.local(2026, 9, 26, 7, 0),
            F.local(2026, 9, 26, 22, 0), F.local(2026, 9, 27, 7, 0)
        ])
    }
}

/// The clock the lock runs on (Akramjon's point 4): the server's time carried forward on a
/// monotonic clock the child cannot set, so moving the date changes nothing within a boot.
final class DeviceLockClockTests: XCTestCase {
    private let wall = Date(timeIntervalSince1970: 1_800_000_000)
    private let second: UInt64 = 1_000_000_000

    private func anchor(offset: TimeInterval = 30, boot: String? = "boot-A") -> DeviceLockClockAnchor {
        DeviceLockClockAnchor(wall: wall, monotonicNanos: 1_000 * second, offset: offset, bootSessionID: boot)
    }

    func testTheServerOffsetIsCarriedForwardOnTheMonotonicClock() {
        let trusted = DeviceLockClock.trustedNow(anchor: anchor(), wall: wall.addingTimeInterval(600),
                                                 monotonicNanos: 1_600 * second, bootSessionID: "boot-A")
        XCTAssertEqual(trusted, wall.addingTimeInterval(600 + 30))
    }

    func testMovingTheWallClockEitherWayWithinABootChangesNothing() {
        let moves: [TimeInterval] = [3 * 3_600, -3 * 3_600, 86_400 * 30]
        for moved in moves {
            let trusted = DeviceLockClock.trustedNow(anchor: anchor(), wall: wall.addingTimeInterval(60 + moved),
                                                     monotonicNanos: 1_060 * second, bootSessionID: "boot-A")
            XCTAssertEqual(trusted, wall.addingTimeInterval(60 + 30), "wall moved \(moved) s")
        }
    }

    func testAfterARebootTheWallClockCarriesTheOffset() {
        let rebooted = DeviceLockClock.trustedNow(anchor: anchor(), wall: wall.addingTimeInterval(7_200),
                                                  monotonicNanos: 50 * second, bootSessionID: nil)
        XCTAssertEqual(rebooted, wall.addingTimeInterval(7_200 + 30), "a monotonic value below the anchor's is a reboot")
    }

    /// A later boot that has simply been up longer than the anchor's would pass the monotonic test
    /// and put the clock back by however long the phone was off. The boot id decides first.
    func testADifferentBootSessionIsARebootEvenWithALargerMonotonicValue() {
        let trusted = DeviceLockClock.trustedNow(anchor: anchor(), wall: wall.addingTimeInterval(86_400),
                                                 monotonicNanos: 5_000 * second, bootSessionID: "boot-B")
        XCTAssertEqual(trusted, wall.addingTimeInterval(86_400 + 30))
    }

    func testNoAnchorIsThePlainWallClockAndNoServerTimeIsOffsetZero() {
        XCTAssertEqual(DeviceLockClock.trustedNow(anchor: nil, wall: wall, monotonicNanos: 1, bootSessionID: nil), wall)
        let noServer = DeviceLockClock.anchor(serverTime: nil, sentWall: wall, sentMonotonicNanos: 10 * second,
                                              receivedMonotonicNanos: 10 * second, bootSessionID: nil)
        XCTAssertEqual(noServer.offset, 0)
    }

    func testTheAnchorSitsAtTheMidpointOfTheRequest() {
        let anchor = DeviceLockClock.anchor(serverTime: wall.addingTimeInterval(1 + 5), sentWall: wall,
                                            sentMonotonicNanos: 10 * second, receivedMonotonicNanos: 12 * second,
                                            bootSessionID: "boot-A")
        XCTAssertEqual(anchor.wall, wall.addingTimeInterval(1))
        XCTAssertEqual(anchor.monotonicNanos, 11 * second)
        XCTAssertEqual(anchor.offset, 5, accuracy: 0.000_1)
        XCTAssertEqual(anchor.bootSessionID, "boot-A")
    }

    func testTheLiveClocksAreReadable() {
        let clock = DeviceLockClock.live
        let first = clock.monotonicNanos()
        XCTAssertGreaterThan(first, 0)
        XCTAssertGreaterThanOrEqual(clock.monotonicNanos(), first, "monotonic")
        XCTAssertEqual(DeviceLockClock.tamperThreshold, 120)
    }
}

/// One one-off `DeviceActivity` per edge, so the lock follows the rule with the app dead.
final class DeviceLockEdgeMonitoringTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // a whole minute
    private let dsn = "8D905F9F-770B-4D36-B41E-E34FD6D46B17"

    private final class FakeCenter: DeviceLockEdgeCenter {
        var armed: [(name: String, start: Date?)] = []
        var started: [(String, DeviceActivitySchedule)] = []
        var stopped: [String] = []
        var failNames: Set<String> = []
        struct Refused: Error {}

        func lockActivities() -> [(name: String, start: Date?)] { armed }
        func start(name: String, schedule: DeviceActivitySchedule) throws {
            if failNames.contains(name) { throw Refused() }
            started.append((name, schedule))
        }
        func stop(names: [String]) { stopped += names }
    }

    private func minute(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 60) }

    private func activity(_ name: String, _ start: Date?) -> (name: String, start: Date?) { (name, start) }

    func testTheNameCarriesTheNormalizedDSNAndTheEdgeMinute() {
        let raw = DeviceLockEdgeActivityIdentifier.rawValue(dsn: dsn, edgeMinute: 30_000_000)
        XCTAssertEqual(raw, "smartoila.lock-edge|8d905f9f-770b-4d36-b41e-e34fd6d46b17|30000000")
        XCTAssertTrue(DeviceLockEdgeActivityIdentifier.isLockEdgeActivity(rawValue: raw))
        XCTAssertEqual(DeviceLockEdgeActivityIdentifier.edgeMinute(from: raw), 30_000_000)
        XCTAssertEqual(DeviceLockEdgeActivityIdentifier.rawValue(dsn: "a|b", edgeMinute: 1), "smartoila.lock-edge|a_b|1",
                       "the separator can never appear inside the DSN")
        // Not swept by the old schedule controller, nor mistaken for any other activity.
        XCTAssertFalse(DeviceLockScheduleActivityIdentifier.isScheduleActivity(rawValue: raw))
        XCTAssertFalse(DeviceAppLimitActivityIdentifier.isAppLimitActivity(rawValue: raw))
        XCTAssertFalse(ScreenTimeUsageActivity.isUsageActivity(rawValue: raw))
        XCTAssertFalse(DeviceLockLegacyDeadline.isLegacyActivity(rawValue: raw))
        XCTAssertTrue(DeviceLockLegacyDeadline.isLegacyActivity(rawValue: "smartoila.lock-until|child"))
    }

    func testEachEdgeIsAOneOffSixteenMinuteActivityStartingAtTheEdge() {
        let edges = [now.addingTimeInterval(2 * 3_600), now.addingTimeInterval(4 * 3_600)]
        let entries = DeviceLockEdgeMonitoring.plan(dsn: dsn, edges: edges, now: now, skew: 0)
        XCTAssertEqual(entries.map(\.edgeMinute), edges.map(minute))
        XCTAssertEqual(entries.map(\.wallStart), edges)
        XCTAssertFalse(entries.contains(where: \.isFallback))
        let calendar = LockFixture.tashkent
        let schedule = DeviceLockEdgeMonitoring.schedule(for: entries[0], calendar: calendar)
        XCTAssertFalse(schedule.repeats)
        let start = calendar.date(from: schedule.intervalStart)
        let end = calendar.date(from: schedule.intervalEnd)
        XCTAssertEqual(start, edges[0])
        XCTAssertEqual(end, edges[0].addingTimeInterval(16 * 60), "Apple's 15-minute floor, plus a minute")
        XCTAssertNotNil(schedule.intervalStart.second, "full date components, year to second")
        XCTAssertNotNil(schedule.intervalStart.year)
    }

    func testAnEdgeIsRoundedUpToItsMinuteNeverDown() {
        let edge = now.addingTimeInterval(3_600 + 30)
        let entry = DeviceLockEdgeMonitoring.plan(dsn: dsn, edges: [edge], now: now, skew: 0).first
        XCTAssertEqual(entry?.edgeMinute, minute(now) + 61)
        XCTAssertGreaterThanOrEqual(entry?.wallStart ?? .distantPast, edge, "an activity may fire late, never before its edge")
    }

    /// Under a minute away the in-app timer has it; an activity that close is unmeasured. But a
    /// phone suspended in that minute still needs a re-check, so one fallback goes a minute out.
    func testAnEdgeUnderAMinuteAwayIsLeftToTheTimerWithAFallbackRecheck() {
        let entries = DeviceLockEdgeMonitoring.plan(
            dsn: dsn, edges: [now.addingTimeInterval(30), now.addingTimeInterval(3 * 3_600)], now: now, skew: 0
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isFallback)
        XCTAssertEqual(entries[0].edgeMinute, minute(now) + 1, "now + 60 s, rounded up to its minute")
        XCTAssertFalse(entries[1].isFallback)
        XCTAssertEqual(entries[1].edgeMinute, minute(now) + 180)
        // No fallback when the next edge is far enough to arm by itself.
        let far = DeviceLockEdgeMonitoring.plan(dsn: dsn, edges: [now.addingTimeInterval(90)], now: now, skew: 0)
        XCTAssertEqual(far.map(\.isFallback), [false])
        // Past edges are never armed.
        XCTAssertTrue(DeviceLockEdgeMonitoring.plan(dsn: dsn, edges: [now.addingTimeInterval(-60)], now: now, skew: 0).isEmpty)
    }

    /// A phone running 100 s fast (under the tamper threshold, so its clock is used for arming)
    /// already shows an edge 90 s away as nearly past. DeviceActivity runs on that clock, so the
    /// edge is left to the timer and the fallback lands a full lead ahead on the PHONE's clock.
    func testAnEdgeThePhonesFastClockShowsAsTooCloseGoesToTheFallback() {
        let entries = DeviceLockEdgeMonitoring.plan(
            dsn: dsn, edges: [now.addingTimeInterval(90), now.addingTimeInterval(3_600)], now: now, skew: -100
        )
        XCTAssertEqual(entries.map(\.isFallback), [true, false])
        let wallNow = now.addingTimeInterval(100)
        XCTAssertGreaterThanOrEqual(entries[0].wallStart.timeIntervalSince(wallNow), DeviceLockEdgeMonitoring.minimumLead)
    }

    func testAtMostTwelveEdgesAreArmed() {
        let edges = (1 ... 20).map { now.addingTimeInterval(Double($0) * 3_600) }
        let entries = DeviceLockEdgeMonitoring.plan(dsn: dsn, edges: edges, now: now, skew: 0)
        XCTAssertEqual(entries.count, 12)
        XCTAssertEqual(entries.last?.wallStart, edges[11], "the nearest twelve")
    }

    /// DeviceActivity runs on the phone's clock. While it agrees with the trusted clock the edges go
    /// on as they are; once it is off by more than the tamper threshold they are moved onto it, so
    /// they still fire at the TRUE time.
    func testAClockFarOffTheServerArmsTheEdgesOnThePhonesClock() {
        let edge = now.addingTimeInterval(3_600)
        let honest = DeviceLockEdgeMonitoring.plan(dsn: dsn, edges: [edge], now: now, skew: 30)
        XCTAssertEqual(honest.first?.wallStart, edge, "30 s of drift is not a changed clock")
        // Trusted is an hour AHEAD of the phone: the phone was set back an hour.
        let setBack = DeviceLockEdgeMonitoring.plan(dsn: dsn, edges: [edge], now: now, skew: 3_600)
        XCTAssertEqual(setBack.first?.wallStart, edge.addingTimeInterval(-3_600))
        XCTAssertEqual(setBack.first?.edgeMinute, minute(edge), "the name keeps the TRUE edge")
    }

    func testAnEarlyStartIsEvaluatedAtItsEdgeButAClockJumpIsNot() {
        let edge = now.addingTimeInterval(3_600)
        let name = DeviceLockEdgeActivityIdentifier.rawValue(dsn: dsn, edgeMinute: minute(edge))
        XCTAssertEqual(DeviceLockEdgeMonitoring.evaluationTime(now: edge.addingTimeInterval(-5), activityName: name), edge,
                       "max(now, edge): a callback a few seconds early reads the edge it was armed for")
        XCTAssertEqual(DeviceLockEdgeMonitoring.evaluationTime(now: edge.addingTimeInterval(10), activityName: name),
                       edge.addingTimeInterval(10))
        XCTAssertEqual(DeviceLockEdgeMonitoring.evaluationTime(now: edge.addingTimeInterval(-3_600), activityName: name),
                       edge.addingTimeInterval(-3_600), "an hour early is a clock moved forward, not this edge")
        XCTAssertEqual(DeviceLockEdgeMonitoring.evaluationTime(now: now, activityName: "smartoila.usage|x"), now)
    }

    func testArmTouchesOnlyWhatDiffers() {
        let entries = DeviceLockEdgeMonitoring.plan(
            dsn: dsn, edges: [now.addingTimeInterval(3_600), now.addingTimeInterval(7_200)], now: now, skew: 0
        )
        let center = FakeCenter()
        let name = { (date: Date) in DeviceLockEdgeActivityIdentifier.rawValue(dsn: self.dsn, edgeMinute: self.minute(date)) }
        center.armed = [
            activity(entries[0].name, entries[0].wallStart),                              // desired, in place
            activity(name(now.addingTimeInterval(1_800)), now.addingTimeInterval(1_800)), // undesired, future
            activity(name(now.addingTimeInterval(-300)), now.addingTimeInterval(-300)),   // undesired, running
            activity(name(now.addingTimeInterval(-3_600)), now.addingTimeInterval(-3_600)), // undesired, long over
            activity("smartoila.lock-until|child", now.addingTimeInterval(-60))            // build 24's
        ]
        let result = DeviceLockEdgeMonitoring.arm(entries, center: center, wallNow: now)
        XCTAssertEqual(Set(center.stopped), [
            name(now.addingTimeInterval(1_800)), name(now.addingTimeInterval(-3_600)), "smartoila.lock-until|child"
        ], "a RUNNING activity is left to end by itself: stopping it is a spurious intervalDidEnd")
        XCTAssertEqual(center.started.map(\.0), [entries[1].name])
        XCTAssertEqual(result.started, [entries[1].name])
        XCTAssertEqual(result.failures, 0)
        // A second pass with the result in place changes nothing.
        let settled = FakeCenter()
        settled.armed = entries.map { activity($0.name, $0.wallStart) }
        let again = DeviceLockEdgeMonitoring.arm(entries, center: settled, wallNow: now)
        XCTAssertTrue(again.started.isEmpty)
        XCTAssertTrue(again.stopped.isEmpty)
    }

    func testAnEntryArmedAtTheWrongTimeIsRestarted() {
        let entries = DeviceLockEdgeMonitoring.plan(dsn: dsn, edges: [now.addingTimeInterval(3_600)], now: now, skew: 0)
        let center = FakeCenter()
        center.armed = [activity(entries[0].name, entries[0].wallStart.addingTimeInterval(3_600))]
        DeviceLockEdgeMonitoring.arm(entries, center: center, wallNow: now)
        XCTAssertEqual(center.stopped, [entries[0].name])
        XCTAssertEqual(center.started.map(\.0), [entries[0].name])
    }

    func testAFailedStartIsCountedAndTheRestStillArm() {
        let entries = DeviceLockEdgeMonitoring.plan(
            dsn: dsn, edges: [now.addingTimeInterval(3_600), now.addingTimeInterval(7_200)], now: now, skew: 0
        )
        let center = FakeCenter()
        center.failNames = [entries[0].name]
        let result = DeviceLockEdgeMonitoring.arm(entries, center: center, wallNow: now)
        XCTAssertEqual(result.failures, 1)
        XCTAssertEqual(result.started, [entries[1].name])
    }

    func testStopAllStopsEveryLockActivity() {
        let center = FakeCenter()
        center.armed = [activity("smartoila.lock-edge|child|1", nil), activity("smartoila.lock-until|child", nil)]
        DeviceLockEdgeMonitoring.stopAll(center: center)
        XCTAssertEqual(center.stopped, ["smartoila.lock-edge|child|1", "smartoila.lock-until|child"])
    }

    func testTheSharedStoreRoundTripsTheSnapshot() {
        let suite = "DeviceLockEdgeMonitoringTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = DeviceLockPolicySharedStore(userDefaults: UserDefaults(suiteName: suite)!)
        XCTAssertNil(store.load())
        let snapshot = LockFixture.snapshot(
            manual: DeviceLockManualWindow(startsAt: now, endsAt: now.addingTimeInterval(60)),
            schedules: [LockFixture.schedule(60, 120, days: LockFixture.monday)],
            clock: DeviceLockClockAnchor(wall: now, monotonicNanos: 42, offset: -3.5, bootSessionID: "b")
        )
        store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
        store.markEdgeEvaluated(at: now)
        XCTAssertEqual(store.lastEdgeEvaluatedAt(), now)
        store.clear()
        XCTAssertNil(store.load())
        XCTAssertNil(store.lastEdgeEvaluatedAt())
    }
}

// MARK: - Parsing the live lock payload

/// `LockStateResponseDto` as the live backend sends it (api.json, 2026-09-24): the manual window
/// and every schedule as DATA, plus the server clock.
final class OilaLockPolicyParsingTests: XCTestCase {
    private func parse(_ json: String) throws -> OilaLockState {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return OilaDeviceClient.parseLockState(from: object)
    }

    private static func payload(isLocked: Bool, manualLockEnabled: Bool, manualLock: String, schedules: String = "[]") -> String {
        """
        {"isLocked":\(isLocked),"manualLockEnabled":\(manualLockEnabled),"manualLock":\(manualLock),
         "serverTime":"2026-09-22T14:05:00.000Z","scheduleLocked":false,"deviceLocalTime":"19:05",
         "activeSchedule":null,"lockedPackages":["com.example.game"],"appLimits":[],"schedules":\(schedules)}
        """
    }

    func testARunningManualWindowAndTheServerClockAreRead() throws {
        let state = try parse(Self.payload(
            isLocked: true, manualLockEnabled: true,
            manualLock: #"{"startsAt":"2026-09-22T14:00:00.000Z","endsAt":"2026-09-22T16:00:00.000Z"}"#
        ))
        XCTAssertEqual(state.manualLock, .window(DeviceLockManualWindow(
            startsAt: LockFixture.utc("2026-09-22T14:00:00Z"), endsAt: LockFixture.utc("2026-09-22T16:00:00Z")
        )))
        XCTAssertEqual(state.serverTime, LockFixture.utc("2026-09-22T14:05:00Z"))
        XCTAssertEqual(state.manualLockEnabled, true)
        XCTAssertTrue(state.carriesLockPolicy)
        XCTAssertEqual(state.schedules, [])
        XCTAssertEqual(state.lockedPackages, ["com.example.game"])
    }

    /// A FUTURE window arrives with `isLocked: false` and `manualLockEnabled: false`. The window
    /// object must not leak into the flag (it used to be read under "manualLock" too), and the
    /// window must survive — it is how the phone locks at `startsAt` with no internet.
    func testAFutureWindowIsKeptAndDoesNotPoseAsARunningLock() throws {
        let state = try parse(Self.payload(
            isLocked: false, manualLockEnabled: false,
            manualLock: #"{"startsAt":"2026-09-22T18:00:00.000Z","endsAt":"2026-09-22T20:00:00.000Z"}"#
        ))
        XCTAssertEqual(state.manualLockEnabled, false)
        guard case let .window(window) = state.manualLock else { return XCTFail("the future window was dropped") }
        XCTAssertEqual(window.startsAt, LockFixture.utc("2026-09-22T18:00:00Z"))
        XCTAssertNil(state.lockedUntil, "manualLock.endsAt is not a generic lock end")
    }

    func testANullManualLockIsNoneAndAMissingOneIsAbsent() throws {
        let none = try parse(Self.payload(isLocked: false, manualLockEnabled: false, manualLock: "null"))
        XCTAssertEqual(none.manualLock, .null)
        XCTAssertTrue(none.carriesLockPolicy)
        let unreadable = try parse(Self.payload(isLocked: true, manualLockEnabled: true, manualLock: #"{"startsAt":"soon"}"#))
        XCTAssertEqual(unreadable.manualLock, .unreadable)
        XCTAssertEqual(OilaDeviceClient.parseManualLock(from: [:]), .absent)
    }

    func testSchedulesAreTypedWithIntOrDoubleMinutes() throws {
        let state = try parse(Self.payload(isLocked: false, manualLockEnabled: false, manualLock: "null", schedules: """
        [{"id":"s1","deviceId":"d","label":"Tun","startMinute":1320,"endMinute":420,"daysBitmask":127,"enabled":true,
          "createdAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-01T00:00:00.000Z","deletedAt":null},
         {"id":"s2","label":"Dars","startMinute":480.0,"endMinute":750.5,"daysBitmask":31.0,"enabled":false,"deletedAt":null},
         {"id":"s3","label":"Old","startMinute":60,"endMinute":120,"daysBitmask":1,"enabled":true,"deletedAt":"2026-09-10T00:00:00.000Z"},
         {"id":"s4","label":"Broken","startMinute":60,"endMinute":120,"enabled":true},
         {"id":"s5","label":"OutOfRange","startMinute":1500,"endMinute":120,"daysBitmask":1,"enabled":true}]
        """))
        let schedules = try XCTUnwrap(state.schedules)
        XCTAssertEqual(schedules.map(\.id), ["s1", "s2", "s3"], "rows without a readable window or bitmask are dropped")
        XCTAssertEqual(schedules[0], DeviceLockSchedule(id: "s1", startMinute: 1_320, endMinute: 420, daysBitmask: 127, enabled: true, deletedAt: nil))
        XCTAssertEqual(schedules[1].startMinute, 480)
        XCTAssertEqual(schedules[1].endMinute, 750)
        XCTAssertEqual(schedules[1].daysBitmask, 31)
        XCTAssertFalse(schedules[1].enabled)
        XCTAssertEqual(schedules[2].deletedAt, "2026-09-10T00:00:00.000Z")
        XCTAssertFalse(schedules[2].isEnforceable)
    }

    /// An old backend sends none of `serverTime`, `schedules`, `manualLock`: its `isLocked` is all
    /// there is, so it is still read.
    func testAnOldPayloadFallsBackToItsIsLocked() throws {
        let state = try parse("""
        {"isLocked":true,"manualLockEnabled":true,"scheduleLocked":false,"deviceLocalTime":"15:45",
         "activeSchedule":null,"lockedPackages":[],"appLimits":[]}
        """)
        XCTAssertFalse(state.carriesLockPolicy)
        XCTAssertEqual(state.manualLock, .absent)
        XCTAssertNil(state.schedules)
        XCTAssertEqual(state.isDeviceLocked, true)
    }

    func testAnOldSpellingEndIsReadButNeverFromInsideManualLock() {
        let iso = "2026-09-18T20:00:00Z"
        let expected = Date(timeIntervalSince1970: 1_789_761_600)
        XCTAssertEqual(OilaDeviceClient.parseLockedUntil(from: ["lockedUntil": iso]), expected)
        XCTAssertEqual(OilaDeviceClient.parseLockedUntil(from: ["unlockAt": 1_789_761_600]), expected)
        XCTAssertEqual(OilaDeviceClient.parseLockedUntil(from: ["lockedUntil": 1_789_761_600_000]), expected, "epoch milliseconds")
        XCTAssertEqual(OilaDeviceClient.parseLockedUntil(from: ["global": ["until": iso]]), expected)
        XCTAssertNil(OilaDeviceClient.parseLockedUntil(from: ["manualLock": ["endsAt": iso]]))
        XCTAssertNil(OilaDeviceClient.parseLockedUntil(from: ["manualLock": ["until": iso]]))
        XCTAssertNil(OilaDeviceClient.parseLockedUntil(from: ["lockedUntil": NSNull()]))
        XCTAssertNil(OilaDeviceClient.parseLockedUntil(from: ["lockedUntil": false]))
    }

    /// The snapshot a payload yields: data from a current backend, a bounded window from an old
    /// one, nothing (keep the saved one) from a shape with no lock information at all.
    func testThePayloadBecomesASnapshot() throws {
        let wall = LockFixture.utc("2026-09-22T14:04:58Z")
        let anchor = DeviceLockClockAnchor(wall: wall, monotonicNanos: 1, offset: 2, bootSessionID: nil)
        let live = try parse(Self.payload(
            isLocked: false, manualLockEnabled: false,
            manualLock: #"{"startsAt":"2026-09-22T18:00:00.000Z","endsAt":"2026-09-22T20:00:00.000Z"}"#,
            schedules: #"[{"startMinute":1320,"endMinute":420,"daysBitmask":127,"enabled":true,"deletedAt":null}]"#
        ))
        let snapshot = try XCTUnwrap(OilaTelemetryService.lockPolicySnapshot(from: live, dsn: "child", anchor: anchor))
        XCTAssertFalse(snapshot.isLegacy)
        XCTAssertEqual(snapshot.manualLock?.startsAt, LockFixture.utc("2026-09-22T18:00:00Z"))
        XCTAssertEqual(snapshot.schedules.count, 1)
        XCTAssertEqual(snapshot.serverTime, LockFixture.utc("2026-09-22T14:05:00Z"))
        XCTAssertEqual(snapshot.clock, anchor)

        let old = OilaLockState(isLocked: true, raw: [:])
        let held = try XCTUnwrap(OilaTelemetryService.lockPolicySnapshot(from: old, dsn: "child", anchor: anchor))
        XCTAssertTrue(held.isLegacy)
        XCTAssertEqual(held.manualLock, DeviceLockManualWindow(startsAt: wall.addingTimeInterval(2), endsAt: wall.addingTimeInterval(2 + 8 * 3_600)),
                       "an old backend's bare lock is held at most 8 h without the server")
        let stale = OilaLockState(isLocked: true, raw: [:], lockedUntil: wall.addingTimeInterval(-60))
        let staleSnapshot = try XCTUnwrap(OilaTelemetryService.lockPolicySnapshot(from: stale, dsn: "child", anchor: anchor))
        XCTAssertNil(staleSnapshot.manualLock?.enforced, "an end already past opens the phone")

        XCTAssertNil(OilaTelemetryService.lockPolicySnapshot(from: OilaLockState(isLocked: nil, raw: ["x": 1]), dsn: "child", anchor: anchor))
    }
}

// MARK: - The service: re-evaluation, relaunch, migration

@MainActor
final class OilaTelemetryServiceLockPolicyTests: XCTestCase {
    private typealias F = LockFixture

    private final class ServiceStub: OilaDeviceServicing {
        struct Unimplemented: Error {}
        func pair(code: String) async throws -> OilaPairResult { throw Unimplemented() }
        func refreshSession() async throws { throw Unimplemented() }
        func logout() async throws {}
        func sendSOS(lat: Double?, lng: Double?, accuracy: Double?, batteryLevel: Double?) async throws {}
        func fetchActiveTasks() async throws -> [OilaDeviceTask] { [] }
        func fetchTasks() async throws -> [OilaDeviceTask] { [] }
        func completeTask(id: String) async throws {}
        func fetchTaskStarTotal() async throws -> Int? { nil }
        func updateFCMToken(_ token: String) async throws {}
        func uploadLocationBatch(_ fixes: [OilaLocationFix]) async throws {}
        func postDeviceStatus(_ status: OilaDeviceStatus) async throws {}
        func reportAppUsage(items: [DeviceApplicationUsageReportItemRequest]) async throws -> DeviceApplicationUsageReportResponse { throw Unimplemented() }
        func reportDailyUsage(days: [ScreenTimeUsageReportDay]) async throws -> DeviceApplicationUsageReportResponse { throw Unimplemented() }
        func syncInstalledApps(items: [DeviceAppLockSyncEntry]) async throws {}
        func fetchLockState() async throws -> OilaLockState { throw Unimplemented() }
        func fetchScreenTime() async throws -> OilaDeviceScreenTime? { nil }
        func reportRemovalAttempt(packageName: String, applicationName: String) async throws {}
        func fetchHome() async throws -> OilaDeviceHome? { nil }
    }

    /// Both clocks, moved independently — a child changing the date moves only `wall`.
    private final class Clocks {
        var wall: Date
        var monotonic: UInt64 = 5_000 * 1_000_000_000
        var boot: String? = "boot-1"
        init(_ wall: Date) { self.wall = wall }
        func advance(_ seconds: TimeInterval) {
            wall = wall.addingTimeInterval(seconds)
            monotonic += UInt64(seconds * 1_000_000_000)
        }
    }

    private final class Recorder {
        var shield: [Bool] = []
        var armed: [[DeviceLockEdgeMonitoring.Entry]] = []
        var stoppedAll = 0
        var retired = 0
        var clearedAlwaysAllowed = 0
        var authorized = true
    }

    private struct Harness {
        let clocks: Clocks
        let store: DeviceLockPolicySharedStore
        let legacy: UserDefaults
        let recorder: Recorder
    }

    private var suiteNames: [String] = []
    private var retained: [OilaTelemetryService] = []

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        retained.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "OilaTelemetryServiceLockPolicyTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeHarness(at wall: Date) -> Harness {
        Harness(clocks: Clocks(wall), store: DeviceLockPolicySharedStore(userDefaults: makeDefaults()),
                legacy: makeDefaults(), recorder: Recorder())
    }

    private func makeService(_ h: Harness) -> OilaTelemetryService {
        let clocks = h.clocks, recorder = h.recorder
        let service = OilaTelemetryService(service: ServiceStub(), lockRuntime: OilaLockRuntime(
            store: h.store,
            clock: DeviceLockClock(wallNow: { clocks.wall }, monotonicNanos: { clocks.monotonic }, bootSessionID: { clocks.boot }),
            calendar: { LockFixture.tashkent },
            pairedDSN: { "8D905F9F-770B-4D36-B41E-E34FD6D46B17" },
            applyWholeDevice: { recorder.shield.append($0) },
            armEdges: { entries in
                guard recorder.authorized else { return false }
                recorder.armed.append(entries)
                return true
            },
            stopAllEdges: { recorder.stoppedAll += 1 },
            legacyDefaults: h.legacy,
            retireLegacyDeadline: { recorder.retired += 1 },
            clearAlwaysAllowed: { recorder.clearedAlwaysAllowed += 1 }
        ))
        retained.append(service)
        return service
    }

    private func livePayload(startsAt: Date, endsAt: Date, serverTime: Date, schedules: [[String: Any]] = []) -> OilaLockState {
        let iso = ISO8601DateFormatter()
        return OilaDeviceClient.parseLockState(from: [
            "isLocked": false, "manualLockEnabled": false,
            "manualLock": ["startsAt": iso.string(from: startsAt), "endsAt": iso.string(from: endsAt)],
            "serverTime": iso.string(from: serverTime), "scheduleLocked": false, "deviceLocalTime": "13:00",
            "activeSchedule": NSNull(), "lockedPackages": [], "appLimits": [], "schedules": schedules
        ])
    }

    /// Akramjon's case, end to end with no network after the one poll: a FUTURE window is unlocked
    /// now, locks at `startsAt` by itself, and opens at `endsAt` by itself.
    func testAFutureWindowLocksAtItsStartAndOpensAtItsEndWithNoServer() {
        let start = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: start)
        let service = makeService(h)
        XCTAssertFalse(service.lockDecisionKnown, "nothing heard yet is unknown")
        XCTAssertTrue(h.recorder.shield.isEmpty, "and nothing is written to the OS from unknown")

        var announced = 0
        let observer = NotificationCenter.default.addObserver(
            forName: OilaTelemetryService.oilaLockEvaluationDidChange, object: nil, queue: nil
        ) { _ in announced += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        let startsAt = start.addingTimeInterval(120), endsAt = start.addingTimeInterval(420)
        service.applyLockState(livePayload(startsAt: startsAt, endsAt: endsAt, serverTime: start))
        XCTAssertTrue(service.lockDecisionKnown)
        XCTAssertFalse(service.isLocked)
        XCTAssertNil(service.lockEndsAt)
        XCTAssertEqual(service.nextLockCheckAt, startsAt, "the in-app timer is armed at startsAt")
        XCTAssertEqual(h.recorder.shield.last, false)
        XCTAssertEqual(h.recorder.armed.last?.map(\.edgeMinute),
                       [startsAt, endsAt].map { Int($0.timeIntervalSince1970 / 60) }, "both edges armed outside the app")
        XCTAssertNotNil(h.store.load(), "the policy is saved for the extension")

        h.clocks.advance(120)
        XCTAssertTrue(service.reevaluateLock(reason: "test"))
        XCTAssertTrue(service.isLocked)
        XCTAssertEqual(service.lockEndsAt, endsAt, "the cover shows the real end")
        XCTAssertEqual(service.nextLockCheckAt, endsAt)
        XCTAssertEqual(h.recorder.shield.last, true, "the OS shield is written by the service itself")

        h.clocks.advance(299)
        service.reevaluateLock(reason: "test")
        XCTAssertTrue(service.isLocked, "one second before the end is still locked")
        h.clocks.advance(1)
        service.reevaluateLock(reason: "test")
        XCTAssertFalse(service.isLocked)
        XCTAssertNil(service.lockEndsAt)
        XCTAssertEqual(h.recorder.shield.last, false)
        XCTAssertEqual(announced, 2, "locked, then unlocked — each flip announced once")
    }

    func testARelaunchDecidesFromTheSavedPolicyWithoutAServer() {
        let start = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: start)
        makeService(h).applyLockState(livePayload(startsAt: start, endsAt: start.addingTimeInterval(3_600), serverTime: start))
        // The process dies; an hour's first half passes; a scene-less relaunch with no network.
        h.clocks.advance(1_800)
        h.recorder.shield.removeAll()
        let relaunched = makeService(h)
        XCTAssertTrue(relaunched.isLocked)
        XCTAssertEqual(relaunched.lockEndsAt, start.addingTimeInterval(3_600))
        XCTAssertEqual(h.recorder.shield, [true], "written at init, with no scene and no coordinator")
        h.clocks.advance(1_800)
        XCTAssertFalse(makeService(h).isLocked, "and a relaunch past the end is open")
    }

    /// No ceiling on a schedule any more: a 10-hour night schedule holds for its whole night offline
    /// (the old 8 h no-server ceiling opened it at 05:00), and opens at 07:00 by itself.
    func testANightScheduleHoldsAllNightOfflineAndOpensOnTime() {
        let evening = F.local(2026, 9, 21, 20, 59)
        let h = makeHarness(at: evening)
        let service = makeService(h)
        service.applyLockState(livePayload(
            startsAt: evening.addingTimeInterval(-7_200), endsAt: evening.addingTimeInterval(-3_600), serverTime: evening,
            schedules: [["startMinute": 21 * 60, "endMinute": 7 * 60, "daysBitmask": 127, "enabled": true, "deletedAt": NSNull()]]
        ))
        XCTAssertFalse(service.isLocked)
        h.clocks.advance(60)
        service.reevaluateLock(reason: "test")
        XCTAssertTrue(service.isLocked)
        XCTAssertEqual(service.lockEndsAt, F.local(2026, 9, 22, 7, 0))
        h.clocks.advance(9 * 3_600 + 59 * 60)
        service.reevaluateLock(reason: "test")
        XCTAssertTrue(service.isLocked, "06:59, ten hours without the server")
        h.clocks.advance(60)
        service.reevaluateLock(reason: "test")
        XCTAssertFalse(service.isLocked)
    }

    /// The child moves the date forward to end the lock: the trusted clock does not move with it.
    func testMovingThePhonesClockDoesNotMoveTheLock() {
        let start = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: start)
        let service = makeService(h)
        service.applyLockState(livePayload(startsAt: start, endsAt: start.addingTimeInterval(3_600), serverTime: start))
        XCTAssertTrue(service.isLocked)
        h.clocks.wall = h.clocks.wall.addingTimeInterval(5 * 3_600)
        service.reevaluateLock(reason: "clock_changed")
        XCTAssertTrue(service.isLocked, "the wall clock moved; the monotonic one did not")
        // …and the real end still opens it, even with the wall clock moved back.
        h.clocks.wall = start.addingTimeInterval(-86_400)
        h.clocks.monotonic += 3_600 * 1_000_000_000
        service.reevaluateLock(reason: "clock_changed")
        XCTAssertFalse(service.isLocked)
    }

    /// The server's clock wins over a phone whose clock is simply wrong, from the first poll.
    func testThePhoneClockIsCorrectedByTheServerTime() {
        let serverNow = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: serverNow.addingTimeInterval(-2 * 3_600)) // the phone is two hours slow
        let service = makeService(h)
        service.applyLockState(livePayload(startsAt: serverNow.addingTimeInterval(-60), endsAt: serverNow.addingTimeInterval(3_600), serverTime: serverNow))
        XCTAssertTrue(service.isLocked, "by the phone's own clock the window is two hours away")
        XCTAssertEqual(h.recorder.armed.last?.first?.wallStart, serverNow.addingTimeInterval(3_600 - 2 * 3_600),
                       "the end is armed where the phone's clock will read it")
    }

    func testTheExtensionsEdgeEvaluationIsNotUndoneInTheGap() {
        let start = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: start)
        let service = makeService(h)
        let startsAt = start.addingTimeInterval(600)
        service.applyLockState(livePayload(startsAt: startsAt, endsAt: startsAt.addingTimeInterval(3_600), serverTime: start))
        h.clocks.advance(595) // five seconds before the edge
        h.store.markEdgeEvaluated(at: startsAt) // the extension's early callback, evaluated at its edge
        var lockedWhenRelayed: Bool?
        let observer = NotificationCenter.default.addObserver(
            forName: OilaTelemetryService.oilaLockExtensionDidEvaluate, object: nil, queue: nil
        ) { _ in lockedWhenRelayed = service.isLocked }
        defer { NotificationCenter.default.removeObserver(observer) }

        service.handleExtensionLockEdge()

        XCTAssertTrue(service.isLocked, "the extension's answer is not undone in the gap")
        XCTAssertEqual(lockedWhenRelayed, true, "the enforcement side is told only after the service re-decided")
    }

    func testAnUnrecognizedPayloadKeepsTheSavedPolicy() {
        let start = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: start)
        let service = makeService(h)
        service.applyLockState(livePayload(startsAt: start, endsAt: start.addingTimeInterval(3_600), serverTime: start))
        let saved = h.store.load()
        service.applyLockState(OilaLockState(isLocked: nil, raw: ["somethingElse": 1]))
        XCTAssertTrue(service.isLocked, "an unexpected shape neither locks nor unlocks")
        XCTAssertEqual(h.store.load(), saved)
    }

    func testAnOldBackendsBareLockIsHeldAtMostEightHours() {
        let start = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: start)
        let service = makeService(h)
        service.applyLockState(OilaLockState(isLocked: true, raw: [:]))
        XCTAssertTrue(service.isLocked)
        XCTAssertEqual(service.lockEndsAt, start.addingTimeInterval(8 * 3_600))
        service.applyLockState(OilaLockState(isLocked: false, raw: [:]))
        XCTAssertFalse(service.isLocked)
    }

    func testEdgesAreReArmedOnlyWhenThePlanChangesAndRetriedWhenUnauthorized() {
        let start = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: start)
        h.recorder.authorized = false
        let service = makeService(h)
        service.applyLockState(livePayload(startsAt: start.addingTimeInterval(600), endsAt: start.addingTimeInterval(1_200), serverTime: start))
        XCTAssertTrue(h.recorder.armed.isEmpty)
        h.recorder.authorized = true
        service.reevaluateLock(reason: "tick")
        XCTAssertEqual(h.recorder.armed.count, 1, "retried once authorization is there")
        service.reevaluateLock(reason: "tick")
        service.reevaluateLock(reason: "tick")
        XCTAssertEqual(h.recorder.armed.count, 1, "an unchanged plan does not talk to DeviceActivity every 30 s")
        XCTAssertEqual(h.recorder.shield.count, 4, "the shield is re-asserted on every evaluation (read-compare-write in the helper)")
    }

    // MARK: Upgrade from build 24

    func testABuild24LockIsHeldToItsOwnEndAfterAnOfflineUpgrade() {
        let now = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: now)
        h.legacy.set(true, forKey: OilaTelemetryService.legacyLockStateKey)
        h.legacy.set(now.addingTimeInterval(-3_600).timeIntervalSince1970, forKey: OilaTelemetryService.legacyLockConfirmedAtKey)
        h.legacy.set(now.addingTimeInterval(2 * 3_600).timeIntervalSince1970, forKey: OilaTelemetryService.legacyLockEndsAtKey)

        let service = makeService(h)

        XCTAssertTrue(service.isLocked, "an upgrade must not unlock early")
        XCTAssertEqual(service.lockEndsAt, now.addingTimeInterval(2 * 3_600))
        XCTAssertEqual(h.store.load()?.isLegacy, true)
        XCTAssertNil(h.legacy.object(forKey: OilaTelemetryService.legacyLockStateKey), "the old keys are gone")
        XCTAssertNil(h.legacy.object(forKey: OilaTelemetryService.legacyLockEndsAtKey))
        XCTAssertNil(h.legacy.object(forKey: OilaTelemetryService.legacyLockConfirmedAtKey))
        XCTAssertEqual(h.recorder.retired, 1, "build 24's lock-until activity is stopped once")
        XCTAssertEqual(h.recorder.clearedAlwaysAllowed, 1)
        _ = makeService(h)
        XCTAssertEqual(h.recorder.retired, 1, "only on the first launch of this build")
        XCTAssertEqual(h.recorder.clearedAlwaysAllowed, 2, "the always-allowed set is cleared at every launch")
    }

    func testABuild24LockWithNoEndNeverOutlivesEightHoursFromItsLastConfirmation() {
        let now = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: now)
        h.legacy.set(true, forKey: OilaTelemetryService.legacyLockStateKey)
        h.legacy.set(now.addingTimeInterval(-7 * 3_600).timeIntervalSince1970, forKey: OilaTelemetryService.legacyLockConfirmedAtKey)
        XCTAssertEqual(makeService(h).lockEndsAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(OilaTelemetryService.migratedLegacyWindow(wasLocked: true, endsAt: nil, confirmedAt: nil, now: now)?.endsAt,
                       now.addingTimeInterval(8 * 3_600), "with nothing known: bounded, never permanent")
        XCTAssertEqual(OilaTelemetryService.migratedLegacyWindow(wasLocked: true, endsAt: now.addingTimeInterval(86_400), confirmedAt: now.addingTimeInterval(86_400), now: now)?.endsAt,
                       now.addingTimeInterval(8 * 3_600), "a future stamp (clock moved back) still cannot buy more than 8 h")
    }

    func testAnExpiredBuild24LockOpensThePhoneOnUpgrade() {
        let now = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: now)
        h.legacy.set(true, forKey: OilaTelemetryService.legacyLockStateKey)
        h.legacy.set(now.timeIntervalSince1970, forKey: OilaTelemetryService.legacyLockConfirmedAtKey)
        h.legacy.set(now.addingTimeInterval(-1).timeIntervalSince1970, forKey: OilaTelemetryService.legacyLockEndsAtKey)
        let service = makeService(h)
        XCTAssertFalse(service.isLocked)
        XCTAssertTrue(service.lockDecisionKnown)
        XCTAssertEqual(h.recorder.shield, [false], "the shield build 24 left up is opened at once")
    }

    func testTheMigrationNeverOverridesAPolicyAlreadySaved() {
        let now = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: now)
        h.store.save(F.snapshot())
        h.legacy.set(true, forKey: OilaTelemetryService.legacyLockStateKey)
        h.legacy.set(now.addingTimeInterval(3_600).timeIntervalSince1970, forKey: OilaTelemetryService.legacyLockEndsAtKey)
        XCTAssertFalse(makeService(h).isLocked)
        XCTAssertNil(h.legacy.object(forKey: OilaTelemetryService.legacyLockStateKey))
    }

    // MARK: Unpair

    /// What `stop()` does to the lock (it runs `clearLockPolicy()`): the policy, the edges, the timer
    /// and the OS shield belong to the family that just left.
    func testUnpairClearsThePolicyTheEdgesAndTheShield() {
        let start = F.local(2026, 9, 21, 13, 0)
        let h = makeHarness(at: start)
        let service = makeService(h)
        service.applyLockState(livePayload(startsAt: start, endsAt: start.addingTimeInterval(3_600), serverTime: start))
        XCTAssertTrue(service.isLocked)

        service.clearLockPolicy()

        XCTAssertFalse(service.isLocked)
        XCTAssertNil(service.lockEndsAt)
        XCTAssertNil(service.nextLockCheckAt)
        XCTAssertFalse(service.lockDecisionKnown)
        XCTAssertNil(h.store.load())
        XCTAssertEqual(h.recorder.stoppedAll, 1)
        XCTAssertEqual(h.recorder.shield.last, false)
        service.reevaluateLock(reason: "tick")
        XCTAssertFalse(service.isLocked, "and nothing comes back from a policy that is gone")
    }
}

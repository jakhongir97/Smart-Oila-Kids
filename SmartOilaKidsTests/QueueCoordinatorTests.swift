import Foundation
import XCTest
@testable import SmartOilaKids

final class DeviceApplicationLockPayloadParserTests: XCTestCase {
    func testParseNestedPayloadNormalizesStatusAndApplicationIdentifiers() throws {
        let parser = DeviceApplicationLockPayloadParser()
        let data = try JSONSerialization.data(withJSONObject: [
            "data": [
                "lock_status": " TRUE ",
                "applications": [
                    " com.example.one ",
                    ["package_name": " COM.example.two "],
                    ["bundle_identifier": "com.example.THREE"],
                    ["bundleIdentifier": " com.example.four "],
                    ["identifier": " com.example.five "],
                    ["identifier": "   "],
                    42
                ]
            ]
        ])

        let event = try XCTUnwrap(parser.parse(from: data))

        XCTAssertTrue(event.lockStatus)
        XCTAssertEqual(
            event.applicationIdentifiers,
            [
                "com.example.one",
                "com.example.two",
                "com.example.three",
                "com.example.four",
                "com.example.five"
            ]
        )
    }

    func testParseSupportsNumericStatusAndDefaultsMissingApplicationsToEmpty() throws {
        let parser = DeviceApplicationLockPayloadParser()
        let data = try JSONSerialization.data(withJSONObject: [
            "value": 0
        ])

        let event = try XCTUnwrap(parser.parse(from: data))

        XCTAssertFalse(event.lockStatus)
        XCTAssertTrue(event.applicationIdentifiers.isEmpty)
    }

    func testParseReturnsNilForUnsupportedPayloads() throws {
        let parser = DeviceApplicationLockPayloadParser()
        let missingStatus = try JSONSerialization.data(withJSONObject: [
            "applications": ["com.example.one"]
        ])
        let invalidJSON = Data("not-json".utf8)

        XCTAssertNil(parser.parse(from: missingStatus))
        XCTAssertNil(parser.parse(from: invalidJSON))
    }
}

final class DeviceGlobalLockPayloadParserTests: XCTestCase {
    func testParseSupportsDirectBoolJSONAndNestedStringFlags() throws {
        let parser = DeviceGlobalLockPayloadParser()
        let direct = Data("true".utf8)
        let nested = try JSONSerialization.data(withJSONObject: [
            "data": [
                "global_application_lock": " 0 "
            ]
        ])

        XCTAssertEqual(parser.parse(from: direct), true)
        XCTAssertEqual(parser.parse(from: nested), false)
    }

    func testParseReturnsNilForUnsupportedShapes() throws {
        let parser = DeviceGlobalLockPayloadParser()
        let invalid = try JSONSerialization.data(withJSONObject: [
            "message": "missing"
        ])

        XCTAssertNil(parser.parse(from: invalid))
        XCTAssertNil(parser.parse(from: Data("null".utf8)))
    }
}

final class SecureTokenStoreTests: XCTestCase {
    private var store: SecureTokenStore!
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        store = SecureTokenStore()
        store.clear()
        suiteName = "SecureTokenStoreTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        store.clear()
        userDefaults = nil
        suiteName = nil
        store = nil
        super.tearDown()
    }

    func testSetReadTrimAndClearTokens() {
        store.setAccessToken("  Bearer access-token  ")
        store.setRefreshToken("\n refresh-token \t")

        XCTAssertEqual(store.accessToken(), "Bearer access-token")
        XCTAssertEqual(store.refreshToken(), "refresh-token")

        store.setAccessToken("   ")
        XCTAssertNil(store.accessToken())
        XCTAssertEqual(store.refreshToken(), "refresh-token")

        store.clear()
        XCTAssertNil(store.accessToken())
        XCTAssertNil(store.refreshToken())
    }

    func testMigrateFromUserDefaultsCopiesLegacyTokensAndRemovesDefaults() {
        userDefaults.set("  Bearer legacy-access  ", forKey: "API_ACCESS_TOKEN")
        userDefaults.set(" legacy-refresh ", forKey: "API_REFRESH_TOKEN")

        store.migrateFromUserDefaults(userDefaults)

        XCTAssertEqual(store.accessToken(), "Bearer legacy-access")
        XCTAssertEqual(store.refreshToken(), "legacy-refresh")
        XCTAssertNil(userDefaults.string(forKey: "API_ACCESS_TOKEN"))
        XCTAssertNil(userDefaults.string(forKey: "API_REFRESH_TOKEN"))
    }

    func testMigrateFromUserDefaultsDoesNotOverwriteExistingTokens() {
        store.setAccessToken("Bearer current-access")
        store.setRefreshToken("current-refresh")
        userDefaults.set("Bearer legacy-access", forKey: "API_ACCESS_TOKEN")
        userDefaults.set("legacy-refresh", forKey: "API_REFRESH_TOKEN")

        store.migrateFromUserDefaults(userDefaults)

        XCTAssertEqual(store.accessToken(), "Bearer current-access")
        XCTAssertEqual(store.refreshToken(), "current-refresh")
        XCTAssertNil(userDefaults.string(forKey: "API_ACCESS_TOKEN"))
        XCTAssertNil(userDefaults.string(forKey: "API_REFRESH_TOKEN"))
    }
}

final class DeviceApplicationRemovalAttemptCoordinatorTests: XCTestCase {
    func testEnqueueIgnoresInvalidEntries() async {
        let service = DeviceApplicationRemovalAttemptServiceSpy()
        let coordinator = DeviceApplicationRemovalAttemptCoordinator(service: service)

        await coordinator.enqueue(dsn: "   ", packageName: "com.example.one", appName: "Example")
        await coordinator.enqueue(dsn: "child-1", packageName: "   ", appName: "Example")
        await coordinator.enqueue(dsn: "child-1", packageName: "com.example.one", appName: "   ")

        let recordedCalls = await service.recordedCalls()
        XCTAssertTrue(recordedCalls.isEmpty)
    }

    func testEnqueueNormalizesValuesAndProcessesImmediately() async {
        let service = DeviceApplicationRemovalAttemptServiceSpy()
        let coordinator = DeviceApplicationRemovalAttemptCoordinator(service: service)

        await coordinator.enqueue(
            dsn: " child-1 ",
            packageName: " COM.EXAMPLE.APP ",
            appName: " Example App "
        )

        let recordedCalls = await service.recordedCalls()
        XCTAssertEqual(
            recordedCalls,
            [
                DeviceApplicationRemovalAttemptEntry(
                    dsn: "child-1",
                    packageName: "com.example.app",
                    appName: "Example App"
                )
            ]
        )
    }

    func testEnqueueDeduplicatesInFlightEntriesAndProcessesDistinctEntriesInOrder() async {
        let service = DeviceApplicationRemovalAttemptServiceSpy(suspendFirstCall: true)
        let coordinator = DeviceApplicationRemovalAttemptCoordinator(service: service)

        let first = Task {
            await coordinator.enqueue(
                dsn: " child-1 ",
                packageName: " COM.EXAMPLE.APP ",
                appName: " Example App "
            )
        }

        await waitForRemovalAttemptCallCount(service, count: 1)

        let duplicate = Task {
            await coordinator.enqueue(
                dsn: "child-1",
                packageName: "com.example.app",
                appName: "Example App"
            )
        }
        let second = Task {
            await coordinator.enqueue(
                dsn: "child-1",
                packageName: "com.example.second",
                appName: "Second App"
            )
        }

        await Task.yield()
        await service.resumeSuspendedCallIfNeeded()
        _ = await (first.result, duplicate.result, second.result)
        await waitForRemovalAttemptCallCount(service, count: 2)

        let recordedCalls = await service.recordedCalls()
        XCTAssertEqual(
            recordedCalls,
            [
                DeviceApplicationRemovalAttemptEntry(
                    dsn: "child-1",
                    packageName: "com.example.app",
                    appName: "Example App"
                ),
                DeviceApplicationRemovalAttemptEntry(
                    dsn: "child-1",
                    packageName: "com.example.second",
                    appName: "Second App"
                )
            ]
        )
    }
}

final class DeviceAppLockSyncCoordinatorTests: XCTestCase {
    func testUpdateNormalizesDSNSortsEntriesAndSkipsEquivalentSignatures() async {
        let service = DeviceAppLockSyncServiceSpy()
        let coordinator = DeviceAppLockSyncCoordinator(service: service)
        let alpha = DeviceAppLockSyncEntry(
            packageName: "com.example.alpha",
            appName: "Alpha",
            isLocked: true,
            usedTime: 10
        )
        let beta = DeviceAppLockSyncEntry(
            packageName: "com.example.beta",
            appName: "Beta",
            isLocked: false,
            usedTime: 20
        )

        await coordinator.update(dsn: " child-sync ", entries: [beta, alpha])
        await coordinator.update(dsn: "child-sync", entries: [alpha, beta])

        let recordedCalls = await service.recordedCalls()

        XCTAssertEqual(recordedCalls, [
            DeviceAppLockSyncCall(
                dsn: "child-sync",
                entries: [alpha, beta]
            )
        ])
    }

    func testRetryNowForcesSyncForUnchangedState() async {
        let service = DeviceAppLockSyncServiceSpy()
        let coordinator = DeviceAppLockSyncCoordinator(service: service)
        let entry = DeviceAppLockSyncEntry(
            packageName: "com.example.camera",
            appName: "Camera",
            isLocked: true,
            usedTime: 33
        )

        await coordinator.update(dsn: "child-sync", entries: [entry])
        await coordinator.retryNow()

        let recordedCalls = await service.recordedCalls()

        XCTAssertEqual(recordedCalls, [
            DeviceAppLockSyncCall(dsn: "child-sync", entries: [entry]),
            DeviceAppLockSyncCall(dsn: "child-sync", entries: [entry])
        ])
    }

    func testBlankDSNResetsSignatureAndAllowsFutureResync() async {
        let service = DeviceAppLockSyncServiceSpy()
        let coordinator = DeviceAppLockSyncCoordinator(service: service)
        let entry = DeviceAppLockSyncEntry(
            packageName: "com.example.mail",
            appName: "Mail",
            isLocked: false,
            usedTime: 5
        )

        await coordinator.update(dsn: "child-sync", entries: [entry])
        await coordinator.update(dsn: "   ", entries: [entry])
        await coordinator.update(dsn: "child-sync", entries: [entry])

        let recordedCalls = await service.recordedCalls()

        XCTAssertEqual(recordedCalls, [
            DeviceAppLockSyncCall(dsn: "child-sync", entries: [entry]),
            DeviceAppLockSyncCall(dsn: "child-sync", entries: [entry])
        ])
    }

    func testFailureSchedulesRetryUntilStateIsCleared() async {
        let service = DeviceAppLockSyncServiceSpy(results: [.failure(DeviceAppLockSyncTestError.offline)])
        let coordinator = DeviceAppLockSyncCoordinator(service: service)
        let entry = DeviceAppLockSyncEntry(
            packageName: "com.example.maps",
            appName: "Maps",
            isLocked: true,
            usedTime: 12
        )

        await coordinator.update(dsn: "child-sync", entries: [entry])
        await coordinator.update(dsn: nil, entries: [])

        let recordedCalls = await service.recordedCalls()

        XCTAssertEqual(recordedCalls, [
            DeviceAppLockSyncCall(dsn: "child-sync", entries: [entry])
        ])
    }
}

final class DeviceApplicationUsageReportCoordinatorTests: XCTestCase {
    func testUpdateSnapshotUploadsOnlyDeltaUsageForTheCurrentDay() async {
        let service = DeviceApplicationUsageReportServiceSpy(
            results: [
                .success(.init(lockedPackages: [], stats: [])),
                .success(.init(lockedPackages: [], stats: []))
            ]
        )
        let suiteName = "DeviceApplicationUsageReportCoordinatorTests.delta.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let coordinator = DeviceApplicationUsageReportCoordinator(
            service: service,
            userDefaults: userDefaults,
            responseHandler: { _, _ in },
            diagnosticsUpdater: { _, _, _, _, _, _, _, _ in },
            retryScheduler: { _, _ in Task {} }
        )

        await coordinator.updateDSN("child-usage")
        await coordinator.updateSnapshot(
            makeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-19",
                entries: [
                    .init(packageName: "com.example.chat", appName: "Chat", usedTime: 120),
                    .init(packageName: "com.example.maps", appName: "Maps", usedTime: 60)
                ]
            )
        )
        await coordinator.updateSnapshot(
            makeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-19",
                entries: [
                    .init(packageName: "com.example.chat", appName: "Chat", usedTime: 180),
                    .init(packageName: "com.example.maps", appName: "Maps", usedTime: 60)
                ]
            )
        )

        let recordedCalls = await service.recordedCalls()
        let pendingBatchCount = await coordinator.pendingBatchCount()

        XCTAssertEqual(recordedCalls, [
            DeviceApplicationUsageReportCall(
                dsn: "child-usage",
                items: [
                    DeviceApplicationUsageReportItemRequest(packageName: "com.example.chat", usedSeconds: 120),
                    DeviceApplicationUsageReportItemRequest(packageName: "com.example.maps", usedSeconds: 60)
                ]
            ),
            DeviceApplicationUsageReportCall(
                dsn: "child-usage",
                items: [
                    DeviceApplicationUsageReportItemRequest(packageName: "com.example.chat", usedSeconds: 60)
                ]
            )
        ])
        XCTAssertEqual(pendingBatchCount, 0)
    }

    func testFailedUploadPersistsQueueUntilANewCoordinatorRetriesIt() async {
        let suiteName = "DeviceApplicationUsageReportCoordinatorTests.retry.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let failingService = DeviceApplicationUsageReportServiceSpy(
            results: [.failure(DeviceApplicationUsageReportTestError.offline)]
        )
        let firstCoordinator = DeviceApplicationUsageReportCoordinator(
            service: failingService,
            userDefaults: userDefaults,
            responseHandler: { _, _ in },
            diagnosticsUpdater: { _, _, _, _, _, _, _, _ in },
            retryScheduler: { _, _ in Task {} }
        )

        await firstCoordinator.updateDSN("child-usage")
        await firstCoordinator.updateSnapshot(
            makeUsageSnapshot(
                dsn: "child-usage",
                dayKey: "2026-03-19",
                entries: [
                    .init(packageName: "com.example.chat", appName: "Chat", usedTime: 240)
                ]
            )
        )

        let firstPendingBatchCount = await firstCoordinator.pendingBatchCount()
        let failingCalls = await failingService.recordedCalls()

        XCTAssertEqual(firstPendingBatchCount, 1)
        XCTAssertEqual(failingCalls, [
            DeviceApplicationUsageReportCall(
                dsn: "child-usage",
                items: [DeviceApplicationUsageReportItemRequest(packageName: "com.example.chat", usedSeconds: 240)]
            )
        ])

        let succeedingService = DeviceApplicationUsageReportServiceSpy(
            results: [.success(.init(
                lockedPackages: ["com.example.chat"],
                stats: [
                    DeviceApplicationUsageReportStat(
                        packageName: "com.example.chat",
                        usageDate: "2026-03-19",
                        usedSeconds: 240,
                        dailyLimitSeconds: 300,
                        remainingSeconds: 60,
                        isLimitReached: false
                    )
                ]
            ))]
        )
        let secondCoordinator = DeviceApplicationUsageReportCoordinator(
            service: succeedingService,
            userDefaults: userDefaults,
            responseHandler: { _, _ in },
            diagnosticsUpdater: { _, _, _, _, _, _, _, _ in },
            retryScheduler: { _, _ in Task {} }
        )

        await secondCoordinator.updateDSN("child-usage")

        let succeedingCalls = await succeedingService.recordedCalls()
        let secondPendingBatchCount = await secondCoordinator.pendingBatchCount()

        XCTAssertEqual(succeedingCalls, [
            DeviceApplicationUsageReportCall(
                dsn: "child-usage",
                items: [DeviceApplicationUsageReportItemRequest(packageName: "com.example.chat", usedSeconds: 240)]
            )
        ])
        XCTAssertEqual(secondPendingBatchCount, 0)
    }

    private func makeUsageSnapshot(
        dsn: String,
        dayKey: String,
        entries: [ScreenTimeUsageSnapshotEntry]
    ) -> ScreenTimeUsageSnapshot {
        ScreenTimeUsageSnapshot(
            dsn: dsn,
            dayKey: dayKey,
            generatedAt: Date(timeIntervalSince1970: 1_742_339_200),
            entries: entries
        )
    }
}

final class SessionStoreTests: XCTestCase {
    override func tearDown() {
        L10n.setLanguage(AppLanguage.defaultForDevice.rawValue)
        super.tearDown()
    }

    func testInitLoadsPersistedValuesAndMigratesSecureTokens() {
        let suiteName = "SessionStoreInitTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set(" child-1 ", forKey: "DSN")
        userDefaults.set("Parent", forKey: "PROFILE_NAME")
        userDefaults.set(AppTheme.dark.rawValue, forKey: "APP_THEME")
        userDefaults.set(AppLanguage.uz.rawValue, forKey: "APP_LANGUAGE")

        let secureTokens = MutableSecureTokenStoreSpy(access: "Bearer access", refresh: "refresh-1")
        let store = SessionStore(userDefaults: userDefaults, secureTokens: secureTokens)

        XCTAssertEqual(secureTokens.migrateCallCount, 1)
        XCTAssertEqual(store.dsn, "child-1")
        XCTAssertEqual(store.profileName, "Parent")
        XCTAssertEqual(store.apiAccessToken, "Bearer access")
        XCTAssertEqual(store.apiRefreshToken, "refresh-1")
        XCTAssertEqual(store.appTheme, .dark)
        XCTAssertEqual(store.appLanguage, .uz)
    }

    func testInitFallsBackForInvalidPersistedThemeLanguageAndProfile() {
        let suiteName = "SessionStoreFallbackTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set("   ", forKey: "DSN")
        userDefaults.set("unknown", forKey: "APP_THEME")
        userDefaults.set("xx", forKey: "APP_LANGUAGE")

        let store = SessionStore(
            userDefaults: userDefaults,
            secureTokens: MutableSecureTokenStoreSpy()
        )

        XCTAssertNil(store.dsn)
        XCTAssertEqual(store.profileName, L10n.tr("common.user_default"))
        XCTAssertEqual(store.appTheme, .system)
        XCTAssertEqual(store.appLanguage, AppLanguage.defaultForDevice)
    }

    func testSettersPersistNormalizedValuesAndClearSession() {
        let suiteName = "SessionStoreMutationTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let secureTokens = MutableSecureTokenStoreSpy()
        let store = SessionStore(userDefaults: userDefaults, secureTokens: secureTokens)

        store.setDSN(" child-2 ")
        store.setProfileName("Guardian")
        store.setAPIAccessToken("  Bearer   access-token  ")
        store.setAPIRefreshToken("refresh-2")
        store.setTheme(.light)
        store.setLanguage(.ru)

        XCTAssertEqual(store.dsn, "child-2")
        XCTAssertEqual(userDefaults.string(forKey: "DSN"), "child-2")
        XCTAssertEqual(store.profileName, "Guardian")
        XCTAssertEqual(userDefaults.string(forKey: "PROFILE_NAME"), "Guardian")
        XCTAssertEqual(store.apiAccessToken, "Bearer access-token")
        XCTAssertEqual(secureTokens.setAccessCalls.last!, "Bearer access-token")
        XCTAssertEqual(store.apiRefreshToken, "refresh-2")
        XCTAssertEqual(secureTokens.setRefreshCalls.last!, "refresh-2")
        XCTAssertEqual(store.appTheme, .light)
        XCTAssertEqual(userDefaults.string(forKey: "APP_THEME"), AppTheme.light.rawValue)
        XCTAssertEqual(store.appLanguage, .ru)
        XCTAssertEqual(userDefaults.string(forKey: "APP_LANGUAGE"), AppLanguage.ru.rawValue)
        XCTAssertTrue(store.hasAuthenticatedSession)

        store.clearSession()

        XCTAssertNil(store.dsn)
        XCTAssertNil(userDefaults.string(forKey: "DSN"))
        XCTAssertNil(store.apiAccessToken)
        XCTAssertNil(store.apiRefreshToken)
        XCTAssertNil(secureTokens.access)
        XCTAssertNil(secureTokens.refresh)
        XCTAssertEqual(store.profileName, "Guardian")
        XCTAssertEqual(store.appTheme, .light)
        XCTAssertEqual(store.appLanguage, .ru)
        XCTAssertFalse(store.hasAuthenticatedSession)
    }

    func testClearSessionRegeneratesDeviceDSNAndClearsGlobalCache() {
        let suiteName = "SessionStorePurgeTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = SessionStore(userDefaults: userDefaults, secureTokens: MutableSecureTokenStoreSpy())

        // Simulate a paired child: a generate-once device DSN + a globally-cached device list.
        let dsnBefore = OilaDeviceIdentity.deviceDSN(userDefaults: userDefaults)
        userDefaults.set(Data("x".utf8), forKey: "SETTINGS_CACHE_CONNECTED_DEVICES")
        userDefaults.set("Aziz", forKey: "SETTINGS_CACHE_PROFILE_NAME")

        store.clearSession()

        // A different child re-pairing on this device must get a FRESH DSN scope...
        let dsnAfter = OilaDeviceIdentity.deviceDSN(userDefaults: userDefaults)
        XCTAssertNotEqual(dsnBefore, dsnAfter)
        // ...and the previous child's globally-cached data must be gone.
        XCTAssertNil(userDefaults.data(forKey: "SETTINGS_CACHE_CONNECTED_DEVICES"))
        XCTAssertNil(userDefaults.string(forKey: "SETTINGS_CACHE_PROFILE_NAME"))
    }

    func testRoutingMigrationSendsLegacyLinkedUserThroughFullOnboarding() {
        let suiteName = "SessionStoreMigrationTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        // A legacy-linked user (has a DSN) who has never run the new routing migration.
        userDefaults.set("legacy-dsn", forKey: "DSN")

        let store = SessionStore(userDefaults: userDefaults, secureTokens: MutableSecureTokenStoreSpy())

        // They must re-pair AND re-run the B1–B11 permission flow (not skip it): the new flow's
        // permissions (Always-location, Screen Time authorization) may never have been granted.
        XCTAssertFalse(store.setupCompleted)
        XCTAssertFalse(store.onboardingCompleted)
        XCTAssertFalse(store.oilaPaired)
        // …and because the reset silently drops their protection, A1 shows them the
        // "re-link to keep protection on" notice.
        XCTAssertTrue(store.migratedFromLegacy)

        // The marker survives a second launch (the migration branch no longer runs).
        let secondLaunch = SessionStore(userDefaults: userDefaults, secureTokens: MutableSecureTokenStoreSpy())
        XCTAssertTrue(secondLaunch.migratedFromLegacy)
    }

    func testRoutingMigrationDoesNotFlagFreshInstallAsMigrated() {
        let suiteName = "SessionStoreFreshInstallTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        // A fresh install also passes through the one-time migration branch, but has no legacy
        // DSN and no completed-flow flags — it must NOT see the re-link notice.
        let store = SessionStore(userDefaults: userDefaults, secureTokens: MutableSecureTokenStoreSpy())

        XCTAssertFalse(store.migratedFromLegacy)
        XCTAssertFalse(store.setupCompleted)
        XCTAssertFalse(store.onboardingCompleted)
        XCTAssertFalse(store.oilaPaired)
    }

    func testHasAuthenticatedSessionUsesRefreshTokenWhenAccessTokenIsMissing() {
        let suiteName = "SessionStoreRefreshOnlyTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = SessionStore(
            userDefaults: userDefaults,
            secureTokens: MutableSecureTokenStoreSpy(access: nil, refresh: "refresh-only")
        )

        XCTAssertNil(store.apiAccessToken)
        XCTAssertEqual(store.apiRefreshToken, "refresh-only")
        XCTAssertTrue(store.hasAuthenticatedSession)
    }
}

private final class MutableSecureTokenStoreSpy: SecureTokenStoring {
    var access: String?
    var refresh: String?
    private(set) var setAccessCalls: [String?] = []
    private(set) var setRefreshCalls: [String?] = []
    private(set) var clearCallCount = 0
    private(set) var migrateCallCount = 0

    init(access: String? = nil, refresh: String? = nil) {
        self.access = access
        self.refresh = refresh
    }

    func accessToken() -> String? { access }
    func refreshToken() -> String? { refresh }

    func setAccessToken(_ token: String?) {
        access = token
        setAccessCalls.append(token)
    }

    func setRefreshToken(_ token: String?) {
        refresh = token
        setRefreshCalls.append(token)
    }

    func migrateFromUserDefaults(_ userDefaults: UserDefaults) {
        migrateCallCount += 1
    }

    func clear() {
        clearCallCount += 1
        access = nil
        refresh = nil
    }
}

private actor RefreshRequestDataSpy {
    private var requests: [URLRequest] = []
    private var responses: [Data]
    private let suspendFirstCall: Bool
    private var shouldSuspend = true
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        responses: [Data],
        suspendFirstCall: Bool = false
    ) {
        self.responses = responses
        self.suspendFirstCall = suspendFirstCall
    }

    func requestData(for request: URLRequest) async throws -> Data {
        requests.append(request)

        if suspendFirstCall, shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        if responses.count > 1 {
            return responses.removeFirst()
        }

        return responses.first ?? Data()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func resumeSuspendedCallIfNeeded() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DeviceApplicationRemovalAttemptServiceSpy: DeviceApplicationRemovalAttemptServicing {
    private var calls: [DeviceApplicationRemovalAttemptEntry] = []
    private let suspendFirstCall: Bool
    private var shouldSuspend = true
    private var continuation: CheckedContinuation<Void, Never>?

    init(suspendFirstCall: Bool = false) {
        self.suspendFirstCall = suspendFirstCall
    }

    func reportRemovalAttempt(dsn: String, packageName: String, appName: String) async throws {
        calls.append(
            DeviceApplicationRemovalAttemptEntry(
                dsn: dsn,
                packageName: packageName,
                appName: appName
            )
        )

        if suspendFirstCall, shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    func recordedCalls() -> [DeviceApplicationRemovalAttemptEntry] {
        calls
    }

    func resumeSuspendedCallIfNeeded() {
        continuation?.resume()
        continuation = nil
    }
}

private struct DeviceAppLockSyncCall: Equatable {
    let dsn: String
    let entries: [DeviceAppLockSyncEntry]
}

private enum DeviceAppLockSyncTestError: Error {
    case offline
}

private enum DeviceApplicationUsageReportTestError: Error {
    case offline
}

private actor DeviceAppLockSyncServiceSpy: DeviceAppLockSyncServicing {
    private var calls: [DeviceAppLockSyncCall] = []
    private var results: [Result<Void, Error>]

    init(results: [Result<Void, Error>] = [.success(())]) {
        self.results = results
    }

    func syncApplications(_ entries: [DeviceAppLockSyncEntry], dsn: String) async throws {
        calls.append(DeviceAppLockSyncCall(dsn: dsn, entries: entries))

        if results.count > 1 {
            return try results.removeFirst().get()
        }

        return try results.first?.get() ?? ()
    }

    func recordedCalls() -> [DeviceAppLockSyncCall] {
        calls
    }
}

private struct DeviceApplicationUsageReportCall: Equatable {
    let dsn: String
    let items: [DeviceApplicationUsageReportItemRequest]
}

private actor DeviceApplicationUsageReportServiceSpy: DeviceApplicationUsageReportServicing {
    private var calls: [DeviceApplicationUsageReportCall] = []
    private var results: [Result<DeviceApplicationUsageReportResponse, Error>]

    init(
        results: [Result<DeviceApplicationUsageReportResponse, Error>] = [
            .success(DeviceApplicationUsageReportResponse(lockedPackages: [], stats: []))
        ]
    ) {
        self.results = results
    }

    func reportUsage(
        dsn: String,
        items: [DeviceApplicationUsageReportItemRequest]
    ) async throws -> DeviceApplicationUsageReportResponse {
        calls.append(DeviceApplicationUsageReportCall(dsn: dsn, items: items))

        if results.count > 1 {
            return try results.removeFirst().get()
        }

        return try results.first?.get() ?? DeviceApplicationUsageReportResponse(lockedPackages: [], stats: [])
    }

    func recordedCalls() -> [DeviceApplicationUsageReportCall] {
        calls
    }
}

private func waitForRemovalAttemptCallCount(
    _ service: DeviceApplicationRemovalAttemptServiceSpy,
    count: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        let currentCount = await service.recordedCalls().count
        if currentCount >= count {
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    // Fail at the wait site rather than returning silently — a silent timeout turns the real
    // problem into a misleading downstream assertion failure.
    let observed = await service.recordedCalls().count
    XCTFail("Timed out waiting for \(count) removal-attempt call(s); observed \(observed).", file: file, line: line)
}

private func waitForRefreshRequestCount(
    _ spy: RefreshRequestDataSpy,
    count: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

    while DispatchTime.now().uptimeNanoseconds < deadline {
        let currentCount = await spy.recordedRequests().count
        if currentCount >= count {
            return
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let observed = await spy.recordedRequests().count
    XCTFail("Timed out waiting for \(count) refresh request(s); observed \(observed).", file: file, line: line)
}

/// Regression coverage for the `POST /device/apps/usage` response contract: the live backend can
/// send a sparse/null payload (proven by Android's nullable UsageReportResponse), so decoding must
/// never throw — a throw would fail the batch, retry the same delta forever, and starve enforcement.
final class DeviceApplicationUsageReportDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> DeviceApplicationUsageReportResponse {
        try JSONDecoder().decode(DeviceApplicationUsageReportResponse.self, from: Data(json.utf8))
    }

    func testDecodesEmptyObjectToEmptyEnforcementStateWithoutThrowing() throws {
        let response = try decode("{}")
        XCTAssertEqual(response.lockedPackages, [])
        XCTAssertEqual(response.stats, [])
    }

    func testDecodesExplicitNullTopLevelFieldsToEmpty() throws {
        let response = try decode(#"{"lockedPackages": null, "stats": null}"#)
        XCTAssertEqual(response.lockedPackages, [])
        XCTAssertEqual(response.stats, [])
    }

    func testDecodesSparseStatWithMissingOptionalFields() throws {
        let response = try decode(#"{"lockedPackages":["com.x"],"stats":[{"packageName":"com.x","isLimitReached":true}]}"#)
        XCTAssertEqual(response.lockedPackages, ["com.x"])
        XCTAssertEqual(response.stats.count, 1)
        let stat = response.stats[0]
        XCTAssertEqual(stat.packageName, "com.x")
        XCTAssertNil(stat.usageDate)
        XCTAssertEqual(stat.usedSeconds, 0)
        XCTAssertNil(stat.dailyLimitSeconds)
        XCTAssertTrue(stat.isLimitReached)
    }

    func testDecodesFullCamelCasePayload() throws {
        let response = try decode(#"{"lockedPackages":["a"],"stats":[{"packageName":"com.y","usageDate":"2026-07-17","usedSeconds":120,"dailyLimitSeconds":3600,"remainingSeconds":3480,"isLimitReached":false}]}"#)
        let stat = response.stats[0]
        XCTAssertEqual(stat.usageDate, "2026-07-17")
        XCTAssertEqual(stat.usedSeconds, 120)
        XCTAssertEqual(stat.dailyLimitSeconds, 3600)
        XCTAssertEqual(stat.remainingSeconds, 3480)
        XCTAssertFalse(stat.isLimitReached)
    }
}

/// Regression coverage for the `GET /device/lock/state` global-lock parse. The critical invariant:
/// an unrecognized 200 shape resolves to nil (unknown) — NEVER false — so the telemetry layer keeps
/// the last-known lock and can never silently release an active parental lock (fail closed).
final class OilaLockStateParsingTests: XCTestCase {
    func testReadsCommonFlatBooleanKeys() {
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["isLocked": true]), true)
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["locked": false]), false)
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["globalLock": true]), true)
    }

    func testReadsEnabledKeyUsedByTheSiblingManualLockDto() {
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["enabled": true]), true)
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["enabled": false]), false)
    }

    func testReadsStateString() {
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["state": "locked"]), true)
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["state": "unlocked"]), false)
    }

    func testReadsNestedGlobalObject() {
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["global": ["enabled": true]]), true)
        XCTAssertEqual(OilaDeviceClient.parseGlobalLock(from: ["global": ["isLocked": false]]), false)
    }

    func testUnrecognizedShapeReturnsNilSoCallerFailsClosed() {
        XCTAssertNil(OilaDeviceClient.parseGlobalLock(from: [:]))
        XCTAssertNil(OilaDeviceClient.parseGlobalLock(from: ["somethingElse": 42]))
        XCTAssertNil(OilaDeviceClient.parseGlobalLock(from: ["state": "weird"]))
    }
}

import ManagedSettings
import XCTest
@testable import SmartOilaKids

@MainActor
final class DeviceAppLimitMonitorControllerTests: XCTestCase {
    private var selectionStore: DeviceAppLockSelectionStore!
    private var selectionSuiteName: String!
    private var sharedStore: DeviceAppLimitSharedStore!
    private var sharedSuiteName: String!

    override func setUp() {
        super.setUp()

        selectionSuiteName = "DeviceAppLimitMonitorControllerTests.selection.\(UUID().uuidString)"
        let selectionDefaults = UserDefaults(suiteName: selectionSuiteName)!
        selectionDefaults.removePersistentDomain(forName: selectionSuiteName)
        selectionStore = DeviceAppLockSelectionStore(
            userDefaults: selectionDefaults,
            syncUpdate: { _, _ in }
        )
        selectionStore.activate(dsn: nil)
        selectionStore.clearSelection()

        sharedSuiteName = "DeviceAppLimitMonitorControllerTests.shared.\(UUID().uuidString)"
        let sharedDefaults = UserDefaults(suiteName: sharedSuiteName)!
        sharedDefaults.removePersistentDomain(forName: sharedSuiteName)
        sharedStore = DeviceAppLimitSharedStore(userDefaults: sharedDefaults)
    }

    override func tearDown() {
        selectionStore.activate(dsn: nil)
        selectionStore.clearSelection()
        UserDefaults(suiteName: selectionSuiteName)?.removePersistentDomain(forName: selectionSuiteName)
        UserDefaults(suiteName: sharedSuiteName)?.removePersistentDomain(forName: sharedSuiteName)

        selectionStore = nil
        selectionSuiteName = nil
        sharedStore = nil
        sharedSuiteName = nil
        super.tearDown()
    }

    func testActivateWithoutAuthorizationPublishesNotAuthorizedWithoutFetching() async {
        let service = DeviceAppLimitServiceSpy()
        var clearShieldCount = 0

        let controller = makeController(
            service: service,
            authorizationStatus: { .denied },
            clearShield: { clearShieldCount += 1 }
        )

        controller.activate(dsn: "  child-auth  ")
        await drainTasks()

        XCTAssertEqual(service.requests, [])
        XCTAssertEqual(controller.presentationState.status, "not_authorized")
        XCTAssertEqual(controller.presentationState.dsn, "child-auth")
        XCTAssertEqual(controller.presentationState.endpoint, "-")
        XCTAssertTrue(controller.presentationState.items.isEmpty)
        XCTAssertEqual(controller.presentationState.lastError, "-")
        XCTAssertGreaterThanOrEqual(clearShieldCount, 2)
    }

    func testActivateWithNoEnabledLimitsPublishesNoLimits() async {
        let noLimitsResult = DeviceAppLimitFetchResult(
            deviceID: 7,
            endpoint: "members/device/v2/7/applications?is_limit_enabled=true",
            limits: [
                makeLimit(packageName: "com.example.disabled", minutes: 15, enabled: false, reached: false),
                makeLimit(packageName: "com.example.zero", minutes: 0, enabled: true, reached: false)
            ]
        )
        let service = DeviceAppLimitServiceSpy(
            results: [.success(noLimitsResult), .success(noLimitsResult)]
        )

        let controller = makeController(service: service)

        controller.activate(dsn: "child-no-limits")
        await drainTasks()
        if controller.presentationState.status == "idle" {
            await controller.refreshNow()
        }

        XCTAssertFalse(service.requests.isEmpty)
        XCTAssertTrue(service.requests.allSatisfy { $0 == "child-no-limits" })
        XCTAssertEqual(controller.presentationState.status, "no_limits")
        XCTAssertEqual(controller.presentationState.dsn, "child-no-limits")
        XCTAssertEqual(controller.presentationState.endpoint, "members/device/v2/7/applications?is_limit_enabled=true")
        XCTAssertEqual(controller.presentationState.remoteLimitCount, 0)
        XCTAssertEqual(controller.presentationState.matchedLimitCount, 0)
        XCTAssertEqual(controller.presentationState.reachedLimitCount, 0)
        XCTAssertTrue(controller.presentationState.items.isEmpty)
    }

    func testActivateWithNoMatchingConfigurationsPublishesNoMatches() async {
        let service = DeviceAppLimitServiceSpy(
            results: [.success(DeviceAppLimitFetchResult(
                deviceID: 8,
                endpoint: "members/device/v2/8/applications?is_limit_enabled=true",
                limits: [makeLimit(packageName: "com.example.app", minutes: 15, enabled: true, reached: false)]
            ))]
        )

        let controller = makeController(
            service: service,
            matchedConfigurationsFromLimits: { _ in [] }
        )

        controller.activate(dsn: "child-no-matches")
        await drainTasks()

        XCTAssertEqual(controller.presentationState.status, "no_matches")
        XCTAssertEqual(controller.presentationState.dsn, "child-no-matches")
        XCTAssertEqual(controller.presentationState.remoteLimitCount, 1)
        XCTAssertEqual(controller.presentationState.matchedLimitCount, 0)
        XCTAssertEqual(controller.presentationState.reachedLimitCount, 0)
        XCTAssertTrue(controller.presentationState.items.isEmpty)
    }

    func testSuccessfulRefreshStartsMonitoringSavesSnapshotAndReportsRecovery() async throws {
        let configuration = DeviceAppLimitConfiguration(
            packageName: "com.example.app",
            appName: "Example App",
            applicationToken: try makeToken("AQ=="),
            dailyLimitMinutes: 15
        )
        let result = DeviceAppLimitFetchResult(
            deviceID: 9,
            endpoint: "members/device/v2/9/applications?is_limit_enabled=true",
            limits: [makeLimit(packageName: "com.example.app", minutes: 15, enabled: true, reached: true)]
        )
        let service = DeviceAppLimitServiceSpy(results: [.success(result), .success(result)])

        var startedMonitoring: [(String, [DeviceAppLimitConfiguration])] = []
        var appliedShieldSnapshots: [DeviceAppLimitSnapshot] = []
        var recoverySnapshots: [DeviceAppLimitSnapshot] = []

        let controller = makeController(
            service: service,
            matchedConfigurationsFromLimits: { _ in [configuration] },
            startMonitoring: { dsn, configurations in
                startedMonitoring.append((dsn, configurations))
            },
            applyShield: { snapshot in
                appliedShieldSnapshots.append(snapshot)
            },
            clearShield: {},
            reportRecovery: { snapshot in
                recoverySnapshots.append(snapshot)
            }
        )

        controller.activate(dsn: "child-good")
        await drainTasks()
        controller.armForegroundRecoveryCheck()
        await controller.refreshNow()

        let snapshot = try XCTUnwrap(sharedStore.loadSnapshot(dsn: "child-good"))

        XCTAssertEqual(service.requests, ["child-good", "child-good"])
        XCTAssertEqual(startedMonitoring.map(\.0), ["child-good"])
        XCTAssertEqual(startedMonitoring.first?.1, [configuration])
        XCTAssertEqual(appliedShieldSnapshots.map(\.dsn), ["child-good", "child-good"])
        XCTAssertEqual(recoverySnapshots.count, 1)
        XCTAssertEqual(recoverySnapshots.first?.reachedPackageNames, ["com.example.app"])
        XCTAssertEqual(snapshot.configurations, [configuration])
        XCTAssertEqual(snapshot.reachedPackageNames, ["com.example.app"])
        XCTAssertEqual(controller.presentationState.status, "monitoring")
        XCTAssertEqual(controller.presentationState.endpoint, result.endpoint)
        XCTAssertEqual(controller.presentationState.matchedLimitCount, 1)
        XCTAssertEqual(controller.presentationState.reachedLimitCount, 1)
        XCTAssertEqual(controller.presentationState.items.map(\.appName), ["Example App"])
        XCTAssertTrue(controller.presentationState.items.allSatisfy(\.isLimitReached))
    }

    func testFetchFailureWithoutSnapshotPublishesFailedState() async {
        let service = DeviceAppLimitServiceSpy(
            results: [.failure(TestDeviceAppLimitError.expected), .failure(TestDeviceAppLimitError.expected)]
        )
        let controller = makeController(service: service)

        controller.activate(dsn: "child-fail")
        await controller.refreshNow()

        XCTAssertEqual(service.requests, ["child-fail", "child-fail"])
        XCTAssertEqual(controller.presentationState.status, "failed")
        XCTAssertEqual(controller.presentationState.dsn, "child-fail")
        XCTAssertEqual(controller.presentationState.endpoint, "-")
        XCTAssertEqual(controller.presentationState.lastError, TestDeviceAppLimitError.expected.localizedDescription)
        XCTAssertTrue(controller.presentationState.items.isEmpty)
    }

    private func makeController(
        service: DeviceAppLimitServicing? = nil,
        authorizationStatus: DeviceAppLimitMonitorController.AuthorizationStatusAction? = nil,
        usedTime: DeviceAppLimitMonitorController.UsedTimeAction? = nil,
        matchedConfigurationsFromLimits: DeviceAppLimitMonitorController.MatchedConfigurationsAction? = nil,
        startMonitoring: DeviceAppLimitMonitorController.MonitorStartAction? = nil,
        stopMonitoring: DeviceAppLimitMonitorController.MonitorStopAction? = nil,
        applyShield: DeviceAppLimitMonitorController.SnapshotAction? = nil,
        clearShield: (() -> Void)? = nil,
        reportRecovery: DeviceAppLimitMonitorController.SnapshotAction? = nil
    ) -> DeviceAppLimitMonitorController {
        DeviceAppLimitMonitorController(
            service: service ?? DeviceAppLimitServiceSpy(),
            selectionStore: selectionStore,
            sharedStore: sharedStore,
            authorizationStatus: authorizationStatus ?? { .granted },
            usedTime: usedTime ?? { _, _ in 0 },
            matchedConfigurationsFromLimits: matchedConfigurationsFromLimits,
            startMonitoring: startMonitoring ?? { _, _ in },
            stopMonitoring: stopMonitoring ?? { _ in },
            applyShield: applyShield ?? { _ in },
            clearShield: clearShield ?? {},
            reportRecovery: reportRecovery ?? { _ in }
        )
    }

    private func makeLimit(
        packageName: String,
        minutes: Int,
        enabled: Bool,
        reached: Bool
    ) -> DeviceAppLimitResponse {
        DeviceAppLimitResponse(
            packageName: packageName,
            dailyLimitMinutes: minutes,
            isLimitEnabled: enabled,
            usedTodaySeconds: reached ? max(1, minutes * 60) : 0,
            remainingTodaySeconds: reached ? 0 : max(0, minutes * 60),
            isLimitReached: reached
        )
    }

    private func makeToken(_ base64Data: String) throws -> ApplicationToken {
        let payload = #"{"data":"\#(base64Data)"}"#
        return try JSONDecoder().decode(ApplicationToken.self, from: Data(payload.utf8))
    }

    private func drainTasks(count: Int = 6) async {
        for _ in 0..<count {
            await Task.yield()
        }
    }
}

private enum TestDeviceAppLimitError: LocalizedError {
    case expected
    case missingResult

    var errorDescription: String? {
        switch self {
        case .expected:
            return "Expected app limit failure"
        case .missingResult:
            return "Missing app limit test result"
        }
    }
}

private final class DeviceAppLimitServiceSpy: DeviceAppLimitServicing {
    var requests: [String] = []
    private var results: [Result<DeviceAppLimitFetchResult, Error>]

    init(results: [Result<DeviceAppLimitFetchResult, Error>] = []) {
        self.results = results
    }

    func fetchLimits(dsn: String) async throws -> DeviceAppLimitFetchResult {
        requests.append(dsn)
        guard !results.isEmpty else {
            throw TestDeviceAppLimitError.missingResult
        }
        return try results.removeFirst().get()
    }
}

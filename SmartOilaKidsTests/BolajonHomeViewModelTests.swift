import XCTest
@testable import SmartOilaKids

/// Covers the Bolajon360 Home SOS path: `sendSOS()` must attach the latest known location +
/// battery from telemetry, and still succeed when location/battery are unavailable.
@MainActor
final class BolajonHomeViewModelTests: XCTestCase {
    func testSendSOSAttachesLatestLocationAndBatteryFromTelemetry() async {
        let service = SOSServiceSpy()
        let telemetry = StubSOSTelemetry(
            context: OilaSOSContext(lat: 41.311081, lng: 69.240562, accuracy: 12.5, batteryPercent: 76)
        )
        let viewModel = BolajonHomeViewModel(service: service, telemetry: telemetry)

        await viewModel.sendSOS()

        XCTAssertEqual(service.sosCalls.count, 1)
        let call = service.sosCalls[0]
        XCTAssertEqual(call.lat, 41.311081)
        XCTAssertEqual(call.lng, 69.240562)
        XCTAssertEqual(call.accuracy, 12.5)
        XCTAssertEqual(call.batteryLevel, 76)   // 0–100 percent as a Double, matching /device/status
        XCTAssertTrue(viewModel.sosSent)
    }

    func testSendSOSStillSendsWhenLocationAndBatteryUnavailable() async {
        let service = SOSServiceSpy()
        let telemetry = StubSOSTelemetry(
            context: OilaSOSContext(lat: nil, lng: nil, accuracy: nil, batteryPercent: nil)
        )
        let viewModel = BolajonHomeViewModel(service: service, telemetry: telemetry)

        await viewModel.sendSOS()

        XCTAssertEqual(service.sosCalls.count, 1)
        let call = service.sosCalls[0]
        XCTAssertNil(call.lat)
        XCTAssertNil(call.lng)
        XCTAssertNil(call.accuracy)
        XCTAssertNil(call.batteryLevel)
        XCTAssertTrue(viewModel.sosSent)
    }

    func testSendSOSDoesNotMarkSentWhenServiceFails() async {
        let service = SOSServiceSpy()
        service.sendSOSError = NetworkError.invalidURL
        let telemetry = StubSOSTelemetry(
            context: OilaSOSContext(lat: 1, lng: 2, accuracy: 3, batteryPercent: 50)
        )
        let viewModel = BolajonHomeViewModel(service: service, telemetry: telemetry)

        await viewModel.sendSOS()

        XCTAssertEqual(service.sosCalls.count, 1)
        XCTAssertFalse(viewModel.sosSent)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testScreenTimeCardHiddenWhenNoLocalUsageData() async {
        let viewModel = BolajonHomeViewModel(
            service: SOSServiceSpy(),
            telemetry: StubSOSTelemetry(context: OilaSOSContext(lat: nil, lng: nil, accuracy: nil, batteryPercent: nil)),
            screenTimeUsage: StubScreenTimeUsage(seconds: nil)
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.showsScreenTimeCard)
        XCTAssertNil(viewModel.trackedUsageSeconds)
    }

    func testScreenTimeCardShowsRealUsageWhenAvailable() async {
        let viewModel = BolajonHomeViewModel(
            service: SOSServiceSpy(),
            telemetry: StubSOSTelemetry(context: OilaSOSContext(lat: nil, lng: nil, accuracy: nil, batteryPercent: nil)),
            screenTimeUsage: StubScreenTimeUsage(seconds: 3900)   // 65 min
        )

        await viewModel.load()

        XCTAssertTrue(viewModel.showsScreenTimeCard)
        XCTAssertEqual(viewModel.trackedUsageSeconds, 3900)
        XCTAssertEqual(viewModel.trackedUsageMinutes, 65)
    }
}

private struct StubSOSTelemetry: SOSTelemetryProviding {
    let context: OilaSOSContext
    func currentSOSContext() -> OilaSOSContext { context }
}

private struct StubScreenTimeUsage: ScreenTimeUsageProviding {
    let seconds: Int?
    func todayTrackedUsageSeconds() -> Int? { seconds }
}

/// Records SOS calls; every other `OilaDeviceServicing` method is an unused stub.
private final class SOSServiceSpy: OilaDeviceServicing {
    private struct Unimplemented: Error {}

    private(set) var sosCalls: [(lat: Double?, lng: Double?, accuracy: Double?, batteryLevel: Double?)] = []
    var sendSOSError: Error?

    func sendSOS(lat: Double?, lng: Double?, accuracy: Double?, batteryLevel: Double?) async throws {
        sosCalls.append((lat, lng, accuracy, batteryLevel))
        if let sendSOSError { throw sendSOSError }
    }

    func pair(code: String) async throws -> OilaPairResult { throw Unimplemented() }
    func refreshSession() async throws {}
    func logout() async throws {}
    func requestOtp(phone: String) async throws {}
    func verifyOtp(phone: String, code: String) async throws -> OilaOtpResult { throw Unimplemented() }
    func telegramInit() async throws -> OilaTelegramSession { throw Unimplemented() }
    func telegramStatus(sessionId: String) async throws -> OilaTelegramStatus { throw Unimplemented() }
    func fetchActiveTasks() async throws -> [OilaDeviceTask] { [] }
    func fetchTasks() async throws -> [OilaDeviceTask] { [] }
    func completeTask(id: String) async throws {}
    func updateFCMToken(_ token: String) async throws {}
    func uploadLocationBatch(_ fixes: [OilaLocationFix]) async throws {}
    func postDeviceStatus(_ status: OilaDeviceStatus) async throws {}
    func fetchLockState() async throws -> OilaLockState { throw Unimplemented() }
    func reportRemovalAttempt(packageName: String, applicationName: String) async throws {}
    func completeRecording(recordingID: String, fileURL: URL, durationSeconds: Int?) async throws -> [String: Any] { [:] }
}

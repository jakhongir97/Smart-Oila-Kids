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

        // A panic button retries transient failures before giving up (3 attempts), then surfaces
        // an explicit failure state — it must never fail silently.
        XCTAssertEqual(service.sosCalls.count, 3)
        XCTAssertFalse(viewModel.sosSent)
        XCTAssertTrue(viewModel.sosFailed)
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
    var fetchTasksError: Error?
    var fetchTasksResult: [OilaDeviceTask] = []
    private(set) var fetchTasksCallCount = 0
    var completeTaskError: Error?
    private(set) var completeTaskCalls: [String] = []

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
    func fetchTasks() async throws -> [OilaDeviceTask] {
        fetchTasksCallCount += 1
        if let fetchTasksError { throw fetchTasksError }
        return fetchTasksResult
    }
    func completeTask(id: String) async throws {
        completeTaskCalls.append(id)
        if let completeTaskError { throw completeTaskError }
    }
    func updateFCMToken(_ token: String) async throws {}
    func uploadLocationBatch(_ fixes: [OilaLocationFix]) async throws {}
    func postDeviceStatus(_ status: OilaDeviceStatus) async throws {}
    func fetchLockState() async throws -> OilaLockState { throw Unimplemented() }
    func reportRemovalAttempt(packageName: String, applicationName: String) async throws {}
    func completeRecording(recordingID: String, fileURL: URL, durationSeconds: Int?) async throws -> [String: Any] { [:] }
}

/// Covers the Bolajon360 Tasks surface (`BolajonTasksViewModel`): a failed load/complete must
/// surface an error (never masquerade as an empty list or fail silently), and a successful reload
/// must clear a stale error.
@MainActor
final class BolajonTasksViewModelTests: XCTestCase {
    private func sampleTask(id: String = "t1") -> OilaDeviceTask {
        OilaDeviceTask(id: id, title: "Test", status: "Active", rewardPoints: 5,
                       emoji: nil, dueAt: nil, completedAt: nil)
    }

    func testLoadFailureSetsErrorAndKeepsListEmpty() async {
        let service = SOSServiceSpy()
        service.fetchTasksError = NetworkError.invalidURL
        let viewModel = BolajonTasksViewModel(service: service)

        await viewModel.load()

        XCTAssertTrue(viewModel.tasks.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testSuccessfulReloadClearsStaleError() async {
        let service = SOSServiceSpy()
        service.fetchTasksError = NetworkError.invalidURL
        let viewModel = BolajonTasksViewModel(service: service)
        await viewModel.load()
        XCTAssertNotNil(viewModel.errorMessage)

        // A later successful fetch must clear the stale error, not leave it stuck on screen.
        service.fetchTasksError = nil
        service.fetchTasksResult = [sampleTask()]
        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.tasks.count, 1)
    }

    func testCompleteFailureSurfacesError() async {
        let service = SOSServiceSpy()
        service.completeTaskError = NetworkError.invalidURL
        let viewModel = BolajonTasksViewModel(service: service)

        await viewModel.complete(sampleTask())

        XCTAssertEqual(service.completeTaskCalls, ["t1"])
        XCTAssertNotNil(viewModel.errorMessage)
    }
}

/// Uzbek Latin → Cyrillic transliteration (used for the `uz-cyrl` language). The result is
/// memoized, so this also guards that caching stays correct and deterministic.
final class UzbekCyrillicTransliterationTests: XCTestCase {
    func testTransliteratesLatinToCyrillic() {
        XCTAssertEqual(UzbekCyrillic.transliterate("salom"), "салом")
        // Digraphs and the o'/g' pairs resolve before single letters.
        XCTAssertEqual(UzbekCyrillic.transliterate("O'zbekcha"), "Ўзбекча")
        XCTAssertEqual(UzbekCyrillic.transliterate("shakar"), "шакар")
    }

    func testRepeatedCallsAreDeterministic() {
        let input = "Bolajon o'yini"
        let first = UzbekCyrillic.transliterate(input)
        let second = UzbekCyrillic.transliterate(input)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, input)
    }
}

/// The push-recording pipeline must never orphan the child's plaintext environment audio in tmp/:
/// the temp file is deleted whether the upload succeeds, fails, or throws.
@MainActor
final class OilaRecordingTriggerServiceTempCleanupTests: XCTestCase {
    private struct UploadFailed: Error {}

    private func makeTempAudioFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audio-\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: url.path, contents: Data("audio".utf8))
        return url
    }

    private func command(_ id: String) -> PushRecordingCommand {
        PushRecordingCommand(recordingID: id, type: .audio, durationSeconds: 1, cameraType: nil)
    }

    func testTempAudioIsDeletedWhenUploadFails() async {
        let tmp = makeTempAudioFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))

        let service = OilaRecordingTriggerService(
            recordAudioAction: { _, _ in tmp },
            uploadAction: { _, _, _ in throw UploadFailed() }
        )
        service.start(dsn: "child-1")

        await service.handleCommand(command("r1"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testTempAudioIsDeletedAfterSuccessfulUpload() async {
        let tmp = makeTempAudioFile()
        let service = OilaRecordingTriggerService(
            recordAudioAction: { _, _ in tmp },
            uploadAction: { _, _, _ in }
        )
        service.start(dsn: "child-1")

        await service.handleCommand(command("r2"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }
}

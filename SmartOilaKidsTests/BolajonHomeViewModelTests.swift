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

private final class StubSOSTelemetry: SOSTelemetryProviding {
    let context: OilaSOSContext
    /// Contexts handed to the durable outbox after every in-flight attempt failed.
    private(set) var enqueued: [OilaSOSContext] = []

    init(context: OilaSOSContext) {
        self.context = context
    }

    func currentSOSContext() -> OilaSOSContext { context }
    func enqueueUndeliveredSOS(_ context: OilaSOSContext) { enqueued.append(context) }
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
    func reportAppUsage(items: [DeviceApplicationUsageReportItemRequest]) async throws -> DeviceApplicationUsageReportResponse {
        DeviceApplicationUsageReportResponse(lockedPackages: [], stats: [])
    }
    func fetchLockState() async throws -> OilaLockState { throw Unimplemented() }
    func reportRemovalAttempt(packageName: String, applicationName: String) async throws {}
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
    /// Proper nouns have no Cyrillic spelling. Before this, a Cyrillic-Uzbek family read "Оила360",
    /// "иОС" and "Болажон360 · в1.0" -- the product's own name, phonetically mangled.
    func testProperNounsSurviveTransliteration() {
        let cases = [
            "Oila360": "Oila360",
            "Bolajon360 \u{00B7} v1.1": "Bolajon360 \u{00B7} v1.1",
            // The real string: the number is appended at runtime, so the "v" is trailing.
            "Bolajon360 \u{00B7} v": "Bolajon360 \u{00B7} v",
            "iOS": "iOS",
            "iPhone": "iPhone",
            "Screen Time": "Screen Time",
            "App Store": "App Store",
            "Wi-Fi": "Wi-Fi",
            "SOS": "SOS",
        ]
        for (input, expected) in cases {
            XCTAssertEqual(UzbekCyrillic.transliterate(input), expected, "\(input) must not be transliterated")
        }
    }

    /// The protection must stay narrow: ordinary Uzbek still has to convert, including a sentence
    /// that CONTAINS a protected name.
    func testOrdinaryWordsStillTransliterateAroundAProtectedName() {
        let result = UzbekCyrillic.transliterate("Oila360 ilovasini oching")
        XCTAssertTrue(result.hasPrefix("Oila360 "), "the name is verbatim: \(result)")
        XCTAssertTrue(result.contains("илова"), "the Uzbek around it still converts: \(result)")
        XCTAssertFalse(result.contains("ilovasini"), "no Latin left over: \(result)")
    }

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

    func testPreservesFormatSpecifiers() {
        // The conversion letter of a %-specifier must survive so a String(format:) applied AFTER
        // transliteration still works (previously %d became %д and the value was dropped).
        let format = UzbekCyrillic.transliterate("Qayta urinish %d daqiqadan so'ng")
        XCTAssertTrue(format.contains("%d"), "expected %d to survive, got: \(format)")
        XCTAssertEqual(String(format: format, 5), format.replacingOccurrences(of: "%d", with: "5"))
        // Positional / object specifiers survive too.
        XCTAssertTrue(UzbekCyrillic.transliterate("Ilova: %@").contains("%@"))
        XCTAssertTrue(UzbekCyrillic.transliterate("%1$@ va %2$@").contains("%1$@"))
    }

    func testWordInitialEUsesCyrillicE() {
        // Word-initial "e" is "э" in Uzbek Cyrillic; elsewhere it is "е".
        XCTAssertEqual(UzbekCyrillic.transliterate("Ertalab"), "Эрталаб")
        XCTAssertEqual(UzbekCyrillic.transliterate("eshik"), "эшик")
        // Non-word-initial "e" stays "е".
        XCTAssertEqual(UzbekCyrillic.transliterate("men"), "мен")
    }
}


/// The two chat read-receipt predicates. Each has already shipped a bug once, and neither had a test.
@MainActor
final class ChatReadReceiptPredicateTests: XCTestCase {
    /// A plain `contains("read")` also fires on "unread" and "thread", so `chat.unread_count` and
    /// `thread.updated` were treated as read receipts — and, combined with the parse bug below,
    /// marked the child's entire thread as read by the parent.
    func testOnlyGenuineReadEventsCount() {
        for event in ["chat.read", "chat:read", "message_read", "READ", "chat read"] {
            XCTAssertTrue(BolajonChatViewModel.isReadReceiptEvent(event), "\(event) is a read receipt")
        }
        for event in ["chat.unread_count", "thread.updated", "unread", "thread", "chat.readiness"] {
            XCTAssertFalse(BolajonChatViewModel.isReadReceiptEvent(event), "\(event) is NOT a read receipt")
        }
    }

    /// The backend emits fractional-second timestamps. A default ISO8601DateFormatter rejects those,
    /// which made every `readAt` fall through to "now" — the whole thread instantly ✓✓.
    func testFractionalAndPlainTimestampsBothParse() {
        XCTAssertNotNil(BolajonChatViewModel.parseISO("2026-07-26T09:15:02.418Z"),
                        "fractional seconds are what the backend actually sends")
        XCTAssertNotNil(BolajonChatViewModel.parseISO("2026-07-26T09:15:02Z"),
                        "and payloads that omit milliseconds must still parse")
        XCTAssertNil(BolajonChatViewModel.parseISO("not a date"))
        XCTAssertNil(BolajonChatViewModel.parseISO(nil))
        XCTAssertNil(BolajonChatViewModel.parseISO("  "))
        XCTAssertEqual(
            BolajonChatViewModel.parseISO("2026-07-26T09:15:02.418Z"),
            BolajonChatViewModel.parseISO("2026-07-26T09:15:02.418Z"),
            "and it is deterministic — the two formatters are separate immutable instances on purpose"
        )
    }
}

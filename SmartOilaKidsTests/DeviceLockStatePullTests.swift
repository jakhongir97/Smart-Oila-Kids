import XCTest
@testable import SmartOilaKids

/// Build 29: the schedule-monitor extension pulls `GET /device/lock/state` itself, on every
/// device-total usage step and on the heartbeat (lock-delivery-silent-push-only,
/// ext-pull-lock-on-usage-rung, early-unlock-missed-stays-locked, parent-unpair-while-locked).
/// Everything the extension decides lives in `DeviceLockStatePull`, driven here through a fake
/// transport, a fake clock and a throwaway App Group suite.
final class DeviceLockStatePullTests: XCTestCase {
    /// The phone's clocks, moved by hand.
    final class Clocks: @unchecked Sendable {
        var wall: Date
        var monotonic: UInt64 = 5_000_000_000_000
        init(_ wall: Date) { self.wall = wall }
        func advance(_ seconds: TimeInterval) {
            wall = wall.addingTimeInterval(seconds)
            monotonic += UInt64(seconds * 1_000_000_000)
        }
        var clock: DeviceLockClock {
            DeviceLockClock(wallNow: { self.wall }, monotonicNanos: { self.monotonic }, bootSessionID: { "boot-1" })
        }
    }

    /// The server, scripted: each request takes the next answer (the last one repeats).
    final class Server: @unchecked Sendable {
        var answers: [DeviceLockStatePull.Answer]
        private(set) var requests: [URLRequest] = []
        init(_ answers: [DeviceLockStatePull.Answer]) { self.answers = answers }
        func answer(_ request: URLRequest) -> DeviceLockStatePull.Answer {
            requests.append(request)
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }

    final class Teardown: @unchecked Sendable {
        var released = 0, stopped = 0, announced = 0, releasedPerApp = 0
        var actions: DeviceLockUnpairTeardown.Actions {
            DeviceLockUnpairTeardown.Actions(
                releaseWholeDevice: { self.released += 1 },
                stopEdgesAndHeartbeat: { self.stopped += 1 },
                announce: { self.announced += 1 },
                releasePerAppAndRemovalProtection: { self.releasedPerApp += 1 }
            )
        }
    }

    /// What the app has published in the shared Keychain item, as the pull re-reads it after the
    /// answer: by default the credential the request itself carried (the pairing is unchanged).
    static func publishedCredential(of server: Server) -> LocationPushSharedCredential.Payload? {
        guard let bearer = server.requests.last?.value(forHTTPHeaderField: "Authorization"),
              bearer.hasPrefix("Bearer ") else { return nil }
        return LocationPushSharedCredential.Payload(
            accessToken: String(bearer.dropFirst("Bearer ".count)), baseURL: "https://api.example.test/api/v1",
            dsn: nil, updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private var suiteNames: [String] = []
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private lazy var clocks = Clocks(t0)
    private lazy var defaults: UserDefaults = {
        let name = "DeviceLockStatePullTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }()
    private lazy var store = DeviceLockPolicySharedStore(userDefaults: defaults)
    private let teardown = Teardown()

    override func tearDown() {
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func credential(
        updatedAt: Date? = nil, dsn: String? = "8D905F9F-770B-4D36-B41E-E34FD6D46B17", accessToken: String = "device-token"
    ) -> LocationPushSharedCredential.Payload {
        LocationPushSharedCredential.Payload(
            accessToken: accessToken, baseURL: "https://api.example.test/api/v1", dsn: dsn,
            updatedAt: updatedAt ?? t0.addingTimeInterval(-3_600)
        )
    }

    private func environment(_ server: Server) -> DeviceLockStatePull.Environment {
        DeviceLockStatePull.Environment(
            store: store, userDefaults: defaults, clock: clocks.clock,
            transport: { request, _ in server.answer(request) }, teardown: teardown.actions,
            currentCredential: { Self.publishedCredential(of: server) }
        )
    }

    private func run(_ server: Server, credential: LocationPushSharedCredential.Payload? = nil) -> DeviceLockStatePull.Outcome {
        DeviceLockStatePull.run(credential: credential ?? self.credential(), fallbackDSN: nil, environment: environment(server))
    }

    private static let iso = ISO8601DateFormatter()

    /// A current backend's 200, in its envelope.
    private func ok(manualLock: (Date, Date)?, serverTime: Date? = nil) -> DeviceLockStatePull.Answer {
        let window: Any = manualLock.map { ["startsAt": Self.iso.string(from: $0.0), "endsAt": Self.iso.string(from: $0.1)] } ?? NSNull()
        let data: [String: Any] = [
            "isLocked": manualLock != nil, "manualLockEnabled": manualLock != nil, "manualLock": window,
            "serverTime": Self.iso.string(from: serverTime ?? clocks.wall), "scheduleLocked": false,
            "activeSchedule": NSNull(), "lockedPackages": [], "appLimits": [], "schedules": []
        ]
        return envelope(200, ["success": true, "data": data])
    }

    private func envelope(_ status: Int, _ json: [String: Any]) -> DeviceLockStatePull.Answer {
        .http(status: status, body: try! JSONSerialization.data(withJSONObject: json))
    }

    private var unpaired: DeviceLockStatePull.Answer {
        envelope(401, ["success": false, "message": "Device unpaired", "errorCode": "DEVICE_UNPAIRED"])
    }

    private func lockedNow() -> Bool {
        let snapshot = store.load()
        return DeviceLockPolicy.isLocked(at: clocks.wall, snapshot: snapshot, calendar: DeviceLockPolicy.ruleCalendar(for: snapshot, phone: .current))
    }

    // MARK: The pull

    func testAPullSavesTheLockTheSilentPushNeverDelivered() throws {
        let server = Server([ok(manualLock: (t0.addingTimeInterval(-60), t0.addingTimeInterval(900)))])
        XCTAssertFalse(lockedNow(), "nothing saved yet")

        XCTAssertEqual(run(server), .saved(changed: true))

        XCTAssertTrue(lockedNow(), "the caller re-evaluates this snapshot and writes the shield")
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/api/v1/device/lock/state")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-token")
        XCTAssertEqual(request.timeoutInterval, DeviceLockStatePull.requestTimeout)
        XCTAssertEqual(store.load()?.dsn, "8d905f9f-770b-4d36-b41e-e34fd6d46b17", "named like the app's edges")
    }

    func testAPullReleasesALockTheParentEndedEarly() {
        let server = Server([ok(manualLock: (t0.addingTimeInterval(-60), t0.addingTimeInterval(8 * 3_600)))])
        XCTAssertEqual(run(server), .saved(changed: true))
        XCTAssertTrue(lockedNow())

        // "Снять": the server now says no manual lock at all.
        clocks.advance(300)
        server.answers = [ok(manualLock: nil)]
        XCTAssertEqual(run(server), .saved(changed: true))
        XCTAssertFalse(lockedNow(), "released at the next step, not at the old end hours later")
    }

    func testTheSnapshotIsTheOneTheAppWouldHaveSaved() throws {
        let server = Server([ok(manualLock: (t0, t0.addingTimeInterval(600)))])
        XCTAssertEqual(run(server), .saved(changed: true))
        let saved = try XCTUnwrap(store.load())

        guard case let .http(_, body) = server.answers[0],
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = json["data"] as? [String: Any] else { return XCTFail("fixture") }
        let appSnapshot = OilaTelemetryService.lockPolicySnapshot(
            from: OilaDeviceClient.parseLockState(from: data), dsn: saved.dsn, anchor: try XCTUnwrap(saved.clock)
        )
        XCTAssertEqual(saved, appSnapshot)
        XCTAssertEqual(saved.clock?.offset ?? .nan, 0, accuracy: 0.001, "serverTime == the phone's wall clock here")
    }

    func testAtMostOnePullAMinute() {
        let server = Server([ok(manualLock: nil)])
        XCTAssertEqual(run(server), .saved(changed: true))
        clocks.advance(59)
        XCTAssertEqual(run(server), .skipped("rate_limited"))
        XCTAssertEqual(server.requests.count, 1)
        clocks.advance(2)
        XCTAssertEqual(run(server), .saved(changed: false), "same policy: nothing to re-arm")
        XCTAssertEqual(server.requests.count, 2)
    }

    func testAFailedPullStillCountsTowardsTheMinute() {
        let server = Server([.failed("timeout"), ok(manualLock: nil)])
        XCTAssertEqual(run(server), .failed("timeout"))
        clocks.advance(30)
        XCTAssertEqual(run(server), .skipped("rate_limited"), "a dead server is not asked on every step")
        clocks.advance(31)
        XCTAssertEqual(run(server), .saved(changed: true))
    }

    func testASnapshotTheAppJustReceivedMakesThePullRedundant() {
        // The running app polled 20 s ago.
        let appServer = Server([ok(manualLock: nil)])
        XCTAssertEqual(run(appServer), .saved(changed: true))
        defaults.removeObject(forKey: DeviceLockStatePull.lastAttemptKey)
        clocks.advance(20)
        let server = Server([ok(manualLock: nil)])
        XCTAssertEqual(run(server), .skipped("rate_limited"))
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testTheRateLimitIgnoresAClockWoundBack() {
        let now = t0
        XCTAssertTrue(DeviceLockStatePull.isRateLimited(now: now, lastAttempt: now.addingTimeInterval(-10), lastReceived: nil))
        XCTAssertTrue(DeviceLockStatePull.isRateLimited(now: now, lastAttempt: nil, lastReceived: now.addingTimeInterval(-59)))
        XCTAssertFalse(DeviceLockStatePull.isRateLimited(now: now, lastAttempt: now.addingTimeInterval(-60), lastReceived: nil))
        XCTAssertFalse(DeviceLockStatePull.isRateLimited(now: now, lastAttempt: now.addingTimeInterval(3_600), lastReceived: now.addingTimeInterval(86_400)),
                       "stamps in the future are a clock moved back, not a pull a moment ago")
        XCTAssertFalse(DeviceLockStatePull.isRateLimited(now: now, lastAttempt: nil, lastReceived: nil))
    }

    func testNoCredentialSendsNothing() {
        let server = Server([ok(manualLock: nil)])
        XCTAssertEqual(DeviceLockStatePull.run(credential: nil, fallbackDSN: "x", environment: environment(server)), .skipped("no_credential"))
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertNil(defaults.object(forKey: DeviceLockStatePull.lastAttemptKey), "and the minute is not spent")
    }

    func testAnUnreadableAnswerKeepsTheSavedLock() {
        let server = Server([ok(manualLock: (t0.addingTimeInterval(-60), t0.addingTimeInterval(900)))])
        XCTAssertEqual(run(server), .saved(changed: true))
        let before = store.load()
        for (answer, outcome) in [
            (envelope(200, ["success": true, "data": ["x": 1]]), DeviceLockStatePull.Outcome.unrecognized),
            (envelope(500, ["success": false]), .failed("http_500")),
            (envelope(200, ["success": false, "message": "nope"]), .failed("envelope_refused")),
            (envelope(401, ["success": false, "errorCode": "UNAUTHORIZED"]), .failed("http_401")),
            (DeviceLockStatePull.Answer.failed("offline"), .failed("offline"))
        ] {
            clocks.advance(61)
            server.answers = [answer]
            XCTAssertEqual(run(server), outcome)
            XCTAssertEqual(store.load(), before, "\(outcome) must neither lock nor unlock")
        }
        XCTAssertNil(defaults.object(forKey: DevicePairingRevocation.suspectedAtKey), "a refused token is not an unpair")
        XCTAssertEqual(teardown.released, 0)
    }

    // MARK: DEVICE_UNPAIRED

    func testTheSecondUnpairedAnswerReleasesTheLockAndLeavesTheAppItsRecord() {
        let server = Server([ok(manualLock: (t0.addingTimeInterval(-60), t0.addingTimeInterval(8 * 3_600)))])
        XCTAssertEqual(run(server), .saved(changed: true))

        clocks.advance(61)
        server.answers = [unpaired]
        XCTAssertEqual(run(server), .unpairedSuspected, "one answer could be a backend blip")
        XCTAssertNotNil(store.load(), "nothing torn down on a suspicion")
        XCTAssertEqual(teardown.released, 0)
        XCTAssertNil(DevicePairingRevocation.revokedAt(userDefaults: defaults))

        clocks.advance(61)
        XCTAssertEqual(run(server), .unpairedConfirmed)
        XCTAssertNil(store.load(), "the old family's policy is gone")
        XCTAssertFalse(lockedNow())
        XCTAssertEqual(teardown.released, 1, "the whole-device shield is written back to unlocked")
        XCTAssertEqual(teardown.releasedPerApp, 1, "final review: per-app shields and deletion protection go too")
        XCTAssertEqual(teardown.stopped, 1, "edges and heartbeat stopped")
        XCTAssertEqual(teardown.announced, 1, "a running app is told")
        let raw = defaults.object(forKey: DevicePairingRevocation.revokedAtKey) as? Double
        XCTAssertEqual(raw ?? 0, clocks.wall.timeIntervalSince1970, accuracy: 0.001, "epoch seconds, a Double")
        XCTAssertEqual(DevicePairingRevocation.revokedAtKey, "PAIRING_REVOKED_AT_V1")

        // Revoked: nothing more goes out…
        clocks.advance(120)
        XCTAssertEqual(run(server), .skipped("revoked"))
        XCTAssertEqual(server.requests.count, 3)
        // …until the app has paired again and published a new credential (a new token).
        server.answers = [ok(manualLock: nil)]
        XCTAssertEqual(run(server, credential: credential(updatedAt: clocks.wall, accessToken: "new-pairing")), .saved(changed: true))
    }

    func testAnAnsweredRequestBetweenTwoUnpairedAnswersClearsTheSuspicion() {
        let server = Server([unpaired, ok(manualLock: nil), unpaired])
        XCTAssertEqual(run(server), .unpairedSuspected)
        clocks.advance(61)
        XCTAssertEqual(run(server), .saved(changed: true))
        clocks.advance(61)
        XCTAssertEqual(run(server), .unpairedSuspected, "a fresh suspicion, not a confirmation")
        XCTAssertEqual(teardown.released, 0)
    }

    func testTwoUnpairedAnswersSecondsApartDoNotConfirm() {
        // The pull and the usage upload of ONE callback both answered DEVICE_UNPAIRED.
        XCTAssertEqual(DevicePairingRevocation.recordUnpairedAnswer(at: t0, userDefaults: defaults), .suspected)
        XCTAssertEqual(DevicePairingRevocation.recordUnpairedAnswer(at: t0.addingTimeInterval(5), userDefaults: defaults), .suspected)
        XCTAssertEqual(DevicePairingRevocation.recordUnpairedAnswer(at: t0.addingTimeInterval(30), userDefaults: defaults), .confirmed)
        // A record in the future (the clock wound back) starts again.
        DevicePairingRevocation.recordAnsweredContact(userDefaults: defaults)
        XCTAssertEqual(DevicePairingRevocation.recordUnpairedAnswer(at: t0, userDefaults: defaults), .suspected)
        XCTAssertEqual(DevicePairingRevocation.recordUnpairedAnswer(at: t0.addingTimeInterval(-3_600), userDefaults: defaults), .suspected)
        XCTAssertEqual(DevicePairingRevocation.recordUnpairedAnswer(at: t0.addingTimeInterval(-3_590), userDefaults: defaults), .suspected)
    }

    func testTheUsageUploadsUnpairedAnswerGoesThroughTheSameRule() {
        let env = environment(Server([ok(manualLock: nil)]))
        XCTAssertEqual(DeviceLockStatePull.handleUnpairedAnswer(now: t0, refused: credential(), environment: env), .unpairedSuspected)
        XCTAssertEqual(DeviceLockStatePull.handleUnpairedAnswer(now: t0.addingTimeInterval(45), refused: credential(), environment: env), .unpairedConfirmed)
        XCTAssertEqual(teardown.released, 1)
        XCTAssertFalse(ScreenTimeUsageExtensionUploader.Outcome.unpaired.mayStillLand, "answered: nothing on the wire")
    }

    func testOnlyA401CarryingDeviceUnpairedIsAnUnpair() {
        func body(_ json: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: json) }
        XCTAssertTrue(DevicePairingRevocation.isDeviceUnpairedAnswer(status: 401, body: body(["errorCode": "DEVICE_UNPAIRED"])))
        XCTAssertTrue(DevicePairingRevocation.isDeviceUnpairedAnswer(status: 401, body: body(["errorCode": " DEVICE_UNPAIRED "])))
        XCTAssertFalse(DevicePairingRevocation.isDeviceUnpairedAnswer(status: 401, body: body(["errorCode": "UNAUTHORIZED"])))
        XCTAssertFalse(DevicePairingRevocation.isDeviceUnpairedAnswer(status: 401, body: body(["message": "x"])))
        XCTAssertFalse(DevicePairingRevocation.isDeviceUnpairedAnswer(status: 403, body: body(["errorCode": "DEVICE_UNPAIRED"])))
        XCTAssertFalse(DevicePairingRevocation.isDeviceUnpairedAnswer(status: 401, body: Data("<html>".utf8)))
        XCTAssertFalse(DevicePairingRevocation.isDeviceUnpairedAnswer(status: 401, body: nil))
        XCTAssertEqual(DevicePairingRevocation.deviceUnpairedCode, OilaAPIError.deviceUnpairedCode)
    }

    func testTheTeardownIsTheAppsClearLockPolicyPlusTheRecord() {
        store.save(DeviceLockPolicySnapshot(
            dsn: "d", manualLock: DeviceLockManualWindow(startsAt: t0, endsAt: t0.addingTimeInterval(60)),
            schedules: [], serverTime: nil, receivedAt: t0, clock: nil, isLegacy: false
        ))
        store.markEdgeEvaluated(at: t0)
        DeviceLockUnpairTeardown.perform(
            now: t0, refusedAccessToken: "device-token", store: store, userDefaults: defaults, actions: teardown.actions
        )
        XCTAssertNil(store.load())
        XCTAssertNil(store.lastEdgeEvaluatedAt())
        XCTAssertEqual([teardown.released, teardown.stopped, teardown.announced, teardown.releasedPerApp], [1, 1, 1, 1])
        XCTAssertEqual(DevicePairingRevocation.revokedAt(userDefaults: defaults), t0)
        XCTAssertNotEqual(defaults.string(forKey: DevicePairingRevocation.revokedTokenKey), "device-token", "a fingerprint, never the token")
        XCTAssertTrue(DevicePairingRevocation.isRevoked(credential: credential(updatedAt: t0.addingTimeInterval(-1)), userDefaults: defaults))
        XCTAssertTrue(DevicePairingRevocation.isRevoked(credential: nil, userDefaults: defaults))
        XCTAssertTrue(DevicePairingRevocation.isRevoked(credential: credential(updatedAt: t0.addingTimeInterval(1)), userDefaults: defaults),
                      "the refused token stays refused whatever its copy's timestamp")
        XCTAssertFalse(DevicePairingRevocation.isRevoked(credential: credential(accessToken: "new-pairing"), userDefaults: defaults))
        DevicePairingRevocation.clear(userDefaults: defaults)
        XCTAssertFalse(DevicePairingRevocation.isRevoked(credential: nil, userDefaults: defaults))
        XCTAssertNil(defaults.object(forKey: DevicePairingRevocation.revokedTokenKey))
    }
    // MARK: b29 review

    /// A suspicion older than the confirmation window says nothing about the pairing now: a blip a
    /// week later is only a new suspicion, and it takes a second answer inside the window again.
    func testAStaleSuspicionDoesNotConfirmALaterBlip() {
        XCTAssertEqual(DevicePairingRevocation.recordUnpairedAnswer(at: t0, userDefaults: defaults), .suspected)
        let later = t0.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(DevicePairingRevocation.recordUnpairedAnswer(at: later, userDefaults: defaults), .suspected,
                       "the stale record is replaced, never counted")
        XCTAssertEqual(
            DevicePairingRevocation.recordUnpairedAnswer(at: later.addingTimeInterval(DevicePairingRevocation.confirmationWindow + 1), userDefaults: defaults),
            .suspected, "one second past the window is stale too"
        )
        // Inside the window, measured from the newest record, the second answer confirms.
        let newest = later.addingTimeInterval(DevicePairingRevocation.confirmationWindow + 1)
        XCTAssertEqual(DevicePairingRevocation.recordUnpairedAnswer(at: newest.addingTimeInterval(DevicePairingRevocation.confirmationWindow), userDefaults: defaults), .confirmed)
        XCTAssertEqual(DevicePairingRevocation.confirmationWindow, 15 * 60)
    }

    func testAStaleSuspicionOnThePullPathTearsNothingDown() {
        let server = Server([ok(manualLock: (t0.addingTimeInterval(-60), t0.addingTimeInterval(30 * 86_400)))])
        XCTAssertEqual(run(server), .saved(changed: true))
        _ = DevicePairingRevocation.recordUnpairedAnswer(at: t0, userDefaults: defaults) // an upload's blip
        clocks.advance(DevicePairingRevocation.confirmationWindow + 60)
        server.answers = [unpaired]
        XCTAssertEqual(run(server), .unpairedSuspected)
        XCTAssertEqual(teardown.released, 0)
        XCTAssertTrue(lockedNow(), "a parent's lock is not dropped by two blips hours apart")
    }

    /// Any answer other than DEVICE_UNPAIRED keeps the pairing, as the app's probe does: a 5xx or a
    /// refused token between two unpair answers clears the suspicion.
    func testAnyOtherHTTPAnswerClearsTheSuspicion() {
        for answer in [envelope(500, ["success": false]), envelope(401, ["success": false, "errorCode": "UNAUTHORIZED"])] {
            let server = Server([unpaired, answer, unpaired])
            XCTAssertEqual(run(server), .unpairedSuspected)
            clocks.advance(61)
            _ = run(server)
            XCTAssertNil(defaults.object(forKey: DevicePairingRevocation.suspectedAtKey))
            clocks.advance(61)
            XCTAssertEqual(run(server), .unpairedSuspected)
            clocks.advance(61)
            DevicePairingRevocation.recordAnsweredContact(userDefaults: defaults)
        }
        // An offline attempt is no answer: it neither keeps nor confirms.
        let server = Server([unpaired, .failed("offline"), unpaired])
        XCTAssertEqual(run(server), .unpairedSuspected)
        clocks.advance(61)
        XCTAssertEqual(run(server), .failed("offline"))
        clocks.advance(61)
        XCTAssertEqual(run(server), .unpairedConfirmed)
        XCTAssertEqual(teardown.released, 1)
    }

    /// The extension's usage upload: a `.sent` (or any non-unpair HTTP answer) is what the monitor
    /// hands to `recordAnsweredContact`.
    func testAnAnsweredUsageUploadCountsAsContact() {
        typealias O = ScreenTimeUsageExtensionUploader.Outcome
        XCTAssertTrue(O.sent(status: 200).wasAnswered)
        XCTAssertTrue(O.failed(O.httpFailurePrefix + "500").wasAnswered)
        XCTAssertFalse(O.failed("timeout").wasAnswered)
        XCTAssertFalse(O.failed(O.encodeFailurePrefix + "x").wasAnswered)
        XCTAssertFalse(O.skipped(reason: "no_credential").wasAnswered)
        XCTAssertFalse(O.unpaired.wasAnswered)

        _ = DevicePairingRevocation.recordUnpairedAnswer(at: t0, userDefaults: defaults)
        DevicePairingRevocation.recordAnsweredContact(userDefaults: defaults)
        XCTAssertNil(defaults.object(forKey: DevicePairingRevocation.suspectedAtKey))
        XCTAssertEqual(DevicePairingRevocation.recordUnpairedAnswer(at: t0.addingTimeInterval(60), userDefaults: defaults), .suspected)
    }

    /// The app's answered calls go through the store's `clearUnpairedSuspicion`.
    func testTheAppsStoreClearsTheSuspicion() {
        _ = DevicePairingRevocation.recordUnpairedAnswer(at: t0, userDefaults: defaults)
        store.clearUnpairedSuspicion()
        XCTAssertNil(defaults.object(forKey: DevicePairingRevocation.suspectedAtKey))
    }

    /// The app, woken by a push, saved a newer answer while this pull's request was in flight: the
    /// pull must not write its older answer over it.
    func testAPullDoesNotOverwriteASnapshotSavedWhileItsRequestWasInFlight() {
        let lockWindow = (t0.addingTimeInterval(-60), t0.addingTimeInterval(900))
        let appsAnswer = Server([ok(manualLock: lockWindow)])
        let pulled = Server([ok(manualLock: nil)])
        let appsSuite = "DeviceLockStatePullTests.app.\(UUID().uuidString)"
        suiteNames.append(appsSuite)
        let appEnv = DeviceLockStatePull.Environment(
            store: store, userDefaults: UserDefaults(suiteName: appsSuite), clock: clocks.clock,
            transport: { request, _ in appsAnswer.answer(request) }, teardown: teardown.actions,
            currentCredential: { Self.publishedCredential(of: appsAnswer) }
        )
        var env = environment(pulled)
        env.transport = { [self] request, _ in
            // Mid-request: the app's own GET lands 2 s later and saves the parent's lock.
            clocks.advance(2)
            XCTAssertEqual(DeviceLockStatePull.run(credential: credential(), fallbackDSN: nil, environment: appEnv), .saved(changed: true))
            clocks.advance(1)
            return pulled.answer(request)
        }
        XCTAssertEqual(DeviceLockStatePull.run(credential: credential(), fallbackDSN: nil, environment: env), .skipped("superseded"))
        XCTAssertTrue(lockedNow(), "the app's newer lock stands")
    }

    /// Final review: the app wiped the pairing while this pull's request was in flight (its first
    /// step tears the shared credential down). The late 200 must not write the old family's lock
    /// back into the purged App Group — nothing is saved and the caller re-evaluates nothing.
    func testALate200AfterTheAppWipedThePairingIsNotSaved() {
        let lockWindow = (t0.addingTimeInterval(-60), t0.addingTimeInterval(8 * 3_600))
        let server = Server([ok(manualLock: lockWindow)])
        var env = environment(server)
        env.currentCredential = { nil }
        XCTAssertEqual(DeviceLockStatePull.run(credential: credential(), fallbackDSN: nil, environment: env),
                       .skipped("credential_changed"))
        XCTAssertNil(store.load(), "nothing saved into the purged App Group")
        XCTAssertFalse(lockedNow())
    }

    /// The same late 200 after a quick re-pair: the new pairing's token is published, so the old
    /// family's policy is not saved over the new pairing.
    func testALate200ForAReplacedCredentialIsNotSaved() {
        let server = Server([ok(manualLock: (t0.addingTimeInterval(-60), t0.addingTimeInterval(900)))])
        var env = environment(server)
        env.currentCredential = { [self] in credential(updatedAt: clocks.wall, accessToken: "new-pairing") }
        XCTAssertEqual(DeviceLockStatePull.run(credential: credential(), fallbackDSN: nil, environment: env),
                       .skipped("credential_changed"))
        XCTAssertNil(store.load())
        // The unchanged pairing still saves.
        clocks.advance(61)
        env.currentCredential = { [self] in credential() }
        XCTAssertEqual(DeviceLockStatePull.run(credential: credential(), fallbackDSN: nil, environment: env),
                       .saved(changed: true))
    }

    /// A new pairing published while the refused request was in flight is not the pairing the
    /// server refused: nothing is torn down and nothing is marked revoked.
    func testAConfirmationForACredentialReplacedMidFlightTearsNothingDown() {
        let server = Server([unpaired])
        XCTAssertEqual(run(server), .unpairedSuspected)
        clocks.advance(61)
        var env = environment(server)
        env.currentCredential = { [self] in credential(updatedAt: clocks.wall, accessToken: "new-pairing") }
        XCTAssertEqual(DeviceLockStatePull.run(credential: credential(), fallbackDSN: nil, environment: env), .skipped("credential_changed"))
        XCTAssertEqual(teardown.released, 0)
        XCTAssertNil(DevicePairingRevocation.revokedAt(userDefaults: defaults))
        XCTAssertNil(defaults.object(forKey: DevicePairingRevocation.suspectedAtKey))

        // The same credential still published: the confirmation stands, tied to that token.
        clocks.advance(61)
        XCTAssertEqual(run(server), .unpairedSuspected)
        clocks.advance(61)
        env.currentCredential = { [self] in credential() }
        XCTAssertEqual(DeviceLockStatePull.run(credential: credential(), fallbackDSN: nil, environment: env), .unpairedConfirmed)
        XCTAssertEqual(defaults.string(forKey: DevicePairingRevocation.revokedTokenKey), DevicePairingRevocation.fingerprint("device-token"))
    }

    /// A revocation confirmed while the phone's clock ran ahead: the re-paired credential, published
    /// once the clock is right again, has an EARLIER `updatedAt` than the record — and still pulls.
    func testARePairAfterAClockThatRanAheadIsNotRevoked() {
        let server = Server([unpaired])
        clocks.wall = t0.addingTimeInterval(86_400) // the child set the date a day forward
        XCTAssertEqual(run(server), .unpairedSuspected)
        clocks.advance(61)
        XCTAssertEqual(run(server), .unpairedConfirmed)
        clocks.wall = t0 // corrected
        server.answers = [ok(manualLock: nil)]
        XCTAssertEqual(run(server, credential: credential(updatedAt: t0, accessToken: "new-pairing")), .saved(changed: true))
    }

    /// Per-app rungs arrive in bursts: a rate-limited pull never reads the Keychain.
    func testARateLimitedPullDoesNotReadTheCredential() {
        let server = Server([ok(manualLock: nil)])
        XCTAssertEqual(run(server), .saved(changed: true))
        clocks.advance(10)
        var reads = 0
        let outcome = DeviceLockStatePull.run(
            readCredential: { reads += 1; return self.credential() }, fallbackDSN: nil, environment: environment(server)
        )
        XCTAssertEqual(outcome, .skipped("rate_limited"))
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(server.requests.count, 1)
    }
}

/// The parser and the snapshot builder moved to Shared (build 29); the app forwards to them. The
/// pre-existing parser and snapshot tests pin the behaviour unchanged; these pin the forwarding.
final class DeviceLockStateSharedParserTests: XCTestCase {
    private let payload: [String: Any] = [
        "isLocked": true, "manualLockEnabled": "true", "scheduleLocked": false, "deviceLocalTime": "15:45",
        "manualLock": ["startsAt": "2026-09-28T10:00:00.000Z", "endsAt": "2026-09-28T12:00:00Z"],
        "serverTime": "2026-09-28T10:45:00.000Z",
        "schedules": [["id": "s1", "startMinute": 1260, "endMinute": 420.0, "daysBitmask": "127", "enabled": true, "deletedAt": NSNull()]],
        "lockedPackages": [" org.telegram ", "com.google.ios.youtube"],
        "appLimits": [["packageName": "com.x", "usedSeconds": 1e30, "dailyLimitSeconds": "600"]],
        "lockedUntil": 1_790_000_000_000.0
    ]

    func testTheAppAndTheExtensionReadTheSamePayloadTheSameWay() {
        let app = OilaDeviceClient.parseLockState(from: payload)
        let shared = DeviceLockStateParser.parseLockState(from: payload)
        XCTAssertEqual(app.isLocked, shared.isLocked)
        XCTAssertEqual(app.manualLockEnabled, true)
        XCTAssertEqual(app.manualLock, shared.manualLock)
        XCTAssertEqual(app.schedules, shared.schedules)
        XCTAssertEqual(app.schedules?.first?.startMinute, 1260)
        XCTAssertEqual(app.schedules?.first?.endMinute, 420)
        XCTAssertEqual(app.serverTime, shared.serverTime)
        XCTAssertEqual(app.lockedPackages, ["org.telegram", "com.google.ios.youtube"])
        XCTAssertEqual(app.appLimits, shared.appLimits)
        XCTAssertEqual(app.appLimits.first?.usedSeconds, 0, "an absurd number reads as absent, never a crash")
        XCTAssertEqual(app.lockedUntil, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(app.deviceLocalTime, "15:45")
        XCTAssertTrue(app.carriesLockPolicy)
    }

    func testTheSnapshotBuilderIsOneImplementation() {
        let state = DeviceLockStateParser.parseLockState(from: payload)
        let anchor = DeviceLockClockAnchor(wall: Date(timeIntervalSince1970: 1_790_000_000), monotonicNanos: 42, offset: 3, bootSessionID: "b")
        XCTAssertEqual(
            OilaTelemetryService.lockPolicySnapshot(from: state, dsn: "d", anchor: anchor),
            DeviceLockPolicySnapshot.fromLockState(state, dsn: "d", anchor: anchor)
        )
        XCTAssertEqual(OilaTelemetryService.legacyLockCeiling, 8 * 3_600)
        XCTAssertNil(DeviceLockPolicySnapshot.fromLockState(OilaLockState(isLocked: nil, raw: [:]), dsn: "d", anchor: anchor))
    }

    func testSamePolicyIgnoresWhenItWasHeard() throws {
        let state = DeviceLockStateParser.parseLockState(from: payload)
        let a = try XCTUnwrap(DeviceLockPolicySnapshot.fromLockState(
            state, dsn: "d", anchor: DeviceLockClockAnchor(wall: Date(timeIntervalSince1970: 1), monotonicNanos: 1, offset: 0, bootSessionID: nil)))
        let b = try XCTUnwrap(DeviceLockPolicySnapshot.fromLockState(
            state, dsn: "d", anchor: DeviceLockClockAnchor(wall: Date(timeIntervalSince1970: 99), monotonicNanos: 9, offset: 2, bootSessionID: "x")))
        XCTAssertTrue(a.hasSamePolicy(as: b))
        XCTAssertFalse(a.hasSamePolicy(as: nil))
        let unlocked = try XCTUnwrap(DeviceLockPolicySnapshot.fromLockState(
            DeviceLockStateParser.parseLockState(from: payload.merging(["manualLock": NSNull()]) { $1 }),
            dsn: "d", anchor: DeviceLockClockAnchor(wall: Date(timeIntervalSince1970: 1), monotonicNanos: 1, offset: 0, bootSessionID: nil)))
        XCTAssertFalse(a.hasSamePolicy(as: unlocked))
    }
}

/// Build 29 readiness for the backend's switch of `lock.refresh` to an ALERT push (priority 10,
/// `content-available: 1`, a visible "Telefon … gacha bloklandi" / "Telefon ochildi").
final class PushLockAlertTests: XCTestCase {
    private func alertLock(_ event: String, dsn: String) -> [AnyHashable: Any] {
        [
            "type": event, "dsn": dsn,
            // Carried, and deliberately NOT trusted: the GET that follows decides.
            "startsAt": "2026-09-28T13:00:00Z", "endsAt": "2026-09-28T13:18:00Z", "serverTime": "2026-09-28T13:00:01Z",
            "aps": ["alert": ["title": "Bolajon360", "body": "Telefon 18:18 gacha bloklandi"], "content-available": 1, "mutable-content": 1]
        ]
    }

    func testLockCommandsNeverFileAnInboxRow() {
        for event in ["lock.refresh", "lock.updated", "LOCK_REFRESH", "unlock", "lock"] {
            let payload = PushCommandRouter.parsePayload(from: ["type": event, "aps": ["alert": ["title": "t", "body": "b"]]])
            XCTAssertTrue(PushCommandRouter.suppressesInboxRow(payload), event)
        }
        for event in ["message_task_lock", "chat.refresh", "task.assigned", "announcement", "block.list", ""] {
            XCTAssertFalse(PushCommandRouter.isLockCommand(event), event)
        }
    }

    func testAnAlertLockRefreshStillRefreshesTheLockInEveryDeliveryPath() async {
        await PushInboxStore.shared.clearAll()
        let dsn = "child-lock-alert"
        var refreshes = 0
        let token = NotificationCenter.default.addObserver(forName: .pushShouldRefreshLockState, object: nil, queue: nil) { _ in refreshes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertTrue(PushCommandRouter.isLockRefreshCommand(userInfo: alertLock("lock.refresh", dsn: dsn)),
                      "the AppDelegate holds the fetch handler for the GET")
        for context in [PushDeliveryContext.backgroundFetch, .foregroundPresentation, .launch, .userResponse] {
            PushCommandRouter.handle(userInfo: alertLock("lock.refresh", dsn: dsn),
                                     openedFromInteraction: context == .userResponse, deliveryContext: context)
        }
        let deadline = Date().addingTimeInterval(3)
        while refreshes < 4, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(refreshes, 4)

        // A control that must still file, so the empty inbox below is the suppression, not a race.
        PushCommandRouter.handle(userInfo: ["event": "announcement", "dsn": dsn, "aps": ["alert": ["title": "E'lon", "body": "x"]]],
                                 deliveryContext: .backgroundFetch)
        let items = await waitForPushInboxItemsMatchingDSNForTests(count: 1, dsn: dsn)
        XCTAssertEqual(items.map(\.event), ["announcement"], "no row, no badge, for the lock banner")
    }
}

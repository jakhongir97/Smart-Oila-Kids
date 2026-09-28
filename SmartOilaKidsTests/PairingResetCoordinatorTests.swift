import XCTest
@testable import SmartOilaKids

/// Build 29 unpair lane (Ibrohim 699760, photo 699758): which answers end a pairing, how fast, and
/// what the chip says meanwhile. Every dependency is faked — no network, no Keychain, no real clock,
/// and the wipe is only counted, so nothing here can touch the test host's own session.
@MainActor
final class PairingResetCoordinatorTests: XCTestCase {
    /// The world the coordinator sees.
    @MainActor
    private final class World {
        var paired = true
        var credentialAbsent = false
        /// Answers to the confirming probe, in order; the last one repeats. nil = 200.
        var probeAnswers: [Error?] = [nil]
        var probeCalls = 0
        var healthy = true
        var healthCalls = 0
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var sleeps: [TimeInterval] = []
        /// When set, `sleep` waits here instead of advancing the clock at once.
        var sleepGate: CheckedContinuation<Void, Error>?
        var holdsSleep = false
        var keepAlivesBegun = 0
        var keepAlivesEnded = 0
        var localDSN: String? = "DSN-LOCAL"
        var wipes: [PairingResetCoordinator.Reason] = []
        /// Held while the probe is "in flight", when `holdsProbe` is set.
        var probeGate: CheckedContinuation<Void, Never>?
        var holdsProbe = false
        let defaults: UserDefaults
        let group: UserDefaults
        let defaultsName = "PairingResetTests.\(UUID().uuidString)"
        let groupName = "PairingResetGroup.\(UUID().uuidString)"

        init() {
            defaults = UserDefaults(suiteName: defaultsName)!
            group = UserDefaults(suiteName: groupName)!
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: defaultsName)
            group.removePersistentDomain(forName: groupName)
        }

        var dependencies: PairingResetCoordinator.Dependencies {
            PairingResetCoordinator.Dependencies(
                isPaired: { [unowned self] in paired },
                credentialIsAbsent: { [unowned self] in credentialAbsent },
                probe: { [unowned self] in
                    probeCalls += 1
                    if holdsProbe { await withCheckedContinuation { probeGate = $0 } }
                    let answer = probeAnswers.count > 1 ? probeAnswers.removeFirst() : probeAnswers[0]
                    if let answer { throw answer }
                },
                checkHealth: { [unowned self] in
                    healthCalls += 1
                    return healthy
                },
                sleep: { [unowned self] seconds in
                    sleeps.append(seconds)
                    if holdsSleep {
                        try await withCheckedThrowingContinuation { sleepGate = $0 }
                    }
                    clock = clock.addingTimeInterval(seconds)
                },
                now: { [unowned self] in clock },
                keepAlive: { [unowned self] _ in
                    keepAlivesBegun += 1
                    return { [unowned self] in keepAlivesEnded += 1 }
                },
                localDSN: { [unowned self] in localDSN },
                defaults: defaults,
                appGroupDefaults: group,
                wipe: { [unowned self] reason in
                    wipes.append(reason)
                    paired = false
                }
            )
        }
    }

    private var world: World!
    private var coordinator: PairingResetCoordinator!

    override func setUp() async throws {
        world = World()
        coordinator = PairingResetCoordinator(dependencies: world.dependencies)
    }

    override func tearDown() async throws {
        coordinator.cancelUnauthorizedSequence(clearPersisted: true)
        world.tearDown()
        world = nil
        coordinator = nil
    }

    private func apiError(_ status: Int, _ code: String?) -> OilaAPIError {
        OilaAPIError(statusCode: status, message: "m", errorCode: code, fieldErrors: [])
    }

    private var unpaired: OilaAPIError { apiError(401, OilaAPIError.deviceUnpairedCode) }
    private var unauthorized: OilaAPIError { apiError(401, "UNAUTHORIZED") }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// Lets queued main-actor work run, for the "nothing happened" assertions.
    private func settle() async {
        for _ in 0 ..< 20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
}

// MARK: DEVICE_UNPAIRED and the other conclusive answers

extension PairingResetCoordinatorTests {
    /// 699760: DEVICE_UNPAIRED from ANY route ends the pairing after ONE immediate probe — no
    /// random 30–120 s wait (that wait is what photo 699758 caught).
    func testDeviceUnpairedFromAnyRouteWipesAfterOneImmediateProbe() async {
        world.probeAnswers = [unpaired]
        coordinator.handle(.refused(unpaired, path: "device/home"))

        let wiped = await waitUntil { !self.world.wipes.isEmpty && !self.coordinator.isConfirmingRevocation }
        XCTAssertTrue(wiped)
        XCTAssertEqual(world.wipes, [.serverUnpaired])
        XCTAssertEqual(world.probeCalls, 1, "one confirming probe")
        XCTAssertTrue(world.sleeps.isEmpty, "no delay before it")
        XCTAssertEqual(world.keepAlivesBegun, world.keepAlivesEnded, "the probe's keep-alive is released")
        XCTAssertFalse(coordinator.isConfirmingRevocation)
    }

    /// A stale DEVICE_UNPAIRED (the probe answers 200) keeps the pairing.
    func testAConclusiveRefusalThatTheProbeAnswers200IsCancelled() async {
        world.probeAnswers = [nil]
        let outcome = await coordinator.confirmConclusive(source: .response)
        XCTAssertEqual(outcome, .stillPaired)
        XCTAssertTrue(world.wipes.isEmpty)
    }

    /// An expired device token is conclusive too (no route can renew it).
    func testAnExpiredTokenConfirmedByTheProbeWipes() async {
        let expired = apiError(401, OilaAPIError.deviceTokenExpiredCode)
        world.probeAnswers = [expired]
        coordinator.handle(.refused(expired, path: "device/status"))
        let wiped = await waitUntil { !self.world.wipes.isEmpty }
        XCTAssertTrue(wiped)
    }

    /// Offline during the probe: nothing is decided.
    func testAnUnansweredProbeKeepsThePairing() async {
        world.probeAnswers = [URLError(.notConnectedToInternet)]
        let outcome = await coordinator.confirmConclusive(source: .response)
        XCTAssertEqual(outcome, .inconclusive)
        XCTAssertTrue(world.wipes.isEmpty)
    }

    /// Two routes hearing the same unpair send ONE probe between them.
    func testConcurrentConfirmationsShareOneProbe() async {
        world.holdsProbe = true
        world.probeAnswers = [unpaired]
        async let first = coordinator.confirmConclusive(source: .response)
        let started = await waitUntil { self.world.probeGate != nil }
        XCTAssertTrue(started)
        async let second = coordinator.confirmConclusive(source: .push)
        await settle()
        world.probeGate?.resume()
        let outcomes = await [first, second]
        XCTAssertEqual(outcomes, [.reset, .reset])
        XCTAssertEqual(world.probeCalls, 1)
        XCTAssertEqual(world.wipes.count, 1)
    }

    /// The Keychain says there is no token while the flags say paired: onboarding at once.
    func testAPairedFlagOverAnAbsentCredentialWipesAtLaunch() {
        world.credentialAbsent = true
        coordinator.checkOnLaunchOrForeground()
        XCTAssertEqual(world.wipes, [.credentialAbsent])
        XCTAssertEqual(world.probeCalls, 0, "no probe can produce a token that is not there")
    }

    func testAnAbsentCredentialReportedByARequestWipes() {
        coordinator.handle(.refused(apiError(401, OilaAPIError.credentialAbsentCode), path: "device/tasks"))
        XCTAssertEqual(world.wipes, [.credentialAbsent])
    }

    /// An unreadable Keychain (locked before first unlock) is transient and decides nothing.
    func testAnUnreadableCredentialIsIgnored() async {
        coordinator.handle(.refused(apiError(401, OilaAPIError.noCredentialCode), path: "device/tasks"))
        await settle()
        XCTAssertTrue(world.wipes.isEmpty)
        XCTAssertEqual(world.probeCalls, 0)
    }

    /// An unpaired install ignores every signal.
    func testNothingHappensOnAnUnpairedInstall() async {
        world.paired = false
        coordinator.handle(.refused(unpaired, path: "device/home"))
        coordinator.handle(.refused(unauthorized, path: "device/home"))
        coordinator.checkOnLaunchOrForeground()
        await settle()
        XCTAssertTrue(world.wipes.isEmpty)
        XCTAssertEqual(world.probeCalls, 0)
    }

    /// Several paths can hear the same unpair; they converge on one wipe.
    func testResetIsIdempotent() {
        coordinator.reset(reason: .selfUnpair)
        coordinator.reset(reason: .sessionInvalidated)
        XCTAssertEqual(world.wipes, [.selfUnpair])
    }
}

// MARK: The chip

extension PairingResetCoordinatorTests {
    /// While the revocation is confirmed the chip is the neutral "Ulanmoqda…", not the red
    /// "Сейчас нет связи" of photo 699758 — even with no contact on record.
    func testTheChipIsNeutralWhileARevocationIsConfirmed() async {
        world.holdsProbe = true
        world.probeAnswers = [unpaired]
        let task = Task { await coordinator.confirmConclusive(source: .response) }
        let inFlight = await waitUntil { self.world.probeGate != nil }
        XCTAssertTrue(inFlight)
        XCTAssertTrue(coordinator.isConfirmingRevocation)
        XCTAssertTrue(coordinator.hasConclusiveConfirmationInFlight)
        XCTAssertEqual(
            LinkHealth.decide(hasCredential: true, offPermissions: 0, lastContactAt: nil,
                              revocationPending: coordinator.isConfirmingRevocation),
            .connecting
        )
        XCTAssertEqual(L10n.tr("home2.link_connecting").isEmpty, false)
        world.probeGate?.resume()
        _ = await task.value
        XCTAssertFalse(coordinator.isConfirmingRevocation)
        XCTAssertEqual(
            LinkHealth.decide(hasCredential: true, offPermissions: 0, lastContactAt: nil),
            .outOfContact(since: nil),
            "without a pending revocation the verdict is unchanged"
        )
    }
}

// MARK: Plain 401 UNAUTHORIZED — only when sustained (699760 "also on HTTP 401")

extension PairingResetCoordinatorTests {
    /// One 401 whose probe then answers 200 is a blip: nothing is wiped and nothing is left armed.
    func testASingleUnauthorizedDoesNotWipe() async {
        world.probeAnswers = [nil]
        coordinator.handle(.refused(unauthorized, path: "device/home"))
        let settled = await waitUntil { self.world.probeCalls == 1 && !self.coordinator.isConfirmingRevocation }
        XCTAssertTrue(settled)
        XCTAssertTrue(world.wipes.isEmpty)
        XCTAssertNil(world.defaults.object(forKey: PairingResetCoordinator.unauthorizedSinceKey))
        XCTAssertEqual(world.healthCalls, 0)
    }

    /// The server refuses but fails its own health check: server trouble, not an unpair.
    func testAnUnhealthyServerAbandonsTheSequence() async {
        world.probeAnswers = [unauthorized]
        world.healthy = false
        coordinator.handle(.refused(unauthorized, path: "device/home"))
        let settled = await waitUntil { self.world.healthCalls == 1 && !self.coordinator.isConfirmingRevocation }
        XCTAssertTrue(settled)
        XCTAssertTrue(world.wipes.isEmpty)
        XCTAssertNil(world.defaults.object(forKey: PairingResetCoordinator.unauthorizedSinceKey))
    }

    /// Refused now, at ~2 min and at ~10 min, with /health up throughout: the pairing is gone.
    func testSustainedUnauthorizedWipes() async {
        world.probeAnswers = [unauthorized]
        let start = world.clock
        coordinator.handle(.refused(unauthorized, path: "device/home"))

        let wiped = await waitUntil { !self.world.wipes.isEmpty }
        XCTAssertTrue(wiped)
        XCTAssertEqual(world.wipes, [.sustainedUnauthorized])
        XCTAssertEqual(world.probeCalls, 3, "immediate, short and long re-probe")
        XCTAssertEqual(world.healthCalls, 2, "at the start and again before the wipe")
        XCTAssertEqual(world.sleeps, [PairingResetCoordinator.unauthorizedShortRecheck,
                                      PairingResetCoordinator.unauthorizedLongRecheck - PairingResetCoordinator.unauthorizedShortRecheck])
        XCTAssertEqual(world.clock.timeIntervalSince(start), PairingResetCoordinator.unauthorizedLongRecheck)
        XCTAssertEqual(world.keepAlivesBegun, 1, "only the short wait keeps the app alive")
        XCTAssertEqual(world.keepAlivesBegun, world.keepAlivesEnded)
        XCTAssertNil(world.defaults.object(forKey: PairingResetCoordinator.unauthorizedSinceKey))
    }

    /// The thresholds 699760 is answered with — pinned so a change is a decision, not a drift.
    func testTheSustainedThresholds() {
        XCTAssertEqual(PairingResetCoordinator.unauthorizedShortRecheck, 120)
        XCTAssertEqual(PairingResetCoordinator.unauthorizedLongRecheck, 600)
    }

    /// Any 2xx on any authorized route while the sequence waits cancels it.
    func testASuccessInBetweenCancelsTheSequence() async {
        world.probeAnswers = [unauthorized]
        world.holdsSleep = true
        coordinator.handle(.refused(unauthorized, path: "device/home"))
        let waiting = await waitUntil { self.world.sleepGate != nil }
        XCTAssertTrue(waiting)
        XCTAssertTrue(coordinator.isConfirmingRevocation)
        XCTAssertNotNil(world.defaults.object(forKey: PairingResetCoordinator.unauthorizedSinceKey))

        coordinator.handle(.succeeded(path: "device/tasks"))
        world.sleepGate?.resume()
        await settle()

        XCTAssertTrue(world.wipes.isEmpty)
        XCTAssertEqual(world.probeCalls, 1, "the cancelled sequence probes no more")
        XCTAssertFalse(coordinator.isConfirmingRevocation)
        XCTAssertNil(world.defaults.object(forKey: PairingResetCoordinator.unauthorizedSinceKey))
    }

    /// A re-probe that answers 200 cancels too.
    func testAReprobeThatSucceedsCancels() async {
        world.probeAnswers = [unauthorized, nil]
        coordinator.handle(.refused(unauthorized, path: "device/home"))
        let settled = await waitUntil { self.world.probeCalls == 2 && !self.coordinator.isConfirmingRevocation }
        XCTAssertTrue(settled)
        XCTAssertTrue(world.wipes.isEmpty)
    }

    /// A DEVICE_UNPAIRED heard during the sequence ends it the conclusive way.
    func testADeviceUnpairedReprobeWipesAtOnce() async {
        world.probeAnswers = [unauthorized, unpaired]
        coordinator.handle(.refused(unauthorized, path: "device/home"))
        let wiped = await waitUntil { !self.world.wipes.isEmpty }
        XCTAssertTrue(wiped)
        XCTAssertEqual(world.wipes, [.serverUnpaired])
    }

    /// The ~10 min re-probe survives a suspension: the persisted stage runs on the next wake.
    func testTheLongRecheckRunsOnTheNextWake() async {
        world.probeAnswers = [unauthorized]
        world.defaults.set(world.clock.addingTimeInterval(-11 * 60).timeIntervalSince1970,
                           forKey: PairingResetCoordinator.unauthorizedSinceKey)
        world.defaults.set(2, forKey: PairingResetCoordinator.unauthorizedStageKey)

        coordinator.checkOnLaunchOrForeground()

        let wiped = await waitUntil { !self.world.wipes.isEmpty }
        XCTAssertTrue(wiped)
        XCTAssertEqual(world.wipes, [.sustainedUnauthorized])
        XCTAssertEqual(world.probeCalls, 1)
        XCTAssertTrue(world.sleeps.isEmpty, "overdue: no further wait")
    }
}

// MARK: The unpair push and the extension's marker

extension PairingResetCoordinatorTests {
    func testAnUnpairPushWipesOnlyWhenTheServerSaysUnpaired() async {
        world.probeAnswers = [unpaired]
        let outcome = await coordinator.handleUnpairPush(pushedDSN: "dsn-local")
        XCTAssertEqual(outcome, .reset, "the dsn is compared case-insensitively")
        XCTAssertEqual(world.wipes, [.unpairPush])
    }

    /// A 200 means the push is stale (sent for a record this phone is no longer, or re-sent).
    func testAStaleUnpairPushIsIgnoredAfterA200() async {
        world.probeAnswers = [nil]
        let outcome = await coordinator.handleUnpairPush(pushedDSN: nil)
        XCTAssertEqual(outcome, .stillPaired)
        XCTAssertTrue(world.wipes.isEmpty)
    }

    /// Addressed to another dsn: ignored without a request (FCM token reuse across pairings).
    func testAnUnpairPushForAnotherDeviceIsIgnored() async {
        world.probeAnswers = [unpaired]
        let outcome = await coordinator.handleUnpairPush(pushedDSN: "DSN-OF-THE-OLD-PAIRING")
        XCTAssertEqual(outcome, .ignored)
        XCTAssertEqual(world.probeCalls, 0)
        XCTAssertTrue(world.wipes.isEmpty)
    }

    func testTheExtensionMarkerIsConfirmedAndWipes() async {
        world.group.set(1_800_000_000.0, forKey: PairingResetCoordinator.extensionRevokedAtKey)
        world.probeAnswers = [unpaired]
        coordinator.checkOnLaunchOrForeground()
        let wiped = await waitUntil { !self.world.wipes.isEmpty }
        XCTAssertTrue(wiped)
        XCTAssertEqual(world.wipes, [.extensionRevoked])
        XCTAssertNil(world.group.object(forKey: PairingResetCoordinator.extensionRevokedAtKey))
    }

    func testAStaleExtensionMarkerIsClearedAfterA200() async {
        world.group.set(1_800_000_000.0, forKey: PairingResetCoordinator.extensionRevokedAtKey)
        world.probeAnswers = [nil]
        coordinator.checkOnLaunchOrForeground()
        let cleared = await waitUntil {
            self.world.group.object(forKey: PairingResetCoordinator.extensionRevokedAtKey) == nil
        }
        XCTAssertTrue(cleared)
        XCTAssertTrue(world.wipes.isEmpty)
    }

    /// Offline: the marker stays for the next wake.
    func testTheExtensionMarkerSurvivesAnUnansweredProbe() async {
        world.group.set(1_800_000_000.0, forKey: PairingResetCoordinator.extensionRevokedAtKey)
        world.probeAnswers = [URLError(.timedOut)]
        coordinator.checkOnLaunchOrForeground()
        let probed = await waitUntil { self.world.probeCalls == 1 && !self.coordinator.isConfirmingRevocation }
        XCTAssertTrue(probed)
        XCTAssertNotNil(world.group.object(forKey: PairingResetCoordinator.extensionRevokedAtKey))
        XCTAssertTrue(world.wipes.isEmpty)
    }

    func testTheMarkerKeyIsTheOneTheExtensionWrites() {
        XCTAssertEqual(PairingResetCoordinator.extensionRevokedAtKey, "PAIRING_REVOKED_AT_V1")
    }
}

// MARK: Push routing

final class UnpairPushRoutingTests: XCTestCase {
    func testUnpairEventsAreRecognisedFromTheMachineEvent() {
        for event in ["unpair", "device.unpaired", "device.unlinked", "unlink", "child.deleted",
                      "child.removed", "device.removed", "device.revoked", "device.deleted",
                      "deviceunpaired", "DEVICE_UNPAIRED", "parent.unpair_device"] {
            XCTAssertTrue(PushCommandRouter.isUnpairCommand(event), event)
        }
    }

    func testOtherCommandsAreNotUnpair() {
        for event in ["", "lock.refresh", "chat.refresh", "status.report", "stream.start", "stream.stop",
                      "task.created", "device.status", "device.lock", "child.updated", "pair", "paired"] {
            XCTAssertFalse(PushCommandRouter.isUnpairCommand(event), event)
        }
    }

    /// Never an inbox row, even when the push carries alert text.
    func testAnUnpairPushFilesNoInboxRow() {
        let payload = PushCommandRouter.parsePayload(from: [
            "event": "device.unpaired",
            "aps": ["alert": ["title": "Qurilma uzildi", "body": "Ota-ona qurilmani uzdi"]]
        ])
        XCTAssertTrue(PushCommandRouter.suppressesInboxRow(payload))
    }

    /// The payload's device serial is read under its own spelling too.
    func testTheDeviceSerialIsReadAsTheDSN() {
        let payload = PushCommandRouter.parsePayload(from: ["event": "unpair", "deviceSerial": "ABC-1"])
        XCTAssertEqual(payload.dsn, "ABC-1")
    }
}

// MARK: The client reports every authorized route's answer

final class OilaDeviceClientPairingSignalTests: XCTestCase {
    private final class Tokens: SecureTokenStoring {
        var access: String?
        init(access: String?) { self.access = access }
        func accessToken() -> String? { access }
        func refreshToken() -> String? { nil }
        func setAccessToken(_ token: String?) { access = token }
        func setRefreshToken(_ token: String?) {}
        func migrateFromUserDefaults(_ userDefaults: UserDefaults) {}
        func clear() { access = nil }
    }

    /// Thread-safe: the sink is called on whatever thread the request finished on.
    private final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [OilaDeviceClient.PairingSignal] = []
        func append(_ signal: OilaDeviceClient.PairingSignal) { lock.lock(); items.append(signal); lock.unlock() }
        var all: [OilaDeviceClient.PairingSignal] { lock.lock(); defer { lock.unlock() }; return items }
    }

    override func tearDown() {
        TestHTTPURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(access: String? = "DEVICE_JWT", base: String = "https://test.local/api/v1") -> (OilaDeviceClient, Signals) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestHTTPURLProtocol.self]
        let client = OilaDeviceClient(
            baseURL: URL(string: base)!,
            session: URLSession(configuration: config),
            secureTokens: Tokens(access: access),
            userDefaults: UserDefaults(suiteName: "PairingSignalTests.\(UUID().uuidString)")!
        )
        let signals = Signals()
        client.pairingSignalSink = { signals.append($0) }
        return (client, signals)
    }

    private func answer(_ code: Int, _ json: String) {
        TestHTTPURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
    }

    /// Home's reads are `try?` — the refusal still reaches the handler, from the transport.
    func testADeviceUnpairedOnHomeIsReported() async {
        let (client, signals) = makeClient()
        answer(401, #"{"success":false,"errorCode":"DEVICE_UNPAIRED","message":"gone"}"#)
        _ = try? await client.fetchHome()
        guard case let .refused(error, path)? = signals.all.first else {
            return XCTFail("expected a refusal, got \(signals.all)")
        }
        XCTAssertEqual(error.errorCode, OilaAPIError.deviceUnpairedCode)
        XCTAssertEqual(path, "device/home")
    }

    func testAPlainUnauthorizedIsReportedAsARefusal() async {
        let (client, signals) = makeClient()
        answer(401, #"{"success":false,"errorCode":"UNAUTHORIZED"}"#)
        _ = try? await client.fetchTasks()
        guard case let .refused(error, _)? = signals.all.first else { return XCTFail("no refusal") }
        XCTAssertTrue(error.isCredentialRejected)
    }

    func testASuccessfulAuthorizedCallIsReported() async {
        let (client, signals) = makeClient()
        answer(200, #"{"success":true,"data":{}}"#)
        _ = try? await client.fetchScreenTime()
        guard case .succeeded? = signals.all.first else { return XCTFail("no success, got \(signals.all)") }
    }

    /// The self-unpair's own DEVICE_UNPAIRED is the Settings flow's business.
    func testTheSelfUnpairRouteIsNotReported() async {
        let (client, signals) = makeClient()
        answer(401, #"{"success":false,"errorCode":"DEVICE_UNPAIRED"}"#)
        _ = await client.unpairDevice(pin: "1234")
        XCTAssertTrue(signals.all.isEmpty)
    }

    /// A 5xx says nothing about the pairing.
    func testAServerErrorIsNotReported() async {
        let (client, signals) = makeClient()
        answer(500, #"{"success":false}"#)
        _ = try? await client.fetchScreenTime()
        XCTAssertTrue(signals.all.isEmpty)
    }

    func testHealthIsAtTheAPIRoot() {
        XCTAssertEqual(
            OilaDeviceClient.healthURL(baseURL: URL(string: "https://api.oila360.uz/api/v1")!)?.absoluteString,
            "https://api.oila360.uz/health"
        )
    }

    func testHealthIsTrueOnlyForA200() async {
        let (client, _) = makeClient()
        answer(200, #"{"status":"ok"}"#)
        let up = await client.checkHealth()
        XCTAssertTrue(up)
        XCTAssertEqual(TestHTTPURLProtocol.recordedRequests.last?.url?.absoluteString, "https://test.local/health")
        XCTAssertNil(TestHTTPURLProtocol.recordedRequests.last?.value(forHTTPHeaderField: "Authorization"))
        answer(503, #"{"status":"error"}"#)
        let down = await client.checkHealth()
        XCTAssertFalse(down)
    }
}

// MARK: The App Group sweep the reset runs twice

final class SessionStoreAppGroupPurgeTests: XCTestCase {
    /// Everything the extension wrote goes — the revocation marker included — and the language stays,
    /// so the language screen the reset lands on comes back preselected.
    func testThePurgeKeepsOnlyTheLanguage() {
        let suiteName = "SessionStorePurgeTests.\(UUID().uuidString)"
        let groupName = "SessionStorePurgeGroup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let group = UserDefaults(suiteName: groupName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            group.removePersistentDomain(forName: groupName)
            L10n.setLanguage(AppLanguage.defaultForDevice.rawValue)
        }
        defaults.set(AppLanguage.ru.rawValue, forKey: "APP_LANGUAGE")
        let store = SessionStore(userDefaults: defaults, secureTokens: SecureTokenStoreStub(access: nil),
                                 deviceTokens: SecureTokenStoreStub(access: nil), appGroupIdentifier: groupName)
        group.set(1_800_000_000.0, forKey: PairingResetCoordinator.extensionRevokedAtKey)
        group.set("snapshot", forKey: "SOME_EXTENSION_KEY")

        store.purgeAppGroupContainer()

        let reread = UserDefaults(suiteName: groupName)!
        XCTAssertNil(reread.object(forKey: PairingResetCoordinator.extensionRevokedAtKey))
        XCTAssertNil(reread.object(forKey: "SOME_EXTENSION_KEY"))
        XCTAssertEqual(reread.string(forKey: "APP_LANGUAGE"), AppLanguage.ru.rawValue)
    }
}

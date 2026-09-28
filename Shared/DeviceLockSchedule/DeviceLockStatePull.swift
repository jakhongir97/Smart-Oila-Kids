import Foundation

// MARK: - The server ended the pairing (seen from an extension)

/// What an extension heard about the pairing, kept in the App Group for the app.
///
/// The monitor extension is often the only process awake on a child's phone, so it is often the
/// first to hear `401 DEVICE_UNPAIRED`. It cannot unpair the app (no Keychain of the app's, no
/// scene); it writes `revokedAtKey` and the app wipes itself on its next launch.
///
/// One answer is not enough, for the same reason the app confirms its own (`confirmAndInvalidate`,
/// a probe 30–120 s later): a backend blip must not wipe every child's pairing at once. The first
/// DEVICE_UNPAIRED is only SUSPECTED; a second one at least `confirmationGap` later, with no
/// answered request in between, confirms it.
enum DevicePairingRevocation {
    /// Epoch seconds (Double) when an extension confirmed the server ended the pairing. The app
    /// reads it on launch and clears it when it pairs again.
    static let revokedAtKey = "PAIRING_REVOKED_AT_V1"
    /// Epoch seconds of the first unconfirmed DEVICE_UNPAIRED answer.
    static let suspectedAtKey = "PAIRING_UNPAIRED_SUSPECTED_AT_V1"
    /// The shortest gap between the two answers that confirm: the app's own shortest probe delay.
    static let confirmationGap: TimeInterval = 30

    enum Verdict: Equatable {
        case suspected
        case confirmed
    }

    static func revokedAt(userDefaults: UserDefaults?) -> Date? {
        guard let raw = userDefaults?.object(forKey: revokedAtKey) as? Double, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    static func markRevoked(at date: Date, userDefaults: UserDefaults?) {
        userDefaults?.set(date.timeIntervalSince1970, forKey: revokedAtKey)
        userDefaults?.removeObject(forKey: suspectedAtKey)
    }

    /// For the app, once it has wiped itself or paired again.
    static func clear(userDefaults: UserDefaults?) {
        userDefaults?.removeObject(forKey: revokedAtKey)
        userDefaults?.removeObject(forKey: suspectedAtKey)
    }

    /// Whether an extension should stay off the network: the pairing was revoked and the app has
    /// not published a credential since (a new pairing publishes a fresh copy, `updatedAt` later).
    static func isRevoked(credentialUpdatedAt: Date?, userDefaults: UserDefaults?) -> Bool {
        guard let revokedAt = revokedAt(userDefaults: userDefaults) else { return false }
        guard let credentialUpdatedAt else { return true }
        return credentialUpdatedAt <= revokedAt
    }

    /// One `401 DEVICE_UNPAIRED` at `now`. Confirmed only when an earlier one is on record at least
    /// `confirmationGap` before it; a record in the future (a clock wound back) starts again.
    static func recordUnpairedAnswer(at now: Date, userDefaults: UserDefaults?) -> Verdict {
        if let raw = userDefaults?.object(forKey: suspectedAtKey) as? Double, raw > 0 {
            let gap = now.timeIntervalSince(Date(timeIntervalSince1970: raw))
            if gap >= confirmationGap { return .confirmed }
            if gap >= 0 { return .suspected }
        }
        userDefaults?.set(now.timeIntervalSince1970, forKey: suspectedAtKey)
        return .suspected
    }

    /// Any answered request: the pairing is alive, and an earlier DEVICE_UNPAIRED was a blip.
    static func recordAnsweredContact(userDefaults: UserDefaults?) {
        userDefaults?.removeObject(forKey: suspectedAtKey)
    }

    /// `{"success":false,"errorCode":"DEVICE_UNPAIRED",...}` under a 401 — the one answer that
    /// says the pairing is gone (a bare 401 or UNAUTHORIZED is a token problem, never an unpair).
    static func isDeviceUnpairedAnswer(status: Int, body: Data?) -> Bool {
        guard status == 401, let body,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        return OilaTolerantJSON.nonEmpty(json["errorCode"] as? String) == deviceUnpairedCode
    }

    /// `OilaAPIError.deviceUnpairedCode`, which the extensions cannot see.
    static let deviceUnpairedCode = "DEVICE_UNPAIRED"
}

/// A confirmed unpair, from an extension: a phone that left the family must not stay locked by it.
/// The same teardown as the app's `clearLockPolicy` (snapshot, OS shield, edges, heartbeat), plus
/// the App Group record the app acts on.
enum DeviceLockUnpairTeardown {
    struct Actions {
        /// Writes the two whole-device keys back to unlocked on the default store.
        var releaseWholeDevice: () -> Void
        /// Stops every lock-edge activity and the daily heartbeat.
        var stopEdgesAndHeartbeat: () -> Void
        /// Tells a running app (the Darwin notification it already follows).
        var announce: () -> Void

        static var live: Actions {
            Actions(
                releaseWholeDevice: { DeviceLockPolicy.applyWholeDevice(locked: false) },
                stopEdgesAndHeartbeat: {
                    DeviceLockEdgeMonitoring.stopAll(center: LiveDeviceLockEdgeCenter())
                    DeviceLockHeartbeat.stopAll()
                },
                announce: { DeviceLockEdgeMonitoring.postDidEvaluate() }
            )
        }
    }

    static func perform(now: Date, store: DeviceLockPolicySharedStore, userDefaults: UserDefaults?, actions: Actions) {
        store.clear()
        actions.releaseWholeDevice()
        actions.stopEdgesAndHeartbeat()
        DevicePairingRevocation.markRevoked(at: now, userDefaults: userDefaults)
        actions.announce()
    }
}

// MARK: - The monitor extension's own `GET /device/lock/state`

/// The lock policy, fetched by the schedule-monitor extension (build 29).
///
/// A parent's lock reached a suspended or force-quit app only through a silent push, which iOS
/// throttles, holds and drops (ANALYSIS_2026-09-28, lock-delivery-silent-push-only). The monitor
/// extension is the one process iOS reliably wakes while the child is USING the phone — every
/// device-total usage step, whatever the app's state, Low Power Mode or APNs — so it asks the
/// server itself there (and on the daily heartbeat), saves the snapshot the app would have saved,
/// and the caller re-evaluates. A lock lands within one step of use; an early unlock lands at the
/// next step too.
///
/// Bounded for an extension (≈6 MB, short synchronous callbacks): one ephemeral request, waited on
/// a semaphore for at most `requestTimeout`, at most once per `minimumInterval`, no retries.
enum DeviceLockStatePull {
    static let minimumInterval: TimeInterval = 60
    static let requestTimeout: TimeInterval = 8
    /// Epoch seconds of the last pull ATTEMPT (stamped before sending, so a failing server is not
    /// asked on every step either).
    static let lastAttemptKey = "DEVICE_LOCK_PULL_ATTEMPTED_AT_V1"

    /// One HTTP answer, or none.
    enum Answer: Equatable {
        case http(status: Int, body: Data)
        case failed(String)
    }

    typealias Transport = (URLRequest, DispatchTime) -> Answer

    enum Outcome: Equatable {
        /// Nothing sent: `rate_limited`, `no_credential` or `revoked`.
        case skipped(String)
        /// No usable answer: a transport error, the deadline, or an HTTP error other than an unpair.
        case failed(String)
        /// A 2xx with no lock information at all: the saved snapshot is KEPT (never lock or unlock
        /// on a shape nobody understands).
        case unrecognized
        /// The policy was saved; `changed` when it says something different from before.
        case saved(changed: Bool)
        case unpairedSuspected
        case unpairedConfirmed
    }

    struct Environment {
        var store: DeviceLockPolicySharedStore
        var userDefaults: UserDefaults?
        var clock: DeviceLockClock
        var transport: Transport
        var teardown: DeviceLockUnpairTeardown.Actions

        static var live: Environment {
            Environment(
                store: DeviceLockPolicySharedStore(),
                userDefaults: ScreenTimeUsageAppGroup.sharedUserDefaults(),
                clock: .live,
                transport: DeviceLockStatePull.liveTransport,
                teardown: .live
            )
        }
    }

    /// Too soon after the last attempt, or after a snapshot the app itself received (a running app
    /// polls every 30 s, and asking again would only double the requests). Only a POSITIVE gap
    /// limits: a clock wound back must not silence the pull until it catches up.
    static func isRateLimited(now: Date, lastAttempt: Date?, lastReceived: Date?, minimumInterval: TimeInterval = minimumInterval) -> Bool {
        [lastAttempt, lastReceived].contains { last in
            guard let last else { return false }
            let elapsed = now.timeIntervalSince(last)
            return elapsed >= 0 && elapsed < minimumInterval
        }
    }

    static func request(credential: LocationPushSharedCredential.Payload) -> URLRequest? {
        guard let root = URL(string: credential.baseURL) else { return nil }
        var request = URLRequest(url: root.appendingPathComponent("device/lock/state"))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// One pull. The caller re-evaluates the lock when this returns `.saved(changed: true)`.
    /// `fallbackDSN` names the snapshot when none is saved yet and the credential carries no DSN.
    static func run(
        credential: LocationPushSharedCredential.Payload?,
        fallbackDSN: String?,
        environment: Environment
    ) -> Outcome {
        let defaults = environment.userDefaults
        let clock = environment.clock
        let now = clock.wallNow()
        guard let credential, let request = request(credential: credential) else { return .skipped("no_credential") }
        if DevicePairingRevocation.isRevoked(credentialUpdatedAt: credential.updatedAt, userDefaults: defaults) {
            return .skipped("revoked")
        }
        let previous = environment.store.load()
        let lastAttempt = (defaults?.object(forKey: lastAttemptKey) as? Double).map(Date.init(timeIntervalSince1970:))
        if isRateLimited(now: now, lastAttempt: lastAttempt, lastReceived: previous?.receivedAt) {
            return .skipped("rate_limited")
        }
        defaults?.set(now.timeIntervalSince1970, forKey: lastAttemptKey)

        // Both clocks on both sides of the request, exactly as the app's poll: the anchor sits at
        // its midpoint.
        let sentWall = clock.wallNow()
        let sentMonotonic = clock.monotonicNanos()
        let answer = environment.transport(request, .now() + requestTimeout)
        let receivedMonotonic = clock.monotonicNanos()

        switch answer {
        case .failed(let why):
            return .failed(why)
        case let .http(status, body):
            if DevicePairingRevocation.isDeviceUnpairedAnswer(status: status, body: body) {
                return handleUnpairedAnswer(now: clock.wallNow(), environment: environment)
            }
            guard (200 ..< 300).contains(status) else { return .failed("http_\(status)") }
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            // The app's envelope rule (`OilaDeviceClient.send`): `success` defaults to true, and
            // the payload is `data`.
            guard (json?["success"] as? Bool) ?? true else { return .failed("envelope_refused") }
            DevicePairingRevocation.recordAnsweredContact(userDefaults: defaults)
            let object = (json?["data"] as? [String: Any]) ?? [:]
            let state = DeviceLockStateParser.parseLockState(from: object)
            let anchor = DeviceLockClock.anchor(
                serverTime: state.serverTime,
                sentWall: sentWall,
                sentMonotonicNanos: sentMonotonic,
                receivedMonotonicNanos: receivedMonotonic,
                bootSessionID: clock.bootSessionID(),
                previous: previous?.clock
            )
            let dsn = previous?.dsn
                ?? DeviceLockEdgeActivityIdentifier.normalize(credential.dsn ?? fallbackDSN ?? "unpaired")
            guard let snapshot = DeviceLockPolicySnapshot.fromLockState(state, dsn: dsn, anchor: anchor) else {
                return .unrecognized
            }
            environment.store.save(snapshot)
            return .saved(changed: !snapshot.hasSamePolicy(as: previous))
        }
    }

    /// A `401 DEVICE_UNPAIRED` from any extension request (this GET or the usage upload): suspect,
    /// or — the second time — tear the lock down and leave the app its record.
    static func handleUnpairedAnswer(now: Date, environment: Environment) -> Outcome {
        switch DevicePairingRevocation.recordUnpairedAnswer(at: now, userDefaults: environment.userDefaults) {
        case .suspected:
            return .unpairedSuspected
        case .confirmed:
            DeviceLockUnpairTeardown.perform(
                now: now, store: environment.store, userDefaults: environment.userDefaults, actions: environment.teardown
            )
            return .unpairedConfirmed
        }
    }

    /// One ephemeral request, waited on for at most `deadline`: a monitor callback is synchronous
    /// and the process may be suspended the moment it returns.
    static func liveTransport(_ request: URLRequest, _ deadline: DispatchTime) -> Answer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let semaphore = DispatchSemaphore(value: 0)
        let box = AnswerBox()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                box.set(.failed(String(describing: error)))
            } else if let http = response as? HTTPURLResponse {
                box.set(.http(status: http.statusCode, body: data ?? Data()))
            } else {
                box.set(.failed("no_http_response"))
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: deadline) == .timedOut {
            task.cancel()
        }
        return box.get()
    }

    private final class AnswerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Answer = .failed("timeout")
        func set(_ answer: Answer) { lock.lock(); value = answer; lock.unlock() }
        func get() -> Answer { lock.lock(); defer { lock.unlock() }; return value }
    }
}

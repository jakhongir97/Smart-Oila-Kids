import CryptoKit
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
/// DEVICE_UNPAIRED is only SUSPECTED; a second one between `confirmationGap` and
/// `confirmationWindow` later, with no answered request in between, confirms it. Any other HTTP
/// answer (a 2xx, a 5xx, a refused token) from the extension or the app clears the suspicion, and a
/// suspicion older than the window is only a new suspicion (b29 review): one stale record must never
/// turn the two-answer rule into a one-answer rule days later.
///
/// The revocation is tied to the TOKEN that was refused (a SHA-256 fingerprint), never to a wall
/// clock the child can move: any other credential — a new pairing, even one published while the
/// refused request was still in flight — is not revoked. Pairing also clears both records
/// (`OilaDeviceClient.pair`), which is the contract the app side relies on.
enum DevicePairingRevocation {
    /// Epoch seconds (Double) when an extension confirmed the server ended the pairing. The app
    /// reads it on launch; a successful pairing clears it.
    static let revokedAtKey = "PAIRING_REVOKED_AT_V1"
    /// Hex SHA-256 of the access token the server refused (never the token itself).
    static let revokedTokenKey = "PAIRING_REVOKED_TOKEN_V1"
    /// Epoch seconds of the first unconfirmed DEVICE_UNPAIRED answer.
    static let suspectedAtKey = "PAIRING_UNPAIRED_SUSPECTED_AT_V1"
    /// The shortest gap between the two answers that confirm: the app's own shortest probe delay.
    static let confirmationGap: TimeInterval = 30
    /// The longest: the app's longest probe (120 s) with slack for the usage-step cadence (60 s,
    /// then 300 s of use). Beyond it the older answer says nothing about the pairing now.
    static let confirmationWindow: TimeInterval = 15 * 60

    enum Verdict: Equatable {
        case suspected
        case confirmed
    }

    static func revokedAt(userDefaults: UserDefaults?) -> Date? {
        guard let raw = userDefaults?.object(forKey: revokedAtKey) as? Double, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    /// `refusedAccessToken` is the token the server answered DEVICE_UNPAIRED to; nil when unknown,
    /// and then only a newer `updatedAt` un-revokes (the fallback rule).
    static func markRevoked(at date: Date, refusedAccessToken: String?, userDefaults: UserDefaults?) {
        userDefaults?.set(date.timeIntervalSince1970, forKey: revokedAtKey)
        if let refusedAccessToken {
            userDefaults?.set(fingerprint(refusedAccessToken), forKey: revokedTokenKey)
        } else {
            userDefaults?.removeObject(forKey: revokedTokenKey)
        }
        userDefaults?.removeObject(forKey: suspectedAtKey)
    }

    /// For the app, once it has wiped itself or paired again.
    static func clear(userDefaults: UserDefaults?) {
        userDefaults?.removeObject(forKey: revokedAtKey)
        userDefaults?.removeObject(forKey: revokedTokenKey)
        userDefaults?.removeObject(forKey: suspectedAtKey)
    }

    /// Whether an extension should stay off the network: the pairing was revoked and the credential
    /// it holds is the one the server refused.
    static func isRevoked(credential: LocationPushSharedCredential.Payload?, userDefaults: UserDefaults?) -> Bool {
        guard let revokedAt = revokedAt(userDefaults: userDefaults) else { return false }
        guard let credential else { return true }
        if let refused = userDefaults?.string(forKey: revokedTokenKey) {
            return fingerprint(credential.accessToken) == refused
        }
        return credential.updatedAt <= revokedAt
    }

    /// One `401 DEVICE_UNPAIRED` at `now`. Confirmed only when an earlier one is on record between
    /// `confirmationGap` and `confirmationWindow` before it; a record older than that, or in the
    /// future (a clock wound back), is replaced and this answer is a new suspicion.
    static func recordUnpairedAnswer(at now: Date, userDefaults: UserDefaults?) -> Verdict {
        if let raw = userDefaults?.object(forKey: suspectedAtKey) as? Double, raw > 0 {
            let gap = now.timeIntervalSince(Date(timeIntervalSince1970: raw))
            if gap >= confirmationGap && gap <= confirmationWindow { return .confirmed }
            if gap >= 0 && gap < confirmationGap { return .suspected }
        }
        userDefaults?.set(now.timeIntervalSince1970, forKey: suspectedAtKey)
        return .suspected
    }

    /// Any answered request other than DEVICE_UNPAIRED — from an extension or the app: the pairing
    /// is alive, and an earlier DEVICE_UNPAIRED was a blip.
    static func recordAnsweredContact(userDefaults: UserDefaults?) {
        guard userDefaults?.object(forKey: suspectedAtKey) != nil else { return }
        userDefaults?.removeObject(forKey: suspectedAtKey)
    }

    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
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

    static func perform(
        now: Date,
        refusedAccessToken: String?,
        store: DeviceLockPolicySharedStore,
        userDefaults: UserDefaults?,
        actions: Actions
    ) {
        store.clear()
        actions.releaseWholeDevice()
        actions.stopEdgesAndHeartbeat()
        DevicePairingRevocation.markRevoked(at: now, refusedAccessToken: refusedAccessToken, userDefaults: userDefaults)
        actions.announce()
    }
}

// MARK: - The monitor extension's own `GET /device/lock/state`

/// The lock policy, fetched by the schedule-monitor extension (build 29).
///
/// A parent's lock reached a suspended or force-quit app only through a silent push, which iOS
/// throttles, holds and drops (ANALYSIS_2026-09-28, lock-delivery-silent-push-only). The monitor
/// extension is the one process iOS reliably wakes while the child is USING the phone — every
/// usage step (device-total with "All Apps & Categories", per-app otherwise), whatever the app's
/// state, Low Power Mode or APNs — so it asks the server itself there (and on the daily heartbeat,
/// which exists only while the policy has edges), saves the snapshot the app would have saved, and
/// the caller re-evaluates. A lock lands within one step of use; an early unlock lands at the next
/// step too. A phone with no usage selection at all gets no steps, only the heartbeat.
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
        /// The credential as the app has published it NOW, re-read just before a confirmed unpair
        /// tears anything down: a new pairing published while the refused request was in flight
        /// must not be torn down with the old one. nil = none readable (teardown proceeds).
        var currentCredential: () -> LocationPushSharedCredential.Payload? = { nil }

        static var live: Environment {
            Environment(
                store: DeviceLockPolicySharedStore(),
                userDefaults: ScreenTimeUsageAppGroup.sharedUserDefaults(),
                clock: .live,
                transport: DeviceLockStatePull.liveTransport,
                teardown: .live,
                currentCredential: { LocationPushSharedCredential.read().payload }
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

    /// One pull. The caller re-evaluates the lock after any `.saved` (a same policy can still carry
    /// a new clock anchor that flips the verdict).
    /// `fallbackDSN` names the snapshot when none is saved yet and the credential carries no DSN.
    static func run(
        credential: LocationPushSharedCredential.Payload?,
        fallbackDSN: String?,
        environment: Environment
    ) -> Outcome {
        run(readCredential: { credential }, fallbackDSN: fallbackDSN, environment: environment)
    }

    /// `readCredential` is called only once the rate limit has let the pull through: a Keychain
    /// read is the slowest thing a skipped pull could do, and per-app rungs arrive in bursts.
    static func run(
        readCredential: () -> LocationPushSharedCredential.Payload?,
        fallbackDSN: String?,
        environment: Environment
    ) -> Outcome {
        let defaults = environment.userDefaults
        let clock = environment.clock
        let now = clock.wallNow()
        let previous = environment.store.load()
        let lastAttempt = (defaults?.object(forKey: lastAttemptKey) as? Double).map(Date.init(timeIntervalSince1970:))
        if isRateLimited(now: now, lastAttempt: lastAttempt, lastReceived: previous?.receivedAt) {
            return .skipped("rate_limited")
        }
        guard let credential = readCredential(), let request = request(credential: credential) else {
            return .skipped("no_credential")
        }
        if DevicePairingRevocation.isRevoked(credential: credential, userDefaults: defaults) {
            return .skipped("revoked")
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
                return handleUnpairedAnswer(now: clock.wallNow(), refused: credential, environment: environment)
            }
            // Answered, and not with DEVICE_UNPAIRED: the pairing is alive (the app's probe keeps
            // the session on any other answer too, 5xx and refused tokens included).
            DevicePairingRevocation.recordAnsweredContact(userDefaults: defaults)
            guard (200 ..< 300).contains(status) else { return .failed("http_\(status)") }
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            // The app's envelope rule (`OilaDeviceClient.send`): `success` defaults to true, and
            // the payload is `data`.
            guard (json?["success"] as? Bool) ?? true else { return .failed("envelope_refused") }
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
            // Someone (the app, woken by a push) saved an answer received AFTER this request left:
            // it is at least as fresh as this one, and writing over it could put back a policy the
            // parent has just changed (b29 review). Its own evaluation already made the OS follow.
            let current = environment.store.load()
            if let current, current.receivedAt > sentWall, current.receivedAt != previous?.receivedAt {
                return .skipped("superseded")
            }
            environment.store.save(snapshot)
            return .saved(changed: !snapshot.hasSamePolicy(as: current))
        }
    }

    /// A `401 DEVICE_UNPAIRED` to `refused` from any extension request (this GET or the usage
    /// upload): suspect, or — the second time — tear the lock down and leave the app its record.
    /// A confirmation is dropped when the app has published a different credential since the
    /// request left (a new pairing): that pairing is not the one the server refused.
    static func handleUnpairedAnswer(
        now: Date,
        refused: LocationPushSharedCredential.Payload?,
        environment: Environment
    ) -> Outcome {
        switch DevicePairingRevocation.recordUnpairedAnswer(at: now, userDefaults: environment.userDefaults) {
        case .suspected:
            return .unpairedSuspected
        case .confirmed:
            if let refused, let current = environment.currentCredential(), current.accessToken != refused.accessToken {
                DevicePairingRevocation.recordAnsweredContact(userDefaults: environment.userDefaults)
                return .skipped("credential_changed")
            }
            DeviceLockUnpairTeardown.perform(
                now: now,
                refusedAccessToken: refused?.accessToken,
                store: environment.store,
                userDefaults: environment.userDefaults,
                actions: environment.teardown
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

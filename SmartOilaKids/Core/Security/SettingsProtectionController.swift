import Foundation
import Security
import Combine

// MARK: - The parent's unpair PIN lives on the SERVER (build 26)
//
// Through build 25 this file held a LOCAL parent PIN: a Keychain PBKDF2 verifier created on the
// child's own phone (first-run sheet on Home, set/change/remove rows in Settings), checked before the
// unpair request was even sent. The product owner retired it on 2026-09-23:
//
//   "PIN manti'gi o'zgargan. Hozir PINni bola telefonida o'rnatilmaydi. PIN ota-onada o'rnatiladi.
//    Shunga UZISH qilganda siz PIN so'raysiz doim. PIN olib API ga zapros berasiz. Success kelsa
//    uzasiz aks holda yo'q."
//
// So the PIN is set by the parent (`PUT /parent/children/{id}/unpair-pin`, a scrypt hash this app
// never sees), the disconnect screen ALWAYS shows the keypad (the user chose "always keypad" over the
// backend's `unpairPinRequired` flag on 2026-09-24), and ONLY the server's yes disconnects. What is
// left here is what the phone still owns: the brute-force ladder in front of the server's
// 10-a-minute limit, the outcome -> screen mapping, and the one-time removal of the old verifier.

/// Resolves how much of a disconnect-PIN lockout is left, on a clock the child does not own.
///
/// The escalating ladder (1min → 24h) is the only thing making a 4-digit PIN expensive to guess, and
/// it was enforced entirely against `Date()`. The device belongs to the person the lockout is
/// defending against: Settings → General → Date & Time, push the date forward, and every tier
/// evaporates — 5 guesses, change the date, 5 more, for the whole 10,000-value space.
///
/// The deadline is therefore also recorded on `ProcessInfo.systemUptime`, which no setting can move.
/// Because uptime resets on reboot, a boot anchor (`wall clock − uptime`) says whether the monotonic
/// deadline still belongs to this boot. When it does not — a genuine reboot, OR a clock change, which
/// are indistinguishable from inside the app — the resolver FAILS CLOSED and restarts the current
/// tier rather than trusting a wall-clock deadline the child may have just walked past.
enum PINLockoutClock {
    /// Boot-anchor drift tolerated as "same boot". `systemUptime` and `Date()` drift slightly against
    /// each other, and an NTP correction is normally sub-second; the attack needs a shift of minutes
    /// to hours, so this is nowhere near large enough to enable it.
    static let bootAnchorTolerance: TimeInterval = 30

    enum Resolution: Equatable {
        /// No lockout is running.
        case clear
        /// Seconds still to serve, measured monotonically.
        case locked(remaining: TimeInterval)
        /// The anchors no longer describe this boot. The caller must restart the tier's full penalty.
        case restart
    }

    /// - Parameters:
    ///   - uptimeUntil: persisted `systemUptime` deadline, or nil when none was recorded.
    ///   - bootAnchor: persisted `wall clock − systemUptime` at the moment the lockout began.
    ///   - now / uptime: today's readings of the two clocks.
    static func resolve(
        uptimeUntil: TimeInterval?,
        bootAnchor: TimeInterval?,
        now: Date,
        uptime: TimeInterval
    ) -> Resolution {
        guard let uptimeUntil, let bootAnchor else { return .clear }
        let currentAnchor = now.timeIntervalSince1970 - uptime
        guard abs(currentAnchor - bootAnchor) <= bootAnchorTolerance else { return .restart }
        let remaining = uptimeUntil - uptime
        return remaining > 0 ? .locked(remaining: remaining) : .clear
    }
}

/// The phone's own brake on guessing the parent's PIN, fed by the SERVER's `403 UNPAIR_PIN_INVALID`.
///
/// The backend throttles `POST /device/unpair` at 10 attempts a minute, which walks all 10 000
/// four-digit codes in about 17 hours. The escalating ladder that used to guard the local PIN
/// (1 min → 5 min → 15 min → 1 h → 24 h after every 5 misses) is kept and now counts the server's
/// refusals instead, which puts the same search at weeks. It persists in UserDefaults — clearing it
/// means deleting the app, which `denyAppRemoval` refuses and which would lose the credential anyway —
/// and it is measured on the monotonic clock (`PINLockoutClock`) so moving the date does not end it.
@MainActor
final class UnpairPINThrottle: ObservableObject {
    static let shared = UnpairPINThrottle()

    /// End of the running lockout, for the countdown text. The authority is `remaining`.
    @Published private(set) var lockedUntil: Date?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let persisted = userDefaults.double(forKey: Self.lockUntilKey)
        if persisted > Date().timeIntervalSince1970 {
            lockedUntil = Date(timeIntervalSince1970: persisted)
        }
    }

    /// Seconds left to serve, or nil when a PIN may be sent. Re-resolved against the monotonic clock
    /// on every read; a reboot or a clock change restarts the current tier rather than ending it.
    var remaining: TimeInterval? {
        let resolution = PINLockoutClock.resolve(
            uptimeUntil: userDefaults.object(forKey: Self.lockUptimeUntilKey) as? TimeInterval,
            bootAnchor: userDefaults.object(forKey: Self.lockBootAnchorKey) as? TimeInterval,
            now: Date(),
            uptime: ProcessInfo.processInfo.systemUptime
        )
        switch resolution {
        case .clear:
            if lockedUntil != nil { clearDeadline() }
            return nil
        case let .locked(remaining):
            if lockedUntil == nil { lockedUntil = Date().addingTimeInterval(remaining) }
            return remaining
        case .restart:
            // `tierKey` already points one past the tier that was served; serve that tier again.
            let tier = max(userDefaults.integer(forKey: Self.tierKey) - 1, 0)
            let duration = Self.ladder[min(tier, Self.ladder.count - 1)]
            beginLockout(duration: duration)
            return duration
        }
    }

    /// The server refused the PIN. Returns the lockout end when this miss started one.
    @discardableResult
    func recordRejectedPIN() -> Date? {
        let fails = userDefaults.integer(forKey: Self.failCountKey) + 1
        guard fails >= Self.maxAttempts else {
            userDefaults.set(fails, forKey: Self.failCountKey)
            return nil
        }
        let tier = min(userDefaults.integer(forKey: Self.tierKey), Self.ladder.count - 1)
        let until = beginLockout(duration: Self.ladder[tier])
        userDefaults.set(0, forKey: Self.failCountKey)
        userDefaults.set(min(tier + 1, Self.ladder.count - 1), forKey: Self.tierKey)
        return until
    }

    /// Clears the whole ladder. Called when the server accepted the PIN (the phone is being reset
    /// anyway) and by `wipe` on every pairing boundary.
    func reset() {
        Self.wipe(userDefaults: userDefaults)
        lockedUntil = nil
    }

    /// Re-reads the persisted deadline into `lockedUntil` without writing anything — for callers
    /// that wiped the keys through `wipe(userDefaults:)` from a nonisolated context.
    func resyncPublishedDeadline() {
        let persisted = userDefaults.double(forKey: Self.lockUntilKey)
        lockedUntil = persisted > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: persisted) : nil
    }

    /// Nonisolated twin of `reset()` for `SessionStore`, which is not main-actor isolated and must
    /// finish its purge before returning. A new family never inherits the previous one's lockout.
    nonisolated static func wipe(userDefaults: UserDefaults = .standard) {
        for key in [failCountKey, lockUntilKey, tierKey, lockUptimeUntilKey, lockBootAnchorKey] {
            userDefaults.removeObject(forKey: key)
        }
    }

    @discardableResult
    private func beginLockout(duration: TimeInterval) -> Date {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let until = now.addingTimeInterval(duration)
        userDefaults.set(until.timeIntervalSince1970, forKey: Self.lockUntilKey)
        userDefaults.set(uptime + duration, forKey: Self.lockUptimeUntilKey)
        userDefaults.set(now.timeIntervalSince1970 - uptime, forKey: Self.lockBootAnchorKey)
        lockedUntil = until
        return until
    }

    /// Drops a served deadline but keeps the fail counter and tier: only an accepted PIN (or a new
    /// pairing) walks the ladder back down.
    private func clearDeadline() {
        userDefaults.removeObject(forKey: Self.lockUntilKey)
        userDefaults.removeObject(forKey: Self.lockUptimeUntilKey)
        userDefaults.removeObject(forKey: Self.lockBootAnchorKey)
        lockedUntil = nil
    }

    private let userDefaults: UserDefaults

    // The keys are the build-25 names on purpose: a lockout running across the update keeps running.
    nonisolated static let failCountKey = "SETTINGS_PROTECTION_PIN_FAILS"
    nonisolated static let lockUntilKey = "SETTINGS_PROTECTION_PIN_LOCK_UNTIL"
    nonisolated static let tierKey = "SETTINGS_PROTECTION_PIN_LOCK_TIER"
    /// The deadline on the MONOTONIC clock (`ProcessInfo.systemUptime`).
    nonisolated static let lockUptimeUntilKey = "SETTINGS_PROTECTION_PIN_LOCK_UPTIME_UNTIL"
    /// `wall clock − systemUptime` when the lockout began, to tell this boot from another one.
    nonisolated static let lockBootAnchorKey = "SETTINGS_PROTECTION_PIN_LOCK_BOOT_ANCHOR"
    /// 1 min, 5 min, 15 min, 1 h, 24 h.
    nonisolated static let ladder: [TimeInterval] = [60, 300, 900, 3600, 86_400]
    nonisolated static let maxAttempts = 5
}

/// What the disconnect screen does with the server's answer. Pure, so the one rule the product owner
/// cares about — "success kelsa uzasiz, aks holda yo'q" — is pinned by tests rather than by a view.
enum UnpairScreenAction: Equatable {
    /// The server cut the link (or there is no credential left that could ever reach it): return the
    /// app to its freshly installed state.
    case reset
    /// Still paired. `messageKey` is the Localizable key to show; `clearDigits` empties the keypad.
    case stay(messageKey: String, clearDigits: Bool)

    static func decide(_ outcome: OilaUnpairOutcome) -> UnpairScreenAction {
        switch outcome {
        case .revoked, .credentialAbsent:
            return .reset
        case .pinRequired:
            return .stay(messageKey: "disconnect2.pin_incorrect", clearDigits: true)
        case .rateLimited:
            return .stay(messageKey: "disconnect2.rate_limited", clearDigits: true)
        case .unreachable:
            // Keep the digits: the parent typed them correctly, the network failed.
            return .stay(messageKey: "disconnect2.offline", clearDigits: false)
        case .noCredential, .credentialRejected, .routeMissing, .rejected:
            return .stay(messageKey: "disconnect2.failed", clearDigits: false)
        }
    }
}

/// One-time removal of the build-25 LOCAL PIN: the Keychain verifier survives app updates (and even
/// reinstalls), and nothing reads it any more, so it is deleted rather than left as a secret that
/// looks meaningful. Also runs on every pairing boundary via `SessionStore`.
enum LegacyLocalPINCleanup {
    nonisolated static func purge(userDefaults: UserDefaults = .standard) {
        KeychainPINCredentialStore().delete()
        for key in legacyKeys { userDefaults.removeObject(forKey: key) }
    }

    /// Every UserDefaults key the local-PIN feature ever wrote, other than the lockout ladder's
    /// (which `UnpairPINThrottle` still owns).
    nonisolated static let legacyKeys = [
        "SETTINGS_PROTECTION_ENABLED",
        "SETTINGS_PROTECTION_PIN_HASH",
        "SETTINGS_PROTECTION_FIRST_RUN_PIN_ANSWERED",
        "SETTINGS_PROTECTION_FIRST_PIN_WINDOW_CLOSED",
    ]
}

// MARK: - Legacy PIN storage (delete-only)

/// Where build 25 kept the local PIN verifier (`kSecClassGenericPassword`, service = bundle id,
/// account `settings_protection_pin_v2`). Kept only so `LegacyLocalPINCleanup` can delete it and a
/// test can plant one; nothing reads a PIN from it any more.
final class KeychainPINCredentialStore {
    private let service: String
    private let account: String

    init(
        service: String = (Bundle.main.bundleIdentifier ?? "SmartOilaKids"),
        account: String = "settings_protection_pin_v2"
    ) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func load() -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func save(_ data: Data) {
        let query = baseQuery
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ] as CFDictionary)
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

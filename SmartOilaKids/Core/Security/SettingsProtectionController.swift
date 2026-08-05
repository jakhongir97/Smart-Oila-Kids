import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import UIKit

enum SettingsProtectionPINPrompt: String, Identifiable {
    case unlock
    case create

    var id: String { rawValue }
}

@MainActor
final class SettingsProtectionController: ObservableObject {
    static let shared = SettingsProtectionController()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isDeviceAuthenticationAvailable = false
    @Published private(set) var hasCustomPIN = false
    @Published private(set) var hasActiveUnlockSession = false
    @Published private(set) var activePINPrompt: SettingsProtectionPINPrompt?
    /// End of the current disconnect-PIN lockout, or nil when not locked out. Persisted so a
    /// relaunch cannot reset a brute-force lockout.
    @Published private(set) var pinLockedUntil: Date?

    var isProtectionAvailable: Bool {
        isDeviceAuthenticationAvailable || hasCustomPIN
    }

    init(
        userDefaults: UserDefaults = .standard,
        pinStore: PINCredentialStoring = KeychainPINCredentialStore()
    ) {
        self.userDefaults = userDefaults
        self.pinStore = pinStore

        // One-time migration off the old unsalted-SHA-256-in-UserDefaults scheme. The old hash
        // can't be reversed into the new salted-KDF verifier, so we simply drop it; a parent
        // re-sets the PIN under the hardened scheme. (Pre-release, so no live PINs are lost.)
        userDefaults.removeObject(forKey: legacyPINHashKey)

        if userDefaults.object(forKey: protectionEnabledKey) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = userDefaults.bool(forKey: protectionEnabledKey)
        }

        let persistedLock = userDefaults.double(forKey: pinLockUntilKey)
        if persistedLock > Date().timeIntervalSince1970 {
            self.pinLockedUntil = Date(timeIntervalSince1970: persistedLock)
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cancelPINPrompt()
                self?.clearUnlockSession()
            }
        }

        refreshAvailability()
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    func refreshAvailability() {
        let context = LAContext()
        var error: NSError?
        let canAuthenticate = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        isDeviceAuthenticationAvailable = canAuthenticate
        hasCustomPIN = pinStore.load() != nil

        guard isProtectionAvailable else {
            if isEnabled {
                setEnabled(false)
            } else {
                clearUnlockSession()
            }
            return
        }

        hasActiveUnlockSession = unlockSessionExpiration.map { $0 > Date() } ?? false
    }

    @discardableResult
    func enableProtection() -> Bool {
        refreshAvailability()
        guard isProtectionAvailable else { return false }
        setEnabled(true)
        return true
    }

    func disableProtection() {
        setEnabled(false)
    }

    func configureCustomPIN() async -> Bool {
        await presentPINPrompt(.create)
    }

    func removeCustomPIN() {
        guard hasCustomPIN else { return }
        pinStore.delete()
        clearLockoutState()
        refreshAvailability()
    }

    /// Wipe every trace of the previous family's settings PIN. Called from the disconnect purge.
    ///
    /// The verifier lives device-globally in the Keychain (`settings_protection_pin_v2`,
    /// AfterFirstUnlockThisDeviceOnly) while the purge only regenerated the DSN and cleared two
    /// caches — so it SURVIVED an unpair. After a re-pair `hasCustomPIN` was still true, which meant
    /// the new parent was offered only "change PIN" and "remove PIN", both of which demand the
    /// PREVIOUS family's secret, and the disconnect flow opened straight into verification against
    /// that stale verifier with a persisted lockout. On a resold or handed-down phone the previous
    /// owner effectively retained on-device disconnect authority over another family's child.
    ///
    /// Unconditional (no `hasCustomPIN` guard) so a Keychain read failure cannot skip the wipe.
    func resetForNewPairing() {
        pinStore.delete()
        clearLockoutState()
        refreshAvailability()
    }

    /// Synchronous, nonisolated wipe of the PERSISTED PIN + lockout.
    ///
    /// `SessionStore.purgeChildScopedData()` is not main-actor isolated and must complete before the
    /// disconnect returns, so it cannot await this controller. Hopping to the main actor instead
    /// would let the purge return while the previous family's verifier was still on disk. This
    /// writes the same storage the instance methods do (keys shared as statics above); the observable
    /// `hasCustomPIN` is refreshed separately.
    nonisolated static func wipePersistedPINState(userDefaults: UserDefaults = .standard) {
        KeychainPINCredentialStore().delete()
        userDefaults.removeObject(forKey: pinFailCountKey)
        userDefaults.removeObject(forKey: pinLockUntilKey)
        userDefaults.removeObject(forKey: pinLockoutTierKey)
    }

    private func clearLockoutState() {
        userDefaults.removeObject(forKey: pinFailCountKey)
        userDefaults.removeObject(forKey: pinLockUntilKey)
        userDefaults.removeObject(forKey: pinLockoutTierKey)
        pinLockedUntil = nil
    }

    func submitPINPrompt(pin: String, confirmation: String?) -> String? {
        guard let activePINPrompt else { return nil }

        let normalizedPIN = normalizePIN(pin)
        guard normalizedPIN.count == pinLength else {
            return L10n.tr("settings.control_protection_pin_invalid")
        }

        switch activePINPrompt {
        case .unlock:
            // Enforce the brute-force lockout on this path too. It was previously enforced only by
            // the disconnect screen's own gate, so any UI wired to this prompt would have been an
            // un-rate-limited oracle for the same shared PIN.
            if pinLockRemaining != nil {
                return L10n.tr("settings.control_protection_pin_incorrect")
            }
            guard verify(normalizedPIN) else {
                recordPINAttempt(success: false)
                return L10n.tr("settings.control_protection_pin_incorrect")
            }
            recordPINAttempt(success: true)
            startUnlockSession()
            completePINPrompt(result: true)
            return nil
        case .create:
            let normalizedConfirmation = normalizePIN(confirmation ?? "")
            guard normalizedConfirmation.count == pinLength else {
                return L10n.tr("settings.control_protection_pin_invalid")
            }
            guard normalizedPIN == normalizedConfirmation else {
                return L10n.tr("settings.control_protection_pin_mismatch")
            }
            pinStore.save(makeRecord(for: normalizedPIN))
            startUnlockSession()
            refreshAvailability()
            completePINPrompt(result: true)
            return nil
        }
    }

    func cancelPINPrompt() {
        guard activePINPrompt != nil || pinPromptContinuation != nil else { return }
        activePINPrompt = nil
        pinPromptContinuation?.resume(returning: false)
        pinPromptContinuation = nil
    }

    // MARK: - Direct gate (used by the Bolajon360 disconnect screen)
    //
    // The disconnect screen owns its own lavender PIN field, so it validates the entered
    // PIN directly rather than through the `activePINPrompt` continuation UI. These are pure
    // and synchronous (except the biometric wrapper) so they are unit-testable.

    /// True when `pin` matches the stored custom PIN. False if no custom PIN is set or the
    /// input is the wrong length. Never throws — safe to call on every keystroke.
    func verifyCustomPIN(_ pin: String) -> Bool {
        // Deny (without recording an attempt — this is called on every keystroke) while a lockout
        // is active, so no caller can turn live verification into an unlimited guessing oracle.
        guard pinLockRemaining == nil else { return false }
        let normalized = normalizePIN(pin)
        guard normalized.count == pinLength else { return false }
        return verify(normalized)
    }

    /// Stores a new custom PIN (used by the Settings provisioning flow and by the disconnect
    /// create-flow when none exists yet). Returns false when the input isn't exactly `pinLength`
    /// digits.
    @discardableResult
    func saveCustomPIN(_ pin: String) -> Bool {
        let normalized = normalizePIN(pin)
        guard normalized.count == pinLength else { return false }
        pinStore.save(makeRecord(for: normalized))
        // Confirm the record actually landed. `PINCredentialStoring.save` returns Void, so a
        // Keychain rejection would otherwise be swallowed and this method would claim success while
        // leaving the parent with no PIN at all — the same silent-failure class this release is
        // fixing in SecureTokenStore. Verifying the just-chosen PIN round-trips proves the write.
        guard verify(normalized) else { return false }
        // A lockout is a rate limit on guessing the OLD secret; carrying it over would leave the
        // parent unable to use the PIN they just chose. Reaching this point already required
        // authorization (the current PIN, or the post-pairing window for the very first one).
        recordPINAttempt(success: true)
        startUnlockSession()
        refreshAvailability()
        return true
    }

    // NOTE: there is deliberately no biometric / device-passcode unlock here. This screen runs on the
    // CHILD's phone, where Face ID, Touch ID and the passcode all belong to the child — see the note
    // in `BolajonSettingsView.DisconnectView`. The app therefore never calls
    // `LAContext.evaluatePolicy`, and `NSFaceIDUsageDescription` has been removed from Info.plist to
    // match. The `canEvaluatePolicy` probe in `refreshAvailability()` needs no usage description.

    // MARK: - Disconnect-PIN brute-force lockout
    //
    // The disconnect gate is the one control keeping a monitored child linked, so guessing the
    // parent PIN must be rate-limited. Attempts and the lockout deadline are persisted, so a
    // relaunch (or a reinstall that preserves UserDefaults via a backup) cannot reset them.

    /// Seconds remaining on the disconnect-PIN lockout, or nil when entry is currently allowed.
    var pinLockRemaining: TimeInterval? {
        guard let pinLockedUntil, pinLockedUntil > Date() else { return nil }
        return pinLockedUntil.timeIntervalSinceNow
    }

    /// Records the outcome of a disconnect-PIN attempt. Success clears the failure counter and any
    /// lockout; failure increments the counter and, at `maxPINAttempts`, starts a persistent
    /// lockout. Returns the lockout end date when this attempt triggered a lockout, else nil.
    @discardableResult
    func recordPINAttempt(success: Bool) -> Date? {
        if success {
            userDefaults.removeObject(forKey: pinFailCountKey)
            userDefaults.removeObject(forKey: pinLockUntilKey)
            pinLockedUntil = nil
            return nil
        }
        let fails = userDefaults.integer(forKey: pinFailCountKey) + 1
        if fails >= maxPINAttempts {
            // ESCALATING lockout. A flat 5-minute penalty with the counter reset to 0 each time
            // allowed a constant ~288 guesses/day, which walks the whole 4-digit space in about
            // five weeks of an unattended device — and the child holds the device. Each subsequent
            // lockout in the same run climbs the ladder and the tier persists, so a relaunch cannot
            // reset it.
            let tier = min(userDefaults.integer(forKey: pinLockoutTierKey), Self.pinLockoutLadder.count - 1)
            let until = Date().addingTimeInterval(Self.pinLockoutLadder[tier])
            userDefaults.set(until.timeIntervalSince1970, forKey: pinLockUntilKey)
            userDefaults.set(0, forKey: pinFailCountKey)
            userDefaults.set(min(tier + 1, Self.pinLockoutLadder.count - 1), forKey: pinLockoutTierKey)
            pinLockedUntil = until
            return until
        }
        userDefaults.set(fails, forKey: pinFailCountKey)
        return nil
    }

    private let userDefaults: UserDefaults
    private let pinStore: PINCredentialStoring
    private var unlockSessionExpiration: Date?
    private var foregroundObserver: NSObjectProtocol?
    private var pinPromptContinuation: CheckedContinuation<Bool, Never>?
    private let unlockGracePeriod: TimeInterval = 120
    private let pinLength = 4
    private let protectionEnabledKey = "SETTINGS_PROTECTION_ENABLED"
    private let legacyPINHashKey = "SETTINGS_PROTECTION_PIN_HASH"
    private var pinFailCountKey: String { Self.pinFailCountKey }
    private var pinLockUntilKey: String { Self.pinLockUntilKey }
    private var pinLockoutTierKey: String { Self.pinLockoutTierKey }
    nonisolated static let pinFailCountKey = "SETTINGS_PROTECTION_PIN_FAILS"
    nonisolated static let pinLockUntilKey = "SETTINGS_PROTECTION_PIN_LOCK_UNTIL"
    nonisolated static let pinLockoutTierKey = "SETTINGS_PROTECTION_PIN_LOCK_TIER"
    /// Escalating lockout durations: 1min, 5min, 15min, 1h, 24h. Index persisted in
    /// `pinLockoutTierKey` so a relaunch cannot walk back down the ladder.
    static let pinLockoutLadder: [TimeInterval] = [60, 300, 900, 3600, 86_400]
    private let maxPINAttempts = 5

    // MARK: - PIN verifier (salted, slow KDF)

    /// Builds a `salt || verifier` record for a fresh PIN.
    private func makeRecord(for pin: String) -> Data {
        let salt = PINKeyDerivation.randomSalt()
        return salt + PINKeyDerivation.derive(pin: pin, salt: salt)
    }

    /// Constant-time verify of `pin` against the stored `salt || verifier` record.
    private func verify(_ pin: String) -> Bool {
        guard let record = pinStore.load(),
              record.count == PINKeyDerivation.saltLength + PINKeyDerivation.keyLength else {
            return false
        }
        let salt = record.prefix(PINKeyDerivation.saltLength)
        let stored = record.suffix(PINKeyDerivation.keyLength)
        let candidate = PINKeyDerivation.derive(pin: pin, salt: Data(salt))
        return PINKeyDerivation.constantTimeEquals(Data(stored), candidate)
    }

    private func presentPINPrompt(_ prompt: SettingsProtectionPINPrompt) async -> Bool {
        cancelPINPrompt()

        return await withCheckedContinuation { continuation in
            pinPromptContinuation = continuation
            activePINPrompt = prompt
        }
    }

    private func completePINPrompt(result: Bool) {
        activePINPrompt = nil
        pinPromptContinuation?.resume(returning: result)
        pinPromptContinuation = nil
    }

    private func startUnlockSession() {
        unlockSessionExpiration = Date().addingTimeInterval(unlockGracePeriod)
        hasActiveUnlockSession = true
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: protectionEnabledKey)

        if !enabled {
            clearUnlockSession()
        }
    }

    private func clearUnlockSession() {
        unlockSessionExpiration = nil
        hasActiveUnlockSession = false
    }

    private func normalizePIN(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(pinLength))
    }
}

// MARK: - PIN credential storage

/// Persists the disconnect-PIN verifier record (`salt || KDF(pin, salt)`). Abstracted so tests can
/// use an in-memory store instead of the shared system Keychain.
protocol PINCredentialStoring {
    func load() -> Data?
    func save(_ data: Data)
    func delete()
}

/// Keychain-backed store (`kSecClassGenericPassword`, AfterFirstUnlockThisDeviceOnly). The verifier
/// lives in the Keychain — not UserDefaults — so a device backup or plist dump can neither lift the
/// verifier for offline brute-forcing nor simply delete the PIN to bypass the gate.
final class KeychainPINCredentialStore: PINCredentialStoring {
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

/// In-memory store for tests (the Keychain is process/device-global and not test-isolable).
final class InMemoryPINCredentialStore: PINCredentialStoring {
    private var data: Data?
    init(data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
    func delete() { data = nil }
}

/// PBKDF2-HMAC-SHA256 password stretching for the (short, 4-digit) disconnect PIN. A slow KDF plus
/// a random per-install salt means the small keyspace can't be precomputed or brute-forced offline
/// as cheaply as a raw SHA-256 hash; the on-device attempt lockout guards online guessing.
enum PINKeyDerivation {
    static let saltLength = 16
    static let keyLength = 32
    static let rounds: UInt32 = 150_000

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes)
        return Data(bytes)
    }

    static func derive(pin: String, salt: Data) -> Data {
        let pinBytes = Array(pin.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)
        salt.withUnsafeBytes { saltBuffer in
            _ = CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pin, pinBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                rounds,
                &derived, keyLength
            )
        }
        return Data(derived)
    }

    /// Length-safe constant-time comparison so verification time can't leak how many bytes matched.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { diff |= a ^ b }
        return diff == 0
    }
}

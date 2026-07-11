import CryptoKit
import Foundation
import LocalAuthentication
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

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
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
        hasCustomPIN = storedPINHash != nil

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
        userDefaults.removeObject(forKey: protectionPINHashKey)
        refreshAvailability()
    }

    func authenticateIfNeeded() async -> Bool {
        refreshAvailability()

        guard isEnabled else { return true }
        guard !hasActiveUnlockSession else { return true }
        guard isProtectionAvailable else {
            setEnabled(false)
            return true
        }

        if !isDeviceAuthenticationAvailable {
            guard hasCustomPIN else {
                setEnabled(false)
                return true
            }
            return await presentPINPrompt(.unlock)
        }

        let success = await authenticateWithDeviceOwner()
        guard success else { return false }

        startUnlockSession()
        return true
    }

    func submitPINPrompt(pin: String, confirmation: String?) -> String? {
        guard let activePINPrompt else { return nil }

        let normalizedPIN = normalizePIN(pin)
        guard normalizedPIN.count == pinLength else {
            return L10n.tr("settings.control_protection_pin_invalid")
        }

        switch activePINPrompt {
        case .unlock:
            guard storedPINHash == hashPIN(normalizedPIN) else {
                return L10n.tr("settings.control_protection_pin_incorrect")
            }
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
            userDefaults.set(hashPIN(normalizedPIN), forKey: protectionPINHashKey)
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
        let normalized = normalizePIN(pin)
        guard normalized.count == pinLength, let storedPINHash else { return false }
        return storedPINHash == hashPIN(normalized)
    }

    /// Stores a new custom PIN (used by the disconnect create-flow when none exists yet).
    /// Returns false when the input isn't exactly `pinLength` digits.
    @discardableResult
    func saveCustomPIN(_ pin: String) -> Bool {
        let normalized = normalizePIN(pin)
        guard normalized.count == pinLength else { return false }
        userDefaults.set(hashPIN(normalized), forKey: protectionPINHashKey)
        startUnlockSession()
        refreshAvailability()
        return true
    }

    /// Confirms the device owner via Face ID / Touch ID / passcode. Starts an unlock
    /// session on success. Returns false when authentication is unavailable or cancelled.
    func confirmDeviceOwner() async -> Bool {
        guard isDeviceAuthenticationAvailable else { return false }
        let success = await authenticateWithDeviceOwner()
        if success { startUnlockSession() }
        return success
    }

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
            let until = Date().addingTimeInterval(pinLockoutDuration)
            userDefaults.set(until.timeIntervalSince1970, forKey: pinLockUntilKey)
            userDefaults.set(0, forKey: pinFailCountKey)
            pinLockedUntil = until
            return until
        }
        userDefaults.set(fails, forKey: pinFailCountKey)
        return nil
    }

    private let userDefaults: UserDefaults
    private var unlockSessionExpiration: Date?
    private var foregroundObserver: NSObjectProtocol?
    private var pinPromptContinuation: CheckedContinuation<Bool, Never>?
    private let unlockGracePeriod: TimeInterval = 120
    private let pinLength = 4
    private let protectionEnabledKey = "SETTINGS_PROTECTION_ENABLED"
    private let protectionPINHashKey = "SETTINGS_PROTECTION_PIN_HASH"
    private let pinFailCountKey = "SETTINGS_PROTECTION_PIN_FAILS"
    private let pinLockUntilKey = "SETTINGS_PROTECTION_PIN_LOCK_UNTIL"
    private let maxPINAttempts = 5
    private let pinLockoutDuration: TimeInterval = 300

    private var storedPINHash: String? {
        guard let value = userDefaults.string(forKey: protectionPINHashKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
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

    private func authenticateWithDeviceOwner() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = L10n.tr("common.cancel")

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: L10n.tr("settings.control_protection_auth_reason")
            ) { didAuthenticate, _ in
                continuation.resume(returning: didAuthenticate)
            }
        }
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

    private func hashPIN(_ pin: String) -> String {
        let digest = SHA256.hash(data: Data(pin.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

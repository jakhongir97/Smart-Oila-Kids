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

    private let userDefaults: UserDefaults
    private var unlockSessionExpiration: Date?
    private var foregroundObserver: NSObjectProtocol?
    private var pinPromptContinuation: CheckedContinuation<Bool, Never>?
    private let unlockGracePeriod: TimeInterval = 120
    private let pinLength = 4
    private let protectionEnabledKey = "SETTINGS_PROTECTION_ENABLED"
    private let protectionPINHashKey = "SETTINGS_PROTECTION_PIN_HASH"

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

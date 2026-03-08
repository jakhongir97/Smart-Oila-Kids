import Foundation
import LocalAuthentication
import UIKit

@MainActor
final class SettingsProtectionController: ObservableObject {
    static let shared = SettingsProtectionController()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isAuthenticationAvailable = false
    @Published private(set) var hasActiveUnlockSession = false

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
        isAuthenticationAvailable = canAuthenticate

        guard canAuthenticate else {
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
        guard isAuthenticationAvailable else { return false }
        setEnabled(true)
        return true
    }

    func disableProtection() {
        setEnabled(false)
    }

    func authenticateIfNeeded() async -> Bool {
        refreshAvailability()

        guard isEnabled else { return true }
        guard !hasActiveUnlockSession else { return true }
        guard isAuthenticationAvailable else {
            setEnabled(false)
            return true
        }

        let context = LAContext()
        context.localizedCancelTitle = L10n.tr("common.cancel")

        let success = await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: L10n.tr("settings.control_protection_auth_reason")
            ) { didAuthenticate, _ in
                continuation.resume(returning: didAuthenticate)
            }
        }

        guard success else { return false }

        unlockSessionExpiration = Date().addingTimeInterval(unlockGracePeriod)
        hasActiveUnlockSession = true
        return true
    }

    private let userDefaults: UserDefaults
    private var unlockSessionExpiration: Date?
    private var foregroundObserver: NSObjectProtocol?
    private let unlockGracePeriod: TimeInterval = 120
    private let protectionEnabledKey = "SETTINGS_PROTECTION_ENABLED"

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
}

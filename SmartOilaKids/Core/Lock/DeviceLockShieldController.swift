import Foundation
import ManagedSettings

@MainActor
final class DeviceLockShieldController {
    func applyLockState(
        _ isLocked: Bool,
        appLockConfiguration: DeviceAppLockShieldConfiguration = .empty
    ) {
        let authorizationStatus = ScreenTimeAuthorizationManager.shared.status
        guard authorizationStatus != lastAuthorizationStatus ||
                isLocked != lastAppliedGlobalLockState ||
                appLockConfiguration != lastAppLockConfiguration else {
            return
        }

        lastAuthorizationStatus = authorizationStatus
        lastAppliedGlobalLockState = isLocked
        lastAppLockConfiguration = appLockConfiguration

        guard authorizationStatus == .granted else {
            clearAllRestrictions()
            return
        }

        if isLocked {
            applyGlobalShield()
        } else if appLockConfiguration.hasRestrictions {
            applySelectiveShield(appLockConfiguration)
        } else {
            clearAllRestrictions()
        }
    }

    func clearAllRestrictions() {
        lastAppliedGlobalLockState = nil
        lastAuthorizationStatus = nil
        lastAppLockConfiguration = nil
        store.clearAllSettings()
    }

    private let store = ManagedSettingsStore(named: .init(DeviceLockManagedSettingsStoreName.runtime))
    private var lastAppliedGlobalLockState: Bool?
    private var lastAuthorizationStatus: ScreenTimePermissionStatus?
    private var lastAppLockConfiguration: DeviceAppLockShieldConfiguration?

    private func applyGlobalShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = .all()
        store.shield.webDomains = nil
        store.shield.webDomainCategories = .all()
    }

    private func applySelectiveShield(_ configuration: DeviceAppLockShieldConfiguration) {
        store.clearAllSettings()
        store.shield.applications = configuration.applicationTokens.isEmpty ? nil : configuration.applicationTokens
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
    }
}

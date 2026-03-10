import Foundation
import ManagedSettings

@MainActor
final class DeviceLockShieldController {
    typealias AuthorizationStatusAction = () -> ScreenTimePermissionStatus
    typealias ApplyGlobalShieldAction = () -> Void
    typealias ApplySelectiveShieldAction = (DeviceAppLockShieldConfiguration) -> Void
    typealias ClearRestrictionsAction = () -> Void

    init(
        authorizationStatus: AuthorizationStatusAction? = nil,
        applyGlobalShield: ApplyGlobalShieldAction? = nil,
        applySelectiveShield: ApplySelectiveShieldAction? = nil,
        clearRestrictions: ClearRestrictionsAction? = nil
    ) {
        let store = ManagedSettingsStore(named: .init(DeviceLockManagedSettingsStoreName.runtime))

        self.authorizationStatus = authorizationStatus ?? {
            ScreenTimeAuthorizationManager.shared.status
        }
        self.applyGlobalShieldAction = applyGlobalShield ?? {
            store.shield.applications = nil
            store.shield.applicationCategories = .all()
            store.shield.webDomains = nil
            store.shield.webDomainCategories = .all()
        }
        self.applySelectiveShieldAction = applySelectiveShield ?? { configuration in
            store.clearAllSettings()
            store.shield.applications = configuration.applicationTokens.isEmpty ? nil : configuration.applicationTokens
            store.shield.applicationCategories = nil
            store.shield.webDomains = nil
            store.shield.webDomainCategories = nil
        }
        self.clearRestrictionsAction = clearRestrictions ?? {
            store.clearAllSettings()
        }
    }

    func applyLockState(
        _ isLocked: Bool,
        appLockConfiguration: DeviceAppLockShieldConfiguration = .empty
    ) {
        let authorizationStatus = authorizationStatus()
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
        clearRestrictionsAction()
    }

    private let authorizationStatus: AuthorizationStatusAction
    private let applyGlobalShieldAction: ApplyGlobalShieldAction
    private let applySelectiveShieldAction: ApplySelectiveShieldAction
    private let clearRestrictionsAction: ClearRestrictionsAction
    private var lastAppliedGlobalLockState: Bool?
    private var lastAuthorizationStatus: ScreenTimePermissionStatus?
    private var lastAppLockConfiguration: DeviceAppLockShieldConfiguration?

    private func applyGlobalShield() {
        applyGlobalShieldAction()
    }

    private func applySelectiveShield(_ configuration: DeviceAppLockShieldConfiguration) {
        applySelectiveShieldAction(configuration)
    }
}

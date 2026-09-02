import Foundation
import ManagedSettings

@MainActor
final class DeviceLockShieldController {
    typealias AuthorizationStatusAction = () -> ScreenTimePermissionStatus
    typealias ApplyGlobalShieldAction = () -> Void
    typealias ApplySelectiveShieldAction = (DeviceAppLockShieldConfiguration) -> Void
    typealias ClearRestrictionsAction = () -> Void
    /// Whether a GLOBAL shield may be raised at all — i.e. whether an always-allowed set exists.
    /// A seam so a test can exercise both sides without writing to the real app group.
    typealias GlobalShieldPermittedAction = () -> Bool

    init(
        authorizationStatus: AuthorizationStatusAction? = nil,
        applyGlobalShield: ApplyGlobalShieldAction? = nil,
        applySelectiveShield: ApplySelectiveShieldAction? = nil,
        clearRestrictions: ClearRestrictionsAction? = nil,
        isGlobalShieldPermitted: GlobalShieldPermittedAction? = nil
    ) {
        self.isGlobalShieldPermittedAction = isGlobalShieldPermitted ?? {
            ScreenTimeAlwaysAllowedSharedStore.isConfigured()
        }
        let store = DeviceLockManagedSettingsStoreFactory.make(
            named: DeviceLockManagedSettingsStoreName.runtime
        )

        self.authorizationStatus = authorizationStatus ?? {
            ScreenTimeAuthorizationManager.shared.status
        }
        self.applyGlobalShieldAction = applyGlobalShield ?? {
            // NEVER `.all()` with no exception set. `.all()` covers every category, which on iOS
            // includes Phone and Messages — and Bolajon360 itself, the app holding the SOS button.
            // A child shielded that way cannot call a parent and cannot open the app that would let
            // them ask to be let out. See ScreenTimeAlwaysAllowedStore for why the set has to be
            // collected on-device rather than hardcoded (Apple mints ApplicationTokens only through
            // FamilyActivityPicker; there is no bundle-id → token API).
            ScreenTimeAlwaysAllowedSharedStore.applyGlobalShield(to: store)
        }
        self.applySelectiveShieldAction = applySelectiveShield ?? { configuration in
            DeviceLockManagedSettingsStoreFactory.clearAllSettings(store)
            store.shield.applications = configuration.applicationTokens.isEmpty ? nil : configuration.applicationTokens
            store.shield.applicationCategories = nil
            store.shield.webDomains = nil
            store.shield.webDomainCategories = nil
        }
        self.clearRestrictionsAction = clearRestrictions ?? {
            DeviceLockManagedSettingsStoreFactory.clearAllSettings(store)
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
            // A global shield with no always-allowed set would cover Phone, Messages and this app.
            // Refuse rather than degrade: a lock that silently does nothing is a support call, but a
            // lock that strands a child with no way to call a parent is a safety incident. The
            // selective path below is unaffected — it shields named apps and excepts everything else
            // by construction.
            guard isGlobalShieldPermittedAction() else {
                clearAllRestrictions()
                return
            }
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
    private let isGlobalShieldPermittedAction: GlobalShieldPermittedAction
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

import Foundation
import SwiftUI

final class SessionStore: ObservableObject {
    static let profileNameDefaultsKey = "PROFILE_NAME"

    private enum Keys {
        static let dsn = "DSN"
        static let profileName = SessionStore.profileNameDefaultsKey
        static let childAvatarEmoji = "CHILD_AVATAR_EMOJI"
        static let childProfileColor = "CHILD_PROFILE_COLOR"
        static let appTheme = "APP_THEME"
        static let appLanguage = "APP_LANGUAGE"
        static let setupCompleted = "BOLAJON_SETUP_COMPLETED"
        static let onboardingCompleted = "BOLAJON_ONBOARDING_COMPLETED"
        static let oilaPaired = "BOLAJON_OILA_PAIRED"
        static let routingMigrated = "BOLAJON_ROUTING_MIGRATED"
        static let migratedFromLegacy = "BOLAJON_MIGRATED_FROM_LEGACY"
    }

    @Published private(set) var dsn: String?
    @Published var profileName: String
    /// Emoji avatar the parent chose for this child (from `POST /device/pair` → child.avatarEmoji).
    @Published private(set) var childAvatarEmoji: String?
    /// Hex profile color the parent chose for this child (child.profileColor, e.g. "#F0605A").
    @Published private(set) var childProfileColor: String?
    @Published private(set) var apiAccessToken: String?
    @Published private(set) var apiRefreshToken: String?
    @Published private(set) var appTheme: AppTheme
    @Published private(set) var appLanguage: AppLanguage
    /// Bolajon360 redesign routing: setup flow (A1–A4) finished.
    @Published private(set) var setupCompleted: Bool = false
    /// Bolajon360 redesign routing: permissions onboarding (B1–B11) finished.
    @Published private(set) var onboardingCompleted: Bool = false
    /// True only after a successful oila360 `POST /device/pair` issued this install's tokens.
    /// Gates telemetry — a legacy DSN alone is NOT an oila360 credential.
    @Published private(set) var oilaPaired: Bool = false
    /// True when the one-time routing migration reset an EXISTING install (legacy DSN or
    /// previously-completed flow) — as opposed to a fresh install, which also runs the
    /// migration branch but has nothing to lose. Drives the "re-link to keep protection on"
    /// notice in the setup flow.
    @Published private(set) var migratedFromLegacy: Bool = false

    init(
        userDefaults: UserDefaults = .standard,
        secureTokens: SecureTokenStoring = SecureTokenStore.shared,
        deviceTokens: SecureTokenStoring = SecureTokenStore.oila
    ) {
        self.userDefaults = userDefaults
        self.secureTokens = secureTokens
        self.deviceTokens = deviceTokens

        secureTokens.migrateFromUserDefaults(userDefaults)

        let resolvedLanguage = SessionStore.defaultLanguage(userDefaults: userDefaults)
        L10n.setLanguage(resolvedLanguage.rawValue)

        dsn = userDefaults.string(forKey: Keys.dsn)?.trimmedNonEmpty
        profileName = userDefaults.string(forKey: Keys.profileName) ?? L10n.tr("common.user_default")
        childAvatarEmoji = userDefaults.string(forKey: Keys.childAvatarEmoji)?.trimmedNonEmpty
        childProfileColor = userDefaults.string(forKey: Keys.childProfileColor)?.trimmedNonEmpty
        apiAccessToken = secureTokens.accessToken()
        apiRefreshToken = secureTokens.refreshToken()
        appTheme = AppTheme(rawValue: userDefaults.string(forKey: Keys.appTheme) ?? "") ?? .system
        appLanguage = resolvedLanguage

        // Bolajon360 routing migration (one-time). The oila360 backend replaced the legacy one,
        // so a legacy DSN carries NO oila360 credentials AND no guarantee the new flow's
        // permissions (Always-location, Screen Time authorization) were ever granted. Send every
        // migrated user through the full setup + B1–B11 permission flow once (all flags false):
        // skipping onboarding for "already linked" users is what left telemetry silently
        // un-permissioned. Marking them "paired" without tokens would 401-loop telemetry forever.
        if !userDefaults.bool(forKey: Keys.routingMigrated) {
            // Capture BEFORE resetting: a fresh install also passes through this branch, but
            // only an upgrading install has a legacy DSN or previously-completed flow state.
            let hadExistingInstallState = dsn != nil
                || userDefaults.bool(forKey: Keys.setupCompleted)
                || userDefaults.bool(forKey: Keys.onboardingCompleted)
                || userDefaults.bool(forKey: Keys.oilaPaired)
            userDefaults.set(false, forKey: Keys.setupCompleted)
            userDefaults.set(false, forKey: Keys.onboardingCompleted)
            userDefaults.set(false, forKey: Keys.oilaPaired)
            userDefaults.set(true, forKey: Keys.routingMigrated)
            if hadExistingInstallState {
                userDefaults.set(true, forKey: Keys.migratedFromLegacy)
            }
        }
        setupCompleted = userDefaults.bool(forKey: Keys.setupCompleted)
        onboardingCompleted = userDefaults.bool(forKey: Keys.onboardingCompleted)
        oilaPaired = userDefaults.bool(forKey: Keys.oilaPaired)
        migratedFromLegacy = userDefaults.bool(forKey: Keys.migratedFromLegacy)

#if DEBUG
        SessionStore.debugThemeLog(
            "init theme=\(appTheme.rawValue) storedRaw=\(userDefaults.string(forKey: Keys.appTheme) ?? "nil") language=\(appLanguage.rawValue)"
        )
#endif
    }

    func setDSN(_ value: String?) {
        let normalized = value?.trimmedNonEmpty
        dsn = normalized
        if let normalized {
            userDefaults.set(normalized, forKey: Keys.dsn)
        } else {
            userDefaults.removeObject(forKey: Keys.dsn)
        }
    }

    func setProfileName(_ name: String) {
        profileName = name
        userDefaults.set(name, forKey: Keys.profileName)
    }

    func setChildAvatarEmoji(_ emoji: String?) {
        let normalized = emoji?.trimmedNonEmpty
        childAvatarEmoji = normalized
        if let normalized {
            userDefaults.set(normalized, forKey: Keys.childAvatarEmoji)
        } else {
            userDefaults.removeObject(forKey: Keys.childAvatarEmoji)
        }
    }

    func setChildProfileColor(_ hex: String?) {
        let normalized = hex?.trimmedNonEmpty
        childProfileColor = normalized
        if let normalized {
            userDefaults.set(normalized, forKey: Keys.childProfileColor)
        } else {
            userDefaults.removeObject(forKey: Keys.childProfileColor)
        }
    }

    func setAPIAccessToken(_ token: String?) {
        secureTokens.setAccessToken(normalizeAccessToken(token))
        apiAccessToken = secureTokens.accessToken()
    }

    func setAPIRefreshToken(_ token: String?) {
        secureTokens.setRefreshToken(token)
        apiRefreshToken = secureTokens.refreshToken()
    }

    func setTheme(_ value: AppTheme) {
#if DEBUG
        let previousTheme = appTheme.rawValue
        let previousStoredValue = userDefaults.string(forKey: Keys.appTheme) ?? "nil"
        SessionStore.debugThemeLog(
            "setTheme requested=\(value.rawValue) previousTheme=\(previousTheme) previousStoredRaw=\(previousStoredValue)"
        )
#endif
        appTheme = value
        userDefaults.set(value.rawValue, forKey: Keys.appTheme)
#if DEBUG
        SessionStore.debugThemeLog(
            "setTheme applied theme=\(appTheme.rawValue) storedRaw=\(userDefaults.string(forKey: Keys.appTheme) ?? "nil")"
        )
#endif
    }

    func setLanguage(_ value: AppLanguage) {
        appLanguage = value
        userDefaults.set(value.rawValue, forKey: Keys.appLanguage)
        L10n.setLanguage(value.rawValue)
    }

    func setSetupCompleted(_ value: Bool) {
        setupCompleted = value
        userDefaults.set(value, forKey: Keys.setupCompleted)
    }

    func setOnboardingCompleted(_ value: Bool) {
        onboardingCompleted = value
        userDefaults.set(value, forKey: Keys.onboardingCompleted)
    }

    func setOilaPaired(_ value: Bool) {
        oilaPaired = value
        userDefaults.set(value, forKey: Keys.oilaPaired)
        if value {
            // The migration re-link notice is a one-time upgrade prompt. Once this install pairs,
            // clear the flag so a later voluntary disconnect doesn't resurrect the notice for a
            // user who is no longer a freshly-migrated install.
            migratedFromLegacy = false
            userDefaults.set(false, forKey: Keys.migratedFromLegacy)
        }
    }

    func clearSession() {
        setDSN(nil)
        setAPIAccessToken(nil)
        setAPIRefreshToken(nil)
        setChildAvatarEmoji(nil)
        setChildProfileColor(nil)
        // Wipe the live oila360 device credential too. `secureTokens` only holds the (unused)
        // legacy account tokens; the Bearer token minted by `POST /device/pair` lives in the
        // separate `deviceTokens` slots, and leaving it behind meant a server-side unpair (or a
        // spurious 401) returned the child to pairing while a still-valid token lingered in the
        // Keychain.
        deviceTokens.clear()
        // Disconnect returns the child to the setup flow.
        setSetupCompleted(false)
        setOnboardingCompleted(false)
        setOilaPaired(false)
        purgeChildScopedData()
    }

    /// Wipes every per-child artifact on disconnect so re-pairing this device to a DIFFERENT child
    /// cannot surface the previous child's data. DSN-scoped stores (tasks, chat, dashboard cache,
    /// geo queue, app-lock selection) are isolated by regenerating the device DSN — the next pair
    /// mints a fresh scope — while the few globally-keyed caches are cleared here directly.
    private func purgeChildScopedData() {
        // 1. Regenerate the generate-once device DSN → all DSN-scoped stores start empty on re-pair.
        OilaDeviceIdentity.resetDSN(userDefaults: userDefaults)
        // 2. Clear the globally-keyed SettingsCacheStore (not DSN-scoped), so the previous child's
        //    cached connected-device list can't surface before a refresh. (profileName is left as
        //    is — it is not shown while unpaired and is overwritten by the next pair.)
        for key in ["SETTINGS_CACHE_PROFILE_NAME", "SETTINGS_CACHE_CONNECTED_DEVICES"] {
            userDefaults.removeObject(forKey: key)
        }
    }

    private static func defaultLanguage(userDefaults: UserDefaults) -> AppLanguage {
        if let persisted = userDefaults.string(forKey: Keys.appLanguage),
           let value = AppLanguage(rawValue: persisted) {
            return value
        }
        return AppLanguage.defaultForDevice
    }

    private let userDefaults: UserDefaults
    private let secureTokens: SecureTokenStoring
    private let deviceTokens: SecureTokenStoring

    var hasLinkedChildDevice: Bool {
        dsn?.trimmedNonEmpty != nil
    }

    var hasAuthenticatedSession: Bool {
        apiAccessToken?.trimmedNonEmpty != nil || apiRefreshToken?.trimmedNonEmpty != nil
    }

    private func normalizeAccessToken(_ token: String?) -> String? {
        guard let token = token?.trimmedNonEmpty else { return nil }
        let parts = token
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

#if DEBUG
    private static func debugThemeLog(_ message: String) {
        print("[ThemeDebug][SessionStore] \(message)")
    }
#endif
}

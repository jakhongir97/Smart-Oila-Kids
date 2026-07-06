import Foundation
import SwiftUI

final class SessionStore: ObservableObject {
    static let profileNameDefaultsKey = "PROFILE_NAME"

    private enum Keys {
        static let dsn = "DSN"
        static let selectedRemoteDSN = "SELECTED_REMOTE_DSN"
        static let profileName = SessionStore.profileNameDefaultsKey
        static let appTheme = "APP_THEME"
        static let appLanguage = "APP_LANGUAGE"
        static let setupCompleted = "BOLAJON_SETUP_COMPLETED"
        static let onboardingCompleted = "BOLAJON_ONBOARDING_COMPLETED"
        static let oilaPaired = "BOLAJON_OILA_PAIRED"
        static let routingMigrated = "BOLAJON_ROUTING_MIGRATED"
    }

    @Published private(set) var dsn: String?
    @Published private(set) var selectedRemoteDSN: String?
    @Published var profileName: String
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

    init(
        userDefaults: UserDefaults = .standard,
        secureTokens: SecureTokenStoring = SecureTokenStore.shared
    ) {
        self.userDefaults = userDefaults
        self.secureTokens = secureTokens

        secureTokens.migrateFromUserDefaults(userDefaults)

        let resolvedLanguage = SessionStore.defaultLanguage(userDefaults: userDefaults)
        L10n.setLanguage(resolvedLanguage.rawValue)

        dsn = userDefaults.string(forKey: Keys.dsn)?.trimmedNonEmpty
        selectedRemoteDSN = userDefaults.string(forKey: Keys.selectedRemoteDSN)?.trimmedNonEmpty
        profileName = userDefaults.string(forKey: Keys.profileName) ?? L10n.tr("common.user_default")
        apiAccessToken = secureTokens.accessToken()
        apiRefreshToken = secureTokens.refreshToken()
        appTheme = AppTheme(rawValue: userDefaults.string(forKey: Keys.appTheme) ?? "") ?? .system
        appLanguage = resolvedLanguage

        // Bolajon360 routing migration (one-time). The oila360 backend replaced the legacy
        // one, so a legacy DSN carries NO oila360 credentials: existing linked users must
        // re-pair once (setupCompleted stays false → A1–A3), but they skip the permissions
        // onboarding they already granted (onboardingCompleted = true). Marking them
        // "paired" without tokens would leave telemetry silently 401-looping forever.
        if !userDefaults.bool(forKey: Keys.routingMigrated) {
            let linked = dsn?.trimmedNonEmpty != nil
            userDefaults.set(false, forKey: Keys.setupCompleted)
            userDefaults.set(linked, forKey: Keys.onboardingCompleted)
            userDefaults.set(false, forKey: Keys.oilaPaired)
            userDefaults.set(true, forKey: Keys.routingMigrated)
        }
        setupCompleted = userDefaults.bool(forKey: Keys.setupCompleted)
        onboardingCompleted = userDefaults.bool(forKey: Keys.onboardingCompleted)
        oilaPaired = userDefaults.bool(forKey: Keys.oilaPaired)

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

    func setSelectedRemoteDSN(_ value: String?) {
        let normalized = value?.trimmedNonEmpty
        selectedRemoteDSN = normalized
        if let normalized {
            userDefaults.set(normalized, forKey: Keys.selectedRemoteDSN)
        } else {
            userDefaults.removeObject(forKey: Keys.selectedRemoteDSN)
        }
    }

    func setProfileName(_ name: String) {
        profileName = name
        userDefaults.set(name, forKey: Keys.profileName)
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
    }

    func clearSession() {
        setDSN(nil)
        setSelectedRemoteDSN(nil)
        setAPIAccessToken(nil)
        setAPIRefreshToken(nil)
        // Disconnect returns the child to the setup flow.
        setSetupCompleted(false)
        setOnboardingCompleted(false)
        setOilaPaired(false)
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

    var activeRemoteDSN: String? {
        selectedRemoteDSN?.trimmedNonEmpty ?? dsn?.trimmedNonEmpty
    }

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

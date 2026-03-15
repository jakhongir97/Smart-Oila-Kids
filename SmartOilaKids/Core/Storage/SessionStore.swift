import Foundation
import SwiftUI

final class SessionStore: ObservableObject {
    static let profileNameDefaultsKey = "PROFILE_NAME"

    private enum Keys {
        static let dsn = "DSN"
        static let profileName = SessionStore.profileNameDefaultsKey
        static let appTheme = "APP_THEME"
        static let appLanguage = "APP_LANGUAGE"
    }

    @Published private(set) var dsn: String?
    @Published var profileName: String
    @Published private(set) var apiAccessToken: String?
    @Published private(set) var apiRefreshToken: String?
    @Published private(set) var appTheme: AppTheme
    @Published private(set) var appLanguage: AppLanguage

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
        profileName = userDefaults.string(forKey: Keys.profileName) ?? L10n.tr("common.user_default")
        apiAccessToken = secureTokens.accessToken()
        apiRefreshToken = secureTokens.refreshToken()
        appTheme = AppTheme(rawValue: userDefaults.string(forKey: Keys.appTheme) ?? "") ?? .system
        appLanguage = resolvedLanguage

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

    func clearSession() {
        setDSN(nil)
        setAPIAccessToken(nil)
        setAPIRefreshToken(nil)
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

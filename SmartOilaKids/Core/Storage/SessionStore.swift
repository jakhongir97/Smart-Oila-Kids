import Foundation
import SwiftUI

final class SessionStore: ObservableObject {
    private enum Keys {
        static let dsn = "DSN"
        static let profileName = "PROFILE_NAME"
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

        dsn = userDefaults.string(forKey: Keys.dsn)?.trimmedNonEmpty
        profileName = userDefaults.string(forKey: Keys.profileName) ?? "Пользователь"
        apiAccessToken = secureTokens.accessToken()
        apiRefreshToken = secureTokens.refreshToken()
        appTheme = AppTheme(rawValue: userDefaults.string(forKey: Keys.appTheme) ?? "") ?? .system
        appLanguage = SessionStore.defaultLanguage(userDefaults: userDefaults)

        L10n.setLanguage(appLanguage.rawValue)
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
        appTheme = value
        userDefaults.set(value.rawValue, forKey: Keys.appTheme)
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
}

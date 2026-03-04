import Foundation
import Security
import SwiftUI

protocol SecureTokenStoring {
    func accessToken() -> String?
    func refreshToken() -> String?
    func setAccessToken(_ token: String?)
    func setRefreshToken(_ token: String?)
    func migrateFromUserDefaults(_ userDefaults: UserDefaults)
    func clear()
}

final class SecureTokenStore: SecureTokenStoring {
    static let shared = SecureTokenStore()

    private enum Constants {
        static let service = Bundle.main.bundleIdentifier ?? "SmartOilaKids"
        static let accessTokenAccount = "api_access_token"
        static let refreshTokenAccount = "api_refresh_token"

        static let legacyAccessTokenDefaultsKey = "API_ACCESS_TOKEN"
        static let legacyRefreshTokenDefaultsKey = "API_REFRESH_TOKEN"
    }

    func accessToken() -> String? {
        readValue(for: Constants.accessTokenAccount)?.trimmedNonEmpty
    }

    func refreshToken() -> String? {
        readValue(for: Constants.refreshTokenAccount)?.trimmedNonEmpty
    }

    func setAccessToken(_ token: String?) {
        writeValue(token, for: Constants.accessTokenAccount)
    }

    func setRefreshToken(_ token: String?) {
        writeValue(token, for: Constants.refreshTokenAccount)
    }

    func migrateFromUserDefaults(_ userDefaults: UserDefaults) {
        if accessToken() == nil,
           let legacyAccessToken = userDefaults.string(forKey: Constants.legacyAccessTokenDefaultsKey)?.trimmedNonEmpty {
            setAccessToken(legacyAccessToken)
        }

        if refreshToken() == nil,
           let legacyRefreshToken = userDefaults.string(forKey: Constants.legacyRefreshTokenDefaultsKey)?.trimmedNonEmpty {
            setRefreshToken(legacyRefreshToken)
        }

        userDefaults.removeObject(forKey: Constants.legacyAccessTokenDefaultsKey)
        userDefaults.removeObject(forKey: Constants.legacyRefreshTokenDefaultsKey)
    }

    func clear() {
        setAccessToken(nil)
        setRefreshToken(nil)
    }

    private func readValue(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            return nil
        }

        guard let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    private func writeValue(_ value: String?, for account: String) {
        let query = baseQuery(for: account)
        guard let value = value?.trimmedNonEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let status = SecItemCopyMatching(query as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        case errSecItemNotFound:
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(insertQuery as CFDictionary, nil)
        default:
            break
        }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.service,
            kSecAttrAccount as String: account
        ]
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case en
    case ru
    case uz

    var id: String { rawValue }

    var localeIdentifier: String { rawValue }

    static var defaultForDevice: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? AppLanguage.en.rawValue
        if preferred.hasPrefix(AppLanguage.ru.rawValue) {
            return .ru
        }
        if preferred.hasPrefix(AppLanguage.uz.rawValue) {
            return .uz
        }
        return .en
    }
}

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

        self.dsn = userDefaults.string(forKey: Keys.dsn)
        self.profileName = userDefaults.string(forKey: Keys.profileName) ?? "Пользователь"
        self.apiAccessToken = secureTokens.accessToken()
        self.apiRefreshToken = secureTokens.refreshToken()
        self.appTheme = AppTheme(rawValue: userDefaults.string(forKey: Keys.appTheme) ?? "") ?? .system
        self.appLanguage = SessionStore.defaultLanguage(userDefaults: userDefaults)

        L10n.setLanguage(appLanguage.rawValue)
    }

    func setDSN(_ value: String?) {
        dsn = value
        if let value {
            userDefaults.set(value, forKey: Keys.dsn)
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
        guard var token = token?.trimmedNonEmpty else { return nil }

        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return token.isEmpty ? nil : token
    }
}

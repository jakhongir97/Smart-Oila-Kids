import Foundation
import SwiftUI

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
        static let apiAccessToken = "API_ACCESS_TOKEN"
        static let appTheme = "APP_THEME"
        static let appLanguage = "APP_LANGUAGE"
    }

    @Published private(set) var dsn: String?
    @Published var profileName: String
    @Published private(set) var apiAccessToken: String?
    @Published private(set) var appTheme: AppTheme
    @Published private(set) var appLanguage: AppLanguage

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.dsn = userDefaults.string(forKey: Keys.dsn)
        self.profileName = userDefaults.string(forKey: Keys.profileName) ?? "Пользователь"
        self.apiAccessToken = userDefaults.string(forKey: Keys.apiAccessToken)
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
        apiAccessToken = token
        if let token, !token.isEmpty {
            userDefaults.set(token, forKey: Keys.apiAccessToken)
        } else {
            userDefaults.removeObject(forKey: Keys.apiAccessToken)
        }
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
    }

    private static func defaultLanguage(userDefaults: UserDefaults) -> AppLanguage {
        if let persisted = userDefaults.string(forKey: Keys.appLanguage),
           let value = AppLanguage(rawValue: persisted) {
            return value
        }
        return AppLanguage.defaultForDevice
    }

    private let userDefaults: UserDefaults
}

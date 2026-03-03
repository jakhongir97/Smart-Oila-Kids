import Foundation

final class SessionStore: ObservableObject {
    private enum Keys {
        static let dsn = "DSN"
        static let profileName = "PROFILE_NAME"
        static let apiAccessToken = "API_ACCESS_TOKEN"
    }

    @Published private(set) var dsn: String?
    @Published var profileName: String
    @Published private(set) var apiAccessToken: String?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.dsn = userDefaults.string(forKey: Keys.dsn)
        self.profileName = userDefaults.string(forKey: Keys.profileName) ?? "Пользователь"
        self.apiAccessToken = userDefaults.string(forKey: Keys.apiAccessToken)
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

    func clearSession() {
        setDSN(nil)
        setAPIAccessToken(nil)
    }

    private let userDefaults: UserDefaults
}

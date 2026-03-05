import Foundation
import Security

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

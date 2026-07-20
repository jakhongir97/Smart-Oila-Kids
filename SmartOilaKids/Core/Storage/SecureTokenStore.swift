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

    /// oila360 device credentials live in their own keychain slots so the two backends'
    /// tokens can never cross-contaminate (legacy tokens include an auth-header prefix;
    /// oila360 tokens are raw JWTs sent as "Bearer <token>").
    static let oila = SecureTokenStore(
        accessTokenAccount: "oila_access_token",
        refreshTokenAccount: "oila_refresh_token"
    )

    private enum Constants {
        static let service = Bundle.main.bundleIdentifier ?? "SmartOilaKids"
        static let accessTokenAccount = "api_access_token"
        static let refreshTokenAccount = "api_refresh_token"

        static let legacyAccessTokenDefaultsKey = "API_ACCESS_TOKEN"
        static let legacyRefreshTokenDefaultsKey = "API_REFRESH_TOKEN"
    }

    private let accessTokenAccount: String
    private let refreshTokenAccount: String

    init(
        accessTokenAccount: String = Constants.accessTokenAccount,
        refreshTokenAccount: String = Constants.refreshTokenAccount
    ) {
        self.accessTokenAccount = accessTokenAccount
        self.refreshTokenAccount = refreshTokenAccount
    }

    func accessToken() -> String? {
        readValue(for: accessTokenAccount)?.trimmedNonEmpty
    }

    func refreshToken() -> String? {
        readValue(for: refreshTokenAccount)?.trimmedNonEmpty
    }

    func setAccessToken(_ token: String?) {
        writeValue(token, for: accessTokenAccount)
    }

    func setRefreshToken(_ token: String?) {
        writeValue(token, for: refreshTokenAccount)
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

    /// Persists (or clears) a value and reports the final Keychain status. Uses update-first so
    /// the read/write is a single atomic Keychain call — the previous check-then-write left a
    /// window where a concurrent writer produced errSecDuplicateItem that was silently swallowed.
    /// On a duplicate we delete-then-add so a corrupt/partial prior entry cannot wedge the slot.
    @discardableResult
    private func writeValue(_ value: String?, for account: String) -> OSStatus {
        let query = baseQuery(for: account)
        guard let value = value?.trimmedNonEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertQuery = query
            insertQuery.merge(attributes) { _, new in new }
            status = SecItemAdd(insertQuery as CFDictionary, nil)
            if status == errSecDuplicateItem {
                SecItemDelete(query as CFDictionary)
                status = SecItemAdd(insertQuery as CFDictionary, nil)
            }
        }
        return status
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.service,
            kSecAttrAccount as String: account
        ]
    }
}

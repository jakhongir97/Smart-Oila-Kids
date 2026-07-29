import Foundation
import Security

/// Why the most recent Keychain write failed. Carries the raw `OSStatus` because that number is
/// what identifies the class of problem (-34018 `errSecMissingEntitlement` = signing/entitlement,
/// -25308 `errSecInteractionNotAllowed` = device locked before first unlock); a boolean alone
/// cannot tell a support engineer those apart.
struct SecureTokenStoreWriteFailure: Equatable {
    /// The Keychain account slot that failed ("api_access_token", "oila_access_token", …).
    /// Never the token value — this string reaches the diagnostics screen.
    let account: String
    let status: OSStatus
    let occurredAt: Date

    /// Single-line form used for the diagnostics timeline.
    var diagnosticDescription: String {
        "keychain_write_failed account=\(account) status=\(status)"
    }
}

protocol SecureTokenStoring {
    func accessToken() -> String?
    func refreshToken() -> String?
    func setAccessToken(_ token: String?)
    func setRefreshToken(_ token: String?)
    func migrateFromUserDefaults(_ userDefaults: UserDefaults)
    func clear()
    /// The last write that the Keychain rejected, or nil when every write so far succeeded.
    /// A failed write silently logs the child out, so callers that must not proceed on a lost
    /// token can check this after storing.
    var lastWriteFailure: SecureTokenStoreWriteFailure? { get }

    /// Store and REPORT whether the Keychain accepted the write. Required on the protocol (not just
    /// the concrete store) so `pair()` can fail loudly through the injected dependency rather than
    /// silently reporting a successful pairing with no credential on disk.
    @discardableResult
    func storeAccessToken(_ token: String?) -> Bool
    @discardableResult
    func storeRefreshToken(_ token: String?) -> Bool
}

extension SecureTokenStoring {
    /// Defaulted so the existing conformers and test doubles — which predate write reporting and
    /// live in files this change does not touch — keep compiling unchanged.
    var lastWriteFailure: SecureTokenStoreWriteFailure? { nil }

    /// Defaults for conformers that do not report write outcomes. They perform the write and then
    /// verify by READING IT BACK, rather than optimistically returning true — an in-memory test
    /// double answers correctly, and a real store that dropped the write is caught.
    @discardableResult
    func storeAccessToken(_ token: String?) -> Bool {
        setAccessToken(token)
        return accessToken()?.trimmedNonEmpty == token?.trimmedNonEmpty
    }

    @discardableResult
    func storeRefreshToken(_ token: String?) -> Bool {
        setRefreshToken(token)
        return refreshToken()?.trimmedNonEmpty == token?.trimmedNonEmpty
    }
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

    /// Writes come from whichever actor made the API call (the device client, the chat socket,
    /// the session store on the main actor), so the outcome bookkeeping is lock-guarded.
    private let stateLock = NSLock()
    private var storedLastWriteStatus: OSStatus = errSecSuccess
    private var storedLastWriteFailure: SecureTokenStoreWriteFailure?
    /// Last failure already pushed to diagnostics — a wedged Keychain fails on every single write,
    /// and an unbounded stream of identical entries would push the real history out of the
    /// diagnostics timeline.
    private var reportedFailureSignature: String?

    init(
        accessTokenAccount: String = Constants.accessTokenAccount,
        refreshTokenAccount: String = Constants.refreshTokenAccount
    ) {
        self.accessTokenAccount = accessTokenAccount
        self.refreshTokenAccount = refreshTokenAccount
    }

    /// Raw status of the most recent write (`errSecSuccess` until one fails).
    var lastWriteStatus: OSStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedLastWriteStatus
    }

    var lastWriteFailure: SecureTokenStoreWriteFailure? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedLastWriteFailure
    }

    func accessToken() -> String? {
        readValue(for: accessTokenAccount)?.trimmedNonEmpty
    }

    func refreshToken() -> String? {
        readValue(for: refreshTokenAccount)?.trimmedNonEmpty
    }

    func setAccessToken(_ token: String?) {
        _ = storeAccessToken(token)
    }

    func setRefreshToken(_ token: String?) {
        _ = storeRefreshToken(token)
    }

    /// Same as `setAccessToken`, but reports whether the Keychain actually accepted the write.
    /// Preferred at the points where a lost token is not recoverable (pairing, token refresh):
    /// the void-returning protocol form cannot tell "stored" from "silently dropped".
    @discardableResult
    func storeAccessToken(_ token: String?) -> Bool {
        write(token, for: accessTokenAccount)
    }

    /// Refresh-token counterpart of `storeAccessToken`.
    @discardableResult
    func storeRefreshToken(_ token: String?) -> Bool {
        write(token, for: refreshTokenAccount)
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

    /// Performs the write and records its outcome. Returns true when the Keychain accepted it.
    private func write(_ value: String?, for account: String) -> Bool {
        let status = writeValue(value, for: account)
        recordWriteOutcome(status: status, account: account)
        return status == errSecSuccess
    }

    /// Remembers the outcome and, on a new failure, publishes it to the diagnostics screen.
    /// Without this a rejected write is invisible: the token is simply gone on the next read and
    /// the child appears to have been logged out for no reason.
    private func recordWriteOutcome(status: OSStatus, account: String) {
        stateLock.lock()
        storedLastWriteStatus = status

        guard status != errSecSuccess else {
            storedLastWriteFailure = nil
            // Clear the dedupe key so a failure that recurs after a healthy write is reported again.
            reportedFailureSignature = nil
            stateLock.unlock()
            return
        }

        let failure = SecureTokenStoreWriteFailure(account: account, status: status, occurredAt: Date())
        storedLastWriteFailure = failure
        let signature = failure.diagnosticDescription
        let isNewFailure = reportedFailureSignature != signature
        reportedFailureSignature = signature
        stateLock.unlock()

        guard isNewFailure else { return }

        // The diagnostics centre is main-actor isolated while writes arrive from any actor, so hop.
        // It has no storage-specific snapshot, and the lifecycle timeline is the app-wide event
        // channel the diagnostics screen already renders — so a wedged Keychain surfaces there
        // rather than nowhere at all.
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updateLifecycle(lastEvent: signature)
        }
    }

    /// Persists (or clears) a value and reports the final Keychain status. Uses update-first so
    /// the read/write is a single atomic Keychain call — the previous check-then-write left a
    /// window where a concurrent writer produced errSecDuplicateItem that was silently swallowed.
    /// On a duplicate we delete-then-add so a corrupt/partial prior entry cannot wedge the slot.
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

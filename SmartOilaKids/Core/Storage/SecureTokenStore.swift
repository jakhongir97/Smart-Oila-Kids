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

/// Why `accessToken()` came back nil — the distinction the app used to be unable to make.
///
/// A nil token has two completely different meanings and only one of them is recoverable by waiting.
/// `errSecInteractionNotAllowed` (device locked before first unlock) is transient: the item is there
/// and will read fine in a moment. `errSecItemNotFound` is CONCLUSIVE: the item is provably not on
/// this device, and no amount of retrying will conjure it. Collapsing both into nil is what let a
/// restored-from-backup install sit "paired" forever with no credential — every item this app writes
/// is `…ThisDeviceOnly`, which iCloud and encrypted-iTunes backups deliberately exclude, while the
/// UserDefaults that say "paired" restore perfectly.
enum SecureTokenCredentialState: Equatable {
    /// A non-empty token was read.
    case present
    /// The Keychain answered `errSecItemNotFound`: there is no such item on this device. Conclusive.
    case absent
    /// The read failed for any other reason (notably locked-before-first-unlock). Say nothing.
    case unreadable(OSStatus)
}

protocol SecureTokenStoring {
    func accessToken() -> String?
    func refreshToken() -> String?
    /// Why `accessToken()` is nil. Defaulted for test doubles, which have no Keychain to ask.
    func accessTokenState() -> SecureTokenCredentialState
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

    /// Defaulted for stores with no Keychain behind them: a token either is or is not there, and an
    /// in-memory double can never be in the "unreadable" state a locked device produces.
    func accessTokenState() -> SecureTokenCredentialState {
        accessToken()?.trimmedNonEmpty == nil ? .absent : .present
    }

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

    /// UserDefaults marker proving the Keychain credentials belong to THIS install of the app.
    nonisolated static let installMarkerKey = "OILA_KEYCHAIN_INSTALL_MARKER"

    /// Drop credentials that outlived an app delete, before anything can route on them.
    ///
    /// Deleting an iOS app destroys its container — UserDefaults with it — but leaves the Keychain
    /// untouched, and everything this app stores there is `AfterFirstUnlockThisDeviceOnly`, which
    /// survives indefinitely. So a parent who "removed" a child's monitoring by deleting the app,
    /// and then reinstalled it, handed the fresh install a LIVE device Bearer for a pairing they
    /// believed was gone, plus the old `dsn` — a real credential for a link the user thinks they cut.
    /// The absence of the UserDefaults marker is the only evidence available that the container is
    /// new, and it is sufficient: nothing else survives a delete either.
    ///
    /// The same shape the parent-PIN verifier already uses (`SessionStore.setOilaPaired(true)` →
    /// `SettingsProtectionController.wipePersistedPINState`): device-global Keychain state is wiped
    /// at the moment authority changes hands, rather than being trusted because it is present. This
    /// deliberately does NOT touch the PIN verifier itself — that one is already handled at pairing
    /// by the owner of that mechanism, and a second wipe from here would be a second thing to keep
    /// in sync.
    ///
    /// The marker is written even when the deletes could not be verified. The alternative — write it
    /// only on a proven-clean read-back — turns a Keychain that was briefly unreadable (locked before
    /// first unlock) into a purge that runs on EVERY later launch, including the launches after a
    /// successful pairing, wiping the credential it just minted. A stale item surviving one attempt
    /// is bounded: the install is unpaired either way, so it routes to pairing, and the next pairing
    /// overwrites the slots.
    @discardableResult
    nonisolated static func purgeCredentialsOrphanedByReinstall(userDefaults: UserDefaults = .standard) -> Bool {
        guard !userDefaults.bool(forKey: installMarkerKey) else { return false }
        // The legacy account tokens and the oila360 device Bearer live in different slots; both are
        // credentials and both survive the delete.
        shared.clear()
        oila.clear()
        // The old serial goes with them. It is Keychain-backed precisely SO it survives a reinstall
        // (see `OilaDeviceIdentity.dsnStore`) — which is right while the credential survives too,
        // and wrong the moment the credential is taken away: the next pairing would otherwise
        // inherit the previous child's DSN scope, the very thing `resetDSN` exists to prevent.
        OilaDeviceIdentity.resetDSN(userDefaults: userDefaults)
        userDefaults.set(true, forKey: installMarkerKey)
        return true
    }

    private func readValue(for account: String) -> String? {
        readValue(for: account).value
    }

    /// The read, keeping the `OSStatus` the plain accessor throws away.
    ///
    /// Everything above this line wants a `String?`; only the credential-liveness path needs to tell
    /// "not on this device" from "cannot look right now", so the status is carried alongside rather
    /// than forced on every caller.
    private func readValue(for account: String) -> (value: String?, status: OSStatus) {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess else {
            return (nil, status)
        }

        guard let data = item as? Data else {
            return (nil, status)
        }

        return (String(data: data, encoding: .utf8), status)
    }

    func accessTokenState() -> SecureTokenCredentialState {
        let read: (value: String?, status: OSStatus) = readValue(for: accessTokenAccount)
        if read.value?.trimmedNonEmpty != nil { return .present }
        // A stored-but-empty item is as useless as a missing one, and it is equally conclusive:
        // the Keychain answered, and what it holds cannot authorize a request.
        if read.status == errSecSuccess { return .absent }
        return read.status == errSecItemNotFound ? .absent : .unreadable(read.status)
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

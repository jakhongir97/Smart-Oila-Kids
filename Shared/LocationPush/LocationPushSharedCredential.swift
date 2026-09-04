import Foundation

/// The one piece of state a location push has to carry across the process boundary.
///
/// A location push does not wake the app — it launches a separate extension process
/// (`CLLocationPushServiceExtension`), which has its own container, its own `Bundle.main` and its
/// own default Keychain scope. To answer the push it needs three things the app already holds: the
/// device bearer token, the API root, and the device serial for diagnostics.
///
/// **Why a copy, and not a shared reading of the real token.** A Keychain item's identity is
/// (class, service, account, access group). `SecureTokenStore` keys its items on
/// `Bundle.main.bundleIdentifier` with no access group, so every paired child in the field has an
/// item under service `uz.smartoila.kids` in this app's private group. Moving those items into a
/// shared access group — or changing the service string so the extension could compute it — would
/// change their identity, and a migration that fails on any device silently unpairs that child.
/// This app is live on real families' phones, so that risk buys nothing worth having.
///
/// Instead the app WRITES a copy here, into a new item that has never existed before, and the
/// extension only ever READS it. Nothing about the existing items changes. Worst case the copy is
/// missing or stale: the extension then answers the push without uploading, which is exactly what
/// happens today with no extension at all.
///
/// The copy carries the same protection class as the original
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`): unavailable until the first unlock after a
/// reboot, never in an iCloud or iTunes backup, never on another device.
enum LocationPushSharedCredential {
    /// What the extension needs to answer one push.
    struct Payload: Codable, Equatable {
        /// Device bearer token, as sent in `Authorization: Bearer …`.
        var accessToken: String
        /// API root, so the extension cannot drift from the app's configured environment.
        var baseURL: String
        /// Device serial. Diagnostics only — the token is what authorizes the upload.
        var dsn: String?
        /// When the app last refreshed this copy, so a stale credential is recognisable.
        var updatedAt: Date
    }

    /// Shared Keychain access group, WITH the team prefix.
    ///
    /// Both entitlements files declare `$(AppIdentifierPrefix)uz.smartoila.kids.shared`, and Xcode
    /// expands that at build time to `3TWN5NW4BL.uz.smartoila.kids.shared`. `kSecAttrAccessGroup`
    /// is matched against the expanded value — "each must specify this shared access group name as
    /// the value for the kSecAttrAccessGroup key" (Security/SecItem.h) — so the prefix has to be
    /// present here too. Passing the bare name fails with `errSecMissingEntitlement` on device,
    /// where nothing in the app is watching to notice.
    ///
    /// The team id is a literal because it already is one everywhere else in this project: the App
    /// Group is `group.3twn5nw4bl.uz.smartoila.kids` and `DEVELOPMENT_TEAM` is set per target.
    static let accessGroup = "3TWN5NW4BL.uz.smartoila.kids.shared"

    /// Deliberately a literal, not `Bundle.main.bundleIdentifier`. The app and the extension have
    /// different bundle identifiers, and the service string is part of the item's identity, so a
    /// computed value would have the two processes reading two different items.
    private static let service = "uz.smartoila.kids.locationpush"
    private static let account = "device_credential"

    // MARK: - App side

    /// Refresh the copy. Called wherever the real token is written, so the copy cannot outlive it
    /// by more than one refresh cycle.
    ///
    /// A nil or blank token clears the copy rather than leaving a dead one behind: an unpaired
    /// device must not keep a credential that a push could still try to use.
    /// Returns the Keychain status so the caller can surface a failure. An access group the signed
    /// profile does not actually carry answers `errSecMissingEntitlement` here, and that is
    /// otherwise invisible until a push arrives at an extension with no credential to use.
    @discardableResult
    static func publish(accessToken: String?, baseURL: URL, dsn: String?, now: Date = Date()) -> OSStatus {
        guard let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return clear()
        }
        let payload = Payload(
            accessToken: accessToken,
            baseURL: baseURL.absoluteString,
            dsn: dsn?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? dsn : nil,
            updatedAt: now
        )
        guard let data = try? JSONEncoder().encode(payload) else { return errSecParam }
        return write(data)
    }

    /// Remove the copy. Called on unpair and on a confirmed session invalidation, alongside the
    /// teardown of the real tokens. An item that was never there is success, not a failure.
    @discardableResult
    static func clear() -> OSStatus {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    // MARK: - Extension side

    /// Read the copy, WITH the Keychain status.
    ///
    /// The status is returned because three very different conditions all produce a nil payload and
    /// the extension's breadcrumb trail is the only place anyone can tell them apart on a real
    /// device: `errSecItemNotFound` means unpaired or never written, `errSecInteractionNotAllowed`
    /// means the phone has not been unlocked since boot (retry later is the right answer),
    /// `errSecMissingEntitlement` means the access group is not really granted (a build problem, and
    /// no amount of retrying fixes it). Collapsing them into nil turns a one-line diagnosis into a
    /// day of guessing.
    static func read() -> (payload: Payload?, status: OSStatus) {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return (nil, status) }
        return (try? JSONDecoder().decode(Payload.self, from: data), status)
    }

    // MARK: - Internals

    private static func write(_ data: Data) -> OSStatus {
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // Update-first, so the read/write is one atomic Keychain call — the same shape
        // `SecureTokenStore.writeValue` settled on, and for the same reason: a check-then-write
        // races with a concurrent writer and swallows `errSecDuplicateItem`.
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            status = SecItemAdd(insert as CFDictionary, nil)
            if status == errSecDuplicateItem {
                SecItemDelete(query as CFDictionary)
                status = SecItemAdd(insert as CFDictionary, nil)
            }
        }
        return status
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }
}

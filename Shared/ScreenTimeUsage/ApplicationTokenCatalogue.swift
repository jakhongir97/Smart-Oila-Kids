import Foundation
import ManagedSettings
import os

/// The bridge from a bundle id the SERVER knows to an `ApplicationToken` the SYSTEM will act on.
///
/// It exists because of a measured fact, not a theory. On an iPhone 12 mini (iOS 26.6.1,
/// authorization `.individual`, entitlement signed on the app and both extensions) we applied four
/// third-party bundle ids to `ManagedSettingsStore.application.blockedApplications`. The write was
/// accepted — no error, and reading the property back returned all four — and **nothing on the
/// home screen changed**. In the same session, on the same device, `shield.applicationCategories =
/// .all()` dimmed every app with an hourglass badge, exactly as Apple documents. So the system is
/// enforcing our policies; it simply does not act on an `Application` built from a bundle
/// identifier. Tokens are the currency it honours, and `Token` has no public initialiser.
///
/// There is exactly one place iOS hands out both halves at once: inside a `DeviceActivityReport`
/// extension, `DeviceActivityData.ApplicationActivity.application` carries a non-nil
/// `bundleIdentifier` AND a usable `token`.
///
/// ⚠️ AND THAT PLACE CANNOT SHARE THEM. Measured on the same device, same App Group, same second:
///
///     extension: read_back=apps=8  ext_keys=SCREEN_TIME_APPLICATION_TOKENS_V1,
///                …_USAGE_SNAPSHOT_…, …_HISTORY_INDEX_…, …_HISTORY_SNAPSHOT_…
///     app:       keys=SCREEN_TIME_USAGE_BRIDGE_CONFIGURATION          ← only its OWN write
///
/// The report extension writes successfully, reads its own writes back, and the app — holding the
/// identical `com.apple.security.application-groups` entitlement, across process restarts — sees
/// none of it. Its container is redirected by the privacy sandbox Apple describes for shield
/// configuration extensions ("prevents your extension from … moving sensitive content outside the
/// extension's address space"); the same applies here.
///
/// So this type works, and is kept, but NOTHING FILLS IT on iOS 26 by this route. What fills it
/// instead (2026-09-16) is the PARENT: `ScreenTimeRestrictedAppsStore` runs `FamilyActivityPicker`
/// on the child's phone and asks the parent to say which catalogue app each picked icon is —
/// `Label(token)` shows them the real name and icon, the app just cannot read it. Every label is
/// one `Entry` here, written by the app process into the real App Group, which the app and the
/// schedule-monitor extension both see (measured 2026-09-16). The consequences of the sandbox are
/// still the product's, not the code's:
/// * per-app usage cannot be exported from iOS at all — it exists only inside an extension that
///   may render it on the child's screen and may not hand it to anyone;
/// * per-app blocking cannot be driven by a bundle id from the server, because no token for that
///   bundle id can ever reach the app process. The only supply of tokens the app can keep is
///   `FamilyActivityPicker`, which needs one human tap on the child's phone.
/// The whole-device lock has neither problem: it needs no identity at all, and it is proven.
struct ApplicationTokenCatalogue {
    struct Entry: Codable, Equatable {
        /// Lower-cased, so it matches what the usage reporter sends the server.
        let bundleId: String
        let displayName: String?
        let token: ApplicationToken
        let lastSeenAt: Date
    }

    /// Bounded so a phone with hundreds of apps cannot grow this without limit inside an App Group
    /// that a 6 MB extension also has to read.
    static let maximumEntries = 300
    static let storageKey = "SCREEN_TIME_APPLICATION_TOKENS_V1"

    /// Posted whenever the map grows, so the app can re-apply blocks that were unenforceable until
    /// this moment. Darwin, because the writer is usually the report extension.
    static let didChangeDarwinNotification = "uz.smartoila.kids.application-tokens-changed"

    init(userDefaults: UserDefaults? = ScreenTimeUsageAppGroup.sharedUserDefaults()) {
        self.userDefaults = userDefaults
    }

    var isAvailable: Bool { userDefaults != nil }

    func entries() -> [Entry] {
        guard let userDefaults, let data = userDefaults.data(forKey: Self.storageKey) else { return [] }
        return Self.decodeCache.entries(for: data) {
            (try? JSONDecoder().decode([Entry].self, from: $0)) ?? []
        }
    }

    /// The last decode, keyed by the exact stored bytes. One Settings tap reads the catalogue a
    /// dozen times (label, rows, enforcement, arm) and each read decoded up to 300 tokens on the
    /// main thread. Keyed by the bytes, not by a flag, so a write from the OTHER process (a
    /// different blob) is never served stale.
    private static let decodeCache = DecodeCache()

    private final class DecodeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var decoded: [Entry] = []

        func entries(for data: Data, decode: (Data) -> [Entry]) -> [Entry] {
            lock.lock()
            if data == self.data {
                let hit = decoded
                lock.unlock()
                return hit
            }
            lock.unlock()
            let fresh = decode(data)
            lock.lock()
            self.data = data
            decoded = fresh
            lock.unlock()
            return fresh
        }
    }

    /// Merge newly-seen apps into the map, newest-wins, oldest-dropped past the cap.
    ///
    /// Merging rather than replacing is the whole point: one report pass only sees apps used in
    /// the window it covers, so replacing would make yesterday's apps unblockable today.
    func merge(_ newEntries: [Entry]) {
        guard let userDefaults, !newEntries.isEmpty else { return }

        var byBundleId: [String: Entry] = [:]
        for entry in entries() {
            byBundleId[entry.bundleId] = entry
        }
        for entry in newEntries {
            byBundleId[entry.bundleId] = entry
        }

        let merged = byBundleId.values
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .prefix(Self.maximumEntries)

        guard let data = try? JSONEncoder().encode(Array(merged)) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
        Self.log.notice(
            "token_catalogue merged=\(newEntries.count, privacy: .public) total=\(merged.count, privacy: .public)"
        )
        // Tell the app, which may be sitting on a block it could not enforce a second ago. The
        // write above happens in the report EXTENSION as often as in the app, so this crosses a
        // process boundary — hence a Darwin notification rather than NotificationCenter.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.didChangeDarwinNotification as CFString),
            nil,
            nil,
            true
        )
    }

    func clear() {
        userDefaults?.removeObject(forKey: Self.storageKey)
    }

    /// The entry a given token stands for, if a label exists for it. Linear, because the map is
    /// keyed by bundle id (the server's key) and is capped at `maximumEntries`.
    func entry(for token: ApplicationToken) -> Entry? {
        entries().first { $0.token == token }
    }

    /// Drop the label for one bundle id — a parent un-labelling an app, or re-labelling a token
    /// that used to stand for another. Posts the same notification as `merge`, because a block the
    /// app was enforcing for that id must be lifted with it.
    func remove(bundleId: String) {
        guard let userDefaults else { return }
        let key = bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = entries()
        let remaining = all.filter { $0.bundleId != key }
        guard remaining.count != all.count else { return }
        if let data = try? JSONEncoder().encode(remaining) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
        Self.log.notice("token_catalogue removed=\(key, privacy: .public) total=\(remaining.count, privacy: .public)")
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.didChangeDarwinNotification as CFString),
            nil,
            nil,
            true
        )
    }

    /// Tokens for the bundle ids we know, and the ids we could not resolve — the caller needs both,
    /// because "blocked" and "we were told to block it but cannot" must not look the same to a
    /// parent.
    func resolve(bundleIds: [String]) -> (tokens: Set<ApplicationToken>, unresolved: [String]) {
        let known = Dictionary(entries().map { ($0.bundleId, $0.token) }, uniquingKeysWith: { first, _ in first })
        var tokens: Set<ApplicationToken> = []
        var unresolved: [String] = []

        for bundleId in bundleIds {
            let key = bundleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let token = known[key] {
                tokens.insert(token)
            } else {
                unresolved.append(bundleId)
            }
        }

        return (tokens, unresolved)
    }

    private let userDefaults: UserDefaults?

    static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime")
}

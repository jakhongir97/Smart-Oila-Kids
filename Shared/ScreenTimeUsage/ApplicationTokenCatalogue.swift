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
/// So this type works, and is kept, but NOTHING FILLS IT on iOS 26 by this route. The consequences
/// are the product's, not the code's:
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
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
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

import Foundation
import ManagedSettings

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
/// `bundleIdentifier` AND a usable `token`. The report extension therefore writes what it learns
/// here, and the app reads it back to turn `lockedPackages` into a shield.
///
/// Consequences worth stating plainly, because they shape the product:
/// * An app the child has never opened has never appeared in a report, so it has no token and
///   cannot be blocked individually yet. The whole-device lock does not have this problem — it
///   needs no tokens at all.
/// * Tokens are voided if authorization is revoked and re-granted, so a stale entry can stop
///   matching. Entries are re-learned on every report pass, and a token that no longer resolves is
///   simply inert rather than harmful.
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
}

import Foundation

enum AppConfig {
    /// oila360 device API root (Bolajon360 redesign). Device pairing + telemetry live here.
    /// Paths are appended without the `/api/v1` prefix, e.g. `device/pair`.
    static let oilaAPIBaseURL = configuredURL(
        envKey: "OILA_API_BASE_URL",
        fallback: "https://api.oila360.uz/api/v1"
    )
    /// Public privacy policy, surfaced from Settings and required by App Store Guideline 5.1.1(i)
    /// for an app that collects background location.
    /// Follows the language the child is actually reading the app in. This was hard-pinned to
    /// `/uz/`, so a family using the app in Russian or English — both shipped locales — was sent to
    /// an Uzbek-only privacy policy from the Settings row, and App Review follows that same link.
    /// uz-Cyrl is served by the same `/uz/` document as uz-Latn.
    static var privacyPolicyURL: URL {
        configuredURL(
            envKey: "SMARTOILA_PRIVACY_POLICY_URL",
            fallback: "https://oila360.uz/\(privacyPolicyLanguagePath)/privacy"
        )
    }

    private static var privacyPolicyLanguagePath: String {
        switch UserDefaults.standard.string(forKey: "APP_LANGUAGE") {
        case "ru": return "ru"
        case "en": return "en"
        default: return "uz"
        }
    }
}

private extension AppConfig {
    static func configuredURL(envKey: String, fallback: String) -> URL {
        let raw = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        return URL(string: fallback)!
    }
}

/// Caches whether THIS build is currently under App Store review, from the public
/// `GET /api/v1/app-config` endpoint (`{ storeReviewMode }`).
///
/// When review mode is active the app hides its covert feature — live audio/video streaming — so a
/// build sitting in App Review cannot exhibit behaviour App Review would reject on a children's
/// device. An operator flips this per-build from the admin panel; every other build reads `false`.
///
/// FAIL-SAFE FALSE. The backend contract is explicit — "any error or timeout must be treated as
/// false" — and that is also the right production default: the config call may be rate-limited,
/// slow, or briefly unavailable, and none of those should hide paid features from a real family.
/// So an unset value, a network failure, or an unparseable body all resolve to "not under review".
///
/// The cached value is a plain `UserDefaults` bool, read SYNCHRONOUSLY wherever a covert feature is
/// about to start (e.g. `PushCommandRouter.applyRouting`), and refreshed asynchronously at launch.
/// It persists across launches so a review build stays protected even before the first refresh.
final class StoreReviewModeStore {
    static let shared = StoreReviewModeStore()

    static let defaultsKey = "BOLAJON_STORE_REVIEW_MODE"

    private let userDefaults: UserDefaults
    private let fetch: () async -> Bool?

    init(
        userDefaults: UserDefaults = .standard,
        fetch: @escaping () async -> Bool? = { try? await OilaDeviceClient.shared.fetchStoreReviewMode() }
    ) {
        self.userDefaults = userDefaults
        self.fetch = fetch
    }

    /// Synchronous last-known value. `false` until the first successful refresh, then the last value
    /// seen, held across launches. Safe to read from any thread (`UserDefaults` is thread-safe).
    var isActive: Bool { userDefaults.bool(forKey: Self.defaultsKey) }

    /// Fetch and cache. Only a DEFINITIVE answer is written; a failure or timeout leaves the last
    /// known value in place.
    ///
    /// The backend's "treat any error as false" rule governs a build that has never had an answer —
    /// and that case is already covered, because `isActive` reads false until something is cached.
    /// Applying it to the CACHE too would be actively unsafe: this endpoint is rate-limited
    /// (60/min/IP), so a single 429 or a dropped connection while the build sits in App Review would
    /// erase a known `true` and re-open the microphone in front of the reviewer. The asymmetry
    /// decides it — a stale `true` costs a real family live audio until the next refresh, a stale
    /// `false` costs an App Store rejection on a children's app.
    func refresh() async {
        guard let value = await fetch() else { return }
        userDefaults.set(value, forKey: Self.defaultsKey)
    }
}

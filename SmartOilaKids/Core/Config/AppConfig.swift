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

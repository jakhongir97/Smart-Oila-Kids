import Foundation

enum AppConfig {
    /// oila360 device API root (Bolajon360 redesign). Device pairing + telemetry live here.
    /// Paths are appended without the `/api/v1` prefix, e.g. `device/pair`.
    static let oilaAPIBaseURL = configuredURL(
        envKey: "OILA_API_BASE_URL",
        fallback: "https://api.oila360.uz/api/v1"
    )
    static let inviteShareURL = configuredURL(
        envKey: "SMARTOILA_INVITE_SHARE_URL",
        fallback: "https://smart-oila.uz"
    )
    /// Public privacy policy, surfaced from Settings and required by App Store Guideline 5.1.1(i)
    /// for an app that collects background location.
    static let privacyPolicyURL = configuredURL(
        envKey: "SMARTOILA_PRIVACY_POLICY_URL",
        fallback: "https://oila360.uz/uz/privacy"
    )

    static let inviteLinkSource = "kids_invite"
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

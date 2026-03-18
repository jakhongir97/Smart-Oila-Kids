import Foundation

enum AppConfig {
    static let apiBaseURL = configuredURL(
        envKey: "SMARTOILA_API_BASE_URL",
        fallback: "https://backend.smart-oila.uz/api"
    )

    static let apiBaseCandidates = [apiBaseURL]
    static let inviteShareURL = configuredURL(
        envKey: "SMARTOILA_INVITE_SHARE_URL",
        fallback: "https://smart-oila.uz"
    )
    static let legacyDeviceClaimURL = configuredURL(
        envKey: "SMARTOILA_LEGACY_DEVICE_CLAIM_URL",
        fallback: "https://child-tracker.uz/upload-v2/device"
    )
    static let qrClaimPath = configuredString(
        envKey: "SMARTOILA_QR_CLAIM_PATH",
        fallback: "auth_v2/child/claim_qr"
    )

    static let websocketTokenPath = configuredWebSocketTokenPath()
    static let websocketBaseCandidates = configuredWebSocketBases()
    static var legacyDeviceClaimFallbackEnabled: Bool {
        configuredBool(
            envKey: "SMARTOILA_ENABLE_LEGACY_DEVICE_CLAIM_FALLBACK",
            defaultValue: true
        )
    }
    static var mediaStreamWebSocketMode: MediaStreamWebSocketMode {
        MediaStreamWebSocketMode(
            environmentValue: ProcessInfo.processInfo.environment["SMARTOILA_MEDIA_STREAM_SOCKET_MODE"]
        )
    }

    static let inviteLinkSource = "kids_invite"
}

enum MediaStreamWebSocketMode: Equatable {
    case legacyOnly
    case v2Preferred
    case v2Only

    init(environmentValue: String?) {
        let normalized = environmentValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "v2", "v2-only", "v2_only", "v2only":
            self = .v2Only
        case "v2-preferred", "v2_preferred", "prefer-v2", "prefer_v2", "dual":
            self = .v2Preferred
        default:
            self = .legacyOnly
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

    static func configuredString(envKey: String, fallback: String) -> String {
        let raw = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty {
            return raw
        }
        return fallback
    }

    static func configuredBool(envKey: String, defaultValue: Bool) -> Bool {
        let raw = ProcessInfo.processInfo.environment[envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }

    static func configuredWebSocketBases() -> [String] {
        let defaultBase = "wss://backend.smart-oila.uz"

        if let raw = ProcessInfo.processInfo.environment["SMARTOILA_WEBSOCKET_BASE_URLS"] {
            let values = raw
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap(normalizeWebSocketBase)
            if !values.isEmpty {
                return values
            }
        }

        if let raw = ProcessInfo.processInfo.environment["SMARTOILA_WEBSOCKET_BASE_URL"],
           let value = normalizeWebSocketBase(raw) {
            return [value]
        }

        return [defaultBase]
    }

    static func configuredWebSocketTokenPath() -> String {
        let defaultSecret = "s7n8hPkmJtdY6CfMWGQKpF2uZHVcw5gX"
        let rawSecret = ProcessInfo.processInfo.environment["SMARTOILA_WEBSOCKET_SECRETKEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = (rawSecret?.isEmpty == false ? rawSecret : nil) ?? defaultSecret
        return "/ws/\(secret)"
    }

    static func normalizeWebSocketBase(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") else { return nil }

        if trimmed.hasSuffix("/") {
            return String(trimmed.dropLast())
        }
        return trimmed
    }
}

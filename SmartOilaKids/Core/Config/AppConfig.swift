import Foundation
import Combine

enum AppConfig {
    static let apiBaseURL = configuredURL(
        envKey: "SMARTOILA_API_BASE_URL",
        fallback: "https://backend.smart-oila.uz/api"
    )

    static let apiBaseCandidates = [apiBaseURL]
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
}

enum AppRuntime {
    private static let environment = ProcessInfo.processInfo.environment

    static var debugRoute: DebugRoute? {
#if DEBUG
        guard let value = trimmed("SMARTOILA_DEBUG_ROUTE") else { return nil }
        return DebugRoute(rawValue: value)
#else
        return nil
#endif
    }

    static var hasDebugRoute: Bool {
        debugRoute != nil
    }

    static var debugAuthStage: DebugAuthStage? {
#if DEBUG
        guard let value = trimmed("SMARTOILA_DEBUG_AUTH_STAGE") else { return nil }
        return DebugAuthStage(rawValue: value)
#else
        return nil
#endif
    }

    static var debugPermissionsStage: DebugPermissionsStage? {
#if DEBUG
        guard let value = trimmed("SMARTOILA_DEBUG_PERMISSIONS_STAGE") else { return nil }
        return DebugPermissionsStage(rawValue: value)
#else
        return nil
#endif
    }

    static var debugDSN: String? {
#if DEBUG
        return trimmed("SMARTOILA_DEBUG_DSN")
#else
        return nil
#endif
    }

    static var debugProfileName: String? {
#if DEBUG
        return trimmed("SMARTOILA_DEBUG_PROFILE")
#else
        return nil
#endif
    }

    static var showGeoDebugOverlay: Bool {
#if DEBUG
        guard let value = trimmed("SMARTOILA_SHOW_GEO_DEBUG_OVERLAY")?.lowercased() else {
            return false
        }
        return value == "1" || value == "true" || value == "yes"
#else
        return false
#endif
    }
}

enum DebugRoute: String {
    case auth
    case main
    case permissions
    case settings
    case chat
    case tasks
    case templates
}

enum DebugAuthStage: String {
    case splash
    case scan
    case failed
    case success
}

enum DebugPermissionsStage: String {
    case intro
    case checklist
    case done
}

enum LoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var errorMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
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

private extension AppRuntime {
    static func trimmed(_ key: String) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

@MainActor
final class RuntimeDiagnosticsCenter: ObservableObject {
    static let shared = RuntimeDiagnosticsCenter()

    @Published private(set) var geo = GeoDiagnosticsSnapshot()
    @Published private(set) var chat = ChatDiagnosticsSnapshot()

    private init() {}

    func updateGeo(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastPayload: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil
    ) {
        if let status {
            geo.status = status
        }
        if let endpoint {
            geo.endpoint = endpoint
        }
        if let dsn {
            geo.dsn = dsn
        }
        if let lastPayload {
            geo.lastPayload = lastPayload
        }
        if let lastError {
            geo.lastError = lastError
        }
        if let reconnectCount {
            geo.reconnectCount = reconnectCount
        }
        geo.updatedAt = Date()
    }

    func updateChat(
        status: String? = nil,
        endpoint: String? = nil,
        dsn: String? = nil,
        lastMessage: String? = nil,
        lastError: String? = nil,
        reconnectCount: Int? = nil
    ) {
        if let status {
            chat.status = status
        }
        if let endpoint {
            chat.endpoint = endpoint
        }
        if let dsn {
            chat.dsn = dsn
        }
        if let lastMessage {
            chat.lastMessage = lastMessage
        }
        if let lastError {
            chat.lastError = lastError
        }
        if let reconnectCount {
            chat.reconnectCount = reconnectCount
        }
        chat.updatedAt = Date()
    }
}

struct GeoDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var lastPayload: String = "-"
    var lastError: String = "-"
    var reconnectCount: Int = 0
    var updatedAt: Date? = nil
}

struct ChatDiagnosticsSnapshot {
    var status: String = "idle"
    var endpoint: String = "-"
    var dsn: String = "-"
    var lastMessage: String = "-"
    var lastError: String = "-"
    var reconnectCount: Int = 0
    var updatedAt: Date? = nil
}

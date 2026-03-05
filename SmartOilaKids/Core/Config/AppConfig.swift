import Foundation
import Combine

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

    static let inviteLinkSource = "kids_invite"
}

struct InviteAttributionContext: Codable, Equatable {
    let inviterName: String
    let inviterDSN: String?
    let referralCode: String?
    let openedAt: Date
}

enum InviteAttributionUserInfoKey {
    static let inviterDSN = "inviter_dsn"
}

extension Notification.Name {
    static let inviteAttributionDidChange = Notification.Name("inviteAttributionDidChange")
}

enum InviteLinkBuilder {
    static func makeURL(baseURL: URL, inviterName: String, inviterDSN: String?) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }

        var queryItems = components.queryItems ?? []
        upsertQueryItem(name: "invite", value: "1", queryItems: &queryItems)
        upsertQueryItem(name: "source", value: AppConfig.inviteLinkSource, queryItems: &queryItems)
        upsertQueryItem(name: "inviter_name", value: inviterName.trimmingCharacters(in: .whitespacesAndNewlines), queryItems: &queryItems)
        upsertQueryItem(name: "ref", value: makeReferralCode(), queryItems: &queryItems)

        if let inviterDSN = normalizeDSN(inviterDSN) {
            upsertQueryItem(name: "inviter_dsn", value: inviterDSN, queryItems: &queryItems)
        }

        components.queryItems = queryItems
        return components.url ?? baseURL
    }

    private static func makeReferralCode() -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(raw.prefix(10))
    }

    private static func normalizeDSN(_ value: String?) -> String? {
        guard let value = value?.trimmedNonEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.unicodeScalars.contains(where: { !allowed.contains($0) }) else {
            return nil
        }
        return value
    }

    private static func upsertQueryItem(name: String, value: String, queryItems: inout [URLQueryItem]) {
        queryItems.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        queryItems.append(URLQueryItem(name: name, value: value))
    }
}

final class InviteAttributionStore {
    static let shared = InviteAttributionStore()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    @discardableResult
    func captureIfInviteURL(_ url: URL) -> InviteAttributionContext? {
        guard let context = parse(url: url) else { return nil }

        lock.lock()
        saveContextLocked(context)
        lock.unlock()

        GrowthMetricsStore.shared.track(.inviteLinkOpened, dsn: context.inviterDSN)

        var userInfo: [String: String] = [:]
        if let inviterDSN = context.inviterDSN {
            userInfo[InviteAttributionUserInfoKey.inviterDSN] = inviterDSN
        }
        NotificationCenter.default.post(
            name: .inviteAttributionDidChange,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )

        return context
    }

    func current() -> InviteAttributionContext? {
        lock.lock()
        let context = loadContextLocked()
        lock.unlock()
        return context
    }

    func clear() {
        lock.lock()
        userDefaults.removeObject(forKey: storageKey)
        lock.unlock()
    }

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private let storageKey = "INVITE_ATTRIBUTION_CONTEXT"

    private func parse(url: URL) -> InviteAttributionContext? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = allQueryItems(from: components)
        let source = queryValue(for: ["source"], in: queryItems)?.lowercased()
        let inviteMarker = queryValue(for: ["invite"], in: queryItems)
        let hasInviteMarker = source == AppConfig.inviteLinkSource || inviteMarker == "1"
        guard hasInviteMarker else { return nil }

        let inviterName = queryValue(
            for: ["inviter_name", "invitername", "name", "family"],
            in: queryItems
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        let inviterDSN = normalizeDSN(queryValue(
            for: ["inviter_dsn", "inviterdsn", "dsn"],
            in: queryItems
        ))

        let referralCode = queryValue(
            for: ["ref", "referral", "referral_code", "invite_ref"],
            in: queryItems
        )?.trimmedNonEmpty

        guard inviterName?.isEmpty == false || inviterDSN != nil else {
            return nil
        }

        return InviteAttributionContext(
            inviterName: inviterName?.trimmedNonEmpty ?? "Smart Oila",
            inviterDSN: inviterDSN,
            referralCode: referralCode,
            openedAt: Date()
        )
    }

    private func queryValue(for names: [String], in items: [URLQueryItem]) -> String? {
        for name in names {
            if let value = items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value?.trimmedNonEmpty {
                return value
            }
        }
        return nil
    }

    private func normalizeDSN(_ value: String?) -> String? {
        guard let value = value?.trimmedNonEmpty, value.count <= 64 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.unicodeScalars.contains(where: { !allowed.contains($0) }) else {
            return nil
        }
        return value
    }

    private func allQueryItems(from components: URLComponents) -> [URLQueryItem] {
        var items = components.queryItems ?? []

        let fragments = [components.fragment, components.fragment?.removingPercentEncoding]
            .compactMap { $0?.trimmedNonEmpty }
        for fragment in fragments where fragment.contains("=") {
            if let fragmentItems = URLComponents(string: "?\(fragment)")?.queryItems {
                items.append(contentsOf: fragmentItems)
            }
        }

        return items
    }

    private func loadContextLocked() -> InviteAttributionContext? {
        guard let data = userDefaults.data(forKey: storageKey),
              let context = try? JSONDecoder().decode(InviteAttributionContext.self, from: data) else {
            return nil
        }
        return context
    }

    private func saveContextLocked(_ context: InviteAttributionContext) {
        guard let data = try? JSONEncoder().encode(context) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
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

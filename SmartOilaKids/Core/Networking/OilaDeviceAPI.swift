import Foundation
import UIKit

// oila360 device API client (Bolajon360 redesign).
//
// Self-contained on purpose: the legacy APIClient / services target the old
// backend (backend.smart-oila.uz / child-tracker.uz). This client speaks the
// oila360 contract — `{ "success": true, "data": … }` envelope, device Bearer
// token from `POST /device/pair`, typed error codes — and is what the new
// redesigned screens call. Token responses are undocumented in the spec, so
// token/child/task parsing is tolerant of key naming.

// MARK: - Errors

struct OilaAPIError: LocalizedError {
    let statusCode: Int
    let message: String
    let errorCode: String?
    let fieldErrors: [String]

    var errorDescription: String? { message }

    /// The refresh token is no longer valid — the caller should force re-pairing.
    var requiresRePair: Bool {
        errorCode == "REFRESH_INVALID" || errorCode == "UNAUTHORIZED" || statusCode == 401
    }
}

// MARK: - Device identity (for RedeemPairingDto)

/// Stable per-install identity sent in the pairing request and reused afterwards.
enum OilaDeviceIdentity {
    private static let dsnKey = "OILA_DEVICE_DSN"

    /// Generate-once, persist-forever device serial number sent as `dsn`.
    static func deviceDSN(userDefaults: UserDefaults = .standard) -> String {
        if let existing = userDefaults.string(forKey: dsnKey)?.trimmedNonEmpty {
            return existing
        }
        let generated = UUID().uuidString
        userDefaults.set(generated, forKey: dsnKey)
        return generated
    }

    static var platform: String { "Ios" }

    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        let trimmed = machine.trimmedNonEmpty
        return trimmed ?? UIDevice.current.model
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static var timezone: String { TimeZone.current.identifier }
}

// MARK: - Models

/// Tolerant token payload extracted from an untyped `data` object.
struct OilaTokens {
    let accessToken: String
    let refreshToken: String?
}

struct OilaChildProfile {
    let id: String?
    let name: String?
    let avatarURL: String?
}

struct OilaPairResult {
    let tokens: OilaTokens
    let child: OilaChildProfile?
    /// The dsn we sent and the server accepted; persist as the session DSN.
    let dsn: String
}

struct OilaDeviceTask: Identifiable {
    let id: String
    let title: String
    let status: String        // Active | Completed | Cancelled
    let rewardPoints: Int
    let emoji: String?
    let dueAt: Date?
    let completedAt: Date?

    var isCompleted: Bool { status.lowercased() == "completed" }
    /// The date used to group tasks (Bugun / Kecha) — completion date, else due date.
    var groupingDate: Date? { completedAt ?? dueAt }
}

/// One GPS fix for `POST /device/location/batch` (LocationPointDto).
struct OilaLocationFix {
    let lat: Double
    let lng: Double
    let accuracy: Double?
    let ts: Date
}

/// Snapshot for `POST /device/status` (PostDeviceStatusDto). All fields optional.
struct OilaDeviceStatus {
    let battery: Int?
    let networkType: String?   // "Wifi" | "Mobile"
    let soundMode: String?     // "Normal" | "Silent" | "Vibrate" — not readable on iOS, usually nil
}

/// Resolved lock state from `GET /device/lock/state` (schema untyped in the spec — parsed tolerantly).
struct OilaLockState {
    let isLocked: Bool
    let raw: [String: Any]
}

// MARK: - Service protocol

protocol OilaDeviceServicing {
    func pair(code: String) async throws -> OilaPairResult
    func refreshSession() async throws
    func logout() async throws
    func sendSOS(lat: Double?, lng: Double?, accuracy: Double?, batteryLevel: Double?) async throws
    func fetchActiveTasks() async throws -> [OilaDeviceTask]
    /// Active + recently-completed tasks (for the tasks screen + collected-stars total).
    func fetchTasks() async throws -> [OilaDeviceTask]
    func completeTask(id: String) async throws
    func updateFCMToken(_ token: String) async throws
    func uploadLocationBatch(_ fixes: [OilaLocationFix]) async throws
    func postDeviceStatus(_ status: OilaDeviceStatus) async throws
    func fetchLockState() async throws -> OilaLockState
}

// MARK: - Client

final class OilaDeviceClient: OilaDeviceServicing {
    static let shared = OilaDeviceClient()

    init(
        baseURL: URL = AppConfig.oilaAPIBaseURL,
        session: URLSession = .shared,
        secureTokens: SecureTokenStoring = SecureTokenStore.oila,
        userDefaults: UserDefaults = .standard
    ) {
        self.baseURL = baseURL
        self.session = session
        self.secureTokens = secureTokens
        self.userDefaults = userDefaults
    }

    // MARK: Pairing / session

    func pair(code: String) async throws -> OilaPairResult {
        let dsn = OilaDeviceIdentity.deviceDSN(userDefaults: userDefaults)
        var body: [String: Any] = [
            "code": code,
            "dsn": dsn,
            "deviceModel": OilaDeviceIdentity.deviceModel,
            "platform": OilaDeviceIdentity.platform,
            "appVersion": OilaDeviceIdentity.appVersion,
            "timezone": OilaDeviceIdentity.timezone
        ]
        // Send whatever push token the app currently holds. NOTE: this is the APNs token
        // captured by PushTokenSyncCoordinator (UserDefaults key "PUSH_NOTIFICATION_TOKEN").
        // oila360's fcmToken expects FCM, so this is best-effort until Firebase is wired (gap #3).
        if let pushToken = userDefaults.string(forKey: "PUSH_NOTIFICATION_TOKEN")?.trimmedNonEmpty {
            body["fcmToken"] = pushToken
        }

        let data = try await requestJSON(path: "device/pair", method: .post, body: body, authorized: false)
        guard let tokens = Self.parseTokens(from: data) else {
            throw OilaAPIError(statusCode: 200, message: "Pairing response missing tokens", errorCode: "PAIR_NO_TOKEN", fieldErrors: [])
        }
        persist(tokens)
        return OilaPairResult(tokens: tokens, child: Self.parseChild(from: data), dsn: dsn)
    }

    func refreshSession() async throws {
        guard let refresh = secureTokens.refreshToken()?.trimmedNonEmpty else {
            throw OilaAPIError(statusCode: 401, message: "No refresh token", errorCode: "UNAUTHORIZED", fieldErrors: [])
        }
        let data = try await requestJSON(
            path: "auth/refresh",
            method: .post,
            body: ["refreshToken": refresh],
            authorized: false
        )
        guard let tokens = Self.parseTokens(from: data) else {
            throw OilaAPIError(statusCode: 200, message: "Refresh response missing tokens", errorCode: "REFRESH_NO_TOKEN", fieldErrors: [])
        }
        persist(tokens)
    }

    func logout() async throws {
        defer { secureTokens.clear() }
        guard let refresh = secureTokens.refreshToken()?.trimmedNonEmpty else { return }
        _ = try? await requestJSON(
            path: "auth/logout",
            method: .post,
            body: ["refreshToken": refresh],
            authorized: true
        )
    }

    // MARK: Device surface

    func sendSOS(lat: Double?, lng: Double?, accuracy: Double?, batteryLevel: Double?) async throws {
        var body: [String: Any] = [:]
        if let lat { body["lat"] = lat }
        if let lng { body["lng"] = lng }
        if let accuracy { body["accuracy"] = accuracy }
        if let batteryLevel { body["batteryLevel"] = batteryLevel }
        _ = try await requestJSON(path: "device/sos", method: .post, body: body, authorized: true)
    }

    func fetchActiveTasks() async throws -> [OilaDeviceTask] {
        let data = try await requestJSON(
            path: "device/tasks",
            method: .get,
            query: [URLQueryItem(name: "status", value: "Active")],
            authorized: true
        )
        return Self.parseTasks(from: data)
    }

    func fetchTasks() async throws -> [OilaDeviceTask] {
        // Active + recently completed, so the tasks screen shows both and the
        // collected-stars total can be summed from completed tasks.
        async let active = fetchStatus("Active")
        async let completed = fetchStatus("Completed")
        return (try await active) + (try await completed)
    }

    private func fetchStatus(_ status: String) async throws -> [OilaDeviceTask] {
        let data = try await requestJSON(
            path: "device/tasks",
            method: .get,
            query: [URLQueryItem(name: "status", value: status)],
            authorized: true
        )
        return Self.parseTasks(from: data)
    }

    func completeTask(id: String) async throws {
        _ = try await requestJSON(path: "device/tasks/\(id)/complete", method: .post, authorized: true)
    }

    func updateFCMToken(_ token: String) async throws {
        userDefaults.set(token, forKey: "OILA_FCM_TOKEN")
        _ = try await requestJSON(
            path: "device/fcm-token",
            method: .patch,
            body: ["fcmToken": token],
            authorized: true
        )
    }

    // MARK: Telemetry

    func uploadLocationBatch(_ fixes: [OilaLocationFix]) async throws {
        guard !fixes.isEmpty else { return }
        let items: [[String: Any]] = fixes.map { fix in
            var item: [String: Any] = [
                "lat": fix.lat,
                "lng": fix.lng,
                "ts": Self.isoFormatter.string(from: fix.ts)
            ]
            if let accuracy = fix.accuracy { item["accuracy"] = accuracy }
            return item
        }
        _ = try await requestJSON(path: "device/location/batch", method: .post, body: ["items": items], authorized: true)
    }

    func postDeviceStatus(_ status: OilaDeviceStatus) async throws {
        var body: [String: Any] = [:]
        if let battery = status.battery { body["battery"] = battery }
        if let network = status.networkType { body["networkType"] = network }
        if let sound = status.soundMode { body["soundMode"] = sound }
        guard !body.isEmpty else { return }
        _ = try await requestJSON(path: "device/status", method: .post, body: body, authorized: true)
    }

    func fetchLockState() async throws -> OilaLockState {
        let data = try await requestJSON(path: "device/lock/state", method: .get, authorized: true)
        let object = (data as? [String: Any]) ?? [:]
        // Tolerant: accept common key spellings for the global lock flag.
        let locked = (object["isLocked"] as? Bool)
            ?? (object["locked"] as? Bool)
            ?? (object["globalLock"] as? Bool)
            ?? ((object["state"] as? String)?.lowercased() == "locked")
        return OilaLockState(isLocked: locked, raw: object)
    }

    // MARK: - Core request

    @discardableResult
    private func requestJSON(
        path: String,
        method: HTTPMethod,
        query: [URLQueryItem] = [],
        body: Any? = nil,
        authorized: Bool,
        allowRefresh: Bool = true
    ) async throws -> Any {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw OilaAPIError(statusCode: -1, message: "Invalid URL", errorCode: nil, fieldErrors: [])
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if authorized, let token = secureTokens.accessToken()?.trimmedNonEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OilaAPIError(statusCode: -1, message: "Invalid response", errorCode: nil, fieldErrors: [])
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if (200 ... 299).contains(http.statusCode) {
            let success = (json?["success"] as? Bool) ?? true
            if success {
                return json?["data"] ?? [:]
            }
            throw Self.error(from: json, statusCode: http.statusCode)
        }

        // 401 → refresh once (single-flight: concurrent 401s share one /auth/refresh),
        // then retry the original request with the freshly stored token.
        if http.statusCode == 401, authorized, allowRefresh {
            try await refreshGate.run { [weak self] in
                guard let self else { return }
                try await self.refreshSession()
            }
            return try await requestJSON(
                path: path, method: method, query: query, body: body,
                authorized: authorized, allowRefresh: false
            )
        }

        throw Self.error(from: json, statusCode: http.statusCode)
    }

    // MARK: - Parsing helpers

    private func persist(_ tokens: OilaTokens) {
        secureTokens.setAccessToken(tokens.accessToken)
        if let refresh = tokens.refreshToken {
            secureTokens.setRefreshToken(refresh)
        }
    }

    private static func error(from json: [String: Any]?, statusCode: Int) -> OilaAPIError {
        let message = (json?["message"] as? String)?.trimmedNonEmpty ?? "Request failed (\(statusCode))"
        let code = (json?["errorCode"] as? String)?.trimmedNonEmpty
        var fields: [String] = []
        if let errors = json?["errors"] as? [[String: Any]] {
            fields = errors.compactMap { ($0["message"] as? String)?.trimmedNonEmpty }
        }
        return OilaAPIError(statusCode: statusCode, message: message, errorCode: code, fieldErrors: fields)
    }

    private static func dict(from data: Any) -> [String: Any]? {
        data as? [String: Any]
    }

    private static func firstString(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = (dict[key] as? String)?.trimmedNonEmpty { return value }
        }
        return nil
    }

    static func parseTokens(from data: Any) -> OilaTokens? {
        guard let object = dict(from: data) else { return nil }
        // tokens may sit at the top of `data` or nested under `tokens`/`session`.
        let source = (object["tokens"] as? [String: Any])
            ?? (object["session"] as? [String: Any])
            ?? object
        guard let access = firstString(source, ["accessToken", "access_token", "token", "jwt"]) else {
            return nil
        }
        let refresh = firstString(source, ["refreshToken", "refresh_token", "refresh"])
        return OilaTokens(accessToken: access, refreshToken: refresh)
    }

    static func parseChild(from data: Any) -> OilaChildProfile? {
        guard let object = dict(from: data) else { return nil }
        let source = (object["child"] as? [String: Any]) ?? object
        let id = firstString(source, ["id", "childId", "_id"])
        let name = firstString(source, ["name", "childName", "displayName", "fullName"])
        let avatar = firstString(source, ["avatarUrl", "avatarURL", "avatar", "photoUrl"])
        if id == nil && name == nil && avatar == nil { return nil }
        return OilaChildProfile(id: id, name: name, avatarURL: avatar)
    }

    static func parseTasks(from data: Any) -> [OilaDeviceTask] {
        let rawItems: [[String: Any]]
        if let array = data as? [[String: Any]] {
            rawItems = array
        } else if let object = data as? [String: Any] {
            let candidate = (object["items"] as? [[String: Any]])
                ?? (object["tasks"] as? [[String: Any]])
                ?? (object["results"] as? [[String: Any]])
                ?? (object["data"] as? [[String: Any]])
            rawItems = candidate ?? []
        } else {
            rawItems = []
        }

        return rawItems.compactMap { item in
            guard let id = firstString(item, ["id", "taskId", "_id"]) else { return nil }
            let title = firstString(item, ["title", "name", "text"]) ?? ""
            let status = firstString(item, ["status", "state"]) ?? "Active"
            let points = intValue(item, ["rewardPoints", "points", "reward", "stars", "coins"]) ?? 0
            return OilaDeviceTask(
                id: id,
                title: title,
                status: status,
                rewardPoints: points,
                emoji: firstString(item, ["emoji", "icon"]),
                dueAt: date(item, ["dueAt", "due_at", "createdAt", "created_at", "assignedAt"]),
                completedAt: date(item, ["completedAt", "completed_at", "finishedAt"])
            )
        }
    }

    private static func intValue(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let intValue = dict[key] as? Int { return intValue }
            if let doubleValue = dict[key] as? Double { return Int(doubleValue) }
            if let stringValue = dict[key] as? String, let parsed = Int(stringValue) { return parsed }
        }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ dict: [String: Any], _ keys: [String]) -> Date? {
        for key in keys {
            if let raw = (dict[key] as? String)?.trimmedNonEmpty {
                if let parsed = isoFormatter.date(from: raw) { return parsed }
                let plain = ISO8601DateFormatter()
                if let parsed = plain.date(from: raw) { return parsed }
            }
        }
        return nil
    }

    private let baseURL: URL
    private let session: URLSession
    private let secureTokens: SecureTokenStoring
    private let userDefaults: UserDefaults
    private let refreshGate = OilaRefreshGate()
}

/// Coalesces concurrent token refreshes: every 401 handler awaits the same in-flight
/// `/auth/refresh` instead of racing the rotation with a shared refresh token.
private actor OilaRefreshGate {
    private var task: Task<Void, Error>?

    func run(_ operation: @escaping () async throws -> Void) async throws {
        if let task {
            try await task.value
            return
        }
        let refreshTask = Task { try await operation() }
        task = refreshTask
        defer { task = nil }
        try await refreshTask.value
    }
}

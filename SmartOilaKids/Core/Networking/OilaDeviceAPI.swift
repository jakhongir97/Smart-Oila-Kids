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

    /// Clears the persisted device DSN so the next `deviceDSN(...)` call mints a fresh one.
    /// Called on disconnect: because every DSN-scoped local store keys off this value, minting a
    /// new DSN means re-pairing the device to a DIFFERENT child starts from an empty scope and
    /// cannot inherit the previous child's cached location/tasks/etc.
    static func resetDSN(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: dsnKey)
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
    /// Emoji the parent picked for the child (PairResult `child.avatarEmoji`, may be null).
    let avatarEmoji: String?
    /// Hex profile color the parent picked (PairResult `child.profileColor`, e.g. "#F0605A").
    let profileColor: String?
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

/// Result of a successful phone OTP verification (`POST /auth/otp/verify`).
struct OilaOtpResult {
    let tokens: OilaTokens
    let child: OilaChildProfile?
}

/// A Telegram magic-link login session started by `POST /auth/telegram/init`.
struct OilaTelegramSession {
    let sessionId: String
    /// Deep link / URL that opens the Telegram bot, when the backend returns one.
    let url: String?
}

/// Poll result for `GET /auth/telegram/status/{sessionId}`.
enum OilaTelegramStatus {
    case pending
    case authorized(OilaTokens, child: OilaChildProfile?)
    case expired
}

// MARK: - Device files

/// Visibility for a device-storage file (`POST /device/files` `visibility`, `GET` list filter).
enum OilaFileVisibility: String {
    case privateVisibility = "Private"
    case publicVisibility = "Public"
}

/// Metadata for a file in the device storage backend (`GET /device/files`,
/// `GET /device/files/{id}`). Parsed tolerantly — the file schema is only loosely
/// documented, so unknown keys are preserved in `raw`.
struct OilaDeviceFile {
    let id: String
    let name: String?
    let visibility: String?
    let sizeBytes: Int?
    let mimeType: String?
    /// A freshly-signed download URL (present on the single-file GET; may be nil in list rows).
    let downloadURL: String?
    let createdAt: Date?
    /// The full tolerant object, for callers needing keys not surfaced above.
    let raw: [String: Any]
}

// MARK: - Service protocol

protocol OilaDeviceServicing {
    func pair(code: String) async throws -> OilaPairResult
    func refreshSession() async throws
    func logout() async throws
    /// Request a one-time phone login code (`POST /auth/otp/request`).
    func requestOtp(phone: String) async throws
    /// Verify a phone login code and persist the issued session (`POST /auth/otp/verify`).
    func verifyOtp(phone: String, code: String) async throws -> OilaOtpResult
    /// Start a Telegram magic-link login session (`POST /auth/telegram/init`).
    func telegramInit() async throws -> OilaTelegramSession
    /// Poll a Telegram login session; persists tokens once authorized (`GET /auth/telegram/status/{id}`).
    func telegramStatus(sessionId: String) async throws -> OilaTelegramStatus
    func sendSOS(lat: Double?, lng: Double?, accuracy: Double?, batteryLevel: Double?) async throws
    func fetchActiveTasks() async throws -> [OilaDeviceTask]
    /// Active + recently-completed tasks (for the tasks screen + collected-stars total).
    func fetchTasks() async throws -> [OilaDeviceTask]
    func completeTask(id: String) async throws
    func updateFCMToken(_ token: String) async throws
    func uploadLocationBatch(_ fixes: [OilaLocationFix]) async throws
    func postDeviceStatus(_ status: OilaDeviceStatus) async throws
    func fetchLockState() async throws -> OilaLockState
    /// Report an app removal/tamper attempt (`POST /device/apps/removal-attempt`).
    func reportRemovalAttempt(packageName: String, applicationName: String) async throws
    /// Upload a finished recording clip (`PUT /device/recordings/{id}/complete`, multipart).
    /// Returns the tolerant unwrapped `data` object (response shape is undocumented).
    func completeRecording(recordingID: String, fileURL: URL, durationSeconds: Int?) async throws -> [String: Any]
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
        // `dsn` is a persisted per-install UUID. iOS/Android 10+ can't read a real hardware
        // serial, so the backend is dropping `dsn` from the pair contract; until then it only
        // validates a non-empty string, and the agreed interim is "send a random value". The
        // server's own device id comes back as `deviceId` in the response.
        let dsn = OilaDeviceIdentity.deviceDSN(userDefaults: userDefaults)
        var body: [String: Any] = [
            "code": code,
            "dsn": dsn,
            "deviceModel": OilaDeviceIdentity.deviceModel,
            "platform": OilaDeviceIdentity.platform,
            "appVersion": OilaDeviceIdentity.appVersion,
            "timezone": OilaDeviceIdentity.timezone
        ]
        // TODO(firebase): this is an APNs device token standing in for an FCM token. The
        // Firebase SDK is not yet integrated (blocked on team config `uz.oila360.child`), so we
        // forward whatever push token PushTokenSyncCoordinator captured (UserDefaults key
        // "PUSH_NOTIFICATION_TOKEN") in the `fcmToken` field. Best-effort: if no token is held
        // yet, the key is simply omitted and pairing still succeeds. Swap for the real FCM
        // registration token once the Firebase SDK lands.
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

    // MARK: Phone / Telegram login (public — no session required)

    func requestOtp(phone: String) async throws {
        _ = try await requestJSON(
            path: "auth/otp/request",
            method: .post,
            body: ["phone": phone],
            authorized: false
        )
    }

    func verifyOtp(phone: String, code: String) async throws -> OilaOtpResult {
        let data = try await requestJSON(
            path: "auth/otp/verify",
            method: .post,
            body: ["phone": phone, "code": code],
            authorized: false
        )
        guard let tokens = Self.parseTokens(from: data) else {
            throw OilaAPIError(
                statusCode: 200,
                message: "Verification response missing tokens",
                errorCode: "OTP_NO_TOKEN",
                fieldErrors: []
            )
        }
        persist(tokens)
        return OilaOtpResult(tokens: tokens, child: Self.parseChild(from: data))
    }

    func telegramInit() async throws -> OilaTelegramSession {
        let data = try await requestJSON(path: "auth/telegram/init", method: .post, authorized: false)
        let object = (data as? [String: Any]) ?? [:]
        guard let sessionId = Self.firstString(object, ["sessionId", "session_id", "id"]) else {
            throw OilaAPIError(
                statusCode: 200,
                message: "Telegram init response missing sessionId",
                errorCode: "TG_NO_SESSION",
                fieldErrors: []
            )
        }
        let url = Self.firstString(object, ["url", "link", "deepLink", "magicLink", "tgUrl", "botUrl"])
        return OilaTelegramSession(sessionId: sessionId, url: url)
    }

    func telegramStatus(sessionId: String) async throws -> OilaTelegramStatus {
        let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        let data = try await requestJSON(path: "auth/telegram/status/\(encoded)", method: .get, authorized: false)
        if let tokens = Self.parseTokens(from: data) {
            persist(tokens)
            return .authorized(tokens, child: Self.parseChild(from: data))
        }
        let object = (data as? [String: Any]) ?? [:]
        let status = (Self.firstString(object, ["status", "state"]) ?? "pending").lowercased()
        switch status {
        case "expired", "cancelled", "canceled", "failed", "rejected", "timeout":
            return .expired
        default:
            return .pending
        }
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
        try await fetchStatus("Active")
    }

    func fetchTasks() async throws -> [OilaDeviceTask] {
        // Active + recently completed, so the tasks screen shows both and the
        // collected-stars total can be summed from completed tasks.
        async let active = fetchStatus("Active")
        async let completed = fetchStatus("Completed")
        return (try await active) + (try await completed)
    }

    /// `GET /device/tasks` pagination: the spec marks `page`/`limit`/`sortOrder` as REQUIRED
    /// (limit max 100), so every request sends them. Pages are walked until a short page
    /// signals the end, hard-capped so a misbehaving backend can't loop us forever.
    static let tasksPageLimit = 100
    static let tasksMaxPages = 10

    private func fetchStatus(_ status: String) async throws -> [OilaDeviceTask] {
        var tasks: [OilaDeviceTask] = []
        for page in 1 ... Self.tasksMaxPages {
            let data = try await requestJSON(
                path: "device/tasks",
                method: .get,
                query: [
                    URLQueryItem(name: "page", value: "\(page)"),
                    URLQueryItem(name: "limit", value: "\(Self.tasksPageLimit)"),
                    URLQueryItem(name: "sortOrder", value: "desc"),
                    URLQueryItem(name: "status", value: status)
                ],
                authorized: true
            )
            let pageTasks = Self.parseTasks(from: data)
            tasks += pageTasks
            // A short (or empty) page means we've drained the collection.
            if pageTasks.count < Self.tasksPageLimit { break }
        }
        return tasks
    }

    func completeTask(id: String) async throws {
        _ = try await requestJSON(path: "device/tasks/\(id)/complete", method: .post, authorized: true)
    }

    func updateFCMToken(_ token: String) async throws {
        userDefaults.set(token, forKey: "OILA_FCM_TOKEN")
        // TODO(firebase): `token` here is an APNs device token (hex), not a Firebase FCM
        // registration token — the Firebase SDK is not yet integrated (blocked on team config
        // `uz.oila360.child`). We send it in `fcmToken` so the backend has *some* push address
        // to reach this device; replace with the real FCM token once Firebase is wired.
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

    func reportRemovalAttempt(packageName: String, applicationName: String) async throws {
        _ = try await requestJSON(
            path: "device/apps/removal-attempt",
            method: .post,
            body: ["packageName": packageName, "applicationName": applicationName],
            authorized: true
        )
    }

    func completeRecording(recordingID: String, fileURL: URL, durationSeconds: Int?) async throws -> [String: Any] {
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyData = try Self.multipartBody(
            fileURL: fileURL,
            durationSeconds: durationSeconds,
            boundary: boundary
        )
        let encodedID = recordingID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? recordingID
        let data = try await send(
            path: "device/recordings/\(encodedID)/complete",
            method: .put,
            bodyData: bodyData,
            contentType: "multipart/form-data; boundary=\(boundary)",
            authorized: true
        )
        return (data as? [String: Any]) ?? [:]
    }

    private static func multipartBody(fileURL: URL, durationSeconds: Int?, boundary: String) throws -> Data {
        let fileData = try Data(contentsOf: fileURL)
        let lineBreak = "\r\n"
        var body = Data()

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\(lineBreak)"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(mimeType(for: fileURL))\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(fileData)
        body.append(lineBreak.data(using: .utf8)!)

        if let durationSeconds {
            body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"durationSeconds\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            body.append("\(durationSeconds)\(lineBreak)".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
    }

    private static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "m4a":
            return "audio/mp4"
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        default:
            return "application/octet-stream"
        }
    }

    // MARK: Device files (storage backend for device-uploaded media)

    /// Upload a file to the device storage backend (`POST /device/files`, multipart).
    /// `file` is the binary part; `visibility` (Private|Public) is an optional text field.
    /// Returns the tolerant unwrapped `data` object (the created file's metadata).
    @discardableResult
    func uploadFile(fileURL: URL, visibility: OilaFileVisibility? = nil) async throws -> [String: Any] {
        let boundary = "Boundary-\(UUID().uuidString)"
        var textFields: [(name: String, value: String)] = []
        if let visibility {
            textFields.append((name: "visibility", value: visibility.rawValue))
        }
        let bodyData = try Self.multipartFileBody(
            fileURL: fileURL,
            textFields: textFields,
            boundary: boundary
        )
        let data = try await send(
            path: "device/files",
            method: .post,
            bodyData: bodyData,
            contentType: "multipart/form-data; boundary=\(boundary)",
            authorized: true
        )
        return (data as? [String: Any]) ?? [:]
    }

    /// List device files (`GET /device/files`). `page`, `limit`, `sortOrder` are REQUIRED by the
    /// spec (limit max 100); `visibility`/`sortBy` are optional filters.
    func fetchFiles(
        visibility: OilaFileVisibility? = nil,
        page: Int = 1,
        limit: Int = 50,
        sortBy: String? = nil,
        sortOrder: String = "desc"
    ) async throws -> [OilaDeviceFile] {
        var query = [
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sortOrder", value: sortOrder)
        ]
        if let visibility {
            query.append(URLQueryItem(name: "visibility", value: visibility.rawValue))
        }
        if let sortBy {
            query.append(URLQueryItem(name: "sortBy", value: sortBy))
        }
        let data = try await requestJSON(path: "device/files", method: .get, query: query, authorized: true)
        return Self.parseFiles(from: data)
    }

    /// Fetch one file's metadata + a fresh signed download URL (`GET /device/files/{id}`).
    func fetchFile(id: String) async throws -> OilaDeviceFile {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let data = try await requestJSON(path: "device/files/\(encodedID)", method: .get, authorized: true)
        let object = (data as? [String: Any]) ?? [:]
        return Self.parseFile(object)
            ?? OilaDeviceFile(
                id: id, name: nil, visibility: nil, sizeBytes: nil,
                mimeType: nil, downloadURL: nil, createdAt: nil, raw: object
            )
    }

    /// Delete a file (`DELETE /device/files/{id}`).
    func deleteFile(id: String) async throws {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await requestJSON(path: "device/files/\(encodedID)", method: .delete, authorized: true)
    }

    /// Multipart builder for `POST /device/files`: one binary `file` part plus arbitrary text
    /// fields (e.g. `visibility`). Generalizes `multipartBody` over its text fields.
    private static func multipartFileBody(
        fileURL: URL,
        textFields: [(name: String, value: String)],
        boundary: String
    ) throws -> Data {
        let fileData = try Data(contentsOf: fileURL)
        let lineBreak = "\r\n"
        var body = Data()

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\(lineBreak)"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(mimeType(for: fileURL))\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(fileData)
        body.append(lineBreak.data(using: .utf8)!)

        for field in textFields {
            body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(field.name)\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            body.append("\(field.value)\(lineBreak)".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
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
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await send(
            path: path,
            method: method,
            query: query,
            bodyData: bodyData,
            contentType: body == nil ? nil : "application/json",
            authorized: authorized,
            allowRefresh: allowRefresh
        )
    }

    /// Body-agnostic transport shared by the JSON helpers and the multipart upload:
    /// applies the `{ success, data }` envelope, device Bearer, and single-flight 401 refresh.
    @discardableResult
    private func send(
        path: String,
        method: HTTPMethod,
        query: [URLQueryItem] = [],
        bodyData: Data?,
        contentType: String?,
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
        if let bodyData {
            request.httpBody = bodyData
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
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
            return try await send(
                path: path, method: method, query: query,
                bodyData: bodyData, contentType: contentType,
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
        // `POST /device/pair` returns the child device's long-lived credential as
        // `deviceToken` (per the backend's PairResult contract) — check it FIRST. The
        // `access*`/`token`/`jwt` spellings are kept for the parent OTP/Telegram flows,
        // which do return an access + refresh pair.
        guard let access = firstString(source, ["deviceToken", "device_token", "accessToken", "access_token", "token", "jwt"]) else {
            return nil
        }
        // A paired device gets a single long-lived token (no refresh). The OTP/Telegram
        // logins still return a refresh token, so keep reading it when present.
        let refresh = firstString(source, ["refreshToken", "refresh_token", "refresh"])
        return OilaTokens(accessToken: access, refreshToken: refresh)
    }

    static func parseChild(from data: Any) -> OilaChildProfile? {
        guard let object = dict(from: data) else { return nil }
        let source = (object["child"] as? [String: Any]) ?? object
        let id = firstString(source, ["id", "childId", "_id"])
        let name = firstString(source, ["name", "childName", "displayName", "fullName"])
        // PairResult uses `profilePictureUrl`; keep the older spellings for other endpoints.
        let avatar = firstString(source, ["profilePictureUrl", "profilePicture", "avatarUrl", "avatarURL", "avatar", "photoUrl"])
        let emoji = firstString(source, ["avatarEmoji", "emoji", "avatar_emoji"])
        let color = firstString(source, ["profileColor", "color", "profile_color"])
        if id == nil && name == nil && avatar == nil && emoji == nil && color == nil { return nil }
        return OilaChildProfile(id: id, name: name, avatarURL: avatar, avatarEmoji: emoji, profileColor: color)
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

    static func parseFiles(from data: Any) -> [OilaDeviceFile] {
        let rawItems: [[String: Any]]
        if let array = data as? [[String: Any]] {
            rawItems = array
        } else if let object = data as? [String: Any] {
            rawItems = (object["items"] as? [[String: Any]])
                ?? (object["files"] as? [[String: Any]])
                ?? (object["results"] as? [[String: Any]])
                ?? (object["data"] as? [[String: Any]])
                ?? []
        } else {
            rawItems = []
        }
        return rawItems.compactMap { parseFile($0) }
    }

    static func parseFile(_ item: [String: Any]) -> OilaDeviceFile? {
        guard let id = firstString(item, ["id", "fileId", "_id"]) else { return nil }
        return OilaDeviceFile(
            id: id,
            name: firstString(item, ["name", "fileName", "filename", "originalName", "title"]),
            visibility: firstString(item, ["visibility", "access"]),
            sizeBytes: intValue(item, ["size", "sizeBytes", "bytes", "fileSize"]),
            mimeType: firstString(item, ["mimeType", "mime", "contentType", "type"]),
            downloadURL: firstString(item, ["downloadUrl", "downloadURL", "url", "signedUrl", "link"]),
            createdAt: date(item, ["createdAt", "created_at", "uploadedAt"]),
            raw: item
        )
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

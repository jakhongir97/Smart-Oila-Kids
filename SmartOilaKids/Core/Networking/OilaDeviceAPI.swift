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

    /// Raised when this device holds no readable credential — an empty Keychain, or a read that
    /// failed for a reason that is NOT "the item is absent" (notably errSecInteractionNotAllowed
    /// before first unlock). Deliberately excluded from `requiresRePair`: see below.
    static let noCredentialCode = "NO_LOCAL_CREDENTIAL"

    /// The device credential is no longer valid server-side — the caller should force re-pairing.
    ///
    /// `NO_LOCAL_CREDENTIAL` is excluded on purpose. Requests used to be sent WITHOUT an
    /// Authorization header whenever the Keychain read returned nil, so the server answered 401 and
    /// "we cannot read our own token" became indistinguishable from "the parent unpaired this
    /// device". The confirmation probe then re-read the same unreadable Keychain, got the same 401,
    /// and self-confirmed the revocation -- destroying a perfectly valid pairing.
    var requiresRePair: Bool {
        guard errorCode != Self.noCredentialCode else { return false }
        return errorCode == "REFRESH_INVALID" || errorCode == "UNAUTHORIZED" || statusCode == 401
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

    /// The DSN this install ALREADY has, without minting one. Read-only callers — deciding whether
    /// an incoming push is addressed to this device, for instance — must use this rather than
    /// `deviceDSN`, which persists a fresh UUID as a side effect and would quietly hand an
    /// unpaired install an identity just by asking the question.
    static func persistedDSN(userDefaults: UserDefaults = .standard) -> String? {
        userDefaults.string(forKey: dsnKey)?.trimmedNonEmpty
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
struct OilaLocationFix: Codable, Equatable {
    let lat: Double
    let lng: Double
    let accuracy: Double?
    let ts: Date
}

/// Snapshot for `POST /device/status` (PostDeviceStatusDto). All fields optional.
struct OilaDeviceStatus {
    let battery: Int?
    let networkType: String?   // "Wifi" | "Mobile"
    /// "Normal" | "Silent" | "Vibrate" — always nil on iOS, by decision.
    ///
    /// iOS exposes no public API for the ring/silent switch. The Android child app fills this in
    /// because Android does expose it. The only way to read it here is a private Darwin
    /// notification (`com.apple.springboard.ringerstate`), which is grounds for App Store rejection
    /// on an app already under extra scrutiny — so this field stays empty rather than being faked.
    /// A nil field is dropped from the request body and the backend accepts its absence.
    let soundMode: String?
}

/// One row of `appLimits[]` in `GET /device/lock/state`: the parent's per-app daily budget plus
/// today's spend for a single package. Parsed tolerantly (the endpoint's 2xx schema is `{}` in the
/// spec), so the numbers are read through the shared `intValue` helper and may arrive as Int,
/// Double or String.
///
/// iOS cannot ENFORCE these — per-app blocking needs the FamilyControls entitlement Apple has not
/// granted this app — so the rows are informational: they tell the child which apps the parent
/// limited and how much time is left today.
struct OilaAppLimit: Identifiable, Equatable {
    /// Package name / bundle id the limit applies to, e.g. `org.telegram.messenger`.
    let packageName: String
    /// The local day the usage figures belong to, exactly as the backend formatted it
    /// (e.g. `"2026-07-22"`). Kept as a string: it is a display value, not a timestamp to parse.
    let usageDate: String?
    let usedSeconds: Int
    /// nil when the payload carried no budget for this row (a usage-only stat).
    let dailyLimitSeconds: Int?
    /// nil when the payload carried no remaining figure; callers may derive `dailyLimit - used`.
    let remainingSeconds: Int?
    let isLimitReached: Bool

    /// `packageName` is unique per row in the lock-state payload, so it doubles as the list id.
    var id: String { packageName }
}

/// Resolved lock state from `GET /device/lock/state` (schema untyped in the spec — parsed tolerantly).
///
/// The live payload carries two independent halves and both are preserved here: the WHOLE-DEVICE
/// lock (`isLocked`, plus the `manualLockEnabled` / `scheduleLocked` reasons behind it) and the
/// PER-APP half (`lockedPackages`, `appLimits`). Only the whole-device half is safety-critical —
/// the per-app half is informational on iOS, which cannot enforce it without FamilyControls.
struct OilaLockState {
    /// nil = the 200 response shape was not recognized (no known lock key, no nested `global`
    /// object). Callers MUST treat nil as "unknown" and keep the last-known lock — never as
    /// "unlocked" — so an unexpected shape can never silently release an active parental lock.
    let isLocked: Bool?
    /// The parent's manual (always-on) lock switch, when the payload reports it; nil when absent.
    let manualLockEnabled: Bool?
    /// True while a lock SCHEDULE window is currently in force, when the payload reports it.
    let scheduleLocked: Bool?
    /// The device-local wall clock the backend evaluated the schedules against, e.g. `"15:45"`.
    /// Kept as the backend's own string — it is a display value, not a timestamp to parse.
    let deviceLocalTime: String?
    /// Packages the parent blocked outright (`lockedPackages`). Display-only on iOS.
    let lockedPackages: [String]
    /// Per-app daily budgets + today's spend (`appLimits`). Display-only on iOS.
    let appLimits: [OilaAppLimit]
    /// PROVISIONAL, UNTYPED: the only live sample had `activeSchedule: null` and `schedules: []`,
    /// so the schedule object's real field names are unknown. Rather than invent a schema we keep
    /// the raw JSON and read it best-effort through `resolvedScheduleRange()`.
    let activeScheduleRaw: [String: Any]?
    /// PROVISIONAL, UNTYPED — see `activeScheduleRaw`.
    let schedulesRaw: [[String: Any]]
    /// The full tolerant `data` object, for callers needing keys not surfaced above.
    let raw: [String: Any]

    /// Everything but `isLocked` / `raw` defaults, so the original `OilaLockState(isLocked:raw:)`
    /// call sites (and test doubles) keep compiling unchanged.
    init(
        isLocked: Bool?,
        raw: [String: Any],
        manualLockEnabled: Bool? = nil,
        scheduleLocked: Bool? = nil,
        deviceLocalTime: String? = nil,
        lockedPackages: [String] = [],
        appLimits: [OilaAppLimit] = [],
        activeScheduleRaw: [String: Any]? = nil,
        schedulesRaw: [[String: Any]] = []
    ) {
        self.isLocked = isLocked
        self.raw = raw
        self.manualLockEnabled = manualLockEnabled
        self.scheduleLocked = scheduleLocked
        self.deviceLocalTime = deviceLocalTime
        self.lockedPackages = lockedPackages
        self.appLimits = appLimits
        self.activeScheduleRaw = activeScheduleRaw
        self.schedulesRaw = schedulesRaw
    }

    /// The whole-device lock, resolved.
    ///
    /// `isLocked` stays AUTHORITATIVE — the backend owner confirmed it already means "the whole
    /// phone", i.e. the server has folded the manual switch and the schedule window into it — so
    /// whenever it is present it is returned untouched. The OR with `scheduleLocked` /
    /// `manualLockEnabled` therefore only fires when the primary flag is MISSING entirely, and it
    /// can only ever turn "unknown" into LOCKED, never into unlocked. That keeps the fail-closed
    /// contract of `isLocked` intact: nil still means "unrecognized shape, keep the last-known
    /// lock", and no payload can release an active lock through this property.
    var isDeviceLocked: Bool? {
        if let isLocked = isLocked { return isLocked }
        // When the primary flag is missing, the reason flags stand in for it — but they must be
        // able to report UNLOCKED too. Returning only true-or-nil made this a one-way latch: a
        // payload carrying `scheduleLocked: false` with no `isLocked` resolved to nil, which the
        // caller correctly reads as "keep the last-known lock", so a lock could never be released
        // through this path. Derive from the reasons whenever ANY of them is present, and fall
        // through to nil only when the shape is genuinely unrecognized.
        if scheduleLocked != nil || manualLockEnabled != nil {
            return (scheduleLocked ?? false) || (manualLockEnabled ?? false)
        }
        return nil
    }

    /// PROVISIONAL best-effort read of the active lock window's start/end times.
    ///
    /// The schedule object's real field names are UNKNOWN (the only live sample had
    /// `activeSchedule: null` and `schedules: []`), so this walks the plausible spellings —
    /// on the object itself and inside a nested window/range object — and returns nil the moment
    /// nothing matches. Callers must read nil as "no window to display", never as "no schedule
    /// exists". Replace with a typed parse once the backend sends a non-null sample.
    func resolvedScheduleRange() -> (start: String, end: String)? {
        var candidates: [[String: Any]] = []
        if let activeScheduleRaw = activeScheduleRaw { candidates.append(activeScheduleRaw) }
        candidates += schedulesRaw
        for candidate in candidates {
            // The times may sit on the schedule object itself or inside a nested window/range.
            var scopes: [[String: Any]] = [candidate]
            for key in Self.scheduleNestingKeys {
                if let nested = candidate[key] as? [String: Any] { scopes.append(nested) }
            }
            for scope in scopes {
                guard let start = Self.timeString(scope, Self.scheduleStartKeys),
                      let end = Self.timeString(scope, Self.scheduleEndKeys) else { continue }
                return (start, end)
            }
        }
        return nil
    }

    /// `resolvedScheduleRange()` rendered for display, e.g. `"21:00 – 07:00"`; nil when the shape
    /// isn't recognized. Deliberately unlocalized — it is only the two backend-formatted times.
    var scheduleRangeText: String? {
        guard let range = resolvedScheduleRange() else { return nil }
        return "\(range.start) – \(range.end)"
    }

    private static let scheduleNestingKeys = ["schedule", "window", "timeRange", "range", "time", "activeWindow"]
    private static let scheduleStartKeys = [
        "startTime", "start", "startAt", "start_time", "from", "fromTime", "beginTime", "lockStart"
    ]
    private static let scheduleEndKeys = [
        "endTime", "end", "endAt", "end_time", "to", "toTime", "finishTime", "lockEnd"
    ]

    private static func timeString(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = (dict[key] as? String)?.trimmedNonEmpty { return value }
        }
        return nil
    }
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
    func sendSOS(lat: Double?, lng: Double?, accuracy: Double?, batteryLevel: Double?) async throws
    func fetchActiveTasks() async throws -> [OilaDeviceTask]
    /// Active + recently-completed tasks (for the tasks screen + collected-stars total).
    func fetchTasks() async throws -> [OilaDeviceTask]
    func completeTask(id: String) async throws
    func updateFCMToken(_ token: String) async throws
    func uploadLocationBatch(_ fixes: [OilaLocationFix]) async throws
    func postDeviceStatus(_ status: OilaDeviceStatus) async throws
    /// Report app-usage deltas (`POST /device/apps/usage`); the response is the enforcement
    /// state (locked packages + per-app limit/remaining) that drives on-device app-limit locking.
    func reportAppUsage(items: [DeviceApplicationUsageReportItemRequest]) async throws -> DeviceApplicationUsageReportResponse
    func fetchLockState() async throws -> OilaLockState
    /// Report an app removal/tamper attempt (`POST /device/apps/removal-attempt`).
    func reportRemovalAttempt(packageName: String, applicationName: String) async throws
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
        // Prefer the real Firebase FCM registration token (`OILA_FCM_TOKEN`, populated by
        // FCMPushRegistrar once the Firebase SDK + GoogleService-Info.plist ship). Fall back to the
        // raw APNs token only as a stopgap before Firebase lands — the backend is FCM-only, so the
        // fallback cannot actually receive pushes, but it keeps the push address non-empty. If no
        // token is held yet the key is omitted and pairing still succeeds.
        // FCM registration token ONLY. The raw APNs token used to be sent as a fallback, which put
        // an undeliverable address in the backend's `fcmToken` field and made the device look
        // push-addressable when nothing could ever reach it. The field is optional at pairing, so
        // omitting it is both legal and honest.
        let pushToken = userDefaults.string(forKey: FCMPushRegistrar.fcmTokenDefaultsKey)?.trimmedNonEmpty
        if let pushToken {
            body["fcmToken"] = pushToken
        }

        let data = try await requestJSON(path: "device/pair", method: .post, body: body, authorized: false)
        guard let tokens = Self.parseTokens(from: data) else {
            throw OilaAPIError(statusCode: 200, message: "Pairing response missing tokens", errorCode: "PAIR_NO_TOKEN", fieldErrors: [])
        }
        try persist(tokens)
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
        try persist(tokens)
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
        // Do NOT write OILA_FCM_TOKEN here — that slot is owned by FCMPushRegistrar and holds ONLY
        // the real Firebase registration token (which pair() prefers). This method may be handed the
        // raw APNs stopgap before Firebase is live; persisting that here poisoned the slot so pairing
        // sent an undeliverable push address. This call just registers whatever token it's given.
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
        // Send even when every field is nil. The backend derives "device offline" from how long it
        // has been since it last heard from this device, so the REQUEST ITSELF is the liveness
        // signal and an empty `{}` is explicitly valid (every field in PostDeviceStatusDto is
        // optional). Skipping the call on an empty body — which is what this did — makes a healthy
        // device go silent and then show up as offline in the parent app.
        _ = try await requestJSON(path: "device/status", method: .post, body: body, authorized: true)
    }

    func reportAppUsage(items: [DeviceApplicationUsageReportItemRequest]) async throws -> DeviceApplicationUsageReportResponse {
        let payload: [[String: Any]] = items.map { ["packageName": $0.packageName, "usedSeconds": $0.usedSeconds] }
        let data = try await requestJSON(path: "device/apps/usage", method: .post, body: ["items": payload], authorized: true)
        let object = (data as? [String: Any]) ?? [:]
        let jsonData = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(DeviceApplicationUsageReportResponse.self, from: jsonData)
    }

    func fetchLockState() async throws -> OilaLockState {
        let data = try await requestJSON(path: "device/lock/state", method: .get, authorized: true)
        let object = (data as? [String: Any]) ?? [:]
        return Self.parseLockState(from: object)
    }

    /// Tolerant whole-payload read for `GET /device/lock/state`. The live response carries
    /// `isLocked` / `manualLockEnabled` / `scheduleLocked` / `deviceLocalTime` / `lockedPackages` /
    /// `appLimits` / `activeSchedule` / `schedules`, but the spec types the 2xx body as `{}` — so
    /// each field is looked up under several plausible spellings and a key we don't recognize
    /// degrades to nil/empty instead of failing the whole parse. One surprising key must never
    /// cost us the rest of the state.
    static func parseLockState(from object: [String: Any]) -> OilaLockState {
        OilaLockState(
            isLocked: parseGlobalLock(from: object),
            raw: object,
            manualLockEnabled: boolValue(object, ["manualLockEnabled", "manualLock", "manual_lock_enabled"]),
            scheduleLocked: boolValue(object, ["scheduleLocked", "isScheduleLocked", "schedule_locked"]),
            deviceLocalTime: firstString(object, ["deviceLocalTime", "device_local_time", "localTime", "deviceTime"]),
            lockedPackages: parseLockedPackages(from: object),
            appLimits: parseAppLimits(from: object),
            activeScheduleRaw: firstDictionary(object, ["activeSchedule", "active_schedule", "currentSchedule"]),
            schedulesRaw: firstArray(object, ["schedules", "lockSchedules", "schedule"]) ?? []
        )
    }

    /// `lockedPackages` may arrive as bare identifier strings (what the live sample sends) or as
    /// objects carrying the identifier under one of the usual package-name spellings.
    static func parseLockedPackages(from object: [String: Any]) -> [String] {
        for key in ["lockedPackages", "locked_packages", "lockedApps", "blockedPackages"] {
            guard let value = object[key] else { continue }
            if let strings = value as? [String] {
                return strings.compactMap { $0.trimmedNonEmpty }
            }
            if let items = value as? [[String: Any]] {
                return items.compactMap { firstString($0, packageNameKeys) }
            }
        }
        return []
    }

    static func parseAppLimits(from object: [String: Any]) -> [OilaAppLimit] {
        guard let rows = firstArray(object, ["appLimits", "app_limits", "applicationLimits", "limits", "stats"]) else {
            return []
        }
        return rows.compactMap { parseAppLimit($0) }
    }

    /// A row without an identifiable package is dropped — there is nothing the UI could attribute
    /// its numbers to. Everything else degrades to a safe default rather than dropping the row.
    static func parseAppLimit(_ item: [String: Any]) -> OilaAppLimit? {
        guard let packageName = firstString(item, packageNameKeys) else { return nil }
        let used = intValue(item, ["usedSeconds", "used_seconds", "usageSeconds", "used"]) ?? 0
        let daily = intValue(item, ["dailyLimitSeconds", "daily_limit_seconds", "limitSeconds", "dailyLimit"])
        let remaining = intValue(item, ["remainingSeconds", "remaining_seconds", "remaining", "leftSeconds"])
        // `isLimitReached` is authoritative when present; otherwise derive it from the numbers so a
        // payload that only reports seconds still drives the right UI. No budget = never "reached".
        let derivedReached: Bool = {
            guard let daily = daily, daily > 0 else { return false }
            return (remaining ?? (daily - used)) <= 0
        }()
        let reached = boolValue(item, ["isLimitReached", "is_limit_reached", "limitReached", "reached"])
            ?? derivedReached
        return OilaAppLimit(
            packageName: packageName,
            usageDate: firstString(item, ["usageDate", "usage_date", "date", "day"]),
            usedSeconds: max(0, used),
            dailyLimitSeconds: daily.map { max(0, $0) },
            remainingSeconds: remaining.map { max(0, $0) },
            isLimitReached: reached
        )
    }

    /// Package-identifier spellings shared by `lockedPackages` objects and `appLimits` rows.
    private static let packageNameKeys = [
        "packageName", "package_name", "package", "packageId", "bundleId", "bundleIdentifier", "appId"
    ]

    /// Tolerant global-lock read for `GET /device/lock/state` (spec response is untyped). Accepts
    /// the flat top-level keys and a nested `global` object, covering `isLocked` / `locked` /
    /// `enabled` / `globalLock` booleans (the sibling SetManualLockDto uses `enabled`) and a
    /// `state` string. Returns nil when NONE are present so the caller fails closed (keeps the
    /// last-known lock) instead of defaulting an unrecognized 200 to unlocked.
    static func parseGlobalLock(from object: [String: Any]) -> Bool? {
        func read(_ dict: [String: Any]) -> Bool? {
            for key in ["isLocked", "locked", "enabled", "globalLock"] {
                if let value = dict[key] as? Bool { return value }
            }
            if let state = (dict["state"] as? String)?.lowercased() {
                if state == "locked" { return true }
                if state == "unlocked" || state == "unlock" { return false }
            }
            return nil
        }
        if let value = read(object) { return value }
        if let global = object["global"] as? [String: Any], let value = read(global) { return value }
        return nil
    }

    func reportRemovalAttempt(packageName: String, applicationName: String) async throws {
        _ = try await requestJSON(
            path: "device/apps/removal-attempt",
            method: .post,
            body: ["packageName": packageName, "applicationName": applicationName],
            authorized: true
        )
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

    private static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
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
        if authorized {
            // Fail fast instead of sending an UNAUTHENTICATED request. There was no `else` here, so
            // an unreadable Keychain silently produced a request with no Authorization header, and
            // the resulting 401 was treated as a revoked pairing.
            guard let token = secureTokens.accessToken()?.trimmedNonEmpty else {
                throw OilaAPIError(
                    statusCode: 401,
                    message: "No device credential available on this device",
                    errorCode: OilaAPIError.noCredentialCode,
                    fieldErrors: []
                )
            }
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

    /// Persist freshly minted tokens, THROWING if the Keychain rejects the write.
    ///
    /// This used the void-returning setters, so a rejected write (e.g. errSecMissingEntitlement on
    /// a mis-signed TestFlight build) was swallowed: `pair()` returned success, `oilaPaired` was set
    /// true, the child walked the whole onboarding, and then every authenticated call failed. The
    /// checked API existed for exactly this and had zero callers anywhere in the repo, tests
    /// included. Pairing is a point where a lost token is unrecoverable, so it must fail loudly.
    private func persist(_ tokens: OilaTokens) throws {
        guard secureTokens.storeAccessToken(tokens.accessToken) else {
            throw OilaAPIError(
                statusCode: -1,
                message: "Could not store the device credential on this device",
                errorCode: "KEYCHAIN_WRITE_FAILED",
                fieldErrors: []
            )
        }
        if let refresh = tokens.refreshToken, !secureTokens.storeRefreshToken(refresh) {
            throw OilaAPIError(
                statusCode: -1,
                message: "Could not store the device credential on this device",
                errorCode: "KEYCHAIN_WRITE_FAILED",
                fieldErrors: []
            )
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

    /// Same tolerance as `intValue`, for flags: a JSON boolean, or a stringified one (some
    /// serializers send `"true"` / `"1"`). Returns nil when no listed key carries a usable value,
    /// so callers can distinguish "absent" from "false".
    private static func boolValue(_ dict: [String: Any], _ keys: [String]) -> Bool? {
        for key in keys {
            if let value = dict[key] as? Bool { return value }
            if let raw = (dict[key] as? String)?.trimmedNonEmpty?.lowercased() {
                if ["true", "1", "yes"].contains(raw) { return true }
                if ["false", "0", "no"].contains(raw) { return false }
            }
        }
        return nil
    }

    private static func firstArray(_ dict: [String: Any], _ keys: [String]) -> [[String: Any]]? {
        for key in keys {
            if let value = dict[key] as? [[String: Any]] { return value }
        }
        return nil
    }

    private static func firstDictionary(_ dict: [String: Any], _ keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] { return value }
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

// MARK: - Chat + live-audio models (Bolajon360 realtime)

/// One message in the parent↔child thread (`GET/POST /device/chat/messages`).
/// The message schema is undocumented in the spec, so every field is parsed tolerantly.
struct OilaChatMessage: Identifiable, Equatable {
    enum Sender: String {
        case parent
        case child
        case system
        case unknown
    }

    let id: String
    let text: String?
    let sender: Sender
    let createdAt: Date?
    /// True when the message carries an image attachment — fetch the signed URL lazily via
    /// `fetchChatAttachmentURL(messageId:)`; never persist a long-lived media URL for a minor.
    let hasImage: Bool
    /// True once the peer (the parent, for a child-sent message) has read it.
    let readByPeer: Bool
    /// The full tolerant object, for callers needing keys not surfaced above.
    let raw: [String: Any]
    /// For a system notice (`sender == .system`) — e.g. `"sos"` — with any structured payload.
    let systemKind: String?
    let systemData: [String: Any]?

    init(id: String, text: String?, sender: Sender, createdAt: Date?, hasImage: Bool,
         readByPeer: Bool, raw: [String: Any], systemKind: String? = nil, systemData: [String: Any]? = nil) {
        self.id = id
        self.text = text
        self.sender = sender
        self.createdAt = createdAt
        self.hasImage = hasImage
        self.readByPeer = readByPeer
        self.raw = raw
        self.systemKind = systemKind
        self.systemData = systemData
    }

    var isFromChild: Bool { sender == .child }

    /// A copy with the peer-read receipt set — used when a `chat:read` WS event arrives so the
    /// child's own sent messages flip to ✓✓ in realtime instead of only on a history refetch.
    func markedReadByPeer() -> OilaChatMessage {
        OilaChatMessage(id: id, text: text, sender: sender, createdAt: createdAt, hasImage: hasImage,
                        readByPeer: true, raw: raw, systemKind: systemKind, systemData: systemData)
    }

    static func == (lhs: OilaChatMessage, rhs: OilaChatMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.sender == rhs.sender
            && lhs.createdAt == rhs.createdAt
            && lhs.hasImage == rhs.hasImage
            && lhs.readByPeer == rhs.readByPeer
    }
}

/// One page of chat history (`GET /device/chat/messages`), newest-first as the backend returns it.
struct OilaChatPage: Equatable {
    let messages: [OilaChatMessage]
    /// Opaque cursor to pass back as `before` to load the next (older) page; nil at the head of history.
    let nextCursor: String?
}

/// A minted LiveKit token for this device's live-audio room (`POST /device/stream/token`).
/// The device always receives a PUBLISHER token; the response schema is undocumented in the
/// spec, so the token / signaling URL / room are read tolerantly.
struct OilaStreamToken: Equatable {
    /// The LiveKit access token (JWT) — handed to the LiveKit SDK, never logged.
    let token: String
    /// The LiveKit signaling URL, e.g. `wss://stream.oila360.uz`.
    let url: String
    let room: String?
    let identity: String?

    static func == (lhs: OilaStreamToken, rhs: OilaStreamToken) -> Bool {
        lhs.token == rhs.token && lhs.url == rhs.url && lhs.room == rhs.room && lhs.identity == rhs.identity
    }
}

// MARK: - Chat + streaming service protocols
//
// Kept SEPARATE from `OilaDeviceServicing` on purpose: the existing device-API mocks
// (e.g. BolajonHomeViewModelTests) don't have to implement chat/streaming to keep compiling.

protocol OilaChatServicing {
    /// Cursor history for this device's thread, newest-first (`GET /device/chat/messages`).
    func fetchChatMessages(limit: Int, before: String?) async throws -> OilaChatPage
    /// Send a message to the parent — text and/or a single image (`POST /device/chat/messages`).
    @discardableResult
    func sendChatMessage(text: String?, imageData: Data?, imageMimeType: String?) async throws -> OilaChatMessage
    /// Advance the child read watermark for this thread (`POST /device/chat/read`).
    func markChatRead(lastMessageId: String?) async throws
    /// Unread messages from the parent for this device (`GET /device/chat/unread-count`).
    func fetchChatUnreadCount() async throws -> Int
    /// A fresh signed URL for a message's image attachment (`GET /device/chat/messages/{id}/attachment`).
    func fetchChatAttachmentURL(messageId: String) async throws -> URL
}

protocol OilaStreamServicing {
    /// Mint a LiveKit PUBLISHER token for this device's live-audio room (`POST /device/stream/token`).
    func mintStreamToken() async throws -> OilaStreamToken
}

// MARK: - Chat + streaming implementation
//
// Same-file extension so it can reuse the private `requestJSON` / `send` transport (device
// Bearer + `{ success, data }` envelope + single-flight 401 refresh) and the tolerant parse helpers.

extension OilaDeviceClient: OilaChatServicing, OilaStreamServicing {
    func fetchChatMessages(limit: Int = 30, before: String? = nil) async throws -> OilaChatPage {
        var query = [URLQueryItem(name: "limit", value: String(max(1, min(limit, 100))))]
        if let before, !before.isEmpty {
            query.append(URLQueryItem(name: "before", value: before))
        }
        let data = try await requestJSON(path: "device/chat/messages", method: .get, query: query, authorized: true)
        return Self.parseChatPage(from: data)
    }

    @discardableResult
    func sendChatMessage(text: String?, imageData: Data? = nil, imageMimeType: String? = nil) async throws -> OilaChatMessage {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = (trimmed?.isEmpty == false)
        guard hasText || imageData != nil else {
            throw OilaAPIError(statusCode: -1, message: "Empty message", errorCode: "EMPTY_MESSAGE", fieldErrors: [])
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = Self.chatMultipartBody(
            text: hasText ? trimmed : nil,
            imageData: imageData,
            imageMimeType: imageMimeType ?? "image/jpeg",
            boundary: boundary
        )
        let data = try await send(
            path: "device/chat/messages",
            method: .post,
            bodyData: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            authorized: true
        )
        return Self.parseChatMessage(fromAny: data)
            ?? OilaChatMessage(
                id: UUID().uuidString,
                text: hasText ? trimmed : nil,
                sender: .child,
                createdAt: nil,
                hasImage: imageData != nil,
                readByPeer: false,
                raw: [:]
            )
    }

    func markChatRead(lastMessageId: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let lastMessageId, !lastMessageId.isEmpty { body["lastMessageId"] = lastMessageId }
        _ = try await requestJSON(path: "device/chat/read", method: .post, body: body, authorized: true)
    }

    func fetchChatUnreadCount() async throws -> Int {
        let data = try await requestJSON(path: "device/chat/unread-count", method: .get, authorized: true)
        if let object = Self.dict(from: data) {
            return Self.intValue(object, ["count", "unread", "unreadCount", "total"]) ?? 0
        }
        if let number = data as? NSNumber { return number.intValue }
        return 0
    }

    func fetchChatAttachmentURL(messageId: String) async throws -> URL {
        let data = try await requestJSON(
            path: "device/chat/messages/\(messageId)/attachment",
            method: .get,
            authorized: true
        )
        let object = Self.dict(from: data) ?? [:]
        guard let raw = Self.firstString(object, ["url", "downloadUrl", "downloadURL", "signedUrl", "signedURL", "attachmentUrl"]),
              let url = URL(string: raw) else {
            throw OilaAPIError(statusCode: 200, message: "Attachment URL missing", errorCode: "NO_ATTACHMENT_URL", fieldErrors: [])
        }
        return url
    }

    func mintStreamToken() async throws -> OilaStreamToken {
        let data = try await requestJSON(path: "device/stream/token", method: .post, body: [:], authorized: true)
        let object = Self.dict(from: data) ?? [:]
        guard let token = Self.firstString(object, ["token", "accessToken", "livekitToken", "jwt"]),
              let url = Self.firstString(object, ["url", "wsUrl", "wsURL", "serverUrl", "serverURL", "signalingUrl", "livekitUrl", "host"]) else {
            throw OilaAPIError(statusCode: 200, message: "Stream token response missing token/url", errorCode: "NO_STREAM_TOKEN", fieldErrors: [])
        }
        return OilaStreamToken(
            token: token,
            url: url,
            room: Self.firstString(object, ["room", "roomName", "roomId"]),
            identity: Self.firstString(object, ["identity", "participant", "participantIdentity"])
        )
    }

    // MARK: Parsing

    static func parseChatPage(from data: Any) -> OilaChatPage {
        let rawItems: [[String: Any]]
        var cursor: String?
        if let array = data as? [[String: Any]] {
            rawItems = array
        } else if let object = data as? [String: Any] {
            rawItems = (object["items"] as? [[String: Any]])
                ?? (object["messages"] as? [[String: Any]])
                ?? (object["results"] as? [[String: Any]])
                ?? (object["data"] as? [[String: Any]])
                ?? []
            let meta = (object["meta"] as? [String: Any]) ?? object
            cursor = firstString(meta, ["nextCursor", "next_cursor", "before", "cursor"])
        } else {
            rawItems = []
        }
        return OilaChatPage(messages: rawItems.compactMap { parseChatMessage($0) }, nextCursor: cursor)
    }

    static func parseChatMessage(fromAny data: Any) -> OilaChatMessage? {
        guard let object = data as? [String: Any] else { return nil }
        // The send response may wrap the created message under `message`/`data`.
        if let nested = (object["message"] as? [String: Any]) ?? (object["data"] as? [String: Any]),
           nested["id"] != nil || nested["_id"] != nil || nested["messageId"] != nil {
            return parseChatMessage(nested)
        }
        return parseChatMessage(object)
    }

    static func parseChatMessage(_ item: [String: Any]) -> OilaChatMessage? {
        guard let id = firstString(item, ["id", "messageId", "_id"]) else { return nil }
        let senderRaw = (firstString(item, ["sender", "senderType", "from", "author", "direction"]) ?? "").lowercased()
        let sender: OilaChatMessage.Sender
        if senderRaw.contains("parent") {
            sender = .parent
        } else if senderRaw.contains("system") {
            sender = .system
        } else if senderRaw.contains("child") || senderRaw.contains("device") || senderRaw.contains("kid") {
            sender = .child
        } else {
            sender = .unknown
        }
        let hasImage = item["imageUrl"] != nil || item["image"] != nil || item["attachment"] != nil
            || (item["hasImage"] as? Bool == true) || (item["hasAttachment"] as? Bool == true)
        let readByPeer = item["readAt"] != nil || (item["readByPeer"] as? Bool == true)
            || (item["isReadByPeer"] as? Bool == true) || (item["read"] as? Bool == true)
        return OilaChatMessage(
            id: id,
            text: firstString(item, ["text", "body", "message", "content"]),
            sender: sender,
            createdAt: date(item, ["createdAt", "created_at", "sentAt", "timestamp", "ts"]),
            hasImage: hasImage,
            readByPeer: readByPeer,
            raw: item,
            systemKind: firstString(item, ["systemKind", "system_kind"]),
            systemData: item["systemData"] as? [String: Any]
        )
    }

    static func chatMultipartBody(text: String?, imageData: Data?, imageMimeType: String, boundary: String) -> Data {
        let lineBreak = "\r\n"
        var body = Data()
        if let text {
            body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"text\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            body.append("\(text)\(lineBreak)".data(using: .utf8)!)
        }
        if let imageData {
            let ext = imageMimeType.contains("png") ? "png" : "jpg"
            body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"image\"; filename=\"chat.\(ext)\"\(lineBreak)".data(using: .utf8)!)
            body.append("Content-Type: \(imageMimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            body.append(imageData)
            body.append(lineBreak.data(using: .utf8)!)
        }
        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
    }
}

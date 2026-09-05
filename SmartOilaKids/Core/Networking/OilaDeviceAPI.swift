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

    /// The Keychain answered definitively that this device holds no credential (`errSecItemNotFound`,
    /// or an item that is present but empty). Unlike `NO_LOCAL_CREDENTIAL` this is CONCLUSIVE, so it
    /// does force re-pairing: waiting cannot produce a token that is not there.
    ///
    /// The case this exists for is a device migration. Every item this app writes is
    /// `…ThisDeviceOnly`, which backups exclude, while the UserDefaults that say "paired" restore
    /// intact — so a restored install used to route to Home, show a green "Connected" chip, and
    /// never send another request for the life of the install.
    static let credentialAbsentCode = "CREDENTIAL_ABSENT"

    /// The device credential is no longer valid server-side — the caller should force re-pairing.
    ///
    /// `NO_LOCAL_CREDENTIAL` is excluded on purpose. Requests used to be sent WITHOUT an
    /// Authorization header whenever the Keychain read returned nil, so the server answered 401 and
    /// "we cannot read our own token" became indistinguishable from "the parent unpaired this
    /// device". The confirmation probe then re-read the same unreadable Keychain, got the same 401,
    /// and self-confirmed the revocation -- destroying a perfectly valid pairing.
    ///
    /// `CREDENTIAL_ABSENT` is the half of that nil the exclusion was never meant to cover: the
    /// Keychain did answer, and it said the item is not here.
    var requiresRePair: Bool {
        if errorCode == Self.credentialAbsentCode { return true }
        guard errorCode != Self.noCredentialCode else { return false }
        return errorCode == "REFRESH_INVALID" || errorCode == "UNAUTHORIZED" || statusCode == 401
    }

    /// A conclusive "there is no credential on this device". Probing cannot change the answer, so the
    /// invalidation path skips its confirmation delay for this one.
    var isCredentialAbsent: Bool { errorCode == Self.credentialAbsentCode }

    /// No Bearer could be attached, for either reason — so `send()` threw before any request left the
    /// app. Callers reporting an OUTCOME must branch on this rather than on the 401, because nothing
    /// was sent and therefore nothing was revoked, rejected by a server, or reached.
    var holdsNoCredential: Bool {
        errorCode == Self.noCredentialCode || errorCode == Self.credentialAbsentCode
    }
}

// MARK: - Device identity (for RedeemPairingDto)

/// Stable per-install identity sent in the pairing request and reused afterwards.
enum OilaDeviceIdentity {
    private static let dsnKey = "OILA_DEVICE_DSN"

    /// Keychain slot the DSN really lives in.
    ///
    /// A reinstall wipes UserDefaults but NOT the Keychain, so a UserDefaults-only DSN handed a
    /// still-paired device a brand-new identity after a reinstall while the device credential
    /// (also Keychain-backed) kept working: every DSN-scoped local store reset, and pushes
    /// addressed to the server's — now stale — dsn stopped matching this install. Only the store's
    /// access slot is used; the refresh slot is never written.
    private static let dsnStore: SecureTokenStoring = SecureTokenStore(
        accessTokenAccount: "oila_device_dsn",
        refreshTokenAccount: "oila_device_dsn_unused"
    )

    /// Generate-once, persist-forever device serial number sent as `dsn`.
    static func deviceDSN(userDefaults: UserDefaults = .standard) -> String {
        if let stored = dsnStore.accessToken()?.trimmedNonEmpty {
            // Keep the UserDefaults mirror in sync — it is the pre-first-unlock fallback below.
            if userDefaults.string(forKey: dsnKey)?.trimmedNonEmpty != stored {
                userDefaults.set(stored, forKey: dsnKey)
            }
            return stored
        }
        if let legacy = userDefaults.string(forKey: dsnKey)?.trimmedNonEmpty {
            // MIGRATION: an already-paired device keeps the identity it was paired with. Minting a
            // fresh UUID here instead would silently unpair every device already in the field.
            // Also the pre-first-unlock path: the Keychain read above returns nil while the device
            // is locked, and promoting the mirror is a no-op once the write finally succeeds.
            _ = dsnStore.storeAccessToken(legacy)
            return legacy
        }
        let generated = UUID().uuidString
        _ = dsnStore.storeAccessToken(generated)
        userDefaults.set(generated, forKey: dsnKey)
        return generated
    }

    /// The DSN this install ALREADY has, without minting one. Read-only callers — deciding whether
    /// an incoming push is addressed to this device, for instance — must use this rather than
    /// `deviceDSN`, which persists a fresh UUID as a side effect and would quietly hand an
    /// unpaired install an identity just by asking the question.
    static func persistedDSN(userDefaults: UserDefaults = .standard) -> String? {
        dsnStore.accessToken()?.trimmedNonEmpty ?? userDefaults.string(forKey: dsnKey)?.trimmedNonEmpty
    }

    /// Clears the persisted device DSN so the next `deviceDSN(...)` call mints a fresh one.
    /// Called on disconnect: because every DSN-scoped local store keys off this value, minting a
    /// new DSN means re-pairing the device to a DIFFERENT child starts from an empty scope and
    /// cannot inherit the previous child's cached location/tasks/etc. Both copies must go, or the
    /// Keychain would hand the next child the previous child's scope.
    static func resetDSN(userDefaults: UserDefaults = .standard) {
        dsnStore.setAccessToken(nil)
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
    /// The parent called this chore off. It is shown, struck through, rather than hidden: a task
    /// that silently disappears reads to a child as one they failed to do.
    var isCancelled: Bool {
        let normalized = status.lowercased()
        return normalized == "cancelled" || normalized == "canceled"
    }
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

/// Today's device-wide screen time from `GET /device/apps/screen-time`.
///
/// The live spec types the 200 body as an untyped `{}`, so every field is read tolerantly. The
/// vocabulary mirrors the sibling per-app rows the same controller already returns
/// (`usedSeconds` / `dailyLimitSeconds` / `remainingSeconds` / `isLimitReached` / `usageDate` —
/// see `parseAppLimit`), plus `dailyScreenLimitSeconds`, which is the name the parent-side
/// `SetScreenLimitDto` gives the device-wide budget. Everything is SECONDS: there is no
/// minutes-named field anywhere in either spec.
struct OilaDeviceScreenTime: Equatable {
    let usedSeconds: Int
    /// The parent's daily budget, or nil when they have not set one. `SetScreenLimitDto` declares
    /// this nullable, so "no budget" is a normal state, not a parse failure.
    let dailyLimitSeconds: Int?
    let remainingSeconds: Int?
    let isLimitReached: Bool
    let usageDate: String?

    var hasBudget: Bool { (dailyLimitSeconds ?? 0) > 0 }
    /// 0...1 for a progress bar; nil when there is no budget to be a fraction OF.
    var progress: Double? {
        guard let limit = dailyLimitSeconds, limit > 0 else { return nil }
        return min(1, max(0, Double(usedSeconds) / Double(limit)))
    }
}

/// One `GET /device/home` answer (DeviceHomeResponseDto) — the whole Home screen in one call.
///
/// Built out of the types the individual endpoints already return rather than a parallel set of
/// home-only models. The route is documented as carrying the SAME values those endpoints do
/// (`screenTime` is explicitly "identical to `GET /device/apps/screen-time`"), so a second set of
/// types would be two spellings of one contract, free to drift apart without anything noticing.
///
/// What Home consumes today is `child`, and only `child`: name/emoji/colour are written once by
/// `BolajonSetupFlowView.handlePaired` out of the pairing response and were then never re-read, so
/// a parent renaming their child never reached the handset at all. The endpoint's own docs are
/// explicit about this — "re-read on every call, do NOT cache the pairing response's copy".
///
/// The other three are parsed because each costs one line through the tolerant helpers that
/// already exist, and because a partial model of a documented payload is a trap for whoever reads
/// this next. They are deliberately NOT wired to the screen:
///
///  * `recentTasks` cannot drive the Home task card. That card shows two pending tasks plus the
///    most recently completed one with cancelled ones excluded; `recent` is capped at two rows with
///    no status filter and no pagination, so the selection is not reproducible from it. Home keeps
///    walking `GET /device/tasks`.
///  * `screenTime` already has its own call on this screen. A second source would only help when
///    that call failed — and on a dead network both fail together, so the fallback could
///    essentially never fire while still adding a second origin for a figure with careful
///    freshness rules (`todaysServerScreenTime`) attached to it.
///  * `chatUnreadCount` belongs to `ChatHomeCard`, which owns its own endpoint and refresh token.
struct OilaDeviceHome {
    /// The child's CURRENT identity. Nil when the payload named no recognizable child field at
    /// all — a caller must then keep the identity it already has rather than clear it.
    let child: OilaChildProfile?
    /// `screenTime`, read with the same parser as the dedicated endpoint (see the type doc).
    let screenTime: OilaDeviceScreenTime?
    /// `tasks.totalPoints` — the same figure `GET /device/tasks/summary` returns.
    let taskTotalPoints: Int?
    /// `tasks.recent`: at most two rows, no status filter. See the type doc for why Home cannot
    /// build its card from these.
    let recentTasks: [OilaDeviceTask]
    let chatUnreadCount: Int?
    /// `chat.lastMessage`; nil on a thread with no messages yet.
    let chatLastMessage: OilaChatMessage?
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

    /// This device's location permission, so the parent app can say WHY a feature is not reporting
    /// ("Only While Using — cannot report in background") instead of showing a bare "offline".
    /// Exactly one of "Always" | "WhenInUse" | "Denied" | "NotDetermined", or nil when the caller
    /// has nothing to report.
    ///
    /// **NOT SENT — deliberately held back.** `PostDeviceStatusDto` declares only
    /// `{battery, networkType, soundMode}`, and this backend rejects undeclared properties
    /// (`forbidNonWhitelisted`) rather than ignoring them, so putting this on the wire 400s the
    /// whole request. The value is still computed and carried here because the field is a live
    /// backend ask; `postDeviceStatus` is the single place to re-enable it, and it must not be
    /// re-enabled until the DTO declares it. The earlier comment here — "the backend ignores keys
    /// it does not know" — was an assumption, and it was wrong.
    let locationAuthorization: String?

    /// `diagnostics` — why this handset can or cannot do what the parent expects (backend decision
    /// D-102). Keys and values come from `DeviceDiagnosticsReporter`; see the contract rules there.
    ///
    /// This is the surface that supersedes `locationAuthorization` above. The backend declared
    /// `diagnostics` on `PostDeviceStatusDto` and mirrored it onto the parent's `ChildStatusDto`,
    /// but it never declared `locationAuthorization` — so that field stays held back and this one
    /// carries the same information in the vocabulary the contract actually accepts.
    ///
    /// Empty means "measured nothing"; the key is then dropped from the body rather than sent as an
    /// empty object, because the contract reads a missing key as "never reported".
    let diagnostics: [String: String]?

    /// Explicit init purely so the optional fields can default: the synthesized memberwise one
    /// would have forced every existing three-field call site (and its test doubles) to change.
    init(
        battery: Int?,
        networkType: String?,
        soundMode: String?,
        locationAuthorization: String? = nil,
        diagnostics: [String: String]? = nil
    ) {
        self.battery = battery
        self.networkType = networkType
        self.soundMode = soundMode
        self.locationAuthorization = locationAuthorization
        self.diagnostics = diagnostics
    }
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
                if let start = Self.timeString(scope, Self.scheduleStartKeys),
                   let end = Self.timeString(scope, Self.scheduleEndKeys) {
                    return (start, end)
                }
                // Minute-of-day form. The parent writes schedules with `CreateLockScheduleDto`,
                // whose `startMinute`/`endMinute` are NUMBERS in 0...1439 — the only typed evidence
                // anywhere for how a schedule is represented. A device payload that echoes that
                // shape used to fall straight through this loop, so the child saw a lock screen
                // with no end time on it while the app held the answer.
                if let start = Self.timeFromMinuteOfDay(scope, Self.scheduleStartMinuteKeys),
                   let end = Self.timeFromMinuteOfDay(scope, Self.scheduleEndMinuteKeys) {
                    return (start, end)
                }
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

    private static let scheduleStartMinuteKeys = ["startMinute", "start_minute", "startMinutes", "fromMinute"]
    private static let scheduleEndMinuteKeys = ["endMinute", "end_minute", "endMinutes", "toMinute"]

    private static func timeString(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = (dict[key] as? String)?.trimmedNonEmpty { return value }
        }
        return nil
    }

    /// Renders a minute-of-day (0...1439) as `"HH:mm"`, matching the format the string form of this
    /// field already arrives in. Out-of-range values are refused rather than wrapped: a schedule
    /// that says 25:00 is a payload we do not understand, and showing a wrong window on a lock
    /// screen is worse than showing none.
    static func timeFromMinuteOfDay(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            let raw: Int?
            switch dict[key] {
            case let value as Int: raw = value
            // Trapping conversion — see `safeInt`. A schedule minute arriving as 1e400 would
            // otherwise crash the app on the lock screen, of all places.
            case let value as Double: raw = OilaDeviceClient.safeInt(value)
            case let value as String: raw = Int(value.trimmingCharacters(in: .whitespaces))
            default: raw = nil
            }
            guard let minute = raw, (0 ... 1439).contains(minute) else { continue }
            return String(format: "%02d:%02d", minute / 60, minute % 60)
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

/// What `POST /device/unpair` actually achieved.
///
/// Three of these look identical from the child's side — the app returns to pairing either way —
/// and telling them apart is the whole point: `.revoked` means the server-side link really is cut,
/// `.routeMissing` means this deployment has no such route yet and a parent must still remove the
/// device in the Oila360 app, and `.unreachable` means the phone had no signal and the link is
/// certainly still standing. Without the distinction the support answer to "I disconnected but the
/// parent still sees the device" is a guess.
///
/// `.pinRequired` and `.rateLimited` arrived with the D-099 contract (see `unpairDevice(pin:)`) and
/// are the two answers the caller must NOT treat as a disconnect: the handset is still paired.
enum OilaUnpairOutcome: String {
    /// The server accepted the revoke.
    case revoked = "device_unpair_revoked"
    /// The route is not deployed (404/405/501). Was the norm until D-099 shipped; kept because a
    /// deployment that loses the route again must not strand every child on this screen.
    case routeMissing = "device_unpair_route_missing"
    /// The request never reached a server — no signal, DNS, a dropped connection.
    case unreachable = "device_unpair_unreachable"
    /// 403 `UNPAIR_PIN_INVALID`: the parent has set an unpair PIN and the one supplied was wrong or
    /// absent. **Still paired.** The only outcome that asks the caller for something.
    case pinRequired = "device_unpair_pin_required"
    /// 429: more than 10 attempts a minute. Still paired; the child has to wait.
    case rateLimited = "device_unpair_rate_limited"
    /// No request left the app — this device holds no readable credential, so there was nothing to
    /// revoke. Kept apart from `.revoked` (the word has to mean the SERVER acted, or the diagnostic
    /// is worse than silence) AND from `.rejected`, because the caller must still be allowed to
    /// finish the local teardown: with no token there is nothing a retry could ever accomplish, and
    /// refusing would strand the handset on the disconnect screen forever. It is not a bypass —
    /// a child cannot arrange this state, only a locked Keychain before first unlock can.
    case noCredential = "device_unpair_no_credential"
    /// A server answered, but with neither a revoke nor a not-implemented. Kept distinct so a 500
    /// is never filed as "offline", which would send anyone reading this to the wrong side.
    case rejected = "device_unpair_rejected"
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
    /// The server's own reward total (`GET /device/tasks/summary` → `totalPoints`), or nil when the
    /// response shape isn't recognized. Authoritative where the local sum is not: see
    /// `fetchTaskStarTotal` on the client.
    func fetchTaskStarTotal() async throws -> Int?
    func updateFCMToken(_ token: String) async throws
    func uploadLocationBatch(_ fixes: [OilaLocationFix]) async throws
    func postDeviceStatus(_ status: OilaDeviceStatus) async throws
    /// Report app-usage deltas (`POST /device/apps/usage`); the response is the enforcement
    /// state (locked packages + per-app limit/remaining) that drives on-device app-limit locking.
    func reportAppUsage(items: [DeviceApplicationUsageReportItemRequest]) async throws -> DeviceApplicationUsageReportResponse
    func fetchLockState() async throws -> OilaLockState
    /// Today's device-wide screen time vs the parent's daily budget
    /// (`GET /device/apps/screen-time`). Nil when the response shape isn't recognized.
    func fetchScreenTime() async throws -> OilaDeviceScreenTime?
    /// Report an app removal/tamper attempt (`POST /device/apps/removal-attempt`).
    func reportRemovalAttempt(packageName: String, applicationName: String) async throws
    /// The Home screen's whole state in one call (`GET /device/home`). Nil when the response shape
    /// isn't recognized.
    ///
    /// ON the protocol, unlike `unpairDevice()`, because Home's view model reaches the backend only
    /// through this abstraction — a test of the child-identity refresh has no other way in. It is
    /// deliberately NOT given a protocol-extension default returning nil: that default would win
    /// silently if the real client's signature ever drifted, and the symptom (an endpoint that is
    /// simply never called) looks identical to a backend that has not deployed the route.
    func fetchHome() async throws -> OilaDeviceHome?
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
        } else {
            // Omitting the key is legal, but it is not harmless: the device pairs with NO push
            // address, so every server→child command (chat.refresh, stream.start, …) is
            // undeliverable until FirebaseMessaging ships. Record it so the diagnostics screen
            // shows why nothing arrives instead of a pairing that looks entirely healthy.
            Task { @MainActor in
                RuntimeDiagnosticsCenter.shared.updatePushToken(
                    status: "missing",
                    endpoint: "device/pair",
                    dsn: dsn,
                    lastError: "paired_without_fcm_token"
                )
                RuntimeDiagnosticsCenter.shared.updateLifecycle(lastEvent: "paired_without_fcm_token")
            }
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

    /// Ends this device's session. The local credential is ALWAYS cleared (the `defer`); the
    /// server-side revoke is best-effort.
    ///
    /// `POST /device/unpair` is the real revoke and is attempted first. `/auth/logout` afterwards is
    /// a legacy leftover and MUST NOT be read as the signal that anything was revoked: it is a
    /// refresh-token route, and a paired device holds a single long-lived `deviceToken` and no
    /// refresh token, so for the case that matters here the route cannot succeed even in principle.
    /// It is still attempted because a legacy install that does hold a refresh token is entitled to
    /// have it invalidated; the `unpairDevice()` outcome is what says whether the LINK was cut.
    ///
    /// Neither call may prevent the disconnect. `unpairDevice()` does not throw and `/auth/logout`
    /// is behind `try?`, so a child with no signal at all still reaches the local teardown — which
    /// is the requirement: a phone that cannot be disconnected offline is a phone the child cannot
    /// disconnect at the moment they most need to.
    func logout() async throws {
        defer { secureTokens.clear() }
        await unpairDevice()
        var body: [String: Any] = [:]
        if let refresh = secureTokens.refreshToken()?.trimmedNonEmpty {
            body["refreshToken"] = refresh
        }
        _ = try? await requestJSON(
            path: "auth/logout",
            method: .post,
            body: body,
            authorized: true,
            // A 401 here means the credential is already dead; refreshing it just to log out is
            // pointless work on a screen the child is leaving.
            allowRefresh: false
        )
    }

    /// Revoke THIS device's credential server-side (`POST /device/unpair`), authenticated with the
    /// device Bearer.
    ///
    /// **The route is live since 2026-08-28** (probed: 401 for an invalid Bearer, where it answered
    /// 404 through build 16), and it now carries the D-099 PIN contract the team settled on in the
    /// group chat — "Yoq. Siz jonatasiz. Backend tekshiradi" / `POST /device/unpair {"pin":"1234"}`.
    /// The PIN is the one a PARENT sets through `PUT /parent/children/{id}/unpair-pin`; it is stored
    /// as a scrypt hash and this app never sees it, which is the whole point of moving the gate off
    /// the handset. Pass `nil` to probe: the server answers 200 when no PIN is set and 403 when one
    /// is, so the caller learns whether to ask without the app having to know.
    ///
    /// The status mapping is the contract's, not a guess:
    ///  * **401 ⇒ `.revoked`.** The spec is explicit that on THIS route a 401 means the call that
    ///    succeeded is what killed the token, so a retry after a dropped response lands here and
    ///    "retrying instead of doing the local reset strands the handset".
    ///  * **403 ⇒ `.pinRequired`**, still paired. Mapped to `.revoked` before D-099, which would now
    ///    wipe the phone on precisely the answer that means "wrong PIN".
    ///  * **429 ⇒ `.rateLimited`**, still paired — more than 10 attempts a minute.
    ///
    /// It NEVER throws, deliberately: the outcome is returned so the caller can tell "the link is
    /// cut" from "the child guessed wrong", which a thrown error flattens.
    ///
    /// Deliberately NOT on `OilaDeviceServicing`, for the same reason the chat/streaming protocols
    /// are separate: the existing device-API mocks would all have to implement it to keep compiling,
    /// and none of them has anything to say about unpairing.
    @discardableResult
    func unpairDevice(pin: String? = nil) async -> OilaUnpairOutcome {
        let outcome: OilaUnpairOutcome
        var detail: String?
        // An empty string is not a PIN. Sending `{"pin":""}` would be validated as a malformed PIN
        // (400/403) rather than read as the "no PIN set" probe the caller meant.
        let trimmedPIN = pin?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = (trimmedPIN?.isEmpty == false) ? ["pin": trimmedPIN!] : [:]
        do {
            _ = try await requestJSON(
                path: "device/unpair",
                method: .post,
                body: body,
                authorized: true,
                // Same reasoning as `logout()`: a 401 means the credential this call exists to
                // revoke is already dead, so minting a fresh one to announce its revocation is work
                // with no possible outcome.
                allowRefresh: false
            )
            outcome = .revoked
        } catch let error as OilaAPIError {
            detail = error.errorCode ?? "http_\(error.statusCode)"
            if error.holdsNoCredential {
                // Nothing was sent: this device holds no readable credential, so there was nothing
                // for the server to revoke and no request left the app. Not `.revoked` — that word
                // has to mean the SERVER acted, or the diagnostic is worse than silence.
                outcome = .noCredential
            } else {
                outcome = Self.unpairOutcome(forStatusCode: error.statusCode)
            }
        } catch {
            // A transport failure, not an answer: no signal, DNS, a dropped connection.
            outcome = .unreachable
            detail = "transport"
        }
        let event = [outcome.rawValue, detail].compactMap { $0 }.joined(separator: " ")
        // The lifecycle timeline is the app-wide event channel the diagnostics screen already
        // renders, and a disconnect is a lifecycle event by any reading. Same channel
        // `SecureTokenStore` uses to surface a wedged Keychain.
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updateLifecycle(lastEvent: event)
        }
        return outcome
    }

    /// Maps an unpair response status onto the outcome vocabulary.
    ///
    /// 404 (no such route), 405 (the path exists for another verb) and 501 (declared but not
    /// implemented) all mean "this deployment does not have it yet" and none of them is an app
    /// error. 401 means the device Bearer was refused, which on this route the contract defines as a
    /// COMPLETED unpair — the call that worked is what revoked it. 403 is the opposite and used to
    /// be folded in with it: `UNPAIR_PIN_INVALID`, the device is still paired, and treating it as a
    /// revoke wiped the phone on a wrong PIN. 429 is the brute-force ceiling. Everything else is a
    /// server that answered something unexpected and is filed as such.
    static func unpairOutcome(forStatusCode statusCode: Int) -> OilaUnpairOutcome {
        switch statusCode {
        case 404, 405, 501: return .routeMissing
        case 401: return .revoked
        case 403: return .pinRequired
        case 429: return .rateLimited
        default: return .rejected
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
        // ONE walk over every status, the way the Android child app does it.
        //
        // That the unfiltered route really returns completed + cancelled rows is not an assumption:
        // Bolajon360 versionCode 5 calls `getTasksUseCase.invoke(null, page, 10, "desc")` — an
        // explicit null status — and its Tasks screen renders Active, Completed ("Collected") and
        // Cancelled rows from that one response. The spec types `status` as an optional query
        // parameter and documents no default.
        //
        // Two things were wrong with asking for "Active" and "Completed" separately:
        //
        //  • A CANCELLED task came back in neither, so a chore the parent called off simply
        //    vanished from the child's screen with no explanation.
        //  • The two walks ran concurrently and each could run up to `tasksMaxPages` — 20 requests
        //    per Home load on a device we ask to stay up all day — and a task completed WHILE they
        //    were in flight came back from both, giving two rows with the same `Identifiable` id.
        //
        // The dedupe below is kept as a cheap guard: it is no longer load-bearing with a single
        // walk, but it costs one set and it is the difference between a duplicate id and a SwiftUI
        // ForEach with undefined behaviour.
        var seen = Set<String>()
        return (try await fetchStatus(nil)).filter { seen.insert($0.id).inserted }
    }

    /// `GET /device/tasks` pagination: the spec marks `page`/`limit`/`sortOrder` as REQUIRED
    /// (limit max 100), so every request sends them. Pages are walked until a short page
    /// signals the end, hard-capped so a misbehaving backend can't loop us forever.
    static let tasksPageLimit = 100
    static let tasksMaxPages = 10

    /// `status: nil` asks for every status (Active + Completed + Cancelled), which is what the
    /// route returns when the filter is omitted.
    private func fetchStatus(_ status: String?) async throws -> [OilaDeviceTask] {
        var tasks: [OilaDeviceTask] = []
        for page in 1 ... Self.tasksMaxPages {
            var query = [
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "limit", value: "\(Self.tasksPageLimit)"),
                URLQueryItem(name: "sortOrder", value: "desc")
            ]
            if let status { query.append(URLQueryItem(name: "status", value: status)) }
            let data = try await requestJSON(
                path: "device/tasks",
                method: .get,
                query: query,
                authorized: true
            )
            let pageTasks = Self.parseTasks(from: data)
            tasks += pageTasks
            // Prefer the server's own pagination meta when it sends one (`{page, limit, total,
            // totalPages}` — the shape the Android client's `PageMetaDto` declares). The row-count
            // heuristic below is a fallback, and it is subtly wrong on its own: it counts PARSED
            // rows, so a full page containing one row this client cannot parse looks short and the
            // walk stops early, silently hiding every later task.
            if let totalPages = Self.pageCount(from: data) {
                if page >= totalPages { break }
            } else if pageTasks.count < Self.tasksPageLimit {
                break
            }
        }
        return tasks
    }

    /// `totalPages` from a paginated list response, when the payload carries pagination meta.
    static func pageCount(from data: Any) -> Int? {
        guard let object = dict(from: data) else { return nil }
        let meta = firstDictionary(object, ["meta", "pagination", "page", "pageMeta"]) ?? object
        guard let totalPages = intValue(meta, ["totalPages", "total_pages", "pageCount", "pages"]),
              totalPages > 0 else { return nil }
        return totalPages
    }

    func completeTask(id: String) async throws {
        _ = try await requestJSON(path: "device/tasks/\(id)/complete", method: .post, authorized: true)
    }

    /// `GET /device/tasks/summary` → `{ "totalPoints": Int }`.
    ///
    /// The collected-stars figure was summed locally from the completed tasks this client happened to
    /// have fetched, which under-reports in three real situations: the page walk is capped
    /// (`tasksPageLimit` x `tasksMaxPages`), the backend need not keep completed tasks forever, and a
    /// task completed on another of the child's devices never appears in this device's list. The
    /// Android child app reads this endpoint for exactly this number and labels it with the same
    /// "collected stars" wording, so adopting it also removes a cross-platform disagreement where the
    /// two apps could show a different total for the same child.
    ///
    /// Returns nil rather than 0 when no known key is present, so a caller can fall back to its local
    /// sum instead of showing a child that their stars have vanished.
    func fetchTaskStarTotal() async throws -> Int? {
        let data = try await requestJSON(path: "device/tasks/summary", method: .get, authorized: true)
        guard let object = Self.dict(from: data) else { return nil }
        // Tolerant like every other read here: the live spec types this response as an untyped {}.
        // `totalPoints` is the confirmed spelling — it is what the Android child app's
        // `TaskSummaryDto` declares, and that client renders it under the same "collected stars"
        // label this one does.
        if let total = Self.intValue(object, ["totalPoints", "total_points", "totalRewardPoints", "points", "stars"]) {
            return total
        }
        // Tolerate one level of nesting rather than falling back to the local sum over a wrapper.
        if let nested = Self.firstDictionary(object, ["summary", "data"]) {
            return Self.intValue(nested, ["totalPoints", "total_points", "totalRewardPoints", "points", "stars"])
        }
        return nil
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
        // ONLY the three fields `PostDeviceStatusDto` declares. This is not stylistic tidiness — the
        // backend runs its NestJS ValidationPipe with `forbidNonWhitelisted`, so an undeclared
        // property is a hard 400, not an ignored extra:
        //
        //     {"errorCode":"VALIDATION_FAILED",
        //      "errors":[{"field":"x","message":"property x should not exist"}]}
        //
        // `locationAuthorization` used to be appended here, and because it is never nil that
        // rejected EVERY status post — silently, since the only catch below that inspects the error
        // is the re-pair one. The request itself is the liveness signal, so losing it made the child
        // read as offline to the parent forever: the exact symptom the field was added to explain.
        // Re-add it (see `OilaDeviceStatus.locationAuthorization`) only once the backend declares it.
        var body: [String: Any] = [:]
        if let battery = status.battery { body["battery"] = battery }
        if let network = status.networkType { body["networkType"] = network }
        if let sound = status.soundMode { body["soundMode"] = sound }
        // `diagnostics` IS declared (D-102), so unlike `locationAuthorization` it is safe to send —
        // but only with keys the schema documents, because the same `forbidNonWhitelisted` rule
        // applies inside the map: one unrecognised key 400s the whole liveness post.
        // `DeviceDiagnosticsReporter.emittableKeys` is the allow-list, and it is filtered again here
        // rather than trusted, so a future caller cannot widen it by accident.
        if let diagnostics = status.diagnostics, !Self.diagnosticsRejectedByServer {
            let permitted = diagnostics.filter { DeviceDiagnosticsReporter.emittableKeys.contains($0.key) }
            if !permitted.isEmpty { body["diagnostics"] = permitted }
        }
        // Send even when every field is nil. The backend derives "device offline" from how long it
        // has been since it last heard from this device, so the REQUEST ITSELF is the liveness
        // signal and an empty `{}` is explicitly valid (every field in PostDeviceStatusDto is
        // optional). Skipping the call on an empty body — which is what this did — made a charged,
        // stationary phone on Wi-Fi look offline: on iOS the snapshot is often all-nil (soundMode
        // is unreadable, battery/network unchanged) and so nothing was ever sent.
        do {
            _ = try await requestJSON(path: "device/status", method: .post, body: body, authorized: true)
        } catch let error as OilaAPIError where error.statusCode == 400 && body["diagnostics"] != nil {
            // Give up the diagnostics rather than the heartbeat.
            //
            // This request is the liveness signal — the backend decides "offline" from how long it
            // has been since the last one — so a 400 here does not lose a diagnostics map, it takes
            // every iOS child in the fleet off the parent's screen. That has already happened once:
            // `locationAuthorization` was appended to this body before the backend declared it, and
            // because nothing inspected the error, every status post 400'd silently for as long as
            // the field was there.
            //
            // `diagnostics` is declared today and the keys are filtered twice, so this should never
            // fire. It exists because "should never" is exactly what was believed last time, and
            // the cost of being wrong is the whole fleet. Drop the map for the rest of the process,
            // resend immediately without it, and let the ping keep working exactly as it did in
            // build 19. A relaunch tries again, so a transient server-side problem heals itself.
            Self.diagnosticsRejectedByServer = true
            body.removeValue(forKey: "diagnostics")
            Task { @MainActor in
                RuntimeDiagnosticsCenter.shared.updateLifecycle(lastEvent: "status_diagnostics_rejected")
            }
            _ = try await requestJSON(path: "device/status", method: .post, body: body, authorized: true)
        }
    }

    /// Set once, if ever, by the 400 handler above. Static because the fleet-wide symptom is what
    /// matters and every client instance shares the same server; deliberately NOT persisted, so a
    /// backend fix takes effect on the next launch without anything having to clear a flag.
    nonisolated(unsafe) private static var diagnosticsRejectedByServer = false

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

    func fetchScreenTime() async throws -> OilaDeviceScreenTime? {
        let data = try await requestJSON(path: "device/apps/screen-time", method: .get, authorized: true)
        guard let object = Self.dict(from: data) else { return nil }
        return Self.parseScreenTime(from: object)
    }

    func fetchHome() async throws -> OilaDeviceHome? {
        let data = try await requestJSON(path: "device/home", method: .get, authorized: true)
        guard let object = Self.dict(from: data) else { return nil }
        return Self.parseHome(from: object)
    }

    /// Tolerant read of `DeviceHomeResponseDto`.
    ///
    /// Every field goes through a parser that already exists, and that is the point rather than a
    /// convenience: `child`, `screenTime`, the task rows and the chat message are documented to be
    /// the SAME values `/device/pair`, `/device/apps/screen-time`, `/device/tasks` and
    /// `/device/chat/messages` return, so parsing them a second way here would be the place the two
    /// readings quietly diverge. Two of the helpers need no argument massaging at all —
    /// `parseChild` looks under `child` before falling back to the whole object, and
    /// `parseScreenTime` looks under `screenTime` when the top level carries no usage figure, which
    /// is exactly this payload's shape. `parseScreenTime` also already tries
    /// `dailyScreenLimitSeconds` first and already reads `date` as the day key, both of which are
    /// what this response spells them.
    ///
    /// Split out from `fetchHome` so the parse is testable without an HTTP stub, the same way
    /// `parseScreenTime` and `parseLockState` are. Never nil: an unrecognized payload yields an
    /// all-nil value, and it is `fetchHome`'s job to decide that a non-object body is nothing.
    static func parseHome(from object: [String: Any]) -> OilaDeviceHome {
        let tasks = firstDictionary(object, ["tasks"])
        let chat = firstDictionary(object, ["chat"])
        let lastMessage = chat.flatMap { $0["lastMessage"] }
        return OilaDeviceHome(
            // Strict about where the child comes from, which `parseChild` on its own is not: with
            // no `child` key it falls back to the object it was handed, and here that object is the
            // WHOLE Home payload — so a stray top-level `name` would be written straight into the
            // child's profile by the refresh below. That fallback is right for the pair response,
            // which really does carry the child at either level; it is wrong here.
            child: firstDictionary(object, ["child"]).flatMap { parseChild(from: $0) },
            screenTime: parseScreenTime(from: object),
            taskTotalPoints: tasks.flatMap { intValue($0, ["totalPoints", "total_points", "points"]) },
            // `recent` absent → an empty array reaches `parseTasks`, which reads it as no rows.
            recentTasks: parseTasks(from: tasks?["recent"] ?? []),
            chatUnreadCount: chat.flatMap { intValue($0, ["unreadCount", "unread_count", "unread"]) },
            chatLastMessage: lastMessage.flatMap { parseChatMessage(fromAny: $0) }
        )
    }

    /// Tolerant read for `GET /device/apps/screen-time` (2xx typed as `{}` in the live spec).
    ///
    /// Returns nil when the payload names no usage figure at all, so a caller can hide its card
    /// rather than assert "0 minutes" — a claim this app is in no position to make on iOS, where
    /// nothing reports per-app usage in the first place.
    static func parseScreenTime(from object: [String: Any]) -> OilaDeviceScreenTime? {
        // Some envelopes nest the payload; look one level down before giving up.
        let source = intValue(object, usedSecondsKeys) != nil
            ? object
            : (firstDictionary(object, ["screenTime", "screen_time", "today", "summary"]) ?? object)

        guard let used = intValue(source, usedSecondsKeys) else { return nil }
        let limit = intValue(source, [
            "dailyScreenLimitSeconds", "daily_screen_limit_seconds",
            "dailyLimitSeconds", "daily_limit_seconds", "limitSeconds", "dailyLimit", "budgetSeconds"
        ])
        let remaining = intValue(source, ["remainingSeconds", "remaining_seconds", "remaining", "leftSeconds"])
        // Same rule as `parseAppLimit`: trust the flag when the server sends one, otherwise derive it
        // from the numbers, and treat "no budget" as never reached.
        let derivedReached: Bool = {
            guard let limit, limit > 0 else { return false }
            return (remaining ?? (limit - used)) <= 0
        }()
        return OilaDeviceScreenTime(
            usedSeconds: max(0, used),
            dailyLimitSeconds: limit.map { max(0, $0) },
            remainingSeconds: remaining.map { max(0, $0) },
            isLimitReached: boolValue(source, ["isLimitReached", "is_limit_reached", "limitReached", "reached"])
                ?? derivedReached,
            usageDate: firstString(source, ["usageDate", "usage_date", "date", "day"])
        )
    }

    /// `totalSeconds` is included because that is what the parent web app's screen-time aggregate
    /// calls the same number; the device response is a different (single-day) shape, but a backend
    /// that reused the name should not cost us the reading.
    private static let usedSecondsKeys = [
        "usedSeconds", "used_seconds", "usageSeconds", "used", "totalSeconds", "total_seconds"
    ]

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

    /// Body-agnostic transport shared by the JSON helpers and the multipart upload: applies the
    /// `{ success, data }` envelope, device Bearer, single-flight 401 refresh, and — for GET only —
    /// the transient-failure replay in `execute`.
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
                // Which nil is this? `.absent` means the Keychain answered "no such item", which no
                // retry can fix and which a restored-from-backup install produces on every request
                // for the rest of its life; anything else (notably locked-before-first-unlock) is
                // transient and must NOT be allowed to tear down a valid pairing.
                let absent = secureTokens.accessTokenState() == .absent
                throw OilaAPIError(
                    statusCode: 401,
                    message: "No device credential available on this device",
                    errorCode: absent ? OilaAPIError.credentialAbsentCode : OilaAPIError.noCredentialCode,
                    fieldErrors: []
                )
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, http) = try await execute(request, allowRetry: method == .get)

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
        //
        // The server's own error is parsed FIRST and is what surfaces whenever the refresh cannot
        // help. A paired device holds a long-lived `deviceToken` and no refresh token, so refresh
        // was attempted unconditionally and failed with a synthetic "No refresh token" —
        // discarding the real `message`/`errorCode` the backend sent (why the pairing was
        // rejected) and replacing it with an error about a token this device never had.
        if http.statusCode == 401, authorized {
            let serverError = Self.error(from: json, statusCode: http.statusCode)
            guard allowRefresh, secureTokens.refreshToken()?.trimmedNonEmpty != nil else {
                throw serverError
            }
            do {
                try await refreshGate.run { [weak self] in
                    guard let self else { return }
                    try await self.refreshSession()
                }
            } catch {
                // The refresh failed on its own terms; the caller still needs to know why the
                // ORIGINAL request was rejected, so the server's 401 wins.
                throw serverError
            }
            return try await send(
                path: path, method: method, query: query,
                bodyData: bodyData, contentType: contentType,
                authorized: authorized, allowRefresh: false
            )
        }

        throw Self.error(from: json, statusCode: http.statusCode)
    }

    /// At most three attempts per idempotent request, backing off 0.4 s then 0.8 s.
    private static let idempotentRetryAttempts = 3
    private static let idempotentRetryBackoff: UInt64 = 400_000_000

    /// Runs one request, replaying it a bounded number of times on a TRANSIENT failure — but only
    /// when the verb is idempotent, which here means GET and nothing else.
    ///
    /// `NetworkError.shouldRetry` / `RetryPolicy` existed with no caller at all while prod was
    /// answering 503, so a single transient failure surfaced to the child as a hard error. The
    /// writes deliberately stay single-attempt: `POST /device/apps/usage` carries usage DELTAS, so
    /// a replay of a write the server already committed double-counts the child's screen time
    /// (there is no idempotency key — backend ask B5), and the other POST/PUT/PATCH/DELETE routes
    /// are no safer to repeat.
    ///
    /// 401 is excluded from the retryable statuses on purpose: it is the single-flight
    /// `refreshGate`'s business one level up, and it is returned here untouched so that path still
    /// sees it. Replaying it instead would hammer `/auth/refresh` with the same dead credential.
    /// 403 is excluded because a replay cannot change the answer.
    private func execute(_ request: URLRequest, allowRetry: Bool) async throws -> (Data, HTTPURLResponse) {
        var attempt = 1
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw OilaAPIError(statusCode: -1, message: "Invalid response", errorCode: nil, fieldErrors: [])
                }
                guard allowRetry,
                      attempt < Self.idempotentRetryAttempts,
                      Self.isRetryableStatus(http.statusCode) else {
                    return (data, http)
                }
            } catch {
                guard allowRetry,
                      attempt < Self.idempotentRetryAttempts,
                      NetworkError.shouldRetry(error, policy: .queueDelivery) else { throw error }
            }
            // A cancelled task must stop here rather than sleep through the cancellation.
            try await Task.sleep(nanoseconds: Self.idempotentRetryBackoff << (attempt - 1))
            attempt += 1
        }
    }

    private static func isRetryableStatus(_ statusCode: Int) -> Bool {
        guard statusCode != 401, statusCode != 403 else { return false }
        return NetworkError.shouldRetry(statusCode: statusCode, policy: .queueDelivery)
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
        // Keep the location-push extension's credential copy in step with the real token. Without
        // this the copy would be whatever the token was at the last telemetry start, so the first
        // push after a rotation would upload with a dead bearer and be answered with a 401 that
        // nobody is awake to see.
        Task { @MainActor in LocationPushRegistrar.shared.publishSharedCredential() }
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
            if let doubleValue = dict[key] as? Double { return Self.safeInt(doubleValue) }
            if let stringValue = dict[key] as? String, let parsed = Int(stringValue) { return parsed }
        }
        return nil
    }

    /// `Int(Double)` is a TRAPPING conversion: NaN, ±infinity and anything outside `Int64` crash the
    /// process rather than returning nil. `JSONSerialization` yields a finite-but-huge Double for an
    /// ordinary-looking literal like `1e19` or `1e30` (it rejects `1e400` outright, so infinity is
    /// not the reachable case — the large finite ones are). So one malformed number anywhere in a
    /// `/device/*` response — a backend serialization bug, a truncated body — killed the child's app
    /// every time it parsed that response. On a monitoring app a crash loop is not a glitch: it is
    /// monitoring silently switched off.
    ///
    /// Implemented with `Int(exactly:)` on the TRUNCATED value rather than a range comparison,
    /// because the obvious range check is itself wrong at the boundary: `Double(Int.max)` rounds UP
    /// to 9223372036854775808, one more than `Int.max`, so `value <= Double(Int.max)` admits a value
    /// that then traps. `Int(exactly:)` cannot trap and needs no boundary reasoning.
    ///
    /// An unusable number is treated as ABSENT, which every caller already handles (`intValue`
    /// returns an Optional precisely so a missing field is normal).
    static func safeInt(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        // `rounded(.towardZero)` preserves the old truncating behaviour for ordinary fractions.
        return Int(exactly: value.rounded(.towardZero))
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

    /// A NUMBER under any of `keys` — for values the backend may send either as a string or as a
    /// raw number (an epoch timestamp, typically). NSNull is rejected, and so is a JSON boolean:
    /// `true`/`false` bridge through NSNumber too, and a `false` read as `0` would look like a
    /// perfectly real value.
    private static func numberValue(_ dict: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            guard let number = dict[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            return number.doubleValue
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

    /// A server-generated notice rather than something a person typed.
    ///
    /// EITHER signal counts, which is what the Android child app does
    /// (`isSystem = sender == SYSTEM || systemKind != null`). iOS keyed only off the sender, so a
    /// row carrying a `systemKind` but no recognizable `senderType` — the shape an SOS or
    /// pairing notice arrives in — rendered as an ordinary white incoming bubble, i.e. as if the
    /// parent had typed it.
    var isSystemNotice: Bool { sender == .system || systemKind?.trimmedNonEmpty != nil }

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
    /// Cursor to pass back as `before` to load the next (older) page; nil at the head of history.
    /// Either the cursor the payload's `meta` carried, or — for the array shape, which has nowhere
    /// to put one — the oldest message id on the page, which `before` accepts just the same.
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
        let resolvedLimit = max(1, min(limit, 100))
        var query = [URLQueryItem(name: "limit", value: String(resolvedLimit))]
        if let before, !before.isEmpty {
            query.append(URLQueryItem(name: "before", value: before))
        }
        let data = try await requestJSON(path: "device/chat/messages", method: .get, query: query, authorized: true)
        return Self.parseChatPage(from: data, requestedLimit: resolvedLimit)
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

    /// Parses one page of chat history. `requestedLimit` is the `limit` the request asked for and
    /// is used only to decide whether the keyset fallback below applies; nil means "the caller did
    /// not say", which keeps the fallback enabled.
    static func parseChatPage(from data: Any, requestedLimit: Int? = nil) -> OilaChatPage {
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
        let messages = rawItems.compactMap { parseChatMessage($0) }
        // KEYSET FALLBACK. A server-sent cursor stays authoritative; this only covers its absence.
        // The likely shape of this endpoint's `data` is a BARE JSON ARRAY, which has nowhere to
        // carry paging meta — so the cursor was read out of an object that never existed, every
        // page reported `nextCursor == nil`, and the thread was permanently capped at its newest
        // page. `before` is documented as "messages older than this message id", so the oldest
        // message ON THIS PAGE is itself a valid cursor. Only a FULL page gets one: a short page is
        // already the head of the thread and a cursor there would only buy an empty extra request.
        if cursor == nil, requestedLimit.map({ rawItems.count >= $0 }) ?? true {
            cursor = oldestMessageID(in: messages)
        }
        return OilaChatPage(messages: messages, nextCursor: cursor)
    }

    /// The oldest message on a page — the keyset `before` value for the next request. History comes
    /// back newest-first, so that is normally the last row, but nothing in the (undocumented)
    /// schema guarantees the order: when every row carries a timestamp the oldest is resolved by
    /// date instead, and the positional read is kept only for a page that has none.
    private static func oldestMessageID(in messages: [OilaChatMessage]) -> String? {
        guard !messages.isEmpty else { return nil }
        let dated = messages.compactMap { message in message.createdAt.map { (message.id, $0) } }
        if dated.count == messages.count, let oldest = dated.min(by: { $0.1 < $1.1 }) {
            return oldest.0
        }
        return messages.last?.id
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
        // `item[key] != nil` is TRUE for an explicit JSON null — it decodes to NSNull, not nil — so
        // a plain text message carrying `"imageUrl": null, "readAt": null` claimed BOTH an image
        // attachment and a read receipt. Route both flags through the tolerant helpers, which
        // reject NSNull (and, for the string keys, an empty string).
        let hasImage = firstString(item, ["imageUrl", "image", "attachment"]) != nil
            || firstDictionary(item, ["image", "attachment"]) != nil
            || (boolValue(item, ["hasImage", "hasAttachment"]) ?? false)
        // `readAt` is a TIMESTAMP on an undocumented schema, so an epoch number is as likely as an
        // ISO string. Routing it through `firstString` alone fixed the NSNull bug but made the
        // numeric spelling read as unread — the child's message would then never show as seen.
        let readByPeer = firstString(item, ["readAt"]) != nil
            || (numberValue(item, ["readAt"]) ?? 0) > 0
            || (boolValue(item, ["readByPeer", "isReadByPeer", "read"]) ?? false)
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

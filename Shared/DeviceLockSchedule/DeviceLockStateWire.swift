import Foundation

// MARK: - `GET /device/lock/state`, read the same way in every process
//
// Moved here from the app (OilaDeviceAPI.swift / OilaTelemetryService.swift) in build 29 so the
// schedule-monitor extension can pull the lock policy itself (`DeviceLockStatePull`) and save
// EXACTLY the snapshot the app saves. One parser and one snapshot builder: the app's
// `OilaDeviceClient.parseLockState` and `OilaTelemetryService.lockPolicySnapshot` now forward here,
// unchanged in behaviour.

/// The tolerant JSON readers every `/device/*` parser uses (`OilaDeviceClient`'s private helpers
/// forward here). Compiled into the monitor extension too, so nothing here may touch app-only code.
enum OilaTolerantJSON {
    /// `String.trimmedNonEmpty` without the app's extension (not compiled into the extensions).
    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func firstString(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = nonEmpty(dict[key] as? String) { return value }
        }
        return nil
    }

    static func intValue(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let intValue = dict[key] as? Int { return intValue }
            if let doubleValue = dict[key] as? Double { return safeInt(doubleValue) }
            if let stringValue = dict[key] as? String, let parsed = Int(stringValue) { return parsed }
        }
        return nil
    }

    /// `Int(Double)` traps on NaN, ±infinity and anything outside `Int64`; see
    /// `OilaDeviceClient.safeInt` for the whole story. An unusable number reads as absent.
    static func safeInt(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }

    static func boolValue(_ dict: [String: Any], _ keys: [String]) -> Bool? {
        for key in keys {
            if let value = dict[key] as? Bool { return value }
            if let raw = nonEmpty(dict[key] as? String)?.lowercased() {
                if ["true", "1", "yes"].contains(raw) { return true }
                if ["false", "0", "no"].contains(raw) { return false }
            }
        }
        return nil
    }

    /// A NUMBER under any of `keys`; NSNull and JSON booleans are rejected.
    static func numberValue(_ dict: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            guard let number = dict[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            return number.doubleValue
        }
        return nil
    }

    static func firstArray(_ dict: [String: Any], _ keys: [String]) -> [[String: Any]]? {
        for key in keys {
            if let value = dict[key] as? [[String: Any]] { return value }
        }
        return nil
    }

    static func firstDictionary(_ dict: [String: Any], _ keys: [String]) -> [String: Any]? {
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

    static func date(_ dict: [String: Any], _ keys: [String]) -> Date? {
        for key in keys {
            if let raw = nonEmpty(dict[key] as? String) {
                if let parsed = isoFormatter.date(from: raw) { return parsed }
                let plain = ISO8601DateFormatter()
                if let parsed = plain.date(from: raw) { return parsed }
            }
        }
        return nil
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

/// What `manualLock` in `GET /device/lock/state` said. Three different answers that must not be
/// confused: the key missing (an old backend), `null` (no manual lock, running or future), and a
/// window. A present-but-unreadable value is kept apart too, so it is never read as "no lock".
enum OilaManualLockField: Equatable {
    case absent
    case null
    case window(DeviceLockManualWindow)
    case unreadable
}

/// Resolved lock state from `GET /device/lock/state` (`LockStateResponseDto`, parsed tolerantly).
///
/// The live payload carries two independent halves and both are preserved here: the WHOLE-DEVICE
/// lock and the PER-APP half (`lockedPackages`, `appLimits`). Since the backend contract of
/// 2026-09-23 the whole-device half is DATA, not a verdict: `manualLock` (a window with a start and
/// an end, a future one included), `schedules` (every schedule) and `serverTime`. The phone decides
/// from those by its own clock (`DeviceLockPolicy`), so it locks and opens on time with no internet;
/// `isLocked` is "kept for old child builds" and read only when neither `manualLock` nor
/// `serverTime` is present (`carriesLockPolicy`).
struct OilaLockState {
    /// The server's own verdict. Only the fallback for an old backend (see `carriesLockPolicy`) and
    /// a diagnostics cross-check; nil = the 200 response shape was not recognized at all.
    let isLocked: Bool?
    /// True only while the manual lock is RUNNING (a future window reads false); nil when absent.
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
    /// The schedule the SERVER found active when it answered, raw. Display only, through
    /// `resolvedScheduleRange()`: it goes stale offline, and the lock itself comes from `schedules`.
    let activeScheduleRaw: [String: Any]?
    /// `schedules[]` raw, for the same display fallback. The lock reads the typed `schedules`.
    let schedulesRaw: [[String: Any]]
    /// An explicit end under an old-backend spelling (`lockedUntil`; ISO-8601 or an epoch). Only the
    /// old-backend fallback reads it; the live payload's end is `manualLock.endsAt`.
    let lockedUntil: Date?
    /// `manualLock` — see `OilaManualLockField`.
    let manualLock: OilaManualLockField
    /// `schedules[]`, typed. nil = the key is absent; an unreadable row is dropped, never guessed.
    let schedules: [DeviceLockSchedule]?
    /// `serverTime`: the server's clock when it answered, for the clock anchor.
    let serverTime: Date?
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
        schedulesRaw: [[String: Any]] = [],
        lockedUntil: Date? = nil,
        manualLock: OilaManualLockField = .absent,
        schedules: [DeviceLockSchedule]? = nil,
        serverTime: Date? = nil
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
        self.lockedUntil = lockedUntil
        self.manualLock = manualLock
        self.schedules = schedules
        self.serverTime = serverTime
    }

    /// Whether the payload carries the lock POLICY (the 2026-09-23 contract). Decided by the keys
    /// only that contract has — `manualLock` (null or a window) and `serverTime`, both required in
    /// `LockStateResponseDto`. `schedules` is NOT one of them: the old backend already sent
    /// `schedules: []` (its only live sample did), and counting it made an old backend's parental
    /// lock (`isLocked: true`, no window) a snapshot that never locks. When neither key is present
    /// only `isLocked` can be read (`isDeviceLocked`).
    var carriesLockPolicy: Bool {
        manualLock != .absent || serverTime != nil
    }

    /// The OLD backend's whole-device verdict, resolved. Read only when the payload carries no lock
    /// policy (`carriesLockPolicy`); a current backend's payload is decided by `DeviceLockPolicy`.
    ///
    /// `isLocked` is authoritative here — on the old backend it already meant "the whole phone",
    /// the manual switch and the schedule window folded in — so whenever it is present it is
    /// returned untouched. The OR with `scheduleLocked` /
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
            if let value = OilaTolerantJSON.nonEmpty(dict[key] as? String) { return value }
        }
        return nil
    }

    /// Renders a minute-of-day (0...1439) as `"HH:mm"`, matching the format the string form of this
    /// field already arrives in. Out-of-range values are refused rather than wrapped: a schedule
    /// that says 25:00 is a payload we do not understand, and showing a wrong window on a lock
    /// screen is worse than showing none.
    static func timeFromMinuteOfDay(_ dict: [String: Any], _ keys: [String]) -> String? {
        guard let minute = minuteOfDay(dict, keys) else { return nil }
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    /// The first in-range minute-of-day under `keys`, whatever JSON type it arrived as.
    static func minuteOfDay(_ dict: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            let raw: Int?
            switch dict[key] {
            case let value as Int: raw = value
            // Trapping conversion — see `safeInt`. A schedule minute arriving as 1e400 would
            // otherwise crash the app on the lock screen, of all places.
            case let value as Double: raw = OilaTolerantJSON.safeInt(value)
            case let value as String: raw = Int(value.trimmingCharacters(in: .whitespaces))
            default: raw = nil
            }
            guard let minute = raw, (0 ... 1439).contains(minute) else { continue }
            return minute
        }
        return nil
    }
}

/// The tolerant `GET /device/lock/state` parser (`OilaDeviceClient.parseLockState` forwards here).
enum DeviceLockStateParser {
    /// Tolerant whole-payload read for `GET /device/lock/state` (`LockStateResponseDto`). The live
    /// response carries `isLocked` / `manualLockEnabled` / `manualLock` / `serverTime` /
    /// `scheduleLocked` / `deviceLocalTime` / `activeSchedule` / `lockedPackages` / `appLimits` /
    /// `schedules`. A key we don't recognize degrades to nil/empty instead of failing the whole
    /// parse: one surprising key must never cost us the rest of the state.
    static func parseLockState(from object: [String: Any]) -> OilaLockState {
        OilaLockState(
            isLocked: parseGlobalLock(from: object),
            raw: object,
            // NOT "manualLock": that key is the window object now, and reading it as a flag was
            // how a future window used to look like a running lock.
            manualLockEnabled: boolValue(object, ["manualLockEnabled", "manual_lock_enabled"]),
            scheduleLocked: boolValue(object, ["scheduleLocked", "isScheduleLocked", "schedule_locked"]),
            deviceLocalTime: firstString(object, ["deviceLocalTime", "device_local_time", "localTime", "deviceTime"]),
            lockedPackages: parseLockedPackages(from: object),
            appLimits: parseAppLimits(from: object),
            activeScheduleRaw: firstDictionary(object, ["activeSchedule", "active_schedule", "currentSchedule"]),
            schedulesRaw: firstArray(object, ["schedules", "lockSchedules", "schedule"]) ?? [],
            lockedUntil: parseLockedUntil(from: object),
            manualLock: parseManualLock(from: object),
            schedules: parseLockSchedules(from: object),
            serverTime: date(object, ["serverTime"])
        )
    }

    /// `manualLock`: absent, `null`, a `{startsAt, endsAt}` window (UTC ISO-8601), or unreadable.
    static func parseManualLock(from object: [String: Any]) -> OilaManualLockField {
        guard let value = object["manualLock"] else { return .absent }
        if value is NSNull { return .null }
        guard let window = value as? [String: Any],
              let startsAt = date(window, ["startsAt"]),
              let endsAt = date(window, ["endsAt"]) else {
            return .unreadable
        }
        return .window(DeviceLockManualWindow(startsAt: startsAt, endsAt: endsAt))
    }

    /// `schedules[]` as `LockScheduleDto` rows. The minutes and the bitmask are `number` in the spec
    /// and are read as Int or Double (or a numeric string, the tolerance every other number here
    /// gets). A row without a readable window or bitmask is DROPPED rather than guessed at — a
    /// guessed schedule locks a child at a time no parent chose. `enabled` defaults to true only
    /// when missing (the DTO requires it); any `deletedAt` other than null means deleted. nil when
    /// the key is absent; a `null` reads as no schedules.
    static func parseLockSchedules(from object: [String: Any]) -> [DeviceLockSchedule]? {
        guard let value = object["schedules"] else { return nil }
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let start = OilaLockState.minuteOfDay(row, ["startMinute"]),
                  let end = OilaLockState.minuteOfDay(row, ["endMinute"]),
                  let days = intValue(row, ["daysBitmask"]), days >= 0 else { return nil }
            var deletedAt: String?
            if let raw = row["deletedAt"], !(raw is NSNull) {
                deletedAt = (raw as? String) ?? String(describing: raw)
            }
            return DeviceLockSchedule(
                id: firstString(row, ["id"]),
                startMinute: start,
                endMinute: end,
                daysBitmask: days & 0x7F,
                enabled: boolValue(row, ["enabled"]) ?? true,
                deletedAt: deletedAt
            )
        }
    }

    /// An explicit end under an old-backend spelling, flat or inside a nested `global` / `lock`
    /// object. ISO-8601 (with or without fractional seconds) or an epoch number — seconds or
    /// milliseconds, told apart by magnitude. Deliberately NOT inside `manualLock`: that window's
    /// `endsAt` is the manual lock's end only, and reading it as "the lock's end" opened a phone
    /// whose SCHEDULE was still running and dropped a future window altogether.
    static func parseLockedUntil(from object: [String: Any]) -> Date? {
        let keys = [
            "lockedUntil", "locked_until", "lockUntil", "lock_until", "lockedUntilAt", "unlockAt", "unlock_at",
            "lockEndsAt", "lock_ends_at", "manualLockUntil", "manual_lock_until", "until"
        ]
        var scopes: [[String: Any]] = [object]
        for nested in ["global", "lock"] {
            if let dict = object[nested] as? [String: Any] { scopes.append(dict) }
        }
        for scope in scopes {
            if let parsed = date(scope, keys) { return parsed }
            if let epoch = numberValue(scope, keys), epoch > 0 {
                // 1e11 seconds is the year 5138; anything larger is milliseconds.
                return Date(timeIntervalSince1970: epoch > 100_000_000_000 ? epoch / 1000 : epoch)
            }
        }
        return nil
    }

    /// `lockedPackages` may arrive as bare identifier strings (what the live sample sends) or as
    /// objects carrying the identifier under one of the usual package-name spellings.
    static func parseLockedPackages(from object: [String: Any]) -> [String] {
        for key in ["lockedPackages", "locked_packages", "lockedApps", "blockedPackages"] {
            guard let value = object[key] else { continue }
            if let strings = value as? [String] {
                return strings.compactMap { OilaTolerantJSON.nonEmpty($0) }
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

    // The tolerant readers, under the names the parsers above were written against.
    private static func firstString(_ dict: [String: Any], _ keys: [String]) -> String? { OilaTolerantJSON.firstString(dict, keys) }
    private static func intValue(_ dict: [String: Any], _ keys: [String]) -> Int? { OilaTolerantJSON.intValue(dict, keys) }
    private static func boolValue(_ dict: [String: Any], _ keys: [String]) -> Bool? { OilaTolerantJSON.boolValue(dict, keys) }
    private static func numberValue(_ dict: [String: Any], _ keys: [String]) -> Double? { OilaTolerantJSON.numberValue(dict, keys) }
    private static func firstArray(_ dict: [String: Any], _ keys: [String]) -> [[String: Any]]? { OilaTolerantJSON.firstArray(dict, keys) }
    private static func firstDictionary(_ dict: [String: Any], _ keys: [String]) -> [String: Any]? { OilaTolerantJSON.firstDictionary(dict, keys) }
    private static func date(_ dict: [String: Any], _ keys: [String]) -> Date? { OilaTolerantJSON.date(dict, keys) }
}

// MARK: - The snapshot one payload yields

extension DeviceLockPolicySnapshot {
    /// How long an OLD backend's bare `isLocked: true` (or build 24's saved lock on upgrade) is held
    /// with no word from the server: the 8 h product rule (PO, 2026-09-16), as a window with an end.
    static let legacyLockCeiling: TimeInterval = 8 * 3_600

    /// The snapshot one lock-state payload yields, or nil for a shape with no lock information at
    /// all (the saved snapshot is then KEPT: an unexpected shape must neither lock nor unlock).
    ///
    /// A current backend's payload is taken as data (`carriesLockPolicy`). An OLD backend's bare
    /// `isLocked` becomes a window from now to its `lockedUntil`, never more than 8 h — refreshed by
    /// every poll while online, so a longer lock keeps being enforced, and ending by itself offline
    /// (the 2026-09-16 rule) instead of the permanent lock this build exists to end; an old
    /// backend's `schedules: []` does not make it a current one. A `manualLock` that is present but
    /// unreadable counts as running only when `manualLockEnabled` says so. A window whose end is
    /// only that 8 h ceiling is marked `manualEndIsCeiling`, so the cover shows no sliding time.
    ///
    /// The app (`OilaTelemetryService.lockPolicySnapshot`) and the monitor extension
    /// (`DeviceLockStatePull`) both build their snapshot here.
    static func fromLockState(
        _ state: OilaLockState,
        dsn: String,
        anchor: DeviceLockClockAnchor,
        phoneZone: TimeZone = .current
    ) -> DeviceLockPolicySnapshot? {
        // "Now" in the trusted domain: the server's clock at the anchor (the phone's, with no serverTime).
        let now = anchor.wall.addingTimeInterval(anchor.offset)
        let heldWindow = DeviceLockManualWindow(startsAt: now, endsAt: now.addingTimeInterval(legacyLockCeiling))
        if state.carriesLockPolicy {
            let manual: DeviceLockManualWindow?
            switch state.manualLock {
            case let .window(window): manual = window
            case .unreadable: manual = state.manualLockEnabled == true ? heldWindow : nil
            case .null, .absent: manual = nil
            }
            return DeviceLockPolicySnapshot(
                dsn: dsn, manualLock: manual, schedules: state.schedules ?? [], serverTime: state.serverTime,
                receivedAt: anchor.wall, clock: anchor, isLegacy: false,
                // The held window's end is the phone's own ceiling, renewed by every poll.
                manualEndIsCeiling: manual != nil && state.manualLock == .unreadable ? true : nil,
                scheduleZoneSecondsFromGMT: DeviceLockPolicy.scheduleZoneSeconds(
                    deviceLocalTime: state.deviceLocalTime, serverTime: state.serverTime,
                    phoneSecondsFromGMT: state.serverTime.map { phoneZone.secondsFromGMT(for: $0) }
                )
            )
        }
        guard let legacyLocked = state.isDeviceLocked else { return nil }
        // A `lockedUntil` already past makes the window empty: the end the parent saw wins over a
        // flag that has not caught up.
        let manual = legacyLocked
            ? DeviceLockManualWindow(startsAt: now, endsAt: min(state.lockedUntil ?? heldWindow.endsAt, heldWindow.endsAt))
            : nil
        // Renewed by every poll, the ceiling is no end to show; a `lockedUntil` inside it is.
        let endIsCeiling = manual.map { window in state.lockedUntil.map { $0 > window.endsAt } ?? true }
        return DeviceLockPolicySnapshot(
            dsn: dsn, manualLock: manual, schedules: [], serverTime: nil,
            receivedAt: anchor.wall, clock: anchor, isLegacy: true, manualEndIsCeiling: endIsCeiling
        )
    }

    /// Whether `other` says the same thing about the lock — everything but when it was heard and
    /// the clock anchor it was heard against. A pull that changes nothing re-arms nothing.
    func hasSamePolicy(as other: DeviceLockPolicySnapshot?) -> Bool {
        guard let other else { return false }
        return dsn == other.dsn && manualLock == other.manualLock && schedules == other.schedules
            && isLegacy == other.isLegacy && manualEndIsCeiling == other.manualEndIsCeiling
            && scheduleZoneSecondsFromGMT == other.scheduleZoneSecondsFromGMT
    }
}

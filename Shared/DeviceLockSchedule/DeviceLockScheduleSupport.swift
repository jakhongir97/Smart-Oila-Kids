import DeviceActivity
import Foundation
import ManagedSettings
import os

enum DeviceLockManagedSettingsStoreName {
    static let runtime = "SmartOilaKidsLock"
    static let schedule = "SmartOilaKidsScheduleLock"
    static let limit = "SmartOilaKidsLimitLock"
    /// Server-driven per-app blocking and the whole-device shield
    /// (`BlockedApplicationsController`). A store of its own because iOS composes stores by taking
    /// the most restrictive result, while two writers sharing one store overwrite each other.
    static let enforcement = "SmartOilaKidsEnforcement"
}

enum DeviceLockScheduleActivityIdentifier {
    static let prefix = "smartoila.global-lock.schedule"

    static func rawValue(dsn: String, suffix: String) -> String {
        "\(prefix).\(normalizedDSN(dsn)).\(suffix)"
    }

    static func isScheduleActivity(rawValue: String) -> Bool {
        rawValue.hasPrefix(prefix)
    }

    static func dsn(from rawValue: String) -> String? {
        let prefixValue = prefix + "."
        guard rawValue.hasPrefix(prefixValue),
              let suffixSeparatorIndex = rawValue.lastIndex(of: ".") else {
            return nil
        }

        let startIndex = rawValue.index(rawValue.startIndex, offsetBy: prefixValue.count)
        guard startIndex < suffixSeparatorIndex else { return nil }
        return String(rawValue[startIndex ..< suffixSeparatorIndex]).nilIfEmpty
    }

    private static func normalizedDSN(_ dsn: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = dsn.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "_"
        }
        return String(sanitized).lowercased()
    }
}

enum DeviceAppLimitActivityIdentifier {
    private static let prefix = "smartoila.app-limit"
    private static let separator = "|"

    static func rawValue(dsn: String) -> String {
        prefix + separator + normalizedDSN(dsn)
    }

    static func dsn(from rawValue: String) -> String? {
        let prefixValue = prefix + separator
        guard rawValue.hasPrefix(prefixValue) else { return nil }
        return String(rawValue.dropFirst(prefixValue.count)).nilIfEmpty
    }

    static func isAppLimitActivity(rawValue: String) -> Bool {
        rawValue.hasPrefix(prefix + separator)
    }

    private static func normalizedDSN(_ dsn: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = dsn.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "_"
        }
        return String(sanitized).lowercased()
    }
}

enum DeviceAppLimitEventIdentifier {
    private static let prefix = "smartoila.app-limit.event"
    private static let separator = "|"

    static func rawValue(packageName: String) -> String {
        prefix + separator + normalizedIdentifier(packageName)
    }

    static func packageName(from rawValue: String) -> String? {
        let prefixValue = prefix + separator
        guard rawValue.hasPrefix(prefixValue) else { return nil }
        return String(rawValue.dropFirst(prefixValue.count)).nilIfEmpty
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

// MARK: - The whole-device lock policy (build 26, 2026-09-24)
//
// The backend contract of 2026-09-23 (Akramjon): `GET /device/lock/state` now carries the parent's
// manual window (`manualLock {startsAt, endsAt} | null`, a FUTURE window included), every schedule
// (`schedules[]`) and the server clock (`serverTime`), and says outright that `isLocked` is "kept
// for old child builds". The bug it exists to end: the app saved the server's `isLocked` and locked
// by it, so a phone that lost the internet while locked never heard the `false` and stayed locked.
// The product rule it serves (PO, 2026-09-16): the child's phone always has a start and an end.
//
// So the phone decides by itself, from the last data it heard and its own clock, with no server:
// locked iff a manual window is running or a schedule is active. Everything below is shared by the
// app and the schedule-monitor extension — the one process iOS wakes at an edge when the app is
// dead — so the two can never disagree about what the rule says.

/// The parent's manual lock: one window with a start and an end (`ManualLockWindowDto`).
struct DeviceLockManualWindow: Codable, Equatable {
    let startsAt: Date
    let endsAt: Date

    /// The backend refuses a window longer than 8 h (`PUT /parent/children/{id}/lock/manual`, D-122).
    /// The phone enforces the same ceiling on what it RECEIVES — plus a minute for the backend's own
    /// "startsAt may be up to 1 minute in the past" — so no payload, however malformed, can lock a
    /// child for longer. The 8 h rule is the manual window's only: schedules are recurring rules the
    /// parent set on purpose, and they decide offline for as long as they say.
    static let maximumLength: TimeInterval = 8 * 3_600 + 60

    /// The window as enforced, half-open (`startsAt <= now < endsAt`), end clamped. nil when the
    /// window is inverted or empty: a window we cannot read locks nothing (schedules still apply).
    var enforced: Range<Date>? {
        guard endsAt > startsAt else { return nil }
        return startsAt ..< min(endsAt, startsAt.addingTimeInterval(Self.maximumLength))
    }
}

/// One row of `schedules[]` (`LockScheduleDto`).
///
/// Minutes are in the PHONE's current time zone (the spec's "device timezone"; the phone's own zone
/// is the only one it can evaluate offline, and a zone change re-evaluates at once). `endMinute` is
/// exclusive; `endMinute < startMinute` crosses midnight. `daysBitmask` has Monday at bit 0, and a
/// bit names the day a window STARTS: a Friday 22:00–07:00 window locks Saturday until 07:00 even
/// when Saturday's bit is off.
struct DeviceLockSchedule: Codable, Equatable {
    var id: String?
    var startMinute: Int
    var endMinute: Int
    var daysBitmask: Int
    var enabled: Bool
    /// The server's `deletedAt`, verbatim. Any value at all means deleted.
    var deletedAt: String?

    /// Whether this row can lock at all. `start == end` is INACTIVE: the parent API accepts it and
    /// "all day" and "never" are equally plausible readings, so it is read as the one that cannot
    /// lock a child by surprise (the same convention `DeviceLockScheduleMonitorController` used).
    var isEnforceable: Bool {
        enabled
            && deletedAt == nil
            && daysBitmask & 0x7F != 0
            && startMinute != endMinute
            && (0 ..< 1_440).contains(startMinute)
            && (0 ..< 1_440).contains(endMinute)
    }

    /// `weekdayIndex` is Monday = 0 … Sunday = 6; `minute` is the local minute of the day.
    func isActive(weekdayIndex today: Int, minute: Int) -> Bool {
        guard isEnforceable else { return false }
        let todayBit = (daysBitmask >> today) & 1 == 1
        if startMinute < endMinute {
            return todayBit && startMinute <= minute && minute < endMinute
        }
        let yesterdayBit = (daysBitmask >> ((today + 6) % 7)) & 1 == 1
        return (todayBit && minute >= startMinute) || (yesterdayBit && minute < endMinute)
    }
}

/// Where the phone's clock stood against the server's at the last successful poll.
///
/// The child owns the wall clock: moving it forward would end a lock early, moving it back would
/// start a schedule late. The monotonic clock (`CLOCK_MONOTONIC`, which on Darwin keeps counting
/// while the phone sleeps — `ProcessInfo.systemUptime` does not) cannot be set, so "server time at
/// the anchor + monotonic time elapsed since" is a clock the child cannot move for as long as the
/// phone does not reboot. That is Akramjon's optional point 4.
struct DeviceLockClockAnchor: Codable, Equatable {
    /// The phone's wall clock at the midpoint of the request that carried `serverTime`.
    let wall: Date
    /// `CLOCK_MONOTONIC` at the same instant, nanoseconds.
    let monotonicNanos: UInt64
    /// `serverTime - wall`, seconds. 0 when the server sent no time (the anchor still pins the
    /// phone's own clock against later changes).
    let offset: TimeInterval
    /// `kern.bootsessionuuid` when readable: a per-boot identity that, unlike the monotonic value,
    /// cannot collide with a later boot that has simply been up longer.
    let bootSessionID: String?
}

/// Everything the phone last heard about the whole-device lock, saved in the App Group so the app
/// (any launch, scene or not) and the extension evaluate the same data.
struct DeviceLockPolicySnapshot: Codable, Equatable {
    /// Normalized (`DeviceLockEdgeActivityIdentifier.normalize`): the form the edge names carry.
    let dsn: String
    let manualLock: DeviceLockManualWindow?
    let schedules: [DeviceLockSchedule]
    /// The server's clock when the payload was read; nil from an old backend or a migration.
    let serverTime: Date?
    /// The phone's wall clock when it was received. Diagnostics.
    let receivedAt: Date
    let clock: DeviceLockClockAnchor?
    /// Built from an old-backend payload that carried only `isLocked` (see
    /// `OilaTelemetryService.lockPolicySnapshot`), or from build 24's saved lock on upgrade.
    let isLegacy: Bool
    /// True when `manualLock.endsAt` is only the phone's own 8 h ceiling on a legacy lock, not an
    /// end anyone set. It still ends the lock offline, but the cover does not promise it: against
    /// an old backend it is renewed by every poll, so a shown time would slide forward every 30 s
    /// (build 25 showed only the server's own end, for the same reason). nil in older saves.
    var manualEndIsCeiling: Bool? = nil
    /// The UTC offset of the zone the SERVER evaluates schedules in — the device timezone captured at
    /// pairing (api.json LockScheduleDto: "startMinute: Minutes from midnight, device timezone").
    /// Derived from the payload's own `deviceLocalTime` + `serverTime` (see
    /// `scheduleZoneSeconds(deviceLocalTime:serverTime:)`), because no DTO carries the zone itself.
    /// Schedules are read in this zone, so a child who switches the phone to a zone ten hours away
    /// cannot move the night lock to the afternoon — and the phone agrees with the server's own
    /// `scheduleLocked` minute for minute. nil (older saves, old backends) = the phone's zone.
    var scheduleZoneSecondsFromGMT: Int? = nil
}

/// The pure rule. No state, no clock of its own: `now` and the calendar are always passed in, so a
/// test can pin a zone (and a DST change) and the extension can evaluate at an edge's own minute.
enum DeviceLockPolicy {
    /// How far ahead `episodeEnd` looks for the end of a lock. A week plus a day covers every
    /// weekly schedule pattern; a lock with no end inside it shows no "until" line.
    static let episodeSearchHorizon: TimeInterval = 8 * 86_400

    /// The phone's calendar for the rule: Gregorian (a Buddhist or Islamic `Calendar.current` must not
    /// change which weekday bit applies) in the phone's CURRENT zone, followed live.
    static func phoneCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    /// The calendar the rule reads SCHEDULES with: Gregorian in the server's device zone when the
    /// snapshot knows it, else `phone`'s zone. Manual windows are absolute instants and do not care.
    static func ruleCalendar(for snapshot: DeviceLockPolicySnapshot?, phone: Calendar) -> Calendar {
        guard let seconds = snapshot?.scheduleZoneSecondsFromGMT,
              let zone = TimeZone(secondsFromGMT: seconds) else { return phone }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// The device zone's UTC offset, from the lock-state payload's `deviceLocalTime` ("HH:mm in the
    /// device timezone") and `serverTime` (the same instant in UTC). Rounded to the nearest 15
    /// minutes, which absorbs the payload's minute boundary and covers every real zone (±14 h).
    /// nil when either is missing or malformed.
    static func scheduleZoneSeconds(deviceLocalTime: String?, serverTime: Date?) -> Int? {
        guard let deviceLocalTime, let serverTime else { return nil }
        let parts = deviceLocalTime.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0 ..< 24).contains(hour), (0 ..< 60).contains(minute) else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let serverParts = utc.dateComponents([.hour, .minute, .second], from: serverTime)
        let serverMinutes = Double((serverParts.hour ?? 0) * 60 + (serverParts.minute ?? 0))
            + Double(serverParts.second ?? 0) / 60
        var delta = Double(hour * 60 + minute) - serverMinutes
        // Into (-12 h, +14 h], the range real zones live in.
        while delta <= -12 * 60 { delta += 1_440 }
        while delta > 14 * 60 { delta -= 1_440 }
        let quarters = (delta / 15).rounded()
        return Int(quarters) * 15 * 60
    }

    /// Monday = 0 … Sunday = 6, from `Calendar`'s Sunday = 1 … Saturday = 7.
    static func weekdayIndex(calendarWeekday: Int) -> Int {
        (calendarWeekday + 5) % 7
    }

    /// THE RULE: locked iff `startsAt <= now < endsAt` for the (clamped) manual window, or any
    /// enforceable schedule is active at the phone's local weekday and minute. No snapshot = no lock.
    static func isLocked(at date: Date, snapshot: DeviceLockPolicySnapshot?, calendar: Calendar) -> Bool {
        guard let snapshot else { return false }
        return evaluate(at: date, snapshot: snapshot, calendar: gregorian(in: calendar.timeZone))
    }

    /// The end of the CURRENT contiguous locked episode — a manual window and the schedules that
    /// overlap or abut it are one episode, because the phone does not open between them. nil when
    /// unlocked, or when no end exists inside `episodeSearchHorizon`.
    static func episodeEnd(at date: Date, snapshot: DeviceLockPolicySnapshot?, calendar: Calendar) -> Date? {
        guard isLocked(at: date, snapshot: snapshot, calendar: calendar) else { return nil }
        return edges(after: date, horizon: episodeSearchHorizon, snapshot: snapshot, calendar: calendar).first
    }

    /// Every instant in `(date, date + horizon]` at which the rule's answer CHANGES, ascending.
    ///
    /// Built as "candidate instants, kept where the answer flips", so correctness never depends on
    /// predicting which boundaries matter: a schedule that starts inside a running manual window,
    /// two schedules that abut, a window that crosses midnight — none produce a false edge. The
    /// candidates are the manual window's two ends, every schedule start/end minute on every local
    /// day in range (BOTH occurrences on a DST fall-back night, none inside a spring-forward gap),
    /// and the zone's DST transitions themselves (where a skipped start minute takes effect).
    static func edges(after date: Date, horizon: TimeInterval, snapshot: DeviceLockPolicySnapshot?, calendar: Calendar) -> [Date] {
        guard let snapshot, horizon > 0 else { return [] }
        let calendar = gregorian(in: calendar.timeZone)
        let through = date.addingTimeInterval(horizon)
        let candidates = Set(candidateInstants(after: date, through: through, snapshot: snapshot, calendar: calendar)).sorted()
        var state = evaluate(at: date, snapshot: snapshot, calendar: calendar)
        var result: [Date] = []
        for instant in candidates {
            let next = evaluate(at: instant, snapshot: snapshot, calendar: calendar)
            guard next != state else { continue }
            result.append(instant)
            state = next
        }
        return result
    }

    /// The whole-device lock on the OS: the two category keys on the DEFAULT store, and only those.
    ///
    /// Plain `.all()`: the always-allowed exception set was removed with its Settings row (PO,
    /// 2026-09-21 — the parent controls blocking from the web, the child phone has no switches), so
    /// a stale `.all(except:)` from an earlier build is rewritten to `.all()` here. Only the default
    /// store enforces on this hardware (named stores measured inert). `shield.applications` — the
    /// per-app blocks — is never touched: they outlive a whole-device lock, and
    /// `BlockedApplicationsController` owns them. Read-compare-write, because the app calls this on
    /// every re-evaluation and the extension at every edge, and each write is a cross-process call.
    /// Returns whether anything was written.
    @discardableResult
    static func applyWholeDevice(locked: Bool, store: ManagedSettingsStore? = nil) -> Bool {
        let store = store ?? ManagedSettingsStore()
        let applications: ShieldSettings.ActivityCategoryPolicy<Application>? = locked ? .all() : nil
        let webDomains: ShieldSettings.ActivityCategoryPolicy<WebDomain>? = locked ? .all() : nil
        var wrote = false
        if store.shield.applicationCategories != applications {
            store.shield.applicationCategories = applications
            wrote = true
        }
        if store.shield.webDomainCategories != webDomains {
            store.shield.webDomainCategories = webDomains
            wrote = true
        }
        return wrote
    }

    // MARK: Private

    private static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func evaluate(at date: Date, snapshot: DeviceLockPolicySnapshot, calendar: Calendar) -> Bool {
        if let window = snapshot.manualLock?.enforced, window.contains(date) { return true }
        guard snapshot.schedules.contains(where: \.isEnforceable) else { return false }
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday, let hour = components.hour, let minute = components.minute else {
            return false
        }
        let index = weekdayIndex(calendarWeekday: weekday)
        let minuteOfDay = hour * 60 + minute
        return snapshot.schedules.contains { $0.isActive(weekdayIndex: index, minute: minuteOfDay) }
    }

    private static func candidateInstants(
        after start: Date,
        through end: Date,
        snapshot: DeviceLockPolicySnapshot,
        calendar: Calendar
    ) -> [Date] {
        var result: [Date] = []
        if let window = snapshot.manualLock?.enforced {
            result += [window.lowerBound, window.upperBound]
        }
        let minutes = Set(snapshot.schedules.filter(\.isEnforceable).flatMap { [$0.startMinute, $0.endMinute] })
        if !minutes.isEmpty, var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: start)) {
            let lastDay = end.addingTimeInterval(86_400)
            // Bounded: 8 days is the longest horizon anyone asks for; the cap only guards a caller bug.
            var remaining = 400
            while day <= lastDay, remaining > 0 {
                let components = calendar.dateComponents([.year, .month, .day], from: day)
                if let year = components.year, let month = components.month, let dayOfMonth = components.day {
                    for minute in minutes {
                        result += localInstants(year: year, month: month, day: dayOfMonth, minute: minute, timeZone: calendar.timeZone)
                    }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                remaining -= 1
            }
            var cursor = start
            while let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: cursor), transition <= end {
                result.append(transition)
                cursor = transition
            }
        }
        return result.filter { $0 > start && $0 <= end }
    }

    /// Every instant whose local wall time in `timeZone` is `year-month-day minute`: one on an
    /// ordinary day, two in a DST fall-back hour, none in a spring-forward gap. Solved per UTC
    /// offset the zone uses around that day, keeping only the self-consistent answers.
    private static func localInstants(year: Int, month: Int, day: Int, minute: Int, timeZone: TimeZone) -> [Date] {
        guard let midnight = utcCalendar.date(from: DateComponents(year: year, month: month, day: day)) else { return [] }
        let wall = midnight.addingTimeInterval(TimeInterval(minute * 60))
        let offsets = Set([-86_400.0, 0, 86_400].map { timeZone.secondsFromGMT(for: wall.addingTimeInterval($0)) })
        return offsets.compactMap { offset in
            let instant = wall.addingTimeInterval(TimeInterval(-offset))
            return timeZone.secondsFromGMT(for: instant) == offset ? instant : nil
        }
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()
}

/// The phone's clocks, injectable so a test can move the wall clock and the monotonic clock
/// independently — which is exactly what a child changing the date does.
struct DeviceLockClock {
    var wallNow: () -> Date
    var monotonicNanos: () -> UInt64
    var bootSessionID: () -> String?

    /// `|wall - trusted|` above this is logged as a changed clock. Two minutes: well above the
    /// offset's own error (half a round trip plus the server's drift), well below any change a
    /// child would bother making.
    static let tamperThreshold: TimeInterval = 120

    static var live: DeviceLockClock {
        DeviceLockClock(
            wallNow: { Date() },
            // Darwin's CLOCK_MONOTONIC keeps counting while the phone sleeps and cannot be set.
            monotonicNanos: { clock_gettime_nsec_np(CLOCK_MONOTONIC) },
            bootSessionID: { DeviceLockClock.readBootSessionID() }
        )
    }

    /// The server's clock carried forward: `anchor.wall + (monotonic now - anchor monotonic) +
    /// offset` while the phone has not rebooted since the anchor; `wall now + offset` after a reboot
    /// (the monotonic clock restarted, so only the phone's wall clock is left to carry the offset);
    /// the plain wall clock when there is no anchor at all.
    func trustedNow(anchor: DeviceLockClockAnchor?) -> Date {
        Self.trustedNow(anchor: anchor, wall: wallNow(), monotonicNanos: monotonicNanos(), bootSessionID: bootSessionID())
    }

    static func trustedNow(anchor: DeviceLockClockAnchor?, wall: Date, monotonicNanos: UInt64, bootSessionID: String?) -> Date {
        guard let anchor else { return wall }
        guard isSameBoot(anchor: anchor, monotonicNanos: monotonicNanos, bootSessionID: bootSessionID) else {
            return wall.addingTimeInterval(anchor.offset)
        }
        let elapsed = TimeInterval(monotonicNanos - anchor.monotonicNanos) / 1_000_000_000
        return anchor.wall.addingTimeInterval(elapsed + anchor.offset)
    }

    /// A monotonic value below the anchor's is a reboot (the clock restarted from zero). When both
    /// sides carry a boot-session id it decides outright: a later boot that has simply been up
    /// longer than the anchor's would otherwise pass the monotonic test and put the clock hours back.
    static func isSameBoot(anchor: DeviceLockClockAnchor, monotonicNanos: UInt64, bootSessionID: String?) -> Bool {
        guard monotonicNanos >= anchor.monotonicNanos else { return false }
        if let recorded = anchor.bootSessionID, let current = bootSessionID {
            return recorded == current
        }
        return true
    }

    /// The longest round trip whose midpoint is trusted. The received time is read when the code
    /// after `await fetchLockState()` runs, and iOS can suspend the app between the server's answer
    /// and that line for hours: the measured "round trip" is then the suspension, and its midpoint
    /// would put the offset off by half of it for the whole offline period after.
    static let maximumRoundTrip: TimeInterval = 10

    /// The anchor for one successful poll: both clocks at the request's midpoint, and the server's
    /// time against it. The midpoint halves the round trip's contribution to the offset's error.
    ///
    /// A round trip over `maximumRoundTrip` says only that the server's time was read somewhere
    /// between sending and receiving, so the true time at sending lies in `[serverTime - trip,
    /// serverTime]`. The phone's own estimate at sending (`previous` carried forward, or the wall
    /// clock) is kept when it lies in that range — `previous` itself, unchanged, while the phone
    /// has not rebooted — and otherwise moved to the nearest end of it.
    static func anchor(
        serverTime: Date?,
        sentWall: Date,
        sentMonotonicNanos: UInt64,
        receivedMonotonicNanos: UInt64,
        bootSessionID: String?,
        previous: DeviceLockClockAnchor? = nil
    ) -> DeviceLockClockAnchor {
        let trip = receivedMonotonicNanos >= sentMonotonicNanos ? receivedMonotonicNanos - sentMonotonicNanos : 0
        let tripSeconds = TimeInterval(trip) / 1_000_000_000
        guard tripSeconds > maximumRoundTrip else {
            let halfTrip = trip / 2
            let wall = sentWall.addingTimeInterval(TimeInterval(halfTrip) / 1_000_000_000)
            return DeviceLockClockAnchor(
                wall: wall,
                monotonicNanos: sentMonotonicNanos + halfTrip,
                offset: serverTime.map { $0.timeIntervalSince(wall) } ?? 0,
                bootSessionID: bootSessionID
            )
        }
        let prior = trustedNow(anchor: previous, wall: sentWall, monotonicNanos: sentMonotonicNanos, bootSessionID: bootSessionID)
        let atSend = serverTime.map { min(max(prior, $0.addingTimeInterval(-tripSeconds)), $0) } ?? prior
        if atSend == prior, let previous,
           isSameBoot(anchor: previous, monotonicNanos: sentMonotonicNanos, bootSessionID: bootSessionID) {
            return previous
        }
        return DeviceLockClockAnchor(
            wall: sentWall,
            monotonicNanos: sentMonotonicNanos,
            offset: atSend.timeIntervalSince(sentWall),
            bootSessionID: bootSessionID
        )
    }

    static func readBootSessionID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }
}

/// App Group copy of the policy, written by the app on every successful poll and read by both.
struct DeviceLockPolicySharedStore {
    static let snapshotKey = "DEVICE_LOCK_POLICY_V1"
    /// The instant the extension last evaluated an edge at. The extension may evaluate a few
    /// seconds AHEAD of the clock (an edge callback that fired early is evaluated at its edge), and
    /// the app, woken by the extension's notification, must not undo that in the gap.
    static let edgeEvaluatedAtKey = "DEVICE_LOCK_EDGE_EVALUATED_AT_V1"

    private let userDefaults: UserDefaults?

    init(userDefaults: UserDefaults? = ScreenTimeUsageAppGroup.sharedUserDefaults()) {
        self.userDefaults = userDefaults
    }

    func load() -> DeviceLockPolicySnapshot? {
        guard let data = userDefaults?.data(forKey: Self.snapshotKey) else { return nil }
        return try? JSONDecoder().decode(DeviceLockPolicySnapshot.self, from: data)
    }

    func save(_ snapshot: DeviceLockPolicySnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults?.set(data, forKey: Self.snapshotKey)
    }

    func clear() {
        userDefaults?.removeObject(forKey: Self.snapshotKey)
        userDefaults?.removeObject(forKey: Self.edgeEvaluatedAtKey)
    }

    func markEdgeEvaluated(at date: Date) {
        userDefaults?.set(date.timeIntervalSince1970, forKey: Self.edgeEvaluatedAtKey)
    }

    func lastEdgeEvaluatedAt() -> Date? {
        guard let raw = userDefaults?.object(forKey: Self.edgeEvaluatedAtKey) as? Double, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }
}

/// `smartoila.lock-edge|<normalized dsn>|<edge epoch minute>` — one one-off activity per edge.
///
/// Its own prefix: `DeviceLockScheduleMonitorController.stopCurrentMonitoring` sweeps every
/// `smartoila.global-lock.schedule*` activity, and a stop on a running activity delivers
/// `intervalDidEnd`. The minute in the name is what the extension evaluates at, so a callback that
/// fires a few seconds early still reads the edge it was armed for.
enum DeviceLockEdgeActivityIdentifier {
    static let prefix = "smartoila.lock-edge"
    private static let separator = "|"

    static func rawValue(dsn: String, edgeMinute: Int) -> String {
        prefix + separator + normalize(dsn) + separator + String(edgeMinute)
    }

    static func isLockEdgeActivity(rawValue: String) -> Bool {
        rawValue.hasPrefix(prefix + separator)
    }

    static func edgeMinute(from rawValue: String) -> Int? {
        guard isLockEdgeActivity(rawValue: rawValue), let last = rawValue.split(separator: "|").last else { return nil }
        return Int(last)
    }

    /// The canonical DSN form (the separator and every other non-identifier character become `_`,
    /// lowercased): a raw DSN is an UPPERCASE `UUID().uuidString`.
    static func normalize(_ dsn: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = dsn.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "_"
        }
        return String(sanitized).lowercased()
    }
}

/// Build 24's single "lock-until" activity and its App Group record, kept only to retire them.
///
/// A phone updated while locked keeps build 24's activity armed until the app next runs. If it
/// fires in this build before the app has ever polled (no snapshot yet), the old promise still
/// holds: the lock ends at the recorded end, not later.
enum DeviceLockLegacyDeadline {
    static let activityPrefix = "smartoila.lock-until|"
    static let recordKey = "DEVICE_LOCK_DEADLINE_V1"
    static let releasedAtKey = "DEVICE_LOCK_DEADLINE_RELEASED_AT_V1"

    private struct Record: Decodable {
        let endsAt: Date
    }

    static func isLegacyActivity(rawValue: String) -> Bool {
        rawValue.hasPrefix(activityPrefix)
    }

    static func recordedEnd(userDefaults: UserDefaults? = ScreenTimeUsageAppGroup.sharedUserDefaults()) -> Date? {
        guard let data = userDefaults?.data(forKey: recordKey) else { return nil }
        return (try? JSONDecoder().decode(Record.self, from: data))?.endsAt
    }

    static func clear(userDefaults: UserDefaults? = ScreenTimeUsageAppGroup.sharedUserDefaults()) {
        userDefaults?.removeObject(forKey: recordKey)
        userDefaults?.removeObject(forKey: releasedAtKey)
    }
}

/// The DeviceActivity surface the edge monitoring needs. A protocol so tests never touch
/// `DeviceActivityCenter`.
protocol DeviceLockEdgeCenter {
    /// Every armed lock activity (edge or legacy lock-until), with its interval start on the
    /// phone's clock when the schedule can be read back.
    func lockActivities() -> [(name: String, start: Date?)]
    func start(name: String, schedule: DeviceActivitySchedule) throws
    func stop(names: [String])
}

struct LiveDeviceLockEdgeCenter: DeviceLockEdgeCenter {
    func lockActivities() -> [(name: String, start: Date?)] {
        let center = DeviceActivityCenter()
        return center.activities.compactMap { activity in
            let raw = activity.rawValue
            guard DeviceLockEdgeActivityIdentifier.isLockEdgeActivity(rawValue: raw)
                    || DeviceLockLegacyDeadline.isLegacyActivity(rawValue: raw) else { return nil }
            let start = center.schedule(for: activity).flatMap { Calendar.current.date(from: $0.intervalStart) }
            return (name: raw, start: start)
        }
    }

    func start(name: String, schedule: DeviceActivitySchedule) throws {
        try DeviceActivityCenter().startMonitoring(DeviceActivityName(name), during: schedule)
    }

    func stop(names: [String]) {
        guard !names.isEmpty else { return }
        DeviceActivityCenter().stopMonitoring(names.map { DeviceActivityName($0) })
    }
}

/// Arms the edges outside the app: the one mechanism that re-checks the lock when the app is
/// suspended or dead, which is precisely when a phone that lost the internet needs it.
///
/// One one-off activity per edge, `[edge, edge + 16 min]`, `repeats: false`, only its START
/// relied on (the callback measured on hardware, proof 7). Window length stops mattering: a
/// 14:00–14:05 lock is two activities, `[14:00, 14:16]` and `[14:05, 14:21]`. The extension never
/// locks or unlocks blindly on a callback: it re-evaluates the rule, so a restart, an early fire or
/// an edge the parent has since moved all come out right.
enum DeviceLockEdgeMonitoring {
    /// How far ahead edges are armed, and how many. 12 + one fallback stays well inside the ~20
    /// activities an app may hold (usage and app-limit take one each, plus a running edge or two).
    /// Beyond the horizon only the very next edge is armed, and only when none is inside it
    /// (`armable`): the chain must never run out.
    static let horizon: TimeInterval = 48 * 3_600
    static let maximumEdges = 12
    /// Edges closer than this are the in-app timer's; an activity starting within a minute is
    /// unmeasured (proof 7 armed two minutes ahead).
    static let minimumLead: TimeInterval = 60
    /// An armed activity the plan no longer wants is still left alone while it starts within this
    /// on the phone's clock. `plan` hands an edge under `minimumLead` away to the fallback, but the
    /// activity already armed for it is the precisely timed one, and stopping it (the fallback is
    /// up to two minutes late) gains nothing: the extension re-evaluates, never flips blindly.
    /// Rounded up to its minute on a phone up to the tamper threshold slow, such an edge still
    /// starts up to this far ahead. It also covers an `intervalDidStart` delivered up to
    /// `earlyCallbackTolerance` early, whose own activity must not be stopped by its own re-arm —
    /// that stop delivers an `intervalDidEnd` evaluated before the edge.
    static let imminentStart: TimeInterval = minimumLead + 60 + DeviceLockClock.tamperThreshold
    /// Apple refuses an interval shorter than 15 minutes.
    static let intervalLength: TimeInterval = 16 * 60
    /// An `intervalDidStart` up to this long before its edge is evaluated AT the edge (a callback a
    /// few seconds early must not read "not yet"). Further off than that it is not the edge's own
    /// callback — a clock moved forward fires every edge early — and is evaluated at the trusted now.
    static let earlyCallbackTolerance: TimeInterval = 180
    /// Posted after every extension evaluation (the name build 24's deadline release used).
    static let darwinNotification = "uz.smartoila.kids.lock-deadline-released"

    struct Entry: Equatable {
        let name: String
        /// The edge rounded UP to its minute, in trusted time: the name's minute, and never before
        /// the edge itself.
        let edgeMinute: Int
        /// Where the activity starts on the PHONE's clock, which is the clock DeviceActivity runs on.
        let wallStart: Date
        /// A re-check one minute out, armed when the very next edge is too close to arm.
        let isFallback: Bool
    }

    static func ceilingMinute(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.up))
    }

    /// The edges worth arming out of `edges` (ascending, all after `from`): every one within
    /// `horizon` — and when none is, still the first one, however far ahead.
    ///
    /// With the app dead only a lock-edge callback re-arms, so a plan with nothing in it ends the
    /// chain for good. A Mon–Fri 08:00–13:00 school schedule evaluated at Friday 13:00 has no flip
    /// for 67 h, and a 48 h cut alone left Monday's lock to the app happening to run in time. A
    /// one-off activity may start days ahead; only its interval length is limited.
    static func armable(_ edges: [Date], from: Date) -> [Date] {
        let near = edges.filter { $0.timeIntervalSince(from) <= horizon }
        return near.isEmpty ? Array(edges.prefix(1)) : near
    }

    /// What one evaluation sees ahead and arms for it.
    struct Outlook: Equatable {
        /// Every flip in `(evaluationTime, evaluationTime + DeviceLockPolicy.episodeSearchHorizon]`.
        /// While locked the first one is where the episode ends.
        let edges: [Date]
        let entries: [Entry]
    }

    /// The one planning path, shared by the app and the extension so the two can never arm
    /// differently: the edges after `evaluationTime` in the episode search horizon, and the entries
    /// for the `armable` ones, seen from the trusted `now` on the phone's clock.
    static func outlook(
        snapshot: DeviceLockPolicySnapshot,
        evaluationTime: Date,
        trustedNow: Date,
        wallNow: Date,
        calendar: Calendar
    ) -> Outlook {
        let edges = DeviceLockPolicy.edges(
            after: evaluationTime, horizon: DeviceLockPolicy.episodeSearchHorizon, snapshot: snapshot, calendar: calendar
        )
        let entries = plan(
            dsn: snapshot.dsn, edges: armable(edges, from: evaluationTime),
            now: trustedNow, skew: trustedNow.timeIntervalSince(wallNow)
        )
        return Outlook(edges: edges, entries: entries)
    }

    /// What to arm for `edges` (trusted time), seen from the trusted `now`.
    ///
    /// Edges less than `minimumLead` away are skipped — but when the VERY NEXT edge is one of them,
    /// one fallback re-check is armed a minute out, so a phone suspended in that minute still gets
    /// a re-check. `skew` is trusted minus wall: while it is under the tamper threshold the phone's
    /// clock is taken as right (no minute-rounding games for a second's drift); past it the edges
    /// are moved onto the phone's clock so they still fire at the TRUE time. The lead is checked on
    /// BOTH clocks: DeviceActivity sees the phone's, and a start it already sees as past is lazy
    /// (measured, proof 6), so an edge a phone running a little fast already shows as "now" counts
    /// as too close too.
    static func plan(dsn: String, edges: [Date], now: Date, skew: TimeInterval) -> [Entry] {
        let armingSkew = abs(skew) > DeviceLockClock.tamperThreshold ? skew : 0
        let wallNow = now.addingTimeInterval(-skew)
        func wallStart(_ minute: Int) -> Date {
            Date(timeIntervalSince1970: TimeInterval(minute) * 60).addingTimeInterval(-armingSkew)
        }
        func isArmable(_ edge: Date) -> Bool {
            edge.timeIntervalSince(now) >= minimumLead
                && wallStart(ceilingMinute(edge)).timeIntervalSince(wallNow) >= minimumLead
        }
        let upcoming = edges.filter { $0 > now }.sorted()
        var entries: [Entry] = []
        var names = Set<String>()
        func add(minute: Int, isFallback: Bool) {
            let name = DeviceLockEdgeActivityIdentifier.rawValue(dsn: dsn, edgeMinute: minute)
            guard names.insert(name).inserted else { return }
            entries.append(Entry(name: name, edgeMinute: minute, wallStart: wallStart(minute), isFallback: isFallback))
        }
        if let next = upcoming.first, !isArmable(next) {
            // The first whole minute a lead ahead on both clocks.
            let earliest = max(now, wallNow.addingTimeInterval(armingSkew)).addingTimeInterval(minimumLead)
            add(minute: ceilingMinute(earliest), isFallback: true)
        }
        var armedEdges = 0
        for edge in upcoming where isArmable(edge) {
            guard armedEdges < maximumEdges else { break }
            add(minute: ceilingMinute(edge), isFallback: false)
            armedEdges += 1
        }
        return entries.sorted { $0.edgeMinute < $1.edgeMinute }
    }

    static func schedule(for entry: Entry, calendar: Calendar = .current) -> DeviceActivitySchedule {
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        return DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(units, from: entry.wallStart),
            intervalEnd: calendar.dateComponents(units, from: entry.wallStart.addingTimeInterval(intervalLength)),
            repeats: false
        )
    }

    /// When an `intervalDidStart` for `activityName` is evaluated: `max(now, edge)` while the edge is
    /// within `earlyCallbackTolerance` ahead, else `now` (see there).
    static func evaluationTime(now: Date, activityName: String) -> Date {
        guard let minute = DeviceLockEdgeActivityIdentifier.edgeMinute(from: activityName) else { return now }
        let edge = Date(timeIntervalSince1970: TimeInterval(minute) * 60)
        guard edge > now, edge.timeIntervalSince(now) <= earlyCallbackTolerance else { return now }
        return edge
    }

    struct ArmResult: Equatable {
        var started: [String] = []
        var stopped: [String] = []
        var failures = 0
    }

    /// Bring the armed set to `entries`, touching only what differs.
    ///
    /// An already-armed entry starting within a minute of where it should is left alone (a restart
    /// is a spurious callback pair). Undesired activities are stopped only when they start more
    /// than `imminentStart` ahead or are long over: stopping a RUNNING one delivers an
    /// `intervalDidEnd` for nothing, and it ends by itself sixteen minutes after its edge; an
    /// imminent one is the edge's precisely timed re-check (see `imminentStart`). Build 24's
    /// lock-until is always stopped.
    @discardableResult
    static func arm(_ entries: [Entry], center: DeviceLockEdgeCenter, wallNow: Date, calendar: Calendar = .current) -> ArmResult {
        var result = ArmResult()
        let armed = center.lockActivities()
        let desired = Set(entries.map(\.name))
        var toStop: [String] = []
        for activity in armed {
            if DeviceLockLegacyDeadline.isLegacyActivity(rawValue: activity.name) {
                toStop.append(activity.name)
                continue
            }
            guard !desired.contains(activity.name) else { continue }
            guard let start = activity.start else {
                toStop.append(activity.name)
                continue
            }
            let ahead = start.timeIntervalSince(wallNow)
            if ahead > imminentStart || -ahead > intervalLength {
                toStop.append(activity.name)
            }
        }
        var toStart: [Entry] = []
        for entry in entries {
            if let existing = armed.first(where: { $0.name == entry.name }) {
                if let start = existing.start, abs(start.timeIntervalSince(entry.wallStart)) < 60 { continue }
                toStop.append(entry.name)
            }
            toStart.append(entry)
        }
        if !toStop.isEmpty {
            center.stop(names: toStop)
            result.stopped = toStop
        }
        for entry in toStart {
            do {
                try center.start(name: entry.name, schedule: schedule(for: entry, calendar: calendar))
                result.started.append(entry.name)
            } catch {
                result.failures += 1
                log.error("lock_edge arm_failed edge_minute=\(entry.edgeMinute, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
        return result
    }

    /// Unpair: nothing of the old family's may fire on this phone.
    static func stopAll(center: DeviceLockEdgeCenter) {
        let names = center.lockActivities().map(\.name)
        center.stop(names: names)
    }

    static func postDidEvaluate() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinNotification as CFString),
            nil,
            nil,
            true
        )
    }

    static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime")
}

enum DeviceLockManagedSettingsStoreFactory {
    static func make(named name: String) -> ManagedSettingsStore {
        if #available(iOS 16.0, *) {
            return ManagedSettingsStore(named: .init(name))
        }
        return ManagedSettingsStore()
    }

    static func clearAllSettings(_ store: ManagedSettingsStore) {
        if #available(iOS 16.0, *) {
            store.clearAllSettings()
            return
        }

        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

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

// MARK: - The lock deadline (2026-09-18)

/// The whole-device lock's END, shared between the app and the schedule-monitor extension.
///
/// The product rule (PO, 2026-09-16): a phone lock never lasts more than 8 hours, the parent
/// chooses from-when to-when, and the child's phone must unlock BY ITSELF at the end even when it
/// has no internet. The app enforces the end while it is alive (`OilaTelemetryService`); this
/// record is how the extension enforces it when the app is not — the extension is the only
/// process iOS promises to wake at the end of a `DeviceActivitySchedule`.
struct DeviceLockDeadlineRecord: Codable, Equatable {
    let dsn: String
    /// The instant the lock ends. Absolute, never a wall-clock "HH:mm": the schedule this arms
    /// is one-off and the release compares against the clock.
    let endsAt: Date
    /// When the app armed the activity for this end. Diagnostics only.
    let armedAt: Date
}

/// One activity per DSN, under a prefix of its own. It must NOT share `smartoila.global-lock.schedule`:
/// `DeviceLockScheduleMonitorController.stopCurrentMonitoring` sweeps every activity under that
/// prefix at every cold launch, and a stop on a running activity delivers `intervalDidEnd` — which
/// would read as "the lock ended" seconds after the app started.
enum DeviceLockDeadlineActivityIdentifier {
    private static let prefix = "smartoila.lock-until"
    private static let separator = "|"

    static func rawValue(dsn: String) -> String {
        prefix + separator + normalizedDSN(dsn)
    }

    /// The canonical DSN form used in BOTH the activity name and the App Group record. A raw DSN is
    /// `UUID().uuidString` — UPPERCASE — and the activity name lowercases it; storing the raw form
    /// in the record while reading the lowercased form back out of the activity name is why an
    /// earlier revision never matched, so the record and every comparison go through this.
    static func normalize(_ dsn: String) -> String { normalizedDSN(dsn) }

    static func dsn(from rawValue: String) -> String? {
        let prefixValue = prefix + separator
        guard rawValue.hasPrefix(prefixValue) else { return nil }
        return String(rawValue.dropFirst(prefixValue.count)).nilIfEmpty
    }

    static func isDeadlineActivity(rawValue: String) -> Bool {
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

/// App Group copy of the armed deadline, plus the extension's "I released it" mark.
///
/// Both processes read and write it. The app writes the record when it arms the activity and
/// clears it when the server unlocks; the extension reads it to decide whether an `intervalDidEnd`
/// is the real end (iOS also delivers one when a running activity is restarted) and writes
/// `releasedAt` after it has cleared the shield, so a relaunched app can tell "the OS is still
/// shielded" from "the extension already opened the phone".
struct DeviceLockDeadlineSharedStore {
    static let recordKey = "DEVICE_LOCK_DEADLINE_V1"
    static let releasedAtKey = "DEVICE_LOCK_DEADLINE_RELEASED_AT_V1"
    /// Posted by the extension after a release, so an app that happens to be alive drops its
    /// cover at once instead of on its next timer tick.
    static let releasedDarwinNotification = "uz.smartoila.kids.lock-deadline-released"

    private let userDefaults: UserDefaults?

    init(userDefaults: UserDefaults? = ScreenTimeUsageAppGroup.sharedUserDefaults()) {
        self.userDefaults = userDefaults
    }

    func load() -> DeviceLockDeadlineRecord? {
        guard let data = userDefaults?.data(forKey: Self.recordKey) else { return nil }
        return try? JSONDecoder().decode(DeviceLockDeadlineRecord.self, from: data)
    }

    func save(_ record: DeviceLockDeadlineRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        userDefaults?.set(data, forKey: Self.recordKey)
        // A new arm supersedes any earlier release: the mark belongs to the deadline it released.
        userDefaults?.removeObject(forKey: Self.releasedAtKey)
    }

    func clear() {
        userDefaults?.removeObject(forKey: Self.recordKey)
        userDefaults?.removeObject(forKey: Self.releasedAtKey)
    }

    func markReleased(at date: Date) {
        userDefaults?.set(date.timeIntervalSince1970, forKey: Self.releasedAtKey)
    }

    func releasedAt() -> Date? {
        guard let raw = userDefaults?.object(forKey: Self.releasedAtKey) as? Double, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    static func postReleased() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(releasedDarwinNotification as CFString),
            nil,
            nil,
            true
        )
    }
}

/// Arms the one-off activity whose end is the lock's end, and releases the shield when it fires.
///
/// Shared by both processes on purpose: the extension's release and the app's launch-time release
/// must write exactly the same two keys, or the two halves of the lock disagree.
enum DeviceLockDeadlineMonitoring {
    typealias StartMonitoring = (DeviceActivityName, DeviceActivitySchedule) throws -> Void
    typealias StopMonitoring = ([DeviceActivityName]) -> Void

    /// Apple refuses a `DeviceActivitySchedule` shorter than 15 minutes.
    static let minimumIntervalLength: TimeInterval = 15 * 60
    /// The start is placed a little in the future, the shape proof 7 measured on device (a start
    /// already in the past is unmeasured). The lock itself is already enforced by the app; the
    /// activity exists only for its END.
    static let startLead: TimeInterval = 60
    /// The extension trusts an `intervalDidEnd` only when the recorded end is (nearly) here: iOS
    /// delivers the same callback when a running activity is restarted, and that must not open the
    /// phone. Five seconds covers the minute-granular schedule landing a hair early.
    static let releaseTolerance: TimeInterval = 5

    /// The interval to arm for a lock that ends at `endsAt`, as a pure function of the clock.
    ///
    /// The end is never EARLIER than the lock's end; when the lock ends sooner than iOS allows an
    /// interval to be, the activity ends at the minimum and the extension releases late by that
    /// much — while the app, when alive, releases on time from its own timer. Documented cost.
    static func plannedInterval(endsAt: Date, now: Date) -> (start: Date, end: Date) {
        let start = now.addingTimeInterval(startLead)
        let end = max(endsAt, start.addingTimeInterval(minimumIntervalLength + startLead))
        return (start, end)
    }

    /// A deadline that moved by less than this is not re-armed. A `startMonitoring` on the running
    /// activity makes iOS deliver `intervalDidEnd` + `intervalDidStart` (measured 2026-09-16), so
    /// every re-arm is one spurious end for the extension to recognise and ignore — and an end
    /// derived from the server's minute-precision `deviceLocalTime` can jitter by a minute from
    /// one poll to the next. Two minutes late, in the app-is-dead case only, is the cost.
    static let rearmTolerance: TimeInterval = 120

    /// Re-arm only when the deadline actually moved (see `rearmTolerance`).
    static func shouldArm(existing: DeviceLockDeadlineRecord?, dsn: String, endsAt: Date) -> Bool {
        guard let existing, existing.dsn == dsn else { return true }
        return abs(existing.endsAt.timeIntervalSince(endsAt)) > rearmTolerance
    }

    /// Whether an `intervalDidEnd` for the deadline activity is the real end.
    static func isReleaseDue(record: DeviceLockDeadlineRecord?, dsn: String, now: Date) -> Bool {
        guard let record, record.dsn == dsn else { return false }
        return now.timeIntervalSince(record.endsAt) >= -releaseTolerance
    }

    static func schedule(endsAt: Date, now: Date, calendar: Calendar = .current) -> DeviceActivitySchedule {
        let interval = plannedInterval(endsAt: endsAt, now: now)
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        return DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(units, from: interval.start),
            intervalEnd: calendar.dateComponents(units, from: interval.end),
            repeats: false
        )
    }

    /// Arm (or leave armed) the activity for `dsn` ending at `endsAt`. Returns true when a new
    /// activity was started.
    @discardableResult
    static func arm(
        dsn rawDSN: String,
        endsAt: Date,
        now: Date = Date(),
        store: DeviceLockDeadlineSharedStore = DeviceLockDeadlineSharedStore(),
        start: StartMonitoring? = nil
    ) throws -> Bool {
        // Normalize to the exact form the activity name carries, so the record the extension reads
        // back (keyed on the DSN it parses OUT of the activity name) always matches.
        let dsn = DeviceLockDeadlineActivityIdentifier.normalize(rawDSN)
        guard shouldArm(existing: store.load(), dsn: dsn, endsAt: endsAt) else { return false }
        let center = DeviceActivityCenter()
        let startMonitoring = start ?? { name, schedule in
            try center.startMonitoring(name, during: schedule)
        }
        let activity = DeviceActivityName(DeviceLockDeadlineActivityIdentifier.rawValue(dsn: dsn))
        // The record is written FIRST: if the start throws, the record says what was intended and
        // the next arm retries it; if the callback fires before the write, the extension would
        // find no record and (correctly) refuse to release.
        store.save(DeviceLockDeadlineRecord(dsn: dsn, endsAt: endsAt, armedAt: now))
        do {
            try startMonitoring(activity, schedule(endsAt: endsAt, now: now))
        } catch {
            store.clear()
            throw error
        }
        log.notice(
            "lock_deadline armed dsn_present=1 ends_at=\(Int(endsAt.timeIntervalSince1970), privacy: .public) in_s=\(Int(endsAt.timeIntervalSince(now)), privacy: .public)"
        )
        return true
    }

    /// Stop the activity and forget the deadline — the server unlocked, or the pairing ended.
    ///
    /// Called on every unlocked poll, so without `force` it talks to `DeviceActivityCenter` only
    /// when a record says something is armed. `force` is for unpair and DSN changes, where the
    /// App Group may already have been wiped from under the record.
    static func stop(
        dsn rawDSN: String,
        force: Bool = false,
        store: DeviceLockDeadlineSharedStore = DeviceLockDeadlineSharedStore(),
        stop: StopMonitoring? = nil
    ) {
        let dsn = DeviceLockDeadlineActivityIdentifier.normalize(rawDSN)
        let hadRecord = store.load() != nil
        guard hadRecord || force else { return }
        store.clear()
        let activity = DeviceActivityName(DeviceLockDeadlineActivityIdentifier.rawValue(dsn: dsn))
        if let stop {
            stop([activity])
        } else {
            DeviceActivityCenter().stopMonitoring([activity])
        }
        if hadRecord { log.notice("lock_deadline stopped") }
    }

    /// Open the phone: the two keys the whole-device lock owns on the DEFAULT store, and only
    /// those. `shield.applications` carries the per-app blocks, which outlive a whole-device lock;
    /// `clearAllSettings()` would drop them and the app's change guard would never put them back.
    static func releaseGlobalShield(store: ManagedSettingsStore? = nil) {
        let store = store ?? ManagedSettingsStore()
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
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

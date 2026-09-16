import Foundation
import os

/// Per-app screen time on this iPhone, as far as iOS will let a third party measure it.
///
/// THE ONLY CHANNEL THAT WORKS. The `DeviceActivityReport` extension sees exact per-app usage and
/// cannot hand any of it to the app (its App Group container is sandbox-redirected — measured on an
/// iPhone 12 mini, iOS 26.6.1, read-back in the extension succeeds while the app sees nothing). The
/// `DeviceActivityMonitor` extension is a plain app extension and CAN write to the App Group —
/// measured 2026-09-16: `schedule_monitor event_written … pending_read_back=1` in the extension,
/// `app_reads pending=1` in the app, same second. What that extension gets from iOS is not a
/// number but a callback: "this app's usage today has reached N". So usage is measured as a
/// staircase — one `DeviceActivityEvent` per labelled app, threshold = (seconds already recorded +
/// one step), re-armed after each step — and this ledger is the staircase's current height, per
/// app, per local day.
///
/// The figure is therefore a FLOOR, exact to one step (`stepSeconds`): an app the ledger says has
/// 15 minutes has been used for at least 15 and fewer than 20. That is the honest resolution of
/// the API, and it is what `PUT /device/apps/usage/daily` receives.
///
/// Written by BOTH processes (the extension on every threshold, the app when it re-arms or the day
/// rolls over), so every write goes through `record` — merge-by-max, never replace — and posts a
/// Darwin notification so the other process can upload or re-arm.
struct ScreenTimeUsageLedger {
    struct Day: Codable, Equatable {
        /// Local calendar day, `YYYY-MM-DD` — the `date` the server expects.
        let dayKey: String
        /// Lower-cased bundle id → seconds reached. The key is the `packageName` on the wire.
        var seconds: [String: Int]
        var updatedAt: Date
    }

    static let storageKey = "SCREEN_TIME_USAGE_LEDGER_V1"
    /// Posted after every write, from whichever process wrote. The app uploads on it; the
    /// extension is the usual writer.
    static let didChangeDarwinNotification = "uz.smartoila.kids.usage-ledger-changed"
    /// One staircase step. Five minutes is coarse enough that a child using six apps all day costs
    /// well under a hundred extension wake-ups, and fine enough for "YouTube: 35 min" to mean
    /// something to a parent.
    static let stepSeconds = 5 * 60
    /// The first rung is lower, so a parent sees "1 min" within a minute of the child opening an
    /// app instead of nothing for five — one extra wake-up per app per day buys that.
    static let firstStepSeconds = 60
    /// Today plus the seven days the server accepts (`[today − 7, today + 1]`).
    static let retainedDays = 8

    init(userDefaults: UserDefaults? = ScreenTimeUsageAppGroup.sharedUserDefaults()) {
        self.userDefaults = userDefaults
    }

    var isAvailable: Bool { userDefaults != nil }

    /// Newest day first.
    func days() -> [Day] {
        guard let userDefaults, let data = userDefaults.data(forKey: Self.storageKey) else { return [] }
        let decoded = (try? JSONDecoder().decode([Day].self, from: data)) ?? []
        return decoded.sorted { $0.dayKey > $1.dayKey }
    }

    func day(_ dayKey: String) -> Day? {
        days().first { $0.dayKey == dayKey }
    }

    /// Seconds reached today for every labelled app, keyed by lower-cased bundle id.
    func secondsReached(dayKey: String) -> [String: Int] {
        day(dayKey)?.seconds ?? [:]
    }

    /// Raise one app's figure for one day. Merge-by-max: a late or repeated callback can never
    /// lower a figure, and two writers racing on the same key keep the higher one.
    ///
    /// Returns true when the stored value changed, so a caller can skip a re-arm and an upload for
    /// a callback that told us nothing new.
    @discardableResult
    func record(bundleId: String, secondsReached: Int, dayKey: String, now: Date = Date()) -> Bool {
        guard let userDefaults else { return false }
        let key = Self.normalizedBundleId(bundleId)
        guard !key.isEmpty, secondsReached > 0 else { return false }

        var all = days()
        var changed = false
        if let index = all.firstIndex(where: { $0.dayKey == dayKey }) {
            let existing = all[index].seconds[key] ?? 0
            if secondsReached > existing {
                all[index].seconds[key] = secondsReached
                all[index].updatedAt = now
                changed = true
            }
        } else {
            all.append(Day(dayKey: dayKey, seconds: [key: secondsReached], updatedAt: now))
            changed = true
        }
        guard changed else { return false }

        all.sort { $0.dayKey > $1.dayKey }
        if all.count > Self.retainedDays {
            all = Array(all.prefix(Self.retainedDays))
        }
        guard let data = try? JSONEncoder().encode(all) else { return false }
        userDefaults.set(data, forKey: Self.storageKey)
        Self.log.notice(
            "usage_ledger record app=\(key, privacy: .public) day=\(dayKey, privacy: .public) seconds=\(secondsReached, privacy: .public)"
        )
        Self.postDidChange()
        return true
    }

    /// A token was re-labelled: what was counted under the old package is the same app's time, so
    /// it moves to the new package (merge-by-max) instead of being reported twice — once under a
    /// name the server now believes is uninstalled. Every retained day, not only today.
    func rename(from oldBundleId: String, to newBundleId: String, now: Date = Date()) {
        guard let userDefaults else { return }
        let oldKey = Self.normalizedBundleId(oldBundleId)
        let newKey = Self.normalizedBundleId(newBundleId)
        guard !oldKey.isEmpty, !newKey.isEmpty, oldKey != newKey else { return }
        var all = days()
        var changed = false
        for index in all.indices {
            guard let seconds = all[index].seconds.removeValue(forKey: oldKey) else { continue }
            all[index].seconds[newKey] = max(seconds, all[index].seconds[newKey] ?? 0)
            all[index].updatedAt = now
            changed = true
        }
        guard changed, let data = try? JSONEncoder().encode(all) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
        Self.log.notice("usage_ledger renamed from=\(oldKey, privacy: .public) to=\(newKey, privacy: .public)")
        Self.postDidChange()
    }

    /// Make sure today exists, so an upload can say "today: nothing yet" once monitoring is armed —
    /// which is different from "today: not measured", the state before any label exists.
    func touch(dayKey: String, now: Date = Date()) {
        guard let userDefaults, day(dayKey) == nil else { return }
        var all = days()
        all.append(Day(dayKey: dayKey, seconds: [:], updatedAt: now))
        all.sort { $0.dayKey > $1.dayKey }
        if all.count > Self.retainedDays {
            all = Array(all.prefix(Self.retainedDays))
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    /// The local day the usage activity was last armed for. `intervalDidStart` re-arms only when
    /// this is not today: iOS may deliver that callback for an interval that is already running
    /// (it says so), and a re-arm that fires a re-arm is a loop nobody would ever see.
    static let armedDayKey = "SCREEN_TIME_USAGE_ARMED_DAY"

    func armedDay() -> String? {
        userDefaults?.string(forKey: Self.armedDayKey)
    }

    func setArmedDay(_ dayKey: String) {
        userDefaults?.set(dayKey, forKey: Self.armedDayKey)
    }

    /// When the monitor extension last had a report accepted — its own rate limit, in the App
    /// Group so it survives the extension process, which lives for one callback.
    static let extensionUploadedAtKey = "SCREEN_TIME_USAGE_EXT_UPLOADED_AT"

    func lastExtensionUploadAt() -> Date? {
        userDefaults?.object(forKey: Self.extensionUploadedAtKey) as? Date
    }

    func setLastExtensionUploadAt(_ date: Date) {
        userDefaults?.set(date, forKey: Self.extensionUploadedAtKey)
    }

    func clear() {
        userDefaults?.removeObject(forKey: Self.storageKey)
        userDefaults?.removeObject(forKey: Self.armedDayKey)
        userDefaults?.removeObject(forKey: Self.extensionUploadedAtKey)
    }

    static func normalizedBundleId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func postDidChange() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(didChangeDarwinNotification as CFString),
            nil,
            nil,
            true
        )
    }

    private let userDefaults: UserDefaults?
    static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime")
}

/// Names shared by the app (which arms the activity) and the monitor extension (which answers it).
///
/// The bundle id rides in the EVENT name because a threshold callback carries nothing else: the
/// extension gets `(event, activity)` and has to know which app and which step fired without
/// touching a token.
enum ScreenTimeUsageActivity {
    static let activityPrefix = "smartoila.usage"
    static let eventPrefix = "usage"
    private static let separator = "|"

    static func activityName(dsn: String) -> String {
        activityPrefix + separator + normalizedDSN(dsn)
    }

    static func isUsageActivity(rawValue: String) -> Bool {
        rawValue.hasPrefix(activityPrefix + separator)
    }

    static func dsn(from rawValue: String) -> String? {
        let prefix = activityPrefix + separator
        guard rawValue.hasPrefix(prefix) else { return nil }
        let value = String(rawValue.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    /// `usage|<bundle id>|<threshold seconds>|<day key>`. A bundle id never contains `|`. The
    /// threshold is in the name so the extension records the exact staircase height the system
    /// confirmed, not a guess from a ledger it may be reading a step late — and the DAY is in the
    /// name because iOS delivers the callback with latency: a rung crossed at 23:58 can arrive at
    /// 00:01, and stamping it with the delivery date would write yesterday's height into today.
    static func eventName(bundleId: String, thresholdSeconds: Int, dayKey: String) -> String {
        [eventPrefix, ScreenTimeUsageLedger.normalizedBundleId(bundleId), String(thresholdSeconds), dayKey]
            .joined(separator: separator)
    }

    static func parse(eventName: String) -> (bundleId: String, thresholdSeconds: Int, dayKey: String)? {
        let parts = eventName.components(separatedBy: separator)
        guard parts.count == 4, parts[0] == eventPrefix,
              !parts[1].isEmpty, let seconds = Int(parts[2]), seconds > 0,
              parts[3].range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return (parts[1], seconds, parts[3])
    }

    private static func normalizedDSN(_ dsn: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = dsn.unicodeScalars.map { scalar -> Character in
            allowedScalars.contains(scalar) ? Character(scalar) : "_"
        }
        return String(sanitized).lowercased()
    }
}

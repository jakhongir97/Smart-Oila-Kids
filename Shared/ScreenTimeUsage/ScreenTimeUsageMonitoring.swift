import DeviceActivity
import Foundation
import ManagedSettings
import os

/// One rung of the staircase: an event the system will fire when what it watches has been used for
/// `thresholdSeconds` today — one labelled app, or (build 26) the whole phone.
struct ScreenTimeUsageThresholdEvent: Equatable {
    enum Target: Equatable {
        case application(ApplicationToken)
        /// Every category of the one-tap pick: the device total. Categories ONLY, never categories
        /// plus app tokens in one event — whether iOS counts an app once when it sits in both sets
        /// is not documented, and a total that might count YouTube twice is worse than none.
        case categories(Set<ActivityCategoryToken>)
    }

    let name: String
    /// The ledger key: a lower-cased bundle id, or `ScreenTimeUsageLedger.deviceTotalKey`.
    let bundleId: String
    let target: Target
    let thresholdSeconds: Int
}

/// The category tokens of the one-tap "All Apps & Categories" pick, mirrored into the App Group for
/// the device-total rung.
///
/// WHY. Until build 26 only LABELLED apps were measured, so a phone nobody labelled armed nothing,
/// uploaded nothing, and the parent's web read "Bugungi ekran 0 daqiqa" (Ibrohim, 2026-09-23). The
/// one-tap pick already holds a token for every category (measured 2026-09-16: `selection apps=0
/// categories=13` before `includeEntireCategory`), and one `DeviceActivityEvent` over those
/// categories counts the whole phone since local midnight. The monitor extension — which re-arms
/// after every rung — needs only that set, so it gets its own key in a type every file it compiles
/// already imports (ManagedSettings), rather than decoding the picker's `FamilyActivitySelection`.
///
/// Written by `ScreenTimeRestrictedAppsStore` whenever the selection is saved or loaded (the load
/// is the migration for phones that picked before build 26), cleared with it.
struct ScreenTimeUsageTotalCategoryStore {
    static let storageKey = "SCREEN_TIME_TOTAL_CATEGORY_TOKENS_V1"

    init(userDefaults: UserDefaults? = ScreenTimeUsageAppGroup.sharedUserDefaults()) {
        self.userDefaults = userDefaults
    }

    func tokens() -> Set<ActivityCategoryToken> {
        guard let userDefaults, let data = userDefaults.data(forKey: Self.storageKey) else { return [] }
        // A blob that stops decoding is "no total", never a throw — the app rungs must still arm.
        return (try? JSONDecoder().decode(Set<ActivityCategoryToken>.self, from: data)) ?? []
    }

    var hasTokens: Bool { !tokens().isEmpty }

    /// An empty set removes the key: "no categories" and "never picked" are the same state. The
    /// same set is not written again — the app mirrors it on every arm, and the App Group is shared
    /// with an extension process.
    func save(_ tokens: Set<ActivityCategoryToken>) {
        guard let userDefaults else { return }
        guard !tokens.isEmpty else {
            clear()
            return
        }
        guard tokens != self.tokens(), let data = try? JSONEncoder().encode(tokens) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    func clear() {
        userDefaults?.removeObject(forKey: Self.storageKey)
    }

    private let userDefaults: UserDefaults?
}

/// Arms (and re-arms) the usage activity — from the app on launch, selection and day change, and
/// from the monitor extension after every threshold, because the extension is the only process
/// guaranteed to be awake when a step is reached.
///
/// ONE activity, MANY events. Apple caps an app and its extensions at twenty activities together,
/// and the lock schedule already spends some. Events per activity have no documented cap, so the
/// code assumes the same fifty it allows labels (`maximumEvents`) and never arms more: at most
/// forty-nine app rungs plus the one device-total rung. With
/// `includesPastActivity: true` (iOS 17.4) every event counts from the interval start — local
/// midnight — so re-arming with new thresholds after a step loses nothing that was already
/// counted. Below iOS 17.4 a re-arm would restart every count from zero, which turns the staircase
/// into a lie, so usage is simply not measured there (`isSupported`).
enum ScreenTimeUsageMonitoring {
    typealias StartMonitoring = (DeviceActivityName, DeviceActivitySchedule, [DeviceActivityEvent.Name: DeviceActivityEvent]) throws -> Void
    typealias StopMonitoring = ([DeviceActivityName]) -> Void

    static var isSupported: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }

    /// Same number as `AppCatalogue.maximumBlockedApplications` — Apple's 50-app shield cap. A
    /// literal because this file is compiled into the monitor extension, which does not carry the
    /// catalogue; `ScreenTimeUsageMonitoringTests` pins the two equal. It is also the per-activity
    /// event budget the code assumes (Apple documents none), so it bounds app rungs AND the total.
    static let maximumEvents = 50

    /// App rungs: one slot of the budget is always reserved for the device total, whether or not
    /// the phone has categories yet, so the budget still holds on the day the one-tap pick lands.
    static let maximumApplicationEvents = maximumEvents - 1

    /// No rung at or above 23:59:00 of usage. The interval ends at 23:59:59, a threshold past it can
    /// never fire, and a runaway ledger asking for `hour: 24+` could make the whole
    /// `startMonitoring` throw — taking every other rung down with it.
    static let maximumThresholdSeconds = 86_340

    /// Clock skew allowed between "seconds since local midnight" and a rung iOS says was reached.
    static let plausibilitySlackSeconds = 120

    /// The whole local day, every day. The interval is what "today" means to every threshold.
    static let schedule = DeviceActivitySchedule(
        intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
        intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
        repeats: true
    )

    /// The events to arm right now: one per labelled app at the next step above what the ledger
    /// already holds for today, plus ONE device-total rung over `totalCategories` when the phone
    /// has them. Pure, so the rule can be pinned without a device.
    ///
    /// `cap` is the per-activity budget: app rungs stop one short of it (the reserved total slot),
    /// so a runaway catalogue cannot arm hundreds and the total always fits.
    static func plan(
        entries: [ApplicationTokenCatalogue.Entry],
        totalCategories: Set<ActivityCategoryToken> = [],
        secondsReached: [String: Int],
        dayKey: String,
        step: Int = ScreenTimeUsageLedger.stepSeconds,
        firstStep: Int = ScreenTimeUsageLedger.firstStepSeconds,
        cap: Int = maximumEvents
    ) -> [ScreenTimeUsageThresholdEvent] {
        let applicationCap = max(0, cap - 1)
        var seen: Set<String> = []
        var events: [ScreenTimeUsageThresholdEvent] = []
        for entry in entries {
            guard events.count < applicationCap else { break }
            let bundleId = ScreenTimeUsageLedger.normalizedBundleId(entry.bundleId)
            guard !bundleId.isEmpty, bundleId != ScreenTimeUsageLedger.deviceTotalKey,
                  seen.insert(bundleId).inserted,
                  let next = nextRung(reached: secondsReached[bundleId] ?? 0, step: step, firstStep: firstStep) else {
                continue
            }
            events.append(
                ScreenTimeUsageThresholdEvent(
                    name: ScreenTimeUsageActivity.eventName(bundleId: bundleId, thresholdSeconds: next, dayKey: dayKey),
                    bundleId: bundleId,
                    target: .application(entry.token),
                    thresholdSeconds: next
                )
            )
        }
        let totalKey = ScreenTimeUsageLedger.deviceTotalKey
        if !totalCategories.isEmpty,
           let next = nextRung(reached: secondsReached[totalKey] ?? 0, step: step, firstStep: firstStep) {
            events.append(
                ScreenTimeUsageThresholdEvent(
                    name: ScreenTimeUsageActivity.eventName(bundleId: totalKey, thresholdSeconds: next, dayKey: dayKey),
                    bundleId: totalKey,
                    target: .categories(totalCategories),
                    thresholdSeconds: next
                )
            )
        }
        return events
    }

    /// The rung above `reached`, or nil when it would not fit in the day. Snapped to the staircase:
    /// a ledger value that is not a multiple of the step (a changed step size, a hand-edited store)
    /// still yields the next whole rung above it. Nothing yet → the low first rung.
    static func nextRung(reached: Int, step: Int, firstStep: Int) -> Int? {
        let reached = max(0, reached)
        let next = reached == 0 ? firstStep : (reached / step + 1) * step
        return next < maximumThresholdSeconds ? next : nil
    }

    /// The most usage `dayKey` can hold at `now`: the seconds since its local midnight (plus slack)
    /// while it is today, a whole day once it is over, nothing for a day that has not begun (a
    /// clock moved backwards). No app can have been used longer than its day has lasted, so a rung
    /// above this is a spurious callback — and trusting every callback is how a staircase runs away,
    /// one re-armed rung at a time (audit 2026-09-24, over-report risk 1).
    static func plausibleSecondsBound(
        dayKey: String,
        now: Date,
        calendar: Calendar = ScreenTimeUsageDayFormatter.gregorian
    ) -> Int {
        let todayKey = ScreenTimeUsageDayFormatter.dayKey(for: now, calendar: calendar)
        // `YYYY-MM-DD` compares chronologically as a string.
        if dayKey < todayKey { return 24 * 60 * 60 }
        if dayKey > todayKey { return 0 }
        let elapsed = Int(now.timeIntervalSince(calendar.startOfDay(for: now)))
        return max(0, elapsed) + plausibilitySlackSeconds
    }

    /// Arm the activity for `dsn` from the current catalogue, category pick and ledger. Returns how
    /// many events were armed; zero with nothing picked at all means monitoring was stopped.
    ///
    /// Safe to call from either process: `startMonitoring` on an activity that is already running
    /// replaces its events, which is exactly the re-arm.
    @discardableResult
    static func arm(
        dsn: String,
        catalogue: ApplicationTokenCatalogue = ApplicationTokenCatalogue(),
        ledger: ScreenTimeUsageLedger = ScreenTimeUsageLedger(),
        totalCategories: ScreenTimeUsageTotalCategoryStore = ScreenTimeUsageTotalCategoryStore(),
        now: Date = Date(),
        calendar: Calendar = ScreenTimeUsageDayFormatter.gregorian,
        start: StartMonitoring? = nil,
        stop: StopMonitoring? = nil,
        shouldContinue: (() -> Bool)? = nil
    ) throws -> Int {
        let center = DeviceActivityCenter()
        let startMonitoring = start ?? { name, schedule, events in
            try center.startMonitoring(name, during: schedule, events: events)
        }
        let stopMonitoring = stop ?? { names in center.stopMonitoring(names) }

        let activity = DeviceActivityName(ScreenTimeUsageActivity.activityName(dsn: dsn))
        guard isSupported else {
            stopMonitoring([activity])
            return 0
        }

        let entries = catalogue.entries()
        let categories = totalCategories.tokens()
        // Nothing picked at all — no label and no one-tap pick: there is no token iOS could
        // measure (Apple's wall), and this is the only state that stops the activity. Everything
        // else keeps it running, even with no rung left today, because a stopped activity gets no
        // `intervalDidStart` at midnight and tomorrow would never be armed.
        guard !entries.isEmpty || !categories.isEmpty else {
            stopMonitoring([activity])
            log.notice("usage_monitor stopped dsn_present=1 reason=nothing_picked")
            return 0
        }

        let dayKey = ScreenTimeUsageDayFormatter.dayKey(for: now, calendar: calendar)
        let events = plan(
            entries: entries,
            totalCategories: categories,
            secondsReached: ledger.secondsReached(dayKey: dayKey),
            dayKey: dayKey
        )
        var armed: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for event in events {
            armed[DeviceActivityEvent.Name(event.name)] = makeEvent(event)
        }
        // No `stopMonitoring` first. Measured 2026-09-16: a stop/start pair makes iOS deliver
        // `intervalDidEnd` + `intervalDidStart` for the running interval on EVERY re-arm — one
        // forced "day is over" upload per rung. A start on a running activity replaces its events
        // (the staircase kept climbing after this change, which is the proof).
        try startMonitoring(activity, schedule, armed)
        // The app arms from a background lane; if the pairing ended while `startMonitoring` was in
        // the daemon, the unpair wipe has already emptied the App Group and must stay empty.
        guard shouldContinue?() ?? true else {
            log.notice("usage_monitor armed_without_ledger reason=pairing_ended_during_arm events=\(events.count, privacy: .public)")
            return events.count
        }
        ledger.setArmedDay(dayKey)
        // Today now exists in the ledger even before the first step, so an upload can state a
        // measured zero instead of staying silent.
        ledger.touch(dayKey: dayKey, now: now)
        log.notice(
            "usage_monitor armed events=\(events.count, privacy: .public) categories=\(categories.count, privacy: .public) day=\(dayKey, privacy: .public) next=\(events.map { "\($0.bundleId)@\($0.thresholdSeconds)" }.joined(separator: ","), privacy: .public)"
        )
        return events.count
    }

    static func stop(dsn: String, stop: StopMonitoring? = nil) {
        let activity = DeviceActivityName(ScreenTimeUsageActivity.activityName(dsn: dsn))
        if let stop {
            stop([activity])
        } else {
            DeviceActivityCenter().stopMonitoring([activity])
        }
    }

    /// Whole hours / minutes / seconds, because a bare `DateComponents(second: 900)` is accepted by
    /// the API but a normalized threshold is what Apple's own examples pass.
    static func thresholdComponents(seconds: Int) -> DateComponents {
        let clamped = max(1, seconds)
        return DateComponents(hour: clamped / 3600, minute: (clamped % 3600) / 60, second: clamped % 60)
    }

    private static func makeEvent(_ event: ScreenTimeUsageThresholdEvent) -> DeviceActivityEvent {
        let threshold = thresholdComponents(seconds: event.thresholdSeconds)
        switch event.target {
        case .application(let token):
            if #available(iOS 17.4, *) {
                return DeviceActivityEvent(applications: [token], threshold: threshold, includesPastActivity: true)
            }
            return DeviceActivityEvent(applications: [token], threshold: threshold)
        case .categories(let categories):
            if #available(iOS 17.4, *) {
                return DeviceActivityEvent(categories: categories, threshold: threshold, includesPastActivity: true)
            }
            return DeviceActivityEvent(categories: categories, threshold: threshold)
        }
    }

    static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime")
}

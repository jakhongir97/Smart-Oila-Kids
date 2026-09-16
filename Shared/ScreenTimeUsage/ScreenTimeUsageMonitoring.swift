import DeviceActivity
import Foundation
import ManagedSettings
import os

/// One rung of the staircase: an event the system will fire when `bundleId` has been used for
/// `thresholdSeconds` today.
struct ScreenTimeUsageThresholdEvent: Equatable {
    let name: String
    let bundleId: String
    let token: ApplicationToken
    let thresholdSeconds: Int
}

/// Arms (and re-arms) the usage activity — from the app on launch, selection and day change, and
/// from the monitor extension after every threshold, because the extension is the only process
/// guaranteed to be awake when a step is reached.
///
/// ONE activity, MANY events. Apple caps an app and its extensions at twenty activities together,
/// and the lock schedule already spends some; events per activity are not capped. With
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
    /// catalogue; `ScreenTimeUsageMonitoringTests` pins the two equal.
    static let maximumEvents = 50

    /// The whole local day, every day. The interval is what "today" means to every threshold.
    static let schedule = DeviceActivitySchedule(
        intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
        intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
        repeats: true
    )

    /// The events to arm right now: one per labelled app, at the next step above what the ledger
    /// already holds for today. Pure, so the rule can be pinned without a device.
    ///
    /// `cap` mirrors the shield cap — a parent cannot label more apps than can be blocked, and the
    /// event list is bounded by the same number so a runaway catalogue cannot arm hundreds.
    static func plan(
        entries: [ApplicationTokenCatalogue.Entry],
        secondsReached: [String: Int],
        dayKey: String,
        step: Int = ScreenTimeUsageLedger.stepSeconds,
        firstStep: Int = ScreenTimeUsageLedger.firstStepSeconds,
        cap: Int = maximumEvents
    ) -> [ScreenTimeUsageThresholdEvent] {
        var seen: Set<String> = []
        var events: [ScreenTimeUsageThresholdEvent] = []
        for entry in entries {
            let bundleId = ScreenTimeUsageLedger.normalizedBundleId(entry.bundleId)
            guard !bundleId.isEmpty, seen.insert(bundleId).inserted else { continue }
            let reached = max(0, secondsReached[bundleId] ?? 0)
            // Snap to the staircase: a ledger value that is not a multiple of the step (a changed
            // step size, a hand-edited store) still yields the next whole rung above it. Nothing
            // yet → the low first rung.
            let next = reached == 0 ? firstStep : (reached / step + 1) * step
            events.append(
                ScreenTimeUsageThresholdEvent(
                    name: ScreenTimeUsageActivity.eventName(bundleId: bundleId, thresholdSeconds: next, dayKey: dayKey),
                    bundleId: bundleId,
                    token: entry.token,
                    thresholdSeconds: next
                )
            )
            if events.count == cap { break }
        }
        return events
    }

    /// Arm the activity for `dsn` from the current catalogue and ledger. Returns how many events
    /// were armed; zero means monitoring was stopped because there is nothing labelled.
    ///
    /// Safe to call from either process: `startMonitoring` on an activity that is already running
    /// replaces its events, which is exactly the re-arm.
    @discardableResult
    static func arm(
        dsn: String,
        catalogue: ApplicationTokenCatalogue = ApplicationTokenCatalogue(),
        ledger: ScreenTimeUsageLedger = ScreenTimeUsageLedger(),
        now: Date = Date(),
        calendar: Calendar = ScreenTimeUsageDayFormatter.gregorian,
        start: StartMonitoring? = nil,
        stop: StopMonitoring? = nil
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

        let dayKey = ScreenTimeUsageDayFormatter.dayKey(for: now, calendar: calendar)
        let events = plan(entries: catalogue.entries(), secondsReached: ledger.secondsReached(dayKey: dayKey), dayKey: dayKey)
        guard !events.isEmpty else {
            stopMonitoring([activity])
            log.notice("usage_monitor stopped dsn_present=1 reason=no_labelled_apps")
            return 0
        }

        var armed: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for event in events {
            armed[DeviceActivityEvent.Name(event.name)] = makeEvent(token: event.token, thresholdSeconds: event.thresholdSeconds)
        }
        // Stop first: a start on a running activity is documented as a replacement, but a stop
        // makes that true on every iOS this ships on, and the interval-start guard
        // (`ScreenTimeUsageLedger.armedDay`) absorbs the callback a restart may trigger.
        stopMonitoring([activity])
        try startMonitoring(activity, schedule, armed)
        ledger.setArmedDay(dayKey)
        // Today now exists in the ledger even before the first step, so an upload can state a
        // measured zero instead of staying silent.
        ledger.touch(dayKey: dayKey, now: now)
        log.notice(
            "usage_monitor armed events=\(events.count, privacy: .public) day=\(dayKey, privacy: .public) next=\(events.map { "\($0.bundleId)@\($0.thresholdSeconds)" }.joined(separator: ","), privacy: .public)"
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

    private static func makeEvent(token: ApplicationToken, thresholdSeconds: Int) -> DeviceActivityEvent {
        let threshold = thresholdComponents(seconds: thresholdSeconds)
        if #available(iOS 17.4, *) {
            return DeviceActivityEvent(applications: [token], threshold: threshold, includesPastActivity: true)
        }
        return DeviceActivityEvent(applications: [token], threshold: threshold)
    }

    static let log = Logger(subsystem: "uz.smartoila.kids", category: "screentime")
}

import DeviceActivity
import Foundation
import ManagedSettings
import UserNotifications
import os

final class SmartOilaKidsDeviceActivityMonitorExtension: DeviceActivityMonitor {
    /// The one line that says this process ran at all. Everything this extension does is invisible
    /// from the app (it may be the ONLY process awake when a schedule starts at night), so each
    /// callback is logged with what it wrote and whether the App Group write reported success —
    /// readable off the phone with `idevicesyslog -m schedule_monitor`.
    static let log = Logger(subsystem: "uz.smartoila.kids", category: "schedule-monitor")

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        Self.log.notice("schedule_monitor interval_start activity=\(activity.rawValue, privacy: .public)")

        // A whole-device lock edge: the phone may be offline and the app dead, and this is the one
        // process iOS wakes at the minute. Re-evaluate the rule; never lock or unlock blindly.
        if DeviceLockEdgeActivityIdentifier.isLockEdgeActivity(rawValue: activity.rawValue) {
            handleLockEdge(activity: activity, callback: .intervalStart)
            return
        }

        // A new local day for the usage staircase: every threshold must start again from one
        // step, or the first callback today would fire at yesterday's height.
        if ScreenTimeUsageActivity.isUsageActivity(rawValue: activity.rawValue) {
            let today = ScreenTimeUsageDayFormatter.dayKey(for: Date())
            // Already armed for today — this is the callback our own (re)start provoked, not a
            // new day. Re-arming here would start again, and start again.
            guard usageLedger.armedDay() != today else {
                Self.log.notice("schedule_monitor usage_interval_start already_armed day=\(today, privacy: .public)")
                return
            }
            if let dsn = ScreenTimeUsageActivity.dsn(from: activity.rawValue) {
                rearmUsage(dsn: dsn, reason: "interval_start")
            }
            return
        }

        if DeviceLockScheduleActivityIdentifier.isScheduleActivity(rawValue: activity.rawValue) {
            scheduleStore.shield.applications = nil
            scheduleStore.shield.applicationCategories = .all()
            scheduleStore.shield.webDomains = nil
            scheduleStore.shield.webDomainCategories = .all()
            if let dsn = DeviceLockScheduleActivityIdentifier.dsn(from: activity.rawValue) {
                recordEvent(kind: .scheduleStarted, dsn: dsn)
            }
            return
        }

        guard let dsn = DeviceAppLimitActivityIdentifier.dsn(from: activity.rawValue) else {
            return
        }

        clearAppLimitState(for: dsn)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        Self.log.notice("schedule_monitor interval_end activity=\(activity.rawValue, privacy: .public)")

        // An edge activity ends 16 minutes after its edge — or early, when it is restarted or
        // stopped. Either way the rule at this moment is the answer.
        if DeviceLockEdgeActivityIdentifier.isLockEdgeActivity(rawValue: activity.rawValue)
            || DeviceLockLegacyDeadline.isLegacyActivity(rawValue: activity.rawValue) {
            handleLockEdge(activity: activity, callback: .intervalEnd)
            return
        }

        if ScreenTimeUsageActivity.isUsageActivity(rawValue: activity.rawValue) {
            // The day is over; what the ledger holds for it is final. Send it while a process is
            // awake to do so — the app may not be for hours. Only when the day REALLY ended: iOS
            // also delivers this for a restart of the running interval (measured 2026-09-16: one
            // per re-arm), and those must not each force an upload.
            let now = Date()
            let components = Calendar.current.dateComponents([.hour, .minute], from: now)
            let dayRolledOver = ScreenTimeUsageDayFormatter.dayKey(for: now) != usageLedger.armedDay()
                || (components.hour == 23 && components.minute == 59)
                || (components.hour == 0 && (components.minute ?? 0) < 2)
            guard dayRolledOver else {
                Self.log.notice("schedule_monitor usage_interval_end ignored reason=restart_not_day_end")
                return
            }
            uploadUsage(reason: "interval_end", force: true)
            return
        }

        if DeviceLockScheduleActivityIdentifier.isScheduleActivity(rawValue: activity.rawValue) {
            DeviceLockManagedSettingsStoreFactory.clearAllSettings(scheduleStore)
            if let dsn = DeviceLockScheduleActivityIdentifier.dsn(from: activity.rawValue) {
                recordEvent(kind: .scheduleEnded, dsn: dsn)
            }
            return
        }

        guard let dsn = DeviceAppLimitActivityIdentifier.dsn(from: activity.rawValue) else {
            return
        }

        clearAppLimitState(for: dsn)
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        Self.log.notice("schedule_monitor threshold activity=\(activity.rawValue, privacy: .public) event=\(event.rawValue, privacy: .public)")

        if ScreenTimeUsageActivity.isUsageActivity(rawValue: activity.rawValue) {
            handleUsageThreshold(event: event, activity: activity)
            return
        }

        guard let dsn = DeviceAppLimitActivityIdentifier.dsn(from: activity.rawValue),
              let packageName = DeviceAppLimitEventIdentifier.packageName(from: event.rawValue),
              var snapshot = sharedStore.loadSnapshot(dsn: dsn) else {
            return
        }

        let normalizedPackageName = packageName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedPackageName.isEmpty else { return }

        var reachedIdentifiers = Set(snapshot.reachedPackageNames.map { $0.lowercased() })
        reachedIdentifiers.insert(normalizedPackageName)
        snapshot.reachedPackageNames = Array(reachedIdentifiers).sorted()
        snapshot.generatedAt = Date()

        try? sharedStore.saveSnapshot(snapshot)
        applyAppLimitShield(using: snapshot)
        let appName = snapshot.configurations.first { configuration in
            configuration.packageName.caseInsensitiveCompare(normalizedPackageName) == .orderedSame
        }?.appName
        recordEvent(
            kind: .appLimitReached,
            dsn: dsn,
            packageName: normalizedPackageName,
            appName: appName
        )
    }

    private let scheduleStore = DeviceLockManagedSettingsStoreFactory.make(
        named: DeviceLockManagedSettingsStoreName.schedule
    )
    private let appLimitStore = DeviceLockManagedSettingsStoreFactory.make(
        named: DeviceLockManagedSettingsStoreName.limit
    )
    private let sharedStore = DeviceAppLimitSharedStore()
    private let eventStore = DeviceControlEventSharedStore()
    private let usageLedger = ScreenTimeUsageLedger()
    private let lockPolicyStore = DeviceLockPolicySharedStore()
}

// MARK: - The whole-device lock edges

private extension SmartOilaKidsDeviceActivityMonitorExtension {
    enum LockEdgeCallback: String {
        case intervalStart = "start"
        case intervalEnd = "end"
    }

    /// A lock edge arrived and the app may not be running: decide the lock by the rule and make the
    /// OS match — the backend contract of 2026-09-23 ("at startsAt and endsAt re-check by itself")
    /// in the one process iOS promises to wake for it, internet or not.
    ///
    /// 1. Load the policy the app saved and evaluate it on the trusted clock — at the edge's own
    ///    minute for an `intervalDidStart` that fired a little early (`evaluationTime`), at now for
    ///    an `intervalDidEnd` (sixteen minutes on, or a restart/stop).
    /// 2. Write the two whole-device keys on the DEFAULT store through the shared helper; the
    ///    per-app blocks in `shield.applications` are not touched.
    /// 3. Arm the next edges, so the chain carries on with the app dead for days.
    /// 4. Tell an app that happens to be alive, and log one line.
    ///
    /// Because it re-evaluates instead of flipping, a restart's spurious callback pair, an edge the
    /// parent has since moved and a clock moved forward (which fires every edge early) all come out
    /// right.
    func handleLockEdge(activity: DeviceActivityName, callback: LockEdgeCallback) {
        let raw = activity.rawValue
        guard let snapshot = lockPolicyStore.load() else {
            // No policy yet: either unpaired (nothing may lock) or build 24's activity firing before
            // this build's app has ever run. Then build 24's own promise stands — open at its end.
            var released = false
            if callback == .intervalEnd, DeviceLockLegacyDeadline.isLegacyActivity(rawValue: raw),
               let end = DeviceLockLegacyDeadline.recordedEnd(), Date().timeIntervalSince(end) >= -5 {
                DeviceLockPolicy.applyWholeDevice(locked: false)
                DeviceLockLegacyDeadline.clear()
                released = true
            }
            Self.log.notice("schedule_monitor lock_edge callback=\(callback.rawValue, privacy: .public) outcome=no_snapshot legacy_released=\(released ? 1 : 0, privacy: .public)")
            return
        }
        let clock = DeviceLockClock.live
        let wallNow = clock.wallNow()
        let trustedNow = clock.trustedNow(anchor: snapshot.clock)
        let evaluationTime = callback == .intervalStart
            ? DeviceLockEdgeMonitoring.evaluationTime(now: trustedNow, activityName: raw)
            : trustedNow
        let calendar = DeviceLockPolicy.phoneCalendar()
        let locked = DeviceLockPolicy.isLocked(at: evaluationTime, snapshot: snapshot, calendar: calendar)
        let wrote = DeviceLockPolicy.applyWholeDevice(locked: locked)
        lockPolicyStore.markEdgeEvaluated(at: evaluationTime)
        // The app's own planning path: the next edge is armed even when it is days away (a Friday
        // afternoon's next flip can be Monday morning), so the chain never runs out.
        let outlook = DeviceLockEdgeMonitoring.outlook(
            snapshot: snapshot, evaluationTime: evaluationTime, trustedNow: trustedNow, wallNow: wallNow, calendar: calendar
        )
        let result = DeviceLockEdgeMonitoring.arm(outlook.entries, center: LiveDeviceLockEdgeCenter(), wallNow: wallNow)
        DeviceLockEdgeMonitoring.postDidEvaluate()
        let nextIn = outlook.edges.first.map { Int($0.timeIntervalSince(trustedNow)) } ?? -1
        Self.log.notice(
            "schedule_monitor lock_edge callback=\(callback.rawValue, privacy: .public) activity=\(raw, privacy: .public) locked=\(locked ? 1 : 0, privacy: .public) wrote=\(wrote ? 1 : 0, privacy: .public) eval_ahead_s=\(Int(evaluationTime.timeIntervalSince(trustedNow)), privacy: .public) skew_s=\(Int(trustedNow.timeIntervalSince(wallNow)), privacy: .public) next_edge_in_s=\(nextIn, privacy: .public) armed=\(outlook.entries.count, privacy: .public) started=\(result.started.count, privacy: .public) stopped=\(result.stopped.count, privacy: .public) failures=\(result.failures, privacy: .public)"
        )
    }
}

// MARK: - Per-app usage (the staircase)

private extension SmartOilaKidsDeviceActivityMonitorExtension {
    /// "This app (or, for `__device_total__`, the whole phone) has been used for N seconds today."
    /// Record N, arm N + step, tell the server.
    ///
    /// Three writes, and the order matters: the ledger first (so a crash after it still leaves
    /// the figure), the re-arm second (so the next rung exists before anything slow happens), the
    /// upload last (network, bounded by a timeout, and the app will retry it anyway).
    ///
    /// None of the three for a rung that cannot be true: more usage than its day has had seconds.
    /// Recording it would put an impossible figure on the parent's screen, and re-arming above it
    /// is how one spurious callback turns into a staircase that climbs by itself.
    func handleUsageThreshold(event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        guard let dsn = ScreenTimeUsageActivity.dsn(from: activity.rawValue),
              let parsed = ScreenTimeUsageActivity.parse(eventName: event.rawValue) else {
            Self.log.error("schedule_monitor usage_event_unparsed event=\(event.rawValue, privacy: .public)")
            return
        }
        let bound = ScreenTimeUsageMonitoring.plausibleSecondsBound(dayKey: parsed.dayKey, now: Date())
        guard parsed.thresholdSeconds <= bound else {
            Self.log.error(
                "schedule_monitor usage_step rejected reason=beyond_elapsed app=\(parsed.bundleId, privacy: .public) seconds=\(parsed.thresholdSeconds, privacy: .public) day=\(parsed.dayKey, privacy: .public) bound=\(bound, privacy: .public)"
            )
            return
        }
        // The DAY comes from the event, never from the clock: a rung crossed at 23:58 may be
        // delivered at 00:01, and it belongs to the day it was armed for.
        let changed = usageLedger.record(bundleId: parsed.bundleId, secondsReached: parsed.thresholdSeconds, dayKey: parsed.dayKey)
        Self.log.notice(
            "schedule_monitor usage_step app=\(parsed.bundleId, privacy: .public) seconds=\(parsed.thresholdSeconds, privacy: .public) day=\(parsed.dayKey, privacy: .public) changed=\(changed ? 1 : 0, privacy: .public)"
        )
        rearmUsage(dsn: dsn, reason: "threshold")
        uploadUsage(reason: "threshold", force: false)
    }

    func rearmUsage(dsn: String, reason: String) {
        do {
            let count = try ScreenTimeUsageMonitoring.arm(dsn: dsn, ledger: usageLedger)
            Self.log.notice("schedule_monitor usage_rearm reason=\(reason, privacy: .public) events=\(count, privacy: .public)")
        } catch {
            Self.log.error("schedule_monitor usage_rearm_failed reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Best effort, from the process that is awake. The app uploads the same ledger when it next
    /// comes forward, so a failure here costs latency, never data.
    ///
    /// Two guards, both from the review of 2026-09-16:
    ///  * ONE request on the wire across processes — `ScreenTimeUsageUploadLock`. The app uploads on
    ///    the Darwin notification `record` just posted, so without the lock the two bodies race and
    ///    the older one can land last (each day REPLACES the server's copy).
    ///  * At most one extension upload per `minimumInterval` unless `force`: a freshly labelled app
    ///    with hours of usage today climbs the whole staircase in back-to-back callbacks
    ///    (`includesPastActivity`), and that climb only ever happens while the parent is holding the
    ///    app — which uploads on every Darwin notification anyway.
    func uploadUsage(reason: String, force: Bool) {
        let now = Date()
        if !force, let last = usageLedger.lastExtensionUploadAt(), now.timeIntervalSince(last) < Self.minimumUploadInterval {
            Self.log.notice("schedule_monitor usage_upload reason=\(reason, privacy: .public) outcome=skipped(rate_limited)")
            return
        }
        guard let lock = ScreenTimeUsageUploadLock.acquire(timeout: 6) else {
            Self.log.notice("schedule_monitor usage_upload reason=\(reason, privacy: .public) outcome=skipped(lock_busy)")
            return
        }
        defer { lock.release() }
        let days = ScreenTimeUsageReport.days(ledger: usageLedger)
        let credential = LocationPushSharedCredential.read()
        let outcome = ScreenTimeUsageExtensionUploader.upload(days: days, credential: credential.payload)
        if case .sent = outcome {
            usageLedger.setLastExtensionUploadAt(now)
        }
        Self.log.notice(
            "schedule_monitor usage_upload reason=\(reason, privacy: .public) keychain=\(credential.status, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)"
        )
    }

    static let minimumUploadInterval: TimeInterval = 60
}

private extension SmartOilaKidsDeviceActivityMonitorExtension {
    func clearAppLimitState(for dsn: String) {
        DeviceLockManagedSettingsStoreFactory.clearAllSettings(appLimitStore)

        guard var snapshot = sharedStore.loadSnapshot(dsn: dsn) else {
            return
        }

        snapshot.reachedPackageNames = []
        snapshot.generatedAt = Date()
        try? sharedStore.saveSnapshot(snapshot)
    }

    func applyAppLimitShield(using snapshot: DeviceAppLimitSnapshot) {
        let reachedIdentifiers = Set(snapshot.reachedPackageNames.map { $0.lowercased() })
        let tokens = snapshot.configurations.compactMap { configuration -> ApplicationToken? in
            reachedIdentifiers.contains(configuration.packageName.lowercased()) ? configuration.applicationToken : nil
        }

        DeviceLockManagedSettingsStoreFactory.clearAllSettings(appLimitStore)
        guard !tokens.isEmpty else { return }

        appLimitStore.shield.applications = Set(tokens)
        appLimitStore.shield.applicationCategories = nil
        appLimitStore.shield.webDomains = nil
        appLimitStore.shield.webDomainCategories = nil
    }

    func recordEvent(
        kind: DeviceControlEventKind,
        dsn: String,
        packageName: String? = nil,
        appName: String? = nil
    ) {
        let appended: DeviceControlEvent?
        do {
            appended = try eventStore.append(kind: kind, dsn: dsn, packageName: packageName, appName: appName)
        } catch {
            Self.log.error("schedule_monitor event_write_failed kind=\(kind.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        // Read back in THIS process, the same way the report extension's sandbox was measured: if
        // the row is here and the app never sees it, the container is per-process and no App Group
        // entitlement will bridge it.
        let pending = eventStore.loadPendingEvents().count
        Self.log.notice("schedule_monitor event_written kind=\(kind.rawValue, privacy: .public) id=\(appended?.id ?? "dedup", privacy: .public) pending_read_back=\(pending, privacy: .public)")
        guard let event = appended else { return }

        scheduleLocalNotification(for: event)
    }

    func scheduleLocalNotification(for event: DeviceControlEvent) {
        applyPreferredLanguage()

        let content = UNMutableNotificationContent()
        content.title = localNotificationTitle(for: event)
        content.body = localNotificationBody(for: event)
        content.sound = .default
        content.userInfo = [
            "dsn": event.dsn,
            "event": event.kind.rawValue
        ]

        let request = UNNotificationRequest(
            identifier: "device-control.\(event.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// The monitor runs in its own process, so nothing has called `L10n.setLanguage` here. Read
    /// the family's chosen language from the App Group; when it has not been mirrored yet, leave
    /// L10n on the extension bundle's own localization (which follows the device language).
    func applyPreferredLanguage() {
        guard let code = DeviceControlLanguagePreference.storedLanguageCode() else { return }
        L10n.setLanguage(code)
    }

    // Same keys as DeviceControlEventBridge, so the system notification and the in-app inbox
    // entry for one event never disagree.
    func localNotificationTitle(for event: DeviceControlEvent) -> String {
        switch event.kind {
        case .scheduleStarted:
            return L10n.tr("notifications.device_control.schedule_started_title")
        case .scheduleEnded:
            return L10n.tr("notifications.device_control.schedule_ended_title")
        case .appLimitReached:
            if let appName = normalizedAppName(for: event) {
                return L10n.tr("notifications.device_control.app_limit_reached_title", appName)
            }
            return L10n.tr("notifications.device_control.app_limit_reached_title_fallback")
        }
    }

    func localNotificationBody(for event: DeviceControlEvent) -> String {
        switch event.kind {
        case .scheduleStarted:
            return L10n.tr("notifications.device_control.schedule_started_body")
        case .scheduleEnded:
            return L10n.tr("notifications.device_control.schedule_ended_body")
        case .appLimitReached:
            if let appName = normalizedAppName(for: event) {
                return L10n.tr("notifications.device_control.app_limit_reached_body", appName)
            }
            return L10n.tr("notifications.device_control.app_limit_reached_body_fallback")
        }
    }

    func normalizedAppName(for event: DeviceControlEvent) -> String? {
        guard let appName = event.appName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appName.isEmpty else {
            return nil
        }

        return appName
    }
}

/// The app's language choice (`SessionStore` key `APP_LANGUAGE`) mirrored into the App Group so
/// extension processes can localize the same way the app does.
private enum DeviceControlLanguagePreference {
    static let defaultsKey = "APP_LANGUAGE"

    static func storedLanguageCode() -> String? {
        let value = sharedUserDefaults()?
            .string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value, !value.isEmpty else { return nil }

        return value
    }

    private static let envKey = "SMARTOILA_APP_GROUP_IDENTIFIER"
    private static let fallbackIdentifier = "group.3twn5nw4bl.uz.smartoila.kids"

    private static var identifier: String {
        let rawValue = ProcessInfo.processInfo.environment[envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let rawValue, !rawValue.isEmpty {
            return rawValue
        }

        return fallbackIdentifier
    }

    private static func sharedUserDefaults() -> UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}

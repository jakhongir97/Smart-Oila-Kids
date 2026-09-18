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

        // The lock-deadline activity exists for its END only; the lock itself was applied by the
        // app when the server said so. Nothing to do here but say it started.
        if DeviceLockDeadlineActivityIdentifier.isDeadlineActivity(rawValue: activity.rawValue) {
            Self.log.notice("schedule_monitor lock_deadline interval_start")
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

        if DeviceLockDeadlineActivityIdentifier.isDeadlineActivity(rawValue: activity.rawValue) {
            releaseLockAtDeadline(activity: activity)
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
    private let deadlineStore = DeviceLockDeadlineSharedStore()
}

// MARK: - The lock deadline

private extension SmartOilaKidsDeviceActivityMonitorExtension {
    /// The whole-device lock's end arrived and the app may not be running: open the phone.
    ///
    /// This is the product rule of 2026-09-16 in the one process iOS promises to wake for it —
    /// "if the internet is off, the phone unlocks by itself after that time". It writes the two
    /// keys the whole-device lock owns on the DEFAULT store and nothing else: `shield.applications`
    /// holds the per-app blocks, which outlive the lock and which the app's change guard would not
    /// put back. Then it marks the App Group so a relaunched app knows the OS is already open, and
    /// tells an app that happens to be alive to drop its cover.
    ///
    /// Guarded by the recorded end: iOS delivers `intervalDidEnd` for a RESTART of a running
    /// activity too (measured 2026-09-16), and a parent extending the lock must not open it.
    func releaseLockAtDeadline(activity: DeviceActivityName) {
        let now = Date()
        let record = deadlineStore.load()
        guard let dsn = DeviceLockDeadlineActivityIdentifier.dsn(from: activity.rawValue),
              DeviceLockDeadlineMonitoring.isReleaseDue(record: record, dsn: dsn, now: now) else {
            let remaining = record.map { Int($0.endsAt.timeIntervalSince(now)) } ?? -1
            Self.log.notice("schedule_monitor lock_deadline ignored reason=not_due record=\(record == nil ? 0 : 1, privacy: .public) remaining_s=\(remaining, privacy: .public)")
            return
        }
        DeviceLockDeadlineMonitoring.releaseGlobalShield()
        deadlineStore.markReleased(at: now)
        DeviceLockDeadlineSharedStore.postReleased()
        // Read back in this process, the way every App Group write here is verified.
        let readBack = deadlineStore.releasedAt() != nil
        Self.log.notice("schedule_monitor lock_deadline released overdue_s=\(Int(now.timeIntervalSince(record?.endsAt ?? now)), privacy: .public) mark_read_back=\(readBack ? 1 : 0, privacy: .public)")
    }
}

// MARK: - Per-app usage (the staircase)

private extension SmartOilaKidsDeviceActivityMonitorExtension {
    /// "This app has been used for N seconds today." Record N, arm N + step, tell the server.
    ///
    /// Three writes, and the order matters: the ledger first (so a crash after it still leaves
    /// the figure), the re-arm second (so the next rung exists before anything slow happens), the
    /// upload last (network, bounded by a timeout, and the app will retry it anyway).
    func handleUsageThreshold(event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        guard let dsn = ScreenTimeUsageActivity.dsn(from: activity.rawValue),
              let parsed = ScreenTimeUsageActivity.parse(eventName: event.rawValue) else {
            Self.log.error("schedule_monitor usage_event_unparsed event=\(event.rawValue, privacy: .public)")
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

import DeviceActivity
import Foundation
import ManagedSettings
import UserNotifications

final class SmartOilaKidsDeviceActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

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
        guard let event = try? eventStore.append(
            kind: kind,
            dsn: dsn,
            packageName: packageName,
            appName: appName
        ) else {
            return
        }

        scheduleLocalNotification(for: event)
    }

    func scheduleLocalNotification(for event: DeviceControlEvent) {
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

    func localNotificationTitle(for event: DeviceControlEvent) -> String {
        switch event.kind {
        case .scheduleStarted:
            return "Device locked by schedule"
        case .scheduleEnded:
            return "Schedule lock ended"
        case .appLimitReached:
            if let appName = event.appName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !appName.isEmpty {
                return "\(appName) locked for today"
            }
            return "App limit reached"
        }
    }

    func localNotificationBody(for event: DeviceControlEvent) -> String {
        switch event.kind {
        case .scheduleStarted:
            return "A parent device schedule started and Smart Oila locked this iPhone."
        case .scheduleEnded:
            return "The parent device schedule ended and Smart Oila unlocked this iPhone."
        case .appLimitReached:
            if let appName = event.appName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !appName.isEmpty {
                return "The daily limit for \(appName) was reached, so it is locked until tomorrow."
            }
            return "A daily app limit was reached, so the app is locked until tomorrow."
        }
    }
}

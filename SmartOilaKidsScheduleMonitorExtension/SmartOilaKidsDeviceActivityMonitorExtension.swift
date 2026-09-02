import DeviceActivity
import Foundation
import ManagedSettings
import UserNotifications

final class SmartOilaKidsDeviceActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

        if DeviceLockScheduleActivityIdentifier.isScheduleActivity(rawValue: activity.rawValue) {
            // Same shield the app raises, same exceptions — one implementation so the two can never
            // drift. Without the exception set this CLEARS rather than shielding: a schedule that
            // fires at 22:00 and covers Phone would strand the child with no way to call a parent.
            ScreenTimeAlwaysAllowedSharedStore.applyGlobalShield(to: scheduleStore)
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

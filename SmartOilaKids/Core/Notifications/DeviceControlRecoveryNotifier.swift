import Foundation
import UserNotifications

enum DeviceControlRecoveryEvent: String {
    case lockRestored = "device_control_lock_restored"
    case appLimitRestored = "device_control_app_limit_restored"
}

struct DeviceControlTelemetryRecord {
    let dsn: String
    let event: String
    let packageName: String?
    let appName: String?
    let createdAt: Date
}

enum DeviceControlTelemetryUserInfoKey {
    static let dsn = "dsn"
    static let event = "event"
    static let packageName = "packageName"
    static let appName = "appName"
    static let createdAt = "createdAt"
}

extension Notification.Name {
    static let deviceControlTelemetryRecorded = Notification.Name("smartoila.deviceControlTelemetryRecorded")
}

actor DeviceControlRecoveryNotifier {
    static let shared = DeviceControlRecoveryNotifier()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func recordLockRestored(dsn: String) async {
        await record(
            event: .lockRestored,
            dsn: dsn,
            packageName: nil,
            appName: nil
        )
    }

    func recordAppLimitRestored(
        dsn: String,
        packageName: String? = nil,
        appName: String? = nil
    ) async {
        await record(
            event: .appLimitRestored,
            dsn: dsn,
            packageName: packageName,
            appName: appName
        )
    }

    private let userDefaults: UserDefaults
    private let cooldown: TimeInterval = 600
}

private extension DeviceControlRecoveryNotifier {
    enum Keys {
        static let lastSentAtPrefix = "DEVICE_CONTROL_RECOVERY_LAST_SENT_"
    }

    func record(
        event: DeviceControlRecoveryEvent,
        dsn: String,
        packageName: String?,
        appName: String?
    ) async {
        guard let normalizedDSN = normalizedDSN(dsn) else { return }

        let normalizedPackageName = normalizedIdentifier(packageName)
        let normalizedAppName = appName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let fingerprint = [
            event.rawValue,
            normalizedDSN.lowercased(),
            normalizedPackageName ?? ""
        ].joined(separator: "|")
        let now = Date()

        if let lastSentAt = lastSentAt(for: fingerprint),
           now.timeIntervalSince(lastSentAt) < cooldown {
            return
        }

        userDefaults.set(now.timeIntervalSince1970, forKey: key(for: fingerprint))

        let title = localizedTitle(for: event, appName: normalizedAppName)
        let body = localizedBody(for: event, appName: normalizedAppName)

        await PushInboxStore.shared.append(
            title: title,
            body: body,
            event: event.rawValue,
            dsn: normalizedDSN,
            isRead: false,
            receivedAt: now
        )

        scheduleLocalNotification(
            title: title,
            body: body,
            event: event,
            dsn: normalizedDSN
        )
        postTelemetry(
            event: event,
            dsn: normalizedDSN,
            packageName: normalizedPackageName,
            appName: normalizedAppName,
            createdAt: now
        )
    }

    func localizedTitle(for event: DeviceControlRecoveryEvent, appName: String?) -> String {
        switch event {
        case .lockRestored:
            return L10n.tr("notifications.device_control.lock_restored_title")
        case .appLimitRestored:
            if let appName {
                return L10n.tr("notifications.device_control.app_limit_restored_title", appName)
            }
            return L10n.tr("notifications.device_control.app_limit_restored_title_fallback")
        }
    }

    func localizedBody(for event: DeviceControlRecoveryEvent, appName: String?) -> String {
        switch event {
        case .lockRestored:
            return L10n.tr("notifications.device_control.lock_restored_body")
        case .appLimitRestored:
            if let appName {
                return L10n.tr("notifications.device_control.app_limit_restored_body", appName)
            }
            return L10n.tr("notifications.device_control.app_limit_restored_body_fallback")
        }
    }

    func scheduleLocalNotification(
        title: String,
        body: String,
        event: DeviceControlRecoveryEvent,
        dsn: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "dsn": dsn,
            "event": event.rawValue
        ]

        let request = UNNotificationRequest(
            identifier: "device-control.recovery.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func key(for fingerprint: String) -> String {
        Keys.lastSentAtPrefix + fingerprint
    }

    func postTelemetry(
        event: DeviceControlRecoveryEvent,
        dsn: String,
        packageName: String?,
        appName: String?,
        createdAt: Date
    ) {
        var userInfo: [AnyHashable: Any] = [
            DeviceControlTelemetryUserInfoKey.dsn: dsn,
            DeviceControlTelemetryUserInfoKey.event: event.rawValue,
            DeviceControlTelemetryUserInfoKey.createdAt: createdAt.timeIntervalSince1970
        ]

        if let packageName {
            userInfo[DeviceControlTelemetryUserInfoKey.packageName] = packageName
        }

        if let appName {
            userInfo[DeviceControlTelemetryUserInfoKey.appName] = appName
        }

        NotificationCenter.default.post(
            name: .deviceControlTelemetryRecorded,
            object: nil,
            userInfo: userInfo
        )
    }

    func lastSentAt(for fingerprint: String) -> Date? {
        let timestamp = userDefaults.double(forKey: key(for: fingerprint))
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func normalizedDSN(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    func normalizedIdentifier(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension DeviceControlTelemetryRecord {
    init?(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let dsn = (userInfo[DeviceControlTelemetryUserInfoKey.dsn] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
              let event = (userInfo[DeviceControlTelemetryUserInfoKey.event] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty else {
            return nil
        }

        let timestamp = userInfo[DeviceControlTelemetryUserInfoKey.createdAt] as? Double ?? Date().timeIntervalSince1970
        self = DeviceControlTelemetryRecord(
            dsn: dsn,
            event: event,
            packageName: (userInfo[DeviceControlTelemetryUserInfoKey.packageName] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            appName: (userInfo[DeviceControlTelemetryUserInfoKey.appName] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty,
            createdAt: Date(timeIntervalSince1970: timestamp)
        )
    }
}

import Foundation
import UserNotifications

enum DeviceControlIntegrityEvent: String {
    case appTargetsRemoved = "device_control_app_targets_removed"
    case screenTimeRevoked = "device_control_screen_time_revoked"
    case remoteLocksUnenforceable = "device_control_remote_lock_unenforceable"
}

actor DeviceControlIntegrityNotifier {
    static let shared = DeviceControlIntegrityNotifier()

    init(
        userDefaults: UserDefaults = .standard,
        removalAttemptCoordinator: DeviceApplicationRemovalAttemptCoordinator = .shared
    ) {
        self.userDefaults = userDefaults
        self.removalAttemptCoordinator = removalAttemptCoordinator
    }

    func recordAppProtectionRemoved(
        dsn: String?,
        applications: [DeviceAppSelectionApplication]
    ) async {
        guard let normalizedDSN = normalizedDSN(dsn) else { return }

        let normalizedApplications = normalizedApplications(applications)
        guard !normalizedApplications.isEmpty else { return }

        let fingerprint = [
            DeviceControlIntegrityEvent.appTargetsRemoved.rawValue,
            normalizedDSN.lowercased(),
            normalizedApplications.map(\.packageName).joined(separator: ",")
        ].joined(separator: "|")
        guard shouldRecord(fingerprint: fingerprint, now: Date()) else { return }

        for application in normalizedApplications {
            await removalAttemptCoordinator.enqueue(
                dsn: normalizedDSN,
                packageName: application.packageName,
                appName: application.appName
            )
        }

        let now = Date()
        let title = localizedAppRemovalTitle(for: normalizedApplications)
        let body = localizedAppRemovalBody(for: normalizedApplications)

        await PushInboxStore.shared.append(
            title: title,
            body: body,
            event: DeviceControlIntegrityEvent.appTargetsRemoved.rawValue,
            dsn: normalizedDSN,
            isRead: false,
            receivedAt: now
        )

        scheduleLocalNotification(
            title: title,
            body: body,
            event: .appTargetsRemoved,
            dsn: normalizedDSN
        )
        postTelemetry(
            event: .appTargetsRemoved,
            dsn: normalizedDSN,
            packageName: normalizedApplications.first?.packageName,
            appName: normalizedApplications.first?.appName,
            createdAt: now
        )
        updateDiagnostics(
            status: "alerted",
            dsn: normalizedDSN,
            lastEvent: title,
            lastError: "-"
        )
    }

    func recordScreenTimeRevoked(dsn: String?) async {
        guard let normalizedDSN = normalizedDSN(dsn) else { return }
        let now = Date()
        let fingerprint = [
            DeviceControlIntegrityEvent.screenTimeRevoked.rawValue,
            normalizedDSN.lowercased()
        ].joined(separator: "|")
        guard shouldRecord(fingerprint: fingerprint, now: now) else { return }

        let title = L10n.tr("notifications.device_control.screen_time_revoked_title")
        let body = L10n.tr("notifications.device_control.screen_time_revoked_body")

        await PushInboxStore.shared.append(
            title: title,
            body: body,
            event: DeviceControlIntegrityEvent.screenTimeRevoked.rawValue,
            dsn: normalizedDSN,
            isRead: false,
            receivedAt: now
        )

        scheduleLocalNotification(
            title: title,
            body: body,
            event: .screenTimeRevoked,
            dsn: normalizedDSN
        )
        postTelemetry(
            event: .screenTimeRevoked,
            dsn: normalizedDSN,
            packageName: nil,
            appName: nil,
            createdAt: now
        )
        updateDiagnostics(
            status: "alerted",
            dsn: normalizedDSN,
            lastEvent: title,
            lastError: "-"
        )
    }

    func recordUnenforceableRemoteLocks(
        dsn: String?,
        applications: [DeviceAppSelectionApplication]
    ) async {
        guard let normalizedDSN = normalizedDSN(dsn) else { return }

        let normalizedApplications = normalizedApplications(applications)
        guard !normalizedApplications.isEmpty else { return }

        let fingerprint = [
            DeviceControlIntegrityEvent.remoteLocksUnenforceable.rawValue,
            normalizedDSN.lowercased(),
            normalizedApplications.map(\.packageName).joined(separator: ",")
        ].joined(separator: "|")
        let now = Date()
        guard shouldRecord(fingerprint: fingerprint, now: now) else { return }

        let title = localizedRemoteLockMismatchTitle(for: normalizedApplications)
        let body = localizedRemoteLockMismatchBody(for: normalizedApplications)

        await PushInboxStore.shared.append(
            title: title,
            body: body,
            event: DeviceControlIntegrityEvent.remoteLocksUnenforceable.rawValue,
            dsn: normalizedDSN,
            isRead: false,
            receivedAt: now
        )

        scheduleLocalNotification(
            title: title,
            body: body,
            event: .remoteLocksUnenforceable,
            dsn: normalizedDSN
        )
        postTelemetry(
            event: .remoteLocksUnenforceable,
            dsn: normalizedDSN,
            packageName: normalizedApplications.first?.packageName,
            appName: normalizedApplications.first?.appName,
            createdAt: now
        )
        updateDiagnostics(
            status: "alerted",
            dsn: normalizedDSN,
            lastEvent: title,
            lastError: "-"
        )
    }

    private let userDefaults: UserDefaults
    private let removalAttemptCoordinator: DeviceApplicationRemovalAttemptCoordinator
    private let cooldown: TimeInterval = 600
}

private extension DeviceControlIntegrityNotifier {
    enum Keys {
        static let lastSentAtPrefix = "DEVICE_CONTROL_INTEGRITY_LAST_SENT_"
    }

    func normalizedApplications(_ applications: [DeviceAppSelectionApplication]) -> [DeviceAppSelectionApplication] {
        let uniqueApplications = Set(applications.compactMap { application -> DeviceAppSelectionApplication? in
            guard let packageName = application.packageName.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .nilIfEmpty,
                  let appName = application.appName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                return nil
            }

            return DeviceAppSelectionApplication(packageName: packageName, appName: appName)
        })

        return uniqueApplications.sorted { lhs, rhs in
            lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    func localizedAppRemovalTitle(for applications: [DeviceAppSelectionApplication]) -> String {
        if applications.count == 1, let appName = applications.first?.appName {
            return L10n.tr("notifications.device_control.app_targets_removed_title", appName)
        }
        return L10n.tr(
            "notifications.device_control.app_targets_removed_title_plural",
            "\(applications.count)"
        )
    }

    func localizedAppRemovalBody(for applications: [DeviceAppSelectionApplication]) -> String {
        if applications.count == 1, let appName = applications.first?.appName {
            return L10n.tr("notifications.device_control.app_targets_removed_body", appName)
        }
        return L10n.tr(
            "notifications.device_control.app_targets_removed_body_plural",
            "\(applications.count)"
        )
    }

    func localizedRemoteLockMismatchTitle(for applications: [DeviceAppSelectionApplication]) -> String {
        if applications.count == 1, let appName = applications.first?.appName {
            return L10n.tr("notifications.device_control.remote_lock_unenforceable_title", appName)
        }
        return L10n.tr(
            "notifications.device_control.remote_lock_unenforceable_title_plural",
            "\(applications.count)"
        )
    }

    func localizedRemoteLockMismatchBody(for applications: [DeviceAppSelectionApplication]) -> String {
        if applications.count == 1, let appName = applications.first?.appName {
            return L10n.tr("notifications.device_control.remote_lock_unenforceable_body", appName)
        }
        return L10n.tr(
            "notifications.device_control.remote_lock_unenforceable_body_plural",
            "\(applications.count)"
        )
    }

    func scheduleLocalNotification(
        title: String,
        body: String,
        event: DeviceControlIntegrityEvent,
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
            identifier: "device-control.integrity.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func postTelemetry(
        event: DeviceControlIntegrityEvent,
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

    func updateDiagnostics(
        status: String? = nil,
        dsn: String? = nil,
        lastEvent: String? = nil,
        lastError: String? = nil
    ) {
        Task { @MainActor in
            RuntimeDiagnosticsCenter.shared.updateAppLockIntegrity(
                status: status,
                dsn: dsn,
                lastEvent: lastEvent,
                lastError: lastError
            )
        }
    }

    func shouldRecord(fingerprint: String, now: Date) -> Bool {
        if let lastSentAt = lastSentAt(for: fingerprint),
           now.timeIntervalSince(lastSentAt) < cooldown {
            return false
        }

        userDefaults.set(now.timeIntervalSince1970, forKey: key(for: fingerprint))
        return true
    }

    func key(for fingerprint: String) -> String {
        Keys.lastSentAtPrefix + fingerprint
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
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
